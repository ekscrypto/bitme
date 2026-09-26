import SwiftUI
import BitMeCore

/// Onboarding: renders `ViewRep.Onboarding` and dispatches
/// `Intent.ResolvePlayer`. All behavior lives in the core machine.
/// Shared by both apps — the host passes its title, tagline, and whether
/// the BitCraft account entry point is offered at all (X-Ray resolves by
/// character name only; Pocket Crafter needs the account).
struct OnboardingView: View {
    let onboarding: ViewRep.Onboarding
    let ingest: @Sendable (Sendable) async -> Void
    let appTitle: String
    let tagline: String
    var showsBitCraftSignIn = false

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Text(appTitle)
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Character name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .submitLabel(.go)
                    .disabled(onboarding.isResolving)
                    .onSubmit(dispatch)
                    .onChange(of: name) { _, _ in
                        // A fresh edit invalidates the previous attempt's error;
                        // presentation-only state, the machine owns the truth.
                        // (Dispatching would be redundant — errors only clear on
                        // the next resolve — so we just visually detach it.)
                        lastErrorDetached = true
                    }

                if onboarding.isResolving {
                    Label("Looking up “\(onboarding.lookingUpName ?? name)”…",
                          systemImage: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let error = onboarding.error, !lastErrorDetached {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 32)

            Button(action: dispatch) {
                Group {
                    if onboarding.isResolving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue").bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || onboarding.isResolving)
            .padding(.horizontal, 32)

            if showsBitCraftSignIn {
                if let accountEmail = onboarding.bitCraftAccountEmail {
                    Button {
                        Task { await ingest(Intent.ShowBitCraftSignIn()) }
                    } label: {
                        Label("Signed in to BitCraft as \(accountEmail)",
                              systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    .padding(.top, 4)
                } else {
                    Button("Sign in with BitCraft") {
                        Task { await ingest(Intent.ShowBitCraftSignIn()) }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.top, 4)
                }
            }

            Spacer()
            Spacer()
        }
        .background(Color(white: 0.05))
        .preferredColorScheme(.dark)
        .onAppear { nameFocused = true }
    }

    @State private var lastErrorDetached = false

    private func dispatch() {
        lastErrorDetached = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await ingest(Intent.ResolvePlayer(name: trimmed)) }
    }
}
