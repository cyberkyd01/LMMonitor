import Foundation
import Darwin

/// Remembers the pids of our `lms log stream` children in a small file so that, if LM Monitor is
/// killed or crashes without cleaning up, the next launch can terminate the orphans. Only a pid
/// that is still alive, has been re-parented to launchd (ppid 1) and whose executable is named
/// `lms` is ever signalled, so an unrelated process that reused the pid is never touched.
final class ChildPIDRegistry {
    static let shared = ChildPIDRegistry()

    private let lock = NSLock()
    private var pids = Set<Int32>()
    private let url = Settings.appSupportDir.appendingPathComponent("children.pids")

    func add(_ pid: Int32) {
        lock.lock(); pids.insert(pid); let snapshot = pids; lock.unlock()
        persist(snapshot)
    }

    func remove(_ pid: Int32) {
        lock.lock(); let removed = pids.remove(pid) != nil; let snapshot = pids; lock.unlock()
        if removed { persist(snapshot) }
    }

    /// Terminates orphaned children left behind by a previous run. Call once at startup,
    /// before spawning new children.
    @discardableResult
    func reapOrphans() -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var reaped = 0
        for token in text.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
            guard let pid = Int32(token), pid > 1 else { continue }
            guard Self.isOrphanedLMS(pid) else { continue }
            kill(pid, SIGTERM)
            reaped += 1
        }
        lock.lock(); let snapshot = pids; lock.unlock()
        persist(snapshot)
        return reaped
    }

    private static func isOrphanedLMS(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        guard info.pbi_ppid == 1 else { return false }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buf)).lastPathComponent == "lms"
    }

    private func persist(_ set: Set<Int32>) {
        let text = set.sorted().map(String.init).joined(separator: "\n")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
