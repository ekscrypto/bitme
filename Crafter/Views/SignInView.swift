import SwiftUI
import BitMeCore

/// The app's launch screen: renders `BitCraftSignIn` and dispatches
/// `Intent.StartBitCraftSignIn` / `Intent.SubmitAccessCode` /
/// `Intent.RetryAccountLink`. All behavior lives in the core machine — the
/// flow is email → access code → (the core links the account's own player
/// over the game's global database) → the session takes over.
struct SignInView: View {
    let signIn: BitCraftSignIn
    let ingest: @Sendable (Sendable) async -> Void

    @State private var email = ""
    @State private var code = ""
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    private var busy: Bool {
        switch signIn.phase {
        case .requestingCode, .authenticating, .linking:
            return signIn.error == nil // a failed link waits for the user
        case .idle, .awaitingCode:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Text("BitMe Pocket Crafter")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Group {
                switch signIn.phase {
                case .idle, .requestingCode:
                    emailStep
                case .awaitingCode, .authenticating:
                    codeStep
                case .linking:
                    linkingStep
                }
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
        .background(Color(white: 0.05))
        .preferredColorScheme(.dark)
        .onAppear { focus(phase: signIn.phase) }
        .onChange(of: signIn.phase) { _, phase in focus(phase: phase) }
        .onAppear {
            if case .awaitingCode(let emailed) = signIn.phase, email.isEmpty {
                email = emailed
            }
        }
    }

    private func focus(phase: BitCraftSignIn.Phase) {
        switch phase {
        case .idle, .requestingCode: emailFocused = true
        case .awaitingCode, .authenticating: codeFocused = true
        case .linking: break // no input to focus
        }
    }

    private var subheadline: String {
        switch signIn.phase {
        case .idle, .requestingCode:
            return "Sign in with your BitCraft account"
        case .awaitingCode(let emailed):
            return "Enter the code sent to \(emailed)"
        case .authenticating(let emailed):
            return "Verifying the code sent to \(emailed)…"
        case .linking(let emailed):
            return "Signed in as \(emailed) — locating your character…"
        }
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Email address", text: $email)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .submitLabel(.go)
                .disabled(busy)
                .onSubmit { requestCode() }

            errorLabel

            Button(action: requestCode) {
                Group {
                    if case .requestingCode = signIn.phase {
                        ProgressView().tint(.white)
                    } else {
                        Text("Email me a code").bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || busy)

            dismissButton
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Sign-in code", text: $code)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($codeFocused)
                .submitLabel(.go)
                .disabled(busy)
                .onSubmit { submitCode() }

            errorLabel

            Button(action: submitCode) {
                Group {
                    if case .authenticating = signIn.phase {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify").bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)

            Button("Use a different email") {
                code = ""
                Task { await ingest(Intent.EditSignInEmail()) }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .disabled(busy)

            dismissButton
        }
    }

    /// The account is verified; the core is locating its player (or just
    /// failed to and is waiting on the user). No cancel here — there is
    /// nothing valid to go back to without a linked character.
    private var linkingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
                Text(busy ? "Finding your character…" : "Couldn't reach BitCraft.")
                    .font(.subheadline)
                    .foregroundStyle(busy ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            errorLabel

            if !busy {
                Button(action: retry) {
                    Text("Try again").bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button("Use a different email") {
                    Task { await ingest(Intent.EditSignInEmail()) }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var dismissButton: some View {
        // Only offered when something sits behind this screen (a live
        // session during an account switch).
        if signIn.canDismiss {
            Button("Cancel") {
                Task { await ingest(Intent.DismissBitCraftSignIn()) }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .disabled(busy)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let error = signIn.error {
            Label {
                Text(error)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.red)
        }
    }

    private func requestCode() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await ingest(Intent.StartBitCraftSignIn(email: trimmed)) }
    }

    private func submitCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await ingest(Intent.SubmitAccessCode(code: trimmed)) }
    }

    private func retry() {
        Task { await ingest(Intent.RetryAccountLink()) }
    }
}
