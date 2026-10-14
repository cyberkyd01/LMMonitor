import Foundation

/// Slot / prediction state machine (design §2.3–§2.6, §10.3).
///
/// Not thread-safe: owned by `MetricsStore` and called on the main actor only (and
/// synchronously from the self-test). Every timestamp comes from `LMEvent.at` or from the
/// `now` handed to `tick(now:)`; `Date()` is never consulted while applying events, so a
/// replayed log produces identical state.
///
/// Call order expected by the store: `apply(_:)` for every event in arrival order (all
/// sources interleaved), `tick(now:)` every publish tick (≈ 2 Hz), `apply(models:…)` after
/// each poll. `onTransition` fires at most once per call when something user-visible
/// changed (new live prediction, phase change, record). `onRecord` fires for each record.
final class LMStateReducer {
    private(set) var state: LMState
    /// ≤ 50 lines, newest last: "HH:mm:ss [source] text". Deduped engine lines plus notable
    /// server/model lines; high-volume noise ("Returning …", request bodies) is skipped.
    private(set) var debugLines: [String] = []
    var onRecord: ((PredictionRecord) -> Void)?
    var onTransition: (() -> Void)?

    // MARK: Tunables

    static let finishingGrace: TimeInterval = 3          // wait for S2 after runtime says done
    static let s2MergeGrace: TimeInterval = 1.5          // wait for runtime final block after S2
    static let staleLiveAfter: TimeInterval = 600
    static let stalledAfter: TimeInterval = 10
    static let instancePruneAfter: TimeInterval = 600
    static let pendingReuseTTL: TimeInterval = 5
    /// §2.3 says ≤ 10 s, but with every slot busy llama.cpp queues the task and `launch_slot_`
    /// can trail "Running chat completion" by a minute; FIFO + the per-model cap keep it bounded.
    static let pendingRequestTTL: TimeInterval = 60
    static let pendingEndpointTTL: TimeInterval = 2
    static let pendingProgressTTL: TimeInterval = 2
    static let pendingCacheRestoreTTL: TimeInterval = 5
    static let pendingProxyTTL: TimeInterval = 5
    static let proxyMatchWindow: TimeInterval = 5
    static let streamsDeadAfter: TimeInterval = 60
    static let debugCapacity = 50
    static let pendingRequestsPerModelCap = 16
    static let pendingProxyCap = 32

    // MARK: Private bookkeeping

    private struct PendingRequest {
        var at: Date
        var model: String
        var messageCount: Int
        var endpoint: String?
    }

    /// Per-live-prediction data that the UI does not need (kept out of `LivePrediction`).
    private struct Aux {
        var sources: Set<EventSource> = []
        var stats: ModelStatsEvent? = nil
        var outcome: PredictionPhase? = nil       // .cancelled when cancel / disconnect seen
        var userStopped = false
        var awaitingRuntimeFinal = false          // S2 merged before the runtime final block
    }

    private struct RecentRecord {
        var model: String
        var finishedAt: Date
        var generated: Int?
    }

    private var aux: [UUID: Aux] = [:]
    private var pendingReuse: [SlotKey: (reuse: PrefixReuse, at: Date)] = [:]
    private var pendingRequests: [String: [PendingRequest]] = [:]
    private var pendingEndpoint: (path: String, at: Date)?
    private var pendingServerProgress: [String: (fraction: Double, at: Date)] = [:]
    private var pendingCacheRestore: (info: PromptCacheRestore, at: Date)?
    private var pendingProxy: [ProxyRequestEvent] = []
    private var recentRecords: [RecentRecord] = []
    private var lastStreamRecordAt: Date?
    private let recent = RecentLineSet(capacity: 512)
    private var transitioned = false
    /// Latest timestamp seen (events or ticks); used only where no event time is available.
    private var clock: Date = .distantPast

    init(state: LMState = LMState()) {
        self.state = state
    }

    // MARK: - Public entry points

    func apply(_ event: LMEvent) {
        if event.at > clock { clock = event.at }
        transitioned = false
        switch event.kind {
        case let .engine(line, ctx, raw):
            applyEngine(line, ctx: ctx, raw: raw, at: event.at, source: event.source)
        case let .server(line):
            applyServer(line, at: event.at, source: event.source)
        case let .modelStats(stats):
            applyModelStats(stats, at: event.at, source: event.source)
        case let .proxy(req):
            applyProxy(req, at: event.at)
        case let .stream(source, status):
            if case let .droppedOversizedLine(bytes) = status {
                state.droppedLines += 1
                debug(at: event.at, source: source, "dropped oversized line (\(bytes) bytes)")
            } else {
                state.streams[source] = status
                if source == .logfile {
                    if case .running = status { state.degradedReason = "lms not found — tailing server log file" }
                    else if case .notStarted = status { state.degradedReason = nil }
                }
                debug(at: event.at, source: source, "stream \(describe(status))")
            }
        }
        if transitioned { onTransition?() }
    }

    func apply(models: [ModelInfo], serverReachable: Bool, port: Int, lmStudioRunning: Bool, lmsPath: String?) {
        transitioned = false
        let wasRunning = state.lmStudioRunning
        state.models = models
        state.serverReachable = serverReachable
        state.serverPort = port
        state.lmStudioRunning = lmStudioRunning
        state.lmsPath = lmsPath
        let now = clock == .distantPast ? Date() : clock
        if wasRunning && !lmStudioRunning {
            // LM Studio quit: every engine process is gone, nothing live can complete.
            for live in state.live { finalize(id: live.id, as: .cancelled, at: now) }
            state.instances.removeAll()
            clearPendings()
        }
        // Unload/reload of a single model is handled by `modelUnloadedTTL`, `modelLoading`, pid
        // changes and the 10-min prune; the REST catalog is deliberately not used to drop
        // instances (a custom --identifier could make its ids differ from runtime identifiers).
        // Backfill context limits / engine type that only the REST catalog knows.
        for i in state.live.indices {
            if state.live[i].contextLimit == nil {
                state.live[i].contextLimit = contextLimit(instance: state.live[i].key.instance, model: state.live[i].model)
            }
            if state.live[i].engineType == nil {
                state.live[i].engineType = engineType(forModel: state.live[i].model)
            }
        }
        if transitioned { onTransition?() }
    }

