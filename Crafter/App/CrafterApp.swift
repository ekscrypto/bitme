import SwiftUI
import BitMeCore

/// BitMe Pocket Crafter: workstations and craft tasks for a claim, on the
/// go. Thin SwiftUI host over the BitMeCore state machine: owns the actor,
/// forwards intents, and renders whatever the published `ViewRep` says.
/// All behavior lives in the core — this target is presentation only.
///
/// The resource-map stack is disabled at construction: this app never
/// renders the hex map, so it never fetches tile windows or opens the
/// change stream.
@main
struct CrafterApp: App {
    @State private var machine = StateMachine(
        adapters: .production(),
        configuration: StateMachine.Configuration(resourceMapEnabled: false)
    )
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
                appTitle: "BitMe Pocket Crafter",
                tagline: "Your claim's crafts, on the go",
                showsBitCraftSignIn: true
            )
        case .bitCraftSignIn(let signIn):
            SignInView(signIn: signIn, ingest: ingest)
        case .session(let session):
            CrafterHomeView(session: session, ingest: ingest)
        case nil:
            Color(white: 0.05).ignoresSafeArea()
        }
    }
}
