import SwiftUI
import BitMeCore

/// Pocket Crafter home: renders `CrafterRep.Session` for the tracked character
/// — the claim they stand in, the account surface, and two icon-only tabs:
/// **Crafting** (stations, the running craft, craft tasks) and **Storage**
/// (storage buildings and the rest). The workstation lists render the
/// dedicated `WorkstationsRep` channel (published only when the buildings
/// state moves), so poll-driven session updates never re-diff them. A busy
/// claim carries hundreds of buildings and crafts, so each tab's volume
/// lives in a `List` (recycled rows); the countdown's periodic timeline is
/// scoped to the running-craft card so its 4 Hz re-eval never touches the
/// long lists.
struct CrafterHomeView: View {
    let session: CrafterRep.Session
    let workstations: WorkstationsRep
    let ingest: @Sendable (Sendable) async -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView {
                CraftingTab(session: session, workstations: workstations)
                    .tabItem { Image(systemName: "hammer") }
                    .accessibilityLabel("Crafting")
                StorageTab(session: session, workstations: workstations)
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

    private var runningCraft: RunningAction? {
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

/// Crafting stations and craft tasks, regrouped under collapsible
/// profession headers (the workstation families of the catalog: Carpentry,
/// …, Tailoring; everything else — Cooking, workbenches, taming — under
/// "Other"). A station's crafts nest under the station row itself (tap to
/// expand): the player's own crafts, plus **shared** bench crafts other
/// players opened to the claim (marked with a two-figure icon — anyone
/// may contribute effort, exactly like at the station in game). Other
/// players' private work — abandoned bench sessions included — renders
/// nowhere; the game shows it to nobody.
/// Own crafts at stations outside the claim (no station row to nest
/// under) list at the bottom of their recipe's profession group.
private struct CraftingTab: View {
    let session: CrafterRep.Session
    let workstations: WorkstationsRep

    /// Collapsed by default — a busy claim carries many stations, and the
    /// running-craft card already surfaces the active work on top.
    @State private var expanded: Set<Profession> = []
    /// Stations whose nested craft list is revealed (by building id).
    @State private var expandedStations: Set<String> = []

    private struct ProfessionGroup {
        let profession: Profession
        let stations: [WorkstationsRep.Building]
        /// Own crafts at claim stations, keyed by the station's building id
        /// — what expanding a station row reveals.
        let craftsByStation: [String: [WorkstationsRep.Craft]]
        /// Own crafts at stations outside the claim — no station row to
        /// nest under, so they list at the group's bottom.
        let awayCrafts: [WorkstationsRep.Craft]
    }

    /// The professions that have something to show, in `Profession.allCases`
    /// order (the named twelve, then Other).
    private var groups: [ProfessionGroup] {
        let crafting = workstations.buildings.filter(\.isCrafting)
        let craftsByStation = Dictionary(grouping: workstations.crafts, by: \.buildingEntityID)
        let stationIDs = Set(crafting.map(\.entityID))
        return Profession.allCases.compactMap { profession in
            let stations = crafting.filter { ($0.profession ?? .other) == profession }
            let nested = stations.reduce(into: [WorkstationsRep.Craft]()) { $0 += craftsByStation[$1.entityID] ?? [] }
            let away = workstations.crafts.filter {
                !stationIDs.contains($0.buildingEntityID) && ($0.profession ?? .other) == profession
            }
            return stations.isEmpty && nested.isEmpty && away.isEmpty
                ? nil
                : ProfessionGroup(
                    profession: profession, stations: stations,
                    craftsByStation: craftsByStation, awayCrafts: away
                )
        }
    }

    var body: some View {
        let stations = workstations
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
                ForEach(groups, id: \.profession) { group in
                    DisclosureGroup(isExpanded: isExpanded(group.profession)) {
                        ForEach(group.stations, id: \.entityID) { building in
                            StationRow(
                                building: building,
                                hasCrafts: !(group.craftsByStation[building.entityID] ?? []).isEmpty,
                                expanded: expandedStations.contains(building.entityID),
                                toggle: { toggleStation(building.entityID) }
                            )
                            if expandedStations.contains(building.entityID) {
                                ForEach(group.craftsByStation[building.entityID] ?? [], id: \.entityID) { craft in
                                    CraftRow(craft: craft)
                                        .padding(.leading, 24)
                                }
                            }
                        }
                        ForEach(group.awayCrafts, id: \.entityID) { craft in
                            CraftRow(craft: craft)
                        }
                        if group.profession == .other && stations.craftsOverflow > 0 {
                            Text("+\(stations.craftsOverflow) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        groupHeader(group)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
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

    private func isExpanded(_ profession: Profession) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(profession) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(profession)
                } else {
                    expanded.remove(profession)
                }
            }
        )
    }

    private func toggleStation(_ entityID: String) {
        if expandedStations.contains(entityID) {
            expandedStations.remove(entityID)
        } else {
            expandedStations.insert(entityID)
        }
    }

    /// The collapsible header: profession icon, name, and what's inside.
    private func groupHeader(_ group: ProfessionGroup) -> some View {
        HStack {
            ProfessionIcon(profession: group.profession)
                .frame(width: 22, height: 22)
            Text(group.profession.displayName)
                .font(.subheadline.bold())
            Spacer()
            Text(countLabel(group))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func countLabel(_ group: ProfessionGroup) -> String {
        let crafts = group.stations.reduce(0) { $0 + (group.craftsByStation[$1.entityID]?.count ?? 0) }
            + group.awayCrafts.count
        var parts: [String] = []
        if !group.stations.isEmpty {
            parts.append("\(group.stations.count) station\(group.stations.count == 1 ? "" : "s")")
        }
        if crafts > 0 {
            parts.append("\(crafts) craft\(crafts == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
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
}

// MARK: - Storage tab

/// Storage buildings on the claim, with everything else below them.
private struct StorageTab: View {
    let session: CrafterRep.Session
    let workstations: WorkstationsRep

    var body: some View {
        let stations = workstations
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
        _ title: String, icon: String, buildings: [WorkstationsRep.Building]
    ) -> some View {
        Section {
            ForEach(buildings, id: \.entityID) { building in
                StorageBuildingRow(building: building)
            }
        } header: {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rows

/// A profession's header icon. Prefers the game's own skill icon from the
/// asset catalog (`tools/asset-extraction/install_app_icons.sh` copies the
/// twelve in from the private bitme-resources checkout; Scholar borrows the
/// game UI's Book icon — the game ships no skill icon for it). When the
/// catalog is absent — a public-only clone — SF Symbols stand in so the
/// design never renders an empty slot.
private struct ProfessionIcon: View {
    let profession: Profession

    var body: some View {
        if let gameIcon, let uiImage = UIImage(named: gameIcon) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
        }
    }

    /// The asset-catalog name, when the game set has one for the profession.
    private var gameIcon: String? {
        switch profession {
        case .carpentry: "SkillIconCarpentry"
        case .farming: "SkillIconFarming"
        case .fishing: "SkillIconFishing"
        case .foraging: "SkillIconForaging"
        case .forestry: "SkillIconForestry"
        case .hunting: "SkillIconHunting"
        case .leatherworking: "SkillIconLeatherworking"
        case .masonry: "SkillIconMasonry"
        case .mining: "SkillIconMining"
        case .smithing: "SkillIconSmithing"
        case .tailoring: "SkillIconTailoring"
        case .scholar: "SkillIconScholar"
        case .other: nil
        }
    }

    /// The SF Symbol fallback (also the permanent art for Other).
    private var symbol: String {
        switch profession {
        case .carpentry: "square.and.pencil"
        case .farming: "leaf"
        case .fishing: "fish"
        case .foraging: "carrot"
        case .forestry: "tree"
        case .hunting: "scope"
        case .leatherworking: "handbag"
        case .masonry: "wallpaper"
        case .mining: "mountain.2"
        case .smithing: "hammer"
        case .tailoring: "scissors"
        case .scholar: "book"
        case .other: "ellipsis"
        }
    }
}

/// One storage building (Storage tab): display name over catalog subtitle.
/// No craft pill — craft rows live in the Crafting tab.
private struct StorageBuildingRow: View {
    let building: WorkstationsRep.Building

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
        }
        .padding(.vertical, 2)
    }
}

/// One workstation: display name (nickname over catalog), catalog
/// subtitle, the player's own pending-craft count pill, and a chevron
/// when there are rows to expand (own crafts plus shared crafts other
/// players opened). Others' private work never surfaces — the game shows
/// it to nobody, so neither do we.
private struct StationRow: View {
    let building: WorkstationsRep.Building
    let hasCrafts: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
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
                if building.myCraftCount > 0 {
                    Text("\(building.myCraftCount)")
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
                if hasCrafts {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One rendered craft task: recipe, station, ownership mark, and phase
/// chip. Own crafts lead with a filled figure; a shared craft another
/// player opened (anyone may contribute effort) with an outlined one.
private struct CraftRow: View {
    let craft: WorkstationsRep.Craft

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: craft.mine ? "person.fill" : "person.2")
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
    let status: WorkstationsRep.Status
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
    let action: RunningAction?
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
    let connection: SessionConnection

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
    let status: CrafterRep.Session.GameSession.Status

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
    let craft: WorkstationsRep.Craft

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
            // Bench-craft progress is cumulative effort over the effort
            // goal (`itemCount × recipe.actions_required`) — the same
            // fraction the game's bar shows.
            if let progress = craft.progress, let total = craft.progressTotal, total > 0 {
                "\(min(progress, total))/\(total)"
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