    /// Finalizes finishing predictions past their grace, expires pending queues, prunes
    /// instances unseen for 10 min and cancels live predictions with no update for 10 min.
    func tick(now: Date) {
        if now > clock { clock = now }
        transitioned = false

        for live in state.live {
            let a = aux[live.id] ?? Aux()
            let idle = now.timeIntervalSince(live.lastUpdate)
            if live.phase == .finishing {
                let grace = a.awaitingRuntimeFinal ? Self.s2MergeGrace : Self.finishingGrace
                if idle >= grace { finalize(id: live.id, as: nil, at: now) }
            } else if live.phase.isLive && idle >= Self.staleLiveAfter {
                finalize(id: live.id, as: .cancelled, at: now)
            }
        }
        // llama.cpp prints a progress line every ~3 s per generating slot; if none arrived for
        // 10 s the generation is stalled (swap, OOM retry…) — show 0 t/s, not the last rate.
        for i in state.live.indices where state.live[i].phase == .generating && state.live[i].key.slot >= 0
            && state.live[i].tg3s != nil && state.live[i].tg3s != 0
            && now.timeIntervalSince(state.live[i].lastUpdate) >= Self.stalledAfter {
            state.live[i].tg3s = 0
        }

        for (key, value) in pendingReuse where now.timeIntervalSince(value.at) > Self.pendingReuseTTL {
            pendingReuse.removeValue(forKey: key)
        }
        for (model, list) in pendingRequests {
            let kept = list.filter { now.timeIntervalSince($0.at) <= Self.pendingRequestTTL }
            if kept.isEmpty { pendingRequests.removeValue(forKey: model) } else { pendingRequests[model] = kept }
        }
        if let pe = pendingEndpoint, now.timeIntervalSince(pe.at) > Self.pendingEndpointTTL { pendingEndpoint = nil }
        for (model, value) in pendingServerProgress where now.timeIntervalSince(value.at) > Self.pendingProgressTTL {
            pendingServerProgress.removeValue(forKey: model)
        }
        if let pc = pendingCacheRestore, now.timeIntervalSince(pc.at) > Self.pendingCacheRestoreTTL { pendingCacheRestore = nil }
        expireProxy(now: now)
        recentRecords.removeAll { now.timeIntervalSince($0.finishedAt) > 60 }

        for inst in state.instances.values where now.timeIntervalSince(inst.lastSeen) >= Self.instancePruneAfter {
            removeInstance(inst.id, at: now)
        }
        if transitioned { onTransition?() }
    }

    /// Clears live state (predictions, instances, pendings, counters, debug ring). Models,
    /// stream statuses and connectivity flags are kept.
    func resetLive() {
        state.live.removeAll()
        state.instances.removeAll()
        state.lastRecord = nil
        state.lastContextFit = nil
        state.lastCacheRestore = nil
        state.promptCacheDisk = nil
        state.dedupedLines = 0
        state.droppedLines = 0
        aux.removeAll()
        clearPendings()
        recentRecords.removeAll()
        lastStreamRecordAt = nil
        debugLines.removeAll()
        onTransition?()
    }

    // MARK: - Engine lines

    private func applyEngine(_ line: EngineLine, ctx: EngineContext, raw: String, at: Date, source: EventSource) {
        guard recent.insert(raw) else {
            state.dedupedLines += 1
            return
        }
        debug(at: at, source: source, raw)

        let instanceKey = resolveInstanceKey(ctx: ctx, line: line)
        if instanceKey != Self.defaultInstance, state.instances[Self.defaultInstance] != nil {
            adoptDefaultInstance(into: instanceKey, ctx: ctx, at: at)
        }
        touchInstance(instanceKey, ctx: ctx, at: at)

        switch line {
        case let .slotSelected(slot, reuse):
            pendingReuse[SlotKey(instance: instanceKey, slot: slot)] = (reuse, at)

        case let .taskLaunched(slot, task, isChild):
            launch(instance: instanceKey, slot: slot, task: task, isChild: isChild, ctx: ctx, at: at, source: source)

        case let .prefillProgress(slot, task, nTokens, progress, elapsed, tps):
            let idx = liveIndex(instance: instanceKey, slot: slot, task: task)
                ?? createMidFlight(instance: instanceKey, slot: slot, task: task, phase: .prefilling,
                                   startedAt: at.addingTimeInterval(-max(0, elapsed)), ctx: ctx, at: at)
            update(idx, at: at, source: source) { p in
                p.prefillProcessedTokens = nTokens
                p.prefillProgress = min(1, max(0, progress))
                p.prefillTps = tps
                p.prefillElapsedSec = elapsed
                if p.phase == .queued { p.phase = .prefilling; self.transitioned = true }
            }

        case let .genProgress(slot, task, nGen, tgAvg, tg3s):
            let estimate: TimeInterval = tgAvg > 0 ? Double(nGen) / tgAvg : 0
            let idx = liveIndex(instance: instanceKey, slot: slot, task: task)
                ?? createMidFlight(instance: instanceKey, slot: slot, task: task, phase: .generating,
                                   startedAt: at.addingTimeInterval(-estimate), ctx: ctx, at: at)
            update(idx, at: at, source: source) { p in
                if p.phase == .prefilling || p.phase == .queued {
                    p.phase = .generating
                    p.generationStartedAt = at
                    p.prefillProgress = 1
                    self.transitioned = true
                }
                p.generatedTokens = nGen
                p.tgAverage = tgAvg
                p.tg3s = tg3s
            }

        case let .promptEval(slot, task, ms, tokens, tps):
            guard let idx = liveIndex(instance: instanceKey, slot: slot, task: task) else { return }
            update(idx, at: at, source: source) { p in
                p.final.promptEvalMs = ms
                p.final.promptEvalTokens = tokens
                p.final.promptEvalTps = tps
                p.prompt.processedTokens = tokens
                if p.prompt.totalTokens == nil, let c = p.prompt.cachedTokens { p.prompt.totalTokens = c + tokens }
                self.markFinishing(&p, at: at)
            }

        case let .eval(slot, task, ms, tokens, tps):
            guard let idx = liveIndex(instance: instanceKey, slot: slot, task: task) else { return }
            update(idx, at: at, source: source) { p in
                p.final.evalMs = ms
                p.final.evalTokens = tokens
                p.final.evalTps = tps
                p.generatedTokens = tokens
                self.markFinishing(&p, at: at)
            }

        case let .totalTime(slot, task, ms, tokens):
            guard let idx = liveIndex(instance: instanceKey, slot: slot, task: task) else { return }
            update(idx, at: at, source: source) { p in
                p.final.totalMs = ms
                p.final.totalTokens = tokens
            }

        case let .draftAcceptance(slot, task, _, accepted, generated, meanLen):
            guard let idx = liveIndex(instance: instanceKey, slot: slot, task: task) else { return }
            update(idx, at: at, source: source) { p in
                p.final.draft = DraftStats(accepted: accepted, generated: generated, meanLength: meanLen)
            }

        case let .slotReleased(slot, task, nTokens, truncated):
            state.instances[instanceKey]?.slotLastNTokens[slot] = nTokens
            guard let idx = liveIndex(instance: instanceKey, slot: slot, task: task) else { return }
            let id = state.live[idx].id
            update(idx, at: at, source: source) { p in
                p.final.releaseNTokens = nTokens
                p.final.truncated = truncated
                self.markFinishing(&p, at: at)
            }
            if aux[id]?.awaitingRuntimeFinal == true {
                // S2 already merged; the release is the last runtime line for this task.
                finalize(id: id, as: nil, at: at)
            }

        case let .taskCancelled(task):
            guard let idx = state.live.firstIndex(where: { $0.key.instance == instanceKey && $0.task == task && $0.phase.isLive }) else { return }
            let id = state.live[idx].id
            var a = aux[id] ?? Aux()
            a.sources.insert(source)
            if a.outcome == nil { a.outcome = .cancelled }
            aux[id] = a
            update(idx, at: at, source: source) { p in self.markFinishing(&p, at: at) }

        case let .decodeFailed(message):
            attachError(message, at: at, source: source) { $0.key.instance == instanceKey }

        case let .gpuOOM(message):
            attachError(message, at: at, source: source) { $0.key.instance == instanceKey }

        case .kvCacheFull:
            break   // alert only (AlertEngine.note)

        case let .modelLoading(path):
            state.instances[instanceKey]?.modelPath = path
            state.instances[instanceKey]?.slotLastNTokens = [:]
            // A (re)load on this instance means nothing that was live can finish.
            for live in state.live where live.key.instance == instanceKey && live.phase != .finishing {
                finalize(id: live.id, as: .cancelled, at: at)
            }

        case let .modelInitialized(nSlots, nCtxSlot, kvUnified):
            state.instances[instanceKey]?.nSlots = nSlots
            state.instances[instanceKey]?.nCtxSlot = nCtxSlot
            state.instances[instanceKey]?.kvUnified = kvUnified
            for i in state.live.indices where state.live[i].key.instance == instanceKey {
                state.live[i].contextLimit = nCtxSlot
            }

        case .other:
            break
        }
    }

