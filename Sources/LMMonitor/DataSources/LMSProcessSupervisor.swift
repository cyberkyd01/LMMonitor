import Foundation

/// Supervises the three `lms log stream` workers (design §1.4).
///
/// CRITICAL: `lms` auto-starts the headless LM Studio daemon when LM Studio is not running, so every
/// spawn is gated on `LMStudioLiveness.check()`. When LM Studio goes away the workers are stopped and
/// stay `.blocked` until it is back.
final class LMSProcessSupervisor {
    private let sink: @MainActor @Sendable ([LMEvent]) -> Void
    private let queue = DispatchQueue(label: "lmmonitor.lms.supervisor", qos: .utility)
    private static let sources: [EventSource] = [.runtime, .model, .server]
    private static let noLiveness = "LM Studio not running"
    private static let noLMS = "lms not found"

    /// Optional hint for the runtime-silence watchdog ("a prediction is generating"). When nil, recent
    /// server-stream output is used as the hint.
    /// Set by the store: true while it sees at least one live prediction. Drives the runtime-stream
    /// watchdog (any other signal — e.g. server output — is polluted by our own REST polls).
    private var _livePredictions = false
    func setLivePredictions(_ live: Bool) { lock.lock(); _livePredictions = live; lock.unlock() }

    // Queue-confined state
    private var started = false
    private var timer: DispatchSourceTimer?
    private var workers: [EventSource: StreamWorker] = [:]
    private var workersLMS: URL?
    private var tailer: ServerLogFileTailer?
    private var tailerRunning = false
    private var nextAttempt: [EventSource: Date] = [:]
    private var nextDelay: [EventSource: Double] = [:]
    private var runningSince: [EventSource: Date] = [:]
    private var exitHandled = Set<EventSource>()
    private var blockedReason: String?
    private var lastLocate = Date.distantPast

    // Lock-protected, readable from any thread
    private let lock = NSLock()
    private var _lmsURL: URL?
    private var overrides: [EventSource: StreamStatus] = [:]
    private var tailerStatus: StreamStatus?

    init(sink: @escaping @MainActor @Sendable ([LMEvent]) -> Void) {
        self.sink = sink
        self._lmsURL = LMSLocator.find(override: Settings.lmsPathOverride)
    }

    var lmsURL: URL? { lock.lock(); defer { lock.unlock() }; return _lmsURL }

    func statuses() -> [EventSource: StreamStatus] {
        lock.lock()
        let ov = overrides, ts = tailerStatus
        lock.unlock()
        // `workers` is queue-confined, but each worker's status is itself thread-safe; we keep a lock-guarded copy of refs.
        var out: [EventSource: StreamStatus] = [:]
        for s in Self.sources { out[s] = ov[s] ?? workerRefs()[s]?.status ?? .notStarted }
        if let ts { out[.logfile] = ts }
        return out
    }

