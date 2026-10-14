import SwiftUI

/// Always-visible at-a-glance system strip: compute and, above all, memory headroom.
struct VitalsStripView: View {
    @EnvironmentObject var store: MetricsStore

    private struct Cell: View {
        var label: String
        var value: String
        var sub: String? = nil
        var fraction: Double? = nil
        var tint: Color = .accentColor
        var valueTint: Color? = nil
        var help: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(valueTint ?? .primary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                if let f = fraction { Meter(value: f, color: tint, height: 4) } else { Color.clear.frame(height: 4) }
                Text(sub ?? " ").font(.system(size: 9)).monospacedDigit().foregroundStyle(valueTint ?? .secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
        }
    }

    var body: some View {
        let s = store.system
        let budget = s.gpuBudgetBytes
        let gpuFrac: Double? = {
            guard let u = s.gpuInUseBytes, let b = budget, b > 0 else { return nil }
            return Double(u) / Double(b)
        }()
        let gpuColor = gpuFrac.map { Palette.level($0, warn: 0.85, crit: 0.95) } ?? .secondary
        let ramFrac = s.memUsedBytes.map { Double($0) / Double(max(s.memTotalBytes, 1)) }
        let pColor = Palette.pressure(s.memPressure)
        let swapUsed = s.swapUsedBytes ?? 0
        let swapFrac = (s.swapTotalBytes ?? 0) > 0 ? Double(swapUsed) / Double(s.swapTotalBytes!) : nil
        let swapColor: Color = swapUsed < 268_435_456 ? .green : (swapUsed > 1_073_741_824 && (swapFrac ?? 0) >= 0.5 ? .red : .orange)
        let watts = s.power.flatMap { $0.totalWatts ?? (($0.cpuWatts ?? 0) + ($0.gpuWatts ?? 0)) }

        let cols = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4)
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            Cell(label: "CPU", value: Fmt.pct(s.cpuPercent), sub: s.cpuPCorePercent.map { p in
                    "P \(Int(p.rounded())) · E \(Int((s.cpuECorePercent ?? 0).rounded()))" },
                 fraction: s.cpuPercent.map { $0 / 100 }, tint: .accentColor,
                 help: "CPU utilization across all cores (P = performance, E = efficiency)")
            Cell(label: "GPU", value: Fmt.pct(s.gpuPercent), fraction: s.gpuPercent.map { $0 / 100 }, tint: .accentColor,
                 help: "GPU device utilization. Near 100% while generating is normal.")
            Cell(label: "GPU memory",
                 value: budget == nil ? Fmt.gib(s.gpuInUseBytes) : "\(gbNum(s.gpuInUseBytes))/\(gbNum(budget)) GB",
                 sub: {
                     guard let u = s.gpuInUseBytes, let b = budget else { return nil }
                     return u > b ? "\(gbNum(u - b)) GB over" : "\(gbNum(b - u)) GB free"
                 }(),
                 fraction: gpuFrac, tint: gpuColor, valueTint: (gpuFrac ?? 0) >= 0.85 ? gpuColor : nil,
                 help: "GPU memory in use vs. the GPU budget: the most memory macOS lets the GPU wire on Apple Silicon (recommendedMaxWorkingSetSize). Beyond it, models fail with out-of-memory errors or spill into swap.")
            Cell(label: "RAM",
                 value: "\(gbNum(s.memUsedBytes))/\(gbNum(s.memTotalBytes, decimals: 0)) GB",
                 sub: s.memPressure == .unknown ? nil : "pressure \(Palette.pressureLabel(s.memPressure))",
                 fraction: ramFrac, tint: pColor == .secondary ? .accentColor : pColor,
                 valueTint: s.memPressure == .warn || s.memPressure == .critical ? pColor : nil,
                 help: "System memory used (active + wired + compressed) of installed RAM. Pressure is macOS's own memory-pressure level.")
            Cell(label: "Swap", value: swapUsed == 0 && s.swapUsedBytes != nil ? "none" : "\(gbNum(s.swapUsedBytes))/\(gbNum(s.swapTotalBytes)) GB",
                 sub: swapUsed >= 268_435_456 ? "slows inference" : nil,
                 fraction: swapFrac, tint: swapColor, valueTint: swapColor == .green ? nil : swapColor,
                 help: "Memory paged out to disk. Any sizeable swap during inference makes generation much slower.")
            Cell(label: "Disk read", value: Fmt.rate(s.diskReadBps), help: "Disk read throughput (large reads while loading a model or paging memory in)")
            Cell(label: "Disk write", value: Fmt.rate(s.diskWriteBps), help: "Disk write throughput")
            if let w = watts, w > 0 {
                Cell(label: "Power", value: Fmt.watts(w),
                     sub: s.power?.gpuWatts.map { "GPU \(Fmt.watts($0))" },
                     help: "SoC power draw (CPU + GPU + ANE + DRAM), not including display or other components")
            } else {
                Cell(label: "Power", value: "—", help: "Power sensors unavailable")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
