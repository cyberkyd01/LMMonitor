import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: MetricsStore

    @AppStorage(Settings.Key.menuBarMode) private var modeRaw: String = MenuBarMode.tps.rawValue
    @AppStorage(Settings.Key.sampleInterval) private var interval: Double = 1.0
    @AppStorage(Settings.Key.notificationsEnabled) private var notifications: Bool = false
    @AppStorage(Settings.Key.lmsPathOverride) private var lmsOverride: String = ""
    @AppStorage(Settings.Key.pollLmsPs) private var pollPs: Bool = true
    @AppStorage(Settings.Key.lmStudioHost) private var host: String = "127.0.0.1"
    @AppStorage(Settings.Key.lmStudioPort) private var port: Int = 0
    @AppStorage(Settings.Key.proxyEnabled) private var proxyOn: Bool = false
    @AppStorage(Settings.Key.proxyPort) private var proxyPort: Int = 1235
    @AppStorage(Settings.Key.injectUsage) private var injectUsage: Bool = true
    @AppStorage(Settings.Key.persistHistory) private var persist: Bool = true
    @AppStorage(Settings.Key.runawayMinutes) private var runMin: Int = 15
    @AppStorage(Settings.Key.runawayTokens) private var runTok: Int = 20_000
    @AppStorage(Settings.Key.contextWarnFraction) private var ctxWarn: Double = 0.85

    @State private var launchOn = false
    @State private var launchStatus = ""
    @State private var launchError: String?
    @State private var rules: Set<AlertRule> = []
    @State private var showRules = false
    @State private var clearArmedUntil: Date?

    /// Binding that also tells the store the settings changed.
    private func b<T>(_ base: Binding<T>) -> Binding<T> {
        Binding(get: { base.wrappedValue }, set: { base.wrappedValue = $0; store.settingsChanged() })
    }

    var body: some View {
        VStack(spacing: 12) {
            SectionBox("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at login", isOn: Binding(get: { launchOn }, set: { on in
                        do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = error.localizedDescription }
                        launchOn = LaunchAtLogin.isEnabled; launchStatus = LaunchAtLogin.status
                    })).disabled(!LaunchAtLogin.isAvailable)
                    HStack {
                        Text(launchError ?? launchStatus).font(.caption2).foregroundStyle(launchError == nil ? Color.secondary : Color.red)
                        Spacer()
                        if LaunchAtLogin.requiresApproval { Button("Open Login Items") { LaunchAtLogin.openSettings() }.controlSize(.mini) }
                    }
                    Picker("Menu bar shows", selection: b($modeRaw)) {
                        ForEach(MenuBarMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Sample interval", selection: b($interval)) {
                        Text("1 s").tag(1.0); Text("2 s").tag(2.0)
                    }.pickerStyle(.segmented)
                    Toggle("Keep history between launches", isOn: b($persist))
                }
            }
            SectionBox("Notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Notify about problems", isOn: Binding(get: { notifications }, set: { store.setNotificationsEnabled($0); notifications = $0 }))
                        .help("Posts a macOS notification for warnings and critical alerts while the popover is closed")
                    DisclosureGroup("Alert rules", isExpanded: $showRules) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(AlertRule.allCases, id: \.self) { rule in
                                Toggle(rule.uiLabel, isOn: Binding(get: { rules.contains(rule) }, set: { on in
                                    if on { rules.insert(rule) } else { rules.remove(rule) }
                                    Settings.notifyRules = rules; store.settingsChanged()
                                }))
                            }
                        }.padding(.top, 4)
                    }.font(.caption)
                }
            }
            SectionBox("LM Studio") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Host").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        TextField("127.0.0.1", text: b($host)).textFieldStyle(.roundedBorder)
                        Text("Port").font(.caption).foregroundStyle(.secondary)
                        TextField("auto", value: b($port), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 64)
                    }
                    Text("Port 0 = read it from LM Studio's own settings.").font(.caption2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("lms path").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            TextField("override (optional)", text: b($lmsOverride)).textFieldStyle(.roundedBorder)
                        }
                        Text("Detected: \(store.lm.lmsPath ?? "not found")").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).padding(.leading, 56)
                    }
                    Toggle("Poll loaded models (lms ps)", isOn: b($pollPs))
                }
            }
            SectionBox("Proxy") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Measure through a local proxy", isOn: b($proxyOn))
                        .help("Point your apps at the proxy port to see exact timings for every request")
                    if proxyOn {
                        HStack {
                            Text("Port").font(.caption).foregroundStyle(.secondary)
                            TextField("1235", value: b($proxyPort), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 70)
                            Spacer()
                            Text(store.proxyRunning ? "running" : (store.proxyError ?? "stopped")).font(.caption2)
                                .foregroundStyle(store.proxyRunning ? Color.green : Color.orange)
                        }
                        Toggle("Ask for usage stats in streams", isOn: b($injectUsage))
                    }
                }
            }
            SectionBox("Alert thresholds") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Runaway after").font(.caption)
                        TextField("", value: b($runMin), format: .number).textFieldStyle(.roundedBorder).frame(width: 52)
                        Text("min or").font(.caption)
                        TextField("", value: b($runTok), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 68)
                        Text("tokens").font(.caption)
                    }
                    HStack {
                        Text("Context warning at").font(.caption)
                        Slider(value: b($ctxWarn), in: 0.5...0.99, step: 0.01)
                        Text(String(format: "%.0f%%", ctxWarn * 100)).font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
            }
            SectionBox("Data") {
                HStack {
                    Button("Reset session") { store.resetSession() }
                        .help("Clears live state and graphs; keeps saved history")
                    let armed = clearArmedUntil.map { $0 > store.now } ?? false
                    Button(armed ? "Confirm clear?" : "Clear history…", role: .destructive) {
                        if armed { clearArmedUntil = nil; store.clearHistory() }
                        else { clearArmedUntil = Date().addingTimeInterval(4) }
                    }
                    .foregroundStyle(armed ? Color.red : Color.primary)
                    .help("Also deletes the saved history file. Click twice to confirm.")
                    Spacer()
                }.controlSize(.small)
            }
        }
        .onAppear { launchOn = LaunchAtLogin.isEnabled; launchStatus = LaunchAtLogin.status; rules = Settings.notifyRules }
    }
}
