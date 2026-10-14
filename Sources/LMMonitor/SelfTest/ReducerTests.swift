import Foundation

/// Scenario tests for LMStateReducer, AlertEngine, MemoryFit and Aggregates. Events are built
/// directly (no parsers involved) from the real 2026-10-14 23:49:33–36 capture and other real
/// server-log lines, so every timestamp below is a genuine LM Studio timestamp.
enum ReducerTests {
    // MARK: Fixtures

    static let instance = "QDB8g1tEXbuH0ZXm2JaOKRav"
    static let model = "qwen/qwen3.8-27b"
    static let ctx = EngineContext(modelIdentifier: model, instanceReference: instance,
                                   engineName: "llama.cpp-mac-arm64-apple-metal-advsimd", engineVersion: "2.57.0",
                                   engineType: "llama.cpp", pid: 6932)

    static func T(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    static func rt(_ line: EngineLine, _ raw: String, _ at: Date, source: EventSource = .runtime, ctx: EngineContext = ctx) -> LMEvent {
        LMEvent(at: at, source: source, kind: .engine(line, source == .runtime ? ctx : EngineContext(), raw: raw))
    }
    static func sv(_ line: ServerLine, _ at: Date) -> LMEvent {
        LMEvent(at: at, source: .server, kind: .server(line))
    }
    static func st(_ s: ModelStatsEvent, _ at: Date) -> LMEvent {
        LMEvent(at: at, source: .model, kind: .modelStats(s))
    }
    static func stats(model: String = model, stop: String = "eosFound", tps: Double, ttft: Double, total: Double,
                      prompt: Int, predicted: Int, draftTotal: Int? = nil, draftAccepted: Int? = nil) -> ModelStatsEvent {
        ModelStatsEvent(modelIdentifier: model, stopReasonRaw: stop, tokensPerSecond: tps, timeToFirstTokenSec: ttft,
                        totalTimeSec: total, promptTokensCount: prompt, predictedTokensCount: predicted,
                        totalTokensCount: prompt + predicted, totalDraftTokensCount: draftTotal,
                        acceptedDraftTokensCount: draftAccepted,
                        rejectedDraftTokensCount: draftTotal.flatMap { t in draftAccepted.map { t - $0 } },
                        outputCharCount: predicted * 4)
    }

    /// Runtime final block as llama.cpp prints it (one multi-line message → 4 parsed lines), plus release.
    static func finalBlock(_ r: LMStateReducer, slot: Int, task: Int, at: Date, promptMs: Double, promptTokens: Int, promptTps: Double,
                           evalMs: Double, evalTokens: Int, evalTps: Double, release: Int, truncated: Bool = false,
                           draft: (Int, Int, Double)? = nil, uptime: String = "46.30.710", withServerCopies: Bool = false) -> Int {
        var dups = 0
        func both(_ line: EngineLine, _ raw: String, _ t: Date) {
            r.apply(rt(line, raw, t))
            if withServerCopies { r.apply(rt(line, raw, t, source: .server)); dups += 1 }
        }
        both(.promptEval(slot: slot, task: task, ms: promptMs, tokens: promptTokens, tps: promptTps),
             "\(uptime).704 I slot print_timing: id  \(slot) | task \(task) | prompt eval time =    \(promptMs) ms /    \(promptTokens) tokens (   25.90 ms per token,    \(promptTps) tokens per second)", at)
        both(.eval(slot: slot, task: task, ms: evalMs, tokens: evalTokens, tps: evalTps),
             "\(uptime).722 I slot print_timing: id  \(slot) | task \(task) |        eval time =    \(evalMs) ms /    \(evalTokens) tokens (   82.42 ms per token,    \(evalTps) tokens per second)", at)
        both(.totalTime(slot: slot, task: task, ms: promptMs + evalMs, tokens: promptTokens + evalTokens),
             "\(uptime).725 I slot print_timing: id  \(slot) | task \(task) |       total time =    \(promptMs + evalMs) ms /    \(promptTokens + evalTokens) tokens", at)
        if let (acc, gen, mean) = draft {
            both(.draftAcceptance(slot: slot, task: task, ratio: Double(acc) / Double(gen), accepted: acc, generated: gen, meanLen: mean),
                 "\(uptime).729 I slot print_timing: id  \(slot) | task \(task) | draft acceptance = 0.88889 (   \(acc) accepted /    \(gen) generated), mean len =  \(mean)", at)
        }
        both(.slotReleased(slot: slot, task: task, nTokens: release, truncated: truncated),
             "\(uptime).823 I slot      release: id  \(slot) | task \(task) | stop processing: n_tokens = \(release), truncated = \(truncated ? 1 : 0)", at.addingTimeInterval(0.001))
        return dups
    }

    static func launch(_ r: LMStateReducer, slot: Int, task: Int, at: Date, reuse: PrefixReuse = .lru(tLast: -1), uptime: String = "46.27.152") {
        let reuseRaw: String
        switch reuse {
        case let .lru(t): reuseRaw = "selected slot by LRU, t_last = \(t)"
        case let .lcp(s, k): reuseRaw = "selected slot by LCP similarity, f_sim_best = \(s) (> 0.100 thold), f_keep = \(k)"
        case .unknown: reuseRaw = "?"
        }
        r.apply(rt(.slotSelected(slot: slot, reuse: reuse), "\(uptime).761 I slot get_availabl: id  \(slot) | task -1 | \(reuseRaw)", at))
        r.apply(rt(.taskLaunched(slot: slot, task: task, isChild: false), "\(uptime).809 I slot launch_slot_: id  \(slot) | task \(task) | processing task, is_child = 0", at.addingTimeInterval(0.001)))
    }

    static func gen(_ r: LMStateReducer, slot: Int, task: Int, n: Int, tg: Double, tg3s: Double, at: Date, uptime: String, source: EventSource = .runtime) {
        r.apply(rt(.genProgress(slot: slot, task: task, nGen: n, tgAvg: tg, tg3s: tg3s),
                   "\(uptime) I slot print_timing: id  \(slot) | task \(task) | n_gen =  \(n), tg =  \(tg) t/s, tg_3s =  \(tg3s) t/s", at, source: source))
    }

    static func liveFor(_ r: LMStateReducer, task: Int) -> LivePrediction? { r.state.live.first { $0.task == task } }

    // MARK: - Entry

    static func run(_ t: TestContext) {
        realSequence(t)
        lcpEstimate(t)
        midFlightAndRunaway(t)
        parallelSlots(t)
        standaloneStats(t)
        cancellationPaths(t)
        mlxPseudoSlot(t)
        graceAndHousekeeping(t)
        contextlessServerCopies(t)
        serverEndSignalsVsRuntimeSlots(t)
        alertEngine(t)
        memoryFit(t)
        aggregates(t)
    }

    // MARK: - Suite: the real 23:49:33–36 sequence

    static func realSequence(_ t: TestContext) {
        t.suite("Reducer · real llama.cpp sequence")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        var transitions = 0
        r.onRecord = { records.append($0) }
        r.onTransition = { transitions += 1 }
        var dups = 0

        // Task 133 is already generating on slot 3 when we start (mid-flight).
        let g1 = "46.26.021.689 I slot print_timing: id  3 | task 133 | n_gen =  27343, tg =  13.30 t/s, tg_3s =  16.33 t/s"
        r.apply(rt(.genProgress(slot: 3, task: 133, nGen: 27343, tgAvg: 13.30, tg3s: 16.33), g1, T(1792001972040)))
        r.apply(rt(.genProgress(slot: 3, task: 133, nGen: 27343, tgAvg: 13.30, tg3s: 16.33), g1, T(1792001972040), source: .server)); dups += 1
        t.equal("mid-flight live created", r.state.live.count, 1)
        t.equal("mid-flight phase", r.state.live.first?.phase, .generating)
        t.equal("mid-flight tokens", r.state.live.first?.generatedTokens, 27343)
        t.equal("instance registered", r.state.instances[instance]?.engineType, "llama.cpp")
        t.equal("instance pid", r.state.instances[instance]?.pid, 6932)

        r.apply(sv(.requestReceived(method: "POST", path: "/api/v0/chat/completions"), T(1792001973129)))
        r.apply(sv(.chatStarted(model: model, messageCount: 1), T(1792001973134)))
        let sel = "46.27.152.761 I slot get_availabl: id  2 | task -1 | selected slot by LRU, t_last = -1"
        r.apply(rt(.slotSelected(slot: 2, reuse: .lru(tLast: -1)), sel, T(1792001973171)))
        r.apply(rt(.slotSelected(slot: 2, reuse: .lru(tLast: -1)), sel, T(1792001973171), source: .server)); dups += 1
        let lau = "46.27.152.809 I slot launch_slot_: id  2 | task 10325 | processing task, is_child = 0"
        r.apply(rt(.taskLaunched(slot: 2, task: 10325, isChild: false), lau, T(1792001973172)))
        r.apply(rt(.taskLaunched(slot: 2, task: 10325, isChild: false), lau, T(1792001973172), source: .server)); dups += 1

        t.equal("two live predictions", r.state.live.count, 2)
        let live0 = liveFor(r, task: 10325)
        t.equal("launched phase", live0?.phase, .prefilling)
        t.equal("messageCount attached", live0?.messageCount, 1)
        t.equal("endpoint attached", live0?.endpoint, "/api/v0/chat/completions")
        t.equal("LRU → cached 0", live0?.prompt.cachedTokens, 0)
        t.equal("LRU t_last -1 is exact", live0?.prompt.cachedIsEstimate, false)
        t.equal("reuse recorded", live0?.reuse, .lru(tLast: -1))
        t.equal("startedAt = launch time", live0?.startedAt, T(1792001973172))

        r.apply(sv(.prefillProgress(model: model, percent: 0.0), T(1792001973203)))
        r.apply(sv(.prefillProgress(model: model, percent: 66.7), T(1792001974168)))
        t.near("server progress", liveFor(r, task: 10325)?.progress, 0.667, tol: 1e-9)
        t.equal("still prefilling", liveFor(r, task: 10325)?.phase, .prefilling)
        r.apply(sv(.prefillProgress(model: model, percent: 93.7), T(1792001974578)))
        r.apply(sv(.prefillProgress(model: model, percent: 100.0), T(1792001974834)))
        t.equal("100% → generating", liveFor(r, task: 10325)?.phase, .generating)
        t.equal("other slot untouched", liveFor(r, task: 133)?.phase, .generating)

        let g2 = "46.29.099.244 I slot print_timing: id  3 | task 133 | n_gen =  27375, tg =  13.30 t/s, tg_3s =  10.40 t/s"
        r.apply(rt(.genProgress(slot: 3, task: 133, nGen: 27375, tgAvg: 13.30, tg3s: 10.40), g2, T(1792001975118)))
        r.apply(rt(.genProgress(slot: 3, task: 133, nGen: 27375, tgAvg: 13.30, tg3s: 10.40), g2, T(1792001975118), source: .server)); dups += 1
        t.near("aggregate tps = tg_3s of generating slots", r.state.aggregateTps, 10.40, tol: 1e-9)

        dups += finalBlock(r, slot: 2, task: 10325, at: T(1792001976729), promptMs: 1631.73, promptTokens: 63, promptTps: 38.61,
                           evalMs: 1895.66, evalTokens: 24, evalTps: 12.13, release: 86, draft: (16, 18, 3.67), withServerCopies: true)
        t.equal("finishing after release", liveFor(r, task: 10325)?.phase, .finishing)
        t.equal("no record before S2", records.count, 0)
        t.equal("slotLastNTokens from release", r.state.instances[instance]?.slotLastNTokens[2], 86)

        r.apply(st(stats(stop: "maxPredictedTokensReached", tps: 12.133003034305803, ttft: 1.631729, total: 3.527385,
                         prompt: 63, predicted: 24, draftTotal: 18, draftAccepted: 16), T(1792001976732)))
        r.apply(sv(.generatedPrediction(model: model), T(1792001976734)))

        t.equal("exactly one record", records.count, 1)
        guard let rec = records.first else { return }
        t.near("tokensPerSecond from S2", rec.tokensPerSecond, 12.133003034305803, tol: 1e-12)
        t.equal("prompt total", rec.prompt.totalTokens, 63)
        t.equal("prompt processed", rec.prompt.processedTokens, 63)
        t.equal("prompt cached", rec.prompt.cachedTokens, 0)
        t.equal("cached exact", rec.prompt.cachedIsEstimate, false)
        t.equal("draft", rec.draft, DraftStats(accepted: 16, generated: 18, meanLength: 3.67))
        t.equal("contextTokensAtEnd", rec.contextTokensAtEnd, 86)
        t.equal("messageCount", rec.messageCount, 1)
        t.equal("endpoint", rec.endpoint, "/api/v0/chat/completions")
        t.check("sources ⊇ runtime/server/model", Set(rec.sources).isSuperset(of: [.runtime, .server, .model]), "\(rec.sources)")
        t.equal("phase finished", rec.phase, .finished)
        t.equal("stop reason", rec.stopReason, .maxPredictedTokensReached)
        t.equal("stop reason raw", rec.stopReasonRaw, "maxPredictedTokensReached")
        t.near("prefill tps", rec.prefillTokensPerSecond, 38.61, tol: 1e-9)
        t.near("ttft (S2 wins)", rec.timeToFirstToken, 1.631729, tol: 1e-9)
        t.near("generation time (runtime eval)", rec.generationTime, 1.89566, tol: 1e-9)
        t.near("total time (S2)", rec.totalTime, 3.527385, tol: 1e-9)
        t.equal("generated", rec.generatedTokens, 24)
        t.equal("slot", rec.slot, 2)
        t.equal("task", rec.task, 10325)
        t.equal("instance", rec.instance, instance)
        t.equal("engineType", rec.engineType, "llama.cpp")
        t.equal("startedAt", rec.startedAt, T(1792001973172))
        t.equal("finishedAt = runtime final block", rec.finishedAt, T(1792001976729))
        t.equal("not truncated", rec.truncated, false)
        t.equal("no error", rec.error, nil)
        t.equal("lastRecord published", r.state.lastRecord, rec)
        t.equal("task 133 still live", r.state.live.count, 1)
        t.equal("task 133 tokens", liveFor(r, task: 133)?.generatedTokens, 27375)
        t.equal("dedupedLines", r.state.dedupedLines, dups)
        t.check("transitions fired", transitions >= 4, "\(transitions)")
        t.check("debug ring bounded", r.debugLines.count <= 50 && r.debugLines.count > 5, "\(r.debugLines.count)")
        t.check("debug line format", r.debugLines.first.map { $0.contains("] ") && $0.contains("[runtime]") } ?? false, r.debugLines.first ?? "")
        t.check("debug excludes duplicates", r.debugLines.filter { $0.contains("launch_slot_") }.count == 1)
    }

    // MARK: - Suite: LCP estimate without S2

    static func lcpEstimate(_ t: TestContext) {
        t.suite("Reducer · LCP prefix estimate")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792001000000)

        // Release for a task we never saw (started mid-flight): no record, but the slot size is remembered.
        r.apply(rt(.slotReleased(slot: 3, task: 0, nTokens: 2048, truncated: false),
                   "3.53.818.854 I slot      release: id  3 | task 0 | stop processing: n_tokens = 2048, truncated = 0", t0))
        t.equal("unknown release → no record", records.count, 0)
        t.equal("unknown release → no live", r.state.live.count, 0)
        t.equal("slot size remembered", r.state.instances[instance]?.slotLastNTokens[3], 2048)

        launch(r, slot: 3, task: 55, at: t0.addingTimeInterval(1), reuse: .lcp(fSim: 0.919, fKeep: 0.986), uptime: "2.52.514")
        let live = liveFor(r, task: 55)
        t.equal("LCP cached estimate", live?.prompt.cachedTokens, 2019)
        t.equal("LCP marked estimate", live?.prompt.cachedIsEstimate, true)
        t.equal("reuse", live?.reuse, .lcp(fSim: 0.919, fKeep: 0.986))

        r.apply(rt(.prefillProgress(slot: 3, task: 55, nTokens: 30, progress: 1.0, elapsedSec: 0.5, tps: 60),
                   "2.53.000.000 I slot print_timing: id  3 | task 55 | prompt processing, n_tokens =     30, progress = 1.000000, t =   0.50 s /  60.00 tokens per second", t0.addingTimeInterval(1.5)))
        t.equal("prefill tokens", liveFor(r, task: 55)?.prefillProcessedTokens, 30)
        _ = finalBlock(r, slot: 3, task: 55, at: t0.addingTimeInterval(3), promptMs: 500, promptTokens: 30, promptTps: 60,
                       evalMs: 1000, evalTokens: 12, evalTps: 12, release: 2061, uptime: "2.55.000")
        t.equal("finishing", liveFor(r, task: 55)?.phase, .finishing)
        r.tick(now: t0.addingTimeInterval(4))
        t.equal("grace not expired", records.count, 0)
        t.equal("still live during grace", r.state.live.count, 1)
        r.tick(now: t0.addingTimeInterval(6.1))
        t.equal("finalized after grace", records.count, 1)
        t.equal("live cleared", r.state.live.count, 0)
        guard let rec = records.first else { return }
        t.equal("cached ≈ 2019", rec.prompt.cachedTokens, 2019)
        t.equal("cached is estimate", rec.prompt.cachedIsEstimate, true)
        t.equal("processed 30", rec.prompt.processedTokens, 30)
        t.equal("total ≈ 2049", rec.prompt.totalTokens, 2049)
        t.equal("context at end", rec.contextTokensAtEnd, 2061)
        t.near("tps from runtime eval", rec.tokensPerSecond, 12, tol: 1e-9)
        t.equal("sources runtime only", rec.sources, [.runtime])
        t.equal("stop unknown without S2", rec.stopReason, .unknown)
        t.equal("phase finished", rec.phase, .finished)
        t.equal("finishedAt = final block", rec.finishedAt, t0.addingTimeInterval(3))
    }

