import Foundation
import Network

/// Minimal HTTP/1.1 reverse proxy in front of LM Studio's server.
/// Every request is forwarded unchanged (apart from optional stream_options
/// injection); responses are streamed back and parsed for token statistics.
final class ProxyServer {
    private let sink: @MainActor @Sendable ([LMEvent]) -> Void
    private let onStatus: @MainActor @Sendable (Bool, String?) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lmmonitor.proxy", qos: .userInitiated)
    private(set) var port: UInt16 = 0

    init(sink: @escaping @MainActor @Sendable ([LMEvent]) -> Void,
         onStatus: @escaping @MainActor @Sendable (Bool, String?) -> Void) {
        self.sink = sink
        self.onStatus = onStatus
    }

    private func report(_ running: Bool, _ error: String?) {
        let cb = onStatus
        hopToMain { cb(running, error) }
    }

    func start(port: UInt16) {
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let p = NWEndpoint.Port(rawValue: port) else { throw NSError(domain: "LMMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad port"]) }
            let l = try NWListener(using: params, on: p)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report(true, nil)
                case .failed(let e): self?.report(false, e.localizedDescription)
                case .cancelled: self?.report(false, nil)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            report(false, error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - client connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
                guard let self else { conn.cancel(); return }
                if let data { buffer.append(data) }
                switch HTTPRequest.parse(buffer) {
                case .complete(let req, let consumed):
                    buffer.removeFirst(consumed)
                    self.forward(req, client: conn)
                    // HTTP keep-alive is not supported: one request per connection.
                case .incomplete:
                    if isComplete || error != nil { conn.cancel() } else { readMore() }
                case .invalid:
                    Self.respond(conn, status: 400, body: "{\"error\":\"bad request\"}")
                }
            }
        }
        readMore()
    }

    private func forward(_ req: HTTPRequest, client: NWConnection) {
        let upstreamHost = Settings.lmStudioHost
        let upstreamPort = Settings.resolvedLMStudioPort
        let urlString = "http://\(upstreamHost):\(upstreamPort)" + (req.target.hasPrefix("/") ? "" : "/") + req.target
        guard let url = URL(string: urlString) else {
            Self.respond(client, status: 400, body: "{\"error\":\"bad url\"}"); return
        }
        var ur = URLRequest(url: url)
        ur.httpMethod = req.method
        for (k, v) in req.headers {
            let lk = k.lowercased()
            if ["host", "content-length", "connection", "accept-encoding", "transfer-encoding", "expect"].contains(lk) { continue }
            ur.setValue(v, forHTTPHeaderField: k)
        }
        ur.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        ur.timeoutInterval = 3600

        var body = req.body
        var stats = ProxyRequestStats()
        stats.endpoint = req.target
        stats.startedAt = Date()
        let isGeneration = req.method == "POST" && (req.target.contains("/completions") || req.target.contains("/responses") || req.target.contains("/embeddings"))
        if isGeneration, !body.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let m = json["model"] as? String { stats.model = m }
            stats.streamed = (json["stream"] as? Bool) ?? false
            // Rough prompt-size estimate (chars/4) until the server reports real usage.
            stats.promptTokens = Self.estimatePromptTokens(json)
            stats.promptTokensEstimated = true
            if stats.streamed, Settings.injectUsage, json["stream_options"] == nil {
                var j = json
                j["stream_options"] = ["include_usage": true]
                if let d = try? JSONSerialization.data(withJSONObject: j) { body = d }
            }
        }
        if !body.isEmpty { ur.httpBody = body }

        let sinkCopy = sink
        let emit: (ProxyRequestEvent.Phase, ProxyRequestStats) -> Void = { phase, st in
            let ev = LMEvent(at: Date(), source: .proxy, kind: .proxy(st.event(phase)))
            hopToMain { sinkCopy([ev]) }
        }
        let handler = UpstreamHandler(client: client, stats: stats, track: isGeneration, upstream: "\(upstreamHost):\(upstreamPort)", emit: emit)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 3600 * 6
        cfg.httpShouldUsePipelining = false
        let session = URLSession(configuration: cfg, delegate: handler, delegateQueue: nil)
        handler.session = session
        if isGeneration { emit(.started, stats) }
        let task = session.dataTask(with: ur)
        handler.setTask(task)
        // Watch the client: if it disconnects (e.g. user pressed Stop), cancel the upstream generation.
        client.stateUpdateHandler = { [weak handler] state in
            switch state {
            case .failed, .cancelled: handler?.clientDisconnected()
            default: break
            }
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak handler] _, _, isComplete, error in
            if isComplete || error != nil { handler?.clientDisconnected() }
        }
        task.resume()
    }

    static func estimatePromptTokens(_ json: [String: Any]) -> Int? {
        var chars = 0
        if let msgs = json["messages"] as? [[String: Any]] {
            for m in msgs {
                if let c = m["content"] as? String { chars += c.count }
                else if let parts = m["content"] as? [[String: Any]] {
                    for p in parts { if let t = p["text"] as? String { chars += t.count } }
                }
            }
        } else if let p = json["prompt"] as? String { chars += p.count }
        else if let p = json["input"] as? String { chars += p.count }
        else { return nil }
        return max(1, chars / 4)
    }

    static func respond(_ conn: NWConnection, status: Int, body: String) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(Data(body.utf8))
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - request bookkeeping

