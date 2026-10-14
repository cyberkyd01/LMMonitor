import SwiftUI

struct LiveCardView: View {
    @EnvironmentObject var store: MetricsStore

    private func phaseColor(_ p: PredictionPhase) -> Color {
        switch p {
        case .generating: return .green
        case .prefilling, .queued: return .orange
        case .finishing: return .blue
        case .errored: return .red
        default: return .gray
        }
    }

    private func phaseName(_ p: PredictionPhase) -> String {
        switch p {
        case .queued: return "queued"
        case .prefilling: return "prefilling"
        case .generating: return "generating"
        case .finishing: return "finishing"
        case .finished: return "done"
        case .errored: return "error"
        case .cancelled: return "cancelled"
        }
    }

    var body: some View {
        let lm = store.lm
        let gen = lm.generating
        let pre = lm.prefilling
        let liveSlots = lm.live.filter { !$0.isChild }
        let now = store.now
        let last = store.lastRecordForDisplay

        SectionBox("Live") {
            VStack(alignment: .leading, spacing: 8) {
                // Big number row
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let t = lm.aggregateTps, !gen.isEmpty {
                        Text(String(format: "%.1f", t)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("tok/s").font(.callout).foregroundStyle(.secondary)
                    } else if let p = pre.first, let t = p.prefillTps {
                        Text(String(format: "%.0f", t)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("tok/s prefill").font(.callout).foregroundStyle(.secondary)
                    } else if !pre.isEmpty {
                        Text("…").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        Text("starting").font(.callout).foregroundStyle(.secondary)
                    } else if let t = last?.tokensPerSecond {
                        Text(String(format: "%.1f", t)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.tertiary)
                        Text("tok/s").font(.callout).foregroundStyle(.tertiary)
                        Text("last").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("—").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary)
                        Text("tok/s").font(.callout).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        if !gen.isEmpty { Chip(text: "generating", color: .green, symbol: "bolt.fill") }
                        else if !pre.isEmpty { Chip(text: "prefilling", color: .orange, symbol: "hourglass") }
                        else if let p = lm.live.first(where: { !$0.isChild }) { Chip(text: phaseName(p.phase), color: phaseColor(p.phase)) }
                        else { Chip(text: "idle", color: .gray) }
                        if let started = (gen.first.map { $0.generationStartedAt ?? $0.startedAt } ?? pre.first?.startedAt) {
                            Text(Fmt.duration(now.timeIntervalSince(started))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .help("Time since this phase started")
                        }
                    }
                }

                // Prefill progress
                if let p = pre.first {
                    let frac = p.progress ?? 0
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Prompt processing").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", frac * 100)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        Meter(value: frac, color: .orange, height: 6)
                        HStack {
                            let done = p.prefillProcessedTokens
                            let total = p.promptTotalEstimate
                            Text("\(Fmt.int(done)) / \(p.prompt.totalTokens == nil ? "≈" : "")\(Fmt.int(total)) tokens")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            if let eta = p.prefillEtaSec { Text(Fmt.eta(eta)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }

                // Per-slot rows
                if liveSlots.count >= 2 {
                    Divider()
                    VStack(spacing: 5) {
                        ForEach(liveSlots) { p in slotRow(p) }
                    }
                }

                // Prefix cache line
                if let p = liveSlots.last(where: { $0.phase == .prefilling || $0.phase == .queued }) ?? liveSlots.last,
                   let line = prefixLine(p) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
                        Text(line).font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                    .help("Prefix cache: tokens reused from the previous prompt, so they did not need to be processed again")
                }
            }
        }
    }

    private func slotRow(_ p: LivePrediction) -> some View {
        HStack(spacing: 6) {
            Circle().fill(phaseColor(p.phase)).frame(width: 6, height: 6)
            Text(p.key.slot >= 0 ? "slot \(p.key.slot)" : "request").font(.caption).frame(width: 46, alignment: .leading)
            Text(phaseName(p.phase)).font(.caption2).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            if p.phase == .prefilling || p.phase == .queued {
                Meter(value: p.progress ?? 0, color: .orange)
                Text(String(format: "%.0f%%", (p.progress ?? 0) * 100)).font(.caption).monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            } else {
                Meter(value: p.contextFraction ?? 0, color: Palette.level(p.contextFraction ?? 0, warn: 0.8, crit: 0.95))
                    .help("Context used by this slot")
                Text(p.currentTps.map { String(format: "%.1f t/s", $0) } ?? "—").font(.caption).monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
        }
        .help(p.contextTokensEstimate.map { "\(Fmt.int($0)) tokens in context" } ?? "")
    }

    private func prefixLine(_ p: LivePrediction) -> String? {
        let cached = p.prompt.cachedTokens
        let approx = p.prompt.cachedIsEstimate ? "≈" : ""
        switch p.reuse {
        case .lcp(let sim, let keep):
            var s = String(format: "Prefix cache: %.0f%% similar, keeps %.1f%%", sim * 100, keep * 100)
            if let c = cached { s += " (\(approx)\(Fmt.int(c)) tokens reused)" }
            return s
        case .lru:
            if let c = cached, c > 0 { return "Prefix cache: \(approx)\(Fmt.int(c)) tokens reused" }
            return "Prefix cache: no reuse (LRU slot)"
        case .unknown:
            if let c = cached { return c > 0 ? "Prefix cache: \(approx)\(Fmt.int(c)) tokens reused" : "Prefix cache: no reuse" }
            return nil
        }
    }
}