    private func launch(instance: String, slot: Int, task: Int, isChild: Bool, ctx: EngineContext, at: Date, source: EventSource) {
        let key = SlotKey(instance: instance, slot: slot)

        // A slot that still has a non-finishing prediction missed its release line.
        for live in state.live where live.key == key && live.phase != .finishing && live.phase.isLive {
            finalize(id: live.id, as: .cancelled, at: at)
        }

        var model = ctx.modelIdentifier ?? state.instances[instance]?.model ?? ""
        var p = LivePrediction(key: key, task: task, model: model, engineType: ctx.engineType ?? state.instances[instance]?.engineType,
                               phase: .prefilling, startedAt: at, lastUpdate: at)
        p.isChild = isChild
        var a = Aux()
        a.sources.insert(source)

        if let pr = pendingReuse.removeValue(forKey: key), at.timeIntervalSince(pr.at) <= Self.pendingReuseTTL {
            p.reuse = pr.reuse
            switch pr.reuse {
            case let .lcp(_, fKeep):
                if let last = state.instances[instance]?.slotLastNTokens[slot], last > 0 {
                    p.prompt.cachedTokens = Int((fKeep * Double(last)).rounded())
                    p.prompt.cachedIsEstimate = true
                }
            case let .lru(tLast):
                // Deviation from §2.4 "LRU → exact 0": a never-used slot (t_last = -1) is exactly 0;
                // a reused LRU slot may still share a short prefix (< 10 % similarity), so mark it ≈.
                p.prompt.cachedTokens = 0
                p.prompt.cachedIsEstimate = tLast >= 0
            case .unknown:
                break
            }
        }

        if !isChild {
            // Request metadata from the server stream (chat started ≤ 10 s ago).
            if let req = takePendingRequest(model: model.isEmpty ? nil : model, at: at) {
                p.messageCount = req.messageCount
                p.endpoint = req.endpoint
                if model.isEmpty { model = req.model; p.model = model }
                a.sources.insert(.server)
            }
            // A pseudo-slot prediction created from server progress lines before the runtime
            // launch line arrived is the same request: absorb it.
            if !model.isEmpty, let pi = state.live.firstIndex(where: { $0.key.slot == SlotKey.pseudoSlot && $0.phase.isLive && $0.phase != .finishing && ModelKey.norm($0.model) == ModelKey.norm(model) }) {
                let pseudo = state.live[pi]
                p.startedAt = min(p.startedAt, pseudo.startedAt)
                p.messageCount = p.messageCount ?? pseudo.messageCount
                p.endpoint = p.endpoint ?? pseudo.endpoint
                p.streamed = pseudo.streamed
                p.serverProgress = pseudo.serverProgress
                if p.prompt.cachedTokens == nil || p.prompt.cachedIsEstimate, pseudo.prompt.cachedTokens != nil, !pseudo.prompt.cachedIsEstimate {
                    p.prompt = pseudo.prompt
                }
                if let pa = aux[pseudo.id] { a.sources.formUnion(pa.sources) }
                aux.removeValue(forKey: pseudo.id)
                state.live.remove(at: pi)
            }
            if !model.isEmpty, let sp = pendingServerProgress.removeValue(forKey: ModelKey.norm(model)), at.timeIntervalSince(sp.at) <= Self.pendingProgressTTL {
                p.serverProgress = sp.fraction
            }
        }

        if model.isEmpty { model = instance; p.model = model }
        if state.instances[instance]?.model == "" { state.instances[instance]?.model = model }
        p.contextLimit = contextLimit(instance: instance, model: model)
        if p.engineType == nil { p.engineType = engineType(forModel: model) }
        aux[p.id] = a
        state.live.append(p)
        transitioned = true
    }

    private func createMidFlight(instance: String, slot: Int, task: Int, phase: PredictionPhase, startedAt: Date, ctx: EngineContext, at: Date) -> Int {
        // Started mid-flight (app launched while the task was running): no launch line seen.
        for live in state.live where live.key.instance == instance && live.key.slot == slot && live.phase != .finishing && live.phase.isLive {
            finalize(id: live.id, as: .cancelled, at: at)
        }
        let model = ctx.modelIdentifier ?? state.instances[instance]?.model ?? instance
        var p = LivePrediction(key: SlotKey(instance: instance, slot: slot), task: task, model: model,
                               engineType: ctx.engineType ?? state.instances[instance]?.engineType ?? engineType(forModel: model),
                               phase: phase, startedAt: startedAt, lastUpdate: at)
        if phase == .generating { p.generationStartedAt = startedAt }
        p.contextLimit = contextLimit(instance: instance, model: model)
        aux[p.id] = Aux()
        state.live.append(p)
        transitioned = true
        return state.live.count - 1
    }

    private func markFinishing(_ p: inout LivePrediction, at: Date) {
        if p.phase == .queued || p.phase == .prefilling || p.phase == .generating {
            p.phase = .finishing
            p.finishingSince = at
            transitioned = true
        }
    }

    private func attachError(_ message: String, at: Date, source: EventSource, where match: (LivePrediction) -> Bool) {
        for i in state.live.indices where match(state.live[i]) && state.live[i].phase.isLive {
            if state.live[i].error == nil {
                state.live[i].error = message
                transitioned = true
            }
            state.live[i].lastUpdate = at
            var a = aux[state.live[i].id] ?? Aux()
            a.sources.insert(source)
            aux[state.live[i].id] = a
        }
    }

    // MARK: - Server lines

