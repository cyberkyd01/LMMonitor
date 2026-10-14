import Foundation

/// Minimal assertion collector for `LMMonitor --selftest` (no XCTest with Command Line Tools).
final class TestContext {
    private(set) var passes = 0
    private(set) var failures = 0
    private var suite = ""
    var verbose = CommandLine.arguments.contains("--verbose")

    func suite(_ name: String) { suite = name; print("── \(name)") }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passes += 1
            if verbose { print("  PASS \(name)") }
        } else {
            failures += 1
            let d = detail()
            print("  FAIL [\(suite)] \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ a: T, _ b: T) {
        check(name, a == b, "got \(a), expected \(b)")
    }

    func near(_ name: String, _ a: Double?, _ b: Double, tol: Double = 1e-6) {
        guard let a else { check(name, false, "got nil, expected \(b)"); return }
        check(name, abs(a - b) <= tol, "got \(a), expected \(b)")
    }
}

enum SelfTest {
    static func run() -> Int32 {
        let t = TestContext()
        print("LM Monitor self-test")
        CoreTests.run(t)
        ParserTests.run(t)
        ReducerTests.run(t)
        IntegrationTests.run(t)
        IntegrationTests.runReviewFixes(t)
        print("\(t.passes) passed, \(t.failures) failed")
        return t.failures == 0 ? 0 : 1
    }
}

/// Tests for the small shared utilities in Core/.
enum CoreTests {
    static func run(_ t: TestContext) {
        t.suite("Core")
        // LineFramer: split across chunks, CRLF, oversize discard
        var f = LineFramer(maxLineBytes: 1024)
        var out = f.append(Data("ab".utf8))
        t.equal("framer partial", out.count, 0)
        out = f.append(Data("c\r\nde\nf".utf8))
        t.equal("framer lines", out.map { String(decoding: $0, as: UTF8.self) }, ["abc", "de"])
        out = f.append(Data(String(repeating: "x", count: 3000).utf8))
        t.equal("framer oversize pending", out.count, 0)
        out = f.append(Data("yy\nok\n".utf8))
        t.equal("framer after discard", out.map { String(decoding: $0, as: UTF8.self) }, ["ok"])
        t.equal("framer dropped count", f.droppedLines, 1)

        // NDJSON
        t.check("ndjson banner ignored", NDJSON.object(Data("Streaming logs from LM Studio".utf8)) == nil)
        let o = NDJSON.object(Data(#"{"timestamp":1792001976732,"data":{"type":"x"}}"#.utf8))
        t.check("ndjson object", o != nil)
        if let o { t.near("ndjson timestamp", NDJSON.timestamp(o)?.timeIntervalSince1970, 1792001976.732, tol: 1e-3) }

        // RecentLineSet
        let r = RecentLineSet(capacity: 2)
        t.check("dedupe first", r.insert("a"))
        t.check("dedupe dup", !r.insert("a"))
        r.insert("b"); r.insert("c")
        t.check("dedupe evicted", r.insert("a"))

        // RingBuffer
        var rb = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { rb.append(i) }
        t.equal("ring wrap", rb.elements, [3, 4, 5])
        t.equal("ring last", rb.last, 5)

        // Fmt
        t.equal("fixed width", Fmt.fixed(5.2, width: 5, decimals: 1).count, Fmt.fixed(112.3, width: 5, decimals: 1).count)
        t.equal("duration", Fmt.duration(3725), "1:02:05")
        t.equal("tokens k", Fmt.tokens(27343), "27.3k")
        t.equal("ModelKey norm", ModelKey.norm("Qwen3.8-27B-MLX@4bit"), "qwen3.8-27b-mlx")

        // UInt64 → Double must convert the value, not reinterpret bits (unlabeled `Double.init`
        // references can resolve to `init(bitPattern:)`; MetricsStore once graphed 0 MB because of it).
        let bytes: UInt64? = 27_700_000_000
        t.near("UInt64 to Double conversion", bytes.map { Double($0) }, 27_700_000_000, tol: 0.5)

        // Rx
        let rx = Rx(#"^a(\d+)(x)?b$"#)
        t.equal("rx captures", rx.captures("a12b") ?? [], ["12", ""])
    }
}
