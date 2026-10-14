import Foundation
import AppKit

/// Main-actor hub: receives events from the log streams, poller and system sampler, runs the
/// reducer / alert engine, and publishes one coherent state to SwiftUI at most every 0.5 s
/// (plus immediately on phase transitions and new records).
@MainActor
final class MetricsStore: ObservableObject {
    static let shared = MetricsStore()

    @Published private(set) var lm = LMState()
    @Published private(set) var system = SystemSnapshot()
    @Published private(set) var series = SeriesSet()
    @Published private(set) var alerts: [Alert] = []
    @Published private(set) var history: [PredictionRecord] = []
    @Published private(set) var aggregates: [ModelAggregate] = []
    @Published private(set) var fit: MemoryFitVerdict?
    @Published private(set) var now = Date()
    @Published private(set) var debugLines: [String] = []
    @Published private(set) var estimates: [String: FitEstimate] = [:]
    @Published private(set) var actionMessage: String?
    @Published private(set) var proxyRunning = false
    @Published private(set) var proxyError: String?
    @Published var popoverOpen = false {
        didSet { if popoverOpen != oldValue { updateActivity(); if popoverOpen { publishTick() } } }
    }

    let menuBar = MenuBarModel()
    let reducer = LMStateReducer()
    let alertEngine = AlertEngine()
    let notifier = Notifier()

    // Wiring (set by AppDelegate)
    var onNewRecord: ((PredictionRecord) -> Void)?
    var onEnginePID: ((Int32) -> Void)?
    var onActivityChange: ((Bool) -> Void)?      // popover open or a prediction is live → poll faster
    var onLivePredictionsChange: ((Bool) -> Void)?
    var onRequestPoll: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var lmsURLProvider: () -> URL? = { nil }

    private var timer: Timer?
    private var publishScheduled = false
    private var lastEnginePID: Int32?
    private var lastActivity = false
    private var lastLive = false
    private var settingsWork: DispatchWorkItem?
    private var actionClear: DispatchWorkItem?
    private let maxHistory = 1000