    private func applyServer(_ line: ServerLine, at: Date, source: EventSource) {
        switch line {
        case let .requestReceived(method, path):
            if !(method.uppercased() == "GET" && path.hasSuffix("/models")) {   // our own polls
                debug(at: at, source: source, "\(method) \(path)")
            }
            if method.uppercased() == "POST" && (path.contains("completions") || path.contains("responses")) {
                pendingEndpoint = (path, at)
            }

        case let .chatStarted(model, n):
            debug(at: at, source: source, "[\(model)] chat completion, \(n) message\(n == 1 ? "" : "s")")
            var endpoint: String?
            if let pe = pendingEndpoint, at.timeIntervalSince(pe.at) <= Self.pendingEndpointTTL {
                endpoint = pe.path
                pendingEndpoint = nil
            }
            let key = ModelKey.norm(model)
            var list = pendingRequests[key] ?? []
            list.append(PendingRequest(at: at, model: model, messageCount: n, endpoint: endpoint))
            if list.count > Self.pendingRequestsPerModelCap { list.removeFirst(list.count - Self.pendingRequestsPerModelCap) }
            pendingRequests[key] = list

        case let .prefillProgress(model, percent):
            debug(at: at, source: source, "[\(model)] prompt processing \(String(format: "%.1f", percent))%")
            serverProgress(model: model, fraction: min(1, max(0, percent / 100)), at: at, source: source)

        case let .streamingStarted(model):
            debug(at: at, source: source, "[\(model)] streaming response")
            if let idx = newestLive(model: model, preferPseudo: false, phases: [.queued, .prefilling, .generating]) {
                update(idx, at: at, source: source) { $0.streamed = true }
            }

        case let .streamingFinished(model):
            debug(at: at, source: source, "[\(model)] finished streaming")
            serverFinished(model: model, at: at, source: source)

        case let .generatedPrediction(model):
            debug(at: at, source: source, "[\(model)] generated prediction")
            serverFinished(model: model, at: at, source: source)

        case let .promptCacheRestore(info):
            debug(at: at, source: source, "prompt cache restore: cached \(info.cachedTokens), uncached \(info.uncachedTokens)")
            state.lastCacheRestore = info
            if let idx = state.live.lastIndex(where: { $0.key.slot == SlotKey.pseudoSlot && ($0.phase == .prefilling || $0.phase == .queued) }) {
                update(idx, at: at, source: source) { p in Self.applyCacheRestore(info, to: &p) }
            } else {
                pendingCacheRestore = (info, at)
            }

        case let .contextFit(info):
            debug(at: at, source: source, "context fit: family \(info.family), fitted \(info.fitted) of \(info.maxContext)")
            state.lastContextFit = info

        case let .cacheStore(disk):
            debug(at: at, source: source, "prompt cache disk: \(String(format: "%.0f", disk.usedMiB)) / \(String(format: "%.0f", disk.capMiB)) MiB, \(disk.records) records")
            state.promptCacheDisk = disk

        case let .modelLoadFailed(model, reason):
            debug(at: at, source: source, "failed to load \(model): \(reason)")

        case let .modelUnloadedTTL(model):
            debug(at: at, source: source, "[\(model)] unloaded (TTL)")
            let key = ModelKey.norm(model)
            for inst in state.instances.values where ModelKey.norm(inst.model) == key { removeInstance(inst.id, at: at) }
            for live in state.live where ModelKey.norm(live.model) == key && live.phase != .finishing {
                finalize(id: live.id, as: .cancelled, at: at)
            }

        case let .predictError(model, message):
            debug(at: at, source: source, "[\(model ?? "?")] predict error: \(message)")
            let key = model.map(ModelKey.norm)
            attachError(message, at: at, source: source) { key == nil || ModelKey.norm($0.model) == key! }
            // Only a pseudo slot ends here: for llama.cpp slots the runtime emits its own
            // cancel/release lines, which are authoritative for the phase.
            for i in state.live.indices where state.live[i].key.slot == SlotKey.pseudoSlot
                && (key == nil || ModelKey.norm(state.live[i].model) == key!) && state.live[i].phase.isLive {
                markFinishing(&state.live[i], at: at)
            }

        case .clientDisconnected:
            debug(at: at, source: source, "client disconnected")
            // Pseudo slots only: llama.cpp reports its own `srv stop: cancel task` for real slots,
            // and the server line carries no model, so guessing a slot would be wrong under load.
            if let idx = state.live.lastIndex(where: { $0.key.slot == SlotKey.pseudoSlot && !$0.isChild && ($0.phase == .generating || $0.phase == .prefilling || $0.phase == .queued) }) {
                let id = state.live[idx].id
                var a = aux[id] ?? Aux()
                a.sources.insert(source)
                if a.outcome == nil { a.outcome = .cancelled }
                a.userStopped = true
                aux[id] = a
                update(idx, at: at, source: source) { p in self.markFinishing(&p, at: at) }
            }

        case .serverStarted:
            debug(at: at, source: source, "server started")
            state.serverReachable = true

        case .serverStopped:
            debug(at: at, source: source, "server stopped")
            state.serverReachable = false

        case let .engineLine(raw):
            // Parsers normally convert these into `.engine` events; if one slips through, at
            // least keep the dedupe set and the debug ring consistent.
            if recent.insert(raw) { debug(at: at, source: source, raw) } else { state.dedupedLines += 1 }

        case let .other(_, text):
            guard !Self.isNoise(text) else { return }
            debug(at: at, source: source, text)
        }
    }

    private func serverProgress(model: String, fraction: Double, at: Date, source: EventSource) {
        let key = ModelKey.norm(model)

        // 1. A real llama.cpp slot for this model is prefilling: this is its progress.
        if let idx = state.live.lastIndex(where: { $0.key.slot >= 0 && !$0.isChild && ModelKey.norm($0.model) == key && ($0.phase == .prefilling || $0.phase == .queued) }) {
            update(idx, at: at, source: source) { p in
                p.serverProgress = fraction
                if fraction >= 0.9995 {
                    // Short answers never get an n_gen line; the server tells us prefill is done.
                    p.phase = .generating
                    p.generationStartedAt = at
                    self.transitioned = true
                }
            }
            return
        }

        // 2. An existing pseudo-slot prediction for this model.
        if let idx = state.live.lastIndex(where: { $0.key.slot == SlotKey.pseudoSlot && ModelKey.norm($0.model) == key && $0.phase.isLive && $0.phase != .finishing }) {
            let p = state.live[idx]
            if p.phase == .generating && fraction < 0.5 {
                // One pseudo prediction per model at a time: a restart means the old one ended.
                update(idx, at: at, source: source) { p in self.markFinishing(&p, at: at) }
                createPseudo(model: model, fraction: fraction, at: at, source: source)
            } else {
                update(idx, at: at, source: source) { p in Self.applyServerProgress(fraction, at: at, to: &p) }
            }
            return
        }

        // 3. llama.cpp model whose launch line has not arrived yet (stream skew ≤ 2 s): hold it.
        if hasRuntimeInstance(model: key) || (modelInfo(key)?.format?.lowercased() == "gguf" && runtimeStreamRunning) {
            if fraction < 0.9995 { pendingServerProgress[key] = (fraction, at) }
            return
        }

        // 4. Engine without slot logs (MLX): pseudo slot.
        createPseudo(model: model, fraction: fraction, at: at, source: source)
    }

