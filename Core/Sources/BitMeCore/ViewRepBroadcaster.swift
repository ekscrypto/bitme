import Foundation

/// Broadcasts a derived rep to subscribers (SwiftUI, CLI, tests). Replays
/// the latest value on subscribe, then every subsequent send, in causal
/// order, under actor isolation (fenex-light ADR-009).
public actor RepBroadcaster<Rep: Sendable> {
    private var latest: Rep
    private var subscribers: [UUID: AsyncStream<Rep>.Continuation] = [:]
    private var terminated = false

    init(initial: Rep) {
        self.latest = initial
    }

    /// The latest emitted value. Diagnostics only — observation should drive
    /// off `values`.
    public var current: Rep { latest }

    func send(_ rep: Rep) {
        guard !terminated else { return }
        latest = rep
        for continuation in subscribers.values {
            continuation.yield(rep)
        }
    }

    /// Async stream of values; replays current on subscribe.
    /// `nonisolated` so callers can start consuming without an actor hop.
    public nonisolated var values: AsyncStream<Rep> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ continuation: AsyncStream<Rep>.Continuation) {
        let id = UUID()
        continuation.yield(latest)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeSubscriber(id) }
        }
    }

    /// Closure subscription; cancels when the returned task is cancelled.
    @discardableResult
    public nonisolated func sink(_ receiveValue: @Sendable @escaping (Rep) -> Void) -> Task<Void, Never> {
        let stream = values
        return Task {
            for await rep in stream {
                receiveValue(rep)
            }
        }
    }

    public func finish() {
        terminated = true
        for continuation in subscribers {
            continuation.value.finish()
        }
        subscribers.removeAll()
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

/// The screen-shaped projection the UI (and CLI) subscribe to.
public typealias ViewRepBroadcaster = RepBroadcaster<ViewRep>