/// Mutable per-request state inside the proxy; converted to the immutable `ProxyRequestEvent` at each emit.
struct ProxyRequestStats {
    let id = UUID()
    var model: String = "?"
    var endpoint: String = ""
    var startedAt: Date = Date()
    var firstTokenAt: Date? = nil
    var finishedAt: Date? = nil
    var promptTokens: Int? = nil
    var promptTokensEstimated: Bool = false
    var completionTokens: Int = 0
    var streamed: Bool = false
    var status: Int? = nil
    var error: String? = nil
    var reportedTPS: Double? = nil
    var reportedTTFT: Double? = nil
    var stopReason: String? = nil

    func event(_ phase: ProxyRequestEvent.Phase) -> ProxyRequestEvent {
        ProxyRequestEvent(phase: phase, id: id, model: model, endpoint: endpoint, startedAt: startedAt,
                          firstTokenAt: firstTokenAt, finishedAt: finishedAt, promptTokens: promptTokens,
                          promptTokensEstimated: promptTokensEstimated, completionTokens: completionTokens,
                          reportedTPS: reportedTPS, reportedTTFT: reportedTTFT, stopReason: stopReason,
                          status: status, error: error)
    }
}

// MARK: - HTTP request parsing

struct HTTPRequest {
    var method: String
    var target: String
    var headers: [(String, String)]
    var body: Data

    enum ParseResult { case complete(HTTPRequest, consumed: Int), incomplete, invalid }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 1 << 20 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let reqLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard reqLine.count >= 2 else { return .invalid }
        var headers: [(String, String)] = []
        var contentLength = 0
        var chunked = false
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            let k = String(l[..<i]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            headers.append((k, v))
            if k.lowercased() == "content-length" { contentLength = Int(v) ?? 0 }
            if k.lowercased() == "transfer-encoding", v.lowercased().contains("chunked") { chunked = true }
        }
        let bodyStart = headerEnd.upperBound
        if chunked {
            // Decode chunked request body.
            var pos = bodyStart
            var body = Data()
            while true {
                guard let lineEnd = data[pos...].range(of: Data("\r\n".utf8)) else { return .incomplete }
                guard let sizeStr = String(data: data[pos..<lineEnd.lowerBound], encoding: .utf8),
                      let size = Int(sizeStr.split(separator: ";").first ?? "", radix: 16) else { return .invalid }
                pos = lineEnd.upperBound
                if size == 0 {
                    guard let trailerEnd = data[pos...].range(of: Data("\r\n".utf8)) else { return .incomplete }
                    pos = trailerEnd.upperBound
                    headers.removeAll { $0.0.lowercased() == "transfer-encoding" }
                    headers.append(("Content-Length", "\(body.count)"))
                    return .complete(HTTPRequest(method: String(reqLine[0]), target: String(reqLine[1]), headers: headers, body: body), consumed: pos - data.startIndex)
                }
                guard data.endIndex - pos >= size + 2 else { return .incomplete }
                body.append(data[pos..<(pos + size)])
                pos += size + 2
            }
        }
        guard data.endIndex - bodyStart >= contentLength else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return .complete(HTTPRequest(method: String(reqLine[0]), target: String(reqLine[1]), headers: headers, body: body),
                         consumed: bodyStart + contentLength - data.startIndex)
    }
}

// MARK: - Upstream response streaming + stats parsing

final class UpstreamHandler: NSObject, URLSessionDataDelegate {
    private let client: NWConnection
    private var stats: ProxyRequestStats
    private let track: Bool
    private let upstream: String
    private let emit: (ProxyRequestEvent.Phase, ProxyRequestStats) -> Void
    var session: URLSession?

    // Shared between the proxy queue (client watcher) and the URLSession delegate queue.
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var clientGone = false

    func setTask(_ t: URLSessionDataTask) {
        lock.lock(); task = t; lock.unlock()
    }

    /// Called when the client connection drops or a send fails: abort the upstream request.
    func clientDisconnected() {
        lock.lock()
        clientGone = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    private var isClientGone: Bool {
        lock.lock(); defer { lock.unlock() }
        return clientGone
    }

    private var headersSent = false
    private var isSSE = false
    private var sseLineBuffer = Data()
    private var fullBody = Data()
    private var sawUsage = false
    private var lastUIUpdate = Date.distantPast
    private var finished = false

    init(client: NWConnection, stats: ProxyRequestStats, track: Bool, upstream: String,
         emit: @escaping (ProxyRequestEvent.Phase, ProxyRequestStats) -> Void) {
        self.client = client
        self.stats = stats
        self.track = track
        self.upstream = upstream
        self.emit = emit
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        stats.status = http.statusCode
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for (k, v) in http.allHeaderFields {
            guard let ks = k as? String, let vs = v as? String else { continue }
            let lk = ks.lowercased()
            if ["content-length", "transfer-encoding", "connection", "keep-alive", "content-encoding"].contains(lk) { continue }
            if lk == "content-type", vs.lowercased().contains("text/event-stream") { isSSE = true }
            head += "\(ks): \(vs)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n"
        headersSent = true
        client.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.clientDisconnected() }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Pass the bytes straight through as one chunk.
        var chunk = Data(String(format: "%X\r\n", data.count).utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        client.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.clientDisconnected() }
        })

