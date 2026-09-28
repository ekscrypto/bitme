import SwiftUI

/// The neutral first screen: shown while the machine's bootstrap restores
/// persisted state and decides the real root — email entry when no account
/// is linked, the pre-sign-in gate (in its resuming state) when a persisted
/// account resumes. Presentation only: no actions, nothing focusable —
/// every path off this screen is machine-driven.
struct StartupView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("BitMe Pocket Crafter")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 24)

            ProgressView()

            Spacer()
            Spacer()
        }
        .background(Color(white: 0.05))
        .preferredColorScheme(.dark)
    }
}