    init() {
        reducer.onRecord = { [weak self] r in self?.recordFinished(r) }
        reducer.onTransition = { [weak self] in self?.schedulePublishSoon() }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishTick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)   // keep ticking while the menu is tracking
        timer = t
    }

    // MARK: - Ingest

    func ingest(_ events: [LMEvent]) {
        for e in events {
            reducer.apply(e)
            alertEngine.note(e)
            if case .engine(_, let ctx, _) = e.kind, let pid = ctx.pid, pid != lastEnginePID {
                lastEnginePID = pid
                onEnginePID?(pid)
            }
        }
    }

    func ingest(system snap: SystemSnapshot) {
        system = snap
        let t = snap.sampledAt
        let st = reducer.state
        series.tps.add(st.aggregateTps, at: t)
        series.prefillTps.add(st.prefilling.compactMap { $0.prefillTps }.max(), at: t)
        series.cpu.add(snap.cpuPercent, at: t)
        series.cpuP.add(snap.cpuPCorePercent, at: t)
        series.cpuE.add(snap.cpuECorePercent, at: t)
        series.gpu.add(snap.gpuPercent, at: t)
        series.gpuMem.add(snap.gpuInUseBytes.map { Double($0) }, at: t)
        series.memUsed.add(snap.memUsedBytes.map { Double($0) }, at: t)
        series.swapUsed.add(snap.swapUsedBytes.map { Double($0) }, at: t)
        series.diskRead.add(snap.diskReadBps, at: t)
        series.diskWrite.add(snap.diskWriteBps, at: t)
        series.powerWatts.add(snap.power?.totalWatts, at: t)
        series.engineRSS.add(snap.engine.map { Double($0.physFootprintBytes) }, at: t)
        if Settings.menuBarMode == .tpsGPU || Settings.menuBarMode == .cpuGpuRam { menuBar.update(from: self) }
    }

    func ingest(poll p: PollResult) {
        reducer.apply(models: p.models, serverReachable: p.serverReachable, port: p.port,
                      lmStudioRunning: p.lmStudioRunning, lmsPath: p.lmsPath)
        schedulePublishSoon()
    }

    func loadHistory(_ records: [PredictionRecord]) {
        // Records finished during this launch are already in `history`; keep them on top.
        let ids = Set(history.map { $0.id })
        history = Array((history + records.filter { !ids.contains($0.id) }).prefix(maxHistory))
        aggregates = Aggregates.compute(history)
    }

    func setProxyStatus(_ running: Bool, _ error: String?) {
        proxyRunning = running
        proxyError = error
    }

    // MARK: - Publishing

    private func schedulePublishSoon() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.publishScheduled = false
                self?.publishTick()
            }
        }
    }

    private func publishTick() {
        let t = Date()
        reducer.tick(now: t)
        let st = reducer.state

        var newFit: MemoryFitVerdict? = nil
        if let m = st.primaryModel {
            let inst = st.instances.values.first { ModelKey.norm($0.model) == ModelKey.norm(m.id) }
            newFit = MemoryFit.evaluate(model: m, instance: inst, contextFit: st.lastContextFit, system: system,
                                        recentGPUOOM: alertEngine.isActive(.gpuOOM),
                                        swapGrowing: alertEngine.isActive(.swapGrowing))
        }
        alertEngine.evaluate(state: st, system: system, series: series, aggregates: aggregates, fit: newFit, now: t)

        let act = alertEngine.active
        // Continuous alerts bump `lastSeen` every evaluation; ignore that so an unchanged alert
        // list doesn't republish (and re-render) at 2 Hz forever.
        if !Self.sameAlerts(act, alerts) { alerts = act }
        if newFit != fit { fit = newFit }
        if st != lm { lm = st }
        let dl = reducer.debugLines
        if popoverOpen, dl != debugLines { debugLines = dl }
        // Elapsed timers only matter while something is visible or live.
        if popoverOpen || !st.live.isEmpty || t.timeIntervalSince(now) > 5 { now = t }

        menuBar.update(from: self)

        let raised = alertEngine.drainNewlyRaised()
        if !raised.isEmpty { notifier.notify(raised, popoverOpen: popoverOpen) }
        updateActivity()
    }

    private static func sameAlerts(_ a: [Alert], _ b: [Alert]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.severity == $1.severity && $0.count == $1.count
                && $0.title == $1.title && $0.detail == $1.detail && $0.firstSeen == $1.firstSeen
        }
    }

    private func updateActivity() {
        let live = !reducer.state.live.isEmpty
        if live != lastLive {
            lastLive = live
            onLivePredictionsChange?(live)
        }
        let active = popoverOpen || live
        if active != lastActivity {
            lastActivity = active
            onActivityChange?(active)
        }
    }

    private func recordFinished(_ r: PredictionRecord) {
        history.insert(r, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        aggregates = Aggregates.compute(history)
        onNewRecord?(r)
        schedulePublishSoon()
    }

    // MARK: - Derived

    var endpointURL: String {
        let host = Settings.lmStudioHost == "127.0.0.1" ? "localhost" : Settings.lmStudioHost
        if Settings.proxyEnabled { return "http://localhost:\(Settings.proxyPort)/v1" }
        return "http://\(host):\(lm.serverPort)/v1"
    }

    var lastRecordForDisplay: PredictionRecord? { lm.lastRecord ?? history.first }

    // MARK: - Actions

    func unloadModel(_ identifier: String) {
        flash("Unloading \(identifier)…")
        LMActions.unload(identifier: identifier, lms: lmsURLProvider()) { [weak self] result in
            switch result {
            case .success: self?.flash("Unloaded \(identifier)")
            case .failure(let e): self?.flash("Unload failed: \(e.localizedDescription)")
            }
            self?.onRequestPoll?()
        }
    }

    func startServer() {
        flash("Starting LM Studio server…")
        LMActions.startServer(lms: lmsURLProvider()) { [weak self] result in
            switch result {
            case .success: self?.flash("Server started")
            case .failure(let e): self?.flash("Could not start server: \(e.localizedDescription)")
            }
            self?.onRequestPoll?()
        }
    }

    func openLMStudio() { LMActions.openLMStudio() }

    func estimateFit(modelKey: String) {
        flash("Estimating memory for \(modelKey)…")
        LMActions.estimateFit(modelKey: modelKey, lms: lmsURLProvider()) { [weak self] est in
            guard let self else { return }
            if let est {
                self.estimates[modelKey] = est
                self.flash(nil)
            } else {
                self.flash("Estimate failed for \(modelKey)")
            }
        }
    }

    func exportCSV() {
        let csv = LMActions.exportCSV(history)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = dir.appendingPathComponent("LMMonitor-history-\(f.string(from: Date())).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            flash("Exported \(history.count) records to Downloads")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
        flash("Copied \(endpointURL)")
    }

    func acknowledgeAlerts() {
        alertEngine.acknowledgeAll()
        alerts = alertEngine.active
    }

    func resetSession() {
        reducer.resetLive()
        series = SeriesSet()
        publishTick()
        flash("Session reset")
    }

    func clearHistory() {
        history = []
        aggregates = []
        onClearHistory?()
        flash("History cleared")
    }

    /// Coalesced: text fields and sliders call this on every keystroke/step, so components are
    /// reconfigured once, 0.5 s after the last change.
    func settingsChanged() {
        settingsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: Settings.changed, object: nil)
                self?.publishTick()
            }
        }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        menuBar.update(from: self)      // display-mode changes show immediately
    }

    func setNotificationsEnabled(_ on: Bool) {
        Settings.notificationsEnabled = on
        guard on else { return }
        guard Notifier.isAvailable else {
            flash("Notifications need the installed app (dist/LMMonitor.app)")
            return
        }
        notifier.requestAuthorizationIfNeeded { granted in
            if !granted {
                MetricsStore.shared.flash("Notifications are blocked — allow LM Monitor in System Settings → Notifications")
            }
        }
    }

    /// Shows a transient message in the popover (auto-clears after 6 s). nil clears immediately.
    func flash(_ message: String?) {
        actionMessage = message
        actionClear?.cancel()
        guard message != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.actionMessage = nil }
        }
        actionClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}
