import Foundation

struct PollResult: Equatable {
    var models: [ModelInfo]
    var serverReachable: Bool
    var port: Int
    var lmStudioRunning: Bool
    var lmsPath: String?
    var error: String?
}

/// Polls LM Studio for the model catalog and loaded-instance state.
/// Sources: REST `/api/v1/models` (+ `/api/v0/models`) and `lms ps --json` (works with the HTTP server stopped).
final class LMStudioPoller {
    private let lmsURL: () -> URL?
    private let sink: @MainActor @Sendable (PollResult) -> Void
    private let queue = DispatchQueue(label: "lmmonitor.poll", qos: .utility)
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // Queue-confined
    private var timer: DispatchSourceTimer?
    private var active = false
    private var lastREST = Date.distantPast
    private var lastPs = Date.distantPast
    private var cycleQueued = false
    private var forceNext = false
    private var lastPublished: PollResult?
    private var v1: [[String: Any]]?
    private var v0: [[String: Any]]?
    private var ps: [[String: Any]]?
    private var restError: String?
    private var lmStudioRunning = false

    init(lmsURL: @escaping () -> URL?, sink: @escaping @MainActor @Sendable (PollResult) -> Void) {
        self.lmsURL = lmsURL
        self.sink = sink
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0)
            t.setEventHandler { [weak self] in self?.cycle(force: false) }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    func pollNow() {
        queue.async { [self] in cycle(force: true) }
    }

    func setActive(_ active: Bool) {
        queue.async { [self] in
            let was = self.active
            self.active = active
            if active && !was { cycle(force: false) }   // due-check uses the faster interval
        }
    }

    // MARK: - cycle (queue)

    private func cycle(force: Bool) {
        let now = Date()
        let restInt: TimeInterval = active ? 5 : 15
        let psInt: TimeInterval = active ? 10 : 30
        let dueREST = force || now.timeIntervalSince(lastREST) >= restInt
        let duePs = force || now.timeIntervalSince(lastPs) >= psInt
        guard dueREST || duePs else { return }

        let live = LMStudioLiveness.check().running
        lmStudioRunning = live
        let lms = lmsURL()

        if !live {
            v1 = nil; v0 = nil; ps = nil
            restError = "LM Studio not running"
            // Don't advance lastREST/lastPs: the liveness check is cheap, so re-check every tick
            // and poll immediately once LM Studio appears.
        } else {
            if dueREST { fetchREST(); lastREST = Date() }
            if duePs {
                if Settings.pollLmsPs, let lms, LMStudioLiveness.check().running { ps = fetchPs(lms) } else { ps = nil }
                lastPs = Date()
            }
        }

        let result = PollResult(models: Self.merge(v1: v1, v0: v0, ps: ps),
                                serverReachable: v1 != nil || v0 != nil,
                                port: Settings.resolvedLMStudioPort,
                                lmStudioRunning: live,
                                lmsPath: lms?.path,
                                error: (v1 != nil || v0 != nil) ? nil : restError)
        if force || result != lastPublished {
            lastPublished = result
            let s = sink
            hopToMain { s(result) }
        }
    }

    // MARK: - fetching (blocking, on the poll queue)

    private func getJSON(_ path: String) -> (obj: Any?, status: Int, error: String?) {
        let url = Settings.lmStudioBaseURL.appendingPathComponent(path)
        let sem = DispatchSemaphore(value: 0)
        let box = Box<(Data?, Int, String?)>((nil, 0, nil))
        session.dataTask(with: url) { data, resp, err in
            box.value = (data, (resp as? HTTPURLResponse)?.statusCode ?? 0, err?.localizedDescription)
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 6) == .timedOut { return (nil, 0, "timeout") }
        let (data, status, err) = box.value
        guard status == 200, let data else { return (nil, status, err ?? "HTTP \(status)") }
        return (try? JSONSerialization.jsonObject(with: data), status, nil)
    }