    private func createPseudo(model: String, fraction: Double, at: Date, source: EventSource) {
        var p = LivePrediction(key: SlotKey(instance: model, slot: SlotKey.pseudoSlot), task: nil, model: model,
                               engineType: engineType(forModel: model), phase: .prefilling, startedAt: at, lastUpdate: at)
        var a = Aux()
        a.sources.insert(source)
        if let req = takePendingRequest(model: model, at: at) {
            p.startedAt = req.at
            p.messageCount = req.messageCount
            p.endpoint = req.endpoint
        }
        if let pc = pendingCacheRestore, at.timeIntervalSince(pc.at) <= Self.pendingCacheRestoreTTL {
            Self.applyCacheRestore(pc.info, to: &p)
            pendingCacheRestore = nil
        }
        p.contextLimit = contextLimit(instance: model, model: model)
        Self.applyServerProgress(fraction, at: at, to: &p)
        aux[p.id] = a
        state.live.append(p)
        transitioned = true
    }

    private static func applyServerProgress(_ fraction: Double, at: Date, to p: inout LivePrediction) {
        if let prev = p.serverProgress {
            let dt = at.timeIntervalSince(p.lastUpdate)
            if dt > 0 && fraction > prev { p.progressRatePerSec = (fraction - prev) / dt }
        }
        p.serverProgress = fraction
        if fraction >= 0.9995 && (p.phase == .prefilling || p.phase == .queued) {
            p.phase = .generating
            p.generationStartedAt = at
        }
    }

    private static func applyCacheRestore(_ info: PromptCacheRestore, to p: inout LivePrediction) {
        p.prompt.cachedTokens = info.cachedTokens
        p.prompt.cachedIsEstimate = false
        p.prompt.processedTokens = info.uncachedTokens
        p.prompt.totalTokens = info.cachedTokens + info.uncachedTokens
    }

    /// "Finished streaming" / "Generated prediction" end a prediction only for engines without
    /// slot logs (pseudo slot). For llama.cpp slots the runtime final block / release and the S2
    /// stats are authoritative: the server line carries no task id, and once the real request has
    /// already been finalized it would otherwise hit an unrelated long-running slot.
    private func serverFinished(model: String, at: Date, source: EventSource) {
        let key = ModelKey.norm(model)
        guard let idx = state.live.lastIndex(where: { $0.key.slot == SlotKey.pseudoSlot && !$0.isChild && ModelKey.norm($0.model) == key
            && ($0.phase == .queued || $0.phase == .prefilling || $0.phase == .generating) }) else { return }
        update(idx, at: at, source: source) { p in
            p.serverProgress = 1
            self.markFinishing(&p, at: at)
        }
    }

    // MARK: - Model stats (S2)

    private func applyModelStats(_ s: ModelStatsEvent, at: Date, source: EventSource) {
        debug(at: at, source: source, "[\(s.modelIdentifier)] stats: \(s.predictedTokensCount.map(String.init) ?? "?") tokens @ \(s.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "?") t/s, stop \(s.stopReasonRaw ?? "?")")
        let key = ModelKey.norm(s.modelIdentifier)
        let candidates = state.live.indices.filter {
            let p = state.live[$0]
            return !p.isChild && ModelKey.norm(p.model) == key && (p.phase == .finishing || p.phase == .generating || p.phase == .prefilling)
        }
        let best = candidates.min { ia, ib in
            let a = state.live[ia], b = state.live[ib]
            let ra = Self.statsRank(a, s, at: at), rb = Self.statsRank(b, s, at: at)
            return ra < rb || (ra == rb && a.startedAt < b.startedAt)
        }
        guard let idx = best else {
            standaloneRecord(from: s, at: at, source: source)
            return
        }
        let id = state.live[idx].id
        var a = aux[id] ?? Aux()
        a.sources.insert(source)
        a.stats = s
        let hasRuntimeFinal = state.live[idx].final.evalTokens != nil || state.live[idx].final.releaseNTokens != nil
        let isPseudo = state.live[idx].key.slot == SlotKey.pseudoSlot
        a.awaitingRuntimeFinal = !hasRuntimeFinal && !isPseudo && hasRuntimeInstance(model: key)
        aux[id] = a
        update(idx, at: at, source: source) { p in
            if let v = s.predictedTokensCount { p.generatedTokens = v }
            if let v = s.promptTokensCount, p.prompt.totalTokens == nil { p.prompt.totalTokens = v }
            self.markFinishing(&p, at: at)
        }
        if a.awaitingRuntimeFinal {
            return   // the runtime final block is usually ≤ 1 s behind; tick() finalizes otherwise
        }
        finalize(id: id, as: nil, at: at)
    }

    /// Lower is better: finishing first, then exact token match, then start-time proximity
    /// (S2 knows the prediction's total duration, so `at − totalTimeSec` is its start), then pseudo slot.
    private static func statsRank(_ p: LivePrediction, _ s: ModelStatsEvent, at: Date) -> Double {
        var rank = 0.0
        if p.phase != .finishing { rank += 100 }
        if let predicted = s.predictedTokensCount {
            if let e = p.final.evalTokens {
                rank += abs(e - predicted) <= 2 ? 0 : 50
            } else if let g = p.generatedTokens {
                rank += Double(min(40, abs(g - predicted)))
            } else {
                // No n_gen line yet means < ~3 s of generation: plausible only for a short answer.
                rank += Double(min(40, predicted / 10))
            }
        }
        if let total = s.totalTimeSec {
            let startMismatch = abs(p.startedAt.timeIntervalSince(at.addingTimeInterval(-total)))
            rank += min(60, startMismatch)
        }
        if p.key.slot != SlotKey.pseudoSlot { rank += 1 }
        return rank
    }

