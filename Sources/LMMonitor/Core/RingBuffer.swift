import Foundation

struct RingBuffer<T> {
    private var storage: [T?]
    private var head = 0
    private(set) var count = 0
    let capacity: Int
    init(capacity: Int) { self.capacity = max(1, capacity); storage = Array(repeating: nil, count: self.capacity) }
    mutating func append(_ v: T) {
        storage[head] = v
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }
    /// Oldest → newest.
    var elements: [T] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }
    var last: T? { count == 0 ? nil : storage[(head - 1 + capacity) % capacity] }
    mutating func removeAll() { storage = Array(repeating: nil, count: capacity); head = 0; count = 0 }
}
extension RingBuffer: Equatable where T: Equatable {
    static func == (a: RingBuffer<T>, b: RingBuffer<T>) -> Bool { a.count == b.count && a.elements == b.elements }
}

struct TimePoint: Equatable { var t: Date; var v: Double? }

struct TimeSeries: Equatable {
    private(set) var points: RingBuffer<TimePoint>
    init(capacity: Int = 600) { points = RingBuffer(capacity: capacity) }
    mutating func add(_ v: Double?, at t: Date) { points.append(TimePoint(t: t, v: v)) }
    var values: [Double?] { points.elements.map { $0.v } }
    var lastValue: Double? { points.last?.v }
    func window(seconds: TimeInterval, now: Date) -> [TimePoint] { points.elements.filter { now.timeIntervalSince($0.t) <= seconds } }
    func maxValue(seconds: TimeInterval, now: Date) -> Double? { window(seconds: seconds, now: now).compactMap { $0.v }.max() }
    /// Value `seconds` ago (nearest older point), for growth checks.
    func value(secondsAgo: TimeInterval, now: Date) -> Double? {
        points.elements.last(where: { now.timeIntervalSince($0.t) >= secondsAgo })?.v
    }
}

struct SeriesSet: Equatable {
    var tps = TimeSeries(), prefillTps = TimeSeries()
    var cpu = TimeSeries(), cpuP = TimeSeries(), cpuE = TimeSeries()
    var gpu = TimeSeries(), gpuMem = TimeSeries()
    var memUsed = TimeSeries(), swapUsed = TimeSeries()
    var diskRead = TimeSeries(), diskWrite = TimeSeries()
    var powerWatts = TimeSeries(), engineRSS = TimeSeries()
}
