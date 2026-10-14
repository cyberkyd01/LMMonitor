import Foundation
import UserNotifications

/// macOS notifications for important alerts. Only used when running from a real .app bundle
/// (UNUserNotificationCenter crashes in a bare executable), rate-limited per rule.
@MainActor
final class Notifier {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var lastSent: [AlertRule: Date] = [:]
    private let launchedAt = Date()
    private(set) var authorized: Bool? = nil

    /// Minimum gap between two notifications for the same rule.
    var perRuleInterval: TimeInterval = 600

    func requestAuthorizationIfNeeded(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard Self.isAvailable else { completion?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            hopToMain { [weak self] in
                self?.authorized = granted
                completion?(granted)
            }
        }
    }

    /// Sends notifications for newly raised alerts that pass the user's filters.
    func notify(_ alerts: [Alert], popoverOpen: Bool) {
        guard Self.isAvailable, Settings.notificationsEnabled, !popoverOpen else { return }
        let now = Date()
        guard now.timeIntervalSince(launchedAt) > 30 else { return }   // no burst on launch
        let rules = Settings.notifyRules
        for a in alerts where a.severity >= .warning && rules.contains(a.rule) {
            if let last = lastSent[a.rule], now.timeIntervalSince(last) < perRuleInterval { continue }
            lastSent[a.rule] = now
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.detail
            if a.severity == .critical { content.sound = .default }
            let req = UNNotificationRequest(identifier: "lmmonitor.\(a.id).\(Int(now.timeIntervalSince1970))",
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }
}
