import Foundation

/// Identity for a resolved character, persisted across launches.
public struct StoredIdentity: Codable, Equatable, Sendable {
    public let entityID: String
    public let username: String
    public let regionID: Int?
    public let resolvedAt: Date

    public init(entityID: String, username: String, regionID: Int?, resolvedAt: Date) {
        self.entityID = entityID
        self.username = username
        self.regionID = regionID
        self.resolvedAt = resolvedAt
    }
}

/// Survives launches: the resolved character. Written by the machine after
/// every persistent mutation via `Adapters.persistIdentity`.
struct PersistentState: Codable, Sendable {
    var identity: StoredIdentity?
    /// The signed-in BitCraft account. The token itself round-trips through
    /// `Adapters.persistBitCraftAccount` (Keychain) — it also sits in this
    /// struct because the machine is the single source of truth.
    var bitCraftAccount: BitCraftAccount?
}

/// Lives for the process lifetime: onboarding progress, gamedata, and the
/// live session. Read only inside `Intent.mutate` and the rep projections
/// (`ViewRep.from`, `CrafterRep.from`) (fenex-light ADR-014).
struct EphemeralState: Sendable {
    enum OnboardingPhase: Equatable, Sendable {
        case idle
        case resolving(name: String)
    }

    var onboarding: OnboardingPhase = .idle
    var resolveError: String?
    var resolvedOfflineHint = false
    var gamedata: FoodBuffGamedata?
    var session: Session?
    /// Seeded once from `StateMachine.Configuration`; mutators gate the
    /// resource-map activities on it. Apps share one value for their whole
    /// process lifetime.
    var resourceMapEnabled = true
    /// Seeded once from `StateMachine.Configuration`: true for account-driven
    /// apps (Pocket Crafter), where the BitCraft sign-in screen is the root
    /// and a resolved character is always the account's own player — never a
    /// name typed on the onboarding screen.
    var accountDrivenSignIn = false

    /// BitCraft account sign-in (emailed access code). The flow:
    /// email → `requestingCode` → `awaitingCode` → `authenticating` →
    /// (`linking`, account-driven apps) → account lands in
    /// `PersistentState.bitCraftAccount`.
    var signIn = SignInState()
    /// Whether the sign-in screen is shown over whatever is behind it
    /// (onboarding or a live session); left via cancel or a successful
    /// authentication. In account-driven apps the screen is also the root
    /// whenever no character is linked — that projection needs no flag.
    var signInVisible = false
    /// Account-driven apps: the post-authentication, pre-sign-in gate is
    /// showing (the character card with its Sign in / Take over session
    /// action). True from a completed link (or a restored launch) until
    /// the user signs the game session in — and again whenever a held
    /// session ends. The game session is never re-taken automatically:
    /// only the button takes it back.
    var preSignInVisible = false
    /// The account email whose startup resume link is in flight — a
    /// persisted JWT re-locates the character over the global database
    /// while the gate already shows (in its resuming state). Nil otherwise.
    var resumingAccount: String?
    /// Why the previous game session ended (refused, kicked, lost) — shown
    /// on the pre-sign-in gate; cleared by the next sign-in attempt.
    var gameSessionNotice: String?

