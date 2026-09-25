import SwiftUI
import BitMeCore

/// BitCraft account sign-in: renders `ViewRep.BitCraftSignIn` and dispatches
/// `Intent.StartBitCraftSignIn` / `Intent.SubmitAccessCode`. All behavior
/// lives in the core machine.
struct SignInView: View {
    let signIn: ViewRep.BitCraftSignIn
    let ingest: @Sendable (Sendable) async -> Void

    @State private var email = ""
    @State private var code = ""
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    private var busy: Bool {
        switch signIn.phase {
        case .requestingCode, .authenticating: return true
        case .idle, .awaitingCode: return false
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Text("BitCraft sign in")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Group {
                switch signIn.phase {
                case .idle, .requestingCode:
                    emailStep
                case .awaitingCode, .authenticating:
                    codeStep
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

    private func focus(phase: ViewRep.BitCraftSignIn.Phase) {
        switch phase {
        case .idle, .requestingCode: emailFocused = true
        case .awaitingCode, .authenticating: codeFocused = true
        }
    }

    private var subheadline: String {
        switch signIn.phase {
        case .idle, .requestingCode:
            return "BitCraft will email you a sign-in code"
        case .awaitingCode(let emailed):
            return "Enter the code sent to \(emailed)"
        case .authenticating(let emailed):
            return "Verifying the code sent to \(emailed)…"
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

    private var dismissButton: some View {
        Button("Cancel") {
            Task { await ingest(Intent.DismissBitCraftSignIn()) }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .disabled(busy)
        .padding(.top, 4)
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
}
