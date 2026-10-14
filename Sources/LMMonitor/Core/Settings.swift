import Foundation

enum MenuBarMode: String, CaseIterable, Codable {
    case tps, tpsGPU, iconOnly, cpuGpuRam
    var label: String {
        switch self {
        case .tps: return "tok/s"
        case .tpsGPU: return "tok/s + GPU"
        case .iconOnly: return "Icon only"
        case .cpuGpuRam: return "CPU / GPU / RAM"
        }
    }
}

enum Settings {
    static let defaults = UserDefaults.standard
    static let changed = Notification.Name("LMMonitor.settingsChanged")

    enum Key {
        static let lmStudioHost = "lmStudioHost", lmStudioPort = "lmStudioPort"
        static let proxyEnabled = "proxyEnabled", proxyPort = "proxyPort", injectUsage = "injectUsage"
        static let lmsPathOverride = "lmsPathOverride", pollLmsPs = "pollLmsPs"
        static let menuBarMode = "menuBarMode", sampleInterval = "sampleInterval"
        static let notificationsEnabled = "notificationsEnabled", notifyRules = "notifyRules"
        static let persistHistory = "persistHistory"
        static let runawayMinutes = "runawayMinutes", runawayTokens = "runawayTokens"
        static let contextWarnFraction = "contextWarnFraction"
        static let showDebug = "showDebug"
    }

    static var lmStudioHost: String {
        get { defaults.string(forKey: Key.lmStudioHost) ?? "127.0.0.1" }
        set { defaults.set(newValue, forKey: Key.lmStudioHost) }
    }
    /// 0 = auto-discover from ~/.lmstudio/.internal/http-server-config.json
    static var lmStudioPort: Int {
        get { defaults.integer(forKey: Key.lmStudioPort) }
        set { defaults.set(newValue, forKey: Key.lmStudioPort) }
    }
    static var proxyEnabled: Bool {
        get { defaults.object(forKey: Key.proxyEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.proxyEnabled) }
    }
    static var proxyPort: Int {
        get { let v = defaults.integer(forKey: Key.proxyPort); return v == 0 ? 1235 : v }
        set { defaults.set(newValue, forKey: Key.proxyPort) }
    }
    static var injectUsage: Bool {
        get { defaults.object(forKey: Key.injectUsage) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.injectUsage) }
    }
    static var lmsPathOverride: String? {
        get { let s = defaults.string(forKey: Key.lmsPathOverride); return (s?.isEmpty ?? true) ? nil : s }
        set { defaults.set(newValue, forKey: Key.lmsPathOverride) }
    }
    static var pollLmsPs: Bool {
        get { defaults.object(forKey: Key.pollLmsPs) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.pollLmsPs) }
    }
    static var menuBarMode: MenuBarMode {
        get { MenuBarMode(rawValue: defaults.string(forKey: Key.menuBarMode) ?? "") ?? .tps }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarMode) }
    }
    /// System sampling interval in seconds (1.0 or 2.0).
    static var sampleInterval: Double {
        get { let v = defaults.double(forKey: Key.sampleInterval); return v == 0 ? 1.0 : v }
        set { defaults.set(newValue, forKey: Key.sampleInterval) }
    }
    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }
    static var notifyRules: Set<AlertRule> {
        get {
            if let arr = defaults.stringArray(forKey: Key.notifyRules) { return Set(arr.compactMap(AlertRule.init(rawValue:))) }
            return Set(AlertRule.allCases.filter { $0.defaultNotify })
        }
        set { defaults.set(newValue.map { $0.rawValue }.sorted(), forKey: Key.notifyRules) }
    }
    static var persistHistory: Bool {
        get { defaults.object(forKey: Key.persistHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.persistHistory) }
    }
    static var runawayMinutes: Int {
        get { let v = defaults.integer(forKey: Key.runawayMinutes); return v == 0 ? 15 : v }
        set { defaults.set(newValue, forKey: Key.runawayMinutes) }
    }
    static var runawayTokens: Int {
        get { let v = defaults.integer(forKey: Key.runawayTokens); return v == 0 ? 20_000 : v }
        set { defaults.set(newValue, forKey: Key.runawayTokens) }
    }
    static var contextWarnFraction: Double {
        get { let v = defaults.double(forKey: Key.contextWarnFraction); return v == 0 ? 0.85 : v }
        set { defaults.set(newValue, forKey: Key.contextWarnFraction) }
    }
    static var showDebug: Bool {
        get { defaults.bool(forKey: Key.showDebug) }
        set { defaults.set(newValue, forKey: Key.showDebug) }
    }

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LMMonitor", isDirectory: true)
    }
    /// Port actually used: explicit setting, else LM Studio's own server config, else 1234.
    static var resolvedLMStudioPort: Int {
        if lmStudioPort > 0 { return lmStudioPort }
        let cfg = lmStudioHome.appendingPathComponent(".internal/http-server-config.json")
        if let d = try? Data(contentsOf: cfg),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let p = o["port"] as? Int, p > 0 { return p }
        return 1234
    }
    static var lmStudioBaseURL: URL { URL(string: "http://\(lmStudioHost):\(resolvedLMStudioPort)")! }
    static var lmStudioHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio") }
}
