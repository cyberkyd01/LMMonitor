import Foundation

/// Health/alert rules (design §5) with hysteresis and automatic clearing.
///
/// Not thread-safe: owned by `MetricsStore`, called on the main actor only.
/// Call order: `note(_:)` for every incoming event (duplicates are tolerated: engine lines are
/// deduped here too), `evaluate(...)` on every publish tick (≈ 2 Hz), `drainNewlyRaised()`
/// after `evaluate` for notifications. Event-driven rules time out relative to the event's
/// own timestamp, so late or replayed events never pin an alert open.
final class AlertEngine {
    /// Every known alert: active ones plus recently cleared ones (pruned after 30 min).
    private(set) var alerts: [Alert] = []

    /// Active and not acknowledged, sorted by severity (desc) then lastSeen (desc).
    var active: [Alert] {
        alerts.filter { $0.active && !isAcknowledged($0) }
            .sorted { a, b in a.severity != b.severity ? a.severity > b.severity : a.lastSeen > b.lastSeen }
    }

    // MARK: Windows

    static let oomClear: TimeInterval = 600
    static let oomBurstWindow: TimeInterval = 10
    static let loadFailedClear: TimeInterval = 600
    static let computeErrorClear: TimeInterval = 300
    static let kvCacheFullClear: TimeInterval = 300
    static let truncatedClear: TimeInterval = 600
    static let swapGrowthBytes: Double = 256 * 1_048_576
    static let swapGrowthFlat: TimeInterval = 120
    static let swapInUseRaise: Double = 1_073_741_824
    static let swapInUseClear: Double = 0.9 * 1_073_741_824
    static let gpuBudgetRaise = 0.95
    static let gpuBudgetClear = 0.90
    static let slowFor: TimeInterval = 15
    static let serverDownFor: TimeInterval = 20
    static let lmStudioDownFor: TimeInterval = 5
    static let lmsMissingFor: TimeInterval = 10
    static let streamDownFor: TimeInterval = 60
    static let prunedAfter: TimeInterval = 1800

    // MARK: Private state

    private struct Meta {
        var clearAfter: TimeInterval?     // event-driven: clear when now − lastSeen ≥ clearAfter
        var ackCount: Int?                // count at acknowledge time; hidden while unchanged
        var incidents = 0                 // gpuOOM bursts
    }
    private var meta: [String: Meta] = [:]
    private var newlyRaised: [Alert] = []
    private let recent = RecentLineSet(capacity: 512)
    private var lastNow: Date?
    private var conditionSince: [AlertRule: Date] = [:]
    private var swapLastGrowth: Date?
    private var streamDownSince: [EventSource: Date] = [:]
    /// Numbers from the last `evaluate`, used to make event-driven texts concrete.
    private var hintContext: Int?
    private var hintParallel: Int?
    private var hintModel: String?

    // MARK: - Event-driven rules

