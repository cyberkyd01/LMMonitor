import SwiftUI

struct LastPredictionCardView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        SectionBox("Last prediction", accessory: {
            if let r = store.lastRecordForDisplay {
                Text(Fmt.ago(r.finishedAt, now: store.now)).font(.caption2).foregroundStyle(.secondary)
            }
        }) {
            if let r = store.lastRecordForDisplay { content(r) }
            else { Text("No predictions yet").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func content(_ r: PredictionRecord) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3)
        VStack(alignment: .leading, spacing: 8) {
            Text(shortModelName(r.model)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                StatCell(label: "Speed", value: Fmt.tps(r.tokensPerSecond), help: "Generation speed (tokens per second)")
                StatCell(label: "Time to first token", value: Fmt.secs(r.timeToFirstToken), help: "Time from request to the first generated token (mostly prompt processing)")
                if let p = r.prefillTokensPerSecond {
                    StatCell(label: "Prefill", value: Fmt.tps(p), help: "Prompt processing speed")
                }
                StatCell(label: "Generated", value: r.generatedTokens.map { "\(Fmt.int($0)) tok" } ?? "—")
                if let d = r.draft {
                    StatCell(label: "Draft acceptance", value: Fmt.ratio(d.acceptance) , help: "Draft acceptance: share of speculative-decoding draft tokens the model accepted (\(d.accepted) of \(d.generated))")
                }
                if let t = r.totalTime {
                    StatCell(label: "Duration", value: Fmt.secs(t), help: "Total time for the request")
                }
            }
            if let total = r.prompt.totalTokens ?? (r.prompt.processedTokens.map { $0 + (r.prompt.cachedTokens ?? 0) }) {
                let approx = r.prompt.cachedIsEstimate ? "≈" : ""
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Prompt").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Fmt.int(total)) tok").font(.caption.weight(.medium)).monospacedDigit()
                    if let cached = r.prompt.cachedTokens {
                        Text("= \(approx)\(Fmt.int(cached)) cached + \(Fmt.int(max(total - cached, 0))) new")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .help("Prefix cache: tokens reused from the previous prompt, so they did not need to be processed again")
            }
            HStack(spacing: 6) {
                if r.stopReason != .unknown {
                    Chip(text: r.stopReason.label, color: stopColor(r), symbol: nil).help("Why generation stopped")
                }
                if r.truncated { Chip(text: "truncated", color: .orange, symbol: "scissors").help("The context window was full, so the oldest text was dropped") }
                if let c = r.contextTokensAtEnd, let l = r.contextLimit {
                    Tag(text: "ctx \(Fmt.tokens(c)) / \(Fmt.tokens(l))").help("Context used at the end of this prediction")
                }
                Spacer(minLength: 0)
            }
            if let e = r.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func stopColor(_ r: PredictionRecord) -> Color {
        switch r.stopReason {
        case .failed: return .red
        case .contextLengthReached, .maxPredictedTokensReached: return .orange
        case .userStopped, .cancelled: return .gray
        default: return .green
        }
    }
}