    private func standaloneRecord(from s: ModelStatsEvent, at: Date, source: EventSource) {
        let total = s.totalTimeSec ?? 0
        let stop = StopReason(lmStudio: s.stopReasonRaw)
        let phase: PredictionPhase = stop == .failed ? .errored : (stop == .userStopped ? .cancelled : .finished)
        var draft: DraftStats?
        if let gen = s.totalDraftTokensCount, let acc = s.acceptedDraftTokensCount, gen > 0 {
            draft = DraftStats(accepted: acc, generated: gen, meanLength: nil)
        }
        var prompt = PromptBreakdown()
        prompt.totalTokens = s.promptTokensCount
        let genTime: Double? = {
            guard let t = s.totalTimeSec, let f = s.timeToFirstTokenSec else { return nil }
            return max(0, t - f)
        }()
        var rec = PredictionRecord(
            id: UUID(), model: s.modelIdentifier, instance: nil, slot: nil, task: nil,
            engineType: engineType(forModel: s.modelIdentifier),
            startedAt: at.addingTimeInterval(-total), finishedAt: at, phase: phase,
            stopReason: stop, stopReasonRaw: s.stopReasonRaw,
            tokensPerSecond: s.tokensPerSecond, prefillTokensPerSecond: nil,
            timeToFirstToken: s.timeToFirstTokenSec, generationTime: genTime, totalTime: s.totalTimeSec,
            prompt: prompt, generatedTokens: s.predictedTokensCount,
            contextTokensAtEnd: s.totalTokensCount, contextLimit: contextLimit(instance: s.modelIdentifier, model: s.modelIdentifier),
            truncated: stop == .contextLengthReached, draft: draft, messageCount: nil, endpoint: nil, error: nil,
            sources: [source])
        if let f = s.timeToFirstTokenSec, f > 0, let pt = s.promptTokensCount, pt > 0 {
            rec.prefillTokensPerSecond = Double(pt) / f
        }
        absorbProxy(into: &rec)
        emit(rec, at: at)
    }

    // MARK: - Proxy (§2.6)

    private func applyProxy(_ req: ProxyRequestEvent, at: Date) {
        guard req.phase == .finished else { return }
        debug(at: at, source: .proxy, "[\(req.model)] \(req.endpoint) \(req.status.map(String.init) ?? "") \(req.completionTokens) tokens")
        let finishedAt = req.finishedAt ?? at
        // A stream-derived record already emitted for this request → drop the proxy copy.
        if recentRecords.contains(where: { ModelKey.norm($0.model) == ModelKey.norm(req.model)
            && abs($0.finishedAt.timeIntervalSince(finishedAt)) <= Self.proxyMatchWindow
            && ($0.generated == nil || abs($0.generated! - req.completionTokens) <= 3) }) {
            return
        }
        pendingProxy.append(req)
        if pendingProxy.count > Self.pendingProxyCap { pendingProxy.removeFirst(pendingProxy.count - Self.pendingProxyCap) }
    }

    private func absorbProxy(into rec: inout PredictionRecord) {
        guard let i = pendingProxy.firstIndex(where: { p in
            ModelKey.norm(p.model) == ModelKey.norm(rec.model)
                && abs((p.finishedAt ?? p.startedAt).timeIntervalSince(rec.finishedAt)) <= Self.proxyMatchWindow
                && (rec.generatedTokens == nil || abs(rec.generatedTokens! - p.completionTokens) <= 3)
        }) else { return }
        let p = pendingProxy.remove(at: i)
        if rec.endpoint == nil { rec.endpoint = p.endpoint }
        if rec.error == nil, let e = p.error { rec.error = e }
        if !rec.sources.contains(.proxy) { rec.sources.append(.proxy) }
    }

    private func expireProxy(now: Date) {
        guard !pendingProxy.isEmpty else { return }
        var kept: [ProxyRequestEvent] = []
        for p in pendingProxy {
            let finishedAt = p.finishedAt ?? p.startedAt
            if now.timeIntervalSince(finishedAt) <= Self.pendingProxyTTL { kept.append(p); continue }
            let streamsDead = lastStreamRecordAt.map { now.timeIntervalSince($0) > Self.streamsDeadAfter } ?? true
            guard streamsDead else { continue }
            let stop = StopReason(lmStudio: p.stopReason)
            let phase: PredictionPhase = p.error != nil ? .errored : (stop == .userStopped ? .cancelled : .finished)
            let total = finishedAt.timeIntervalSince(p.startedAt)
            let ttft = p.reportedTTFT ?? p.firstTokenAt.map { $0.timeIntervalSince(p.startedAt) }
            var prompt = PromptBreakdown()
            prompt.totalTokens = p.promptTokens
            let rec = PredictionRecord(
                id: p.id, model: p.model, instance: nil, slot: nil, task: nil, engineType: engineType(forModel: p.model),
                startedAt: p.startedAt, finishedAt: finishedAt, phase: phase, stopReason: phase == .errored ? .failed : stop,
                stopReasonRaw: p.stopReason,
                tokensPerSecond: p.reportedTPS ?? (ttft.map { total - $0 > 0 ? Double(p.completionTokens) / (total - $0) : 0 }),
                prefillTokensPerSecond: nil, timeToFirstToken: ttft,
                generationTime: ttft.map { max(0, total - $0) }, totalTime: total,
                prompt: prompt, generatedTokens: p.completionTokens,
                contextTokensAtEnd: p.promptTokens.map { $0 + p.completionTokens },
                contextLimit: contextLimit(instance: p.model, model: p.model), truncated: false, draft: nil,
                messageCount: nil, endpoint: p.endpoint, error: p.error, sources: [.proxy])
            emit(rec, at: now, fromStream: false)
        }
        pendingProxy = kept
    }

    // MARK: - Finalization

