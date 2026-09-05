import Foundation

/// Broadcasts the derived `ViewRep` to subscribers (SwiftUI, CLI, tests).
/// Replays the latest value on subscribe, then every subsequent send, in
/// causal order, under actor isolation (fenex-light ADR-009).
public actor ViewRepBroadcaster {
    private var latest: ViewRep
    private var subscribers: [UUID: AsyncStream<ViewRep>.Continuation] = [:]
    private var terminated = false

    init(initial: ViewRep) {
        self.latest = initial
    }

    /// The latest emitted value. Diagnostics only — observation should drive
    /// off `values`.
    public var current: ViewRep { latest }

    func send(_ viewRep: ViewRep) {
        guard !terminated else { return }
        latest = viewRep
        for continuation in subscribers.values {
            continuation.yield(viewRep)
        }
    }

    /// Async stream of ViewRep values; replays current on subscribe.
    /// `nonisolated` so callers can start consuming without an actor hop.
    public nonisolated var values: AsyncStream<ViewRep> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ continuation: AsyncStream<ViewRep>.Continuation) {
        let id = UUID()
        continuation.yield(latest)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeSubscriber(id) }
        }
    }

    /// Closure subscription; cancels when the returned task is cancelled.
    @discardableResult
    public nonisolated func sink(_ receiveValue: @Sendable @escaping (ViewRep) -> Void) -> Task<Void, Never> {
        let stream = values
        return Task {
            for await viewRep in stream {
                receiveValue(viewRep)
            }
        }
    }

    public func finish() {
        terminated = true
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
