import SwiftUI
import BitMeCore

/// Pocket Crafter home: renders `ViewRep.Session` for the tracked character
/// — the claim they stand in, the account surface, and the craft currently
/// running. The workstation list (public + personal tasks per station, with
/// resume) is a placeholder until its data source lands; everything shown
/// today is real relay data.
struct CrafterHomeView: View {
    let session: ViewRep.Session
    let ingest: @Sendable (Sendable) async -> Void

    /// Converts device time to relay-clock ms (snapshot anchors are relay ms).
    private var relayOffsetMs: Double {
        session.nowMs.map { now in now - Date().timeIntervalSince1970 * 1_000 } ?? 0
    }

    private var runningCraft: ViewRep.Session.RunningAction? {
        session.actions.first { $0.actionType == "Craft" }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let nowMs = Date().timeIntervalSince1970 * 1_000 + relayOffsetMs
            ZStack {
                Color(white: 0.05).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        if session.signedIn == false {
                            OfflineBanner()
                        }
                        craftCard(nowMs: nowMs)
                        workstationsPlaceholder
                    }
                    .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.claimName ?? session.username ?? "—")
                    .font(.headline)
                HStack(spacing: 6) {
                    if let username = session.username, session.claimName != nil {
                        Text(username)
                    }
                    if let region = session.region {
                        Text("· Region \(region)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            accountMenu
            ConnectionPill(connection: session.connection)
        }
    }

    /// Account + character controls. The BitCraft entry opens the emailed-
    /// code sign-in screen (signed in or not — a second sign-in switches
    /// accounts); "Switch character" forgets the resolved character and
    /// stops the session.
    private var accountMenu: some View {
        Menu {
            if let email = session.bitCraftAccountEmail {
                Button {
                    Task { await ingest(Intent.ShowBitCraftSignIn()) }
                } label: {
                    Label("BitCraft account: \(email)", systemImage: "person.crop.circle")
                }
            } else {
                Button {
                    Task { await ingest(Intent.ShowBitCraftSignIn()) }
                } label: {
                    Label("Sign in with BitCraft", systemImage: "person.crop.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                Task { await ingest(Intent.SignOut()) }
            } label: {
                Label("Switch character", systemImage: "arrow.uturn.backward")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.bold())
                .padding(8)
                .background(Color(white: 0.18), in: Circle())
        }
        .accessibilityLabel("Account and settings")
    }

    // MARK: - Running craft (real data)

    /// The character's in-flight Craft action, when there is one: the
    /// station being worked (the snapshot target while crafting) and a live
    /// progress bar anchored to relay clock.
    @ViewBuilder
    private func craftCard(nowMs: Double) -> some View {
        if let craft = runningCraft {
            let remaining = craft.endsAtMs - nowMs
            let progress = craft.durationMs > 0
                ? min(1, max(0, (nowMs - craft.startsAtMs) / craft.durationMs))
                : 1
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Crafting", systemImage: "hammer")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(remaining > 0 ? "\(Format.mmss(remaining)) left" : "finishing…")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(craft.targetName ?? "at a workstation")
                    .font(.title3)
                    .lineLimit(1)
                ProgressView(value: progress)
                    .tint(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Workstations (placeholder)

    /// The product's centerpiece — every workstation in the claim with its
    /// public queue and the player's personal tasks — is waiting on a data
    /// source (relay endpoints or the direct SpacetimeDB connection). The
    /// seam is ready: this becomes a list once the Core grows the domain.
    private var workstationsPlaceholder: some View {
        VStack(spacing: 10) {
            ContentUnavailableView {
                Label("Workstations", systemImage: "wrench.and.screwdriver")
            } description: {
                Text("Every workstation in \(session.claimName ?? "your claim"), with public queues and your personal tasks, arrives here once the crafting data source is wired up.")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Banners & pills

private struct ConnectionPill: View {
    let connection: ViewRep.Session.Connection

    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch connection {
        case .ok: "LIVE"
        case .degraded: "RETRYING"
        case .down: "RECONNECTING"
        }
    }

    private var color: Color {
        switch connection {
        case .ok: .green
        case .degraded: .orange
        case .down: .red
        }
    }
}

private struct OfflineBanner: View {
    var body: some View {
        Label("Character offline — indicators are from their last session.",
              systemImage: "moon.zzz")
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}
