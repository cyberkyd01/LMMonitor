import Foundation

/// Model memory-fit insight (design §6). Pure functions; safe to call from anywhere.
///
/// Budget is the GPU working-set budget (`SystemSnapshot.gpuBudgetBytes`). For a loaded model
/// the measured engine footprint is used; for a model that is not loaded the need is estimated
/// from its file size (× 1.08 for runtime overhead) plus KV cache (`contextFit` bytes/token ×
/// context) when the auto-fit line's `family` matches the model's architecture.
enum MemoryFit {
    static let tightFraction = 0.85
    static let weightsOverhead = 1.08
    static let defaultEstimateContext = 32_768

    static func evaluate(model: ModelInfo, instance: EngineInstance?, contextFit: ContextFitInfo?,
                         system: SystemSnapshot, recentGPUOOM: Bool, swapGrowing: Bool) -> MemoryFitVerdict {
        let budget = system.gpuBudgetBytes.flatMap { $0 > 0 ? $0 : nil }
        let suffix = conditionSuffix(system: system, recentGPUOOM: recentGPUOOM, swapGrowing: swapGrowing)

        if model.isLoaded, let measured = system.engine?.physFootprintBytes, measured > 0 {
            var level = level(need: measured, available: budget)
            level = adjust(level, system: system, recentGPUOOM: recentGPUOOM, swapGrowing: swapGrowing)
            let detail = "\(Fmt.gib(measured)) used of \(budget.map { Fmt.gib($0) } ?? "unknown") GPU budget" + suffix
            return MemoryFitVerdict(level: level, measuredBytes: measured, estimatedBytes: nil, budgetBytes: budget,
                                    isEstimate: false, detail: detail)
        }

        guard let size = model.sizeBytes, size > 0 else {
            return MemoryFitVerdict(level: .unknown, measuredBytes: nil, estimatedBytes: nil, budgetBytes: budget,
                                    isEstimate: true, detail: "No size information for this model" + suffix)
        }

        let kvPerToken = kvBytesPerToken(for: model, contextFit: contextFit)
        let context = model.loadedContextLength
            ?? instance?.nCtxSlot
            ?? (kvPerToken != nil ? contextFit?.fitted : nil)
            ?? min(model.maxContextLength ?? 4096, defaultEstimateContext)
        let weights = UInt64(Double(size) * weightsOverhead)
        let kvBytes = kvPerToken.map { UInt64($0) * UInt64(max(0, context)) } ?? 0
        let estimate = weights + kvBytes

        // Memory already taken by whatever is loaded now (the engine footprint covers all loaded models).
        let taken: UInt64 = model.isLoaded ? 0 : (system.engine?.physFootprintBytes ?? 0)
        let available = budget.map { $0 > taken ? $0 - taken : 0 }
        var level = level(need: estimate, available: available)
        level = adjust(level, system: system, recentGPUOOM: recentGPUOOM, swapGrowing: swapGrowing)

        var detail = "≈\(Fmt.gib(estimate)) needed ("
        if kvPerToken != nil {
            detail += "weights \(Fmt.gib(weights)) + KV \(Fmt.gib(kvBytes)) at \(Fmt.int(context)) ctx)"
        } else {
            detail += "weights only, no KV estimate for \(model.architecture ?? "this architecture"))"
        }
        if let available, let budget {
            detail += " of \(Fmt.gib(available)) free in \(Fmt.gib(budget)) GPU budget"
        } else {
            detail += ", GPU budget unknown"
        }
        return MemoryFitVerdict(level: level, measuredBytes: nil, estimatedBytes: estimate, budgetBytes: budget,
                                isEstimate: true, detail: detail + suffix)
    }

    /// KV-cache bytes per token from LM Studio's `context_fit` line, only when it describes the
    /// same model family as `model.architecture` (e.g. "qwen3_5" vs "qwen35").
    static func kvBytesPerToken(for model: ModelInfo, contextFit: ContextFitInfo?) -> Int? {
        guard let fit = contextFit, fit.fullKVBytesPerToken > 0, let arch = model.architecture else { return nil }
        return canonical(fit.family) == canonical(arch) ? fit.fullKVBytesPerToken : nil
    }

    // MARK: - Internals

    private static func level(need: UInt64, available: UInt64?) -> FitLevel {
        guard let available else { return .unknown }
        guard available > 0 else { return .willSwap }
        let f = Double(need) / Double(available)
        if f > 1 { return .willSwap }
        if f > tightFraction { return .tight }
        return .fits
    }

    private static func adjust(_ level: FitLevel, system: SystemSnapshot, recentGPUOOM: Bool, swapGrowing: Bool) -> FitLevel {
        if system.memPressure == .critical || swapGrowing || recentGPUOOM { return .willSwap }
        if system.memPressure == .warn && (level == .fits || level == .unknown) { return .tight }
        return level
    }

    private static func conditionSuffix(system: SystemSnapshot, recentGPUOOM: Bool, swapGrowing: Bool) -> String {
        var parts: [String] = []
        if let swap = system.swapUsedBytes { parts.append("swap \(Fmt.gib(swap))" + (swapGrowing ? " (growing)" : "")) }
        switch system.memPressure {
        case .normal: parts.append("pressure normal")
        case .warn: parts.append("pressure warn")
        case .critical: parts.append("pressure critical")
        case .unknown: break
        }
        if recentGPUOOM { parts.append("GPU out-of-memory recently") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private static func canonical(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
