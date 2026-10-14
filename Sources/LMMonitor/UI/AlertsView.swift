import SwiftUI

struct AlertsView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let list = store.alerts.sorted { a, b in
            a.severity != b.severity ? a.severity > b.severity : a.lastSeen > b.lastSeen
        }
        SectionBox("Alerts", accessory: {
            if !list.isEmpty {
                Button("Acknowledge all") { store.acknowledgeAlerts() }.controlSize(.mini)
            }
        }) {
            if list.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All clear").font(.callout.weight(.medium))
                        Text("No memory, GPU, thermal or context problems detected.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().padding(.vertical, 6) }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: Palette.severityIcon(a.severity)).foregroundStyle(Palette.severity(a.severity))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(a.title).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    if a.count > 1 {
                                        Text("×\(a.count)").font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                                            .help("Number of times this alert was raised")
                                    }
                                }
                                Text(a.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("started " + Fmt.ago(a.firstSeen, now: store.now)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}
