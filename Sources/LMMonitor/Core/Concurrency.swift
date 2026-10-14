import Foundation

/// RULE: every closure handed to Task / DispatchQueue is @Sendable. Capture only `let`
/// constants of value types. Never capture a `var` (Swift 5.10 error: "reference to
/// captured var in concurrently-executing code").
@inline(__always)
func hopToMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    Task { @MainActor in body() }
}

/// Coalesces calls on a serial queue: fires `action` at most every `interval`, trailing edge.
final class Coalescer {
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private var scheduled = false
    private let action: () -> Void
    init(queue: DispatchQueue, interval: TimeInterval, action: @escaping () -> Void) {
        self.queue = queue; self.interval = interval; self.action = action
    }
    /// Call only from `queue`.
    func poke() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.action()
        }
    }
}