    func note(_ event: LMEvent) {
        let at = event.at
        switch event.kind {
        case let .engine(line, _, raw):
            guard recent.insert(raw) else { return }   // server copy of a runtime line
            switch line {
            case let .gpuOOM(message):
                noteGPUOOM(message, at: at)
            case let .decodeFailed(message):
                guard fresh(at, within: Self.computeErrorClear) else { return }
                raise(.computeError, severity: .critical, title: "Generation failed with a compute error",
                      detail: "llama.cpp reported “\(message.trimmingCharacters(in: .whitespacesAndNewlines))”. The request was aborted; this usually follows a GPU out-of-memory error. Lower the context length\(contextHint) or Parallel\(parallelHint) and retry.",
                      at: at, clearAfter: Self.computeErrorClear, countEvent: true)
            case .kvCacheFull:
                guard fresh(at, within: Self.kvCacheFullClear) else { return }
                raise(.kvCacheFull, severity: .warning, title: "KV cache is full",
                      detail: "llama.cpp could not find free space in the KV cache and is retrying with smaller batches. Generation slows down; lower the context length\(contextHint) or Parallel\(parallelHint).",
                      at: at, clearAfter: Self.kvCacheFullClear, countEvent: true)
            case let .slotReleased(slot, _, nTokens, truncated) where truncated:
                guard fresh(at, within: Self.truncatedClear) else { return }
                raise(.contextTruncated, severity: .warning, title: "Context was truncated",
                      detail: "Slot \(slot) hit the context limit\(contextHint) at \(Fmt.int(nTokens)) tokens and older tokens were dropped. The reply may have lost earlier context; raise the context length or shorten the conversation.",
                      at: at, clearAfter: Self.truncatedClear, countEvent: true)
            default:
                break
            }

        case let .server(line):
            switch line {
            case let .modelLoadFailed(model, reason):
                guard fresh(at, within: Self.loadFailedClear) else { return }
                raise(.modelLoadFailed, key: model, severity: .critical, title: "Model failed to load",
                      detail: "“\(model)” could not be loaded: \(Self.trim(reason)). Unload another model or lower the context length before retrying.",
                      at: at, clearAfter: Self.loadFailedClear, countEvent: true)
            case let .predictError(model, message):
                guard fresh(at, within: Self.computeErrorClear) else { return }
                let lower = message.lowercased()
                if lower.contains("context overflow") || lower.contains("context length") {
                    // The "stop at limit" overflow policy ending a request is a context problem, not an engine fault.
                    guard fresh(at, within: Self.truncatedClear) else { return }
                    raise(.contextTruncated, severity: .warning, title: "Context limit reached",
                          detail: "\(model ?? "The model") hit its context length\(contextHint) and LM Studio stopped the request (\(Self.trim(message))). Raise the context length, shorten the conversation, or change the context overflow policy.",
                          at: at, clearAfter: Self.truncatedClear, countEvent: true)
                    return
                }
                if lower.contains("model unloaded") || lower.contains("terminated") || lower.contains("aborted") {
                    return   // user-initiated: unloading or stopping during a request
                }
                raise(.computeError, severity: .critical, title: "Generation failed",
                      detail: "LM Studio reported an engine error\(model.map { " for \($0)" } ?? ""): \(Self.trim(message)). The request was aborted; check memory pressure and retry.",
                      at: at, clearAfter: Self.computeErrorClear, countEvent: true)
            default:
                break
            }

        case let .modelStats(stats):
            if stats.stopReasonRaw == StopReason.contextLengthReached.rawValue, fresh(at, within: Self.truncatedClear) {
                raise(.contextTruncated, severity: .warning, title: "Context was truncated",
                      detail: "\(stats.modelIdentifier) stopped because the context length\(contextHint) was reached after \(Fmt.int(stats.totalTokensCount)) tokens. Raise the context length or shorten the conversation.",
                      at: at, clearAfter: Self.truncatedClear, countEvent: true)
            }

        case .proxy, .stream:
            break
        }
    }

    private func noteGPUOOM(_ message: String, at: Date) {
        guard fresh(at, within: Self.oomClear) else { return }
        let id = Alert(rule: .gpuOOM, key: nil, severity: .critical, title: "", detail: "", firstSeen: at, lastSeen: at, count: 0, active: true).id
        var m = meta[id] ?? Meta()
        let existing = alerts.first(where: { $0.id == id })
        let sameBurst = existing.map { $0.active && at.timeIntervalSince($0.lastSeen) < Self.oomBurstWindow } ?? false
        if !sameBurst { m.incidents += 1 }
        if existing?.active != true { m.incidents = 1 }
        meta[id] = m
        let count = (existing?.active == true ? existing!.count : 0) + 1
        let since = existing?.active == true ? existing!.firstSeen : at
        let bursts = m.incidents
        raise(.gpuOOM, severity: .critical, title: "GPU ran out of memory",
              detail: "Metal reported Insufficient Memory \(count)× (\(bursts) burst\(bursts == 1 ? "" : "s")) since \(Fmt.shortTime.string(from: since)). Lower the context length\(contextHint), reduce Parallel\(parallelHint), or use a smaller quant.",
              at: at, clearAfter: Self.oomClear, countEvent: true)
    }

    /// Events older than their own clear window (relative to the last evaluate) are ignored:
    /// they would be cleared on the very next tick and would only produce a stale notification.
    private func fresh(_ at: Date, within window: TimeInterval) -> Bool {
        guard let now = lastNow else { return true }
        return now.timeIntervalSince(at) < window
    }

