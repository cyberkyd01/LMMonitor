import SwiftUI

/// What the menu bar item shows. Kept separate from MetricsStore so the status item only
/// re-renders when its icon or text actually changes (the store publishes at 1–2 Hz).
@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var icon = "gauge.medium"
    @Published private(set) var text = ""

    func update(from store: MetricsStore) {
        let (i, t) = Self.compute(lm: store.lm, system: store.system, alerts: store.alerts,
                                  lastRecord: store.lastRecordForDisplay, mode: Settings.menuBarMode)
        if i != icon { icon = i }
        if t != text { text = t }
    }

    static func compute(lm: LMState, system: SystemSnapshot, alerts: [Alert],
                        lastRecord: PredictionRecord?, mode: MenuBarMode) -> (icon: String, text: String) {
        let icon: String
        if alerts.contains(where: { $0.severity == .critical }) { icon = "exclamationmark.triangle.fill" }
        else if !lm.lmStudioRunning { icon = "moon.zzz" }
        else if lm.lmsPath == nil && lm.degradedReason != nil { icon = "questionmark.circle" }
        else if !lm.generating.isEmpty { icon = "bolt.fill" }
        else if !lm.prefilling.isEmpty { icon = "hourglass" }
        else { icon = "gauge.medium" }

        func tpsText() -> String {
            if !lm.lmStudioRunning { return "off" }
            if let t = lm.aggregateTps { return Fmt.fixed(t, width: 5, decimals: 1) + " t/s" }
            if let p = lm.prefilling.first?.progress { return Fmt.fixed(p * 100, width: 3, decimals: 0) + "%" }
            if let t = lastRecord?.tokensPerSecond { return Fmt.fixed(t, width: 5, decimals: 1) + " t/s" }
            return Fmt.fixed(0, width: 5, decimals: 1) + " t/s"
        }

        let text: String
        switch mode {
        case .iconOnly: text = ""
        case .tps: text = tpsText()
        case .tpsGPU:
            text = tpsText() + " · " + Fmt.fixed(system.gpuPercent ?? 0, width: 3, decimals: 0) + "%"
        case .cpuGpuRam:
            let ram = Double(system.memUsedBytes ?? 0) / 1_073_741_824
            text = "C " + Fmt.fixed(system.cpuPercent ?? 0, width: 2, decimals: 0)
                + " · G " + Fmt.fixed(system.gpuPercent ?? 0, width: 2, decimals: 0)
                + " · " + Fmt.fixed(ram, width: 2, decimals: 0) + "G"
        }
        return (icon, text)
    }
}

/// Menu bar item. MenuBarExtra labels render only an Image and a Text, so no colors here.
struct MenuBarLabel: View {
    let store: MetricsStore          // deliberately not observed — see MenuBarModel
    var body: some View { MenuBarLabelContent(model: store.menuBar) }
}

private struct MenuBarLabelContent: View {
    @ObservedObject var model: MenuBarModel
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.icon)
            if !model.text.isEmpty { Text(model.text).monospacedDigit() }
        }
    }
}
