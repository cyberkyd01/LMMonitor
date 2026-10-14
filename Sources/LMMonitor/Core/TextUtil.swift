import Foundation

/// Precompiled NSRegularExpression wrapper. Patterns are matched against the whole string
/// starting at index 0 only when they begin with "^" (we don't add anchors implicitly).
struct Rx {
    let re: NSRegularExpression
    init(_ pattern: String) {
        // Patterns are compile-time constants; a bad one is a programming error caught by --selftest.
        re = try! NSRegularExpression(pattern: pattern, options: [])
    }
    /// Capture groups 1...n of the first match ("" for groups that didn't participate), or nil.
    func captures(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        var out: [String] = []
        out.reserveCapacity(max(0, m.numberOfRanges - 1))
        if m.numberOfRanges > 1 {
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
        }
        return out
    }
    func matches(_ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

/// Splits a byte stream into lines. Lines longer than `maxLineBytes` are discarded (counted),
/// so a single huge log line can never blow up memory. Not thread-safe: own it on one queue.
struct LineFramer {
    let maxLineBytes: Int
    private(set) var droppedLines = 0
    private(set) var droppedBytes = 0
    private var buffer = Data()
    private var discarding = false

    init(maxLineBytes: Int) { self.maxLineBytes = max(1024, maxLineBytes) }

    /// Appends bytes; returns complete lines (without the trailing \n; a trailing \r is stripped).
    mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var chunk = data[...]
        while !chunk.isEmpty {
            if let nl = chunk.firstIndex(of: 0x0A) {
                let piece = chunk[chunk.startIndex..<nl]
                if discarding {
                    droppedBytes += piece.count
                    discarding = false
                } else if buffer.count + piece.count > maxLineBytes {
                    droppedLines += 1
                    droppedBytes += buffer.count + piece.count
                } else {
                    buffer.append(contentsOf: piece)
                    var line = buffer
                    if line.last == 0x0D { line.removeLast() }
                    lines.append(line)
                }
                buffer = Data()
                chunk = chunk[chunk.index(after: nl)...]
            } else {
                if discarding {
                    droppedBytes += chunk.count
                } else if buffer.count + chunk.count > maxLineBytes {
                    droppedLines += 1
                    droppedBytes += buffer.count + chunk.count
                    buffer = Data()
                    discarding = true
                } else {
                    buffer.append(contentsOf: chunk)
                }
                chunk = chunk[chunk.endIndex...]
            }
        }
        return lines
    }
}

enum NDJSON {
    /// Parses one NDJSON line into a dictionary. Lines not starting with "{" (banners, blanks) → nil.
    static func object(_ line: Data) -> [String: Any]? {
        guard let first = line.first(where: { $0 != 0x20 && $0 != 0x09 }), first == UInt8(ascii: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: line, options: [])) as? [String: Any]
    }
    /// `timestamp` field in milliseconds since 1970.
    static func timestamp(_ obj: [String: Any]) -> Date? {
        if let ms = obj["timestamp"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = obj["timestamp"] as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }
}

/// Bounded set of recently seen strings (ring + hash set). Used to drop engine lines that arrive
/// twice (runtime stream and its verbatim copy inside the server stream). Single-threaded.
final class RecentLineSet {
    private var ring: [String?]
    private var head = 0
    private var set = Set<String>()
    init(capacity: Int = 512) { ring = Array(repeating: nil, count: max(1, capacity)) }
    /// Returns false if `s` was already seen recently (a duplicate).
    @discardableResult
    func insert(_ s: String) -> Bool {
        if set.contains(s) { return false }
        if let old = ring[head] { set.remove(old) }
        ring[head] = s
        set.insert(s)
        head = (head + 1) % ring.count
        return true
    }
    func removeAll() { ring = Array(repeating: nil, count: ring.count); set.removeAll(); head = 0 }
}
