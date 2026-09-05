import SwiftUI
import Observation
import os

@main
struct BitMeApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
    }
}

/// Durable onboarding state (tutorial 1, step 4). On relaunch the app skips
/// straight to the activity screen.
struct StoredIdentity: Codable, Equatable, Sendable {
    let entityID: String
    let username: String
    let regionID: Int?
    let resolvedAt: Date
}

@MainActor
@Observable
final class AppModel {
    private static let identityKey = "bitme.identity.v1"
    private static let log = Logger(subsystem: "life.encoded.bitme.ios", category: "onboarding")

    /// The relay answers misses in tens of milliseconds; hold the resolving
    /// state at least this long so the spinner is actually perceivable.
    private static let minimumResolvingDuration: TimeInterval = 0.7

    let relay = RelayClient.production

    private(set) var identity: StoredIdentity?

    var isResolving = false
    var resolveErrorText: String?
    /// Live sign-in state from the last resolve — used to soften the
    /// onboarding message when the name is real but the character is offline.
    var resolvedOffline = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.identityKey),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data) {
            identity = stored
        }
    }

    func resolve(_ rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isResolving = true
        resolveErrorText = nil
        resolvedOffline = false
        Self.log.info("resolve “\(name, privacy: .public)” started")
        let startedAt = Date()
        defer {
            // Keep spinner + disabled button up for a perceivable minimum.
            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = Self.minimumResolvingDuration - elapsed
            if remaining > 0 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(remaining))
                    self?.isResolving = false
                }
            } else {
                isResolving = false
            }
        }
        do {
            let resolved = try await relay.resolve(name: name)
            identity = StoredIdentity(
                entityID: resolved.entityID,
                username: resolved.username,
                regionID: resolved.regionID,
                resolvedAt: .now
            )
            resolvedOffline = resolved.signedIn == false
            persistIdentity()
            Self.log.info("resolve “\(name, privacy: .public)” found entity \(resolved.entityID, privacy: .public)")
        } catch RelayError.notFound {
            resolveErrorText = "No character found with the exact name “\(name)”."
            Self.log.info("resolve “\(name, privacy: .public)” missed (404)")
        } catch let RelayError.badRequest(message) {
            resolveErrorText = message
            Self.log.error("resolve “\(name, privacy: .public)” bad request: \(message, privacy: .public)")
        } catch {
            resolveErrorText = "Relay unreachable — check your connection and try again."
            Self.log.error("resolve “\(name, privacy: .public)” failed: \(String(describing: error), privacy: .public)")
        }
    }

    func signOut() {
        identity = nil
        UserDefaults.standard.removeObject(forKey: Self.identityKey)
    }

    private func persistIdentity() {
        guard let identity,
              let data = try? JSONEncoder().encode(identity) else { return }
        UserDefaults.standard.set(data, forKey: Self.identityKey)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let identity = appModel.identity {
            ActivityScreen(identity: identity)
        } else {
            OnboardingView()
                .onAppear { Task { await appModel.autoResolveIfHooked() } }
        }
    }
}

extension AppModel {
    /// DEBUG smoke-test hook: `SIMCTL_CHILD_BITME_AUTO_RESOLVE=<name>`
    /// (simctl) or `BITME_AUTO_RESOLVE=<name>` (Xcode scheme env) skips the
    /// typed onboarding. No-op outside DEBUG builds.
    func autoResolveIfHooked() async {
        #if DEBUG
        guard identity == nil, !isResolving else { return }
        if let name = ProcessInfo.processInfo.environment["BITME_AUTO_RESOLVE"], !name.isEmpty {
            await resolve(name)
        }
        #endif
    }
}
