import SwiftUI
import BitMeCore
import UIKit

/// BitMe X-Ray: the map-first companion — resolve a character by name,
/// then live on the hex resource map. Thin SwiftUI host over the BitMeCore
/// state machine: owns the actor, forwards intents, and renders whatever
/// the published `ViewRep` says. All behavior lives in the core — this
/// target is presentation only.
@main
struct XRayApp: App {
    @State private var machine = StateMachine(adapters: .production())
    @State private var viewRep: ViewRep?

    var body: some Scene {
        WindowGroup {
            RootView(
                machine: machine,
                viewRep: viewRep,
                ingest: { intent in await machine.ingest(intent) }
            )
            .task {
                let stream = machine.viewRep.values
                for await rep in stream {
                    viewRep = rep
                }
            }
            .task {
                await machine.start()
            }
        }
    }
}

struct RootView: View {
    let machine: StateMachine
    let viewRep: ViewRep?
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        screen
            // X-Ray is a live companion: while the relay sees the player
            // in-game, keep the display on so the map keeps earning its
            // stream. `playerIsOnline` reads the same liveness signal
            // (`signedIn != false`) the core gates the change stream on.
            .keepScreenAwake(playerIsOnline)
    }

    @ViewBuilder
    private var screen: some View {
        // The broadcaster replays the latest rep immediately, so this
        // placeholder renders for at most a frame.
        switch viewRep {
        case .onboarding(let onboarding):
            OnboardingView(
                onboarding: onboarding,
                ingest: ingest,
                appTitle: "BitMe X-Ray",
                tagline: "The live resource map"
            )
        case .signIn:
            // The BitCraft sign-in screen is a machine capability in this
            // flow too, but no X-Ray view dispatches `ShowBitCraftSignIn` —
            // the account entry belongs to Pocket Crafter. Fall through to
            // the placeholder; the next rep restores a real screen.
            Color(white: 0.05).ignoresSafeArea()
        case .session:
            MapScreen(machine: machine, ingest: ingest)
        case nil:
            Color(white: 0.05).ignoresSafeArea()
        }
    }

    /// True while a session is showing and the relay hasn't reported the
    /// player offline (`signedIn` nil = not yet answered, same reading as
    /// the core's stream liveness gate in `Intent.SessionPolled`).
    private var playerIsOnline: Bool {
        guard case .session(let session) = viewRep else { return false }
        return session.signedIn != false
    }
}

/// The only lever iOS gives for "don't dim the screen" is the UIKit idle
/// timer — SwiftUI has no equivalent, so this bridges it. Re-runs on every
/// change of `awake` (and at appear) to keep the flag in sync.
private struct KeepScreenAwake: ViewModifier {
    let awake: Bool

    func body(content: Content) -> some View {
        content.task(id: awake) {
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }
}

private extension View {
    func keepScreenAwake(_ awake: Bool) -> some View {
        modifier(KeepScreenAwake(awake: awake))
    }
}
