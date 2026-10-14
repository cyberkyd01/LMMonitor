import Foundation

/// Per-model statistics over the prediction history (design §3).
/// Token-rate statistics only count finished predictions with ≥ 20 generated tokens, because
/// very short answers make tok/s noisy. Counts, totals and errors include every record.
enum Aggregates {
    static let minTokensForRates = 20

    static func compute(_ records: [PredictionRecord]) -> [ModelAggregate] {
        var groups: [String: [PredictionRecord]] = [:]
        for r in records { groups[ModelKey.norm(r.model), default: []].append(r) }

        var out: [ModelAggregate] = []
        out.reserveCapacity(groups.count)
        for (key, recs) in groups {
            let rated = recs.filter { $0.phase == .finished && ($0.generatedTokens ?? 0) >= minTokensForRates }
            let tps = rated.compactMap { $0.tokensPerSecond }.filter { $0.isFinite && $0 > 0 }.sorted()
            let prefill = rated.compactMap { $0.prefillTokensPerSecond }.filter { $0.isFinite && $0 > 0 }
            let ttft = rated.compactMap { $0.timeToFirstToken }.filter { $0.isFinite && $0 >= 0 }
            out.append(ModelAggregate(
                id: key,
                count: recs.count,
                avgTps: mean(tps),
                medianTps: median(sorted: tps),
                p10Tps: percentile(sorted: tps, 0.10),
                avgPrefillTps: mean(prefill),
                avgTTFT: mean(ttft),
                totalGenerated: recs.reduce(0) { $0 + ($1.generatedTokens ?? 0) },
                totalPrompt: recs.reduce(0) { $0 + promptTokens($1) },
                errors: recs.filter { $0.phase == .errored }.count))
        }
        return out.sorted { a, b in a.count != b.count ? a.count > b.count : a.id < b.id }
    }

    static func mean(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Median of an ascending-sorted array (mean of the two middle values for even counts).
    static func median(sorted v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }

    /// Nearest-rank percentile of an ascending-sorted array (`p` in 0...1).
    static func percentile(sorted v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let rank = Int((Double(v.count - 1) * min(1, max(0, p))).rounded())
        return v[rank]
    }

    private static func promptTokens(_ r: PredictionRecord) -> Int {
        r.prompt.totalTokens ?? ((r.prompt.cachedTokens ?? 0) + (r.prompt.processedTokens ?? 0))
    }
}
