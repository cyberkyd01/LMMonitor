import SwiftUI

struct ContextMeterView: View {
    @EnvironmentObject var store: MetricsStore

    private struct SlotUse: Identifiable { var id: String; var slot: Int; var tokens: Int; var live: Bool }

    private var instance: EngineInstance? {
        let lm = store.lm
        if let m = lm.primaryModel {
            let n = ModelKey.norm(m.id)
            if let i = lm.instances.values.first(where: { ModelKey.norm($0.model) == n }) { return i }
        }
        return lm.instances.values.sorted { $0.lastSeen > $1.lastSeen }.first
    }

    private func slotUses(_ inst: EngineInstance?, _ liveSlots: [LivePrediction]) -> [SlotUse] {
        var uses: [SlotUse] = liveSlots.compactMap { p in
            p.contextTokensEstimate.map { SlotUse(id: "\(p.key.instance)#\(p.key.slot)", slot: p.key.slot, tokens: $0, live: true) }
        }
        let liveIDs = Set(liveSlots.map { $0.key.slot })  // already restricted to this instance
        for (slot, n) in inst?.slotLastNTokens ?? [:] where !liveIDs.contains(slot) && n > 0 {
            uses.append(SlotUse(id: "\(inst?.id ?? "")#\(slot)", slot: slot, tokens: n, live: false))
        }
        return uses
    }

    var body: some View {
        let lm = store.lm
        let inst = instance
        let limit = inst?.nCtxSlot ?? lm.primaryModel?.loadedContextLength ?? lm.primaryModel?.maxContextLength
        let liveSlots = lm.live.filter { !$0.isChild && (inst == nil || $0.key.instance == inst!.id) }
        let uses = slotUses(inst, liveSlots)
        let sorted = uses.sorted { ($0.slot, $0.id) < ($1.slot, $1.id) }
        let used = sorted.reduce(0) { $0 + $1.tokens }
        let truncated = (store.lastRecordForDisplay?.truncated ?? false) || liveSlots.contains { $0.final.truncated == true }

        SectionBox("Context", accessory: {
            if truncated { Chip(text: "truncated", color: .orange, symbol: "scissors").help("The context window was full, so the oldest text was dropped") }
        }) {
            if let limit, limit > 0, !sorted.isEmpty {
                let frac = Double(used) / Double(limit)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("In use").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Fmt.int(used)) / \(Fmt.int(limit)) tokens").font(.caption).monospacedDigit()
                        Text(String(format: "%.0f%%", frac * 100)).font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(frac >= 0.85 ? Palette.level(frac, warn: 0.85, crit: 0.95) : .primary)
                    }
                    .help("Tokens held in the context window across slots, compared with the window size")
                    Meter(value: frac, color: Palette.level(frac, warn: 0.85, crit: 0.95), height: 6)
                    if sorted.count > 1 {
                        VStack(spacing: 4) {
                            ForEach(sorted) { u in
                                HStack(spacing: 6) {
                                    Text(u.slot >= 0 ? "slot \(u.slot)" : "request").font(.caption2).foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                    Meter(value: Double(u.tokens) / Double(limit), color: u.live ? .accentColor : .gray, height: 4)
                                    Text(Fmt.int(u.tokens)).font(.caption2).monospacedDigit().frame(width: 52, alignment: .trailing)
                                    Image(systemName: u.live ? "circle.fill" : "circle").font(.system(size: 5))
                                        .foregroundStyle(u.live ? .green : .secondary)
                                        .help(u.live ? "Active" : "Idle: its cached tokens are still held in memory")
                                }
                            }
                        }
                    }
                }
            } else if let limit, limit > 0 {
                Text("Window \(Fmt.int(limit)) tokens · empty").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No context data yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
