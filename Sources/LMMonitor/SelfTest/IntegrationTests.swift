import Foundation

/// End-to-end: the real captured NDJSON of one request (runtime + server + model streams) goes
/// through the same parse closures the supervisor uses, then through the reducer — exactly one
/// correct record must come out, with duplicate engine lines dropped.
enum IntegrationTests {
    static func run(_ t: TestContext) {
        t.suite("Integration · captured request end-to-end")

        typealias Parse = ([String: Any], Date) -> [LMEvent]
        let streams: [(lines: [String], parse: Parse)] = [
            (Fixtures.scenarioRuntime, LMSProcessSupervisor.parseRuntime),
            (Fixtures.scenarioServer, LMSProcessSupervisor.parseServer),
            (Fixtures.scenarioModel, LMSProcessSupervisor.parseModel),
        ]
        var events: [(order: Int, ev: LMEvent)] = []
        var n = 0
        for s in streams {
            for line in s.lines {
                guard let obj = NDJSON.object(Data(line.utf8)) else { continue }
                let at = NDJSON.timestamp(obj) ?? Date(timeIntervalSince1970: 0)
                for e in s.parse(obj, at) { events.append((n, e)); n += 1 }
            }
        }
        t.check("events produced", events.count > 20, "only \(events.count)")
        // Arrival order across the three pipes is by timestamp (stable for equal ms).
        events.sort { $0.ev.at == $1.ev.at ? $0.order < $1.order : $0.ev.at < $1.ev.at }

        let reducer = LMStateReducer()
        var records: [PredictionRecord] = []
        reducer.onRecord = { records.append($0) }
        for (_, e) in events { reducer.apply(e) }
        let last = events.last?.ev.at ?? Date()
        reducer.tick(now: last.addingTimeInterval(10))

        t.equal("exactly one record", records.count, 1)
        if records.count != 1 || t.verbose {
            for r in records {
                print("    record task=\(r.task.map(String.init) ?? "nil") slot=\(r.slot.map(String.init) ?? "nil") phase=\(r.phase) tps=\(r.tokensPerSecond ?? -1) gen=\(r.generatedTokens ?? -1) prompt=\(r.prompt.totalTokens ?? -1) sources=\(r.sources) stop=\(r.stopReason)")
            }
        }
        guard let r = records.first else { return }
        t.near("tok/s from model stream", r.tokensPerSecond, 12.133003034305803, tol: 1e-9)
        t.near("ttft", r.timeToFirstToken, 1.631729, tol: 1e-6)
        t.equal("prompt total", r.prompt.totalTokens, 63)
        t.equal("prompt cached (exact)", r.prompt.cachedTokens, 0)
        t.equal("cached is exact", r.prompt.cachedIsEstimate, false)
        t.equal("generated", r.generatedTokens, 24)
        t.equal("draft accepted", r.draft?.accepted, 16)
        t.equal("draft generated", r.draft?.generated, 18)
        t.equal("context at end", r.contextTokensAtEnd, 86)
        t.equal("stop reason", r.stopReason, .maxPredictedTokensReached)
        t.equal("phase finished", r.phase, .finished)
        t.check("sources include runtime+model", r.sources.contains(.runtime) && r.sources.contains(.model), "\(r.sources)")
        t.check("prefill tok/s present", (r.prefillTokensPerSecond ?? 0) > 30, "\(String(describing: r.prefillTokensPerSecond))")
        t.check("duplicate engine lines dropped", reducer.state.dedupedLines > 0, "deduped \(reducer.state.dedupedLines)")
        // The long mid-flight generation (task 133, slot 3) really kept running until 23:50:40, so it
        // must still be live — server end signals for the short request must not end it.
        t.equal("only the mid-flight task stays live", reducer.state.live.map { $0.task }, [133])
        t.equal("mid-flight task still generating", reducer.state.live.first?.phase, .generating)

        // Alerts on the same event stream must not produce errors for a healthy request.
        let alerts = AlertEngine()
        for (_, e) in events { alerts.note(e) }
        t.check("no error alerts for a healthy request",
                !alerts.isActive(.gpuOOM) && !alerts.isActive(.computeError) && !alerts.isActive(.contextTruncated))
    }

