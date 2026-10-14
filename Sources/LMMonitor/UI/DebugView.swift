import SwiftUI

struct DebugView: View {
    @EnvironmentObject var store: MetricsStore

    private func describe(_ s: StreamStatus?) -> String {
        switch s {
        case .none, .notStarted: return "not started"
        case .blocked(let r): return "blocked: \(r)"
        case .starting: return "starting"
        case .running(let since): return "running since \(Fmt.clock.string(from: since))"
        case .exited(let c, let tail): return "exited (\(c)) \(tail.suffix(80))"
        case .backoff(let s): return "backoff \(Int(s)) s"
        case .droppedOversizedLine(let b): return "dropped oversized line (\(b) B)"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            SectionBox("Streams") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(EventSource.allCases, id: \.self) { src in
                        if let st = store.lm.streams[src] {
                            HStack(alignment: .firstTextBaseline) {
                                Text(src.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                                Text(describe(st)).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider()
                    row("Deduplicated lines", Fmt.int(store.lm.dedupedLines))
                    row("Dropped lines", Fmt.int(store.lm.droppedLines))
                    row("lms path", store.lm.lmsPath ?? "not found")
                    if let d = store.lm.degradedReason { row("Degraded", d) }
                    row("Proxy", store.proxyRunning ? "running" : (store.proxyError ?? "off"))
                }
            }
            SectionBox("Recent log lines") {
                if store.debugLines.isEmpty {
                    Text("No lines yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.debugLines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 9, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(v).font(.caption).monospacedDigit().lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
