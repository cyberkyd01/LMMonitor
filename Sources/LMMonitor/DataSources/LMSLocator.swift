import Foundation

/// Finds the `lms` CLI (design §1.3).
enum LMSLocator {
    static func find(override: String?) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let o = override, !o.isEmpty { candidates.append((o as NSString).expandingTildeInPath) }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms").path)
        candidates.append("/opt/homebrew/bin/lms")
        candidates.append("/usr/local/bin/lms")
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                candidates.append(String(dir) + "/lms")
            }
        }
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }

    /// Port from LM Studio's own server config; nil when unreadable.
    static func lmStudioPortFromConfig() -> Int? {
        let cfg = Settings.lmStudioHome.appendingPathComponent(".internal/http-server-config.json")
        guard let d = try? Data(contentsOf: cfg),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = o["port"] as? Int, p > 0 else { return nil }
        return p
    }
}
