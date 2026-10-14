import Foundation

enum PredictionPhase: String, Codable {
    case queued, prefilling, generating, finishing, finished, errored, cancelled
    var isLive: Bool { self == .queued || self == .prefilling || self == .generating || self == .finishing }
}

enum StopReason: String, Codable {
    case eosFound, stopStringFound, toolCalls, maxPredictedTokensReached, contextLengthReached
    case userStopped, failed, cancelled, unknown
    init(lmStudio raw: String?) { self = raw.flatMap(StopReason.init(rawValue:)) ?? .unknown }
    var label: String {
        switch self {
        case .eosFound: return "end of text"
        case .stopStringFound: return "stop string"
        case .toolCalls: return "tool call"
        case .maxPredictedTokensReached: return "max tokens"
        case .contextLengthReached: return "context full"
        case .userStopped: return "stopped by user"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .unknown: return "—"
        }
    }
}

struct SlotKey: Hashable, Codable {
    var instance: String
    var slot: Int                 // -1 = pseudo slot (engine without slot logs, e.g. MLX)
    static let pseudoSlot = -1
}

struct PromptBreakdown: Equatable, Codable {
    var totalTokens: Int? = nil
    var processedTokens: Int? = nil   // tokens actually evaluated (not cached)
    var cachedTokens: Int? = nil
    var cachedIsEstimate: Bool = false
}

struct DraftStats: Equatable, Codable {
    var accepted: Int
    var generated: Int
    var meanLength: Double?
    var acceptance: Double { generated > 0 ? Double(accepted) / Double(generated) : 0 }
}

struct FinalTimings: Equatable {
    var promptEvalMs: Double? = nil
    var promptEvalTokens: Int? = nil
    var promptEvalTps: Double? = nil
    var evalMs: Double? = nil
    var evalTokens: Int? = nil
    var evalTps: Double? = nil
    var totalMs: Double? = nil
    var totalTokens: Int? = nil
    var draft: DraftStats? = nil
    var releaseNTokens: Int? = nil
    var truncated: Bool? = nil
}

struct LivePrediction: Identifiable, Equatable {
    var id = UUID()
    var key: SlotKey
    var task: Int?
    var model: String
    var engineType: String?
    var phase: PredictionPhase
    var startedAt: Date
    var generationStartedAt: Date?
    var lastUpdate: Date
    var messageCount: Int?
    var endpoint: String?
    var streamed = false
    var isChild = false
    var reuse: PrefixReuse = .unknown
    var prompt = PromptBreakdown()
    var prefillProcessedTokens: Int?
    var prefillProgress: Double?        // 0...1 from runtime
    var serverProgress: Double?         // 0...1 from server "Prompt processing progress"
    var prefillTps: Double?
    var prefillElapsedSec: Double?
    var progressRatePerSec: Double?     // for ETA when only server progress exists
    var generatedTokens: Int?
    var tgAverage: Double?
    var tg3s: Double?
    var contextLimit: Int?
    var final = FinalTimings()
    var finishingSince: Date?
    var error: String?

    var progress: Double? {
        switch (prefillProgress, serverProgress) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
    var promptTotalEstimate: Int? {
        if let t = prompt.totalTokens { return t }
        if let n = prefillProcessedTokens, let p = prefillProgress, p > 0.01 { return Int(Double(n) / p) }
        return nil
    }
    var prefillEtaSec: Double? {
        if let n = prefillProcessedTokens, let p = prefillProgress, p > 0.01, let tps = prefillTps, tps > 0 {
            return (Double(n) / p - Double(n)) / tps
        }
        if let p = progress, let r = progressRatePerSec, r > 0 { return (1 - p) / r }
        return nil
    }
    var contextTokensEstimate: Int? {
        if let n = final.releaseNTokens { return n }
        let promptPart = prompt.totalTokens ?? ((prompt.cachedTokens ?? 0) + (prompt.processedTokens ?? prefillProcessedTokens ?? 0))
        guard promptPart > 0 || generatedTokens != nil else { return nil }
        return promptPart + (generatedTokens ?? 0)
    }
    var contextFraction: Double? {
        guard let c = contextTokensEstimate, let l = contextLimit, l > 0 else { return nil }
        return Double(c) / Double(l)
    }
    var currentTps: Double? { tg3s ?? tgAverage ?? final.evalTps }
}

struct PredictionRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var model: String
    var instance: String?
    var slot: Int?
    var task: Int?
    var engineType: String?
    var startedAt: Date
    var finishedAt: Date
    var phase: PredictionPhase            // finished | errored | cancelled
    var stopReason: StopReason
    var stopReasonRaw: String?
    var tokensPerSecond: Double?
    var prefillTokensPerSecond: Double?
    var timeToFirstToken: Double?
    var generationTime: Double?
    var totalTime: Double?
    var prompt: PromptBreakdown
    var generatedTokens: Int?
    var contextTokensAtEnd: Int?
    var contextLimit: Int?
    var truncated: Bool
    var draft: DraftStats?
    var messageCount: Int?
    var endpoint: String?
    var error: String?
    var sources: [EventSource]
}