    private final class Box<T> {
        private let lock = NSLock()
        private var _v: T
        init(_ v: T) { _v = v }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return _v } set { lock.lock(); _v = newValue; lock.unlock() } }
    }

    private func fetchREST() {
        let r1 = getJSON("api/v1/models")
        if let o = r1.obj as? [String: Any], let arr = (o["models"] ?? o["data"]) as? [[String: Any]] {
            v1 = arr; restError = nil
        } else {
            v1 = nil; restError = r1.error
        }
        let r0 = getJSON("api/v0/models")
        if let o = r0.obj as? [String: Any], let arr = o["data"] as? [[String: Any]] {
            v0 = arr; if v1 == nil { restError = nil }
        } else {
            v0 = nil
            if v1 == nil, restError == nil { restError = r0.error }
        }
    }

    private func fetchPs(_ lms: URL) -> [[String: Any]]? {
        let out = ProcessRunner.run(lms, ["ps", "--json"], timeout: 5)
        guard out.launchError == nil, !out.timedOut, out.status == 0 else { return nil }
        let text = out.stdout
        guard let start = text.firstIndex(of: "[") else { return nil }
        guard let data = String(text[start...]).data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return arr
    }

    // MARK: - merge (pure)

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func date(_ v: Any?) -> Date? {
        if let n = v as? Double ?? (v as? Int).map({ Double($0) }) {
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        return nil
    }

    private static func name(_ m: ModelInfo) -> String { (m.displayName ?? m.id).lowercased() }

    static func merge(v1: [[String: Any]]?, v0: [[String: Any]]?, ps: [[String: Any]]?) -> [ModelInfo] {
        var base: [String: ModelInfo] = [:]
        var loaded: [String: ModelInfo] = [:]

        if let v1 {
            for m in v1 {
                guard let key = m["key"] as? String ?? m["id"] as? String else { continue }
                var info = ModelInfo(id: key)
                info.displayName = m["display_name"] as? String
                info.publisher = m["publisher"] as? String
                info.type = m["type"] as? String
                info.format = m["format"] as? String
                info.architecture = m["architecture"] as? String
                if let q = m["quantization"] as? [String: Any] {
                    info.quantization = q["name"] as? String
                    info.bitsPerWeight = q["bits_per_weight"] as? Double ?? int(q["bits_per_weight"]).map { Double($0) }
                } else { info.quantization = m["quantization"] as? String }
                info.paramsString = m["params_string"] as? String
                if let sz = m["size_bytes"] as? NSNumber { info.sizeBytes = sz.uint64Value }
                info.maxContextLength = int(m["max_context_length"])
                if let caps = m["capabilities"] as? [String: Any] {
                    info.vision = caps["vision"] as? Bool
                    info.toolUse = caps["trained_for_tool_use"] as? Bool
                }
                base[key] = info
                for inst in (m["loaded_instances"] as? [[String: Any]]) ?? [] {
                    let iid = inst["id"] as? String ?? key
                    var row = info
                    row.id = iid; row.instanceID = iid; row.isLoaded = true
                    if let cfg = inst["config"] as? [String: Any] {
                        row.loadedContextLength = int(cfg["context_length"])
                        row.parallel = int(cfg["parallel"])
                        row.speculativeDraftMTP = cfg["speculative_draft_mtp"] as? Bool
                        row.kvOffloadToGPU = cfg["offload_kv_cache_to_gpu"] as? Bool
                        row.flashAttention = cfg["flash_attention"] as? Bool
                    }
                    loaded[iid] = row
                }
            }
        }

        if let v0 {
            for m in v0 {
                guard let id = m["id"] as? String else { continue }
                let state = m["state"] as? String
                let ctx = int(m["loaded_context_length"])
                if v1 == nil || base[id] == nil && loaded[id] == nil {
                    // v1 unavailable: v0 is the catalog.
                    var info = ModelInfo(id: id)
                    info.publisher = m["publisher"] as? String
                    info.type = m["type"] as? String
                    info.format = m["compatibility_type"] as? String
                    info.architecture = m["arch"] as? String
                    info.quantization = m["quantization"] as? String
                    info.maxContextLength = int(m["max_context_length"])
                    if base[id] == nil { base[id] = info }
                }
                if state == "loaded" || ctx != nil {
                    if var row = loaded[id] {
                        if row.loadedContextLength == nil { row.loadedContextLength = ctx }
                        loaded[id] = row
                    } else {
                        var row = base[id] ?? ModelInfo(id: id)
                        row.id = id; row.instanceID = id; row.isLoaded = true
                        row.loadedContextLength = ctx
                        loaded[id] = row
                    }
                }
            }
        }

        for p in ps ?? [] {
            guard let key = p["modelKey"] as? String ?? p["path"] as? String ?? p["identifier"] as? String else { continue }
            let ident = p["identifier"] as? String ?? key
            var row = loaded[ident] ?? base[key] ?? ModelInfo(id: ident)
            row.id = ident; row.instanceID = ident; row.isLoaded = true
            row.status = p["status"] as? String ?? row.status
            row.queued = int(p["queued"]) ?? row.queued
            row.ttlMs = int(p["ttlMs"]) ?? row.ttlMs
            row.lastUsedTime = date(p["lastUsedTime"]) ?? row.lastUsedTime
            row.loadedContextLength = int(p["contextLength"]) ?? row.loadedContextLength
            row.parallel = int(p["parallel"]) ?? row.parallel
            if row.sizeBytes == nil, let sz = p["sizeBytes"] as? NSNumber { row.sizeBytes = sz.uint64Value }
            row.maxContextLength = row.maxContextLength ?? int(p["maxContextLength"])
            row.displayName = row.displayName ?? p["displayName"] as? String
            row.publisher = row.publisher ?? p["publisher"] as? String
            row.type = row.type ?? p["type"] as? String
            row.format = row.format ?? p["format"] as? String
            row.architecture = row.architecture ?? p["architecture"] as? String
            row.paramsString = row.paramsString ?? p["paramsString"] as? String
            if row.quantization == nil, let q = p["quantization"] as? [String: Any] {
                row.quantization = q["name"] as? String
                row.bitsPerWeight = q["bits"] as? Double ?? int(q["bits"]).map { Double($0) }
            }
            row.vision = row.vision ?? p["vision"] as? Bool
            row.toolUse = row.toolUse ?? p["trainedForToolUse"] as? Bool
            loaded[ident] = row
        }

        let byName: (ModelInfo, ModelInfo) -> Bool = { name($0) != name($1) ? name($0) < name($1) : $0.id < $1.id }
        let loadedRows = loaded.values.sorted(by: byName)
        let rest = base.values.filter { loaded[$0.id] == nil }.sorted(by: byName)
        return loadedRows + rest
    }
}
