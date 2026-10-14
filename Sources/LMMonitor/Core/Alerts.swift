import Foundation

enum AlertSeverity: Int, Codable, Comparable {
    case info = 0, warning = 1, critical = 2
    static func < (a: AlertSeverity, b: AlertSeverity) -> Bool { a.rawValue < b.rawValue }
}

enum AlertRule: String, Codable, CaseIterable {
    case gpuOOM, modelLoadFailed, computeError, kvCacheFull
    case memoryPressure, swapInUse, swapGrowing, gpuMemoryAtBudget, thermal, lowPowerMode, onBattery
    case contextNearlyFull, contextTruncated, runawayGeneration, slowGeneration
    case serverNotRunning, lmStudioNotRunning, lmsMissing, logStreamDown
    case modelFitTight, modelWillSwap
    var defaultNotify: Bool {
        switch self {
        case .gpuOOM, .modelLoadFailed, .computeError, .memoryPressure, .swapGrowing, .thermal,
             .contextTruncated, .runawayGeneration, .modelWillSwap: return true
        default: return false
        }
    }
}

struct Alert: Identifiable, Equatable, Codable {
    var rule: AlertRule
    var key: String?                 // e.g. model id or slot, nil for global
    var severity: AlertSeverity
    var title: String
    var detail: String
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var active: Bool
    var id: String { rule.rawValue + "|" + (key ?? "") }
}
