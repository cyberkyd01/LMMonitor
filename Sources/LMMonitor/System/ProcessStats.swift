import Foundation
import Darwin

/// Per-process memory footprint / CPU time via libproc (no root needed for same-user processes).
enum ProcessStats {
    struct Usage: Equatable {
        var physFootprint: UInt64
        var cpuTimeNs: UInt64
    }

    /// PIDs whose executable path contains any of `needles`.
    static func pids(pathContainsAny needles: [String]) -> [Int32] {
        pids(groups: [needles])[0]
    }

    /// One process-table walk, several needle groups; result[i] = pids matching any needle of groups[i].
    static func pids(groups: [[String]]) -> [[Int32]] {
        var out = [[Int32]](repeating: [], count: groups.count)
        guard groups.contains(where: { !$0.isEmpty }) else { return out }
        // proc_listallpids(nil,0) returns a size hint whose unit differs across macOS versions
        // (bytes vs. count); over-allocate generously and stop at the first 0 pid / returned count.
        let hint = Int(proc_listallpids(nil, 0))
        guard hint > 0 else { return out }
        var buf = [Int32](repeating: 0, count: hint * 2 + 1024)
        let got = Int(proc_listallpids(&buf, Int32(buf.count * MemoryLayout<Int32>.size)))
        guard got > 0 else { return out }
        let n = buf.count   // unused tail is 0 and skipped below (pid <= 0)
        var path = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        for i in 0..<n {
            let pid = buf[i]
            if pid <= 0 { continue }
            let len = proc_pidpath(pid, &path, UInt32(path.count))
            if len <= 0 { continue }
            let s = String(cString: path)
            for (gi, needles) in groups.enumerated() where needles.contains(where: { s.contains($0) }) {
                out[gi].append(pid)
            }
        }
        return out
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        if tb.denom == 0 { tb.numer = 1; tb.denom = 1 }
        return tb
    }()

    static func usage(pid: Int32) -> Usage? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        // 128-bit-safe: ticks * numer may overflow only after centuries of CPU time; use multipliedFullWidth anyway.
        let tb = timebase
        let (hi, lo) = ticks.multipliedFullWidth(by: UInt64(tb.numer))
        let ns = hi == 0 ? lo / UInt64(tb.denom) : UInt64.max
        return Usage(physFootprint: info.ri_phys_footprint, cpuTimeNs: ns)
    }
}
