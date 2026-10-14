import SwiftUI
import AppKit

/// Owns the background components and wires them to the MetricsStore.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: LMSProcessSupervisor?
    private var poller: LMStudioPoller?
    private var sampler: SystemSampler?
    private var proxy: ProxyServer?
    private let historyStore = HistoryStore()
    private var settingsObserver: NSObjectProtocol?
    /// Last applied values, so a settings change only restarts what it affects.
    private struct Applied: Equatable {
        var sampleInterval = Settings.sampleInterval
        var lmsPathOverride = Settings.lmsPathOverride
        var host = Settings.lmStudioHost
        var port = Settings.lmStudioPort
        var pollLmsPs = Settings.pollLmsPs
        var proxyEnabled = Settings.proxyEnabled
        var proxyPort = Settings.proxyPort
        var injectUsage = Settings.injectUsage
        init() {}
    }
    private var applied = Applied()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = MetricsStore.shared

        let sup = LMSProcessSupervisor(sink: { events in MetricsStore.shared.ingest(events) })
        let pol = LMStudioPoller(lmsURL: { sup.lmsURL }, sink: { result in MetricsStore.shared.ingest(poll: result) })
        let power = PowerSampler()
        let smp = SystemSampler(power: power.isAvailable ? power : nil,
                                sink: { snap in MetricsStore.shared.ingest(system: snap) })
        supervisor = sup
        poller = pol
        sampler = smp

        let history = historyStore
        store.lmsURLProvider = { sup.lmsURL }
        store.onEnginePID = { pid in smp.setEnginePID(pid) }
        store.onActivityChange = { active in pol.setActive(active) }
        store.onLivePredictionsChange = { live in sup.setLivePredictions(live) }
        store.onRequestPoll = { pol.pollNow() }
        store.onNewRecord = { r in if Settings.persistHistory { history.append(r) } }
        store.onClearHistory = { history.clear() }
        store.start()

        if Settings.persistHistory {
            history.load(limit: 1000) { records in MetricsStore.shared.loadHistory(records) }
        }

        smp.start(interval: Settings.sampleInterval)
        pol.start()
        sup.start()
        applyProxySetting()

        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        }
        // `kill`/`pkill` (SIGTERM), Ctrl-C (SIGINT) and SIGHUP skip applicationWillTerminate, which
        // would orphan the `lms log stream` children — stop them, then exit.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stopAll() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        // No willPowerOff handler: if the user cancels a logout we'd be left stopped.
        // applicationWillTerminate runs on a real logout/shutdown.
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAll()
    }

    private func stopAll() {
        supervisor?.stop()
        poller?.stop()
        sampler?.stop()
        proxy?.stop()
    }

    private func settingsDidChange() {
        let new = Applied()
        let old = applied
        applied = new
        if new.lmsPathOverride != old.lmsPathOverride { supervisor?.reconfigure() }
        if new.sampleInterval != old.sampleInterval { sampler?.start(interval: new.sampleInterval) }
        if (new.proxyEnabled, new.proxyPort, new.injectUsage) != (old.proxyEnabled, old.proxyPort, old.injectUsage) {
            applyProxySetting()
        }
        if (new.host, new.port, new.pollLmsPs, new.lmsPathOverride) != (old.host, old.port, old.pollLmsPs, old.lmsPathOverride) {
            poller?.pollNow()
        }
    }

    private func applyProxySetting() {
        if Settings.proxyEnabled {
            if proxy == nil {
                proxy = ProxyServer(sink: { events in MetricsStore.shared.ingest(events) },
                                    onStatus: { running, error in MetricsStore.shared.setProxyStatus(running, error) })
            }
            proxy?.start(port: UInt16(clamping: Settings.proxyPort))
        } else if let p = proxy {
            p.stop()
            proxy = nil
            MetricsStore.shared.setProxyStatus(false, nil)
        }
    }
}

/// Entry point is main.swift (so `--selftest` can run without starting the UI).
struct LMMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Not a @StateObject on purpose: observing the store here would re-evaluate the whole
    /// MenuBarExtra scene (and re-render the status item) on every 1–2 Hz publish.
    private let store = MetricsStore.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
