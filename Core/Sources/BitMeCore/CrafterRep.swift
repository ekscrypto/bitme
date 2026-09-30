import Foundation

/// The pure projection of machine state for **account-driven hosts**
/// (Pocket Crafter — `StateMachine.Configuration.accountDrivenSignIn`
/// on): the emailed-code screen is the root, the tracked character is
/// always the signed-in account's own player, and the session carries
/// the account's live game session. The name-driven flow (X-Ray, CLI)
/// has its own `ViewRep`; the machine publishes exactly one of the two,
/// chosen at construction.
public enum CrafterRep: Equatable, Sendable, Codable {
    /// The pre-bootstrap screen: persisted state is still being restored, so
    /// whether the user needs to authenticate is not yet known. Never
    /// projected — it exists only as the channel's bootstrap value; the
    /// first ingest (bootstrap completed) replaces it with a real screen.
    case startup
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
            /// The server's rejection message when `status` is
            /// `rejected`; on a `live` session, the degraded-global note
            /// (region session standing, global presence offline).
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
        /// The status banner's vitals — the player's own pools from the
        /// region leg, nil until the game session is held. Values inside
        /// may be nil while the own-row snapshot is still landing.
        public var vitals: Vitals?
        /// The active-craft banner (under the vitals strip): the tapped
        /// craft the driver is walking to / driving / has finished. Nil
        /// while no drive has been tapped (or after Stop/Dismiss).
        public var craftBanner: CraftBanner?

        public struct CraftBanner: Equatable, Sendable, Codable {
            public enum State: Equatable, Sendable, Codable {
                case walking(stationName: String?)
                case crafting
                /// Paused by the user, or out of stamina.
                case paused(outOfStamina: Bool)
                case completed
                case failed(String)
            }

            public var state: State
            public var recipeName: String?
            /// Server-confirmed effort over the effort goal.
            public var effortDone: Int?
            public var effortTotal: Int?
        }

        /// The two-line status banner's data: what the player is doing
        /// and the four pools. `activity` is the driver's phase when a
        /// drive is running (Walking / Crafting / …), else the server's
        /// own action record (`PlayerActionKind.displayName`).
        public struct Vitals: Equatable, Sendable, Codable {
            public var activity: String
            public var stamina: Float?
            public var maxStamina: Float?
            public var health: Float?
            public var maxHealth: Float?
            public var teleportEnergy: Float?
            public var maxTeleportEnergy: Float?
            public var satiation: Float?
            public var maxSatiation: Float?
        }
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
        var vitals: Session.Vitals?
        var craftBanner: Session.CraftBanner?
        if let liveSession = ephemeral.session {
            let status: Session.GameSession.Status
            switch liveSession.gameSession.status {
            case .connecting: status = .connecting
            case .live: status = .live
            case .reconnecting: status = .reconnecting
            case .rejected: status = .rejected
            }
            gameSession = Session.GameSession(
                status: status, error: liveSession.gameSession.lastError
            )
            // The banner exists only while this app holds the game session
            // (the vitals sync rides its region leg).
            if liveSession.gameSessionLoop != nil {
                vitals = Session.Vitals(
                    activity: liveSession.driver.bannerActivity
                        ?? liveSession.vitals.action.displayName,
                    stamina: liveSession.vitals.stamina,
                    maxStamina: liveSession.vitals.maxStamina,
                    health: liveSession.vitals.health,
                    maxHealth: liveSession.vitals.maxHealth,
                    teleportEnergy: liveSession.vitals.teleportEnergy,
                    maxTeleportEnergy: liveSession.vitals.maxTeleportEnergy,
                    satiation: liveSession.vitals.satiation,
                    maxSatiation: liveSession.vitals.maxSatiation
                )
            }

            // The craft banner renders whatever the driver holds — the
            // plan stays until dismissed (or stopped), so completed and
            // failed drives keep their banner.
            if liveSession.driver.phase != .idle, let plan = liveSession.driver.plan {
                let state: Session.CraftBanner.State
                switch liveSession.driver.phase {
                case .idle: state = .crafting // unreachable — guarded above
                case .walking(let station): state = .walking(stationName: station)
                case .crafting: state = .crafting
                case .paused(.outOfStamina): state = .paused(outOfStamina: true)
                case .paused: state = .paused(outOfStamina: false)
                case .completed: state = .completed
                case .failed(let message): state = .failed(message)
                }
                craftBanner = Session.CraftBanner(
                    state: state,
                    recipeName: plan.recipeName,
                    effortDone: plan.effortDone,
                    effortTotal: plan.effortTotal
                )
            }
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
            actions: shell.actions,
            vitals: vitals,
            craftBanner: craftBanner
        ))
    }
}