    /// Regressions for issues found in code review.
    static func runReviewFixes(_ t: TestContext) {
        t.suite("Review fixes")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var ctx = EngineContext(); ctx.modelIdentifier = "m"; ctx.instanceReference = "I"; ctx.engineType = "llama.cpp"

        // Stalled generation: no progress line for >10 s → live speed shows 0, not the last rate.
        let r = LMStateReducer()
        let gen = EngineLine.genProgress(slot: 0, task: 7, nGen: 500, tgAvg: 12, tg3s: 12)
        r.apply(LMEvent(at: t0, source: .runtime, kind: .engine(gen, ctx, raw: "1.0 I gen")))
        r.tick(now: t0.addingTimeInterval(2))
        t.near("live rate while progressing", r.state.aggregateTps, 12)
        r.tick(now: t0.addingTimeInterval(15))
        t.near("stalled generation shows 0 t/s", r.state.aggregateTps, 0)

        // Context-overflow / user-stop errors are not critical engine faults.
        let a = AlertEngine()
        a.evaluate(state: LMState(), system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0)
        a.note(LMEvent(at: t0, source: .server, kind: .server(.predictError(model: "m", message: "Context overflow policy error: stop at limit"))))
        a.note(LMEvent(at: t0, source: .server, kind: .server(.predictError(model: "m", message: "terminated"))))
        a.evaluate(state: LMState(), system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0.addingTimeInterval(1))
        t.check("context overflow → contextTruncated", a.isActive(.contextTruncated))
        t.check("context overflow / terminated are not computeError", !a.isActive(.computeError))
        a.note(LMEvent(at: t0, source: .server, kind: .server(.predictError(model: "m", message: #"{"code":500,"message":"Compute error."}"#))))
        a.evaluate(state: LMState(), system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0.addingTimeInterval(2))
        t.check("real engine error → computeError", a.isActive(.computeError))

        // Launch mid-flight: the server-log copy (no runtime metadata) of a task's progress line
        // arrives before the runtime stream's first line → still exactly one live prediction.
        let r3 = LMStateReducer()
        var rec3: [PredictionRecord] = []
        r3.onRecord = { rec3.append($0) }
        let p1 = EngineLine.prefillProgress(slot: 0, task: 12660, nTokens: 10240, progress: 0.51, elapsedSec: 159, tps: 64)
        r3.apply(LMEvent(at: t0, source: .server, kind: .engine(p1, EngineContext(), raw: "88.33.874 I p1")))
        let p2 = EngineLine.prefillProgress(slot: 0, task: 12660, nTokens: 12288, progress: 0.54, elapsedSec: 193, tps: 63)
        r3.apply(LMEvent(at: t0.addingTimeInterval(34), source: .runtime, kind: .engine(p2, ctx, raw: "89.06.524 I p2")))
        t.equal("mid-flight task tracked once", r3.state.live.filter { $0.task == 12660 }.count, 1)
        t.equal("adopted into the real instance", r3.state.live.first?.key.instance, "I")
        t.check("placeholder instance removed", r3.state.instances["default"] == nil)
        r3.apply(LMEvent(at: t0.addingTimeInterval(40), source: .runtime, kind: .engine(.taskCancelled(task: 12660), ctx, raw: "90.42 W c")))
        r3.apply(LMEvent(at: t0.addingTimeInterval(58), source: .runtime, kind: .engine(.slotReleased(slot: 0, task: 12660, nTokens: 48070, truncated: false), ctx, raw: "91.00 I r")))
        r3.tick(now: t0.addingTimeInterval(70))
        t.equal("one record for the task", rec3.filter { $0.task == 12660 }.count, 1)

        // Log-file fallback marks the state degraded.
        let r2 = LMStateReducer()
        r2.apply(LMEvent(at: t0, source: .logfile, kind: .stream(.logfile, .running(since: t0))))
        t.check("degraded when tailing log file", r2.state.degradedReason != nil)
    }
}