struct EngineInstance: Identifiable, Equatable {
    var id: String                       // EngineContext.instanceKey
    var model: String
    var engineName: String?
    var engineVersion: String?
    var engineType: String?
    var pid: Int32?
    var modelPath: String?
    var nSlots: Int?
    var nCtxSlot: Int?
    var kvUnified: Bool?
    var slotLastNTokens: [Int: Int] = [:]
    var lastSeen: Date
}

struct ModelInfo: Identifiable, Equatable, Codable {
    var id: String                       // key (REST) == identifier (lms ps) unless --identifier was used
    var instanceID: String? = nil        // loaded_instances[].id
    var displayName: String? = nil
    var publisher: String? = nil
    var type: String? = nil              // llm | vlm | embeddings
    var format: String? = nil            // gguf | mlx
    var architecture: String? = nil
    var quantization: String? = nil
    var bitsPerWeight: Double? = nil
    var paramsString: String? = nil
    var sizeBytes: UInt64? = nil
    var maxContextLength: Int? = nil
    var loadedContextLength: Int? = nil
    var parallel: Int? = nil
    var speculativeDraftMTP: Bool? = nil
    var kvOffloadToGPU: Bool? = nil
    var flashAttention: Bool? = nil
    var ttlMs: Int? = nil
    var lastUsedTime: Date? = nil
    var status: String? = nil            // idle | processingPrompt | generating | ... (lms ps, pass-through)
    var queued: Int? = nil
    var isLoaded: Bool = false
    var vision: Bool? = nil
    var toolUse: Bool? = nil
}

struct ModelAggregate: Identifiable, Equatable {
    var id: String                       // normalized model key
    var count: Int
    var avgTps: Double?
    var medianTps: Double?
    var p10Tps: Double?
    var avgPrefillTps: Double?
    var avgTTFT: Double?
    var totalGenerated: Int
    var totalPrompt: Int
    var errors: Int
}

/// Everything the reducer owns. Published to the UI as one value.
struct LMState: Equatable {
    var live: [LivePrediction] = []
    var instances: [String: EngineInstance] = [:]
    var models: [ModelInfo] = []
    var lastRecord: PredictionRecord?
    var lmStudioRunning = false
    var serverReachable = false
    var serverPort = 1234
    var lmsPath: String?
    var streams: [EventSource: StreamStatus] = [:]
    var lastContextFit: ContextFitInfo?
    var lastCacheRestore: PromptCacheRestore?
    var promptCacheDisk: PromptCacheDisk?
    var dedupedLines = 0
    var droppedLines = 0
    var degradedReason: String?          // "lms not found — tailing server log file"

    var loadedModels: [ModelInfo] { models.filter { $0.isLoaded } }
    var primaryModel: ModelInfo? {
        if let m = live.last?.model, let found = models.first(where: { $0.isLoaded && ModelKey.norm($0.id) == ModelKey.norm(m) }) { return found }
        return loadedModels.first(where: { $0.type != "embeddings" }) ?? loadedModels.first
    }
    var generating: [LivePrediction] { live.filter { $0.phase == .generating && !$0.isChild } }
    var prefilling: [LivePrediction] { live.filter { ($0.phase == .prefilling || $0.phase == .queued) && !$0.isChild } }
    var aggregateTps: Double? {
        let v = generating.compactMap { $0.currentTps }
        return v.isEmpty ? nil : v.reduce(0, +)
    }
}

enum ModelKey {
    /// Lowercase and strip an "@variant" suffix so "x@4bit", "x" and the server tag all match.
    static func norm(_ s: String) -> String {
        let lower = s.lowercased()
        if let at = lower.firstIndex(of: "@") { return String(lower[..<at]) }
        return lower
    }
}
