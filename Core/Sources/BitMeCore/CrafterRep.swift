import Foundation

/// The pure projection of machine state for **account-driven hosts**
/// (Pocket Crafter — `StateMachine.Configuration.accountDrivenSignIn`
/// on): the emailed-code screen is the root, the tracked character is
/// always the signed-in account's own player, and the session carries
/// the account's live game session. The name-driven flow (X-Ray, CLI)
/// has its own `ViewRep`; the machine publishes exactly one of the two,
/// chosen at construction.
public enum CrafterRep: Equatable, Sendable, Codable {
    case signIn(BitCraftSignIn)
    case gameSessionPrompt(GameSessionPrompt)
    case session(Session)

    /// The post-authentication, pre-sign-in gate: the signed-in account's
    /// character at a glance — name, in-game N/E coordinates, the claim
    /// they stand in — plus the relay's live answer to whether the account
    /// already holds a session (on another device), and the action that
    /// signs the game session in.
    public struct GameSessionPrompt: Equatable, Sendable, Codable {
        public var username: String?
        public var entityID: String?
        public var region: Int?
        public var bitCraftAccountEmail: String?
        /// In-game map coordinates: super-hex N/E offsets of the
        /// character's last known position (+z north, +x east — the same
        /// display the game's map and X-Ray's tile inspect use). Nil while
        /// no position is known.
        public var north: Int?
        public var east: Int?
        /// The claim the character stands in, when relay data names one.
        public var claimName: String?
        /// The relay's presence answer: the account is signed in — on
        /// another device, since this gate shows only while this app holds
        /// no session. Nil while unknown. Drives the gate's action label:
        /// "Take over session" vs "Sign in".
        public var signedInElsewhere: Bool?
        /// True while the startup resume link is relocating the persisted
        /// account's character over the global database — the gate's
        /// pending state (identity fields are nil until it lands).
        public var resuming: Bool = false
        /// Why the previous game session ended, when there was one
        /// (refused / kicked / lost).
        public var notice: String?
    }

    public struct Session: Equatable, Sendable, Codable {
        /// The account's `sign_in` on the game's global database — the
        /// session the actual game enforces one of per account. `live`
        /// means this device owns it (other devices were kicked).
        public struct GameSession: Equatable, Sendable, Codable {
            public enum Status: String, Equatable, Sendable, Codable {
                case connecting
                case live
                case reconnecting
                case rejected
            }

            public var status: Status
            /// The server's rejection message, when `status` is `rejected`.
            public var error: String?
        }

        public var username: String?
        public var entityID: String?
        public var region: Int?
        /// Email of the signed-in BitCraft account — drives the session
        /// header's account entry.
        public var bitCraftAccountEmail: String?
        public var signedIn: Bool?
        public var connection: SessionConnection
        /// The account's live game session: the `sign_in` held on the
        /// game's global database, which owns the game's one-live-session
        /// -per-account slot.
        public var gameSession: GameSession?
        public var claimName: String?
        /// Relay clock at snapshot time — the interpolation anchor.
        public var nowMs: Double?
        public var actions: [RunningAction]
    }

    /// The projection entry the machine uses for this configuration. The
    /// workstations join rides its own `workstationsRep` channel (computed
    /// once per buildings-state change), so this path never touches it.
    static func from(
        persistent: PersistentState,
        ephemeral: EphemeralState
    ) -> CrafterRep {
        // With no linked character the sign-in screen is the root — there
        // is no name onboarding to fall back to in this flow. A startup
        // resume (persisted JWT, character still being located) is the
        // exception: the gate is already up in its resuming state, so the
        // missing identity must not pull the email screen over it.
        if ephemeral.signInVisible
            || (persistent.identity == nil && ephemeral.resumingAccount == nil) {
            return .signIn(BitCraftSignIn(
                state: ephemeral.signIn,
                canDismiss: persistent.identity != nil
            ))
        }

        // Between a completed link (or a restored launch) and a user-taken
        // game session — and again whenever a held session ends — the
        // pre-sign-in gate is the screen.
        if ephemeral.preSignInVisible {
            let position = ephemeral.session?.snapshot?.position
            let superOffset = position.map {
                SuperHexMath.tileToSuperOffset(x: $0.tileX, z: $0.tileZ)
            }
            return .gameSessionPrompt(GameSessionPrompt(
                username: persistent.identity?.username,
                entityID: persistent.identity?.entityID,
                region: ephemeral.session?.snapshot?.region ?? persistent.identity?.regionID,
                bitCraftAccountEmail: persistent.bitCraftAccount?.email,
                north: superOffset?.z,
                east: superOffset?.x,
                claimName: ephemeral.session?.snapshot?.claim?.name,
                signedInElsewhere: ephemeral.session?.snapshot?.signedIn,
                resuming: ephemeral.resumingAccount != nil,
                notice: ephemeral.gameSessionNotice
            ))
        }

        let shell = SessionShell.project(persistent: persistent, ephemeral: ephemeral)
        var gameSession: Session.GameSession?
        if let session = ephemeral.session {
            let status: Session.GameSession.Status
            switch session.gameSession.status {
            case .connecting: status = .connecting
            case .live: status = .live
            case .reconnecting: status = .reconnecting
            case .rejected: status = .rejected
            }
            gameSession = Session.GameSession(
                status: status, error: session.gameSession.lastError
            )
        }
        return .session(Session(
            username: shell.username,
            entityID: shell.entityID,
            region: shell.region,
            bitCraftAccountEmail: shell.bitCraftAccountEmail,
            signedIn: shell.signedIn,
            connection: shell.connection,
            gameSession: gameSession,
            claimName: shell.claimName,
            nowMs: shell.nowMs,
            actions: shell.actions
        ))
    }
}

