import Foundation

/// The tile-data projection for the hex-grid map renderer — the one place
/// where raw window words leave the machine. Unlike `ViewRep` (compact,
/// diff-friendly), this carries the full BMR1 word grid plus the BME1
/// terrain plane and the dictionary needed to color/name tiles; it is
/// published only when map-relevant state actually changed (tile data,
/// terrain, dictionary, player position), never on every poll.
public struct MapRep: Equatable, Sendable {
    public enum StreamStatus: String, Equatable, Sendable {
        case off
        case connecting
        case live
        case reconnecting
    }

    public struct Player: Equatable, Sendable {
        /// Fractional world position for a smooth marker.
        public var worldX: Double
        public var worldZ: Double
        public var tileX: Int
        public var tileZ: Int
        public var isWalking: Bool
        public var destinationWorldX: Double?
        public var destinationWorldZ: Double?
        /// > 1 = building/dungeon interior — world coords are interior
        /// coords; the overworld marker must be hidden.
        public var dimension: Int
    }

    public struct Target: Equatable, Sendable {
        public var tileX: Int
        public var tileZ: Int
    }

    /// A pending prospection's target area (docs/protocol/prospecting.md):
    /// a bearing cone anchored at where the player stood when they
    /// prospected, out to the measured range, plus the crumb-radius circle
    /// at the cone's midline (the dead-reckoned target point). Static until
    /// the next prospection — it does not follow the player marker.
    public struct Prospect: Equatable, Sendable {
        /// The fix origin — the player's position at prospection time.
        public var fixX: Double
        public var fixZ: Double
        /// Compass cone (radians, `atan2(Δz, Δx)`, world axes; +z is map
        /// north). `bearingLo == bearingHi` = the final step's precise
        /// bearing to the prize.
        public var bearingLo: Double
        public var bearingHi: Double

        /// The cone's midline — the server's true bearing to the target.
        /// Midpoint of the *signed shortest* arc lo→hi, so cones that
        /// straddle ±π (roughly due map-west) keep pointing west instead
        /// of flipping through east; on the final step (lo == hi) it is
        /// the precise bearing itself.
        public var bearingMid: Double {
            let sweep = atan2(sin(bearingHi - bearingLo), cos(bearingHi - bearingLo))
            return bearingLo + sweep / 2
        }
        /// Player→target distance, world units.
        public var distance: Double
        /// Crumb acceptance radius (world units) — the target circle.
        public var crumbRadius: Double
        /// True on the final step: the prize is the target.
        public var isFinalStep: Bool
        /// 1-based step / total (total = crumbs + final).
        public var step: Int
        public var totalSteps: Int
    }

    public var region: Int?
    public var originX: Int?
    public var originZ: Int?
    public var width: Int?
    public var words: [UInt16]
    /// Dictionary index → entry (identity for coloring/naming tiles).
    public var entries: [Int: ResourceDictionary.Entry]
    /// Dictionary index → populated resource tiles in the window (the
    /// filter panel's nearby counts).
    public var tally: [Int: Int]
    public var terrain: TerrainPlane?
    /// Window center the stream subscription is anchored to.
    public var anchorX: Int?
    public var anchorZ: Int?
    public var populatedTiles: Int
    public var stream: StreamStatus
    public var player: Player?
    public var target: Target?
    /// Pending prospection overlay (nil while the player has none).
    public var prospect: Prospect?
    /// Bumped on every tile-affecting change (window fetch, delta, dict,
    /// terrain) — renderers key their prerender caches on it instead of
    /// diffing 160k words.
    public var tileVersion: Int

    public static let empty = MapRep(
        region: nil, originX: nil, originZ: nil, width: nil, words: [],
        entries: [:], tally: [:], terrain: nil, anchorX: nil, anchorZ: nil,
        populatedTiles: 0, stream: .off, player: nil, target: nil,
        prospect: nil, tileVersion: 0
    )

    static func from(ephemeral: EphemeralState) -> MapRep {
        guard let session = ephemeral.session else { return .empty }
        let map = session.resourceMap

        let player: Player?
        if let position = session.snapshot?.position {
            player = Player(
                worldX: position.worldX,
                worldZ: position.worldZ,
                tileX: position.tileX,
                tileZ: position.tileZ,
                isWalking: position.isWalking,
                destinationWorldX: position.isWalking ? position.destinationWorldX : nil,
                destinationWorldZ: position.isWalking ? position.destinationWorldZ : nil,
                dimension: position.dimension
            )
        } else {
            player = nil
        }

        let target: Target?
        if let location = session.snapshot?.target?.location {
            target = Target(tileX: location.tileX, tileZ: location.tileZ)
        } else {
            target = nil
        }

        let prospect: Prospect?
        if session.prospection.isActive,
           let distance = session.prospection.toNextNode, distance > 0,
           let fixX = session.prospection.fixX, let fixZ = session.prospection.fixZ,
           // An angle-less row has no direction to draw — the server
           // always sends one (final) or two (cone); anything else is a
           // decode anomaly, and a fallback bearing would point somewhere
           // the trail doesn't.
           !session.prospection.nextCrumbAngles.isEmpty {
            let angles = session.prospection.nextCrumbAngles
            let lo = angles.map(Double.init).min() ?? 0
            let hi = angles.map(Double.init).max() ?? 0
            prospect = Prospect(
                fixX: fixX,
                fixZ: fixZ,
                bearingLo: lo,
                bearingHi: hi,
                distance: Double(distance),
                crumbRadius: GameConfig.shared.prospectCrumbRadius,
                isFinalStep: session.prospection.ongoingStep >= session.prospection.totalSteps - 1,
                step: session.prospection.ongoingStep + 1,
                totalSteps: session.prospection.totalSteps
            )
        } else {
            prospect = nil
        }

        let stream: StreamStatus
        switch map.streamStatus {
        case .off: stream = .off
        case .connecting: stream = .connecting
        case .live: stream = .live
        case .reconnecting: stream = .reconnecting
        }

        return MapRep(
            region: map.window?.region,
            originX: map.window?.originX,
            originZ: map.window?.originZ,
            width: map.window?.width,
            words: map.window?.words ?? [],
            entries: map.entryByIndex ?? [:],
            tally: map.tally,
            terrain: map.terrain,
            anchorX: map.anchorX,
            anchorZ: map.anchorZ,
            populatedTiles: map.populatedTiles,
            stream: stream,
            player: player,
            target: target,
            prospect: prospect,
            tileVersion: map.tileVersion
        )
    }
}
