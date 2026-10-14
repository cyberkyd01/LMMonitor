import Foundation

/// Design §10.8 suites 1–3: every regex of the three parsers pinned against real captured lines
/// (`Fixtures`), the cross-stream dedupe key, multi-line handling and malformed input.
enum ParserTests {
    static func run(_ t: TestContext) {
        engineLineParser(t)
        serverLineParser(t)
        modelStatsParser(t)
    }

    // MARK: - Suite 1: EngineLineParser

    static func engineLineParser(_ t: TestContext) {
        t.suite("EngineLineParser")
        let P = EngineLineParser.self

        // splitPrefix / isEngineLine
        let sp = P.splitPrefix(Fixtures.genProgress)
        t.equal("split level", sp?.level, "I")
        t.equal("split body", sp?.body, "slot print_timing: id  3 | task 133 | n_gen =  27343, tg =  13.30 t/s, tg_3s =  16.33 t/s")
        t.equal("split W", P.splitPrefix(Fixtures.taskCancelled)?.level, "W")
        t.equal("split E", P.splitPrefix(Fixtures.decodeFailed)?.level, "E")
        t.equal("split body-only glitch (uptime optional)", P.splitPrefix(Fixtures.glitchBodyOnly)?.body,
                "slot print_timing: id  0 | task 167 | prompt processing, n_tokens =   2048, progress = 0.31, t =  18.84 s / 108.72 tokens per second")
        t.check("split uptime-only glitch", P.splitPrefix(Fixtures.glitchUptimeOnly) == nil)
        t.check("split level-only glitch", P.splitPrefix(Fixtures.glitchLevelOnly) == nil)
        t.check("split no-level glitch", P.splitPrefix(Fixtures.glitchNoLevel) == nil)
        for s in ["", " ", "  \"model\": \"qwen/qwen3.8-27b\",", "{", "}", "Streaming logs from LM Studio",
                  Fixtures.srvEngineGen, "12 I x", "46.30.710.704 I", "46.30.710.704 X slot", "46.30.710.704  I slot",
                  "46.30.710.704I slot", "1. I x", ".1 I x", "46.30.710.704 i slot"] {
            t.check("not engine: \(s.prefix(30))", !P.isEngineLine(s))
        }
        t.check("engine: minimal", P.isEngineLine("1.2 I x"))
        t.check("engine: 4-part uptime", P.isEngineLine(Fixtures.slotReleased))
        t.check("engine: substring overload", P.isEngineLine(Fixtures.srvFinalBlock.split(separator: "\n")[1]))

        // every regex → expected enum, exact values
        t.equal("genProgress", P.parse(Fixtures.genProgress), .genProgress(slot: 3, task: 133, nGen: 27343, tgAvg: 13.30, tg3s: 16.33))
        t.equal("slotSelected LRU", P.parse(Fixtures.slotSelectedLRU), .slotSelected(slot: 2, reuse: .lru(tLast: -1)))
        t.equal("slotSelected LCP", P.parse(Fixtures.slotSelectedLCP), .slotSelected(slot: 1, reuse: .lcp(fSim: 0.919, fKeep: 0.986)))
        t.equal("slotSelected LCP 1.000", P.parse(Fixtures.slotSelectedLCPFull), .slotSelected(slot: 3, reuse: .lcp(fSim: 0.610, fKeep: 1.0)))
        t.equal("taskLaunched", P.parse(Fixtures.taskLaunched), .taskLaunched(slot: 2, task: 10325, isChild: false))
        t.equal("prefillProgress", P.parse(Fixtures.prefillProgress),
                .prefillProgress(slot: 1, task: 9, nTokens: 2048, progress: 0.22, elapsedSec: 13.40, tps: 152.84))
        t.equal("prefillProgress large", P.parse(Fixtures.prefillProgressLarge),
                .prefillProgress(slot: 3, task: 0, nTokens: 19076, progress: 0.53, elapsedSec: 178.67, tps: 106.77))
        t.equal("promptEval", P.parse(Fixtures.promptEval), .promptEval(slot: 2, task: 10325, ms: 1631.73, tokens: 63, tps: 38.61))
        t.equal("promptEval slow", P.parse(Fixtures.promptEvalSlow), .promptEval(slot: 2, task: 3, ms: 99725.01, tokens: 93, tps: 0.93))
        t.equal("eval", P.parse(Fixtures.evalTime), .eval(slot: 2, task: 10325, ms: 1895.66, tokens: 24, tps: 12.13))
        t.equal("eval huge", P.parse(Fixtures.evalTimeHuge), .eval(slot: 3, task: 133, ms: 2124448.22, tokens: 28373, tps: 13.35))
        t.equal("totalTime", P.parse(Fixtures.totalTime), .totalTime(slot: 2, task: 10325, ms: 3527.39, tokens: 87))
        t.check("graphs reused → nil", P.parse(Fixtures.graphsReused) == nil)
        t.check("graph reallocs → nil", P.parse(Fixtures.graphReallocs) == nil)
        t.equal("draftAcceptance", P.parse(Fixtures.draftAcceptance),
                .draftAcceptance(slot: 2, task: 10325, ratio: 0.88889, accepted: 16, generated: 18, meanLen: 3.67))
        t.equal("slotReleased", P.parse(Fixtures.slotReleased), .slotReleased(slot: 2, task: 10325, nTokens: 86, truncated: false))
        t.equal("slotReleased truncated", P.parse(Fixtures.slotReleasedTruncated), .slotReleased(slot: 3, task: 133, nTokens: 35839, truncated: true))
        t.equal("taskCancelled", P.parse(Fixtures.taskCancelled), .taskCancelled(task: 0))
        t.equal("kvCacheFull", P.parse(Fixtures.kvCacheFull), .kvCacheFull)
        t.equal("decodeFailed", P.parse(Fixtures.decodeFailed), .decodeFailed(message: "Compute error."))
        t.equal("decodeFailed (srv decode)", P.parse(Fixtures.decodeComputeError),
                .decodeFailed(message: "Compute error. off = 0, n_batch = 2048, ret = -3"))
        t.equal("gpuOOM insufficient memory", P.parse(Fixtures.oomInsufficientMemory),
                .gpuOOM(message: "error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"))
        t.equal("gpuOOM command buffer", P.parse(Fixtures.oomCommandBuffer),
                .gpuOOM(message: "ggml_metal_synchronize: error: command buffer 0 failed with status 5"))
        t.equal("modelLoading", P.parse(Fixtures.modelLoading),
                .modelLoading(path: "/Users/me/.lmstudio/models/lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q6_K.gguf"))
        t.equal("modelInitialized", P.parse(Fixtures.modelInitialized), .modelInitialized(nSlots: 4, nCtxSlot: 71168, kvUnified: true))
        t.equal("modelInitialized 102400", P.parse(Fixtures.modelInitialized102400), .modelInitialized(nSlots: 4, nCtxSlot: 102400, kvUnified: true))

        // unrecognized engine lines → .other(level, body)
        t.equal("other: loaded multimodal", P.parse(Fixtures.modelLoadedMultimodal),
                .other(level: "I", text: "srv    load_model: loaded multimodal model, '/Users/me/.lmstudio/models/lmstudio-community/Qwen3.8-27B-GGUF/mmproj-Qwen3.8-27B-BF16.gguf'"))
        t.equal("other: send_error", P.parse(Fixtures.sendError), .other(level: "E", text: "srv    send_error: task id = 0, error: Compute error."))
        t.equal("other: try_clear_id", P.parse(Fixtures.tryClearId), .other(level: "W", text: "srv  try_clear_id: purging slot 2 with 86 tokens"))
        t.equal("other: memory slot", P.parse(Fixtures.memorySlotWarning), .other(level: "W", text: "decode: failed to find a memory slot for batch of size 1"))
        t.equal("other: spec draft", P.parse(Fixtures.specDraftError), .other(level: "E", text: "spec        draft: llama_process[1] returned 1"))
        t.equal("other: listening", P.parse(Fixtures.listening), .other(level: "I", text: "srv  llama_server: listening on http://127.0.0.1:56616"))

        // LM Studio's split-line glitch
        t.equal("glitch body-only parses", P.parse(Fixtures.glitchBodyOnly),
                .prefillProgress(slot: 0, task: 167, nTokens: 2048, progress: 0.31, elapsedSec: 18.84, tps: 108.72))
        t.equal("glitch uptime-only → other(?)", P.parse(Fixtures.glitchUptimeOnly), .other(level: "?", text: "10.21.054.799"))
        t.equal("glitch level-only → other(?)", P.parse(Fixtures.glitchLevelOnly), .other(level: "?", text: "5.07.479.406 E"))
        t.equal("glitch no-level → other(?)", P.parse(Fixtures.glitchNoLevel), .other(level: "?", text: Fixtures.glitchNoLevel))

        // blank / garbage never crash
        t.check("empty → nil", P.parse("") == nil)
        t.check("blank → nil", P.parse("   \t ") == nil)
        t.equal("free text → other(?)", P.parse("hello world"), .other(level: "?", text: "hello world"))
        t.equal("banner → other(?)", P.parse(Fixtures.ndjsonBanner), .other(level: "?", text: Fixtures.ndjsonBanner))
        t.equal("bad number → other", P.parse("46.30.710.704 I slot print_timing: id  2 | task 10325 | n_gen = abc, tg = x"),
                .other(level: "I", text: "slot print_timing: id  2 | task 10325 | n_gen = abc, tg = x"))
        t.equal("bad slot select → other", P.parse("1.1 I slot get_availabl: id x | task -1 | selected slot by LRU, t_last = y"),
                .other(level: "I", text: "slot get_availabl: id x | task -1 | selected slot by LRU, t_last = y"))
        t.equal("truncated release → other", P.parse("1.1 I slot      release: id  2 | task 10325 | stop processing: n_tokens ="),
                .other(level: "I", text: "slot      release: id  2 | task 10325 | stop processing: n_tokens ="))
        t.equal("empty decode message", P.parse("1.1 E srv  update_slots: decode() failed: "), .decodeFailed(message: ""))
        _ = P.parse(String(repeating: "9.", count: 5000))
        _ = P.parse(String(repeating: "9", count: 5000) + " I slot print_timing: id 1 | task 1 | n_gen = 1, tg = 1 t/s, tg_3s = 1 t/s")
        _ = P.parse("\u{0}\u{1}\u{FFFD} I slot")
        _ = P.parse("46.30.710.704 I \u{1F600} slot print_timing")
        t.check("garbage survived", true)
        t.equal("huge uptime still parses", P.parse(String(repeating: "9", count: 50) + ".1 I srv          stop: cancel task, id_task = 7"), .taskCancelled(task: 7))

        // multi-line runtime `message`: split on "\n", parse each
        let block = Fixtures.finalBlockMessage.split(separator: "\n", omittingEmptySubsequences: false).map { P.parse(String($0)) }
        t.equal("final block parses", block, [
            .promptEval(slot: 2, task: 10325, ms: 1631.73, tokens: 63, tps: 38.61),
            .eval(slot: 2, task: 10325, ms: 1895.66, tokens: 24, tps: 12.13),
            .totalTime(slot: 2, task: 10325, ms: 3527.39, tokens: 87),
            nil, nil,
            .draftAcceptance(slot: 2, task: 10325, ratio: 0.88889, accepted: 16, generated: 18, meanLen: 3.67),
        ])

        // whole runtime scenario: no .other, two ignorable lines
        var counts: [String: Int] = [:]
        var nils = 0, total = 0
        for raw in runtimeLines() {
            total += 1
            guard let e = P.parse(raw) else { nils += 1; continue }
            counts[name(e), default: 0] += 1
        }
        t.equal("scenario runtime physical lines", total, 12)
        t.equal("scenario runtime ignorable", nils, 2)
        t.equal("scenario runtime cases", counts, ["genProgress": 3, "slotSelected": 1, "taskLaunched": 1, "promptEval": 1,
                                                    "eval": 1, "totalTime": 1, "draftAcceptance": 1, "slotReleased": 1])
    }