    // MARK: - Suite: mid-flight + runaway

    static func midFlightAndRunaway(_ t: TestContext) {
        t.suite("Reducer · mid-flight start & runaway alert")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792001972040)
        gen(r, slot: 3, task: 133, n: 27343, tg: 13.30, tg3s: 16.33, at: t0, uptime: "46.26.021.689")
        guard let live = r.state.live.first else { t.check("live created", false); return }
        t.equal("phase generating", live.phase, .generating)
        t.equal("generated", live.generatedTokens, 27343)
        t.near("startedAt estimated from n_gen/tg", live.startedAt.timeIntervalSince1970, t0.timeIntervalSince1970 - 27343 / 13.30, tol: 1e-6)
        t.equal("generationStartedAt set", live.generationStartedAt, live.startedAt)
        t.equal("model from ctx", live.model, model)
        t.near("currentTps", live.currentTps, 16.33, tol: 1e-9)

        let a = AlertEngine()
        a.evaluate(state: r.state, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0)
        t.check("runaway active (tokens ≥ 20000)", a.isActive(.runawayGeneration))
        let raised = a.drainNewlyRaised()
        t.check("runaway in newlyRaised", raised.contains { $0.rule == .runawayGeneration })
        t.check("runaway detail mentions tokens", a.active.first { $0.rule == .runawayGeneration }?.detail.contains("27.3k") ?? false,
                a.active.first { $0.rule == .runawayGeneration }?.detail ?? "")
        t.equal("drain empties", a.drainNewlyRaised().count, 0)

