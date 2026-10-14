import Foundation
import Metal

/// GPU working-set budget on Apple Silicon (unified memory).
enum GPUBudget {
    /// `MTLDevice.recommendedMaxWorkingSetSize` (fixed for the process lifetime).
    static let recommendedWorkingSetBytes: UInt64? = {
        guard let d = MTLCreateSystemDefaultDevice() else { return nil }
        let v = d.recommendedMaxWorkingSetSize
        return v > 0 ? v : nil
    }()

    /// User override via `sudo sysctl iogpu.wired_limit_mb=N`; nil when unset (0). Re-read each call (cheap).
    static var wiredLimitBytes: UInt64? {
        var mb: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("iogpu.wired_limit_mb", &mb, &size, nil, 0) == 0, mb > 0 else { return nil }
        return UInt64(mb) * 1024 * 1024
    }

    static var effectiveBudgetBytes: UInt64? { wiredLimitBytes ?? recommendedWorkingSetBytes }
}