    // MARK: - Suite 2: ServerLineParser

    static func serverLineParser(_ t: TestContext) {
        t.suite("ServerLineParser")
        let P = ServerLineParser.self
        let m = "qwen/qwen3.8-27b"

        // prefix regex
        t.equal("prefix model tag", P.prefix.captures(Fixtures.srvChatStarted) ?? [],
                ["2026-10-14 23:49:33", "INFO", m, "", "Running chat completion on conversation with 1 messages."])
        t.equal("prefix two tags + colon", P.prefix.captures(Fixtures.srvPromptCacheRestore) ?? [],
                ["2026-10-14 00:02:33", "DEBUG", "coordinator", "INFO", "Prompt cache restore: cached_tokens=16128 uncached_tokens=20360 lifetime_efficiency=32.54%"])
        t.equal("prefix untagged engine", P.prefix.captures(Fixtures.srvEngineGen) ?? [],
                ["2026-10-14 23:49:32", "DEBUG", "", "", Fixtures.genProgress])
        t.equal("prefix three tags", P.prefix.captures(Fixtures.srvAuthEndpoint) ?? [],
                ["2026-10-14 23:50:29", "INFO", "LMSAuthenticator", "Client=lms-cli", "[Endpoint=listLoaded] Listing loaded models"])
        t.equal("prefix empty rest", P.prefix.captures(Fixtures.srvEmptyInfo) ?? [], ["2026-10-14 02:02:21", "INFO", "", "", ""])
        t.check("prefix rejects continuation", P.prefix.captures(Fixtures.logEngineContinuation) == nil)

        // embedded engine line == runtime copy (dedupe key)
        t.equal("engineLine raw == runtime line", P.parse(content: Fixtures.srvEngineGen), [.engineLine(raw: Fixtures.genProgress)])
        let serverRaws = Fixtures.scenarioServer.compactMap { NDJSON.object(Data($0.utf8)) }
            .compactMap { ($0["data"] as? [String: Any])?["content"] as? String }
            .flatMap { P.parse(content: $0) }
            .compactMap { if case .engineLine(let raw) = $0 { return raw } else { return nil } }
        t.equal("all 12 runtime lines appear verbatim in the server stream, same order", serverRaws, runtimeLines())

        // multi-line bodies: only the first line is interpreted, JSON is never parsed
        t.equal("request POST (multi-line body)", P.parse(content: Fixtures.srvRequestPOST), [.requestReceived(method: "POST", path: "/api/v0/chat/completions")])
        t.equal("request GET", P.parse(content: Fixtures.srvRequestGET), [.requestReceived(method: "GET", path: "/api/v0/models")])
        t.equal("generated prediction (multi-line)", P.parse(content: Fixtures.srvGeneratedPrediction), [.generatedPrediction(model: m)])
        t.equal("Returning JSON dropped", P.parse(content: Fixtures.srvReturningJSON), [])
        t.equal("Returning N models dropped", P.parse(content: Fixtures.srvReturningModels), [])
        t.equal("error block → other, first line only", P.parse(content: Fixtures.srvErrorBlock), [.other(level: "ERROR", text: "[LM STUDIO SERVER] {")])
        let block = P.parse(content: Fixtures.srvFinalBlock)
        t.equal("final block → 6 engine lines", block, Fixtures.finalBlockMessage.split(separator: "\n").map { .engineLine(raw: String($0)) })
        t.equal("OOM burst → 4 engine lines, all gpuOOM",
                P.parse(content: Fixtures.srvOOMBlock).map { if case .engineLine(let r) = $0 { return EngineLineParser.parse(r).map(name) ?? "nil" } else { return "?" } },
                ["gpuOOM", "gpuOOM", "gpuOOM", "gpuOOM"])
        let computeBlock: [EngineLine?] = P.parse(content: Fixtures.srvComputeErrorBlock).map {
            if case .engineLine(let r) = $0 { return EngineLineParser.parse(r) } else { return nil }
        }
        t.equal("compute error block", computeBlock, [
            .decodeFailed(message: "Compute error. off = 0, n_batch = 2048, ret = -3"),
            .other(level: "E", text: "srv    send_error: task id = 0, error: Compute error."),
            .slotReleased(slot: 3, task: 0, nTokens: 2048, truncated: false),
            .taskCancelled(task: 0),
        ])

        // model-tagged lines
        t.equal("chatStarted", P.parse(content: Fixtures.srvChatStarted), [.chatStarted(model: m, messageCount: 1)])
        t.equal("chatStarted MLX @variant", P.parse(content: Fixtures.srvChatStartedMLX), [.chatStarted(model: "qwen3.8-27b-mlx@4bit", messageCount: 185)])
        t.equal("progress 0", P.parse(content: Fixtures.srvPrefill0), [.prefillProgress(model: m, percent: 0.0)])
        t.equal("progress 66.7", P.parse(content: Fixtures.srvPrefill667), [.prefillProgress(model: m, percent: 66.7)])
        t.equal("progress 100", P.parse(content: Fixtures.srvPrefill100), [.prefillProgress(model: m, percent: 100.0)])
        t.equal("progress MLX", P.parse(content: Fixtures.srvPrefillMLX), [.prefillProgress(model: "qwen3.8-27b-mlx@4bit", percent: 20.7)])
        t.equal("streamingStarted", P.parse(content: Fixtures.srvStreamingStarted), [.streamingStarted(model: m)])
        t.equal("streamingFinished", P.parse(content: Fixtures.srvStreamingFinished), [.streamingFinished(model: m)])
        t.equal("predictError", P.parse(content: Fixtures.srvPredictError),
                [.predictError(model: m, message: #"{"code":500,"message":"Compute error.","type":"server_error"}"#)])
        t.equal("terminated", P.parse(content: Fixtures.srvTerminated), [.predictError(model: m, message: "terminated")])
        t.equal("model ERROR generic", P.parse(content: Fixtures.srvModelUnloadedError),
                [.predictError(model: "qwen3.8-27b-mlx@6bit", message: "Model unloaded.")])
        if case .predictError(let model, let msg)? = P.parse(content: Fixtures.srvContextOverflowError).first {
            t.equal("overflow error model", model, "qwen3.8-27b-mlx")
            t.check("overflow error message", msg.hasPrefix("Context overflow policy error: TruncateMiddle") && msg.hasSuffix("different context overflow policy."), msg)
        } else { t.check("overflow error", false) }
        t.equal("tool calls → other", P.parse(content: Fixtures.srvToolCalls), [.other(level: "INFO", text: "[\(m)] Model generated tool calls: []")])
        t.equal("done reasoning → other", P.parse(content: Fixtures.srvDoneReasoning),
                [.other(level: "INFO", text: "[qwen3.8-27b-mlx] Done reasoning. Reasoned for 6061.49 seconds.")])
        if case .other(let level, let text)? = P.parse(content: Fixtures.srvWarnReasoning).first {
            t.equal("WARN level", level, "WARN")
            t.check("WARN text", text.hasPrefix("[qwen3.8-27b-mlx] No valid custom reasoning fields"), text)
        } else { t.check("WARN other", false) }

        // MLX coordinator / context_fit / cache_store
        t.equal("promptCacheRestore", P.parse(content: Fixtures.srvPromptCacheRestore),
                [.promptCacheRestore(PromptCacheRestore(cachedTokens: 16128, uncachedTokens: 20360, lifetimeEfficiency: 32.54))])
        t.equal("promptCacheRestore zero", P.parse(content: Fixtures.srvPromptCacheRestoreZero),
                [.promptCacheRestore(PromptCacheRestore(cachedTokens: 0, uncachedTokens: 411, lifetimeEfficiency: 32.29))])
        t.equal("contextFit", P.parse(content: Fixtures.srvContextFit), [.contextFit(ContextFitInfo(
            family: "qwen3_5", maxContext: 262144, fitted: 55040,
            workingSetBytes: 28_991_029_248, reserveBytes: 3_221_225_472, safeCeilingBytes: 25_769_803_776, baselineBytes: 16_052_440_269,
            fullKVBytesPerToken: 65536, promptInputBytesPerToken: 10240, attentionBytesPerToken: 98304, estimatedPeakBytes: 25_791_278_612))])
        t.equal("contextFit without optional fields", P.parse(content:
            "[2026-10-02 04:58:35][DEBUG][context_fit][INFO]: Model context auto-fit: family=x max=4,096 fitted=1,024 working_set=1.00GiB reserve=0.50GiB safe_ceiling=0.50GiB baseline=0.25GiB full_kv=1B/token estimated_peak=0.30GiB"),
            [.contextFit(ContextFitInfo(family: "x", maxContext: 4096, fitted: 1024, workingSetBytes: 1_073_741_824, reserveBytes: 536_870_912,
                                        safeCeilingBytes: 536_870_912, baselineBytes: 268_435_456, fullKVBytesPerToken: 1,
                                        promptInputBytesPerToken: nil, attentionBytesPerToken: nil, estimatedPeakBytes: 322_122_547))])
        t.equal("gib 27.00", P.gib("27.00"), 28_991_029_248)
        t.equal("gib garbage", P.gib("x"), nil)
        t.equal("cacheStore", P.parse(content: Fixtures.srvCacheStore), [.cacheStore(PromptCacheDisk(usedMiB: 17797.9, capMiB: 35004.7, records: 262))])
        t.equal("disk_budget → other", P.parse(content: Fixtures.srvDiskBudget),
                [.other(level: "DEBUG", text: "[disk_budget][INFO] VLM prompt cache disk budget: stage=provisional cap_gib=30.00")])

        // untagged server events
        if case .modelLoadFailed(let model, let reason)? = P.parse(content: Fixtures.srvModelLoadFailedGuardrail).first {
            t.equal("loadFailed model", model, "qwen3.8-27b-mlx")
            t.check("loadFailed reason", reason.hasPrefix("Model loading was stopped due to insufficient system resources") && reason.hasSuffix("guardrails in settings."), reason)
        } else { t.check("loadFailed guardrail", false) }
        t.equal("loadFailed short", P.parse(content: Fixtures.srvModelLoadFailedShort), [.modelLoadFailed(model: m, reason: "Error loading model.")])
        t.equal("LLMProcess load failure → other", P.parse(content: Fixtures.srvLLMProcessFailed),
                [.other(level: "DEBUG", text: "[LLMProcess] Failed to load model _0x44052f [Error]: Failed to load model.")])
        t.equal("TTL unload", P.parse(content: Fixtures.srvTTLUnload), [.modelUnloadedTTL(model: "qwen3.8-27b-mlx")])
        t.equal("clientDisconnected", P.parse(content: Fixtures.srvClientDisconnected), [.clientDisconnected])
        t.equal("LMSAuthenticator disconnect is not a client disconnect", P.parse(content: Fixtures.srvAuthDisconnected),
                [.other(level: "DEBUG", text: "[LMSAuthenticator][Client=lms-cli] Client disconnected.")])
        t.equal("three-tag other", P.parse(content: Fixtures.srvAuthEndpoint),
                [.other(level: "INFO", text: "[LMSAuthenticator][Client=lms-cli] [Endpoint=listLoaded] Listing loaded models")])
        t.equal("serverStarted", P.parse(content: Fixtures.srvServerStarted), [.serverStarted])
        t.equal("serverStopped", P.parse(content: Fixtures.srvServerStopped), [.serverStopped])
        t.equal("empty INFO → nothing", P.parse(content: Fixtures.srvEmptyInfo), [])
        t.equal("JIT → other", P.parse(content: Fixtures.srvJIT), [.other(level: "INFO", text: "Just-in-time model loading active.")])
        t.equal("unexpected endpoint → other", P.parse(content: Fixtures.srvUnexpectedEndpoint),
                [.other(level: "ERROR", text: "Unexpected endpoint or method. (POST /api/v0/models/unload). Returning 200 anyway")])
        t.equal("supported endpoints → other", P.parse(content: Fixtures.srvSupportedEndpoints), [.other(level: "INFO", text: "[LM STUDIO SERVER] Supported endpoints:")])
        t.equal("stopGenerating → other", P.parse(content: Fixtures.srvStopGenerating),
                [.other(level: "DEBUG", text: "stopGenerating() without a request_id is deprecated. Taking no action")])
        t.equal("plugin → other", P.parse(content: Fixtures.srvPlugin),
                [.other(level: "INFO", text: "[Plugin(danielsig/duckduckgo)] stdout: [Tools Prvdr.] Register with LM Studio")])
        if case .other(let level, let text)? = P.parse(content: Fixtures.srvMLXTruncate).first {
            t.equal("MLX truncate level", level, "DEBUG")
            t.check("MLX truncate text", text.hasPrefix("[MLXAmphibianEngine][INFO] TruncateMiddle policy activated"), text)
        } else { t.check("MLX truncate other", false) }
        if case .other(_, let text)? = P.parse(content: Fixtures.srvTransformers).first {
            t.check("transformers text", text.hasPrefix("[transformers] Unrecognized keys"), text)
        } else { t.check("transformers other", false) }

        // LM Studio split-line glitch, as seen in the server stream
        t.equal("glitch uptime-only → other", P.parse(content: Fixtures.srvGlitchUptime), [.other(level: "DEBUG", text: "10.21.054.799")])
        t.equal("glitch body → engineLine", P.parse(content: Fixtures.srvGlitchBody), [.engineLine(raw: Fixtures.glitchBodyOnly)])
        t.equal("glitch no-level → other", P.parse(content: Fixtures.srvGlitchNoLevel), [.other(level: "DEBUG", text: Fixtures.glitchNoLevel)])

        // persisted log file, one physical line at a time
        t.equal("log continuation engine line", P.parse(content: Fixtures.logEngineContinuation), [.engineLine(raw: Fixtures.logEngineContinuation)])
        t.equal("log continuation == runtime line", Fixtures.logEngineContinuation, Fixtures.evalTime)
        t.equal("log JSON continuation → nothing", P.parse(content: Fixtures.logJSONContinuation), [])
        t.equal("log JSON close → nothing", P.parse(content: Fixtures.logJSONClose), [])
        t.equal("empty content → nothing", P.parse(content: ""), [])
        t.equal("newline only → nothing", P.parse(content: "\n"), [])
        t.equal("banner → nothing", P.parse(content: Fixtures.ndjsonBanner), [])
        let kv = Fixtures.logKVSequence.split(separator: "\n").map { P.parse(content: String($0)) }
        t.check("KV sequence: one engine line per physical line", kv.allSatisfy { lines in
            guard lines.count == 1, case .engineLine = lines[0] else { return false }
            return true
        })
        t.equal("KV sequence parses", kv.map { if case .engineLine(let r) = $0[0] { return EngineLineParser.parse(r).map(name) ?? "nil" } else { return "?" } },
                ["other", "other", "other", "other", "other", "kvCacheFull"])

        // whole server scenario
        var counts: [String: Int] = [:]
        for s in Fixtures.scenarioServer.compactMap({ NDJSON.object(Data($0.utf8)) })
            .compactMap({ ($0["data"] as? [String: Any])?["content"] as? String }).flatMap({ P.parse(content: $0) }) {
            counts[name(s), default: 0] += 1
        }
        t.equal("scenario server cases", counts, ["engineLine": 12, "requestReceived": 1, "chatStarted": 1, "prefillProgress": 4, "generatedPrediction": 1, "other": 1])

        // garbage never crashes
        for s in ["[", "[]", "[2026-10-14 23:49:33]", "[2026-10-14 23:49:33][INFO", "[2026-10-14 23:49:33][NOPE] x",
                  "[2026-10-14 23:49:33][INFO][", "[2026-10-14 23:49:33][INFO][][] :", "\u{0}", String(repeating: "\n", count: 100),
                  "[2026-10-14 23:49:33][DEBUG] Received request: ", "[2026-10-14 23:49:33][ERROR] Failed to load model \"x",
                  "[2026-10-14 23:49:33][DEBUG][context_fit][INFO]: Model context auto-fit: family=x max=a fitted=b",
                  "[2026-10-14 23:49:33][DEBUG][cache_store][INFO]: VLM prompt cache disk usage: used_mib=x",
                  "[2026-10-14 23:49:33][INFO][m] Prompt processing progress: x%", "[2026-10-14 23:49:33][INFO][m] Running chat completion on conversation with x messages."] {
            _ = P.parse(content: s)
        }
        t.check("garbage survived", true)
        t.equal("unknown level → not prefixed", P.parse(content: "[2026-10-14 23:49:33][NOPE] x"), [])
        t.equal("bad progress → other", P.parse(content: "[2026-10-14 23:49:33][INFO][m] Prompt processing progress: x%"),
                [.other(level: "INFO", text: "[m] Prompt processing progress: x%")])
        let longText = String(repeating: "x", count: 1000)
        if case .other(_, let text)? = P.parse(content: "[2026-10-14 23:49:33][INFO] \(longText)").first {
            t.check("other text clipped", text.count <= 300, "\(text.count)")
        } else { t.check("other long", false) }

        // parseLocalDate
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.autoupdatingCurrent
        if let d = P.parseLocalDate("2026-10-14 23:49:33") {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            t.equal("date components", [c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 10, 14, 23, 49, 33])
        } else { t.check("parseLocalDate", false) }
        t.check("date from prefix capture", P.parseLocalDate(P.prefix.captures(Fixtures.srvChatStarted)?[0] ?? "") != nil)
        for bad in ["", "garbage", "2026-13-14 23:49:33", "2026-10-14T23:49:33", "2026-10-14 24:00:00", "2026-10-14 23:49:3", "2026-10-14 23:49:33 "] {
            t.check("bad date nil: \(bad)", P.parseLocalDate(bad) == nil)
        }
    }

    // MARK: - Suite 3: ModelStatsParser

    static func modelStatsParser(_ t: TestContext) {
        t.suite("ModelStatsParser")
        guard let obj = NDJSON.object(Data(Fixtures.modelOutputLine.utf8)) else { t.check("decode output line", false); return }
        t.near("timestamp", NDJSON.timestamp(obj)?.timeIntervalSince1970, 1792001976.732, tol: 1e-3)
        guard let e = ModelStatsParser.parse(obj) else { t.check("parse output", false); return }
        t.equal("model", e.modelIdentifier, "qwen/qwen3.8-27b")
        t.equal("stopReason", e.stopReasonRaw, "maxPredictedTokensReached")
        t.near("tps", e.tokensPerSecond, 12.133003034305803, tol: 1e-12)
        t.near("ttft", e.timeToFirstTokenSec, 1.631729, tol: 1e-12)
        t.near("total time", e.totalTimeSec, 3.527385, tol: 1e-12)
        t.equal("prompt tokens", e.promptTokensCount, 63)
        t.equal("predicted tokens", e.predictedTokensCount, 24)
        t.equal("total tokens", e.totalTokensCount, 87)
        t.equal("draft total", e.totalDraftTokensCount, 18)
        t.equal("draft accepted", e.acceptedDraftTokensCount, 16)
        t.equal("draft rejected", e.rejectedDraftTokensCount, 2)
        t.equal("output char count (text not retained)", e.outputCharCount, 86)
        t.check("whole event", e == ModelStatsEvent(
            modelIdentifier: "qwen/qwen3.8-27b", stopReasonRaw: "maxPredictedTokensReached", tokensPerSecond: 12.133003034305803,
            timeToFirstTokenSec: 1.631729, totalTimeSec: 3.527385, promptTokensCount: 63, predictedTokensCount: 24, totalTokensCount: 87,
            totalDraftTokensCount: 18, acceptedDraftTokensCount: 16, rejectedDraftTokensCount: 2, outputCharCount: 86))

        // input events and non-objects are ignored
        if let input = NDJSON.object(Data(Fixtures.modelInputLine.utf8)) {
            t.check("input line → nil", ModelStatsParser.parse(input) == nil)
        } else { t.check("decode input line", false) }
        t.check("banner → no object", NDJSON.object(Data(Fixtures.ndjsonBanner.utf8)) == nil)
        t.check("blank → no object", NDJSON.object(Data("".utf8)) == nil)
        t.check("no data → nil", ModelStatsParser.parse(["timestamp": 1]) == nil)
        t.check("no type → nil", ModelStatsParser.parse(["data": ["modelIdentifier": "m"]]) == nil)
        t.check("no model → nil", ModelStatsParser.parse(["data": ["type": "llm.prediction.output"]]) == nil)

        // Int vs Double numbers, via JSONSerialization and via literal dictionaries
        let mixed = #"{"timestamp":1,"data":{"type":"llm.prediction.output","modelIdentifier":"m","output":"héllo 👋","stats":{"tokensPerSecond":12,"timeToFirstTokenSec":2,"promptTokensCount":63.0,"predictedTokensCount":24,"totalTokensCount":"87","stopReason":"eosFound"}}}"#
        if let o = NDJSON.object(Data(mixed.utf8)), let e2 = ModelStatsParser.parse(o) {
            t.equal("int tps", e2.tokensPerSecond, 12.0)
            t.equal("int ttft", e2.timeToFirstTokenSec, 2.0)
            t.equal("double prompt count", e2.promptTokensCount, 63)
            t.equal("int predicted", e2.predictedTokensCount, 24)
            t.equal("string total", e2.totalTokensCount, 87)
            t.equal("missing total time", e2.totalTimeSec, nil)
            t.equal("missing draft", e2.totalDraftTokensCount, nil)
            t.equal("stop reason", e2.stopReasonRaw, "eosFound")
            t.equal("unicode output count", e2.outputCharCount, 7)
        } else { t.check("mixed parse", false) }
        let literal: [String: Any] = ["data": ["type": "llm.prediction.output", "modelPath": "p", "stats": ["tokensPerSecond": 3, "promptTokensCount": 5.0, "predictedTokensCount": "x", "totalTimeSec": "nan"]]]
        if let e3 = ModelStatsParser.parse(literal) {
            t.equal("modelPath fallback", e3.modelIdentifier, "p")
            t.equal("literal int tps", e3.tokensPerSecond, 3.0)
            t.equal("literal double count", e3.promptTokensCount, 5)
            t.equal("bad string count", e3.predictedTokensCount, nil)
            t.equal("nan string", e3.totalTimeSec, nil)
            t.equal("no output", e3.outputCharCount, 0)
        } else { t.check("literal parse", false) }
        let garbage: [String: Any] = ["data": ["type": "llm.prediction.output", "modelIdentifier": "m", "stats": "not a dict", "output": 42]]
        if let e4 = ModelStatsParser.parse(garbage) {
            t.equal("garbage stats → nil fields", e4.tokensPerSecond, nil)
            t.equal("non-string output → 0", e4.outputCharCount, 0)
        } else { t.check("garbage parse", false) }
    }

    // MARK: - Helpers

    /// All physical engine lines of the runtime scenario, in order (multi-line messages split).
    static func runtimeLines() -> [String] {
        Fixtures.scenarioRuntime.compactMap { NDJSON.object(Data($0.utf8)) }
            .compactMap { ($0["data"] as? [String: Any])?["message"] as? String }
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    }

    static func name(_ e: EngineLine) -> String {
        switch e {
        case .slotSelected: return "slotSelected"
        case .taskLaunched: return "taskLaunched"
        case .prefillProgress: return "prefillProgress"
        case .genProgress: return "genProgress"
        case .promptEval: return "promptEval"
        case .eval: return "eval"
        case .totalTime: return "totalTime"
        case .draftAcceptance: return "draftAcceptance"
        case .slotReleased: return "slotReleased"
        case .taskCancelled: return "taskCancelled"
        case .decodeFailed: return "decodeFailed"
        case .gpuOOM: return "gpuOOM"
        case .kvCacheFull: return "kvCacheFull"
        case .modelLoading: return "modelLoading"
        case .modelInitialized: return "modelInitialized"
        case .other: return "other"
        }
    }

    static func name(_ s: ServerLine) -> String {
        switch s {
        case .requestReceived: return "requestReceived"
        case .chatStarted: return "chatStarted"
        case .streamingStarted: return "streamingStarted"
        case .streamingFinished: return "streamingFinished"
        case .generatedPrediction: return "generatedPrediction"
        case .prefillProgress: return "prefillProgress"
        case .promptCacheRestore: return "promptCacheRestore"
        case .contextFit: return "contextFit"
        case .cacheStore: return "cacheStore"
        case .modelLoadFailed: return "modelLoadFailed"
        case .modelUnloadedTTL: return "modelUnloadedTTL"
        case .predictError: return "predictError"
        case .clientDisconnected: return "clientDisconnected"
        case .serverStarted: return "serverStarted"
        case .serverStopped: return "serverStopped"
        case .engineLine: return "engineLine"
        case .other: return "other"
        }
    }
}