        // Finish it: final block + release, S2 arrives → record; alert clears.
        let t1 = t0.addingTimeInterval(5)
        _ = finalBlock(r, slot: 3, task: 133, at: t1, promptMs: 20000, promptTokens: 4000, promptTps: 200,
                       evalMs: 2_100_000, evalTokens: 27400, evalTps: 13.05, release: 31400, uptime: "46.31.000")
        r.apply(st(stats(stop: "eosFound", tps: 13.05, ttft: 20.0, total: 2120.0, prompt: 4000, predicted: 27400), t1.addingTimeInterval(0.002)))
        t.equal("record for mid-flight task", records.count, 1)
        t.equal("record generated", records.first?.generatedTokens, 27400)
        t.equal("record cached exact", records.first?.prompt.cachedTokens, 0)
        a.evaluate(state: r.state, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t1.addingTimeInterval(0.5))
        t.check("runaway cleared when prediction ends", !a.isActive(.runawayGeneration))
    }

    // MARK: - Suite: parallel slots

    static func parallelSlots(_ t: TestContext) {
        t.suite("Reducer · parallel slots")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792002000000)
        r.apply(rt(.modelInitialized(nSlots: 4, nCtxSlot: 102400, kvUnified: true),
                   "0.34.630.517 I srv    load_model: initializing, n_slots = 4, n_ctx_slot = 102400, kv_unified = 'true'", t0))
        r.apply(sv(.chatStarted(model: model, messageCount: 3), t0.addingTimeInterval(0.1)))
        launch(r, slot: 0, task: 100, at: t0.addingTimeInterval(0.2), uptime: "10.00.000")
        r.apply(sv(.chatStarted(model: model, messageCount: 7), t0.addingTimeInterval(0.3)))
        launch(r, slot: 1, task: 101, at: t0.addingTimeInterval(0.4), uptime: "10.00.200")
        t.equal("two live", r.state.live.count, 2)
        t.equal("A messageCount", liveFor(r, task: 100)?.messageCount, 3)
        t.equal("B messageCount", liveFor(r, task: 101)?.messageCount, 7)
        t.equal("context limit from n_ctx_slot", liveFor(r, task: 101)?.contextLimit, 102400)

        gen(r, slot: 0, task: 100, n: 30, tg: 20.0, tg3s: 21.0, at: t0.addingTimeInterval(2), uptime: "10.02.000.000")
        gen(r, slot: 1, task: 101, n: 20, tg: 9.0, tg3s: 9.5, at: t0.addingTimeInterval(2.1), uptime: "10.02.100.000")
        t.equal("A tokens", liveFor(r, task: 100)?.generatedTokens, 30)
        t.equal("B tokens", liveFor(r, task: 101)?.generatedTokens, 20)
        t.near("Σ tg_3s", r.state.aggregateTps, 30.5, tol: 1e-9)

        // B finishes first (120 tokens), then A (50 tokens). S2 for B arrives first.
        _ = finalBlock(r, slot: 1, task: 101, at: t0.addingTimeInterval(14), promptMs: 800, promptTokens: 400, promptTps: 500,
                       evalMs: 13200, evalTokens: 120, evalTps: 9.09, release: 520, uptime: "10.14.000")
        _ = finalBlock(r, slot: 0, task: 100, at: t0.addingTimeInterval(14.5), promptMs: 300, promptTokens: 100, promptTps: 333,
                       evalMs: 2500, evalTokens: 50, evalTps: 20.0, release: 150, uptime: "10.14.500")
        t.equal("both finishing, none recorded yet", records.count, 0)
        r.apply(st(stats(stop: "eosFound", tps: 9.1, ttft: 0.8, total: 14.0, prompt: 400, predicted: 120), t0.addingTimeInterval(14.6)))
        r.apply(st(stats(stop: "eosFound", tps: 20.2, ttft: 0.3, total: 2.8, prompt: 100, predicted: 50), t0.addingTimeInterval(14.7)))
        t.equal("two records", records.count, 2)
        let recB = records.first { $0.task == 101 }
        let recA = records.first { $0.task == 100 }
        t.near("B tps matched by token count", recB?.tokensPerSecond, 9.1, tol: 1e-9)
        t.equal("B generated", recB?.generatedTokens, 120)
        t.equal("B messageCount", recB?.messageCount, 7)
        t.equal("B context at end", recB?.contextTokensAtEnd, 520)
        t.near("A tps", recA?.tokensPerSecond, 20.2, tol: 1e-9)
        t.equal("A generated", recA?.generatedTokens, 50)
        t.equal("A messageCount", recA?.messageCount, 3)
        t.equal("A prompt processed", recA?.prompt.processedTokens, 100)
        t.equal("A slot", recA?.slot, 0)
        t.equal("B slot", recB?.slot, 1)
        t.equal("live cleared", r.state.live.count, 0)

        // Child tasks are tracked but never recorded.
        r.apply(rt(.taskLaunched(slot: 2, task: 200, isChild: true), "10.20.000.000 I slot launch_slot_: id  2 | task 200 | processing task, is_child = 1", t0.addingTimeInterval(20)))
        t.equal("child tracked", r.state.live.first?.isChild, true)
        t.equal("child excluded from prefilling", r.state.prefilling.count, 0)
        _ = finalBlock(r, slot: 2, task: 200, at: t0.addingTimeInterval(22), promptMs: 10, promptTokens: 5, promptTps: 500,
                       evalMs: 1000, evalTokens: 20, evalTps: 20, release: 25, uptime: "10.22.000")
        r.tick(now: t0.addingTimeInterval(26))
        t.equal("child never recorded", records.count, 2)
        t.equal("child removed", r.state.live.count, 0)

        // A missed release: a new launch on a busy slot cancels the stale prediction.
        launch(r, slot: 0, task: 300, at: t0.addingTimeInterval(30), uptime: "10.30.000")
        gen(r, slot: 0, task: 300, n: 10, tg: 10, tg3s: 10, at: t0.addingTimeInterval(31), uptime: "10.31.000.000")
        launch(r, slot: 0, task: 301, at: t0.addingTimeInterval(32), uptime: "10.32.000")
        t.equal("stale prediction recorded as cancelled", records.last?.phase, .cancelled)
        t.equal("stale task id", records.last?.task, 300)
        t.equal("one live after relaunch", r.state.live.count, 1)
        t.equal("new task live", r.state.live.first?.task, 301)
    }

    // MARK: - Suite: standalone S2 record

    static func standaloneStats(_ t: TestContext) {
        t.suite("Reducer · standalone model stats")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792003000000)
        r.apply(models: [ModelInfo(id: "qwen3.8-27b-mlx", format: "mlx", architecture: "qwen3_5", maxContextLength: 262144, loadedContextLength: 65536, isLoaded: true)],
                serverReachable: true, port: 1234, lmStudioRunning: true, lmsPath: "/x/lms")
        r.apply(st(stats(model: "qwen3.8-27b-mlx", stop: "stopStringFound", tps: 25.5, ttft: 2.0, total: 12.0, prompt: 500, predicted: 250), t0))
        t.equal("one record", records.count, 1)
        guard let rec = records.first else { return }
        t.equal("sources model only", rec.sources, [.model])
        t.equal("startedAt = at − total", rec.startedAt, t0.addingTimeInterval(-12))
        t.equal("finishedAt", rec.finishedAt, t0)
        t.equal("prompt total", rec.prompt.totalTokens, 500)
        t.equal("cached unknown", rec.prompt.cachedTokens, nil)
        t.equal("generated", rec.generatedTokens, 250)
        t.near("tps", rec.tokensPerSecond, 25.5, tol: 1e-9)
        t.near("generation time", rec.generationTime, 10.0, tol: 1e-9)
        t.equal("stop", rec.stopReason, .stopStringFound)
        t.equal("context at end", rec.contextTokensAtEnd, 750)
        t.equal("context limit from catalog", rec.contextLimit, 65536)
        t.equal("engine type from catalog", rec.engineType, "mlx")
        t.equal("no slot", rec.slot, nil)
        t.equal("no live created", r.state.live.count, 0)
        t.equal("lmsPath stored", r.state.lmsPath, "/x/lms")
        t.equal("serverReachable", r.state.serverReachable, true)
    }

    // MARK: - Suite: cancellation / error

    static func cancellationPaths(_ t: TestContext) {
        t.suite("Reducer · cancellation & errors")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792004000000)

        // User stop: release → cancel (real order), no S2.
        launch(r, slot: 1, task: 7, at: t0, uptime: "20.00.000")
        gen(r, slot: 1, task: 7, n: 40, tg: 10, tg3s: 10, at: t0.addingTimeInterval(4), uptime: "20.04.000.000")
        r.apply(rt(.slotReleased(slot: 1, task: 7, nTokens: 500, truncated: false), "20.05.000.100 I slot      release: id  1 | task 7 | stop processing: n_tokens = 500, truncated = 0", t0.addingTimeInterval(5)))
        r.apply(rt(.taskCancelled(task: 7), "20.05.000.200 W srv          stop: cancel task, id_task = 7", t0.addingTimeInterval(5.0001)))
        t.equal("cancel keeps it finishing for grace", liveFor(r, task: 7)?.phase, .finishing)
        r.tick(now: t0.addingTimeInterval(9))
        t.equal("cancelled record", records.count, 1)
        t.equal("phase cancelled", records.last?.phase, .cancelled)
        t.equal("stop reason cancelled", records.last?.stopReason, .cancelled)
        t.equal("generated from n_gen", records.last?.generatedTokens, 40)
        t.equal("context at end from release", records.last?.contextTokensAtEnd, 500)

        // Compute error: OOM → release → cancel → decode failed (uptime order from the real log).
        launch(r, slot: 3, task: 0, at: t0.addingTimeInterval(20), uptime: "3.50.000")
        gen(r, slot: 3, task: 0, n: 100, tg: 3.2, tg3s: 3.2, at: t0.addingTimeInterval(22), uptime: "3.52.000.000")
        r.apply(rt(.gpuOOM(message: "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"),
                   "3.50.618.139 E error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)", t0.addingTimeInterval(23)))
        t.equal("error attached", liveFor(r, task: 0)?.error, "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)")
        r.apply(rt(.slotReleased(slot: 3, task: 0, nTokens: 2048, truncated: false), "3.53.818.854 I slot      release: id  3 | task 0 | stop processing: n_tokens = 2048, truncated = 0", t0.addingTimeInterval(23.1)))
        r.apply(rt(.taskCancelled(task: 0), "3.53.818.885 W srv          stop: cancel task, id_task = 0", t0.addingTimeInterval(23.1001)))
        r.apply(rt(.decodeFailed(message: "Compute error."), "3.53.818.956 E srv  update_slots: decode() failed: Compute error.", t0.addingTimeInterval(23.1002)))
        t.equal("first error wins", liveFor(r, task: 0)?.error, "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)")
        r.tick(now: t0.addingTimeInterval(27))
        t.equal("errored record", records.count, 2)
        t.equal("phase errored", records.last?.phase, .errored)
        t.equal("stop failed", records.last?.stopReason, .failed)
        t.check("error text kept", records.last?.error?.contains("Insufficient Memory") ?? false)

        // Client disconnect on a pseudo-slot prediction finishes it as user-stopped.
        r.apply(models: [ModelInfo(id: "some-mlx", format: "mlx", isLoaded: true)], serverReachable: true, port: 1234, lmStudioRunning: true, lmsPath: "/x")
        r.apply(sv(.prefillProgress(model: "some-mlx", percent: 0), t0.addingTimeInterval(40)))
        r.apply(sv(.prefillProgress(model: "some-mlx", percent: 100), t0.addingTimeInterval(41)))
        t.equal("pseudo generating", r.state.live.first?.phase, .generating)
        r.apply(sv(.clientDisconnected, t0.addingTimeInterval(45)))
        t.equal("pseudo finishing after disconnect", r.state.live.first?.phase, .finishing)
        r.tick(now: t0.addingTimeInterval(49))
        t.equal("user-stopped record", records.last?.stopReason, .userStopped)
        t.equal("user-stopped phase", records.last?.phase, .cancelled)

        // S2 stop reason overrides a pending cancel outcome.
        launch(r, slot: 2, task: 9, at: t0.addingTimeInterval(60), uptime: "30.00.000")
        r.apply(rt(.slotReleased(slot: 2, task: 9, nTokens: 90, truncated: false), "30.01.000.100 I slot      release: id  2 | task 9 | stop processing: n_tokens = 90, truncated = 0", t0.addingTimeInterval(61)))
        r.apply(rt(.taskCancelled(task: 9), "30.01.000.200 W srv          stop: cancel task, id_task = 9", t0.addingTimeInterval(61.0001)))
        r.apply(st(stats(stop: "userStopped", tps: 10, ttft: 0.5, total: 1.0, prompt: 80, predicted: 10), t0.addingTimeInterval(61.1)))
        t.equal("S2 userStopped → cancelled", records.last?.phase, .cancelled)
        t.equal("S2 stop reason kept", records.last?.stopReason, .userStopped)

        // LM Studio quits: everything live is cancelled, instances dropped.
        launch(r, slot: 0, task: 11, at: t0.addingTimeInterval(70), uptime: "40.00.000")
        r.tick(now: t0.addingTimeInterval(71))
        r.apply(models: [], serverReachable: false, port: 1234, lmStudioRunning: false, lmsPath: "/x")
        t.equal("quit cancels live", r.state.live.count, 0)
        t.equal("quit clears instances", r.state.instances.count, 0)
        t.equal("quit record phase", records.last?.phase, .cancelled)
    }

    // MARK: - Suite: MLX pseudo slot

    static func mlxPseudoSlot(_ t: TestContext) {
        t.suite("Reducer · MLX pseudo slot")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let mlx = "qwen3.8-27b-mlx"
        let t0 = T(1792005000000)
        r.apply(models: [ModelInfo(id: mlx, format: "mlx", architecture: "qwen3_5", maxContextLength: 262144, loadedContextLength: 65536, isLoaded: true)],
                serverReachable: true, port: 1234, lmStudioRunning: true, lmsPath: "/x/lms")

        r.apply(sv(.requestReceived(method: "POST", path: "/v1/chat/completions"), t0))
        r.apply(sv(.chatStarted(model: mlx + "@4bit", messageCount: 5), t0.addingTimeInterval(0.05)))
        r.apply(sv(.promptCacheRestore(PromptCacheRestore(cachedTokens: 3584, uncachedTokens: 540, lifetimeEfficiency: 45.51)), t0.addingTimeInterval(0.1)))
        t.equal("cache restore remembered", r.state.lastCacheRestore?.cachedTokens, 3584)
        r.apply(sv(.prefillProgress(model: mlx, percent: 0.0), t0.addingTimeInterval(0.2)))
        t.equal("pseudo created", r.state.live.count, 1)
        guard let p = r.state.live.first else { return }
        t.equal("pseudo slot", p.key.slot, SlotKey.pseudoSlot)
        t.equal("pseudo prefilling", p.phase, .prefilling)
        t.equal("pseudo startedAt = request time", p.startedAt, t0.addingTimeInterval(0.05))
        t.equal("pseudo messageCount", p.messageCount, 5)
        t.equal("pseudo endpoint", p.endpoint, "/v1/chat/completions")
        t.equal("exact cached from restore", p.prompt.cachedTokens, 3584)
        t.equal("cached exact flag", p.prompt.cachedIsEstimate, false)
        t.equal("processed from restore", p.prompt.processedTokens, 540)
        t.equal("total from restore", p.prompt.totalTokens, 4124)
        t.equal("context limit from catalog", p.contextLimit, 65536)
        t.equal("engine type", p.engineType, "mlx")

        r.apply(sv(.prefillProgress(model: mlx, percent: 54.6), t0.addingTimeInterval(5.2)))
        t.near("server progress", r.state.live.first?.progress, 0.546, tol: 1e-9)
        t.near("progress rate", r.state.live.first?.progressRatePerSec, 0.546 / 5.0, tol: 1e-6)
        t.check("ETA available", (r.state.live.first?.prefillEtaSec ?? -1) > 0)
        r.apply(sv(.prefillProgress(model: mlx, percent: 100.0), t0.addingTimeInterval(9)))
        t.equal("100% → generating", r.state.live.first?.phase, .generating)
        t.equal("generationStartedAt", r.state.live.first?.generationStartedAt, t0.addingTimeInterval(9))
        r.apply(sv(.streamingStarted(model: mlx), t0.addingTimeInterval(9.1)))
        t.equal("streamed", r.state.live.first?.streamed, true)
        r.apply(sv(.streamingFinished(model: mlx), t0.addingTimeInterval(20)))
        t.equal("finishing", r.state.live.first?.phase, .finishing)
        t.equal("no record yet", records.count, 0)
        r.apply(st(stats(model: mlx, stop: "eosFound", tps: 20.0, ttft: 8.8, total: 23.8, prompt: 4124, predicted: 300), t0.addingTimeInterval(20.01)))
        t.equal("one record", records.count, 1)
        guard let rec = records.first else { return }
        t.equal("record slot nil", rec.slot, nil)
        t.equal("record instance nil", rec.instance, nil)
        t.equal("cached exact", rec.prompt.cachedTokens, 3584)
        t.equal("cached flag", rec.prompt.cachedIsEstimate, false)
        t.equal("processed", rec.prompt.processedTokens, 540)
        t.equal("total", rec.prompt.totalTokens, 4124)
        t.equal("messageCount", rec.messageCount, 5)
        t.equal("endpoint", rec.endpoint, "/v1/chat/completions")
        t.equal("phase", rec.phase, .finished)
        t.equal("engine", rec.engineType, "mlx")
        t.equal("context at end = S2 total", rec.contextTokensAtEnd, 4424)
        t.equal("context limit", rec.contextLimit, 65536)
        t.near("prefill tps = processed / ttft", rec.prefillTokensPerSecond, 540 / 8.8, tol: 1e-9)
        t.equal("sources", Set(rec.sources), Set([.server, .model]))
        t.equal("finishedAt = streaming finished", rec.finishedAt, t0.addingTimeInterval(20))
        t.equal("live cleared", r.state.live.count, 0)

        // Back-to-back: a new 0% while the previous pseudo is still generating finishes the old one.
        r.apply(sv(.prefillProgress(model: mlx, percent: 0.0), t0.addingTimeInterval(30)))
        r.apply(sv(.prefillProgress(model: mlx, percent: 100.0), t0.addingTimeInterval(30.5)))
        r.apply(sv(.prefillProgress(model: mlx, percent: 0.0), t0.addingTimeInterval(40)))
        t.equal("old pseudo finishing, new prefilling", r.state.live.map { $0.phase }, [.finishing, .prefilling])
        r.tick(now: t0.addingTimeInterval(44))
        t.equal("old pseudo recorded", records.count, 2)
        t.equal("new pseudo remains", r.state.live.count, 1)
    }

    // MARK: - Suite: grace, housekeeping, streams

    static func graceAndHousekeeping(_ t: TestContext) {
        t.suite("Reducer · housekeeping")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792006000000)

        // Stream status events.
        r.apply(LMEvent(at: t0, source: .runtime, kind: .stream(.runtime, .running(since: t0))))
        r.apply(LMEvent(at: t0, source: .server, kind: .stream(.server, .backoff(seconds: 4))))
        t.equal("stream status stored", r.state.streams[.runtime], .running(since: t0))
        r.apply(LMEvent(at: t0, source: .server, kind: .stream(.server, .droppedOversizedLine(bytes: 2_000_000))))
        t.equal("dropped counted", r.state.droppedLines, 1)
        t.equal("dropped keeps status", r.state.streams[.server], .backoff(seconds: 4))

        // Stale live prediction (no update for 10 min) → cancelled.
        launch(r, slot: 0, task: 1, at: t0, uptime: "50.00.000")
        gen(r, slot: 0, task: 1, n: 5, tg: 5, tg3s: 5, at: t0.addingTimeInterval(1), uptime: "50.01.000.000")
        r.tick(now: t0.addingTimeInterval(500))
        t.equal("not stale yet", r.state.live.count, 1)
        t.equal("instance present", r.state.instances.count, 1)
        r.tick(now: t0.addingTimeInterval(601.5))
        t.equal("stale → cancelled record", records.last?.phase, .cancelled)
        t.equal("stale cleared", r.state.live.count, 0)
        // The instance was last seen at t0+1, so the same tick prunes it (10 min unseen).
        t.equal("instance pruned", r.state.instances.count, 0)

        // Pid change on the same instance key resets slots.
        r.apply(rt(.slotReleased(slot: 1, task: 3, nTokens: 300, truncated: false), "60.00.000.000 I slot      release: id  1 | task 3 | stop processing: n_tokens = 300, truncated = 0", t0.addingTimeInterval(1300)))
        var ctx2 = ctx; ctx2.pid = 7001
        r.apply(rt(.other(level: "I", text: "srv main: hello"), "0.00.100.000 I srv main: hello", t0.addingTimeInterval(1301), ctx: ctx2))
        t.equal("slots reset on pid change", r.state.instances[instance]?.slotLastNTokens.isEmpty, true)
        t.equal("pid updated", r.state.instances[instance]?.pid, 7001)

        // modelLoading clears slots too; modelInitialized sets context limit on live predictions.
        launch(r, slot: 0, task: 20, at: t0.addingTimeInterval(1400), uptime: "70.00.000")
        r.apply(rt(.modelInitialized(nSlots: 4, nCtxSlot: 71168, kvUnified: true), "0.34.630.517 I srv    load_model: initializing, n_slots = 4, n_ctx_slot = 71168, kv_unified = 'true'", t0.addingTimeInterval(1401)))
        t.equal("ctx limit backfilled", liveFor(r, task: 20)?.contextLimit, 71168)
        t.equal("nCtxSlot stored", r.state.instances[instance]?.nCtxSlot, 71168)

        // S2 before the runtime final block: record waits briefly, then release finalizes it with both sources.
        r.apply(st(stats(stop: "eosFound", tps: 11, ttft: 0.4, total: 3.0, prompt: 50, predicted: 30), t0.addingTimeInterval(1403)))
        t.equal("S2 first → still live (waiting for runtime)", r.state.live.count, 1)
        _ = finalBlock(r, slot: 0, task: 20, at: t0.addingTimeInterval(1403.2), promptMs: 400, promptTokens: 50, promptTps: 125,
                       evalMs: 2600, evalTokens: 30, evalTps: 11.5, release: 80, uptime: "70.03.200")
        t.equal("release finalizes merged record", r.state.live.count, 0)
        t.equal("merged prefill tps from runtime", records.last?.prefillTokenRate, 125)
        t.near("merged tps from S2", records.last?.tokensPerSecond, 11, tol: 1e-9)
        t.equal("merged context from release", records.last?.contextTokensAtEnd, 80)
        t.check("merged sources", Set(records.last?.sources ?? []).isSuperset(of: [.runtime, .model]))

        // S2 before runtime, runtime never arrives → tick finalizes after the short grace.
        launch(r, slot: 1, task: 21, at: t0.addingTimeInterval(1500), uptime: "80.00.000")
        r.apply(st(stats(stop: "eosFound", tps: 9, ttft: 0.4, total: 2.0, prompt: 40, predicted: 15), t0.addingTimeInterval(1502)))
        r.tick(now: t0.addingTimeInterval(1503))
        t.equal("short grace not yet expired", r.state.live.count, 1)
        r.tick(now: t0.addingTimeInterval(1503.6))
        t.equal("short grace expired", r.state.live.count, 0)
        t.equal("record generated from S2", records.last?.generatedTokens, 15)

        // Truncated release → record flags truncated & context-length stop reason.
        launch(r, slot: 2, task: 22, at: t0.addingTimeInterval(1600), uptime: "90.00.000")
        _ = finalBlock(r, slot: 2, task: 22, at: t0.addingTimeInterval(1605), promptMs: 100, promptTokens: 10, promptTps: 100,
                       evalMs: 4000, evalTokens: 40, evalTps: 10, release: 71168, truncated: true, uptime: "90.05.000")
        r.tick(now: t0.addingTimeInterval(1609))
        t.equal("truncated flag", records.last?.truncated, true)
        t.equal("truncated stop reason", records.last?.stopReason, .contextLengthReached)

        // resetLive clears everything live but keeps models/streams.
        r.apply(models: [ModelInfo(id: model, format: "gguf", isLoaded: true)], serverReachable: true, port: 1234, lmStudioRunning: true, lmsPath: "/x")
        launch(r, slot: 0, task: 30, at: t0.addingTimeInterval(1700), uptime: "95.00.000")
        r.resetLive()
        t.equal("reset clears live", r.state.live.count, 0)
        t.equal("reset clears instances", r.state.instances.count, 0)
        t.equal("reset keeps models", r.state.models.count, 1)
        t.equal("reset keeps streams", r.state.streams.count, 2)
        t.equal("reset clears counters", r.state.dedupedLines + r.state.droppedLines, 0)
        t.equal("reset clears debug", r.debugLines.count, 0)
    }

    // MARK: - Suite: context-less engine lines (server copies while runtime stream is down)

    static func contextlessServerCopies(_ t: TestContext) {
        t.suite("Reducer · context-less engine lines")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792007000000)
        // Runtime seen once (instance known), then only server copies arrive (no EngineContext).
        gen(r, slot: 3, task: 133, n: 100, tg: 13, tg3s: 13, at: t0, uptime: "46.26.021.689")
        r.apply(sv(.chatStarted(model: model, messageCount: 2), t0.addingTimeInterval(1)))
        r.apply(rt(.taskLaunched(slot: 2, task: 500, isChild: false), "46.27.000.000 I slot launch_slot_: id  2 | task 500 | processing task, is_child = 0", t0.addingTimeInterval(1.1), source: .server))
        let live = liveFor(r, task: 500)
        t.equal("attributed to known instance", live?.key.instance, instance)
        t.equal("model from instance", live?.model, model)
        t.equal("request attached", live?.messageCount, 2)
        t.equal("engine type inherited", live?.engineType, "llama.cpp")
        r.apply(rt(.eval(slot: 2, task: 500, ms: 1000, tokens: 10, tps: 10), "46.28.000.000 I slot print_timing: id  2 | task 500 |        eval time =    1000.00 ms /    10 tokens (  100.00 ms per token,    10.00 tokens per second)", t0.addingTimeInterval(2), source: .server))
        r.apply(rt(.slotReleased(slot: 2, task: 500, nTokens: 40, truncated: false), "46.28.000.100 I slot      release: id  2 | task 500 | stop processing: n_tokens = 40, truncated = 0", t0.addingTimeInterval(2.001), source: .server))
        r.tick(now: t0.addingTimeInterval(6))
        t.equal("record from server copies", records.count, 1)
        t.equal("record instance", records.first?.instance, instance)
        t.equal("record sources", records.first?.sources, [.server])
        t.equal("instance slot size", r.state.instances[instance]?.slotLastNTokens[2], 40)

        // Server progress for a gguf model arriving before its launch line is held, not turned into a pseudo slot.
        r.apply(sv(.prefillProgress(model: model, percent: 0.0), t0.addingTimeInterval(10)))
        t.equal("no pseudo for llama.cpp model", r.state.live.filter { $0.key.slot == SlotKey.pseudoSlot }.count, 0)
        launch(r, slot: 1, task: 501, at: t0.addingTimeInterval(10.3), uptime: "46.40.000")
        t.near("held progress applied at launch", liveFor(r, task: 501)?.serverProgress, 0, tol: 1e-9)
        t.equal("one live for that model", r.state.live.filter { $0.task == 501 }.count, 1)

        // Pseudo slot created before the launch line (no instance known) is absorbed by the real slot.
        let r2 = LMStateReducer()
        r2.apply(sv(.chatStarted(model: model, messageCount: 9), t0))
        r2.apply(sv(.prefillProgress(model: model, percent: 12.0), t0.addingTimeInterval(0.2)))
        t.equal("pseudo created when nothing known", r2.state.live.first?.key.slot, SlotKey.pseudoSlot)
        launch(r2, slot: 0, task: 600, at: t0.addingTimeInterval(0.5), uptime: "1.00.000")
        t.equal("pseudo absorbed", r2.state.live.count, 1)
        t.equal("absorbed task", r2.state.live.first?.task, 600)
        t.equal("absorbed messageCount", r2.state.live.first?.messageCount, 9)
        t.near("absorbed progress", r2.state.live.first?.serverProgress, 0.12, tol: 1e-9)
        t.equal("absorbed startedAt = request time", r2.state.live.first?.startedAt, t0)
    }

    // MARK: - Suite: server-level end signals must not touch runtime slots

    /// Regression (found by the integration replay): after the short request on slot 2 was
    /// finalized by model stats, the server's "Finished streaming" / "Generated prediction" /
    /// "Client disconnected" lines for the same model must not end the long mid-flight task on
    /// slot 3. Runtime eval/release lines and S2 stats are authoritative for slot-keyed predictions.
    static func serverEndSignalsVsRuntimeSlots(_ t: TestContext) {
        t.suite("Reducer · server end signals vs runtime slots")
        let r = LMStateReducer()
        var records: [PredictionRecord] = []
        r.onRecord = { records.append($0) }
        let t0 = T(1792001972040)
        gen(r, slot: 3, task: 133, n: 27343, tg: 13.30, tg3s: 16.33, at: t0, uptime: "46.26.021.689")

        r.apply(sv(.chatStarted(model: model, messageCount: 1), t0.addingTimeInterval(1.094)))
        launch(r, slot: 2, task: 10325, at: t0.addingTimeInterval(1.131))
        r.apply(sv(.prefillProgress(model: model, percent: 0.0), t0.addingTimeInterval(1.163)))
        r.apply(sv(.prefillProgress(model: model, percent: 100.0), t0.addingTimeInterval(2.794)))
        gen(r, slot: 3, task: 133, n: 27375, tg: 13.30, tg3s: 10.40, at: t0.addingTimeInterval(3.078), uptime: "46.29.099.244")
        let tEnd = t0.addingTimeInterval(4.689)
        _ = finalBlock(r, slot: 2, task: 10325, at: tEnd, promptMs: 1631.73, promptTokens: 63, promptTps: 38.61,
                       evalMs: 1895.66, evalTokens: 24, evalTps: 12.13, release: 86, draft: (16, 18, 3.67))
        r.apply(st(stats(stop: "maxPredictedTokensReached", tps: 12.133003034305803, ttft: 1.631729, total: 3.527385,
                         prompt: 63, predicted: 24, draftTotal: 18, draftAccepted: 16), tEnd.addingTimeInterval(0.003)))
        t.equal("short request recorded", records.count, 1)
        t.equal("record is task 10325", records.first?.task, 10325)

        // Server end signals for the model arrive after the record exists.
        r.apply(sv(.streamingFinished(model: model), tEnd.addingTimeInterval(0.005)))
        r.apply(sv(.generatedPrediction(model: model), tEnd.addingTimeInterval(0.005)))
        t.equal("slot 3 still live", r.state.live.count, 1)
        t.equal("slot 3 still generating", liveFor(r, task: 133)?.phase, .generating)
        r.tick(now: tEnd.addingTimeInterval(5))
        t.equal("slot 3 survives the grace window", r.state.live.count, 1)
        t.equal("no second record", records.count, 1)

        r.apply(sv(.clientDisconnected, tEnd.addingTimeInterval(6)))
        t.equal("client disconnect ignores runtime slot", liveFor(r, task: 133)?.phase, .generating)
        r.apply(sv(.predictError(model: model, message: "boom"), tEnd.addingTimeInterval(7)))
        t.equal("predict error attaches text", liveFor(r, task: 133)?.error, "boom")
        t.equal("predict error keeps runtime slot generating", liveFor(r, task: 133)?.phase, .generating)
        r.tick(now: tEnd.addingTimeInterval(12))
        t.equal("still one record after more server noise", records.count, 1)
        gen(r, slot: 3, task: 133, n: 27421, tg: 13.30, tg3s: 15.29, at: tEnd.addingTimeInterval(13), uptime: "46.32.108.312")
        t.equal("slot 3 keeps updating", liveFor(r, task: 133)?.generatedTokens, 27421)

        // S2 arriving while BOTH slots are still generating must pick the short request, not the
        // long mid-flight task (start-time proximity from totalTimeSec decides).
        let r2 = LMStateReducer()
        var recs2: [PredictionRecord] = []
        r2.onRecord = { recs2.append($0) }
        gen(r2, slot: 3, task: 133, n: 27343, tg: 13.30, tg3s: 16.33, at: t0, uptime: "46.26.021.689")
        launch(r2, slot: 2, task: 10325, at: t0.addingTimeInterval(1.131))
        r2.apply(sv(.prefillProgress(model: model, percent: 100.0), t0.addingTimeInterval(2.794)))
        r2.apply(st(stats(stop: "maxPredictedTokensReached", tps: 12.13, ttft: 1.63, total: 3.527, prompt: 63, predicted: 24), t0.addingTimeInterval(4.66)))
        t.equal("S2 merged into the short slot (awaiting runtime)", liveFor(r2, task: 10325)?.phase, .finishing)
        t.equal("long slot untouched by S2", liveFor(r2, task: 133)?.phase, .generating)
        r2.tick(now: t0.addingTimeInterval(6.5))
        t.equal("short slot recorded after short grace", recs2.map { $0.task }, [10325])
        t.equal("long slot still live", r2.state.live.map { $0.task }, [133])
    }

    // MARK: - Suite: AlertEngine

    static func alertEngine(_ t: TestContext) {
        t.suite("AlertEngine")
        let t0 = T(1792008000000)
        let a = AlertEngine()
        let idle = LMState()

        // gpuOOM: raise, coalesce, count, clear after 10 min of silence.
        let oom = "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"
        a.note(rt(.gpuOOM(message: oom), "0.34.020.760 E error: \(oom)", t0))
        a.note(rt(.gpuOOM(message: oom), "0.34.020.760 E error: \(oom)", t0, source: .server))       // duplicate line
        a.note(rt(.gpuOOM(message: oom), "0.34.020.900 E error: \(oom)", t0.addingTimeInterval(0.1)))
        a.note(rt(.gpuOOM(message: oom), "0.34.035.000 E error: \(oom)", t0.addingTimeInterval(15)))
        a.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0.addingTimeInterval(16))
        t.check("gpuOOM active", a.isActive(.gpuOOM))
        let oomAlert = a.active.first { $0.rule == .gpuOOM }
        t.equal("gpuOOM count (dups ignored)", oomAlert?.count, 3)
        t.equal("gpuOOM severity", oomAlert?.severity, .critical)
        t.equal("gpuOOM title", oomAlert?.title, "GPU ran out of memory")
        t.check("gpuOOM detail has count and bursts", oomAlert?.detail.contains("3× (2 bursts)") ?? false, oomAlert?.detail ?? "")
        t.check("gpuOOM detail actionable", oomAlert?.detail.contains("Parallel") ?? false)
        t.equal("gpuOOM lastSeen = event time", oomAlert?.lastSeen, t0.addingTimeInterval(15))
        a.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0.addingTimeInterval(15 + 599))
        t.check("gpuOOM still active at 9:59", a.isActive(.gpuOOM))
        a.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: t0.addingTimeInterval(15 + 600))
        t.check("gpuOOM cleared after 10 min", !a.isActive(.gpuOOM))
        t.check("cleared alert still listed", a.alerts.contains { $0.rule == .gpuOOM && !$0.active })
        // A stale event (older than the window relative to the last evaluate) is ignored.
        a.note(rt(.gpuOOM(message: oom), "0.10.000.000 E error: \(oom)", t0.addingTimeInterval(-700)))
        t.check("stale event ignored", !a.isActive(.gpuOOM))

        // Other event-driven rules.
        let now1 = t0.addingTimeInterval(700)
        a.note(rt(.decodeFailed(message: "Compute error."), "3.53.818.956 E srv  update_slots: decode() failed: Compute error.", now1))
        a.note(rt(.kvCacheFull, "5.00.000.000 W srv decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 2048, ret = 1", now1))
        a.note(rt(.slotReleased(slot: 1, task: 9, nTokens: 71168, truncated: true), "6.00.000.000 I slot      release: id  1 | task 9 | stop processing: n_tokens = 71168, truncated = 1", now1))
        a.note(sv(.modelLoadFailed(model: "big-model", reason: "insufficient system resources"), now1))
        a.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(1))
        t.check("computeError active", a.isActive(.computeError))
        t.check("kvCacheFull active", a.isActive(.kvCacheFull))
        t.check("contextTruncated active", a.isActive(.contextTruncated))
        t.check("modelLoadFailed active", a.isActive(.modelLoadFailed))
        t.equal("modelLoadFailed keyed by model", a.active.first { $0.rule == .modelLoadFailed }?.key, "big-model")
        t.check("sorted severity desc", a.active.first?.severity == .critical && a.active.last?.severity != .critical)
        a.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(301))
        t.check("computeError cleared after 5 min", !a.isActive(.computeError))
        t.check("kvCacheFull cleared after 5 min", !a.isActive(.kvCacheFull))
        t.check("contextTruncated still active (10 min)", a.isActive(.contextTruncated))
        t.check("modelLoadFailed still active (10 min)", a.isActive(.modelLoadFailed))
        // stopReason contextLengthReached also raises contextTruncated.
        let b = AlertEngine()
        b.note(st(ModelStatsEvent(modelIdentifier: model, stopReasonRaw: "contextLengthReached", tokensPerSecond: 10, timeToFirstTokenSec: 1, totalTimeSec: 10, promptTokensCount: 100, predictedTokensCount: 50, totalTokensCount: 150, totalDraftTokensCount: nil, acceptedDraftTokensCount: nil, rejectedDraftTokensCount: nil, outputCharCount: 10), now1))
        t.check("truncated from stop reason", b.isActive(.contextTruncated))

        // memoryPressure from the system snapshot.
        let c = AlertEngine()
        var sys = SystemSnapshot()
        sys.memPressure = .warn
        sys.memUsedBytes = 30 << 30; sys.swapUsedBytes = 2_750_000_000
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1)
        t.check("pressure warn → warning", c.active.first { $0.rule == .memoryPressure }?.severity == .warning)
        t.check("swapInUse info", c.active.first { $0.rule == .swapInUse }?.severity == .info)
        t.check("newlyRaised has pressure", c.drainNewlyRaised().contains { $0.rule == .memoryPressure })
        sys.memPressure = .critical
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(1))
        t.check("pressure critical → critical", c.active.first { $0.rule == .memoryPressure }?.severity == .critical)
        t.check("escalation re-notifies", c.drainNewlyRaised().contains { $0.rule == .memoryPressure })
        sys.memPressure = .normal
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(2))
        t.check("pressure normal → cleared", !c.isActive(.memoryPressure))
        sys.swapUsedBytes = 500 << 20
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(3))
        t.check("swapInUse cleared", !c.isActive(.swapInUse))

        // gpuMemoryAtBudget hysteresis.
        sys.gpuBudgetBytes = 28_991_029_248; sys.gpuInUseBytes = 27_700_000_000
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(4))
        t.check("gpu at budget", c.isActive(.gpuMemoryAtBudget))
        sys.gpuInUseBytes = 27_000_000_000   // 93%: between clear and raise → stays
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(5))
        t.check("gpu budget hysteresis holds", c.isActive(.gpuMemoryAtBudget))
        sys.gpuInUseBytes = 25_000_000_000
        c.evaluate(state: idle, system: sys, series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(6))
        t.check("gpu budget cleared below 90%", !c.isActive(.gpuMemoryAtBudget))

        // swapGrowing from the series while a prediction is live; clears after 2 min flat.
        let d = AlertEngine()
        var liveState = LMState()
        var lp = LivePrediction(key: SlotKey(instance: instance, slot: 0), task: 1, model: model, engineType: "llama.cpp",
                                phase: .generating, startedAt: now1.addingTimeInterval(-100), lastUpdate: now1)
        lp.generatedTokens = 500
        liveState.live = [lp]
        var series = SeriesSet()
        let gib = 1_073_741_824.0
        series.swapUsed.add(1.0 * gib, at: now1.addingTimeInterval(-70))
        series.swapUsed.add(1.1 * gib, at: now1.addingTimeInterval(-30))
        series.swapUsed.add(1.4 * gib, at: now1)
        d.evaluate(state: liveState, system: SystemSnapshot(), series: series, aggregates: [], fit: nil, now: now1)
        t.check("swapGrowing active", d.isActive(.swapGrowing))
        t.check("swapGrowing detail has delta", d.active.first { $0.rule == .swapGrowing }?.detail.contains("Swap grew by") ?? false)
        d.evaluate(state: idle, system: SystemSnapshot(), series: series, aggregates: [], fit: nil, now: now1.addingTimeInterval(1))
        t.check("swapGrowing needs a live prediction to re-trigger but stays active", d.isActive(.swapGrowing))
        for s in stride(from: 10.0, through: 125.0, by: 5) { series.swapUsed.add(1.4 * gib, at: now1.addingTimeInterval(s)) }
        d.evaluate(state: liveState, system: SystemSnapshot(), series: series, aggregates: [], fit: nil, now: now1.addingTimeInterval(119))
        t.check("swapGrowing still active before 2 min flat", d.isActive(.swapGrowing))
        d.evaluate(state: liveState, system: SystemSnapshot(), series: series, aggregates: [], fit: nil, now: now1.addingTimeInterval(121))
        t.check("swapGrowing cleared after 2 min flat", !d.isActive(.swapGrowing))

        // contextNearlyFull hysteresis (warn 0.85 default, clear < 0.80).
        let e = AlertEngine()
        var ctxState = LMState()
        var cp = LivePrediction(key: SlotKey(instance: instance, slot: 2), task: 5, model: model, engineType: "llama.cpp",
                                phase: .generating, startedAt: now1, lastUpdate: now1)
        cp.contextLimit = 100_000
        cp.prompt.totalTokens = 90_000
        cp.generatedTokens = 0
        ctxState.live = [cp]
        e.evaluate(state: ctxState, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1)
        t.check("context 90% → active", e.isActive(.contextNearlyFull))
        t.check("context detail has numbers", e.active.first { $0.rule == .contextNearlyFull }?.detail.contains("\(Fmt.int(90_000)) of \(Fmt.int(100_000))") ?? false,
                e.active.first { $0.rule == .contextNearlyFull }?.detail ?? "")
        ctxState.live[0].prompt.totalTokens = 82_000
        e.evaluate(state: ctxState, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(1))
        t.check("context 82% stays active (hysteresis)", e.isActive(.contextNearlyFull))
        ctxState.live[0].prompt.totalTokens = 70_000
        e.evaluate(state: ctxState, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(2))
        t.check("context 70% → cleared", !e.isActive(.contextNearlyFull))
        ctxState.live[0].prompt.totalTokens = 86_000
        e.evaluate(state: ctxState, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(3))
        t.check("context re-raised", e.isActive(.contextNearlyFull))
        ctxState.live = []
        e.evaluate(state: ctxState, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(4))
        t.check("context cleared when prediction ends", !e.isActive(.contextNearlyFull))

        // acknowledgeAll hides until a new occurrence.
        let f = AlertEngine()
        f.note(rt(.gpuOOM(message: oom), "7.00.000.000 E error: \(oom)", now1))
        f.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1)
        t.equal("ack: active before", f.active.count, 1)
        f.acknowledgeAll()
        t.equal("ack: hidden", f.active.count, 0)
        t.check("ack: isActive still true", f.isActive(.gpuOOM))
        f.note(rt(.gpuOOM(message: oom), "7.00.000.001 E error: \(oom)", now1.addingTimeInterval(1)))
        t.equal("ack: new occurrence un-hides", f.active.count, 1)

        // fit verdict → modelFitTight / modelWillSwap.
        let g = AlertEngine()
        g.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [],
                   fit: MemoryFitVerdict(level: .tight, measuredBytes: nil, estimatedBytes: nil, budgetBytes: nil, isEstimate: false, detail: "d"), now: now1)
        t.check("fit tight → modelFitTight", g.isActive(.modelFitTight) && !g.isActive(.modelWillSwap))
        g.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [],
                   fit: MemoryFitVerdict(level: .willSwap, measuredBytes: nil, estimatedBytes: nil, budgetBytes: nil, isEstimate: false, detail: "d"), now: now1.addingTimeInterval(1))
        t.check("fit willSwap → modelWillSwap", g.isActive(.modelWillSwap) && !g.isActive(.modelFitTight))
        g.evaluate(state: idle, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(2))
        t.check("fit nil → cleared", !g.isActive(.modelWillSwap))

        // Connectivity rules need the condition to hold for a while.
        let h = AlertEngine()
        var conn = LMState()
        conn.lmStudioRunning = false
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1)
        t.check("lmStudioNotRunning not immediate", !h.isActive(.lmStudioNotRunning))
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(6))
        t.check("lmStudioNotRunning after 5 s", h.isActive(.lmStudioNotRunning))
        conn.lmStudioRunning = true; conn.serverReachable = false; conn.lmsPath = "/x"
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(7))
        t.check("lmStudioNotRunning cleared", !h.isActive(.lmStudioNotRunning))
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(28))
        t.check("serverNotRunning after 20 s", h.isActive(.serverNotRunning))
        conn.streams[.runtime] = .backoff(seconds: 30)
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(29))
        t.check("logStreamDown not immediate", !h.isActive(.logStreamDown))
        conn.streams[.runtime] = .starting
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(90))
        t.check("logStreamDown after 60 s of restart cycle", h.isActive(.logStreamDown))
        conn.streams[.runtime] = .running(since: now1.addingTimeInterval(91))
        h.evaluate(state: conn, system: SystemSnapshot(), series: SeriesSet(), aggregates: [], fit: nil, now: now1.addingTimeInterval(91))
        t.check("logStreamDown cleared when running", !h.isActive(.logStreamDown))
    }

    // MARK: - Suite: MemoryFit

    static func memoryFit(_ t: TestContext) {
        t.suite("MemoryFit")
        let gib: UInt64 = 1_073_741_824
        var sys = SystemSnapshot()
        sys.gpuBudgetBytes = 27 * gib
        sys.memPressure = .normal
        sys.swapUsedBytes = 2_750_000_000
        var loaded = ModelInfo(id: model, format: "gguf", architecture: "qwen35", sizeBytes: UInt64(16.52 * Double(gib)),
                               maxContextLength: 262144, loadedContextLength: 35840, isLoaded: true)
        func verdict(_ footprint: UInt64, oom: Bool = false, swap: Bool = false, pressure: MemoryPressure = .normal) -> MemoryFitVerdict {
            var s = sys
            s.memPressure = pressure
            s.engine = ProcessFootprint(name: "llama-server", pids: [6932], physFootprintBytes: footprint, cpuPercent: nil)
            return MemoryFit.evaluate(model: loaded, instance: nil, contextFit: nil, system: s, recentGPUOOM: oom, swapGrowing: swap)
        }
        t.equal("20/27 fits", verdict(20 * gib).level, .fits)
        t.equal("24/27 tight", verdict(24 * gib).level, .tight)
        t.equal("28/27 willSwap", verdict(28 * gib).level, .willSwap)
        t.equal("pressure warn → tight", verdict(20 * gib, pressure: .warn).level, .tight)
        t.equal("pressure critical → willSwap", verdict(20 * gib, pressure: .critical).level, .willSwap)
        t.equal("recent OOM → willSwap", verdict(20 * gib, oom: true).level, .willSwap)
        t.equal("swap growing → willSwap", verdict(20 * gib, swap: true).level, .willSwap)
        let v = verdict(UInt64(23.3 * Double(gib)), pressure: .warn)
        t.equal("measured not estimate", v.isEstimate, false)
        t.equal("measured bytes", v.measuredBytes, UInt64(23.3 * Double(gib)))
        t.equal("budget bytes", v.budgetBytes, 27 * gib)
        t.equal("detail", v.detail, "23.3 GB used of 27.0 GB GPU budget · swap 2.6 GB · pressure warn")

        // Not loaded: estimate = size × 1.08 + ctx × kv (family match).
        let fit = ContextFitInfo(family: "qwen3_5", maxContext: 262144, fitted: 55040, workingSetBytes: 27 * gib, reserveBytes: 3 * gib,
                                 safeCeilingBytes: 24 * gib, baselineBytes: UInt64(14.95 * Double(gib)), fullKVBytesPerToken: 65536,
                                 promptInputBytesPerToken: 10240, attentionBytesPerToken: 98304, estimatedPeakBytes: UInt64(24.02 * Double(gib)))
        loaded.isLoaded = false
        loaded.loadedContextLength = nil
        loaded.architecture = "qwen35"
        t.equal("kv per token with family match", MemoryFit.kvBytesPerToken(for: loaded, contextFit: fit), 65536)
        var other = loaded; other.architecture = "llama"
        t.equal("kv per token without match", MemoryFit.kvBytesPerToken(for: other, contextFit: fit), nil)
        let e1 = MemoryFit.evaluate(model: loaded, instance: nil, contextFit: fit, system: sys, recentGPUOOM: false, swapGrowing: false)
        let expected = UInt64(Double(loaded.sizeBytes!) * 1.08) + UInt64(65536) * 55040
        t.equal("estimate bytes", e1.estimatedBytes, expected)
        t.equal("estimate flagged", e1.isEstimate, true)
        t.equal("estimate fits in empty budget", e1.level, .fits)
        t.check("estimate detail", e1.detail.hasPrefix("≈21.") && e1.detail.contains("KV 3.4 GB at \(Fmt.int(55040)) ctx") && e1.detail.contains("27.0 GB GPU budget"), e1.detail)
        var busy = sys
        busy.engine = ProcessFootprint(name: "llama-server", pids: [1], physFootprintBytes: 20 * gib, cpuPercent: nil)
        let e2 = MemoryFit.evaluate(model: loaded, instance: nil, contextFit: fit, system: busy, recentGPUOOM: false, swapGrowing: false)
        t.equal("estimate vs remaining budget → willSwap", e2.level, .willSwap)
        let e3 = MemoryFit.evaluate(model: other, instance: nil, contextFit: fit, system: sys, recentGPUOOM: false, swapGrowing: false)
        t.check("weights-only estimate", e3.detail.contains("weights only"), e3.detail)
        t.equal("weights-only bytes", e3.estimatedBytes, UInt64(Double(loaded.sizeBytes!) * 1.08))
        var noBudget = sys; noBudget.gpuBudgetBytes = nil
        t.equal("unknown without budget", MemoryFit.evaluate(model: loaded, instance: nil, contextFit: fit, system: noBudget, recentGPUOOM: false, swapGrowing: false).level, .unknown)
        var noSize = loaded; noSize.sizeBytes = nil
        t.equal("unknown without size", MemoryFit.evaluate(model: noSize, instance: nil, contextFit: fit, system: sys, recentGPUOOM: false, swapGrowing: false).level, .unknown)
    }

    // MARK: - Suite: Aggregates

    static func aggregates(_ t: TestContext) {
        t.suite("Aggregates")
        let t0 = T(1792009000000)
        func rec(_ m: String, tps: Double?, gen: Int, phase: PredictionPhase = .finished, prefill: Double? = nil, ttft: Double? = nil, prompt: Int? = nil) -> PredictionRecord {
            var pb = PromptBreakdown(); pb.totalTokens = prompt
            return PredictionRecord(id: UUID(), model: m, instance: nil, slot: nil, task: nil, engineType: nil, startedAt: t0, finishedAt: t0,
                                    phase: phase, stopReason: .eosFound, stopReasonRaw: nil, tokensPerSecond: tps, prefillTokensPerSecond: prefill,
                                    timeToFirstToken: ttft, generationTime: nil, totalTime: nil, prompt: pb, generatedTokens: gen,
                                    contextTokensAtEnd: nil, contextLimit: nil, truncated: false, draft: nil, messageCount: nil, endpoint: nil,
                                    error: nil, sources: [.runtime])
        }
        let records = [
            rec("Qwen/Qwen3.8-27B", tps: 10, gen: 100, prefill: 100, ttft: 1.0, prompt: 500),
            rec("qwen/qwen3.8-27b", tps: 20, gen: 100, prefill: 300, ttft: 3.0, prompt: 500),
            rec("qwen/qwen3.8-27b", tps: 30, gen: 100),
            rec("qwen/qwen3.8-27b", tps: 40, gen: 100),
            rec("qwen/qwen3.8-27b", tps: 1000, gen: 100),
            rec("qwen/qwen3.8-27b", tps: 5000, gen: 5),                       // too short: excluded from rates
            rec("qwen/qwen3.8-27b", tps: 0.1, gen: 300, phase: .errored),     // errored: excluded from rates
            rec("qwen/qwen3.8-27b", tps: nil, gen: 50, phase: .cancelled),
            rec("other@4bit", tps: 7, gen: 40),
            rec("other", tps: 9, gen: 40),
        ]
        let agg = Aggregates.compute(records)
        t.equal("groups", agg.count, 2)
        t.equal("sorted by count desc", agg.first?.id, "qwen/qwen3.8-27b")
        t.equal("count includes everything", agg.first?.count, 8)
        t.near("median excludes short/errored", agg.first?.medianTps, 30, tol: 1e-9)
        t.near("avg", agg.first?.avgTps, 220, tol: 1e-9)
        t.near("p10", agg.first?.p10Tps, 10, tol: 1e-9)
        t.near("avg prefill", agg.first?.avgPrefillTps, 200, tol: 1e-9)
        t.near("avg ttft", agg.first?.avgTTFT, 2.0, tol: 1e-9)
        t.equal("errors", agg.first?.errors, 1)
        t.equal("total generated", agg.first?.totalGenerated, 100 * 5 + 5 + 300 + 50)
        t.equal("total prompt", agg.first?.totalPrompt, 1000)
        t.equal("variant suffix normalized", agg.last?.id, "other")
        t.near("even-count median", agg.last?.medianTps, 8, tol: 1e-9)
        t.equal("empty input", Aggregates.compute([]).count, 0)
    }
}

private extension PredictionRecord {
    var prefillTokenRate: Double? { prefillTokensPerSecond }
}
