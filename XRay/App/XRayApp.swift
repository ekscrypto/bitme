import SwiftUI
import BitMeCore

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
        // The broadcaster replays the latest rep immediately, so this
        // placeholder renders for at most a frame.
        switch viewRep {
        case .onboarding(let onboarding):
            OnboardingView(
                onboarding: onboarding,
                ingest: ingest,
                appTitle: "BitMe X-Ray",
                tagline: "The live resource map",
                showsBitCraftSignIn: false
            )
        case .bitCraftSignIn:
            // Unreachable in X-Ray: nothing dispatches `ShowBitCraftSignIn`.
            // Fall through to the placeholder — the next rep restores a real
            // screen (a hidden restored account never opens the flow).
            Color(white: 0.05).ignoresSafeArea()
        case .session:
            MapScreen(machine: machine, ingest: ingest)
        case nil:
            Color(white: 0.05).ignoresSafeArea()
        }
    }
}
