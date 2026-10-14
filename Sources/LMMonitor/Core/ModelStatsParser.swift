import Foundation

/// Parses one `lms log stream --source model --filter output --stats --json` object:
/// `{"timestamp":…,"data":{"type":"llm.prediction.output","output":"…","stats":{…},"modelIdentifier":"…"}}`.
/// Only `llm.prediction.output` is accepted (`llm.prediction.input` → nil). The `output` text is
/// reduced to its character count and never retained (privacy).
enum ModelStatsParser {
    static func parse(_ obj: [String: Any]) -> ModelStatsEvent? {
        guard let data = obj["data"] as? [String: Any],
              (data["type"] as? String) == "llm.prediction.output" else { return nil }
        guard let model = (data["modelIdentifier"] as? String) ?? (data["modelPath"] as? String) else { return nil }
        let stats = data["stats"] as? [String: Any] ?? [:]
        return ModelStatsEvent(
            modelIdentifier: model,
            stopReasonRaw: stats["stopReason"] as? String,
            tokensPerSecond: double(stats["tokensPerSecond"]),
            timeToFirstTokenSec: double(stats["timeToFirstTokenSec"]),
            totalTimeSec: double(stats["totalTimeSec"]),
            promptTokensCount: int(stats["promptTokensCount"]),
            predictedTokensCount: int(stats["predictedTokensCount"]),
            totalTokensCount: int(stats["totalTokensCount"]),
            totalDraftTokensCount: int(stats["totalDraftTokensCount"]),
            acceptedDraftTokensCount: int(stats["acceptedDraftTokensCount"]),
            rejectedDraftTokensCount: int(stats["rejectedDraftTokensCount"]),
            outputCharCount: (data["output"] as? String)?.count ?? 0)
    }

    /// JSONSerialization yields NSNumber (bridged to Int or Double depending on the literal);
    /// accept either, plus numeric strings.
    private static func double(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = v as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    private static func int(_ v: Any?) -> Int? {
        guard let v else { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double {
            guard d.isFinite, abs(d) < 9.0e15 else { return nil }
            return Int(d.rounded())
        }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