    // MARK: - Continuous rules

    func evaluate(state: LMState, system: SystemSnapshot, series: SeriesSet, aggregates: [ModelAggregate], fit: MemoryFitVerdict?, now: Date) {
        lastNow = now
        let primary = state.primaryModel
        hintModel = primary?.id
        hintParallel = primary?.parallel
        hintContext = state.instances.values.compactMap { $0.nCtxSlot }.max() ?? primary?.loadedContextLength

        // Event-driven rules time out.
        for i in alerts.indices where alerts[i].active {
            if let c = meta[alerts[i].id]?.clearAfter, now.timeIntervalSince(alerts[i].lastSeen) >= c {
                alerts[i].active = false
            }
        }

        let liveAny = state.live.contains { !$0.isChild && $0.phase.isLive }

        evaluateMemoryPressure(system, now: now)
        evaluateSwap(system, series: series, liveAny: liveAny, now: now)
        evaluateGPUBudget(system, now: now)
        evaluateThermal(system, now: now)
        evaluatePower(system, liveAny: liveAny, now: now)
        evaluateContext(state, now: now)
        evaluateRunaway(state, now: now)
        evaluateSlow(state, aggregates: aggregates, now: now)
        evaluateConnectivity(state, now: now)
        evaluateStreams(state, now: now)
        evaluateFit(fit, model: primary, now: now)

        alerts.removeAll { !$0.active && now.timeIntervalSince($0.lastSeen) > Self.prunedAfter }
        for id in meta.keys where !alerts.contains(where: { $0.id == id }) { meta.removeValue(forKey: id) }
    }

    private func evaluateMemoryPressure(_ s: SystemSnapshot, now: Date) {
        let used = Fmt.gib(s.memUsedBytes), total = Fmt.gib(s.memTotalBytes), swap = Fmt.gib(s.swapUsedBytes)
        switch s.memPressure {
        case .critical:
            raise(.memoryPressure, severity: .critical, title: "Memory pressure is critical",
                  detail: "macOS reports critical memory pressure: \(used) of \(total) RAM in use, swap \(swap). Generation will stall; unload a model, close other apps, or use a smaller model or context length.",
                  at: now)
        case .warn:
            raise(.memoryPressure, severity: .warning, title: "Memory pressure is high",
                  detail: "macOS reports memory pressure WARN: \(used) of \(total) RAM in use, swap \(swap). Close other apps, or use a smaller model or context length.",
                  at: now)
        case .normal, .unknown:
            clear(.memoryPressure)
        }
    }

    private func evaluateSwap(_ s: SystemSnapshot, series: SeriesSet, liveAny: Bool, now: Date) {
        if let swap = s.swapUsedBytes {
            let v = Double(swap)
            if v >= Self.swapInUseRaise {
                raise(.swapInUse, severity: .info, title: "Swap in use",
                      detail: "\(Fmt.gib(swap)) of swap is in use\(s.swapTotalBytes.map { " (of \(Fmt.gib($0)))" } ?? ""). That is fine while it stays flat; growth during generation means the model does not fit in memory.",
                      at: now)
            } else if v < Self.swapInUseClear {
                clear(.swapInUse)
            }
        }

        let current = series.swapUsed.lastValue ?? s.swapUsedBytes.map { Double($0) }
        let before = series.swapUsed.value(secondsAgo: 60, now: now)
        var growing = false
        var delta: Double = 0
        if liveAny, let c = current, let b = before, c - b >= Self.swapGrowthBytes {
            growing = true
            delta = c - b
        }
        if growing {
            swapLastGrowth = now
            raise(.swapGrowing, severity: .warning, title: "Swap is growing during generation",
                  detail: "Swap grew by \(Fmt.gib(UInt64(delta))) in the last minute (now \(Fmt.gib(current.map { UInt64($0) }))). The model no longer fits in memory and tokens will slow down sharply. Use a smaller context length, quant or model.",
                  at: now)
        } else if isActive(.swapGrowing), let last = swapLastGrowth, now.timeIntervalSince(last) >= Self.swapGrowthFlat {
            clear(.swapGrowing)
        }
    }