    private var _workerRefs: [EventSource: StreamWorker] = [:]
    private func workerRefs() -> [EventSource: StreamWorker] { lock.lock(); defer { lock.unlock() }; return _workerRefs }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            ChildPIDRegistry.shared.reapOrphans()   // children left behind by a crash / force quit
            blockedReason = ""      // sentinel: forces the staggered start on the first live tick, and a blocked event if not live
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 2.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync { [self] in
            guard started else { return }
            started = false
            timer?.cancel(); timer = nil
            for w in workers.values { w.signalTerminate() }   // all three exit in parallel…
            for w in workers.values { w.stop() }              // …then reap each (≤ 1 s total)
            tailer?.stop(); tailerRunning = false
            lock.lock(); tailerStatus = nil; lock.unlock()
        }
    }

    /// Call after `Settings.changed` (lms path override).
    func reconfigure() {
        queue.async { [self] in
            lastLocate = .distantPast
            if started { tick() }
        }
    }

    // MARK: - tick

    private func tick() {
        guard started else { return }
        let now = Date()

        // 1. locate lms (every tick while missing is cheap, but throttle to 30 s; always on reconfigure)
        if lmsURL == nil || now.timeIntervalSince(lastLocate) >= 30 {
            lastLocate = now
            let found = LMSLocator.find(override: Settings.lmsPathOverride)
            lock.lock(); _lmsURL = found; lock.unlock()
        }
        guard let lms = lmsURL else { enterNoLMS(); return }
        if tailerRunning { tailer?.stop(); tailerRunning = false; setTailerStatus(nil) }
        if workersLMS != lms {
            for w in workers.values { w.stop() }
            workers.removeAll()
            lock.lock(); _workerRefs.removeAll(); lock.unlock()
            workersLMS = lms
            blockedReason = ""      // re-run staggered start
        }

        // 2. liveness gate
        guard LMStudioLiveness.check().running else { enterBlocked(Self.noLiveness); return }
        if blockedReason != nil {
            blockedReason = nil
            lock.lock(); overrides.removeAll(); lock.unlock()
            for (i, s) in Self.sources.enumerated() {
                nextAttempt[s] = now.addingTimeInterval(0.3 * Double(i))
                exitHandled.remove(s)
                nextDelay[s] = 1
                queue.asyncAfter(deadline: .now() + 0.3 * Double(i) + 0.05) { [weak self] in self?.tick() }
            }
        }

        // 3. start whatever is due
        for s in Self.sources {
            let w = ensureWorker(s, lms: lms)
            if w.isRunning { continue }
            if case .exited = w.status, !exitHandled.contains(s) { continue }   // exit not yet processed
            if case .starting = w.status { continue }
            if let t = nextAttempt[s], now < t { continue }
            exitHandled.remove(s)
            lock.lock(); overrides[s] = nil; lock.unlock()
            w.start()
        }

        // 4. watchdog: runtime stream silent for 10 min while predictions seem to run
        if let rt = workers[.runtime], rt.isRunning {
            if case .running(let since) = rt.status {
                let last = rt.lastOutputAt ?? since
                if now.timeIntervalSince(last) > 600 && generatingHint(now: now) {
                    rt.stop()
                    nextAttempt[.runtime] = now
                    exitHandled.remove(.runtime)
                }
            }
        }
    }

    private func generatingHint(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _livePredictions
    }

    private func enterBlocked(_ reason: String) {
        guard blockedReason != reason else { return }
        blockedReason = reason
        for w in workers.values { w.stop() }
        publishBlocked(reason)
    }

    private func enterNoLMS() {
        for w in workers.values { w.stop() }
        workers.removeAll()
        workersLMS = nil
        lock.lock(); _workerRefs.removeAll(); lock.unlock()
        if blockedReason != Self.noLMS {
            blockedReason = Self.noLMS
            publishBlocked(Self.noLMS)
        }
        if !tailerRunning {
            let t = tailer ?? ServerLogFileTailer(sink: sink)
            tailer = t
            t.start()
            tailerRunning = true
            setTailerStatus(.running(since: Date()))
        }
    }

    private func setTailerStatus(_ s: StreamStatus?) { lock.lock(); tailerStatus = s; lock.unlock() }

    private func publishBlocked(_ reason: String) {
        let now = Date()
        let st = StreamStatus.blocked(reason: reason)
        lock.lock()
        for s in Self.sources { overrides[s] = st }
        lock.unlock()
        deliver(Self.sources.map { LMEvent(at: now, source: $0, kind: .stream($0, st)) })
    }

    private func deliver(_ events: [LMEvent]) {
        let b = events
        let s = sink
        hopToMain { s(b) }
    }

    // MARK: - workers

    private func ensureWorker(_ source: EventSource, lms: URL) -> StreamWorker {
        if let w = workers[source] { return w }
        let args: [String]
        let maxBytes: Int
        let parse: (_ obj: [String: Any], _ at: Date) -> [LMEvent]
        switch source {
        case .runtime:
            args = ["log", "stream", "--source", "runtime", "--json"]
            maxBytes = 256 << 10
            parse = Self.parseRuntime
        case .model:
            args = ["log", "stream", "--source", "model", "--filter", "output", "--stats", "--json"]
            maxBytes = 16 << 20
            parse = Self.parseModel
        default:
            args = ["log", "stream", "--source", "server", "--json"]
            maxBytes = 1 << 20
            parse = Self.parseServer
        }
        let sinkCopy = sink
        let w = StreamWorker(source: source, lms: lms, arguments: args, maxLineBytes: maxBytes, parse: parse) { events in
            let b = events
            hopToMain { sinkCopy(b) }
        }
        w.onStatusChange = { [weak self] st in
            self?.queue.async { self?.workerStatusChanged(source, st) }
        }
        workers[source] = w
        lock.lock(); _workerRefs[source] = w; lock.unlock()
        return w
    }

    private func workerStatusChanged(_ source: EventSource, _ st: StreamStatus) {
        guard started, blockedReason == nil else { return }
        switch st {
        case .running(let since):
            runningSince[source] = since
        case .exited:
            let now = Date()
            if let since = runningSince[source], now.timeIntervalSince(since) > 60 { nextDelay[source] = 1 }
            runningSince[source] = nil
            let delay = nextDelay[source] ?? 1
            nextDelay[source] = min(30, delay * 2)
            nextAttempt[source] = now.addingTimeInterval(delay)
            exitHandled.insert(source)
            let b = StreamStatus.backoff(seconds: delay)
            lock.lock(); overrides[source] = b; lock.unlock()
            deliver([LMEvent(at: now, source: source, kind: .stream(source, b))])
            queue.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in self?.tick() }
        default:
            break
        }
    }

    // MARK: - parse closures (pure; run on worker queues)

    static func parseRuntime(_ obj: [String: Any], _ at: Date) -> [LMEvent] {
        guard let data = obj["data"] as? [String: Any], let msg = data["message"] as? String else { return [] }
        var ctx = EngineContext()
        ctx.modelIdentifier = data["modelIdentifier"] as? String
        ctx.instanceReference = data["instanceReference"] as? String
        ctx.engineName = data["engineName"] as? String
        ctx.engineVersion = data["engineVersion"] as? String
        ctx.engineType = data["engineType"] as? String
        if let p = data["pid"] as? Int { ctx.pid = Int32(truncatingIfNeeded: p) }
        var out: [LMEvent] = []
        for piece in msg.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(piece)
            if line.hasSuffix("\r") { line.removeLast() }
            guard let parsed = EngineLineParser.parse(line) else { continue }
            out.append(LMEvent(at: at, source: .runtime, kind: .engine(parsed, ctx, raw: line)))
        }
        return out
    }

    static func parseModel(_ obj: [String: Any], _ at: Date) -> [LMEvent] {
        guard let m = ModelStatsParser.parse(obj) else { return [] }
        return [LMEvent(at: at, source: .model, kind: .modelStats(m))]
    }

    static func parseServer(_ obj: [String: Any], _ at: Date) -> [LMEvent] {
        guard let data = obj["data"] as? [String: Any], let content = data["content"] as? String else { return [] }
        return ServerEventMapper.events(content: content, at: at, source: .server)
    }
}
