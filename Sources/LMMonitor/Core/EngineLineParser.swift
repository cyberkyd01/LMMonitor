import Foundation

/// Parses llama.cpp engine lines as LM Studio relays them: the runtime stream's `message`
/// (possibly several physical lines joined by "\n") and the verbatim copies embedded in the
/// server log after its `[date][LEVEL] ` prefix.
///
/// Grammar of one physical line: `<uptime> <level> <body>` where uptime is `\d+(\.\d+)+`
/// (e.g. `46.30.710.704`, microsecond-unique and therefore the dedupe key) and level is one of
/// `I W E D`. LM Studio occasionally splits a line between the uptime and the level (seen 5× in
/// 19k lines), so the uptime is optional here: `I slot print_timing: …` still parses.
///
/// Hot path: this runs on every log line, so every regex is gated by a cheap `hasPrefix` /
/// `contains` check and compiled once (`static let`).
enum EngineLineParser {

    // MARK: - Prefix

    /// Splits `<uptime> <I|W|E|D> <body>` (uptime optional) into level and body.
    /// Returns nil when the line is not an engine line (JSON body lines, banners, blanks, the
    /// bare-uptime half of a split line, …).
    static func splitPrefix(_ raw: String) -> (level: Character, body: String)? {
        splitPrefix(raw[...])
    }

    static func splitPrefix(_ raw: Substring) -> (level: Character, body: String)? {
        let u = raw.utf8
        let end = u.endIndex
        var i = u.startIndex
        guard i < end else { return nil }

        // Optional uptime: digits and dots, at least one dot, ending in a digit, then a space.
        if isDigit(u[i]) {
            var dots = 0
            var lastWasDigit = false
            var j = i
            while j < end {
                let b = u[j]
                if isDigit(b) {
                    lastWasDigit = true
                } else if b == 0x2E, lastWasDigit {            // "."
                    dots += 1
                    lastWasDigit = false
                } else {
                    break
                }
                j = u.index(after: j)
            }
            guard dots >= 1, lastWasDigit, j < end, u[j] == 0x20 else { return nil }
            i = u.index(after: j)
        }

        guard i < end else { return nil }
        let lv = u[i]
        guard lv == 0x49 || lv == 0x57 || lv == 0x45 || lv == 0x44 else { return nil }   // I W E D
        let afterLevel = u.index(after: i)
        guard afterLevel < end, u[afterLevel] == 0x20 else { return nil }
        let bodyStart = u.index(after: afterLevel)
        guard bodyStart < end else { return nil }
        return (Character(UnicodeScalar(lv)), String(raw[bodyStart...]))
    }

    /// True when `s` looks like one physical engine line (see `splitPrefix`).
    static func isEngineLine(_ s: String) -> Bool { splitPrefix(s[...]) != nil }
    static func isEngineLine(_ s: Substring) -> Bool { splitPrefix(s) != nil }

    // MARK: - Parse

