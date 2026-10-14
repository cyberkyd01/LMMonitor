import Foundation
import AppKit

struct LMActionError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Runs a short-lived child process with a timeout. Blocking: call off the main thread.
enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var launchError: String?
    }

    private final class Box {
        let lock = NSLock()
        var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    static func run(_ exe: URL, _ args: [String], timeout: TimeInterval) -> Output {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"; env["FORCE_COLOR"] = "0"; env["TERM"] = "dumb"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let outBox = Box(), errBox = Box()
        let outH = outPipe.fileHandleForReading, errH = errPipe.fileHandleForReading
        outH.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { outBox.append(d) } }
        errH.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { errBox.append(d) } }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            outH.readabilityHandler = nil; errH.readabilityHandler = nil
            return Output(status: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
        }
        outH.readabilityHandler = nil; errH.readabilityHandler = nil
        if let rest = try? outH.readToEnd() { outBox.append(rest) }
        if let rest = try? errH.readToEnd() { errBox.append(rest) }
        return Output(status: p.terminationStatus, stdout: outBox.string, stderr: errBox.string, timedOut: timedOut, launchError: nil)
    }
}

enum LMActions {
    private static let queue = DispatchQueue(label: "lmmonitor.actions", qos: .userInitiated, attributes: .concurrent)

    // MARK: unload / start server

    static func unload(identifier: String, lms: URL?, completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error>
            if let lms {
                result = commandResult(ProcessRunner.run(lms, ["unload", identifier], timeout: 60), success: "Unloaded \(identifier)")
            } else {
                result = restUnload(identifier)
            }
            hopToMain { completion(result) }
        }
    }

    static func startServer(lms: URL?, completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error>
            if let lms {
                result = commandResult(ProcessRunner.run(lms, ["server", "start"], timeout: 60), success: "Server start requested")
            } else {
                result = .failure(LMActionError(message: "lms not found"))
            }
            hopToMain { completion(result) }
        }
    }

    private static func commandResult(_ out: ProcessRunner.Output, success: String) -> Result<String, Error> {
        if let e = out.launchError { return .failure(LMActionError(message: e)) }
        if out.timedOut { return .failure(LMActionError(message: "Timed out after 60 s")) }
        if out.status != 0 {
            let text = stripANSI(out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LMActionError(message: text.isEmpty ? "lms exited with status \(out.status)" : String(text.suffix(300))))
        }
        return .success(success)
    }

    private static func restUnload(_ identifier: String) -> Result<String, Error> {
        var req = URLRequest(url: Settings.lmStudioBaseURL.appendingPathComponent("api/v1/models/unload"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["instance_id": identifier])
        req.timeoutInterval = 30
        let sem = DispatchSemaphore(value: 0)
        let box = RestBox()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            box.set(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, error: err?.localizedDescription, body: data)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        let (status, err, body) = box.get()
        if (200..<300).contains(status) { return .success("Unloaded \(identifier)") }
        let text = err ?? body.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(200)) } ?? "HTTP \(status)"
        return .failure(LMActionError(message: text))
    }

    private final class RestBox {
        private let lock = NSLock()
        private var status = 0, error: String?, body: Data?
        func set(status: Int, error: String?, body: Data?) { lock.lock(); self.status = status; self.error = error; self.body = body; lock.unlock() }
        func get() -> (Int, String?, Data?) { lock.lock(); defer { lock.unlock() }; return (status, error, body) }
    }

    // MARK: open LM Studio

    static func openLMStudio() {
        let ws = NSWorkspace.shared
        let url = ws.urlForApplication(withBundleIdentifier: "ai.elementlabs.lmstudio")
            ?? URL(fileURLWithPath: "/Applications/LM Studio.app")
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    // MARK: estimate

    static func estimateFit(modelKey: String, lms: URL?, completion: @escaping @MainActor @Sendable (FitEstimate?) -> Void) {
        queue.async {
            var est: FitEstimate?
            if let lms {
                let out = ProcessRunner.run(lms, ["load", modelKey, "--estimate-only", "--yes"], timeout: 60)
                if out.launchError == nil, !out.timedOut {
                    let e = parseEstimate(out.stdout + "\n" + out.stderr)
                    if e.gpuBytes != nil || e.totalBytes != nil || e.verdict != nil { est = e }
                }
            }
            let result = est
            hopToMain { completion(result) }
        }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    /// Parses `lms load --estimate-only` output (ANSI-stripped first).
    static func parseEstimate(_ output: String) -> FitEstimate {
        var e = FitEstimate()
        for raw in stripANSI(output).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = value(of: "Estimated GPU Memory:", in: line) { e.gpuBytes = parseSize(v) }
            else if let v = value(of: "Estimated Total Memory:", in: line) { e.totalBytes = parseSize(v) }
            else if let v = value(of: "Confidence:", in: line) { e.confidence = v.isEmpty ? nil : v }
            else if let v = value(of: "Estimate:", in: line) { e.verdict = v.isEmpty ? nil : v }
        }
        return e
    }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private static func parseSize(_ s: String) -> UInt64? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first, let n = Double(first.replacingOccurrences(of: ",", with: "")) else { return nil }
        let unit = parts.count > 1 ? parts[1].lowercased() : "b"
        let mult: Double
        switch unit {
        case "kib": mult = 1024
        case "mib": mult = 1_048_576
        case "gib": mult = 1_073_741_824
        case "tib": mult = 1_099_511_627_776
        case "kb": mult = 1000
        case "mb": mult = 1_000_000
        case "gb": mult = 1_000_000_000
        case "tb": mult = 1_000_000_000_000
        default: mult = 1
        }
        let v = n * mult
        return v >= 0 && v < 1.8e19 ? UInt64(v) : nil
    }

    // MARK: CSV

    static let csvHeader = ["startedAt", "model", "engine", "tokensPerSecond", "prefillTokensPerSecond", "timeToFirstToken",
                            "promptTotal", "promptCached", "cachedIsEstimate", "generatedTokens", "totalTime", "stopReason",
                            "draftAccepted", "draftGenerated", "contextTokensAtEnd", "contextLimit", "truncated", "error", "sources"]

    /// RFC 4180: CRLF line endings, fields quoted when they contain a comma, quote, CR or LF.
    static func exportCSV(_ records: [PredictionRecord]) -> String {
        let iso = ISO8601DateFormatter()
        func f(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        func i(_ v: Int?) -> String { v.map(String.init) ?? "" }
        var rows: [String] = [csvHeader.joined(separator: ",")]
        for r in records {
            let fields: [String] = [
                iso.string(from: r.startedAt), r.model, r.engineType ?? "",
                f(r.tokensPerSecond, 2), f(r.prefillTokensPerSecond, 2), f(r.timeToFirstToken, 3),
                i(r.prompt.totalTokens), i(r.prompt.cachedTokens), r.prompt.cachedIsEstimate ? "true" : "false",
                i(r.generatedTokens), f(r.totalTime, 3), r.stopReasonRaw ?? r.stopReason.rawValue,
                i(r.draft?.accepted), i(r.draft?.generated), i(r.contextTokensAtEnd), i(r.contextLimit),
                r.truncated ? "true" : "false", r.error ?? "", r.sources.map { $0.rawValue }.joined(separator: "|")
            ]
            rows.append(fields.map(csvQuote).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvQuote(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