    private func finalize(id: UUID, as requested: PredictionPhase?, at: Date) {
        guard let idx = state.live.firstIndex(where: { $0.id == id }) else { return }
        let live = state.live.remove(at: idx)
        let a = aux.removeValue(forKey: id) ?? Aux()
        transitioned = true
        guard !live.isChild else { return }   // child tasks are tracked but never recorded

        let s2 = a.stats
        let finishedAt = live.finishingSince ?? min(at, max(live.lastUpdate, live.startedAt))
        let phase = Self.terminalPhase(live: live, aux: a, requested: requested)

        var prompt = live.prompt
        if let pt = s2?.promptTokensCount {
            prompt.totalTokens = pt
            if let pe = live.final.promptEvalTokens {
                // §2.4 rule 1 (exact, llama.cpp): cached = S2 prompt tokens − runtime evaluated tokens.
                prompt.processedTokens = pe
                prompt.cachedTokens = max(0, pt - pe)
                prompt.cachedIsEstimate = false
            } else if let c = prompt.cachedTokens, !prompt.cachedIsEstimate {
                // Rule 2 (exact, MLX cache restore): S2 total wins, processed follows.
                prompt.processedTokens = max(0, pt - c)
            } else if let c = prompt.cachedTokens {
                // Rule 3 (estimate) with S2 total: processed derived, cached stays ≈.
                if prompt.processedTokens == nil { prompt.processedTokens = max(0, pt - c) }
            }
        } else {
            if prompt.processedTokens == nil { prompt.processedTokens = live.final.promptEvalTokens ?? live.prefillProcessedTokens }
            if prompt.totalTokens == nil, let c = prompt.cachedTokens, let p = prompt.processedTokens { prompt.totalTokens = c + p }
        }

        let ttft = s2?.timeToFirstTokenSec ?? live.final.promptEvalMs.map { $0 / 1000 }
        var prefillTps = live.final.promptEvalTps ?? live.prefillTps
        if prefillTps == nil, let p = prompt.processedTokens, p > 0, let t = ttft, t > 0 { prefillTps = Double(p) / t }
        let totalTime: Double? = s2?.totalTimeSec ?? live.final.totalMs.map { $0 / 1000 } ?? (finishedAt > live.startedAt ? finishedAt.timeIntervalSince(live.startedAt) : nil)
        var genTime: Double? = live.final.evalMs.map { $0 / 1000 }
        if genTime == nil, let t = s2?.totalTimeSec, let f = s2?.timeToFirstTokenSec { genTime = max(0, t - f) }
        if genTime == nil, let g = live.generationStartedAt, finishedAt > g { genTime = finishedAt.timeIntervalSince(g) }
        let generated = s2?.predictedTokensCount ?? live.final.evalTokens ?? live.generatedTokens
        var tps = s2?.tokensPerSecond ?? live.final.evalTps ?? live.tgAverage
        if tps == nil, let g = generated, g > 0, let gt = genTime, gt > 0 { tps = Double(g) / gt }

        var draft = live.final.draft
        if let gen = s2?.totalDraftTokensCount, let acc = s2?.acceptedDraftTokensCount, gen > 0 {
            draft = DraftStats(accepted: acc, generated: gen, meanLength: live.final.draft?.meanLength)
        }

        let stopReason: StopReason
        if let raw = s2?.stopReasonRaw {
            stopReason = StopReason(lmStudio: raw)
        } else {
            switch phase {
            case .errored: stopReason = .failed
            case .cancelled: stopReason = a.userStopped ? .userStopped : .cancelled
            default: stopReason = live.final.truncated == true ? .contextLengthReached : .unknown
            }
        }

        var contextAtEnd = live.final.releaseNTokens ?? s2?.totalTokensCount
        if contextAtEnd == nil {
            var l = live
            l.prompt = prompt
            l.generatedTokens = generated
            contextAtEnd = l.contextTokensEstimate
        }

        var rec = PredictionRecord(
            id: live.id, model: live.model, instance: live.key.slot == SlotKey.pseudoSlot ? nil : live.key.instance,
            slot: live.key.slot == SlotKey.pseudoSlot ? nil : live.key.slot, task: live.task,
            engineType: live.engineType ?? state.instances[live.key.instance]?.engineType ?? engineType(forModel: live.model),
            startedAt: live.startedAt, finishedAt: finishedAt, phase: phase,
            stopReason: stopReason, stopReasonRaw: s2?.stopReasonRaw,
            tokensPerSecond: tps, prefillTokensPerSecond: prefillTps, timeToFirstToken: ttft,
            generationTime: genTime, totalTime: totalTime, prompt: prompt, generatedTokens: generated,
            contextTokensAtEnd: contextAtEnd, contextLimit: live.contextLimit ?? contextLimit(instance: live.key.instance, model: live.model),
            truncated: live.final.truncated ?? false, draft: draft, messageCount: live.messageCount,
            endpoint: live.endpoint, error: live.error,
            sources: EventSource.allCases.filter { a.sources.contains($0) })
        absorbProxy(into: &rec)
        emit(rec, at: at)
    }

    private static func terminalPhase(live: LivePrediction, aux: Aux, requested: PredictionPhase?) -> PredictionPhase {
        if let raw = aux.stats?.stopReasonRaw {
            let sr = StopReason(lmStudio: raw)
            if sr == .userStopped { return .cancelled }
            if sr == .failed { return .errored }
            if sr != .unknown { return .finished }
        }
        if live.error != nil { return .errored }
        if let r = requested, r == .cancelled || r == .errored { return r }
        if let o = aux.outcome { return o }
        return .finished
    }

    private func emit(_ rec: PredictionRecord, at: Date, fromStream: Bool = true) {
        state.lastRecord = rec
        if fromStream { lastStreamRecordAt = at }
        recentRecords.append(RecentRecord(model: rec.model, finishedAt: rec.finishedAt, generated: rec.generatedTokens))
        if recentRecords.count > 16 { recentRecords.removeFirst(recentRecords.count - 16) }
        transitioned = true
        onRecord?(rec)
    }

    // MARK: - Helpers

    private func update(_ idx: Int, at: Date, source: EventSource, _ body: (inout LivePrediction) -> Void) {
        guard state.live.indices.contains(idx) else { return }
        body(&state.live[idx])
        state.live[idx].lastUpdate = max(state.live[idx].lastUpdate, at)
        var a = aux[state.live[idx].id] ?? Aux()
        a.sources.insert(source)
        aux[state.live[idx].id] = a
    }

    private func liveIndex(instance: String, slot: Int, task: Int) -> Int? {
        // Newest first: the same slot may hold a finishing prediction and a new one.
        state.live.lastIndex(where: { $0.key.instance == instance && $0.key.slot == slot && $0.task == task && $0.phase.isLive })
    }

    private func newestLive(model: String, preferPseudo: Bool, phases: Set<PredictionPhase>) -> Int? {
        let key = ModelKey.norm(model)
        let matches = state.live.indices.filter { !state.live[$0].isChild && ModelKey.norm(state.live[$0].model) == key && phases.contains(state.live[$0].phase) }
        if preferPseudo, let pseudo = matches.last(where: { state.live[$0].key.slot == SlotKey.pseudoSlot }) { return pseudo }
        return matches.last
    }

    private func takePendingRequest(model: String?, at: Date) -> PendingRequest? {
        func take(_ key: String) -> PendingRequest? {
            guard var list = pendingRequests[key] else { return nil }
            list.removeAll { at.timeIntervalSince($0.at) > Self.pendingRequestTTL }
            let first = list.isEmpty ? nil : list.removeFirst()
            if list.isEmpty { pendingRequests.removeValue(forKey: key) } else { pendingRequests[key] = list }
            return first
        }
        if let model, !model.isEmpty { return take(ModelKey.norm(model)) }
        // Model unknown (context-less engine line): accept any pending request if exactly one
        // model has requests waiting.
        let keys = pendingRequests.keys.sorted()
        guard keys.count == 1, let key = keys.first else { return nil }
        return take(key)
    }

    /// Engine lines that arrive without runtime metadata (server-log copies, log-file tailer)
    /// are attributed to the instance that owns their task, else to the most recently seen
    /// llama.cpp instance, else to "default".
    private func resolveInstanceKey(ctx: EngineContext, line: EngineLine) -> String {
        if ctx.instanceReference != nil || ctx.modelIdentifier != nil { return ctx.instanceKey }
        if let task = Self.taskID(of: line),
           let live = state.live.last(where: { $0.task == task && $0.key.slot >= 0 && $0.phase.isLive }) {
            return live.key.instance
        }
        if let inst = state.instances.values
            .filter({ $0.engineType == nil || $0.engineType == "llama.cpp" })
            .max(by: { $0.lastSeen < $1.lastSeen }) {
            return inst.id
        }
        return Self.defaultInstance
    }

