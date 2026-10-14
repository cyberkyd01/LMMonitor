import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var store: MetricsStore

    private func streamColor(_ s: StreamStatus?) -> Color {
        switch s {
        case .running: return .green
        case .starting, .backoff, .droppedOversizedLine: return .orange
        case .exited: return .red
        case .blocked, .notStarted, .none: return .gray
        }
    }
    private func streamText(_ name: String, _ s: StreamStatus?) -> String {
        switch s {
        case .running(let since): return "\(name): running since \(Fmt.clock.string(from: since))"
        case .starting: return "\(name): starting"
        case .backoff(let sec): return "\(name): reconnecting in \(Int(sec)) s"
        case .exited(let code, _): return "\(name): exited (code \(code))"
        case .blocked(let r): return "\(name): blocked — \(r)"
        case .droppedOversizedLine(let b): return "\(name): dropped an oversized line (\(b) bytes)"
        case .notStarted, .none: return "\(name): not started"
        }
    }

    var body: some View {
        let lm = store.lm
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Color.accentColor)
                Text("LM Monitor").font(.headline)
                Spacer(minLength: 0)
                if !lm.live.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
            }
            HStack(spacing: 6) {
                Chip(text: lm.lmStudioRunning ? "LM Studio" : "LM Studio off",
                     color: lm.lmStudioRunning ? .green : .gray,
                     symbol: lm.lmStudioRunning ? "checkmark" : "moon.zzz")
                    .help(lm.lmStudioRunning ? "LM Studio is running" : "LM Studio is not running")
                Chip(text: lm.serverReachable ? "Server :\(lm.serverPort)" : "Server stopped",
                     color: lm.serverReachable ? .green : .orange,
                     symbol: lm.serverReachable ? "network" : "network.slash")
                    .help(lm.serverReachable ? "LM Studio's local server answers on port \(lm.serverPort)" : "LM Studio's local server is not reachable")
                HStack(spacing: 3) {
                    ForEach([("runtime", EventSource.runtime), ("model", .model), ("server", .server)], id: \.0) { name, src in
                        Circle().fill(streamColor(lm.streams[src])).frame(width: 7, height: 7)
                            .help(streamText(name, lm.streams[src]))
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .help("Log streams: runtime (engine), model (statistics), server. Green = live.")
                if let reason = lm.degradedReason {
                    Chip(text: "degraded", color: .orange, symbol: "exclamationmark.triangle").help(reason)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
