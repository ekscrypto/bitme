import Foundation
@testable import BitMeCore

/// Event-driven rep waiting for the machine-flow suites: resumes the moment
/// a matching rep lands, instead of polling the collector on a timer.
/// Timer polling was the old scheme — under full-suite load (many machines
/// running their loops at once) the poller tasks were starved past their
/// deadlines, stretching every staged wait to its backstop even when the
/// awaited rep had long since arrived.
enum RepCollecting {

    /// Subscribes `onRep` to the machine's rep stream — the single
    /// subscription for the wait, since the broadcaster replays only the
    /// latest value and a second subscriber would miss intermediate reps —
    /// runs `dispatch`, and returns as soon as `until` matches any rep.
    /// The match is evaluated inside the sink callback, off every actor the
    /// test or machine occupies, so the wait costs nothing beyond the
    /// flow's own latency. `timeout` is a backstop paid only when the flow
    /// under test is broken, never on the happy path.
    static func collect(
        _ machine: StateMachine,
        dispatch: (@Sendable () async -> Void)? = nil,
        onRep: @Sendable @escaping (ViewRep) -> Void,
        until finished: @Sendable @escaping (ViewRep) -> Bool,
        timeout: TimeInterval = 10
    ) async {
        let matched = AsyncStream<Void> { continuation in
            let task = machine.viewRep.sink { rep in
                onRep(rep)
                if finished(rep) { continuation.yield(()) }
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
    }
}
