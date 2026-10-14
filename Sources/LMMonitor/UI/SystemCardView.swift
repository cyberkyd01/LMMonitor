import SwiftUI

struct SystemCardView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        let s = store.system
        let gpuFrac: Double? = {
            guard let u = s.gpuInUseBytes, let b = s.gpuBudgetBytes, b > 0 else { return nil }
            return Double(u) / Double(b)
        }()
        let gpuColor = gpuFrac.map { Palette.level($0, warn: 0.85, crit: 0.95) } ?? .accentColor
        let pColor = Palette.pressure(s.memPressure)
        let swapUsed = s.swapUsedBytes ?? 0
        let swapColor: Color = swapUsed < 268_435_456 ? .green : (swapUsed > 1_073_741_824 ? .red : .orange)

        SectionBox("System", accessory: {
            HStack(spacing: 4) {
                if s.memPressure != .unknown {
                    Chip(text: "pressure " + Palette.pressureLabel(s.memPressure), color: pColor, symbol: "memorychip")
                        .help("macOS memory pressure level")
                }
                Chip(text: Palette.thermalLabel(s.thermal), color: Palette.thermal(s.thermal), symbol: "thermometer.medium")
                    .help("Thermal state: serious or critical means macOS is throttling the chip")
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                MetricRow(label: "CPU", value: Fmt.pct(s.cpuPercent), fraction: s.cpuPercent.map { $0 / 100 })
                if s.pCoreCount > 0, let p = s.cpuPCorePercent {
                    MetricRow(label: "P-cores ×\(s.pCoreCount)", value: Fmt.pct(p), fraction: p / 100, help: "Performance cores")
                }
                if s.eCoreCount > 0, let e = s.cpuECorePercent {
                    MetricRow(label: "E-cores ×\(s.eCoreCount)", value: Fmt.pct(e), fraction: e / 100, help: "Efficiency cores")
                }
                MetricRow(label: "GPU", value: Fmt.pct(s.gpuPercent), fraction: s.gpuPercent.map { $0 / 100 })
                if s.gpuRendererPercent != nil || s.gpuTilerPercent != nil {
                    MetricRow(label: "Renderer / Tiler", value: "\(Fmt.pct(s.gpuRendererPercent)) / \(Fmt.pct(s.gpuTilerPercent))",
                              help: "GPU renderer and tiler unit utilization")
                }
                Divider()
                MetricRow(label: "GPU memory",
                          value: "\(Fmt.gib(s.gpuInUseBytes)) / \(Fmt.gib(s.gpuBudgetBytes))",
                          fraction: gpuFrac, tint: gpuColor, valueTint: (gpuFrac ?? 0) >= 0.85 ? gpuColor : nil,
                          help: "GPU budget: the most memory macOS lets the GPU wire on Apple Silicon (recommendedMaxWorkingSetSize)")
                MetricRow(label: "RAM", value: "\(Fmt.gib(s.memUsedBytes)) / \(Fmt.gib(s.memTotalBytes, decimals: 0))",
                          fraction: s.memUsedBytes.map { Double($0) / Double(max(s.memTotalBytes, 1)) },
                          tint: pColor == .secondary ? .accentColor : pColor)
                if s.memWiredBytes != nil || s.memCompressedBytes != nil {
                    MetricRow(label: "Wired", value: "\(Fmt.gib(s.memWiredBytes)) wired · \(Fmt.gib(s.memCompressedBytes)) compressed",
                              help: "Wired memory cannot be paged out; compressed memory is RAM squeezed to avoid swapping")
                }
                if s.swapUsedBytes != nil {
                    MetricRow(label: "Swap", value: "\(Fmt.gib(s.swapUsedBytes)) / \(Fmt.gib(s.swapTotalBytes))",
                              fraction: (s.swapTotalBytes ?? 0) > 0 ? Double(swapUsed) / Double(s.swapTotalBytes!) : nil,
                              tint: swapColor, valueTint: swapColor == .green ? nil : swapColor,
                              help: "Memory paged out to disk. Sizeable swap during inference makes generation much slower.")
                }
                Divider()
                MetricRow(label: "Disk read", value: Fmt.rate(s.diskReadBps))
                MetricRow(label: "Disk write", value: Fmt.rate(s.diskWriteBps))
                if let p = s.power { power(p) }
                if s.onBattery == true || s.lowPowerMode {
                    HStack(spacing: 6) {
                        if s.onBattery == true {
                            Chip(text: s.batteryPercent.map { "battery \($0)%" } ?? "on battery", color: .orange, symbol: "battery.50")
                                .help("Running on battery; macOS may limit performance")
                        }
                        if s.lowPowerMode { Chip(text: "Low Power Mode", color: .orange, symbol: "leaf").help("Low Power Mode reduces CPU/GPU speed") }
                        Spacer(minLength: 0)
                    }
                }
                if s.engine != nil || s.lmStudio != nil {
                    Divider()
                    if let e = s.engine { proc("Engine", e, help: "The inference engine process that holds the model") }
                    if let l = s.lmStudio { proc("LM Studio", l, help: "The LM Studio app (UI and helpers)") }
                }
            }
        }
    }

    @ViewBuilder private func power(_ p: PowerReading) -> some View {
        let parts: [String] = [
            p.cpuWatts.map { "CPU \(Fmt.watts($0))" }, p.gpuWatts.map { "GPU \(Fmt.watts($0))" },
            p.aneWatts.map { "ANE \(Fmt.watts($0))" }, p.dramWatts.map { "DRAM \(Fmt.watts($0))" },
        ].compactMap { $0 }
        if let t = p.totalWatts { MetricRow(label: "Power", value: Fmt.watts(t), help: "SoC power (CPU + GPU + ANE + DRAM); excludes display and other parts") }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        let extras: [String] = [
            p.gpuFrequencyMHz.map { "GPU " + Fmt.mhz($0) },
            p.cpuTempC.map { "CPU " + Fmt.temp($0) }, p.gpuTempC.map { "GPU " + Fmt.temp($0) },
        ].compactMap { $0 }
        if !extras.isEmpty {
            Text(extras.joined(separator: " · ")).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("GPU clock and die temperatures")
        }
    }

    private func proc(_ name: String, _ p: ProcessFootprint, help: String) -> some View {
        MetricRow(label: name, value: "\(Fmt.bytes(p.physFootprintBytes))" + (p.cpuPercent.map { " · \(Fmt.pct($0)) CPU" } ?? ""), help: help)
    }
}
