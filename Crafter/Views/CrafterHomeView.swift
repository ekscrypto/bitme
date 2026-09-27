import SwiftUI
import BitMeCore

/// Pocket Crafter home: renders `ViewRep.Session` for the tracked character
/// — the claim they stand in, the account surface, and two icon-only tabs:
/// **Crafting** (stations, the running craft, craft tasks) and **Storage**
/// (storage buildings and the rest). A busy claim carries hundreds of
/// buildings and crafts, so each tab's volume lives in a `List` (recycled
/// rows); the countdown's periodic timeline is scoped to the running-craft
/// card so its 4 Hz re-eval never touches the long lists.
struct CrafterHomeView: View {
    let session: ViewRep.Session
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView {
                CraftingTab(session: session)
                    .tabItem { Image(systemName: "hammer") }
                    .accessibilityLabel("Crafting")
                StorageTab(session: session)
                    .tabItem { Image(systemName: "shippingbox") }
                    .accessibilityLabel("Storage")
            }
        }
        .background(Color(white: 0.05).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// Converts device time to relay-clock ms (snapshot anchors are relay ms).
    private var relayOffsetMs: Double {
        session.nowMs.map { now in now - Date().timeIntervalSince1970 * 1_000 } ?? 0
    }

    private var runningCraft: ViewRep.Session.RunningAction? {
        session.actions.first { $0.actionType == "Craft" }
    }

    // MARK: - Header (shared across tabs)

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
            if let game = session.gameSession {
                GameSessionPill(status: game.status)
            }
            ConnectionPill(connection: session.connection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Account controls. "Switch BitCraft account" reopens the emailed-code
    /// screen over the session (cancel returns here); "Sign out" forgets the
    /// account and its player — the app returns to email entry.
    private var accountMenu: some View {
        Menu {
            Button {
                Task { await ingest(Intent.ShowBitCraftSignIn()) }
            } label: {
                Label(
                    session.bitCraftAccountEmail.map { "Switch BitCraft account (\($0))" }
                        ?? "Sign in with BitCraft",
                    systemImage: "person.crop.circle"
                )
            }
            Divider()
            Button(role: .destructive) {
                Task { await ingest(Intent.SignOut()) }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.bold())
                .padding(8)
                .background(Color(white: 0.18), in: Circle())
        }
        .accessibilityLabel("Account and settings")
    }
}

// MARK: - Crafting tab

/// Crafting stations with the crafts running at them: the character's
/// in-flight craft, the claim's stations, and the pending craft tasks.
private struct CraftingTab: View {
    let session: ViewRep.Session
    let home: CrafterHomeView? = nil

    var body: some View {
        let stations = session.workstations
        let crafting = stations.buildings.filter(\.isCrafting)
        List {
            Group {
                if session.signedIn == false {
                    OfflineBanner()
                }
                RunningCraftCard(action: session.actions.first { $0.actionType == "Craft" }, relayOffsetMs: relayOffsetMs)
                SyncStatusRow(status: stations.status, error: stations.error)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            if crafting.isEmpty && stations.crafts.isEmpty && stations.status == .live {
                emptyState(
                    "No crafting stations",
                    "Crafting stations on \(session.claimName ?? "your claim") appear here."
                )
            } else {
                if !crafting.isEmpty {
                    stationSection("Crafting stations", icon: "hammer", buildings: crafting)
                }
                if !stations.crafts.isEmpty || stations.craftsOverflow > 0 {
                    craftTasks(stations)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Converts device time to relay-clock ms (snapshot anchors are relay ms).
    private var relayOffsetMs: Double {
        session.nowMs.map { now in now - Date().timeIntervalSince1970 * 1_000 } ?? 0
    }

    private func emptyState(_ title: String, _ message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "hammer")
        } description: {
            Text(message)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .padding(.vertical, 24)
    }

    private func stationSection(
        _ title: String, icon: String, buildings: [ViewRep.Session.Workstations.Building]
    ) -> some View {
        Section {
            ForEach(buildings, id: \.entityID) { building in
                BuildingRow(building: building)
            }
        } header: {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }

    /// Craft tasks: the player's own pending crafts first, then the claim's.
    private func craftTasks(_ stations: ViewRep.Session.Workstations) -> some View {
        Section {
            ForEach(stations.crafts, id: \.entityID) { craft in
                CraftRow(craft: craft)
            }
            if stations.craftsOverflow > 0 {
                Text("+\(stations.craftsOverflow) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Craft tasks", systemImage: "hourglass")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Storage tab

/// Storage buildings on the claim, with everything else below them.
private struct StorageTab: View {
    let session: ViewRep.Session

    var body: some View {
        let stations = session.workstations
        let storage = stations.buildings.filter { $0.isStorage && !$0.isCrafting }
        let other = stations.buildings.filter { !$0.isCrafting && !$0.isStorage }
        List {
            SyncStatusRow(status: stations.status, error: stations.error)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            if storage.isEmpty && other.isEmpty && stations.status == .live {
                ContentUnavailableView {
                    Label("No storage", systemImage: "shippingbox")
                } description: {
                    Text("Storage buildings on \(session.claimName ?? "your claim") appear here.")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 24)
            } else {
                if !storage.isEmpty {
                    storageSection("Storage", icon: "shippingbox", buildings: storage)
                }
                if !other.isEmpty {
                    storageSection("Other buildings", icon: "house", buildings: other)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func storageSection(
        _ title: String, icon: String, buildings: [ViewRep.Session.Workstations.Building]
    ) -> some View {
        Section {
            ForEach(buildings, id: \.entityID) { building in
                BuildingRow(building: building)
            }
        } header: {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rows

/// One workstation: display name (nickname over catalog), catalog subtitle,
/// and the pending-craft count badge.
private struct BuildingRow: View {
    let building: ViewRep.Session.Workstations.Building

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(building.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if building.name != building.catalogName, let catalog = building.catalogName {
                    Text(catalog)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if building.craftCount > 0 {
                Text("\(building.craftCount)")
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One pending craft task: recipe, station, ownership icon, and phase chip.
private struct CraftRow: View {
    let craft: ViewRep.Session.Workstations.Craft

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: craft.mine ? "person.fill" : "person")
                .font(.caption2)
                .foregroundStyle(craft.mine ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(craft.recipeName ?? "Recipe \(craft.entityID)")
                    .font(.subheadline)
                    .lineLimit(1)
                if let station = craft.stationName {
                    Text(station)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            CraftPhaseBadge(craft: craft)
        }
        .padding(.vertical, 2)
    }
}

/// The claim-buildings sync state — busy while pooling the snapshot, the
/// error otherwise silent rows would hide.
private struct SyncStatusRow: View {
    let status: ViewRep.Session.Workstations.Status
    let error: String?

    var body: some View {
        switch status {
        case .idle, .live:
            EmptyView()
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing claim…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Label(error ?? "Sync stopped", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// The character's in-flight Craft action: the station being worked and a
/// live progress bar. Owns the periodic timeline — the only part of the
/// screen that needs sub-second updates.
private struct RunningCraftCard: View {
    let action: ViewRep.Session.RunningAction?
    let relayOffsetMs: Double

    var body: some View {
        if let craft = action {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let nowMs = Date().timeIntervalSince1970 * 1_000 + relayOffsetMs
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

/// The account's game session — the `sign_in` this app holds on the game's
/// global database. The game allows one live session per account: while
/// this reads "held", the desktop client has been kicked (and vice versa).
private struct GameSessionPill: View {
    let status: ViewRep.Session.GameSession.Status

    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .connecting: "SIGNING IN"
        case .live: "GAME SESSION"
        case .reconnecting: "RETAKING"
        case .rejected: "REFUSED"
        }
    }

    private var color: Color {
        switch status {
        case .connecting: .secondary
        case .live: .indigo
        case .reconnecting: .orange
        case .rejected: .red
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

/// A craft task's state chip: passive crafts carry their queue state,
/// at-the-bench crafts their action progress.
private struct CraftPhaseBadge: View {
    let craft: ViewRep.Session.Workstations.Craft

    var body: some View {
        Text(label)
            .font(.caption2.monospacedDigit().bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.22), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch craft.phase {
        case .queued: "Queued"
        case .processing: "Crafting"
        case .complete: "Done"
        case .preparing: "Preparing"
        case .active:
            if let progress = craft.progress, let count = craft.craftCount, count > 0 {
                "\(min(progress, count))/\(count)"
            } else {
                "Active"
            }
        }
    }

    private var tint: Color {
        switch craft.phase {
        case .queued: .secondary
        case .processing, .preparing, .active: .orange
        case .complete: .green
        }
    }
}