    private func evaluateGPUBudget(_ s: SystemSnapshot, now: Date) {
        guard let use = s.gpuInUseBytes, let budget = s.gpuBudgetBytes, budget > 0 else { return }
        let f = Double(use) / Double(budget)
        if f >= Self.gpuBudgetRaise {
            raise(.gpuMemoryAtBudget, severity: .warning, title: "GPU memory at its limit",
                  detail: "\(Fmt.gib(use)) of the \(Fmt.gib(budget)) GPU working-set budget is in use (\(Fmt.pct(f * 100))). Loading another model or growing the context will cause out-of-memory errors.",
                  at: now)
        } else if f < Self.gpuBudgetClear {
            clear(.gpuMemoryAtBudget)
        }
    }

    private func evaluateThermal(_ s: SystemSnapshot, now: Date) {
        switch s.thermal {
        case .critical:
            raise(.thermal, severity: .critical, title: "Mac is thermally throttled",
                  detail: "macOS thermal state is critical. Token speed will drop until the Mac cools down; improve airflow or pause heavy work.", at: now)
        case .serious:
            raise(.thermal, severity: .warning, title: "Mac is running hot",
                  detail: "macOS thermal state is serious. Expect lower token speed until the Mac cools down.", at: now)
        default:
            clear(.thermal)
        }
    }

    private func evaluatePower(_ s: SystemSnapshot, liveAny: Bool, now: Date) {
        if s.lowPowerMode {
            if liveAny {
                raise(.lowPowerMode, severity: .info, title: "Low Power Mode is on",
                      detail: "Generation runs slower in Low Power Mode. Turn it off in System Settings → Battery for full speed.", at: now)
            }
        } else {
            clear(.lowPowerMode)
        }
        if s.onBattery == true {
            if liveAny {
                raise(.onBattery, severity: .info, title: "Running on battery",
                      detail: "Generation is slower on battery power\(s.batteryPercent.map { " (\($0)% left)" } ?? ""). Plug in for full speed.", at: now)
            }
        } else if s.onBattery == false {
            clear(.onBattery)
        }
    }

    private func evaluateContext(_ state: LMState, now: Date) {
        let warn = Settings.contextWarnFraction
        let clearBelow = min(0.80, warn - 0.05)
        var keep = Set<String>()
        for p in state.live where !p.isChild && p.phase.isLive {
            guard let f = p.contextFraction, let used = p.contextTokensEstimate, let limit = p.contextLimit else { continue }
            let key = Self.slotKeyString(p)
            let id = AlertRule.contextNearlyFull.rawValue + "|" + key
            let wasActive = alerts.first(where: { $0.id == id })?.active ?? false
            if f >= warn || (wasActive && f >= clearBelow) {
                raise(.contextNearlyFull, key: key, severity: .warning, title: "Context nearly full",
                      detail: "\(Self.slotLabel(p)) of \(p.model) is using \(Fmt.int(used)) of \(Fmt.int(limit)) context tokens (\(Fmt.pct(f * 100))). Older messages will be truncated soon — start a new chat or raise the context length.",
                      at: now)
                keep.insert(id)
            }
        }
        for a in alerts where a.rule == .contextNearlyFull && a.active && !keep.contains(a.id) { clear(a.rule, key: a.key) }
    }

    private func evaluateRunaway(_ state: LMState, now: Date) {
        let maxTokens = Settings.runawayTokens
        let maxMinutes = Settings.runawayMinutes
        var keep = Set<String>()
        for p in state.live where !p.isChild && p.phase == .generating {
            let elapsed = now.timeIntervalSince(p.generationStartedAt ?? p.startedAt)
            let tokens = p.generatedTokens ?? 0
            guard tokens >= maxTokens || elapsed >= Double(maxMinutes) * 60 else { continue }
            let key = Self.slotKeyString(p)
            raise(.runawayGeneration, key: key, severity: .warning, title: "Runaway generation",
                  detail: "\(p.model) has produced \(Fmt.tokens(tokens)) tokens over \(Fmt.duration(max(0, elapsed))) on \(Self.slotLabel(p).lowercased()) (limits: \(Fmt.tokens(maxTokens)) tokens / \(maxMinutes) min). Stop it in LM Studio if this is not intentional.",
                  at: now)
            keep.insert(AlertRule.runawayGeneration.rawValue + "|" + key)
        }
        for a in alerts where a.rule == .runawayGeneration && a.active && !keep.contains(a.id) { clear(a.rule, key: a.key) }
    }

