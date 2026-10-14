import Foundation

enum Fmt {
    private static let decimal: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()

    static func bytes(_ b: UInt64?) -> String {
        guard let b else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }
    static func rate(_ bps: Double?) -> String {
        guard let bps, bps.isFinite else { return "—" }
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / 1024 / 1024) }
        return String(format: "%.2f GB/s", bps / 1024 / 1024 / 1024)
    }
    static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f%%", v)
    }
    static func tps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: v < 100 ? "%.1f tok/s" : "%.0f tok/s", v)
    }
    static func secs(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        if v < 1 { return String(format: "%.0f ms", v * 1000) }
        if v < 60 { return String(format: "%.2f s", v) }
        return duration(v)
    }
    static func int(_ v: Int?) -> String {
        guard let v else { return "—" }
        return decimal.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "27.0 GB" using 1024^3 (matches how LM Studio and Activity Monitor label memory).
    static func gib(_ b: UInt64?, decimals: Int = 1) -> String {
        guard let b else { return "—" }
        let g = Double(b) / 1_073_741_824
        if g < 1 { return String(format: "%.0f MB", Double(b) / 1_048_576) }
        return String(format: "%.\(decimals)f GB", g)
    }
    /// "1:23:45" / "12:34" / "0:07"
    static func duration(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "—" }
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// "27.3k" at or above 10k, else "2,048".
    static func tokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        if abs(n) >= 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return int(n)
    }
    static func watts(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "—" }
        return String(format: w < 10 ? "%.1f W" : "%.0f W", w)
    }
    static func mhz(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f MHz", v)
    }
    static func temp(_ c: Double?) -> String {
        guard let c, c.isFinite else { return "—" }
        return String(format: "%.0f°C", c)
    }
    /// 0...1 → "88.9%"
    static func ratio(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1f%%", v * 100)
    }
    static func eta(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "" }
        return "~\(duration(s)) left"
    }
    /// Fixed-width number for the menu bar: pads with U+2007 FIGURE SPACE so width is stable.
    static func fixed(_ v: Double, width: Int, decimals: Int) -> String {
        let s = String(format: "%\(width).\(decimals)f", v)
        return s.replacingOccurrences(of: " ", with: "\u{2007}")
    }
    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let shortTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    /// "just now" / "3 min ago" / "2 h ago"
    static func ago(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "—" }
        let s = now.timeIntervalSince(d)
        if s < 10 { return "just now" }
        if s < 60 { return "\(Int(s)) s ago" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}