    private static func taskID(of line: EngineLine) -> Int? {
        switch line {
        case let .taskLaunched(_, task, _), let .prefillProgress(_, task, _, _, _, _), let .genProgress(_, task, _, _, _),
             let .promptEval(_, task, _, _, _), let .eval(_, task, _, _, _), let .totalTime(_, task, _, _),
             let .draftAcceptance(_, task, _, _, _, _), let .slotReleased(_, task, _, _), let .taskCancelled(task):
            return task
        default:
            return nil
        }
    }

    private func touchInstance(_ key: String, ctx: EngineContext, at: Date) {
        if var inst = state.instances[key] {
            if let pid = ctx.pid, let old = inst.pid, pid != old {
                // Same key, new process: the engine restarted under us.
                inst.slotLastNTokens = [:]
                inst.nSlots = nil; inst.nCtxSlot = nil; inst.kvUnified = nil
                for live in state.live where live.key.instance == key && live.phase != .finishing {
                    finalize(id: live.id, as: .cancelled, at: at)
                }
            }
            if let m = ctx.modelIdentifier { inst.model = m }
            if let v = ctx.engineName { inst.engineName = v }
            if let v = ctx.engineVersion { inst.engineVersion = v }
            if let v = ctx.engineType { inst.engineType = v }
            if let v = ctx.pid { inst.pid = v }
            inst.lastSeen = max(inst.lastSeen, at)
            state.instances[key] = inst
        } else {
            state.instances[key] = EngineInstance(id: key, model: ctx.modelIdentifier ?? "", engineName: ctx.engineName,
                                                  engineVersion: ctx.engineVersion, engineType: ctx.engineType, pid: ctx.pid,
                                                  lastSeen: at)
        }
    }

    static let defaultInstance = "default"

    /// Context-less engine lines (server-log copies) that arrive before any runtime line — e.g.
    /// right after launch, mid-generation — are filed under "default". As soon as a line with real
    /// runtime metadata shows up, move those predictions and slot data to the real instance so the
    /// same task is not tracked twice (which would produce duplicate records).
    private func adoptDefaultInstance(into key: String, ctx: EngineContext, at: Date) {
        guard let def = state.instances.removeValue(forKey: Self.defaultInstance) else { return }
        touchInstance(key, ctx: ctx, at: at)
        if var inst = state.instances[key] {
            for (slot, n) in def.slotLastNTokens where inst.slotLastNTokens[slot] == nil { inst.slotLastNTokens[slot] = n }
            if inst.nSlots == nil { inst.nSlots = def.nSlots }
            if inst.nCtxSlot == nil { inst.nCtxSlot = def.nCtxSlot }
            if inst.kvUnified == nil { inst.kvUnified = def.kvUnified }
            if inst.modelPath == nil { inst.modelPath = def.modelPath }
            state.instances[key] = inst
        }
        for i in state.live.indices where state.live[i].key.instance == Self.defaultInstance {
            let slot = state.live[i].key.slot
            let task = state.live[i].task
            let clash = state.live.contains { $0.key.instance == key && $0.key.slot == slot && $0.task == task && $0.phase.isLive }
            if clash {
                finalizeQuietly(index: i)
            } else {
                state.live[i].key = SlotKey(instance: key, slot: slot)
                if state.live[i].model.isEmpty, let m = ctx.modelIdentifier { state.live[i].model = m }
                if state.live[i].contextLimit == nil { state.live[i].contextLimit = state.instances[key]?.nCtxSlot }
            }
        }
        state.live.removeAll { $0.key.instance == Self.defaultInstance && $0.phase == .cancelled }
        for (k, v) in pendingReuse where k.instance == Self.defaultInstance {
            pendingReuse.removeValue(forKey: k)
            pendingReuse[SlotKey(instance: key, slot: k.slot)] = v
        }
        transitioned = true
    }

    /// Drops a duplicate live prediction without emitting a record.
    private func finalizeQuietly(index i: Int) {
        aux.removeValue(forKey: state.live[i].id)
        state.live[i].phase = .cancelled
    }

    private func removeInstance(_ key: String, at: Date) {
        for live in state.live where live.key.instance == key {
            finalize(id: live.id, as: live.phase == .finishing ? nil : .cancelled, at: at)
        }
        state.instances.removeValue(forKey: key)
        for k in pendingReuse.keys where k.instance == key { pendingReuse.removeValue(forKey: k) }
    }

    private func hasRuntimeInstance(model normKey: String) -> Bool {
        state.instances.values.contains { ModelKey.norm($0.model) == normKey && $0.engineType != "mlx" }
    }

    private var runtimeStreamRunning: Bool {
        if case .running = state.streams[.runtime] { return true }
        return false
    }

    private func modelInfo(_ normKey: String) -> ModelInfo? {
        state.models.first(where: { $0.isLoaded && ModelKey.norm($0.id) == normKey })
            ?? state.models.first(where: { ModelKey.norm($0.id) == normKey })
    }

    private func contextLimit(instance: String, model: String) -> Int? {
        if let n = state.instances[instance]?.nCtxSlot { return n }
        if let m = modelInfo(ModelKey.norm(model)) { return m.loadedContextLength ?? m.maxContextLength }
        return nil
    }

    private func engineType(forModel model: String) -> String? {
        let key = ModelKey.norm(model)
        if let inst = state.instances.values.first(where: { ModelKey.norm($0.model) == key }), let t = inst.engineType { return t }
        switch modelInfo(key)?.format?.lowercased() {
        case "gguf": return "llama.cpp"
        case "mlx": return "mlx"
        default: return nil
        }
    }

    private func clearPendings() {
        pendingReuse.removeAll()
        pendingRequests.removeAll()
        pendingEndpoint = nil
        pendingServerProgress.removeAll()
        pendingCacheRestore = nil
        pendingProxy.removeAll()
    }

    private static func isNoise(_ text: String) -> Bool {
        if text.hasPrefix("Returning") { return true }
        if text.hasPrefix("Received request") { return true }
        if text.count > 400 { return true }           // request / response bodies
        return false
    }

    private func debug(at: Date, source: EventSource, _ text: String) {
        var line = text
        if let nl = line.firstIndex(of: "\n") { line = String(line[..<nl]) }
        if line.count > 240 { line = String(line.prefix(240)) + "…" }
        debugLines.append("\(Fmt.clock.string(from: at)) [\(source.rawValue)] \(line)")
        if debugLines.count > Self.debugCapacity { debugLines.removeFirst(debugLines.count - Self.debugCapacity) }
    }

    private func describe(_ status: StreamStatus) -> String {
        switch status {
        case .notStarted: return "not started"
        case let .blocked(reason): return "blocked: \(reason)"
        case .starting: return "starting"
        case .running: return "running"
        case let .exited(code, _): return "exited (\(code))"
        case let .backoff(seconds): return "backoff \(String(format: "%.0f", seconds)) s"
        case let .droppedOversizedLine(bytes): return "dropped oversized line (\(bytes) bytes)"
        }
    }
}
