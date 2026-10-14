import Foundation

/// Maps one server-log `content` string to events (shared by the `lms` server stream and the file tailer).
enum ServerEventMapper {
    static func events(content: String, at: Date, source: EventSource) -> [LMEvent] {
        var out: [LMEvent] = []
        for line in ServerLineParser.parse(content: content) {
            if case .engineLine(let raw) = line {
                if let parsed = EngineLineParser.parse(raw) {
                    out.append(LMEvent(at: at, source: source, kind: .engine(parsed, EngineContext(), raw: raw)))
                }
            } else {
                out.append(LMEvent(at: at, source: source, kind: .server(line)))
            }
        }
        return out
    }
}

/// Fallback when `lms` is not installed: follows the newest LM Studio server log file (no replay).
final class ServerLogFileTailer {
    private let sink: @MainActor @Sendable ([LMEvent]) -> Void
    private let queue = DispatchQueue(label: "lmmonitor.tail", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var started = false

    // Queue-confined
    private var currentPath: String?
    private var offset: UInt64 = 0
    private var framer = LineFramer(maxLineBytes: 1 << 20)
    private var lastPick = Date.distantPast

    init(sink: @escaping @MainActor @Sendable ([LMEvent]) -> Void) { self.sink = sink }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            currentPath = nil; offset = 0; lastPick = .distantPast
            framer = LineFramer(maxLineBytes: 1 << 20)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            send([LMEvent(at: Date(), source: .logfile, kind: .stream(.logfile, .running(since: Date())))])
        }
    }

    func stop() {
        queue.async { [self] in
            guard started else { return }
            started = false
            timer?.cancel(); timer = nil
            send([LMEvent(at: Date(), source: .logfile, kind: .stream(.logfile, .notStarted))])
        }
    }

    private func send(_ events: [LMEvent]) {
        guard !events.isEmpty else { return }
        let b = events
        let s = sink
        hopToMain { s(b) }
    }

    private func newestLogFile() -> String? {
        let fm = FileManager.default
        let root = Settings.lmStudioHome.appendingPathComponent("server-logs")
        guard let months = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        var best: (String, Date)?
        for m in months.sorted().suffix(2) {
            let dir = root.appendingPathComponent(m)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for f in files where f.hasSuffix(".log") {
                let p = dir.appendingPathComponent(f).path
                guard let attrs = try? fm.attributesOfItem(atPath: p), let mt = attrs[.modificationDate] as? Date else { continue }
                if best == nil || mt > best!.1 { best = (p, mt) }
            }
        }
        return best?.0
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    private func tick() {
        guard started else { return }
        let now = Date()
        if currentPath == nil || now.timeIntervalSince(lastPick) >= 5 {
            lastPick = now
            if let p = newestLogFile(), p != currentPath {
                let first = currentPath == nil
                currentPath = p
                offset = first ? (fileSize(p) ?? 0) : 0     // first open: no replay; rotation: read from the top
                framer = LineFramer(maxLineBytes: 1 << 20)
            }
        }
        guard let path = currentPath, let size = fileSize(path) else { return }
        if size < offset { offset = 0 }
        guard size > offset, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        var events: [LMEvent] = []
        do {
            try fh.seek(toOffset: offset)
            let chunk = try fh.read(upToCount: Int(min(size - offset, 4 << 20))) ?? Data()
            offset += UInt64(chunk.count)
            for lineData in framer.append(chunk) {
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                var at = now
                if line.hasPrefix("["), line.count >= 20 {
                    let stamp = String(line.dropFirst().prefix(19))
                    if let d = ServerLineParser.parseLocalDate(stamp) { at = d }
                }
                // Continuation lines (no [date] prefix) are passed through too: the parser handles bare engine lines.
                events.append(contentsOf: ServerEventMapper.events(content: line, at: at, source: .logfile))
            }
        } catch {
            return
        }
        send(events)
    }
}
