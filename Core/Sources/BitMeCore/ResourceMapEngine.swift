import Foundation

/// Pure transforms over the resource-map wire state (BMR1 window + BMD1
/// deltas): tallying and in-place delta application. No I/O — unit-tested
/// directly, independent of the state machine.
enum ResourceMapEngine {
    struct Transition: Equatable, Sendable {
        let x: Int
        let z: Int
        let oldWord: UInt16
        let newWord: UInt16

        var oldIndex: Int { TileWord.dictIndex(oldWord) }
        var newIndex: Int { TileWord.dictIndex(newWord) }
    }

    struct Applied: Equatable, Sendable {
        let window: ResourceWindow
        /// Only tiles whose word actually changed (in-bounds, non-identical).
        let transitions: [Transition]
    }

    /// Counts populated resource tiles per dictionary index (nonzero,
    /// non-paving words — the same words the reference client tallies).
    static func tally(of window: ResourceWindow) -> (counts: [Int: Int], populatedTiles: Int) {
        var counts: [Int: Int] = [:]
        var populated = 0
        for word in window.words where TileWord.hasResource(word) {
            counts[TileWord.dictIndex(word), default: 0] += 1
            populated += 1
        }
        return (counts, populated)
    }

    /// Applies in-bounds changes to a copy of the window. Nil when the delta
    /// belongs to a different region or dictionary generation than the
    /// window — the caller marks the window stale and refetches rather than
    /// mixing dictionary generations.
    static func applying(_ delta: ResourceTileDelta, to window: ResourceWindow) -> Applied? {
        guard window.region == delta.region, window.dictVersion == delta.dictVersion else {
            return nil
        }
        var words = window.words
        var transitions: [Transition] = []
        for change in delta.changes {
            guard let i = window.wordIndex(x: change.x, z: change.z) else { continue }
            let old = words[i]
            guard old != change.word else { continue }
            words[i] = change.word
            transitions.append(Transition(x: change.x, z: change.z, oldWord: old, newWord: change.word))
        }
        guard !transitions.isEmpty else {
            return Applied(window: window, transitions: [])
        }
        return Applied(window: ResourceWindow(
            region: window.region,
            dictVersion: window.dictVersion,
            originX: window.originX,
            originZ: window.originZ,
            width: window.width,
            words: words
        ), transitions: transitions)
    }
}
