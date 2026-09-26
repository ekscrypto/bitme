import SwiftUI
import BitMeCore

/// The post-authentication, pre-sign-in gate: the signed-in account's
/// character at a glance — name, in-game N/E coordinates, the claim they
/// stand in — and whether the account already holds a live session on
/// another device (the relay's presence answer, live at 1 Hz). The action
/// performs the game's `sign_in`: "Take over session" when someone else
/// holds it, "Sign in" when not — and only while the character stands in
/// a claim (outside one, the action is disabled). The app enters the home view on tap;
/// if the session is later kicked or dropped, the machine returns here —
/// never re-taking it automatically.
struct GameSessionPromptView: View {
    let prompt: ViewRep.GameSessionPrompt
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                header
                characterCard
                if let notice = prompt.notice {
                    Text(notice)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
                presenceLine
                Button {
                    Task { await ingest(Intent.SignInGameSession()) }
                } label: {
                    Text(prompt.signedInElsewhere == true ? "Take over session" : "Sign in")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.claimName == nil)
                Button {
                    Task { await ingest(Intent.SignOut()) }
                } label: {
                    Text("Not you? Sign out")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Spacer()
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(prompt.username ?? "—")
                .font(.title2.bold())
            if let email = prompt.bitCraftAccountEmail {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var characterCard: some View {
        VStack(spacing: 10) {
            cardRow(icon: "location.north.line", label: "Position") {
                if let north = prompt.north, let east = prompt.east {
                    Text("N \(north) · E \(east)").monospacedDigit()
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
            cardRow(icon: "flag", label: "Claim") {
                if let claim = prompt.claimName {
                    Text(claim)
                } else {
                    Text("No claim")
                        .bold()
                        .underline()
                        .foregroundStyle(.red)
                }
            }
            if let region = prompt.region {
                cardRow(icon: "globe", label: "Region") {
                    Text("\(region)").monospacedDigit()
                }
            }
        }
        .padding()
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func cardRow<Content: View>(
        icon: String, label: String, @ViewBuilder value: () -> Content
    ) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline)
            Spacer()
            value().font(.subheadline)
        }
    }

    /// The relay's live presence answer — surfaces the kick warning and
    /// the pending check; the all-clear state is silent. Outside a claim
    /// (known from a snapshot), the blocker explains itself here instead —
    /// the sign-in it guards stays disabled until the character stands in
    /// a claim.
    @ViewBuilder
    private var presenceLine: some View {
        switch (prompt.claimName == nil, prompt.signedInElsewhere) {
        case (_, nil):
            Label("Checking session status…", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case (true, _):
            Label("This app can only be used when your character is on a claim",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        case (false, .some(true)):
            Label("Signed in on another device — taking over will kick it.",
                  systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
        case (false, .some(false)):
            EmptyView()
        }
    }
}