    private func evaluateSlow(_ state: LMState, aggregates: [ModelAggregate], now: Date) {
        let gen = state.generating
        var slow: (LivePrediction, Double, Double)?
        if gen.count == 1, let p = gen.first, let n = p.generatedTokens, n >= 50, let tg = p.tg3s,
           let agg = aggregates.first(where: { $0.id == ModelKey.norm(p.model) }), agg.count >= 5,
           let median = agg.medianTps, median > 0, tg < 0.5 * median {
            slow = (p, tg, median)
        }
        guard let (p, tg, median) = slow else {
            conditionSince[.slowGeneration] = nil
            clear(.slowGeneration)
            return
        }
        let since = conditionSince[.slowGeneration] ?? now
        conditionSince[.slowGeneration] = since
        guard now.timeIntervalSince(since) >= Self.slowFor else { return }
        raise(.slowGeneration, severity: .info, title: "Generation slower than usual",
              detail: "\(p.model) is producing \(Fmt.tps(tg)) versus its usual median of \(Fmt.tps(median)). Check memory pressure, thermal state and other GPU load.",
              at: now)
    }

    private func evaluateConnectivity(_ state: LMState, now: Date) {
        held(.lmStudioNotRunning, condition: !state.lmStudioRunning, for: Self.lmStudioDownFor, now: now) {
            raise(.lmStudioNotRunning, severity: .info, title: "LM Studio is not running",
                  detail: "No LM Studio process was found. Open LM Studio to start monitoring.", at: now)
        }
        held(.serverNotRunning, condition: state.lmStudioRunning && !state.serverReachable, for: Self.serverDownFor, now: now) {
            raise(.serverNotRunning, severity: .info, title: "LM Studio server is not running",
                  detail: "LM Studio is open but nothing answers on port \(state.serverPort). Start the server in LM Studio → Developer, or use “Start server” in the model card.", at: now)
        }
        let lmsMissing = state.degradedReason != nil || (state.lmsPath == nil && state.lmStudioRunning)
        held(.lmsMissing, condition: lmsMissing, for: Self.lmsMissingFor, now: now) {
            raise(.lmsMissing, severity: .warning, title: "lms command not found",
                  detail: "The lms command-line tool is needed to stream LM Studio logs. Run “~/.lmstudio/bin/lms bootstrap” in Terminal or enable it in LM Studio → Developer, or set its path in Settings. Until then only the server log file is read, so live engine details are missing.", at: now)
        }
    }

    private func evaluateStreams(_ state: LMState, now: Date) {
        var down: [String] = []
        var longest: TimeInterval = 0
        for source in [EventSource.runtime, .model, .server] {
            switch state.streams[source] {
            case .backoff?, .exited?:
                if streamDownSince[source] == nil { streamDownSince[source] = now }
            case .starting?:
                break   // still part of the restart cycle
            default:
                streamDownSince[source] = nil
            }
            if state.lmStudioRunning, let since = streamDownSince[source], now.timeIntervalSince(since) >= Self.streamDownFor {
                down.append(source.rawValue)
                longest = max(longest, now.timeIntervalSince(since))
            }
        }
        if down.isEmpty {
            clear(.logStreamDown)
        } else {
            raise(.logStreamDown, severity: .warning, title: down.count == 1 ? "Log stream down" : "Log streams down",
                  detail: "The \(down.joined(separator: ", ")) log stream\(down.count == 1 ? " keeps" : "s keep") restarting (down for \(Fmt.duration(longest))). Live stats may be missing; check that LM Studio is running and that “lms log stream” works in Terminal.",
                  at: now)
        }
    }

