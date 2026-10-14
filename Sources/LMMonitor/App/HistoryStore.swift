import Foundation

/// Persists finished predictions as JSON Lines in ~/Library/Application Support/LMMonitor/history.jsonl.
/// All file IO runs on one serial queue. The file is compacted to the newest 1,000 records once it
/// grows past 2,000 lines or 2 MiB.
final class HistoryStore {
    private let url: URL
    private let queue = DispatchQueue(label: "lmmonitor.history", qos: .utility)
    private var lineCount = 0
    private let keep = 1000
    private let maxLines = 2000
    private let maxBytes = 2 << 20

    init(url: URL = Settings.appSupportDir.appendingPathComponent("history.jsonl")) {
        self.url = url
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// Loads up to `limit` newest records (returned newest first).
    func load(limit: Int, completion: @escaping @MainActor @Sendable ([PredictionRecord]) -> Void) {
        queue.async { [self] in
            let records = readAll()
            lineCount = records.count
            let out = Array(records.suffix(limit).reversed())
            hopToMain { completion(out) }
        }
    }

    func append(_ r: PredictionRecord) {
        queue.async { [self] in
            guard var line = try? Self.makeEncoder().encode(r) else { return }
            line.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: line)
                } else {
                    try line.write(to: url, options: .atomic)
                }
                lineCount += 1
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if lineCount > maxLines || size > maxBytes { compact() }
            } catch {
                // History is best-effort; a failed write must never affect monitoring.
            }
        }
    }

    func clear() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: url)
            lineCount = 0
        }
    }

    // MARK: - queue-only helpers

    private func readAll() -> [PredictionRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let dec = Self.makeDecoder()
        var out: [PredictionRecord] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let r = try? dec.decode(PredictionRecord.self, from: Data(line)) { out.append(r) }
        }
        return out   // oldest → newest (file order)
    }

    private func compact() {
        let newest = readAll().suffix(keep)
        let enc = Self.makeEncoder()
        var blob = Data()
        for r in newest {
            if let d = try? enc.encode(r) { blob.append(d); blob.append(0x0A) }
        }
        if (try? blob.write(to: url, options: .atomic)) != nil { lineCount = newest.count }
    }
}
