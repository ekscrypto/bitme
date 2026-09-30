import SwiftUI
import BitMeCore

/// BitMe Pocket Crafter: workstations and craft tasks for a claim, on the
/// go. Thin SwiftUI host over the BitMeCore state machine: owns the actor,
/// forwards intents, and renders whatever the published `CrafterRep` (the
/// account-driven projection) says. All behavior lives in the core — this
/// target is presentation only.
///
/// Sign-in is account-driven: the app opens on a neutral startup screen
/// until bootstrap restores persisted state, then shows the emailed-code
/// screen or (for a persisted account) the pre-sign-in gate — and the
/// tracked character is always the signed-in account's own player (the
/// core resolves it over the game's global database — no character-name
/// step). The resource-map stack is disabled at construction: this app
/// never renders the hex map, so it never fetches tile windows or opens the
/// change stream.
///
/// Flow: startup → email/code → account link → the pre-sign-in gate (character card,
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
    @State private var viewRep: CrafterRep?
    @State private var workstations: WorkstationsRep = .empty

    var body: some Scene {
        WindowGroup {
            RootView(
                machine: machine,
                viewRep: viewRep,
                workstations: workstations,
                ingest: { intent in await machine.ingest(intent) }
            )
            .modifier(LifecycleModifier(ingest: { intent in await machine.ingest(intent) }))
            .task {
                let stream = machine.crafterRep.values
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
    let viewRep: CrafterRep?
    let workstations: WorkstationsRep
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        // The broadcaster replays the latest rep immediately, so `nil`
        // renders for at most a frame — the rep itself opens on the
        // neutral `.startup` screen and stays there until bootstrap
        // decides whether the user needs to authenticate.
        switch viewRep {
        case .startup:
            StartupView()
        case .signIn(let signIn):
            SignInView(signIn: signIn, ingest: ingest)
        case .gameSessionPrompt(let prompt):
            GameSessionPromptView(prompt: prompt, ingest: ingest)
        case .session(let session):
            CrafterHomeView(session: session, workstations: workstations, ingest: ingest)
        case nil:
            Color(white: 0.05).ignoresSafeArea()
        }
    }
}

/// Backgrounding pauses a running craft drive (iOS suspends the process —
/// the client-paced loop cannot run); returning to the foreground resumes
/// a drive paused that way. User-paused and stamina-paused drives stay
/// paused until the user says otherwise.
private struct LifecycleModifier: ViewModifier {
    let ingest: @Sendable (Sendable) async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                Task { await ingest(Intent.AppBackgrounded()) }
            case .active:
                Task { await ingest(Intent.AppForegrounded()) }
            @unknown default:
                break
            }
        }
    }
}
