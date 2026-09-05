import Foundation

/// Reference box the machine stamps a spawned activity `Task` into, so a
/// later intent can cancel a long-running activity (fenex-light ADR-001
/// pattern). Stamped exactly once, by the serial actor.
public final class CancellableTask: Sendable {
    private nonisolated(unsafe) var stored: Task<Void, Never>?

    init() {}

    var task: Task<Void, Never>? {
        get { stored }
        set {
            precondition(stored == nil, "CancellableTask stamped twice")
            stored = newValue
        }
    }

    public func cancel() {
        stored?.cancel()
    }

    public var isCancelled: Bool {
        stored?.isCancelled ?? false
    }
}