    struct SignInState: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case idle
            case requestingCode(email: String)
            case awaitingCode(email: String)
            case authenticating(email: String, code: String)
            /// The account is verified; its player is being located over the
            /// game's global database (account-driven apps only).
            case linking(email: String)
        }

        var phase: Phase = .idle
        var error: String?
    }

    struct Session: Sendable {
        let entityID: String
        /// Shared with the session loop activity; poll intents stamp the
        /// loop's next delay here (ADR-014 carrier pattern).
        let carrier = SessionLoopCarrier()
        var connection: Connection = .ok
        var snapshot: SessionSnapshot?
        var previous: SessionSnapshot?
        var lastError: String?
        var pacing = HarvestStateEngine.PacingEstimator()
        var notFoundBackoffMs: Double = 0
        var errorBackoffMs: Double = 0
        var loop: CancellableTask
        /// Shared with the resource-stream loop; poll intents stamp whether
        /// streaming is wanted (live + overworld) here.
        let streamCarrier = ResourceStreamCarrier()
        var streamLoop: CancellableTask?
        /// The account's game session on the game's global database: the
        /// `sign_in` the game-session loop holds, which owns the game's
        /// one-live-session slot (account-driven apps only).
        var gameSessionLoop: CancellableTask?
        var gameSession = GameSessionState()
        /// The game session's region-shard leg, once its `sign_in` commits
        /// (nil for global-only sessions). The claim-buildings sync
        /// subscribes on this connection — the game allows one live
        /// session per account per database, so all region traffic shares it.
        var regionLeg: RegionLeg?
        /// Shared with the claim-buildings loop; poll intents stamp the
        /// relay's current claim entity id here (ADR-014 carrier pattern).
        let claimCarrier = ClaimCarrier()
        /// Machine-stamped with the spawned claim-buildings sync task.
        var buildingsLoop: CancellableTask?
        /// Machine-stamped with the spawned player-vitals sync task.
        var vitalsLoop: CancellableTask?
        /// The player's own rows on the region leg — vitals pools, stats,
        /// action record, position (Pocket Crafter's status banner and the
        /// craft driver's inputs).
        var vitals = VitalsState()
        /// The pending prospection's compass row, watched anonymously on
        /// the region mirror (X-Ray's map overlay). `prospectionRegion`
        /// pins the watched region — a region transfer restarts the watch.
        var prospectionLoop: CancellableTask?
        var prospectionRegion: Int?
        var prospection = ProspectionState()
        /// The craft driver (Pocket Crafter): the walk-then-craft state
        /// machine for a tapped craft. `driverLoop` holds the running
        /// drive; a paused drive has no loop (resume re-arms with
        /// `craft_continue_start`).
        var driver = DriverState()
        var driverLoop: CancellableTask?
        /// The pinned claim's buildings, catalogs, and crafts (Pocket
        /// Crafter's workstation domain). Pinned once at sync start — the
        /// product scope is one claim per session.
        var buildings = BuildingsState()

        /// Client-side state of the claim-buildings sync.
        struct BuildingsState: Sendable {
            enum Status: Equatable, Sendable {
                case idle
                case syncing
                case live
                case failed
            }

            var status: Status = .idle
            var lastError: String?
            var claim: ClaimHeader?
            var gamedata = BuildingGamedata.empty
            var buildings: [UInt64: RegionBuilding] = [:]
            var nicknames: [UInt64: String] = [:]
            var crafts: [UInt64: RegionCraft] = [:]
            /// Entity ids in the game's shared-craft projection
            /// (`public_progressive_action_state`): effort crafts their
            /// owner opened to other players. Others' crafts render only
            /// while shared and not yet complete — private crafts (all
            /// passive ones, plus bench crafts absent here) stay counts.
            var sharedCraftIDs: Set<UInt64> = []
            /// The tracked player's entity id — the `mine` marker for crafts.
            var playerEntityID: UInt64?
            /// Bumped on every mutation, and carried forward across resets,
            /// so it stays monotonic within a session — the machine's
            /// workstations cache keys on it to skip the join when nothing
            /// in the buildings state moved.
            var version = 0

            var isEmpty: Bool {
                claim == nil && buildings.isEmpty && crafts.isEmpty && nicknames.isEmpty
            }
        }

        /// The craft driver's state: what a tapped craft is doing right
        /// now. The banner's second line renders `plan` while a craft is
        /// walking/crafting/paused/completed.
        struct DriverState: Sendable, Equatable {
            enum PauseReason: Equatable, Sendable {
                case byUser
                case outOfStamina
                case backgrounded
            }

            enum Phase: Equatable, Sendable {
                case idle
                case walking(stationName: String?)
                case crafting
                case paused(PauseReason)
                case completed(recipeName: String?)
                case failed(message: String)
            }

            var phase: Phase = .idle
            var plan: CraftPlan?

            /// The banner's activity label while a drive runs — nil hands
            /// the label back to the server's action record (paused and
            /// finished drives tell their story in the craft banner).
            var bannerActivity: String? {
                switch phase {
                case .walking: "Walking"
                case .crafting: "Crafting"
                case .idle, .paused, .completed, .failed: nil
                }
            }
        }

        /// One tapped craft the driver is walking to and driving — the
        /// plan the loop paces against and the banner renders.
        struct CraftPlan: Equatable, Sendable {
            /// The `progressive_action_state` entity — the
            /// `craft_continue*` argument ("pocket id").
            let progressiveActionEntityID: UInt64
            let buildingEntityID: UInt64
            let recipeID: Int32
            let recipeName: String?
            let stationName: String?
            /// Effort goal: `craftCount × recipe.actions_required`.
            let effortTotal: Int
            /// Latest server-confirmed effort (from the receipts' craft
            /// row; tracks the in-game progress bar).
            var effortDone: Int
            /// `recipe.stamina_requirement` — charged per completed action.
            let staminaPerAction: Float
            /// The paced delay between `craft_continue_start` and
            /// `craft_continue`, milliseconds: the server's own formula
            /// (`time_requirement / (CraftingSpeed + skill_speed − 1)`)
            /// with the ≥95 % safety margin applied.
            let delayMs: Double
            /// How close to the station's center tile to stand: footprint
            /// radius + 2 (≤2 tiles from every footprint tile, never on
            /// one — the craft range check's own metric).
            let standDistanceTiles: Int32
            /// Walk speed in raw milli-tile units/s — the measured base
            /// × the player's `MovementMultiplier` (buffs change it).
            let walkSpeedRawPerSec: Double
        }

        /// The player's own vitals from the region leg: pools, the
        /// materialized stat vector (maxes live at `CharacterStatIndex`
        /// offsets), the server's action record, and the position truth.
        struct VitalsState: Sendable, Equatable {
            var stamina: Float?
            var health: Float?
            var satiation: Float?
            var teleportEnergy: Float?
            /// The raw stat vector — the driver's speed/cooldown math
            /// reads it (`stat(_:)` bounds-checks the index).
            var stats: [Float] = []
            /// The Base-layer action row's kind — server truth for what
            /// the player is doing.
            var action = PlayerActionKind.none
            var actionRecipeID: Int32?
            /// Position in fixed-point milli-tiles; nil until the own-row
            /// snapshot lands.
            var positionX: Int32?
            var positionZ: Int32?
            var dimension: UInt32?

            var maxStamina: Float? { stat(CharacterStatIndex.maxStamina) }
            var maxHealth: Float? { stat(CharacterStatIndex.maxHealth) }
            var maxSatiation: Float? { stat(CharacterStatIndex.maxSatiation) }
            var maxTeleportEnergy: Float? { stat(CharacterStatIndex.maxTeleportationEnergy) }
            var movementMultiplier: Float? { stat(CharacterStatIndex.movementMultiplier) }
            var craftingSpeed: Float? { stat(CharacterStatIndex.craftingSpeed) }
            var gatheringSpeed: Float? { stat(CharacterStatIndex.gatheringSpeed) }
            func skillSpeed(skillID: Int32) -> Float? {
                CharacterStatIndex.skillSpeed(skillID: skillID).flatMap { stat($0) }
            }

            private func stat(_ index: Int) -> Float? {
                guard index >= 0, index < stats.count else { return nil }
                return stats[index]
            }

            var hasAnyValue: Bool {
                stamina != nil || health != nil || satiation != nil
                    || teleportEnergy != nil || !stats.isEmpty
                    || positionX != nil
            }
        }

        /// The pending prospection's compass projection
        /// (`prospecting_state`, docs/protocol/prospecting.md): a bearing
        /// cone + range from where the player stood when they prospected,
        /// cleared when the trail completes, is abandoned, or the watch
        /// dies.
        struct ProspectionState: Sendable, Equatable {
            var prospectingID: Int32?
            var trailEntityID: UInt64?
            var completedSteps: Int = 0
            var ongoingStep: Int = 0
            var totalSteps: Int = 0
            /// Compass bearings (radians, `atan2(Δz, Δx)`, world axes):
            /// two = the `[lo, hi]` cone, one = the final step's precise
            /// bearing to the prize.
            var nextCrumbAngles: [Float] = []
            /// Player→target distance, world units.
            var toNextNode: Float?
            var lastProspectionMs: Double?
            /// Where the player stood when this fix was taken (world
            /// units) — the server measured the bearing from here. The
            /// cone is anchored at this point and stays put until the next
            /// prospection, even as the player walks on.
            var fixX: Double?
            var fixZ: Double?

            var isActive: Bool { trailEntityID != nil && toNextNode != nil }
        }

        /// Projection-facing state of the game-session loop.
        struct GameSessionState: Sendable {
            enum Status: Equatable, Sendable {
                case connecting
                case live
                case reconnecting
                case rejected
            }

            var status: Status = .connecting
            var lastError: String?
        }
        /// Live resource map (window + dictionary + change feed).
        var resourceMap = ResourceMapState()
        /// Local-clock ms of the last poll — anchors the local→relay clock
        /// offset used to timestamp stream feed entries.
        var lastPolledLocalMs: Double = 0

        enum Connection: Equatable, Sendable {
            case ok
            case degraded
            case down
        }

        /// Everything derived from the resource-map endpoints (docs/api.md
        /// §6–7): the session-anchored BMR1 window, its dictionary, and the
        /// spawn/despawn feed maintained from the change stream.
        struct ResourceMapState: Sendable {
            enum StreamStatus: Equatable, Sendable {
                case off
                case connecting
                case live
                case reconnecting
            }

            struct FeedEntry: Equatable, Sendable {
                let tileX: Int
                let tileZ: Int
                /// Tile-word dictionary index — resolved to a name through
                /// the region dictionary at projection time.
                let dictIndex: Int
                /// False = the resource despawned / the tile emptied.
                let spawned: Bool
                /// Relay-clock ms (best effort: local receipt time corrected
                /// by the last snapshot's clock offset).
                let atMs: Double
            }

            var window: ResourceWindow?
            /// Local-clock ms of the fetch — drives the staleness refetch.
            var windowFetchedAtMs: Double = 0
            /// 202 seeding backoff window (local-clock ms).
            var seedingUntilMs: Double = 0
            /// Short backoff after a failed fetch (local-clock ms).
            var refetchNotBeforeMs: Double = 0
            /// Set while a fetch activity runs — keeps 1 Hz polls from
            /// stacking a second one.
            var fetchInFlight = false
            var dictionary: ResourceDictionary?
            /// `dictionary`'s index lookup, derived once on load.
            var entryByIndex: [Int: ResourceDictionary.Entry]?
            /// BME1 terrain plane behind the window (renderer background).
            var terrain: TerrainPlane?
            /// Local-clock ms of the terrain fetch (10 min TTL guidance).
            var terrainFetchedAtMs: Double = 0
            /// Dictionary index → populated resource tiles in the window.
            var tally: [Int: Int] = [:]
            /// Total populated resource tiles (nonzero, non-paving words).
            var populatedTiles = 0
            /// Newest-first spawn/despawn ring (capped by GameConfig).
            var feed: [FeedEntry] = []
            var streamStatus: StreamStatus = .off
            /// Window center reported by the stream's `subscribed` message.
            var anchorX: Int?
            var anchorZ: Int?
            /// Bumped on every tile-affecting change — prerender cache key
            /// for the map renderer (see `MapRep.tileVersion`).
            var tileVersion = 0

            var needsDictionary: (region: Int, version: Int)? {
                guard let window else { return nil }
                guard dictionary?.region != window.region || dictionary?.dictVersion != window.dictVersion else {
                    return nil
                }
                return (window.region, window.dictVersion)
            }
        }
    }
}

/// ADR-014 carrier for the resource-stream loop: the machine stamps
/// whether the stream should be connected (player live in the overworld);
/// the loop reads it between connections and never reads machine state.
final class ResourceStreamCarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var _wanted = false

    var wanted: Bool {
        get { lock.withLock { _wanted } }
        set { lock.withLock { _wanted = newValue } }
    }
}

/// ADR-014 carrier for the claim-buildings loop: poll intents stamp the
/// relay's answer for the claim the character stands in (the entity id the
/// gate already validated before the session was taken); the loop reads it
/// at startup and never reads machine state.
final class ClaimCarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var _claimEntityID: UInt64?

    var claimEntityID: UInt64? {
        get { lock.withLock { _claimEntityID } }
        set { lock.withLock { _claimEntityID = newValue } }
    }
}
