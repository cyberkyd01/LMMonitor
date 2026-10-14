import Foundation
import Darwin

/// Cheap "is LM Studio (or its headless daemon) running?" check. Gate for every `lms` spawn:
/// `lms` auto-starts the llmster daemon when LM Studio is not running.
enum LMStudioLiveness {
    struct Status: Equatable { var running: Bool; var pid: Int32? }

    private static let appMarker = "/LM Studio.app/Contents/MacOS/LM Studio"

    static func check() -> Status {
        if let pid = lockPid(), isAlive(pid), pathMatches(pid) {
            return Status(running: true, pid: pid)
        }
        if let pid = scanForProcess() { return Status(running: true, pid: pid) }
        return Status(running: false, pid: nil)
    }

    static func isRunning() -> Bool { check().running }

    private static func lockPid() -> Int32? {
        let url = Settings.lmStudioHome.appendingPathComponent(".internal/llmster-pid.lock")
        guard let d = try? Data(contentsOf: url), d.count < 4096,
              let s = String(data: d, encoding: .utf8) else { return nil }
        let digits = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = Int32(digits), p > 1 { return p }
        // Possibly JSON like {"pid": 123}
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let p = (o["pid"] as? Int).map(Int32.init(truncatingIfNeeded:)), p > 1 { return p }
        return nil
    }

    /// Only a process we can signal counts: LM Studio always runs as the current user, and an
    /// EPERM answer means the pid now belongs to someone else (stale lock, recycled pid).
    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Guards against a stale lock whose pid was recycled. An unreadable path is NOT accepted:
    /// a false "running" would let `lms` auto-start the headless daemon.
    private static func pathMatches(_ pid: Int32) -> Bool {
        guard let p = path(of: pid) else { return false }
        return p.contains(appMarker) || p.contains("llmster")
    }

    private static func scanForProcess() -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard got > 0 else { return nil }
        for i in 0..<Int(got) {
            let pid = pids[i]
            if pid <= 1 { continue }
            guard let p = path(of: pid) else { continue }
            if p.hasSuffix(appMarker) || p.contains("llmster") { return pid }
        }
        return nil
    }
}
