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
/// live session. Read only inside `Intent.mutate` and `ViewRep.from`
/// (fenex-light ADR-014).
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
