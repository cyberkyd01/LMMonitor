import SwiftUI
import AppKit

enum PopoverTab: String, CaseIterable, Identifiable {
    case overview = "Overview", system = "System", history = "History", alerts = "Alerts"
    var id: String { rawValue }
}

/// The content of one tab (also used by the offline renderer).
struct TabContentView: View {
    var tab: PopoverTab
    var body: some View {
        VStack(spacing: 12) {
            switch tab {
            case .overview:
                LastPredictionCardView(); ContextMeterView(); ModelCardView()
            case .system:
                SystemCardView(); SparklinesView()
            case .history:
                HistoryView()
            case .alerts:
                AlertsView()
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ContentView: View {
    @ObservedObject var store: MetricsStore
    @State private var tab: PopoverTab = .overview
    @State private var overlay: Overlay? = nil
    @State private var contentHeight: CGFloat = 300

    enum Overlay { case settings, debug }

    init(store: MetricsStore) { self.store = store }
    @MainActor init() { self.store = MetricsStore.shared }

    var body: some View {
        VStack(spacing: 10) {
            HeaderView()
            LiveCardView()
            VitalsStripView()
            if overlay == nil {
                Picker("", selection: $tab) {
                    ForEach(PopoverTab.allCases) { t in
                        Text(t == .alerts && !store.alerts.isEmpty ? "Alerts (\(store.alerts.count))" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            ScrollView {
                Group {
                    switch overlay {
                    case .settings: SettingsView()
                    case .debug: DebugView()
                    case nil: TabContentView(tab: tab)
                    }
                }
                .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 40), maxScrollHeight))
            if let msg = store.actionMessage {
                Text(msg).font(.caption).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                    .transition(.opacity)
            }
            footer
        }
        .padding(12)
        .frame(width: 400)
        .environmentObject(store)
        .animation(.easeInOut(duration: 0.15), value: store.actionMessage)
        .background(WindowVisibilityObserver { visible in
            if store.popoverOpen != visible { store.popoverOpen = visible }
        })
        .onAppear { store.popoverOpen = true }
        .onDisappear { store.popoverOpen = false }
    }

    /// Tab area height cap: what's left of the screen after the always-visible header, live card,
    /// vitals strip and footer (~560 pt worst case), so the popover never runs off a 14" display.
    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(240, min(560, screen - 560))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { store.copyEndpoint() } label: {
                Label(store.endpointURL, systemImage: "doc.on.doc").lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            .help("Copy the API endpoint")
            Spacer(minLength: 0)
            Button { overlay = overlay == .settings ? nil : .settings } label: {
                Image(systemName: "gearshape\(overlay == .settings ? ".fill" : "")")
            }.help("Settings")
            Button { overlay = overlay == .debug ? nil : .debug } label: {
                Image(systemName: "ladybug\(overlay == .debug ? ".fill" : "")")
            }.help("Debug info")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit LM Monitor")
        }
        .buttonStyle(.borderless)
        .padding(.top, 2)
    }
}

/// Reports whether the hosting window is actually on screen. MenuBarExtra(.window) hides its panel
/// instead of tearing the view down, so `.onDisappear` alone is not reliable for "popover closed".
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }
    func updateNSView(_ v: ObserverView, context: Context) { v.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let w = window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak self, weak w] _ in
                MainActor.assumeIsolated {
                    guard let w else { return }
                    self?.onChange?(w.occlusionState.contains(.visible))
                }
            }
            // Not during the view update that attached us.
            DispatchQueue.main.async { [weak self, weak w] in
                MainActor.assumeIsolated {
                    guard let w else { return }
                    self?.onChange?(w.occlusionState.contains(.visible))
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
