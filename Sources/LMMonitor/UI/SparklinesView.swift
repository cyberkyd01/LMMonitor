import SwiftUI

struct SparklinesView: View {
    @EnvironmentObject var store: MetricsStore
    @State private var range: Double = 300

    private struct Item: Identifiable {
        var id: String { title }
        var title: String
        var series: TimeSeries
        var maxValue: Double?
        var color: Color
        var format: (Double?) -> String
    }

    private var items: [Item] {
        let s = store.series
        let sys = store.system
        let gb: (Double?) -> String = { v in v.map { Fmt.gib(UInt64(max($0, 0))) } ?? "—" }
        var out: [Item] = [
            Item(title: "Generation", series: s.tps, maxValue: nil, color: .green, format: { Fmt.tps($0) }),
            Item(title: "Prefill", series: s.prefillTps, maxValue: nil, color: .teal, format: { Fmt.tps($0) }),
            Item(title: "CPU", series: s.cpu, maxValue: 100, color: .blue, format: { Fmt.pct($0) }),
            Item(title: "GPU", series: s.gpu, maxValue: 100, color: .purple, format: { Fmt.pct($0) }),
            Item(title: "GPU memory", series: s.gpuMem, maxValue: sys.gpuBudgetBytes.map { Double($0) }, color: .orange, format: gb),
            Item(title: "RAM used", series: s.memUsed, maxValue: Double(sys.memTotalBytes), color: .indigo, format: gb),
            Item(title: "Swap", series: s.swapUsed, maxValue: sys.swapTotalBytes.map { max(Double($0), 1_073_741_824) }, color: .red, format: gb),
            Item(title: "Disk read", series: s.diskRead, maxValue: nil, color: .cyan, format: { Fmt.rate($0) }),
            Item(title: "Disk write", series: s.diskWrite, maxValue: nil, color: .mint, format: { Fmt.rate($0) }),
        ]
        if sys.power != nil {
            out.append(Item(title: "Power", series: s.powerWatts, maxValue: nil, color: .yellow, format: { Fmt.watts($0) }))
        }
        return out
    }

    var body: some View {
        SectionBox("History graphs", accessory: {
            Picker("Range", selection: $range) {
                Text("1 min").tag(60.0); Text("5 min").tag(300.0); Text("10 min").tag(600.0)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 150)
        }) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(items) { it in
                    let pts = it.series.window(seconds: range, now: store.now).map { $0.v }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(it.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(it.format(it.series.lastValue)).font(.caption2.weight(.medium)).monospacedDigit().lineLimit(1)
                        }
                        Sparkline(values: pts, maxValue: it.maxValue, color: it.color).frame(height: 30)
                    }
                }
            }
        }
    }
}
