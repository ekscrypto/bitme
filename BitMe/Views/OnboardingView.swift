import SwiftUI

/// Character-name onboarding (tutorial 1). Button-driven resolve — no call
/// per keystroke, so the relay's exact-match endpoint is never fanned out.
struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Text("Bit-Me")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                Text("Live guidance for timed world resources")
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
                    .disabled(appModel.isResolving)
                    .onSubmit { Task { await appModel.resolve(name) } }
                    .onChange(of: name) { _, _ in
                        // A fresh edit invalidates the previous attempt's result.
                        appModel.resolveErrorText = nil
                    }

                if appModel.isResolving {
                    Label("Looking up “\(name)”…", systemImage: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let error = appModel.resolveErrorText {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("resolve-error")
                }
            }
            .padding(.horizontal, 32)

            Button {
                Task { await appModel.resolve(name) }
            } label: {
                Group {
                    if appModel.isResolving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue").bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || appModel.isResolving)
            .padding(.horizontal, 32)

            if appModel.resolvedOffline {
                Text("That character is offline right now — you can still set up and connect later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            Spacer()
        }
        .background(Color(white: 0.05))
        .preferredColorScheme(.dark)
        .onAppear { nameFocused = true }
    }
}
