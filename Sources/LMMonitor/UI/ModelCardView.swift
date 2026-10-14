import SwiftUI

struct ModelCardView: View {
    @EnvironmentObject var store: MetricsStore
    @State private var unloadArmedUntil: Date?
    @State private var showDisk = false

    private var onDisk: [ModelInfo] {
        store.lm.models.filter { !$0.isLoaded }.sorted { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }
    }

    var body: some View {
        let lm = store.lm
        SectionBox("Model") {
            VStack(alignment: .leading, spacing: 8) {
                if let m = lm.primaryModel { loaded(m) } else {
                    HStack(spacing: 6) {
                        Image(systemName: "cube").foregroundStyle(.secondary)
                        Text(lm.lmStudioRunning ? "No model loaded" : "LM Studio is not running").font(.callout).foregroundStyle(.secondary)
                    }
                }
                actions(lm.primaryModel)
                if !onDisk.isEmpty { disk }
            }
        }
    }

    @ViewBuilder private func loaded(_ m: ModelInfo) -> some View {
        let lm = store.lm
        let inst = lm.instances.values.first { ModelKey.norm($0.model) == ModelKey.norm(m.id) }
        VStack(alignment: .leading, spacing: 2) {
            Text(m.displayName ?? shortModelName(m.id)).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(m.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        HStack(spacing: 4) {
            if let v = m.architecture { Tag(text: v) }
            if let q = m.quantization { Tag(text: m.bitsPerWeight.map { "\(q) · \(String(format: "%.1f", $0)) bpw" } ?? q).help("Quantization (and bits per weight)") }
            if let p = m.paramsString { Tag(text: p).help("Parameter count") }
            if let f = m.format { Tag(text: f) }
            if m.vision == true { Tag(text: "vision", symbol: "eye") }
            if m.toolUse == true { Tag(text: "tools", symbol: "wrench.and.screwdriver") }
            Spacer(minLength: 0)
        }
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3)
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            if let s = m.sizeBytes { StatCell(label: "Size on disk", value: Fmt.gib(s), help: "Weights file size. Memory use is higher once the context cache is added.") }
            if let c = m.loadedContextLength ?? inst?.nCtxSlot {
                StatCell(label: "Context", value: m.maxContextLength.map { "\(Fmt.tokens(c)) / \(Fmt.tokens($0))" } ?? Fmt.tokens(c),
                         help: "Loaded context length / the model's maximum")
            }
            if let p = m.parallel ?? inst?.nSlots { StatCell(label: "Parallel", value: "\(p) slots", help: "How many requests can be processed at once") }
            if let e = inst?.engineName {
                StatCell(label: "Engine", value: (e.components(separatedBy: "-mac").first ?? e) + (inst?.engineVersion.map { " v\($0)" } ?? ""), help: e)
            }
            if let ttl = m.ttlMs, ttl > 0 {
                let left = m.lastUsedTime.map { $0.addingTimeInterval(Double(ttl) / 1000).timeIntervalSince(store.now) }
                StatCell(label: "Auto-unload", value: left.map { $0 > 0 ? "in " + Fmt.duration($0) : "now" } ?? Fmt.duration(Double(ttl) / 1000),
                         help: "Idle time-to-live: LM Studio unloads the model after this much inactivity")
            }
            if let st = m.status { StatCell(label: "Status", value: st, help: "Status reported by LM Studio") }
            if let q = m.queued, q > 0 { StatCell(label: "Queued", value: "\(q) requests", color: .orange) }
            if let mtp = m.speculativeDraftMTP { StatCell(label: "Speculative", value: mtp ? "MTP on" : "off", help: "Speculative decoding with a draft model/MTP head") }
        }
        if let v = store.fit { fitRow(v) }
    }

    private func fitRow(_ v: MemoryFitVerdict) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: Palette.fitIcon(v.level)).foregroundStyle(Palette.fit(v.level))
            VStack(alignment: .leading, spacing: 1) {
                Text(Palette.fitLabel(v.level) + (v.isEstimate ? " (estimate)" : "")).font(.caption.weight(.semibold)).foregroundStyle(Palette.fit(v.level))
                Text(v.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.fit(v.level).opacity(0.1)))
        .help("Compares the model's memory footprint with the GPU budget (the most memory macOS lets the GPU wire on Apple Silicon)")
    }

    private func actions(_ m: ModelInfo?) -> some View {
        HStack(spacing: 6) {
            if m != nil {
                let armed = unloadArmedUntil.map { $0 > store.now } ?? false
                Button {
                    if armed {
                        unloadArmedUntil = nil
                        store.unloadModel(m!.id)
                    } else {
                        unloadArmedUntil = Date().addingTimeInterval(4)
                    }
                } label: {
                    Label(armed ? "Confirm unload?" : "Unload", systemImage: "eject")
                        .foregroundStyle(armed ? Color.red : Color.primary)
                }
                .help("Unloads the model; any generation in progress will be interrupted. Click twice to confirm.")
            }
            Button { store.openLMStudio() } label: { Label("Open LM Studio", systemImage: "arrow.up.forward.app") }
            if !store.lm.serverReachable && store.lm.lmStudioRunning {
                Button { store.startServer() } label: { Label("Start server", systemImage: "play.fill") }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private var disk: some View {
        DisclosureGroup(isExpanded: $showDisk) {
            VStack(spacing: 6) {
                ForEach(onDisk) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(m.displayName ?? shortModelName(m.id)).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Fmt.gib(m.sizeBytes)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            Button("Estimate fit") { store.estimateFit(modelKey: m.id) }
                                .controlSize(.mini)
                                .help("Runs LM Studio's own estimate of the memory this model needs (does not load it)")
                        }
                        if let e = store.estimates[m.id] {
                            VStack(alignment: .leading, spacing: 1) {
                                Text([e.gpuBytes.map { "GPU \(Fmt.gib($0))" }, e.totalBytes.map { "total \(Fmt.gib($0))" }, e.confidence.map { "confidence \($0)" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                if let v = e.verdict { Text(v).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("On disk (\(onDisk.count))").font(.caption).foregroundStyle(.secondary)
        }
    }
}
