import SwiftUI
import BitMeCore

/// BitMe Pocket Crafter: workstations and craft tasks for a claim, on the
/// go. Thin SwiftUI host over the BitMeCore state machine: owns the actor,
/// forwards intents, and renders whatever the published `ViewRep` says.
/// All behavior lives in the core — this target is presentation only.
///
/// Sign-in is account-driven: the app opens on the emailed-code screen and
/// the tracked character is always the signed-in account's own player (the
/// core resolves it over the game's global database — no character-name
/// step). The resource-map stack is disabled at construction: this app
/// never renders the hex map, so it never fetches tile windows or opens the
/// change stream.
///
/// Flow: email/code → account link → the pre-sign-in gate (character card,
/// presence, Sign in / Take over session) → home while the game session is
/// held. A kicked or dropped game session returns to the gate — never
/// re-taken automatically.
@main
struct CrafterApp: App {
    @State private var machine = StateMachine(
        adapters: .production(),
        configuration: StateMachine.Configuration(
            resourceMapEnabled: false, accountDrivenSignIn: true
        )
    )
    @State private var viewRep: ViewRep?
    @State private var workstations: WorkstationsRep = .empty

    var body: some Scene {
        WindowGroup {
            RootView(
                machine: machine,
                viewRep: viewRep,
                workstations: workstations,
                ingest: { intent in await machine.ingest(intent) }
            )
            .task {
                let stream = machine.viewRep.values
                for await rep in stream {
                    viewRep = rep
                }
            }
            .task {
                // The workstation domain rides its own channel (the mapRep
                // precedent): the tabs re-render when the buildings state
                // moves, not on every session rep (stamina ticks, polls).
                let stream = machine.workstationsRep.values
                for await rep in stream {
                    workstations = rep
                }
            }
            .task {
                // Debug builds log one line per intent — the state summary
                // that answers "the UI shows X but the wire said Y" from a
                // single Console capture. Release stays silent.
                #if DEBUG
                await machine.setIngestTracing(true)
                #endif
                await machine.start()
            }
        }
    }
}

struct RootView: View {
    let machine: StateMachine
    let viewRep: ViewRep?
    let workstations: WorkstationsRep
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        // The broadcaster replays the latest rep immediately, so this
        // placeholder renders for at most a frame.
        switch viewRep {
        case .bitCraftSignIn(let signIn):
            SignInView(signIn: signIn, ingest: ingest)
        case .gameSessionPrompt(let prompt):
            GameSessionPromptView(prompt: prompt, ingest: ingest)
        case .session(let session):
            CrafterHomeView(session: session, workstations: workstations, ingest: ingest)
        case .onboarding:
            // Name onboarding is unreachable in the account-driven machine —
            // it exists for X-Ray's flow. Render the launch background if a
            // stray rep ever lands here.
            Color(white: 0.05).ignoresSafeArea()
        case nil:
            Color(white: 0.05).ignoresSafeArea()
        }
    }
}
