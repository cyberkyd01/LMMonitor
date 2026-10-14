import SwiftUI
import AppKit

// MARK: - Colors

enum Palette {
    /// Green / orange / red by fraction (0...1+).
    static func level(_ f: Double, warn: Double = 0.75, crit: Double = 0.9) -> Color {
        f >= crit ? .red : (f >= warn ? .orange : .green)
    }
    static func severity(_ s: AlertSeverity) -> Color {
        switch s { case .critical: return .red; case .warning: return .orange; case .info: return .blue }
    }
    static func severityIcon(_ s: AlertSeverity) -> String {
        switch s {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    static func fit(_ l: FitLevel) -> Color {
        switch l { case .fits: return .green; case .tight: return .orange; case .willSwap: return .red; case .unknown: return .secondary }
    }
    static func fitIcon(_ l: FitLevel) -> String {
        switch l {
        case .fits: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .willSwap: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    static func fitLabel(_ l: FitLevel) -> String {
        switch l { case .fits: return "Fits in memory"; case .tight: return "Memory is tight"; case .willSwap: return "Will swap / may fail"; case .unknown: return "Fit unknown" }
    }
    static func pressure(_ p: MemoryPressure) -> Color {
        switch p { case .normal: return .green; case .warn: return .orange; case .critical: return .red; case .unknown: return .secondary }
    }
    static func pressureLabel(_ p: MemoryPressure) -> String {
        switch p { case .normal: return "normal"; case .warn: return "warning"; case .critical: return "critical"; case .unknown: return "unknown" }
    }
    static func thermal(_ s: ProcessInfo.ThermalState) -> Color {
        switch s { case .nominal: return .green; case .fair: return .yellow; case .serious: return .orange; case .critical: return .red; @unknown default: return .secondary }
    }
    static func thermalLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s { case .nominal: return "nominal"; case .fair: return "fair"; case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "unknown" }
    }
}

extension AlertRule {
    /// Human label used in Settings.
    var uiLabel: String {
        switch self {
        case .gpuOOM: return "GPU out of memory"
        case .modelLoadFailed: return "Model failed to load"
        case .computeError: return "Compute / decode error"
        case .kvCacheFull: return "KV cache full"
        case .memoryPressure: return "Memory pressure"
        case .swapInUse: return "Swap in use"
        case .swapGrowing: return "Swap growing during generation"
        case .gpuMemoryAtBudget: return "GPU memory at budget"
        case .thermal: return "Thermal throttling"
        case .lowPowerMode: return "Low Power Mode on"
        case .onBattery: return "Running on battery"
        case .contextNearlyFull: return "Context nearly full"
        case .contextTruncated: return "Context truncated"
        case .runawayGeneration: return "Runaway generation"
        case .slowGeneration: return "Slow generation"
        case .serverNotRunning: return "LM Studio server stopped"
        case .lmStudioNotRunning: return "LM Studio not running"
        case .lmsMissing: return "lms command missing"
        case .logStreamDown: return "Log stream down"
        case .modelFitTight: return "Model fit is tight"
        case .modelWillSwap: return "Model will swap"
        }
    }
}

// MARK: - Building blocks

/// Thin rounded progress bar. `value` is 0...1 (clamped).
struct Meter: View {
    var value: Double
    var color: Color = .accentColor
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: max(value.isFinite && value > 0 ? height : 0, g.size.width * CGFloat(min(max(value.isFinite ? value : 0, 0), 1))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((value.isFinite ? value : 0) * 100)) percent"))
    }
}

/// Small label over a value, e.g. "TTFT" / "1.63 s".
struct StatCell: View {
    var label: String
    var value: String
    var help: String? = nil
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }
}

/// Label ... meter ... value row.
struct MetricRow: View {
    var label: String
    var value: String
    var fraction: Double? = nil
    var tint: Color = .accentColor
    var valueTint: Color? = nil
    var help: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 84, alignment: .leading)
            if let f = fraction { Meter(value: f, color: tint) } else { Spacer(minLength: 0) }
            Text(value).font(.caption).monospacedDigit().foregroundStyle(valueTint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(minWidth: fraction == nil ? 0 : 110, alignment: .trailing)
        }
        .help(help ?? "")
    }
}

/// Neutral label tag.
struct Tag: View {
    var text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
    }
}

/// Colored status chip.
struct Chip: View {
    var text: String
    var color: Color
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Rounded card with a title and an optional trailing accessory.
struct SectionBox<Content: View, Accessory: View>: View {
    var title: String
    var accessory: Accessory
    var content: Content
    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.4)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
extension SectionBox where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Short display name: drops the publisher prefix ("qwen/qwen3.8-27b" -> "qwen3.8-27b").
func shortModelName(_ s: String) -> String {
    if let i = s.lastIndex(of: "/") { return String(s[s.index(after: i)...]) }
    return s
}

/// "27.4" (GiB number without unit) for compact "a / b GB" strings.
func gbNum(_ b: UInt64?, decimals: Int = 1) -> String {
    guard let b else { return "—" }
    return String(format: "%.\(decimals)f", Double(b) / 1_073_741_824)
}
