import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: MetricsStore

    private func stopSymbol(_ r: PredictionRecord) -> (String, Color) {
        if r.phase == .errored || r.stopReason == .failed { return ("xmark.octagon.fill", .red) }
        switch r.stopReason {
        case .eosFound, .stopStringFound, .toolCalls: return ("checkmark.circle", .green)
        case .maxPredictedTokensReached, .contextLengthReached: return ("exclamationmark.triangle.fill", .orange)
        case .userStopped, .cancelled: return ("stop.circle", .secondary)
        default: return ("circle.dotted", .secondary)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            SectionBox("Recent predictions", accessory: {
                Button { store.exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .controlSize(.mini).help("Save all stored predictions as CSV to Downloads")
            }) {
                if store.history.isEmpty {
                    Text("Nothing recorded yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Time").frame(width: 50, alignment: .leading)
                            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                            Text("tok/s").frame(width: 38, alignment: .trailing)
                            Text("in → out").frame(width: 70, alignment: .trailing)
                            Text("TTFT").frame(width: 42, alignment: .trailing)
                            Color.clear.frame(width: 14, height: 1)
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        ForEach(store.history.prefix(20)) { r in
                            let (sym, col) = stopSymbol(r)
                            HStack(spacing: 6) {
                                Text(Fmt.clock.string(from: r.startedAt)).frame(width: 50, alignment: .leading).foregroundStyle(.secondary)
                                Text(shortModelName(r.model)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                Text(r.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—").frame(width: 38, alignment: .trailing)
                                Text("\(r.prompt.totalTokens.map { Fmt.tokens($0) } ?? "—")→\(Fmt.tokens(r.generatedTokens))")
                                    .frame(width: 70, alignment: .trailing).lineLimit(1)
                                Text(r.timeToFirstToken.map { String(format: "%.2f s", $0) } ?? "—").frame(width: 42, alignment: .trailing)
                                Image(systemName: sym).foregroundStyle(col).frame(width: 14)
                                    .help(r.error ?? r.stopReason.label)
                            }
                            .font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
            if !store.aggregates.isEmpty {
                SectionBox("Per-model stats") {
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Runs").frame(width: 28, alignment: .trailing)
                            Text("Median").frame(width: 38, alignment: .trailing).help("Median generation tok/s")
                            Text("Avg").frame(width: 34, alignment: .trailing).help("Average generation tok/s")
                            Text("Prefill").frame(width: 38, alignment: .trailing).help("Average prompt-processing tok/s")
                            Text("TTFT").frame(width: 40, alignment: .trailing).help("Average time to first token")
                            Text("Tokens").frame(width: 44, alignment: .trailing).help("Total generated tokens")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        ForEach(store.aggregates) { a in
                            HStack(spacing: 6) {
                                Text(shortModelName(a.id)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(a.count)").frame(width: 28, alignment: .trailing)
                                Text(a.medianTps.map { String(format: "%.1f", $0) } ?? "—").frame(width: 38, alignment: .trailing)
                                Text(a.avgTps.map { String(format: "%.1f", $0) } ?? "—").frame(width: 34, alignment: .trailing)
                                Text(a.avgPrefillTps.map { String(format: "%.0f", $0) } ?? "—").frame(width: 38, alignment: .trailing)
                                Text(a.avgTTFT.map { String(format: "%.2f s", $0) } ?? "—").frame(width: 40, alignment: .trailing)
                                Text(Fmt.tokens(a.totalGenerated)).frame(width: 44, alignment: .trailing)
                            }
                            .font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
