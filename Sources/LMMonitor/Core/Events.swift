import Foundation

enum EventSource: String, Codable, Hashable, CaseIterable {
    case runtime, model, server, logfile, proxy, poller, system
}

enum PrefixReuse: Equatable, Codable {
    case unknown
    case lru(tLast: Int)
    case lcp(fSim: Double, fKeep: Double)
}

/// Metadata the runtime stream attaches to each engine line. All nil when the line
/// arrived via the server log or the log file.
struct EngineContext: Equatable {
    var modelIdentifier: String? = nil
    var instanceReference: String? = nil
    var engineName: String? = nil
    var engineVersion: String? = nil
    var engineType: String? = nil      // "llama.cpp", "mlx", ...
    var pid: Int32? = nil
    var instanceKey: String { instanceReference ?? modelIdentifier ?? "default" }
}

enum EngineLine: Equatable {
    case slotSelected(slot: Int, reuse: PrefixReuse)
    case taskLaunched(slot: Int, task: Int, isChild: Bool)
    case prefillProgress(slot: Int, task: Int, nTokens: Int, progress: Double, elapsedSec: Double, tps: Double)
    case genProgress(slot: Int, task: Int, nGen: Int, tgAvg: Double, tg3s: Double)
    case promptEval(slot: Int, task: Int, ms: Double, tokens: Int, tps: Double)
    case eval(slot: Int, task: Int, ms: Double, tokens: Int, tps: Double)
    case totalTime(slot: Int, task: Int, ms: Double, tokens: Int)
    case draftAcceptance(slot: Int, task: Int, ratio: Double, accepted: Int, generated: Int, meanLen: Double)
    case slotReleased(slot: Int, task: Int, nTokens: Int, truncated: Bool)
    case taskCancelled(task: Int)
    case decodeFailed(message: String)
    case gpuOOM(message: String)
    case kvCacheFull
    case modelLoading(path: String)
    case modelInitialized(nSlots: Int, nCtxSlot: Int, kvUnified: Bool)
    case other(level: Character, text: String)
}

struct ContextFitInfo: Equatable, Codable {
    var family: String
    var maxContext: Int
    var fitted: Int
    var workingSetBytes: UInt64
    var reserveBytes: UInt64
    var safeCeilingBytes: UInt64
    var baselineBytes: UInt64
    var fullKVBytesPerToken: Int
    var promptInputBytesPerToken: Int?
    var attentionBytesPerToken: Int?
    var estimatedPeakBytes: UInt64
}

struct PromptCacheRestore: Equatable, Codable {
    var cachedTokens: Int
    var uncachedTokens: Int
    var lifetimeEfficiency: Double   // 0...100
}

struct PromptCacheDisk: Equatable, Codable {
    var usedMiB: Double
    var capMiB: Double
    var records: Int
}

enum ServerLine: Equatable {
    case requestReceived(method: String, path: String)
    case chatStarted(model: String, messageCount: Int)
    case streamingStarted(model: String)
    case streamingFinished(model: String)
    case generatedPrediction(model: String)
    case prefillProgress(model: String, percent: Double)
    case promptCacheRestore(PromptCacheRestore)
    case contextFit(ContextFitInfo)
    case cacheStore(PromptCacheDisk)
    case modelLoadFailed(model: String, reason: String)
    case modelUnloadedTTL(model: String)
    case predictError(model: String?, message: String)
    case clientDisconnected
    case serverStarted
    case serverStopped
    /// A runtime/engine line embedded in the server log ("[DEBUG] 46.30.710.704 I slot ...").
    /// `raw` excludes the "[date][LEVEL] " prefix so it string-equals the runtime copy.
    case engineLine(raw: String)
    case other(level: String, text: String)
}

struct ModelStatsEvent: Equatable {
    var modelIdentifier: String
    var stopReasonRaw: String?
    var tokensPerSecond: Double?
    var timeToFirstTokenSec: Double?
    var totalTimeSec: Double?
    var promptTokensCount: Int?
    var predictedTokensCount: Int?
    var totalTokensCount: Int?
    var totalDraftTokensCount: Int?
    var acceptedDraftTokensCount: Int?
    var rejectedDraftTokensCount: Int?
    var outputCharCount: Int          // text itself is never retained
}

struct ProxyRequestEvent: Equatable {
    enum Phase: Equatable { case started, updated, finished }
    var phase: Phase
    var id: UUID
    var model: String
    var endpoint: String
    var startedAt: Date
    var firstTokenAt: Date?
    var finishedAt: Date?
    var promptTokens: Int?
    var promptTokensEstimated: Bool
    var completionTokens: Int
    var reportedTPS: Double?
    var reportedTTFT: Double?
    var stopReason: String?
    var status: Int?
    var error: String?
}

enum StreamStatus: Equatable {
    case notStarted
    case blocked(reason: String)        // "LM Studio not running", "lms not found"
    case starting
    case running(since: Date)
    case exited(code: Int32, stderrTail: String)
    case backoff(seconds: Double)
    case droppedOversizedLine(bytes: Int)
}

struct LMEvent {
    enum Kind {
        case engine(EngineLine, EngineContext, raw: String)
        case server(ServerLine)
        case modelStats(ModelStatsEvent)
        case proxy(ProxyRequestEvent)
        case stream(EventSource, StreamStatus)
    }
    var at: Date
    var source: EventSource
    var kind: Kind
}
