import Foundation

/// One supervised `lms log stream ...` child process. All mutable state lives on `queue`;
/// `status` / `lastOutputAt` are mirrored under a lock for thread-safe reads.
final class StreamWorker {
    let source: EventSource

    private let lms: URL
    private let arguments: [String]
    private let maxLineBytes: Int
    private let parse: (_ obj: [String: Any], _ at: Date) -> [LMEvent]
    private let emit: ([LMEvent]) -> Void
    private let queue: DispatchQueue

    /// Called on the worker queue whenever the status changes (the supervisor uses `.exited` for restarts).
    var onStatusChange: ((StreamStatus) -> Void)?

    // Queue-confined state
    private var process: Process?
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private var generation = 0
    private var framer: LineFramer
    private var lastDroppedBytes = 0
    private var pending: [LMEvent] = []
    private var flushScheduled = false
    private var stderrTail = Data()
    private var stopping = false

    // Lock-protected mirrors
    private let lock = NSLock()
    private var _status: StreamStatus = .notStarted
    private var _lastOutputAt: Date?
    private var _isRunning = false

    var status: StreamStatus { lock.lock(); defer { lock.unlock() }; return _status }
    var lastOutputAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastOutputAt }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isRunning }

    init(source: EventSource, lms: URL, arguments: [String], maxLineBytes: Int,
         parse: @escaping (_ obj: [String: Any], _ at: Date) -> [LMEvent],
         emit: @escaping ([LMEvent]) -> Void) {
        self.source = source
        self.lms = lms
        self.arguments = arguments
        self.maxLineBytes = maxLineBytes
        self.parse = parse
        self.emit = emit
        self.framer = LineFramer(maxLineBytes: maxLineBytes)
        self.queue = DispatchQueue(label: "lmmonitor.lms.\(source.rawValue)", qos: .utility)
    }

    func start() {
        queue.async { [self] in spawn() }
    }

    /// Sends SIGTERM without waiting (used to stop several workers in parallel before `stop()`).
    /// Must not be called from the worker queue.
    func signalTerminate() {
        queue.sync { [self] in
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    /// Terminates the child (SIGTERM, SIGKILL after 1 s) and blocks until it is gone.
    /// Must not be called from the worker queue.
    func stop() {
        queue.sync { [self] in
            guard let p = process else { setStatus(.notStarted, notify: false); return }
            stopping = true
            generation += 1                 // ignore late callbacks from this child
            detachHandles()
            if p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(1.0)
            while p.isRunning && Date() < deadline { usleep(10_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL); usleep(50_000) }
            ChildPIDRegistry.shared.remove(p.processIdentifier)
            process = nil
            stopping = false
            pending.removeAll()
            setStatus(.notStarted, notify: false)
        }
    }

    // MARK: - queue-confined

    private func spawn() {
        if process != nil { return }
        generation += 1
        let gen = generation
        framer = LineFramer(maxLineBytes: maxLineBytes)
        lastDroppedBytes = 0
        stderrTail = Data()
        pending.removeAll()
        setStatus(.starting, notify: true)

        let p = Process()
        p.executableURL = lms
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"; env["FORCE_COLOR"] = "0"; env["TERM"] = "dumb"
        p.environment = env
        p.qualityOfService = .utility

        let out = outPipe.fileHandleForReading
        let err = errPipe.fileHandleForReading
        out.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // EOF
            self?.queue.async { self?.handleStdout(d, gen: gen) }
        }
        err.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.handleStderr(d, gen: gen) }
        }
        p.terminationHandler = { [weak self] proc in
            ChildPIDRegistry.shared.remove(proc.processIdentifier)
            let code = proc.terminationStatus
            self?.queue.async { self?.handleExit(code: code, gen: gen) }
        }

        do {
            try p.run()
        } catch {
            out.readabilityHandler = nil
            err.readabilityHandler = nil
            try? outPipe.fileHandleForWriting.close(); try? errPipe.fileHandleForWriting.close()
            setStatus(.exited(code: -1, stderrTail: "spawn failed: \(error.localizedDescription)"), notify: true)
            return
        }
        ChildPIDRegistry.shared.add(p.processIdentifier)
        // Parent's copies of the write ends must be closed or EOF never arrives.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        process = p
        outHandle = out
        errHandle = err
        lock.lock(); _isRunning = true; lock.unlock()
        setStatus(.running(since: Date()), notify: true)
    }

    private func handleStdout(_ data: Data, gen: Int) {
        guard gen == generation else { return }
        lock.lock(); _lastOutputAt = Date(); lock.unlock()
        let lines = framer.append(data)
        if framer.droppedBytes > lastDroppedBytes {
            let delta = framer.droppedBytes - lastDroppedBytes
            lastDroppedBytes = framer.droppedBytes
            pending.append(LMEvent(at: Date(), source: source, kind: .stream(source, .droppedOversizedLine(bytes: delta))))
        }
        for line in lines {
            guard let obj = NDJSON.object(line) else { continue }
            let at = NDJSON.timestamp(obj) ?? Date()
            pending.append(contentsOf: parse(obj, at))
        }
        if pending.count >= 64 {
            flush()
        } else if !pending.isEmpty && !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flush()
            }
        }
    }

    private func handleStderr(_ data: Data, gen: Int) {
        guard gen == generation else { return }
        stderrTail.append(data)
        if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
    }

    private func handleExit(code: Int32, gen: Int) {
        guard gen == generation, !stopping else { return }
        flush()
        detachHandles()
        process = nil
        let tail = String(decoding: stderrTail, as: UTF8.self)
        setStatus(.exited(code: code, stderrTail: tail), notify: true)
    }

    private func detachHandles() {
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        // No explicit close(): FileHandle closes its descriptor on dealloc, after the dispatch source is gone.
        outHandle = nil
        errHandle = nil
        lock.lock(); _isRunning = false; lock.unlock()
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        emit(batch)
    }

    private func setStatus(_ s: StreamStatus, notify: Bool) {
        lock.lock(); _status = s; lock.unlock()
        guard notify else { return }
        flush()
        emit([LMEvent(at: Date(), source: source, kind: .stream(source, s))])
        onStatusChange?(s)
    }
}
