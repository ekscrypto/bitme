import SwiftUI
import BitMeCore

/// Thin SwiftUI host over the BitMeCore state machine: owns the actor,
/// forwards intents, and renders whatever the published `ViewRep` says.
/// All behavior lives in the core — this target is presentation only.
@main
struct BitMeApp: App {
    @State private var machine = StateMachine(adapters: .production())
    @State private var viewRep: ViewRep?

    var body: some Scene {
        WindowGroup {
            RootView(viewRep: viewRep) { intent in
                await machine.ingest(intent)
            }
            .task {
                let stream = await machine.viewRep.values
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
    let viewRep: ViewRep?
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        // The broadcaster replays the latest rep immediately, so this
        // placeholder renders for at most a frame.
        switch viewRep {
        case .onboarding(let onboarding):
            OnboardingView(onboarding: onboarding, ingest: ingest)
        case .session(let session):
            ActivityScreen(session: session, ingest: ingest)
        case nil:
            Color(white: 0.05).ignoresSafeArea()
        }
    }
}