        guard track else { return }
        if isSSE { parseSSE(data) } else if fullBody.count < 8 << 20 { fullBody.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.session?.finishTasksAndInvalidate(); self.session = nil }
        let gone = isClientGone
        if gone {
            stats.error = "client disconnected"
            client.cancel()
        } else if !headersSent {
            let msg = error?.localizedDescription ?? "upstream error"
            stats.error = msg
            let body = "{\"error\":{\"message\":\"LM Monitor could not reach LM Studio at \(upstream): \(msg.replacingOccurrences(of: "\"", with: "'"))\"}}"
            ProxyServer.respond(client, status: 502, body: body)
        } else {
            if let error { stats.error = error.localizedDescription }
            let tail = Data("0\r\n\r\n".utf8)
            client.send(content: tail, completion: .contentProcessed { [client] _ in client.cancel() })
        }
        guard track, !finished else { return }
        finished = true
        if !isSSE, !fullBody.isEmpty, let json = try? JSONSerialization.jsonObject(with: fullBody) as? [String: Any] {
            absorb(json)
            if stats.completionTokens == 0, let usage = json["usage"] as? [String: Any], let c = usage["completion_tokens"] as? Int {
                stats.completionTokens = c
            }
            if stats.completionTokens == 0, let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                // Estimate from text when no usage was returned.
                var text = ""
                if let m = first["message"] as? [String: Any], let c = m["content"] as? String { text = c }
                else if let t = first["text"] as? String { text = t }
                stats.completionTokens = max(0, text.count / 4)
            }
            if !gone, let err = json["error"] { stats.error = (err as? String) ?? ((err as? [String: Any])?["message"] as? String) ?? "error" }
        }
        stats.finishedAt = Date()
        if stats.firstTokenAt == nil, stats.completionTokens > 0 { stats.firstTokenAt = stats.startedAt }
        emit(.finished, stats)
    }

    // MARK: SSE

    private func parseSSE(_ data: Data) {
        sseLineBuffer.append(data)
        while let nl = sseLineBuffer.firstIndex(of: 0x0A) {
            let lineData = sseLineBuffer[sseLineBuffer.startIndex..<nl]
            sseLineBuffer.removeSubrange(sseLineBuffer.startIndex...nl)
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.hasPrefix("data:") else { continue }
            var payload = line.dropFirst(5)
            while payload.first == " " { payload = payload.dropFirst() }
            if payload == "[DONE]" { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            let before = stats.completionTokens
            absorb(json)
            if stats.completionTokens > before, stats.firstTokenAt == nil { stats.firstTokenAt = Date() }
        }
        let now = Date()
        if now.timeIntervalSince(lastUIUpdate) > 0.25 {
            lastUIUpdate = now
            emit(.updated, stats)
        }
    }

    /// Pulls model name, token deltas, usage and LM Studio stats out of a response object (streamed chunk or full body).
    private func absorb(_ json: [String: Any]) {
        if let m = json["model"] as? String, !m.isEmpty { stats.model = m }
        if let choices = json["choices"] as? [[String: Any]] {
            for c in choices {
                var produced = false
                if let delta = c["delta"] as? [String: Any] {
                    for key in ["content", "reasoning_content", "reasoning"] {
                        if let s = delta[key] as? String, !s.isEmpty { produced = true }
                    }
                    if let tc = delta["tool_calls"] as? [Any], !tc.isEmpty { produced = true }
                } else if let t = c["text"] as? String, !t.isEmpty {
                    produced = true
                }
                if produced, !sawUsage { stats.completionTokens += 1 }
                if let fr = c["finish_reason"] as? String { stats.stopReason = fr }
            }
        }
        // Responses API streaming (output_text.delta events)
        if let type = json["type"] as? String, type.hasSuffix(".delta"), json["delta"] is String, !sawUsage {
            stats.completionTokens += 1
        }
        if let usage = json["usage"] as? [String: Any] {
            if let p = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int {
                stats.promptTokens = p; stats.promptTokensEstimated = false
            }
            if let c = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int, c > 0 {
                stats.completionTokens = c; sawUsage = true
            }
        }
        if let st = json["stats"] as? [String: Any] {
            if let t = st["tokens_per_second"] as? Double { stats.reportedTPS = t }
            if let t = st["time_to_first_token"] as? Double { stats.reportedTTFT = t }
            if let r = st["stop_reason"] as? String { stats.stopReason = r }
        }
    }
}