/// A crafting profession — the collapsible groups of the crafting tab.
/// Skill ids are the game's profession enum (`CharacterStatType` 21+; see
/// `FoodBuffGamedata.statNames`): 0 Forestry, 1 Carpentry, 2 Masonry,
/// 3 Mining, 4 Smithing, 5 Scholar, 6 Leatherworking, 7 Hunting,
/// 8 Tailoring, 9 Farming, 10 Fishing, 11 Cooking, 12 Foraging. Cooking
/// has no group of its own — it lands in `.other` with the workbenches.
public enum Profession: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case carpentry, farming, fishing, foraging, forestry, hunting
    case leatherworking, masonry, mining, scholar, smithing, tailoring
    case other

    public var id: String { rawValue }

    public var displayName: String {
        self == .other ? "Other" : rawValue.capitalized
    }

    static func from(skillID: Int32) -> Profession? {
        switch skillID {
        case 0: .forestry
        case 1: .carpentry
        case 2: .masonry
        case 3: .mining
        case 4: .smithing
        case 5: .scholar
        case 6: .leatherworking
        case 7: .hunting
        case 8: .tailoring
        case 9: .farming
        case 10: .fishing
        case 12: .foraging
        default: nil // 11 Cooking and anything unknown → caller's "other"
        }
    }

    /// Catalog name → profession. Every crafting station in `building_desc`
    /// (verified 2026-09 against the full 233-name catalog) is either a
    /// tiered `"<Quality> <Profession> Station"` family or a classical
    /// workstation whose profession is the tool family it hosts: Kiln and
    /// Grinder → Masonry, Smelter → Smithing, Loom → Tailoring, Tanning
    /// Tub → Leatherworking, the field buildings → Farming. The rest —
    /// Cooking, workbenches, taming, sailing, construction — is nil, which
    /// the tab groups under `.other`.
    static func from(stationName: String) -> Profession? {
        let table: [(needle: String, profession: Profession)] = [
            ("Carpentry Station", .carpentry),
            ("Kiln", .masonry),
            ("Grinder", .masonry),
            ("Masonry Station", .masonry),
            ("Mining Station", .mining),
            ("Smelter", .smithing),
            ("Smithing Station", .smithing),
            ("Scholar Station", .scholar),
            ("Tanning Tub", .leatherworking),
            ("Leatherworking Station", .leatherworking),
            ("Hunting Station", .hunting),
            ("Loom", .tailoring),
            ("Tailoring Station", .tailoring),
            ("Farming Station", .farming),
            ("Farming Field", .farming),
            ("Farmer's Garden", .farming),
            ("Fishing Station", .fishing),
            ("Forestry Station", .forestry),
            ("Foraging Station", .foraging),
        ]
        return table.first { stationName.contains($0.needle) }?.profession
    }
}

