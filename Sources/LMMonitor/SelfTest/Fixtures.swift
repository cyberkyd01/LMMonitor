import Foundation

// GENERATED from real captured data (SCRATCH/gen_fixtures.py) — every constant is a verbatim copy of a
// physical line (or decoded multi-line `message`/`content`) seen on this machine on 2026-10-01…15.
// Sources: ~/.lmstudio/server-logs/2026-10/*.log and `lms log stream --json` captures of the
// 23:49:33–36 test request (runtime / server / model streams).
//
// swiftlint:disable all
enum Fixtures {
    // MARK: - Engine lines (runtime `message` text; identical text appears after the server-log prefix)

    /// n_gen line (one every ~3 s per busy slot)
    static let genProgress = #"46.26.021.689 I slot print_timing: id  3 | task 133 | n_gen =  27343, tg =  13.30 t/s, tg_3s =  16.33 t/s"#
    /// slot selection, LRU (no prefix reuse)
    static let slotSelectedLRU = #"46.27.152.761 I slot get_availabl: id  2 | task -1 | selected slot by LRU, t_last = -1"#
    /// slot selection, LCP similarity (prefix reuse, f_keep = 0.986)
    static let slotSelectedLCP = #"2.52.514.405 I slot get_availabl: id  1 | task -1 | selected slot by LCP similarity, f_sim_best = 0.919 (> 0.100 thold), f_keep = 0.986"#
    /// LCP with f_keep = 1.000
    static let slotSelectedLCPFull = #"3.41.087.945 I slot get_availabl: id  3 | task -1 | selected slot by LCP similarity, f_sim_best = 0.610 (> 0.100 thold), f_keep = 1.000"#
    /// task launch
    static let taskLaunched = #"46.27.152.809 I slot launch_slot_: id  2 | task 10325 | processing task, is_child = 0"#
    /// prompt processing progress
    static let prefillProgress = #"0.45.503.541 I slot print_timing: id  1 | task 9 | prompt processing, n_tokens =   2048, progress = 0.22, t =  13.40 s / 152.84 tokens per second"#
    /// prompt processing progress, 5-digit n_tokens / 3-digit seconds
    static let prefillProgressLarge = #"3.15.101.142 I slot print_timing: id  3 | task 0 | prompt processing, n_tokens =  19076, progress = 0.53, t = 178.67 s / 106.77 tokens per second"#
    /// final block line 1
    static let promptEval = #"46.30.710.704 I slot print_timing: id  2 | task 10325 | prompt eval time =    1631.73 ms /    63 tokens (   25.90 ms per token,    38.61 tokens per second)"#
    /// prompt eval with 4-digit ms-per-token (fewer pad spaces)
    static let promptEvalSlow = #"2.14.949.644 I slot print_timing: id  2 | task 3 | prompt eval time =   99725.01 ms /    93 tokens ( 1072.31 ms per token,     0.93 tokens per second)"#
    /// final block line 2
    static let evalTime = #"46.30.710.722 I slot print_timing: id  2 | task 10325 |        eval time =    1895.66 ms /    24 tokens (   82.42 ms per token,    12.13 tokens per second)"#
    /// eval time with 7-digit ms and 5-digit tokens (runaway task 133)
    static let evalTimeHuge = #"47.34.635.381 I slot print_timing: id  3 | task 133 |        eval time = 2124448.22 ms / 28373 tokens (   74.88 ms per token,    13.35 tokens per second)"#
    /// final block line 3
    static let totalTime = #"46.30.710.725 I slot print_timing: id  2 | task 10325 |       total time =    3527.39 ms /    87 tokens"#
    /// ignorable
    static let graphsReused = #"46.30.710.725 I slot print_timing: id  2 | task 10325 |    graphs reused =      10202"#
    /// ignorable
    static let graphReallocs = #"46.30.710.725 I slot print_timing: id  2 | task 10325 |   graph reallocs =          0    /     0        (same size) / (changed size)"#
    /// speculative decoding acceptance
    static let draftAcceptance = #"46.30.710.729 I slot print_timing: id  2 | task 10325 | draft acceptance = 0.88889 (   16 accepted /    18 generated), mean len =  3.67"#
    /// slot release, not truncated
    static let slotReleased = #"46.30.710.823 I slot      release: id  2 | task 10325 | stop processing: n_tokens = 86, truncated = 0"#
    /// slot release after context overflow (truncated = 1)
    static let slotReleasedTruncated = #"47.34.637.961 I slot      release: id  3 | task 133 | stop processing: n_tokens = 35839, truncated = 1"#
    /// task cancel
    static let taskCancelled = #"3.53.818.885 W srv          stop: cancel task, id_task = 0"#
    /// KV cache full warning (23:50:35)
    static let kvCacheFull = #"47.29.671.581 W srv        decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 2048, ret = 1"#
    /// decode() failed
    static let decodeFailed = #"3.53.818.956 E srv  update_slots: decode() failed: Compute error."#
    /// srv decode: Compute error (precedes decode() failed)
    static let decodeComputeError = #"3.53.818.847 E srv        decode: Compute error. off = 0, n_batch = 2048, ret = -3"#
    /// GPU OOM pair, line 2
    static let oomInsufficientMemory = #"3.53.817.075 E error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"#
    /// GPU OOM pair, line 1
    static let oomCommandBuffer = #"3.53.817.064 E ggml_metal_synchronize: error: command buffer 0 failed with status 5"#
    /// load_model: loading
    static let modelLoading = #"0.12.032.390 I srv    load_model: loading model '/Users/me/.lmstudio/models/lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q6_K.gguf'"#
    /// load_model: loaded multimodal model (-> .other)
    static let modelLoadedMultimodal = #"0.34.630.495 I srv    load_model: loaded multimodal model, '/Users/me/.lmstudio/models/lmstudio-community/Qwen3.8-27B-GGUF/mmproj-Qwen3.8-27B-BF16.gguf'"#
    /// load_model: initializing
    static let modelInitialized = #"0.34.630.517 I srv    load_model: initializing, n_slots = 4, n_ctx_slot = 71168, kv_unified = 'true'"#
    /// load_model: initializing (current instance)
    static let modelInitialized102400 = #"0.04.807.094 I srv    load_model: initializing, n_slots = 4, n_ctx_slot = 102400, kv_unified = 'true'"#
    /// srv send_error (-> .other)
    static let sendError = #"3.53.818.849 E srv    send_error: task id = 0, error: Compute error."#
    /// srv try_clear_id (-> .other)
    static let tryClearId = #"47.29.661.346 W srv  try_clear_id: purging slot 2 with 86 tokens"#
    /// non-srv decode warning (-> .other)
    static let memorySlotWarning = #"47.29.659.927 W decode: failed to find a memory slot for batch of size 1"#
    /// spec draft error (-> .other)
    static let specDraftError = #"47.29.659.935 E spec        draft: llama_process[1] returned 1"#
    /// llama_server listening (-> .other)
    static let listening = #"0.34.848.002 I srv  llama_server: listening on http://127.0.0.1:56616"#
    /// LM Studio split an engine line: uptime alone (-> not an engine line)
    static let glitchUptimeOnly = #"10.21.054.799"#
    /// LM Studio split an engine line: level+body without uptime (still parsed)
    static let glitchBodyOnly = #"I slot print_timing: id  0 | task 167 | prompt processing, n_tokens =   2048, progress = 0.31, t =  18.84 s / 108.72 tokens per second"#
    /// uptime+level with empty body (-> not an engine line)
    static let glitchLevelOnly = #"5.07.479.406 E"#
    /// body without uptime or level (-> not an engine line)
    static let glitchNoLevel = #"ggml_metal_synchronize: error: command buffer 0 failed with status 5"#

