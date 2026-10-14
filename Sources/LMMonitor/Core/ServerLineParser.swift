import Foundation

/// Parses LM Studio server-log messages: the `content` of a `server.log` NDJSON event
/// (`lms log stream --source server --json`) or one physical line of the persisted
/// `~/.lmstudio/server-logs/YYYY-MM/*.log` file.
///
/// A `content` may span several physical lines: a `[date][LEVEL]…` first line followed by
/// continuation lines (a JSON body, or further engine lines when LM Studio batched several
/// llama.cpp lines into one message). Only the first line is matched against server patterns;
/// JSON bodies are never parsed or retained. Every physical line that `EngineLineParser.isEngineLine`
/// accepts (the first line's text after the prefix, and each continuation line) becomes
/// `.engineLine(raw:)` whose `raw` string-equals the runtime stream's copy of that line — that
/// equality is the dedupe key.
enum ServerLineParser {

    /// `[2026-10-14 23:49:33][INFO][tag1][tag2]: rest` — tags and the colon are optional.
    static let prefix = Rx(#"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\[(INFO|DEBUG|WARN|WARNING|ERROR)\](?:\[([^\]]*)\])?(?:\[([^\]]*)\])?:?\s?(.*)$"#)

    /// Parses one server-log message (possibly multi-line). See the type comment.
    static func parse(content: String) -> [ServerLine] {
        var out: [ServerLine] = []
        var isFirst = true
        var start = content.startIndex
        let u = content.utf8
        while true {
            let nl = u[start...].firstIndex(of: 0x0A)
            let line = content[start..<(nl ?? content.endIndex)]
            if isFirst {
                parseFirstLine(line, into: &out)
                isFirst = false
            } else if EngineLineParser.isEngineLine(line) {
                out.append(.engineLine(raw: String(line)))
            }
            guard let nl else { break }
            start = u.index(after: nl)
        }
        return out
    }

    /// Parses the persisted-log timestamp (`yyyy-MM-dd HH:mm:ss`, local time zone).
    static func parseLocalDate(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count == 19, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x20, u[13] == 0x3A, u[16] == 0x3A else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                let b = u[i]
                guard b >= 0x30, b <= 0x39 else { return nil }
                v = v * 10 + Int(b - 0x30)
            }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let se = num(17..<19),
              (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59, se <= 60 else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = se
        return calendar.date(from: c)
    }

    // MARK: - First line

    private static func parseFirstLine(_ line: Substring, into out: inout [ServerLine]) {
        guard let c = prefix.captures(String(line)) else {
            // No `[date][LEVEL]` prefix: a persisted-log continuation line. Engine text is kept,
            // JSON body lines are dropped.
            if EngineLineParser.isEngineLine(line) { out.append(.engineLine(raw: String(line))) }
            return
        }
        let level = c[1], tag1 = c[2], tag2 = c[3], rest = c[4]

        if tag1.isEmpty {
            if EngineLineParser.isEngineLine(rest) { out.append(.engineLine(raw: rest)); return }
            if rest.isEmpty { return }
            if rest.hasPrefix("Received request: ") {
                if let m = rxRequest.captures(rest) { out.append(.requestReceived(method: m[0], path: m[1])); return }
            } else if rest.hasPrefix("Failed to load model \"") {
                if let m = rxLoadFailed.captures(rest) { out.append(.modelLoadFailed(model: m[0], reason: m[1])); return }
            } else if rest.hasPrefix("Unloading model ") {
                if let m = rxTTL.captures(rest) { out.append(.modelUnloadedTTL(model: m[0])); return }
            } else if rest.hasPrefix("Server started.") {
                out.append(.serverStarted); return
            } else if rest.hasPrefix("Server stopped.") {
                out.append(.serverStopped); return
            } else if rest.hasPrefix("Returning ") {
                return                                     // model lists / response bodies: drop
            }
            out.append(.other(level: level, text: clip(rest)))
            return
        }

        switch tag1 {
        case "LM STUDIO SERVER":
            if rest.contains("Client disconnected") { out.append(.clientDisconnected); return }
        case "coordinator":
            if rest.hasPrefix("Prompt cache restore: "), let m = rxCacheRestore.captures(rest),
               let cached = Int(m[0]), let uncached = Int(m[1]), let eff = Double(m[2]) {
                out.append(.promptCacheRestore(PromptCacheRestore(cachedTokens: cached, uncachedTokens: uncached, lifetimeEfficiency: eff)))
                return
            }
        case "context_fit":
            if rest.hasPrefix("Model context auto-fit: "), let info = parseContextFit(rest) {
                out.append(.contextFit(info)); return
            }
        case "cache_store":
            if rest.hasPrefix("VLM prompt cache disk usage: "), let m = rxCacheStore.captures(rest),
               let used = Double(m[0]), let cap = Double(m[1]), let records = Int(m[2]) {
                out.append(.cacheStore(PromptCacheDisk(usedMiB: used, capMiB: cap, records: records)))
                return
            }
        default:
            if isModelTag(tag1, tag2: tag2) {
                if let line = parseModelLine(model: tag1, level: level, rest: rest) { out.append(line) }
                return
            }
        }
        out.append(.other(level: level, text: clip(tagged(tag1, tag2, rest))))
    }

    // MARK: - Model-tagged lines

    /// Model tags never carry a second bracket; python-module tags (`[model_kit][INFO]`) and
    /// `[LMSAuthenticator][Client=…]` do. The remaining tag2-less non-model tags are listed.
    private static func isModelTag(_ tag1: String, tag2: String) -> Bool {
        if !tag2.isEmpty { return false }
        if tag1.hasPrefix("Plugin(") { return false }
        return !nonModelTags.contains(tag1)
    }
    private static let nonModelTags: Set<String> = [
        "LM STUDIO SERVER", "coordinator", "context_fit", "cache_store", "disk_budget", "model_kit",
        "transformers", "LMSAuthenticator", "MLXAmphibianEngine", "LLMProcess",
    ]

    private static func parseModelLine(model: String, level: String, rest: String) -> ServerLine? {
        if rest.hasPrefix("Prompt processing progress: ") {
            if let m = rxProgress.captures(rest), let pct = Double(m[0]) { return .prefillProgress(model: model, percent: pct) }
        } else if rest.hasPrefix("Running chat completion on conversation with ") {
            if let m = rxChatStarted.captures(rest), let n = Int(m[0]) { return .chatStarted(model: model, messageCount: n) }
        } else if rest.hasPrefix("Streaming response...") {
            return .streamingStarted(model: model)
        } else if rest.hasPrefix("Finished streaming response") {
            return .streamingFinished(model: model)
        } else if rest.hasPrefix("Generated prediction: ") {
            return .generatedPrediction(model: model)
        } else if rest.hasPrefix("Engine protocol predict stream returned an error: ") {
            if let m = rxPredictError.captures(rest) { return .predictError(model: model, message: m[0]) }
        } else if rest.hasPrefix("terminated") {
            return .predictError(model: model, message: "terminated")
        }
        if level == "ERROR" {
            // e.g. "Context overflow policy error: …. Error Data: n/a, Additional Data: n/a",
            //      "Model unloaded.. Error Data: n/a, Additional Data: n/a"
            return .predictError(model: model, message: clip(stripErrorData(rest)))
        }
        return .other(level: level, text: clip("[\(model)] \(rest)"))
    }

    // MARK: - context_fit

    private static func parseContextFit(_ rest: String) -> ContextFitInfo? {
        guard let m = rxContextFit.captures(rest),
              let maxCtx = Int(m[1].replacingOccurrences(of: ",", with: "")),
              let fitted = Int(m[2].replacingOccurrences(of: ",", with: "")),
              let ws = gib(m[3]), let reserve = gib(m[4]), let ceiling = gib(m[5]), let baseline = gib(m[6]),
              let fullKV = Int(m[7]), let peak = gib(m[10]) else { return nil }
        return ContextFitInfo(
            family: m[0], maxContext: maxCtx, fitted: fitted,
            workingSetBytes: ws, reserveBytes: reserve, safeCeilingBytes: ceiling, baselineBytes: baseline,
            fullKVBytesPerToken: fullKV,
            promptInputBytesPerToken: m[8].isEmpty ? nil : Int(m[8]),
            attentionBytesPerToken: m[9].isEmpty ? nil : Int(m[9]),
            estimatedPeakBytes: peak)
    }

    /// "27.00" GiB → 28991029248 bytes (rounded).
    static func gib(_ s: String) -> UInt64? {
        guard let d = Double(s), d.isFinite, d >= 0 else { return nil }
        return UInt64((d * 1_073_741_824).rounded())
    }

    // MARK: - Helpers

    private static func stripErrorData(_ s: String) -> String {
        if let r = s.range(of: ". Error Data: ") { return String(s[..<r.lowerBound]) }
        return s
    }
    private static func tagged(_ tag1: String, _ tag2: String, _ rest: String) -> String {
        tag2.isEmpty ? "[\(tag1)] \(rest)" : "[\(tag1)][\(tag2)] \(rest)"
    }
    /// `.other` text only feeds the 50-entry Debug ring; keep it bounded.
    private static func clip(_ s: String) -> String {
        s.count <= 300 ? s : String(s.prefix(299)) + "…"
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.autoupdatingCurrent
        return c
    }()

    // MARK: - Regexes

    private static let rxRequest = Rx(#"^Received request: ([A-Z]+) to (\S+)"#)
    private static let rxLoadFailed = Rx(#"^Failed to load model "([^"]+)"\. Error: (.*)$"#)
    private static let rxTTL = Rx(#"^Unloading model (.+?) due to TTL expiration\."#)
    private static let rxCacheRestore = Rx(#"^Prompt cache restore: cached_tokens=(\d+) uncached_tokens=(\d+) lifetime_efficiency=([\d.]+)%"#)
    private static let rxContextFit = Rx(#"^Model context auto-fit: family=(\S+) max=([\d,]+) fitted=([\d,]+) working_set=([\d.]+)GiB reserve=([\d.]+)GiB safe_ceiling=([\d.]+)GiB baseline=([\d.]+)GiB full_kv=(\d+)B/token(?: prompt_inputs=(\d+)B/token)?(?: attention=(\d+)B/token)?.*?estimated_peak=([\d.]+)GiB"#)
    private static let rxCacheStore = Rx(#"^VLM prompt cache disk usage: used_mib=([\d.]+) cap_mib=([\d.]+) .*?records=(\d+)"#)
    private static let rxProgress = Rx(#"^Prompt processing progress: ([\d.]+)%"#)
    private static let rxChatStarted = Rx(#"^Running chat completion on conversation with (\d+) messages\."#)
    private static let rxPredictError = Rx(#"^Engine protocol predict stream returned an error: (.*?)(?:\. Error Data: .*)?$"#)
}