/// The claim's workstations (Pocket Crafter): every building in the claim
/// joined with the catalogs, nicknames, and the crafts running at them —
/// the live state of the claim-buildings sync. This is the
/// `machine.workstationsRep` channel's payload: hosts whose whole screen
/// is the workstation list subscribe the channel and re-render only when
/// the buildings state moves, not on every session rep.
public struct WorkstationsRep: Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case idle
        case syncing
        case live
        case failed
    }

    public enum CraftPhase: String, Equatable, Sendable, Codable {
        case queued
        case processing
        case complete
        case active
        case preparing
    }

    public struct Building: Equatable, Sendable, Codable {
        public let entityID: String
        /// Nickname, else catalog name, else "Building <entity id>".
        public let name: String
        public let catalogName: String?
        /// Any function entry advertises crafting/refining slots.
        public let isCrafting: Bool
        /// Any function entry advertises item/cargo pockets.
        public let isStorage: Bool
        /// Crafts at this station (active + queued, anyone's).
        public let craftCount: Int
        /// From the catalog name (nil when the catalog hasn't landed or
        /// the station has no profession — those group under `.other`).
        public let profession: Profession?
    }

    public struct Craft: Equatable, Sendable, Codable {
        public let entityID: String
        /// Catalog recipe name; nil until the catalog lands.
        public let recipeName: String?
        /// Joined station name; nil for crafts at unknown stations.
        public let stationName: String?
        public let mine: Bool
        public let phase: CraftPhase
        /// Active crafts: completed actions of `craftCount`.
        public let progress: Int?
        public let craftCount: Int?
        /// The recipe's profession (skill id from the catalog's
        /// level-requirement or its tool type) — nil when unresolved,
        /// which the tab groups under `.other`.
        public let profession: Profession?
    }

    public var status: Status
    public var error: String?
    /// Crafting stations first, then storage, then the rest —
    /// name-sorted within each group.
    public var buildings: [Building]
    /// The player's own pending crafts first, then the claim's,
    /// each station-then-name sorted. Completed passive crafts are
    /// collected in game and stay out of the list; `craftsOverflow`
    /// counts what the cap dropped.
    public var crafts: [Craft]
    public var craftsOverflow: Int

    public static let empty = WorkstationsRep(status: .idle, error: nil, buildings: [], crafts: [], craftsOverflow: 0)

    /// Projects the claim-buildings sync state: the claim's buildings joined
    /// with the catalogs and nicknames, plus the pending crafts the
    /// subscriptions delivered (the player's own anywhere, anyone's at claim
    /// stations). Completed passive crafts are dropped — they are collected
    /// in game and would otherwise dominate a busy claim's list — and the
    /// list is capped (`craftsOverflow` carries what fell off).
    static func from(session: EphemeralState.Session?, cap: Int = 200) -> WorkstationsRep {
        guard let session else { return .empty }
        let state = session.buildings
        guard state.status != .idle, !state.isEmpty else { return .empty }

        let status: Status
        switch state.status {
        case .idle: status = .idle
        case .syncing: status = .syncing
        case .live: status = .live
        case .failed: status = .failed
        }

        let isPending: (RegionCraft) -> Bool = { craft in
            if case .passive(.complete, _) = craft.kind { return false }
            return true
        }

        var craftsByBuilding: [UInt64: Int] = [:]
        for craft in state.crafts.values where isPending(craft) {
            craftsByBuilding[craft.buildingEntityID, default: 0] += 1
        }

        let buildings: [Building] = state.buildings.values
            .map { building in
                let desc = state.gamedata.buildings[building.buildingDescriptionID]
                let nickname = state.nicknames[building.entityID]
                return Building(
                    entityID: String(building.entityID),
                    name: nickname ?? desc?.name ?? "Building \(building.entityID)",
                    catalogName: desc?.name,
                    isCrafting: desc?.isCrafting ?? false,
                    isStorage: desc?.isStorage ?? false,
                    craftCount: craftsByBuilding[building.entityID] ?? 0,
                    profession: desc.flatMap { Profession.from(stationName: $0.name) }
                )
            }
            .sorted { lhs, rhs in
                let lRank = (lhs.isCrafting ? 0 : lhs.isStorage ? 1 : 2, lhs.name, lhs.entityID)
                let rRank = (rhs.isCrafting ? 0 : rhs.isStorage ? 1 : 2, rhs.name, rhs.entityID)
                return lRank < rRank
            }

        let playerID = state.playerEntityID
        let nameByBuilding = Dictionary(uniqueKeysWithValues: buildings.map { (UInt64($0.entityID) ?? 0, $0.name) })
        let pending = state.crafts.values
            .filter { isPending($0) }
            .filter { craft in
                // Anything the subscriptions delivered is in scope by
                // construction (personal set, per-building claim sets);
                // the filter keeps stragglers from removed stations honest.
                state.buildings[craft.buildingEntityID] != nil
                    || craft.ownerEntityID == playerID
            }
            .sorted { lhs, rhs in
                let lRank = (lhs.ownerEntityID == playerID ? 0 : 1, lhs.buildingEntityID, lhs.entityID)
                let rRank = (rhs.ownerEntityID == playerID ? 0 : 1, rhs.buildingEntityID, rhs.entityID)
                return lRank < rRank
            }
        var crafts: [Craft] = []
        crafts.reserveCapacity(min(pending.count, cap))
        for craft in pending.prefix(cap) {
            let phase: CraftPhase
            var progress: Int?
            var craftCount: Int?
            switch craft.kind {
            case .passive(let status, _):
                switch status {
                case .queued: phase = .queued
                case .processing: phase = .processing
                case .complete: phase = .complete
                }
            case .active(let rawProgress, let count, let preparation, _):
                phase = preparation ? .preparing : .active
                progress = Int(rawProgress)
                craftCount = Int(count)
            }
            crafts.append(Craft(
                entityID: String(craft.entityID),
                recipeName: state.gamedata.recipeNames[craft.recipeID],
                stationName: nameByBuilding[craft.buildingEntityID],
                mine: craft.ownerEntityID == playerID,
                phase: phase,
                progress: progress,
                craftCount: craftCount,
                profession: state.gamedata.recipeSkills[craft.recipeID]
                    .flatMap(Profession.from(skillID:))
            ))
        }

        return WorkstationsRep(
            status: status, error: state.lastError,
            buildings: buildings, crafts: crafts,
            craftsOverflow: max(0, pending.count - cap)
        )
    }
}