    /// Parses ONE physical line (callers split a multi-line runtime `message` on "\n" first).
    /// - nil: ignorable (empty, `graphs reused`, `graph reallocs`).
    /// - `.other(level, body)`: an engine line we have no case for (Debug ring only). A non-empty
    ///   line without any recognizable prefix is returned as `.other("?", raw)` so nothing from
    ///   the runtime stream is silently lost.
    static func parse(_ raw: String) -> EngineLine? {
        guard let (level, body) = splitPrefix(raw[...]) else {
            if raw.utf8.isEmpty || raw.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return nil }
            return .other(level: "?", text: raw)
        }
        if body.hasPrefix("slot ") { return parseSlot(level: level, body: body) }
        if body.hasPrefix("srv ") { return parseSrv(level: level, body: body) }
        if body.contains("Insufficient Memory") || body.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory") {
            return .gpuOOM(message: body)
        }
        if body.hasPrefix("ggml_metal_synchronize: error: command buffer"), rxMetalCommandBuffer.matches(body) {
            return .gpuOOM(message: body)
        }
        return .other(level: level, text: body)
    }

    // MARK: - slot …

    private static func parseSlot(level: Character, body: String) -> EngineLine? {
        if body.hasPrefix("slot print_timing:") {
            if body.contains("n_gen =") {
                if let c = rxGenProgress.captures(body), let slot = Int(c[0]), let task = Int(c[1]),
                   let nGen = Int(c[2]), let tg = Double(c[3]), let tg3 = Double(c[4]) {
                    return .genProgress(slot: slot, task: task, nGen: nGen, tgAvg: tg, tg3s: tg3)
                }
            } else if body.contains("prompt processing,") {
                if let c = rxPrefillProgress.captures(body), let slot = Int(c[0]), let task = Int(c[1]),
                   let n = Int(c[2]), let p = Double(c[3]), let t = Double(c[4]), let tps = Double(c[5]) {
                    return .prefillProgress(slot: slot, task: task, nTokens: n, progress: p, elapsedSec: t, tps: tps)
                }
            } else if body.contains("prompt eval time") {                 // test before "eval time"
                if let c = rxPromptEval.captures(body), let slot = Int(c[0]), let task = Int(c[1]),
                   let ms = Double(c[2]), let tok = Int(c[3]), let tps = Double(c[4]) {
                    return .promptEval(slot: slot, task: task, ms: ms, tokens: tok, tps: tps)
                }
            } else if body.contains("eval time =") {
                if let c = rxEval.captures(body), let slot = Int(c[0]), let task = Int(c[1]),
                   let ms = Double(c[2]), let tok = Int(c[3]), let tps = Double(c[4]) {
                    return .eval(slot: slot, task: task, ms: ms, tokens: tok, tps: tps)
                }
            } else if body.contains("total time =") {
                if let c = rxTotalTime.captures(body), let slot = Int(c[0]), let task = Int(c[1]),
                   let ms = Double(c[2]), let tok = Int(c[3]) {
                    return .totalTime(slot: slot, task: task, ms: ms, tokens: tok)
                }
            } else if body.contains("draft acceptance") {
                if let c = rxDraft.captures(body), let slot = Int(c[0]), let task = Int(c[1]),
                   let ratio = Double(c[2]), let acc = Int(c[3]), let gen = Int(c[4]), let mean = Double(c[5]) {
                    return .draftAcceptance(slot: slot, task: task, ratio: ratio, accepted: acc, generated: gen, meanLen: mean)
                }
            } else if body.contains("graphs reused") || body.contains("graph reallocs") {
                return nil
            }
        } else if body.hasPrefix("slot get_availabl:") {
            if body.contains("LCP similarity") {
                if let c = rxSelectedLCP.captures(body), let slot = Int(c[0]),
                   let fSim = Double(c[1]), let fKeep = Double(c[2]) {
                    return .slotSelected(slot: slot, reuse: .lcp(fSim: fSim, fKeep: fKeep))
                }
            } else if body.contains("by LRU") {
                if let c = rxSelectedLRU.captures(body), let slot = Int(c[0]), let tLast = Int(c[1]) {
                    return .slotSelected(slot: slot, reuse: .lru(tLast: tLast))
                }
            }
        } else if body.hasPrefix("slot launch_slot_:") {
            if let c = rxLaunch.captures(body), let slot = Int(c[0]), let task = Int(c[1]) {
                return .taskLaunched(slot: slot, task: task, isChild: c[2] != "0")
            }
        } else if body.contains("release:"), body.contains("stop processing:") {
            if let c = rxRelease.captures(body), let slot = Int(c[0]), let task = Int(c[1]), let n = Int(c[2]) {
                return .slotReleased(slot: slot, task: task, nTokens: n, truncated: c[3] != "0")
            }
        }
        return .other(level: level, text: body)
    }

    // MARK: - srv …

    private static func parseSrv(level: Character, body: String) -> EngineLine? {
        if body.contains("stop: cancel task, id_task =") {
            if let c = rxCancel.captures(body), let task = Int(c[0]) { return .taskCancelled(task: task) }
        } else if body.contains("decode: failed to find free space in the KV cache") {
            if rxKVCacheFull.matches(body) { return .kvCacheFull }
        } else if body.contains("update_slots: decode() failed:") {
            if let c = rxDecodeFailed.captures(body) { return .decodeFailed(message: c[0]) }
        } else if body.contains("decode: Compute error") {
            if let c = rxDecodeComputeError.captures(body) { return .decodeFailed(message: c[0]) }
        } else if body.contains("load_model: loading model '") {
            if let c = rxModelLoading.captures(body) { return .modelLoading(path: c[0]) }
        } else if body.contains("load_model: initializing,") {
            if let c = rxModelInitialized.captures(body), let nSlots = Int(c[0]), let nCtx = Int(c[1]) {
                return .modelInitialized(nSlots: nSlots, nCtxSlot: nCtx, kvUnified: c[2] == "true")
            }
        }
        return .other(level: level, text: body)
    }

    // MARK: - Regexes (body after the prefix; llama.cpp pads numbers, hence \s*)

    private static let rxSelectedLCP = Rx(#"^slot get_availabl: id\s+(\d+) \| task\s+-?\d+ \| selected slot by LCP similarity, f_sim_best = ([\d.]+) \(> [\d.]+ thold\), f_keep = ([\d.]+)"#)
    private static let rxSelectedLRU = Rx(#"^slot get_availabl: id\s+(\d+) \| task\s+-?\d+ \| selected slot by LRU, t_last = (-?\d+)"#)
    private static let rxLaunch = Rx(#"^slot launch_slot_: id\s+(\d+) \| task\s+(\d+) \| processing task, is_child = (\d)"#)
    private static let rxPrefillProgress = Rx(#"^slot print_timing: id\s+(\d+) \| task\s+(\d+) \| prompt processing, n_tokens =\s*(\d+), progress = ([\d.]+), t =\s*([\d.]+) s /\s*([\d.]+) tokens per second"#)
    private static let rxGenProgress = Rx(#"^slot print_timing: id\s+(\d+) \| task\s+(\d+) \| n_gen =\s*(\d+), tg =\s*([\d.]+) t/s, tg_3s =\s*([\d.]+) t/s"#)
    private static let rxPromptEval = Rx(#"^slot print_timing: id\s+(\d+) \| task\s+(\d+) \| prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens \(\s*[\d.]+ ms per token,\s*([\d.]+) tokens per second\)"#)
    private static let rxEval = Rx(#"^slot print_timing: id\s+(\d+) \| task\s+(\d+) \|\s+eval time =\s*([\d.]+) ms /\s*(\d+) tokens \(\s*[\d.]+ ms per token,\s*([\d.]+) tokens per second\)"#)
    private static let rxTotalTime = Rx(#"^slot print_timing: id\s+(\d+) \| task\s+(\d+) \|\s+total time =\s*([\d.]+) ms /\s*(\d+) tokens"#)
    private static let rxDraft = Rx(#"^slot print_timing: id\s+(\d+) \| task\s+(\d+) \| draft acceptance = ([\d.]+) \(\s*(\d+) accepted /\s*(\d+) generated\), mean len =\s*([\d.]+)"#)
    private static let rxRelease = Rx(#"^slot\s+release: id\s+(\d+) \| task\s+(\d+) \| stop processing: n_tokens = (\d+), truncated = (\d)"#)
    private static let rxCancel = Rx(#"^srv\s+stop: cancel task, id_task = (\d+)"#)
    private static let rxKVCacheFull = Rx(#"^srv\s+decode: failed to find free space in the KV cache"#)
    private static let rxDecodeFailed = Rx(#"^srv\s+update_slots: decode\(\) failed: (.*)$"#)
    private static let rxDecodeComputeError = Rx(#"^srv\s+decode: (Compute error.*)$"#)
    private static let rxModelLoading = Rx(#"^srv\s+load_model: loading model '(.+)'"#)
    private static let rxModelInitialized = Rx(#"^srv\s+load_model: initializing, n_slots = (\d+), n_ctx_slot = (\d+), kv_unified = '(true|false)'"#)
    private static let rxMetalCommandBuffer = Rx(#"^ggml_metal_synchronize: error: command buffer \d+ failed"#)

    @inline(__always) private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
}
