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

        enum Connection: Equatable, Sendable {
            case ok
            case degraded
            case down
        }
    }
}