    /// The final per-task block arrives as ONE multi-line runtime `message` (6 physical lines).
    static let finalBlockMessage = #"""
        46.30.710.704 I slot print_timing: id  2 | task 10325 | prompt eval time =    1631.73 ms /    63 tokens (   25.90 ms per token,    38.61 tokens per second)
        46.30.710.722 I slot print_timing: id  2 | task 10325 |        eval time =    1895.66 ms /    24 tokens (   82.42 ms per token,    12.13 tokens per second)
        46.30.710.725 I slot print_timing: id  2 | task 10325 |       total time =    3527.39 ms /    87 tokens
        46.30.710.725 I slot print_timing: id  2 | task 10325 |    graphs reused =      10202
        46.30.710.725 I slot print_timing: id  2 | task 10325 |   graph reallocs =          0    /     0        (same size) / (changed size)
        46.30.710.729 I slot print_timing: id  2 | task 10325 | draft acceptance = 0.88889 (   16 accepted /    18 generated), mean len =  3.67
        """#

    // MARK: - Server-log `content` strings (decoded) and persisted-log physical lines

    /// embedded engine line (dedupe twin of Fixtures.genProgress)
    static let srvEngineGen = #"[2026-10-14 23:49:32][DEBUG] 46.26.021.689 I slot print_timing: id  3 | task 133 | n_gen =  27343, tg =  13.30 t/s, tg_3s =  16.33 t/s"#
    /// Received request with multi-line JSON body (first line only is parsed)
    static let srvRequestPOST = #"""
        [2026-10-14 23:49:33][DEBUG] Received request: POST to /api/v0/chat/completions with body {
          "model": "qwen/qwen3.8-27b",
          "messages": [
            {
              "role": "user",
              "content": "Say hi in 3 words. /no_think"
            }
          ],
          "max_tokens": 24,
          "stream": false
        }
        """#
    /// Received request without body
    static let srvRequestGET = #"[2026-10-14 09:46:43][DEBUG] Received request: GET to /api/v0/models"#
    static let srvChatStarted = #"[2026-10-14 23:49:33][INFO][qwen/qwen3.8-27b] Running chat completion on conversation with 1 messages."#
    /// MLX model with @variant and 3-digit message count
    static let srvChatStartedMLX = #"[2026-10-08 21:44:00][INFO][qwen3.8-27b-mlx@4bit] Running chat completion on conversation with 185 messages."#
    static let srvPrefill0 = #"[2026-10-14 23:49:33][INFO][qwen/qwen3.8-27b] Prompt processing progress: 0.0%"#
    static let srvPrefill667 = #"[2026-10-14 23:49:34][INFO][qwen/qwen3.8-27b] Prompt processing progress: 66.7%"#
    static let srvPrefill100 = #"[2026-10-14 23:49:34][INFO][qwen/qwen3.8-27b] Prompt processing progress: 100.0%"#
    static let srvPrefillMLX = #"[2026-10-08 21:44:05][INFO][qwen3.8-27b-mlx@4bit] Prompt processing progress: 20.7%"#
    static let srvStreamingStarted = #"[2026-10-14 09:49:49][INFO][qwen/qwen3.8-27b] Streaming response..."#
    static let srvStreamingFinished = #"[2026-10-14 09:54:51][INFO][qwen/qwen3.8-27b] Finished streaming response"#
    /// Generated prediction with multi-line JSON (first line only is parsed)
    static let srvGeneratedPrediction = #"""
        [2026-10-14 23:49:36][INFO][qwen/qwen3.8-27b] Generated prediction: {
          "id": "chatcmpl-uii8zfthkfeqfu8fjsivu",
          "object": "chat.completion",
          "created": 1792001973,
          "model": "qwen/qwen3.8-27b",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "",
                "reasoning_content": "The user wants me to say \"hi\" in exactly 3 words. The /no_think tag suggests they want",
                "tool_calls": []
              },
              "logprobs": null,
              "finish_reason": "length"
            }
          ],
          "usage": {
            "prompt_tokens": 63,
            "completion_tokens": 24,
            "total_tokens": 87,
            "completion_tokens_details": {
              "reasoning_tokens": 24
            },
            "total_draft_tokens_count": 18,
            "accepted_draft_tokens_count": 16,
            "rejected_draft_tokens_count": 2
          },
          "stats": {
            "tokens_per_second": 12.133003034305803,
            "time_to_first_token": 1.631729,
            "generation_time": 3.527385,
            "stop_reason": "maxPredictedTokensReached"
          },
          "model_info": {
            "arch": "qwen35",
            "quant": "Q4_K_M",
            "format": "gguf",
            "context_length": 35840
          },
          "runtime": {
            "name": "llama.cpp-mac-arm64-apple-metal-advsimd",
            "version": "2.57.0",
            "supported_formats": [
              "gguf"
            ]
          }
        }
        """#
    /// (-> .other)
    static let srvToolCalls = #"[2026-10-14 23:49:36][INFO][qwen/qwen3.8-27b] Model generated tool calls: []"#
    /// (-> .other)
    static let srvDoneReasoning = #"[2026-10-05 17:35:51][INFO][qwen3.8-27b-mlx] Done reasoning. Reasoned for 6061.49 seconds."#
    /// MLX coordinator
    static let srvPromptCacheRestore = #"[2026-10-14 00:02:33][DEBUG][coordinator][INFO]: Prompt cache restore: cached_tokens=16128 uncached_tokens=20360 lifetime_efficiency=32.54%"#
    /// MLX coordinator, nothing cached
    static let srvPromptCacheRestoreZero = #"[2026-10-14 00:26:34][DEBUG][coordinator][INFO]: Prompt cache restore: cached_tokens=0 uncached_tokens=411 lifetime_efficiency=32.29%"#
    /// MLX context auto-fit
    static let srvContextFit = #"[2026-10-02 04:58:35][DEBUG][context_fit][INFO]: Model context auto-fit: family=qwen3_5 max=262,144 fitted=55,040 working_set=27.00GiB reserve=3.00GiB safe_ceiling=24.00GiB baseline=14.95GiB full_kv=65536B/token prompt_inputs=10240B/token attention=98304B/token rotating_peak=0.00GiB fixed_ssm=0.14GiB estimated_peak=24.02GiB"#
    /// MLX prompt cache disk usage
    static let srvCacheStore = #"[2026-10-14 00:02:36][DEBUG][cache_store][INFO]: VLM prompt cache disk usage: used_mib=17797.9 cap_mib=35004.7 lifetime_evicted_mib=0.0 records=262 lifetime=model_load"#
    /// (-> .other)
    static let srvDiskBudget = #"[2026-10-14 03:26:38][DEBUG][disk_budget][INFO]: VLM prompt cache disk budget: stage=provisional cap_gib=30.00"#
    static let srvModelLoadFailedGuardrail = #"[2026-10-14 10:00:39][ERROR] Failed to load model "qwen3.8-27b-mlx". Error: Model loading was stopped due to insufficient system resources. Continuing to load the model would likely overload your system and cause it to freeze. If you think this is incorrect, you can adjust the model loading guardrails in settings."#
    static let srvModelLoadFailedShort = #"[2026-10-07 08:19:45][ERROR] Failed to load model "qwen/qwen3.8-27b". Error: Error loading model."#
    /// (-> .other; the [ERROR] line carries the real event)
    static let srvLLMProcessFailed = #"[2026-10-08 01:55:07][DEBUG][LLMProcess] Failed to load model _0x44052f [Error]: Failed to load model."#
    static let srvTTLUnload = #"[2026-10-14 01:29:12][INFO] Unloading model qwen3.8-27b-mlx due to TTL expiration."#
    static let srvPredictError = #"[2026-10-14 09:49:52][ERROR][qwen/qwen3.8-27b] Engine protocol predict stream returned an error: {"code":500,"message":"Compute error.","type":"server_error"}. Error Data: n/a, Additional Data: n/a"#
    static let srvTerminated = #"[2026-10-14 23:51:45][ERROR][qwen/qwen3.8-27b] terminated. Error Data: n/a, Additional Data: n/a"#
    /// model-tagged ERROR (generic predictError)
    static let srvContextOverflowError = #"[2026-10-06 05:55:20][ERROR][qwen3.8-27b-mlx] Context overflow policy error: TruncateMiddle context overflow policy is not currently supported for prompts with images. Please increase the model's loaded context length, shorten the prompt, or utilize a different context overflow policy.. Error Data: n/a, Additional Data: n/a"#
    /// model-tagged ERROR (generic predictError)
    static let srvModelUnloadedError = #"[2026-10-08 22:43:53][ERROR][qwen3.8-27b-mlx@6bit] Model unloaded.. Error Data: n/a, Additional Data: n/a"#
    /// [WARN] level, model-tagged (-> .other)
    static let srvWarnReasoning = #"[2026-10-08 11:35:53][WARN][qwen3.8-27b-mlx] No valid custom reasoning fields found in model 'publisher/Qwen3.8-27B-MLX-6bit'. Reasoning setting 'low' cannot be converted to any custom KVs."#
    static let srvClientDisconnected = #"[2026-10-14 23:06:34][INFO][LM STUDIO SERVER] Client disconnected. Stopping generation... (If the model is busy processing the prompt, it will finish first.)"#
    /// LMSAuthenticator disconnect is NOT a client disconnect (-> .other)
    static let srvAuthDisconnected = #"[2026-10-14 23:49:40][DEBUG][LMSAuthenticator][Client=lms-cli] Client disconnected."#
    /// three bracket tags (-> .other)
    static let srvAuthEndpoint = #"[2026-10-14 23:50:29][INFO][LMSAuthenticator][Client=lms-cli][Endpoint=listLoaded] Listing loaded models"#
    static let srvServerStarted = #"[2026-10-14 22:36:49][INFO] Server started."#
    static let srvServerStopped = #"[2026-10-14 11:06:38][INFO] Server stopped."#
    /// (dropped)
    static let srvReturningModels = #"[2026-10-14 23:50:29][INFO] Returning 6 models from v1 API"#
    /// (dropped; truncated JSON body, never parsed)
    static let srvReturningJSON = #"""
        [2026-10-14 09:46:43][INFO] Returning {
          "data": [
            {
              "id": "qwen/qwen3.8-27b",
              "object": "model",
              "owned_by": "organization_owner"
            },
        """#
    /// [INFO] with empty text (-> nothing)
    static let srvEmptyInfo = #"[2026-10-14 02:02:21][INFO] "#
    /// (-> .other)
    static let srvJIT = #"[2026-10-14 02:02:21][INFO] Just-in-time model loading active."#
    /// (-> .other)
    static let srvUnexpectedEndpoint = #"[2026-10-14 00:27:47][ERROR] Unexpected endpoint or method. (POST /api/v0/models/unload). Returning 200 anyway"#
    /// [ERROR][LM STUDIO SERVER] with JSON body (-> .other, first line only)
    static let srvErrorBlock = #"""
        [2026-10-14 00:27:47][ERROR][LM STUDIO SERVER] {
          "error": {
            "message": "Missing required field 'instance_id'",
            "type": "invalid_request",
            "code": "missing_required_parameter",
            "param": "instance_id"
          }
        }
        """#
    /// (-> .other)
    static let srvSupportedEndpoints = #"[2026-10-14 02:02:21][INFO][LM STUDIO SERVER] Supported endpoints:"#
    /// (-> .other)
    static let srvMLXTruncate = #"[2026-10-14 00:32:23][DEBUG][MLXAmphibianEngine][INFO] TruncateMiddle policy activated, pre-processing the '60227' token prompt by removing '32753' tokens from the middle, starting at token idx (n_keep)' 92'."#
    /// (-> .other)
    static let srvTransformers = #"[2026-10-14 03:26:38][DEBUG][transformers] Unrecognized keys in `rope_parameters` for 'rope_type'='default': {'mrope_interleaved', 'mrope_section'}"#
    /// (-> .other)
    static let srvPlugin = #"[2026-10-14 02:02:22][INFO][Plugin(danielsig/duckduckgo)] stdout: [Tools Prvdr.] Register with LM Studio"#
    /// (-> .other)
    static let srvStopGenerating = #"[2026-10-14 01:29:13][DEBUG] stopGenerating() without a request_id is deprecated. Taking no action"#
    /// split engine line, uptime only (-> .other)
    static let srvGlitchUptime = #"[2026-10-14 10:02:20][DEBUG] 10.21.054.799"#
    /// split engine line, level+body (-> .engineLine, parsed)
    static let srvGlitchBody = #"[2026-10-14 10:02:20][DEBUG] I slot print_timing: id  0 | task 167 | prompt processing, n_tokens =   2048, progress = 0.31, t =  18.84 s / 108.72 tokens per second"#
    /// split engine line, body only (-> .other)
    static let srvGlitchNoLevel = #"[2026-10-14 09:51:06][DEBUG] ggml_metal_synchronize: error: command buffer 0 failed with status 5"#
    /// server copy of the multi-line runtime final block (6 engine lines)
    static let srvFinalBlock = #"""
        [2026-10-14 23:49:36][DEBUG] 46.30.710.704 I slot print_timing: id  2 | task 10325 | prompt eval time =    1631.73 ms /    63 tokens (   25.90 ms per token,    38.61 tokens per second)
        46.30.710.722 I slot print_timing: id  2 | task 10325 |        eval time =    1895.66 ms /    24 tokens (   82.42 ms per token,    12.13 tokens per second)
        46.30.710.725 I slot print_timing: id  2 | task 10325 |       total time =    3527.39 ms /    87 tokens
        46.30.710.725 I slot print_timing: id  2 | task 10325 |    graphs reused =      10202
        46.30.710.725 I slot print_timing: id  2 | task 10325 |   graph reallocs =          0    /     0        (same size) / (changed size)
        46.30.710.729 I slot print_timing: id  2 | task 10325 | draft acceptance = 0.88889 (   16 accepted /    18 generated), mean len =  3.67
        """#
    /// GPU OOM burst as one server message (4 engine lines)
    static let srvOOMBlock = #"""
        [2026-10-14 09:49:52][DEBUG] 3.53.817.064 E ggml_metal_synchronize: error: command buffer 0 failed with status 5
        3.53.817.075 E error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
        3.53.817.076 E ggml_metal_synchronize: error: command buffer 0 failed with status 5
        3.53.817.076 E error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
        """#
    /// compute error -> send_error -> release -> cancel, one message
    static let srvComputeErrorBlock = #"""
        [2026-10-14 09:49:52][DEBUG] 3.53.818.847 E srv        decode: Compute error. off = 0, n_batch = 2048, ret = -3
        3.53.818.849 E srv    send_error: task id = 0, error: Compute error.
        3.53.818.854 I slot      release: id  3 | task 0 | stop processing: n_tokens = 2048, truncated = 0
        3.53.818.885 W srv          stop: cancel task, id_task = 0
        """#
    /// KV-cache pressure sequence as persisted (6 physical lines, mixed prefixed/continuation; feed line by line)
    static let logKVSequence = #"""
        [2026-10-14 23:50:35][DEBUG] 47.29.659.927 W decode: failed to find a memory slot for batch of size 1
        47.29.659.935 E spec        draft: llama_process[1] returned 1
        [2026-10-14 23:50:35][DEBUG] 47.29.661.295 E init_batch: failed to prepare attention ubatches
        47.29.661.301 W decode: failed to find a memory slot for batch of size 2
        [2026-10-14 23:50:35][DEBUG] 47.29.661.346 W srv  try_clear_id: purging slot 2 with 86 tokens
        [2026-10-14 23:50:35][DEBUG] 47.29.671.581 W srv        decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 2048, ret = 1
        """#
    /// persisted-log continuation line (no prefix)
    static let logEngineContinuation = #"46.30.710.722 I slot print_timing: id  2 | task 10325 |        eval time =    1895.66 ms /    24 tokens (   82.42 ms per token,    12.13 tokens per second)"#
    /// persisted-log JSON continuation line (-> nothing)
    static let logJSONContinuation = #"  "model": "qwen/qwen3.8-27b","#
    /// persisted-log JSON continuation line (-> nothing)
    static let logJSONClose = #"}"#

    // MARK: - Raw NDJSON lines (`lms log stream --json`), in capture order, for the reducer replay

    static let ndjsonBanner = "Streaming logs from LM Studio"

    /// `lms log stream --source runtime --json`
    static let scenarioRuntime: [String] = [
        #"{"timestamp":1792001972040,"data":{"type":"runtime.log","level":"debug","message":"46.26.021.689 I slot print_timing: id  3 | task 133 | n_gen =  27343, tg =  13.30 t/s, tg_3s =  16.33 t/s","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
        #"{"timestamp":1792001973171,"data":{"type":"runtime.log","level":"debug","message":"46.27.152.761 I slot get_availabl: id  2 | task -1 | selected slot by LRU, t_last = -1","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
        #"{"timestamp":1792001973172,"data":{"type":"runtime.log","level":"debug","message":"46.27.152.809 I slot launch_slot_: id  2 | task 10325 | processing task, is_child = 0","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
        #"{"timestamp":1792001975118,"data":{"type":"runtime.log","level":"debug","message":"46.29.099.244 I slot print_timing: id  3 | task 133 | n_gen =  27375, tg =  13.30 t/s, tg_3s =  10.40 t/s","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
        #"{"timestamp":1792001976729,"data":{"type":"runtime.log","level":"debug","message":"46.30.710.704 I slot print_timing: id  2 | task 10325 | prompt eval time =    1631.73 ms /    63 tokens (   25.90 ms per token,    38.61 tokens per second)\n46.30.710.722 I slot print_timing: id  2 | task 10325 |        eval time =    1895.66 ms /    24 tokens (   82.42 ms per token,    12.13 tokens per second)\n46.30.710.725 I slot print_timing: id  2 | task 10325 |       total time =    3527.39 ms /    87 tokens\n46.30.710.725 I slot print_timing: id  2 | task 10325 |    graphs reused =      10202\n46.30.710.725 I slot print_timing: id  2 | task 10325 |   graph reallocs =          0    /     0        (same size) / (changed size)\n46.30.710.729 I slot print_timing: id  2 | task 10325 | draft acceptance = 0.88889 (   16 accepted /    18 generated), mean len =  3.67","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
        #"{"timestamp":1792001976730,"data":{"type":"runtime.log","level":"debug","message":"46.30.710.823 I slot      release: id  2 | task 10325 | stop processing: n_tokens = 86, truncated = 0","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
        #"{"timestamp":1792001978127,"data":{"type":"runtime.log","level":"debug","message":"46.32.108.312 I slot print_timing: id  3 | task 133 | n_gen =  27421, tg =  13.30 t/s, tg_3s =  15.29 t/s","engineName":"llama.cpp-mac-arm64-apple-metal-advsimd","engineVersion":"2.57.0","engineType":"llama.cpp","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"QDB8g1tEXbuH0ZXm2JaOKRav","pid":6932}}"#,
    ]

    /// `lms log stream --source server --json`
    static let scenarioServer: [String] = [
        #"{"timestamp":1792001972040,"data":{"type":"server.log","content":"[2026-10-14 23:49:32][DEBUG] 46.26.021.689 I slot print_timing: id  3 | task 133 | n_gen =  27343, tg =  13.30 t/s, tg_3s =  16.33 t/s","level":"debug"}}"#,
        #"{"timestamp":1792001973129,"data":{"type":"server.log","content":"[2026-10-14 23:49:33][DEBUG] Received request: POST to /api/v0/chat/completions with body {\n  \"model\": \"qwen/qwen3.8-27b\",\n  \"messages\": [\n    {\n      \"role\": \"user\",\n      \"content\": \"Say hi in 3 words. /no_think\"\n    }\n  ],\n  \"max_tokens\": 24,\n  \"stream\": false\n}","level":"debug"}}"#,
        #"{"timestamp":1792001973134,"data":{"type":"server.log","content":"[2026-10-14 23:49:33][INFO][qwen/qwen3.8-27b] Running chat completion on conversation with 1 messages.","level":"info"}}"#,
        #"{"timestamp":1792001973171,"data":{"type":"server.log","content":"[2026-10-14 23:49:33][DEBUG] 46.27.152.761 I slot get_availabl: id  2 | task -1 | selected slot by LRU, t_last = -1","level":"debug"}}"#,
        #"{"timestamp":1792001973172,"data":{"type":"server.log","content":"[2026-10-14 23:49:33][DEBUG] 46.27.152.809 I slot launch_slot_: id  2 | task 10325 | processing task, is_child = 0","level":"debug"}}"#,
        #"{"timestamp":1792001973203,"data":{"type":"server.log","content":"[2026-10-14 23:49:33][INFO][qwen/qwen3.8-27b] Prompt processing progress: 0.0%","level":"info"}}"#,
        #"{"timestamp":1792001974168,"data":{"type":"server.log","content":"[2026-10-14 23:49:34][INFO][qwen/qwen3.8-27b] Prompt processing progress: 66.7%","level":"info"}}"#,
        #"{"timestamp":1792001974578,"data":{"type":"server.log","content":"[2026-10-14 23:49:34][INFO][qwen/qwen3.8-27b] Prompt processing progress: 93.7%","level":"info"}}"#,
        #"{"timestamp":1792001974834,"data":{"type":"server.log","content":"[2026-10-14 23:49:34][INFO][qwen/qwen3.8-27b] Prompt processing progress: 100.0%","level":"info"}}"#,
        #"{"timestamp":1792001975118,"data":{"type":"server.log","content":"[2026-10-14 23:49:35][DEBUG] 46.29.099.244 I slot print_timing: id  3 | task 133 | n_gen =  27375, tg =  13.30 t/s, tg_3s =  10.40 t/s","level":"debug"}}"#,
        #"{"timestamp":1792001976729,"data":{"type":"server.log","content":"[2026-10-14 23:49:36][DEBUG] 46.30.710.704 I slot print_timing: id  2 | task 10325 | prompt eval time =    1631.73 ms /    63 tokens (   25.90 ms per token,    38.61 tokens per second)\n46.30.710.722 I slot print_timing: id  2 | task 10325 |        eval time =    1895.66 ms /    24 tokens (   82.42 ms per token,    12.13 tokens per second)\n46.30.710.725 I slot print_timing: id  2 | task 10325 |       total time =    3527.39 ms /    87 tokens\n46.30.710.725 I slot print_timing: id  2 | task 10325 |    graphs reused =      10202\n46.30.710.725 I slot print_timing: id  2 | task 10325 |   graph reallocs =          0    /     0        (same size) / (changed size)\n46.30.710.729 I slot print_timing: id  2 | task 10325 | draft acceptance = 0.88889 (   16 accepted /    18 generated), mean len =  3.67","level":"debug"}}"#,
        #"{"timestamp":1792001976730,"data":{"type":"server.log","content":"[2026-10-14 23:49:36][DEBUG] 46.30.710.823 I slot      release: id  2 | task 10325 | stop processing: n_tokens = 86, truncated = 0","level":"debug"}}"#,
        #"{"timestamp":1792001976734,"data":{"type":"server.log","content":"[2026-10-14 23:49:36][INFO][qwen/qwen3.8-27b] Model generated tool calls: []","level":"info"}}"#,
        #"{"timestamp":1792001976734,"data":{"type":"server.log","content":"[2026-10-14 23:49:36][INFO][qwen/qwen3.8-27b] Generated prediction: {\n  \"id\": \"chatcmpl-uii8zfthkfeqfu8fjsivu\",\n  \"object\": \"chat.completion\",\n  \"created\": 1792001973,\n  \"model\": \"qwen/qwen3.8-27b\",\n  \"choices\": [\n    {\n      \"index\": 0,\n      \"message\": {\n        \"role\": \"assistant\",\n        \"content\": \"\",\n        \"reasoning_content\": \"The user wants me to say \\\"hi\\\" in exactly 3 words. The /no_think tag suggests they want\",\n        \"tool_calls\": []\n      },\n      \"logprobs\": null,\n      \"finish_reason\": \"length\"\n    }\n  ],\n  \"usage\": {\n    \"prompt_tokens\": 63,\n    \"completion_tokens\": 24,\n    \"total_tokens\": 87,\n    \"completion_tokens_details\": {\n      \"reasoning_tokens\": 24\n    },\n    \"total_draft_tokens_count\": 18,\n    \"accepted_draft_tokens_count\": 16,\n    \"rejected_draft_tokens_count\": 2\n  },\n  \"stats\": {\n    \"tokens_per_second\": 12.133003034305803,\n    \"time_to_first_token\": 1.631729,\n    \"generation_time\": 3.527385,\n    \"stop_reason\": \"maxPredictedTokensReached\"\n  },\n  \"model_info\": {\n    \"arch\": \"qwen35\",\n    \"quant\": \"Q4_K_M\",\n    \"format\": \"gguf\",\n    \"context_length\": 35840\n  },\n  \"runtime\": {\n    \"name\": \"llama.cpp-mac-arm64-apple-metal-advsimd\",\n    \"version\": \"2.57.0\",\n    \"supported_formats\": [\n      \"gguf\"\n    ]\n  }\n}","level":"info"}}"#,
        #"{"timestamp":1792001978127,"data":{"type":"server.log","content":"[2026-10-14 23:49:38][DEBUG] 46.32.108.312 I slot print_timing: id  3 | task 133 | n_gen =  27421, tg =  13.30 t/s, tg_3s =  15.29 t/s","level":"debug"}}"#,
    ]

    /// `lms log stream --source model --filter output --stats --json` (the input line is only present
    /// without `--filter output`; it is included so parsers prove they ignore it).
    static let scenarioModel: [String] = [
        #"{"timestamp":1792001976731,"data":{"type":"llm.prediction.input","input":"<|im_start|>system\nReasoning effort is set to xhigh. Please think carefully through the task, validate key assumptions, consider plausible alternatives, and prioritize correctness, consistency, and clarity in the final answer.<|im_end|>\n<|im_start|>user\nSay hi in 3 words. /no_think<|im_end|>\n<|im_start|>assistant\n<think>\n","modelPath":"qwen/qwen3.8-27b","modelIdentifier":"qwen/qwen3.8-27b"}}"#,
        #"{"timestamp":1792001976732,"data":{"type":"llm.prediction.output","output":"The user wants me to say \"hi\" in exactly 3 words. The /no_think tag suggests they want","stats":{"stopReason":"maxPredictedTokensReached","tokensPerSecond":12.133003034305803,"timeToFirstTokenSec":1.631729,"totalTimeSec":3.527385,"promptTokensCount":63,"predictedTokensCount":24,"totalTokensCount":87,"totalDraftTokensCount":18,"acceptedDraftTokensCount":16,"rejectedDraftTokensCount":2},"modelIdentifier":"qwen/qwen3.8-27b"}}"#,
    ]

    /// The `llm.prediction.output` NDJSON line of the test request.
    static var modelOutputLine: String { scenarioModel[1] }
    /// The `llm.prediction.input` NDJSON line (must be ignored by ModelStatsParser).
    static var modelInputLine: String { scenarioModel[0] }
}
