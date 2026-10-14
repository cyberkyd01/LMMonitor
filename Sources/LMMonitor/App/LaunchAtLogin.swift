import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService.mainApp. Works only when running from a .app bundle
/// (ideally in /Applications); every call is guarded so a bare binary never crashes.
@MainActor
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Human-readable status for the Settings view.
    static var status: String {
        guard isAvailable else { return "Unavailable (not running from the .app)" }
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Needs approval in System Settings → Login Items"
        case .notFound: return "Unavailable (move LM Monitor to /Applications)"
        @unknown default: return "Unknown"
        }
    }

    static var requiresApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ on: Bool) throws {
        guard isAvailable else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
