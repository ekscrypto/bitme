import Foundation
@testable import BitMeCore

/// Event-driven rep waiting for the machine-flow suites: resumes the moment
/// a matching rep lands, instead of polling the collector on a timer.
/// Timer polling was the old scheme — under full-suite load (many machines
/// running their loops at once) the poller tasks were starved past their
/// deadlines, stretching every staged wait to its backstop even when the
/// awaited rep had long since arrived.
enum RepCollecting {

    /// Subscribes `onRep` to the given rep channel (the machine's screen
    /// channel for its configuration — `machine.viewRep` or
    /// `machine.crafterRep` — or a domain channel like
    /// `machine.workstationsRep`) — the single subscription for the wait,
    /// since the broadcaster replays only the latest value and a second
    /// subscriber would miss intermediate reps — runs `dispatch`, and
    /// returns as soon as `until` matches any rep (returning that rep; nil
    /// only on timeout). The broadcaster's replay makes a collect issued
    /// after an `ingest` still see that ingest's final rep. The match is
    /// evaluated inside the sink callback, off every actor the test or
    /// machine occupies, so the wait costs nothing beyond the flow's own
    /// latency. `timeout` is a backstop paid only when the flow under test
    /// is broken, never on the happy path.
    @discardableResult
    static func collect<Rep: Sendable>(
        _ channel: RepBroadcaster<Rep>,
        dispatch: (@Sendable () async -> Void)? = nil,
        onRep: @Sendable @escaping (Rep) -> Void = { _ in },
        until finished: @Sendable @escaping (Rep) -> Bool,
        timeout: TimeInterval = 10
    ) async -> Rep? {
        let matchedRep = MatchedRep<Rep>()
        let matched = AsyncStream<Void> { continuation in
            let task = channel.sink { rep in
                onRep(rep)
                if finished(rep) {
                    matchedRep.set(rep)
                    continuation.yield(())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        await dispatch?()
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in matched { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
        return matchedRep.rep
    }
}

/// Lock-protected box for the matched rep — sink callbacks arrive off the
/// waiting task.
private final class MatchedRep<Rep: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _rep: Rep?

    func set(_ rep: Rep) { lock.withLock { _rep = rep } }
    var rep: Rep? { lock.withLock { _rep } }
}