/// A crafting profession — the collapsible groups of the crafting tab.
/// Skill ids are the game's `skill_desc` catalog (live-verified 2026-09-27
/// against the relay's region mirror): 0 is the no-skill sentinel
/// (`tool_type_desc`'s Mallet), 1 ANY, then 2 Forestry, 3 Carpentry,
/// 4 Masonry, 5 Mining, 6 Smithing, 7 Scholar, 8 Leatherworking,
/// 9 Hunting, 10 Tailoring, 11 Farming, 12 Fishing, 13 Cooking,
/// 14 Foraging, 15+ the non-station skills (Construction, Taming, …) —
/// *not* the zero-based profession ordinals of
/// `FoodBuffGamedata.statNames` (which start at stat 21). Cooking has no
/// group of its own — it lands in `.other` with the workbenches.
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
        case 2: .forestry
        case 3: .carpentry
        case 4: .masonry
        case 5: .mining
        case 6: .smithing
        case 7: .scholar
        case 8: .leatherworking
        case 9: .hunting
        case 10: .tailoring
        case 11: .farming
        case 12: .fishing
        case 14: .foraging
        default: nil // 0 no-skill, 1 ANY, 13 Cooking, 15+ non-station skills
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
/// the live state of the claim-buildings sync. Craft rows are the player's
/// own pending crafts plus other players' **shared** bench crafts (the
/// game's `public_progressive_action_state` projection — anyone may
/// contribute); everything else of others' renders nothing, like the
/// game's own station UI. This is the
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
        /// The player's own pending crafts at this station — the row's pill
        /// and what expanding it lists first. Other players surface only
        /// through their shared (not-yet-complete) bench crafts nested
        /// under the station; their private work — abandoned bench
        /// sessions included — renders nowhere, exactly like in game.
        public let myCraftCount: Int
        /// From the catalog name (nil when the catalog hasn't landed or
        /// the station has no profession — those group under `.other`).
        public let profession: Profession?
    }

    public struct Craft: Equatable, Sendable, Codable {
        public let entityID: String
        /// The station the craft runs at — nests the row under that
        /// building's expandable list.
        public let buildingEntityID: String
        /// Catalog recipe name with its template placeholders resolved
        /// ("Braid {0} from {1}" → "Braid Rough Rope from Rough Cloth
        /// Strip"); nil until the catalog lands.
        public let recipeName: String?
        /// Joined station name; nil for crafts at unknown stations.
        public let stationName: String?
        /// The player's own craft (true) or a shared craft another player
        /// opened to the claim (false — the game's
        /// `public_progressive_action_state` lists it).
        public let mine: Bool
        public let phase: CraftPhase
        /// Active crafts: cumulative effort so far and the effort goal —
        /// `itemCount × recipe.actions_required` (nil while the recipe is
        /// unresolved). Effort, not items: 89300/129050 is 890 Exquisite
        /// Stripped Wood at 145 effort each, one-third done.
        public let progress: Int?
        public let progressTotal: Int?
        /// Active crafts: items queued (`craft_count`).
        public let itemCount: Int?
        /// The recipe's profession (skill id from the catalog's
        /// level-requirement or its tool type) — nil when unresolved,
        /// which the tab groups under `.other`. Only consulted for the
        /// player's own crafts at stations outside the claim (the rows
        /// that have no station to nest under).
        public let profession: Profession?
    }

    public var status: Status
    public var error: String?
    /// Crafting stations first, then storage, then the rest —
    /// name-sorted within each group.
    public var buildings: [Building]
    /// Rendered craft rows: the player's own pending crafts (anywhere,
    /// nested under their station), plus other players' **shared** bench
    /// crafts while not yet complete (the game's
    /// `public_progressive_action_state` projection lists them — anyone
    /// may contribute effort). Everything else of others' — private
    /// queues, unshared or abandoned bench sessions, finished-but-
    /// uncollected crafts — renders nothing, exactly like the game's
    /// station UI. Completed passive crafts are collected in game and
    /// stay out; `craftsOverflow` counts what the cap dropped.
    public var crafts: [Craft]
    public var craftsOverflow: Int

    public static let empty = WorkstationsRep(status: .idle, error: nil, buildings: [], crafts: [], craftsOverflow: 0)

    /// Projects the claim-buildings sync state: the claim's buildings joined
    /// with the catalogs and nicknames, plus the renderable craft rows —
    /// the player's own pending crafts, and other players' shared bench
    /// crafts while not yet complete. Everyone else's work (private
    /// queues, unshared or abandoned bench sessions, finished-but-
    /// uncollected crafts) renders nothing, like the game's own station
    /// UI. Completed passive crafts are dropped — they are collected in
    /// game — and the row list is capped (`craftsOverflow` carries what
    /// fell off).
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

        let playerID = state.playerEntityID

        let isPending: (RegionCraft) -> Bool = { craft in
            if case .passive(.complete, _) = craft.kind { return false }
            return true
        }
        // A bench craft is finished when its effort goal is reached —
        // `progress ≥ itemCount × recipe.actions_required` (effort, not
        // items). Unknown recipes never read as finished: showing a live
        // craft beats hiding it on a catalog gap.
        let isFinished: (RegionCraft) -> Bool = { craft in
            guard case .active(let progress, let count, _, _) = craft.kind,
                  let perCraft = state.gamedata.recipeActionsRequired[craft.recipeID] else {
                return false
            }
            return Int64(progress) >= Int64(perCraft) * Int64(count)
        }
        // A shared bench craft of someone else's, still open for effort.
        let isSharedOpen: (RegionCraft) -> Bool = { craft in
            guard case .active = craft.kind else { return false }
            return state.sharedCraftIDs.contains(craft.entityID) && !isFinished(craft)
        }

        var mineByBuilding: [UInt64: Int] = [:]
        for craft in state.crafts.values where isPending(craft) {
            if craft.ownerEntityID == playerID {
                mineByBuilding[craft.buildingEntityID, default: 0] += 1
            }
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
                    myCraftCount: mineByBuilding[building.entityID] ?? 0,
                    profession: desc.flatMap { Profession.from(stationName: $0.name) }
                )
            }
            .sorted { lhs, rhs in
                let lRank = (lhs.isCrafting ? 0 : lhs.isStorage ? 1 : 2, lhs.name, lhs.entityID)
                let rRank = (rhs.isCrafting ? 0 : rhs.isStorage ? 1 : 2, rhs.name, rhs.entityID)
                return lRank < rRank
            }

        let nameByBuilding = Dictionary(uniqueKeysWithValues: buildings.map { (UInt64($0.entityID) ?? 0, $0.name) })
        let pending = state.crafts.values
            .filter { craft in
                guard isPending(craft) else { return false }
                if craft.ownerEntityID == playerID { return true }
                return isSharedOpen(craft)
            }
            .sorted { lhs, rhs in
                let lRank = (lhs.buildingEntityID, lhs.ownerEntityID == playerID ? 0 : 1, lhs.entityID)
                let rRank = (rhs.buildingEntityID, rhs.ownerEntityID == playerID ? 0 : 1, rhs.entityID)
                return lRank < rRank
            }
        var crafts: [Craft] = []
        crafts.reserveCapacity(min(pending.count, cap))
        for craft in pending.prefix(cap) {
            let phase: CraftPhase
            var progress: Int?
            var progressTotal: Int?
            var itemCount: Int?
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
                itemCount = Int(count)
                progressTotal = state.gamedata.recipeActionsRequired[craft.recipeID]
                    .map { Int($0) * Int(count) }
            }
            crafts.append(Craft(
                entityID: String(craft.entityID),
                buildingEntityID: String(craft.buildingEntityID),
                recipeName: state.gamedata.recipeDisplayName(craft.recipeID),
                stationName: nameByBuilding[craft.buildingEntityID],
                mine: craft.ownerEntityID == playerID,
                phase: phase,
                progress: progress,
                progressTotal: progressTotal,
                itemCount: itemCount,
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
