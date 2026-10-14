import Foundation

enum MemoryPressure: Int, Equatable { case unknown = 0, normal = 1, warn = 2, critical = 4 }

/// Rootless SoC power/thermal reading (IOReport "Energy Model" + HID sensors). Every field optional.
struct PowerReading: Equatable {
    var cpuWatts: Double? = nil
    var gpuWatts: Double? = nil
    var aneWatts: Double? = nil
    var dramWatts: Double? = nil
    var totalWatts: Double? = nil      // cpu + gpu + ane + dram (not full package power)
    var gpuFrequencyMHz: Double? = nil // nil when the DVFS table can't be mapped reliably
    var cpuTempC: Double? = nil        // mean of "PMU tdie*" (whole SoC die)
    var gpuTempC: Double? = nil        // IOReport GPU Stats / Temperature
    var maxTempC: Double? = nil
}

struct ProcessFootprint: Equatable {
    var name: String
    var pids: [Int32]
    var physFootprintBytes: UInt64
    var cpuPercent: Double?        // delta of ri_user_time+ri_system_time over the sample interval
}

struct SystemSnapshot: Equatable {
    var sampledAt = Date()
    var cpuPercent: Double?
    var cpuPCorePercent: Double?
    var cpuECorePercent: Double?
    var pCoreCount = 0
    var eCoreCount = 0
    var gpuPercent: Double?            // "Device Utilization %"
    var gpuRendererPercent: Double?
    var gpuTilerPercent: Double?
    var gpuInUseBytes: UInt64?         // "In use system memory"
    var gpuAllocBytes: UInt64?         // "Alloc system memory"
    var gpuBudgetBytes: UInt64?        // GPUBudget.effectiveBudgetBytes
    var memTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memUsedBytes: UInt64?          // active + wired + compressed
    var memWiredBytes: UInt64?
    var memCompressedBytes: UInt64?
    var memFreeBytes: UInt64?          // free + inactive + speculative
    var memPressure: MemoryPressure = .unknown
    var swapUsedBytes: UInt64?
    var swapTotalBytes: UInt64?
    var diskReadBps: Double?
    var diskWriteBps: Double?
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false
    var onBattery: Bool?
    var batteryPercent: Int?
    var power: PowerReading?
    var engine: ProcessFootprint?
    var lmStudio: ProcessFootprint?
}

enum FitLevel: String, Equatable { case fits, tight, willSwap, unknown }

struct MemoryFitVerdict: Equatable {
    var level: FitLevel
    var measuredBytes: UInt64?
    var estimatedBytes: UInt64?
    var budgetBytes: UInt64?
    var isEstimate: Bool
    var detail: String
}

/// Result of `lms load <key> --estimate-only --yes`.
struct FitEstimate: Equatable {
    var gpuBytes: UInt64?
    var totalBytes: UInt64?
    var confidence: String?
    var verdict: String?          // LM Studio's own sentence, e.g. "This model will fail to load…"
}