    private func evaluateFit(_ fit: MemoryFitVerdict?, model: ModelInfo?, now: Date) {
        let name = model?.displayName ?? model?.id ?? "The model"
        switch fit?.level {
        case .tight?:
            clear(.modelWillSwap)
            raise(.modelFitTight, severity: .warning, title: "Model barely fits in GPU memory",
                  detail: "\(name): \(fit!.detail). Avoid loading a second model or raising the context length.", at: now)
        case .willSwap?:
            clear(.modelFitTight)
            raise(.modelWillSwap, severity: .critical, title: "Model does not fit in GPU memory",
                  detail: "\(name): \(fit!.detail). Expect swapping and very slow tokens; use a smaller context length, quant or model.", at: now)
        default:
            clear(.modelFitTight)
            clear(.modelWillSwap)
        }
    }

    /// Raise only after `condition` has held for `duration`; clear as soon as it is false.
    private func held(_ rule: AlertRule, condition: Bool, for duration: TimeInterval, now: Date, raise: () -> Void) {
        guard condition else {
            conditionSince[rule] = nil
            clear(rule)
            return
        }
        let since = conditionSince[rule] ?? now
        conditionSince[rule] = since
        if now.timeIntervalSince(since) >= duration { raise() }
    }

    // MARK: - Queries & actions

    func isActive(_ rule: AlertRule) -> Bool {
        alerts.contains { $0.rule == rule && $0.active }
    }

    /// Hides the currently active alerts until they re-trigger with a new occurrence
    /// (a new event for event-driven rules, or a clear-and-raise cycle for continuous ones).
    func acknowledgeAll() {
        for a in alerts where a.active {
            var m = meta[a.id] ?? Meta()
            m.ackCount = a.count
            meta[a.id] = m
        }
    }

    /// Alerts that became active (or escalated in severity) since the last drain.
    func drainNewlyRaised() -> [Alert] {
        let out = newlyRaised
        newlyRaised.removeAll()
        return out
    }

    // MARK: - Core mutation

    private func raise(_ rule: AlertRule, key: String? = nil, severity: AlertSeverity, title: String, detail: String,
                       at: Date, clearAfter: TimeInterval? = nil, countEvent: Bool = false) {
        let id = rule.rawValue + "|" + (key ?? "")
        var m = meta[id] ?? Meta()
        m.clearAfter = clearAfter
        meta[id] = m
        if let i = alerts.firstIndex(where: { $0.id == id }) {
            var a = alerts[i]
            let wasActive = a.active
            let escalated = wasActive && severity > a.severity
            if !wasActive {
                a.active = true
                a.firstSeen = at
                a.count += 1              // a new activation is a new occurrence (voids an ack)
            } else if countEvent || escalated {
                a.count += 1
            }
            a.severity = severity
            a.title = title
            a.detail = detail
            a.lastSeen = max(a.lastSeen, at)
            alerts[i] = a
            if !wasActive || escalated { newlyRaised.append(a) }
        } else {
            let a = Alert(rule: rule, key: key, severity: severity, title: title, detail: detail,
                          firstSeen: at, lastSeen: at, count: 1, active: true)
            alerts.append(a)
            newlyRaised.append(a)
        }
    }

    private func clear(_ rule: AlertRule, key: String? = nil) {
        let id = rule.rawValue + "|" + (key ?? "")
        guard let i = alerts.firstIndex(where: { $0.id == id }), alerts[i].active else { return }
        alerts[i].active = false
    }

    private func isAcknowledged(_ a: Alert) -> Bool {
        meta[a.id]?.ackCount == a.count
    }

    private var contextHint: String {
        hintContext.map { " (currently \(Fmt.int($0)))" } ?? ""
    }
    private var parallelHint: String {
        hintParallel.map { " (currently \($0))" } ?? ""
    }

    private static func slotKeyString(_ p: LivePrediction) -> String {
        p.key.slot == SlotKey.pseudoSlot ? ModelKey.norm(p.model) : "\(p.key.instance)#\(p.key.slot)"
    }
    private static func slotLabel(_ p: LivePrediction) -> String {
        p.key.slot == SlotKey.pseudoSlot ? "The prediction" : "Slot \(p.key.slot)"
    }
    private static func trim(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        if t.count > 200 { t = String(t.prefix(200)) + "…" }
        return t
    }
}
