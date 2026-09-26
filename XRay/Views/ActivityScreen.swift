import SwiftUI
import BitMeCore

/// The glanceable activity dashboard, presented over the map from
/// `MapScreen`: renders `ViewRep.Session` and interpolates countdowns
/// locally between machine publications (4 Hz ticks, 1 Hz polls). X-Ray
/// resolves characters by name only — there is no BitCraft account entry
/// here ("Switch character" is the way back to onboarding).
struct ActivityScreen: View {
    let machine: StateMachine
    let ingest: @Sendable (Sendable) async -> Void

    /// The latest session rep, subscribed from the machine so the dashboard
    /// stays anchored to fresh polls while the cover is up.
    @State private var session: ViewRep.Session?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let session {
                dashboard(session)
            } else {
                Color(white: 0.05).ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            for await viewRep in machine.viewRep.values {
                switch viewRep {
                case .session(let next):
                    session = next
                case .onboarding, .bitCraftSignIn:
                    // e.g. "Switch character" dispatched below — hand the
                    // screen back to the root (onboarding) immediately.
                    session = nil
                    dismiss()
                }
            }
        }
    }

    private func dashboard(_ session: ViewRep.Session) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = Date().timeIntervalSince1970 * 1_000 + relayOffsetMs
            ZStack {
                Color(white: 0.05).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        header(session)
                        switch session.connection {
                        case .down: ReconnectingBanner()
                        case .degraded: DegradedBanner()
                        case .ok: EmptyView()
                        }
                        CitricBanner(alert: session.citric, nowMs: now)
                        if session.signedIn == false {
                            OfflineBanner()
                        }
                        bushCard(nowMs: now)
                        staminaCard
                        foodCard
                        nearbyCard(nowMs: now)
                    }
                    .padding()
                }
            }
        }
    }

    /// Converts device time to relay-clock ms (snapshot anchors are relay ms).
    private var relayOffsetMs: Double {
        session?.nowMs.map { now in now - Date().timeIntervalSince1970 * 1_000 } ?? 0
    }

    // MARK: - Header

    private func header(_ session: ViewRep.Session) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityLabel("Close dashboard")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.username ?? "—")
                    .font(.headline)
                HStack(spacing: 6) {
                    if let region = session.region {
                        Text("Region \(region)")
                    }
                    if let claim = session.claimName {
                        Text("· \(claim)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            characterMenu
            ConnectionPill(connection: session.connection)
        }
    }

    /// Character control. "Switch character" forgets the resolved character
    /// and stops the session — the only account surface X-Ray has.
    private var characterMenu: some View {
        Menu {
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

    // MARK: - Bush countdown

    private func bushCard(nowMs: Double) -> some View {
        VStack(spacing: 8) {
            if let bush = session?.bush {
                Text(bush.name)
                    .font(.title3)
                    .lineLimit(1)

                let timeLeft = [bush.depletesAtMs, bush.windowEndsAtMs]
                    .compactMap { $0 }
                    .map { $0 - nowMs }
                    .min()

                if let timeLeft, timeLeft > 0 {
                    Text(Format.mmss(timeLeft))
                        .font(.system(size: 96, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("until depleted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let pct = bush.harvestedPct {
                    // Health known but pacing not learned yet — percentage only.
                    Gauge(value: pct) {
                        Text("depleted")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .font(.system(size: 64))
                    Text("\(Int((pct * 100).rounded()))% harvested")
                        .font(.title3.monospacedDigit())
                } else {
                    Text("Waiting for health data…")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No resource targeted")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Stamina

    private var staminaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Stamina", systemImage: "bolt")
                    .font(.subheadline.bold())
                Spacer()
                if let stamina = session?.stamina {
                    Text("\(Int(stamina.projected.rounded())) / \(Int(stamina.max.rounded()))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let stamina = session?.stamina {
                ProgressView(value: stamina.pct)
                    .tint(stamina.pct < 0.15 ? .red : .yellow)
                HStack {
                    if let fullAtMs = stamina.fullAtMs {
                        Text("Full at \(Format.clockTime(fullAtMs))")
                    } else if stamina.pct >= 1 {
                        Text("Full — ready to harvest")
                    } else {
                        Text("No regen anchor yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No stamina data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Food

    private var foodCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Food buff", systemImage: "fork.knife")
                .font(.subheadline.bold())

            let relayNowSec = Int64((Date().timeIntervalSince1970 * 1_000 + relayOffsetMs) / 1_000)

            if let food = session?.food, food.configured {
                if food.active, let expiresAtSec = food.expiresAtSec {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Active — \(Format.mmss(Double(expiresAtSec - relayNowSec) * 1_000)) left")
                            .font(.title3.monospacedDigit())
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text("No food buff — eat before the citric phase")
                            .font(.subheadline)
                    }
                }
            } else {
                Label("Food tracking pending gamedata — live buffs below",
                      systemImage: "clock.badge.questionmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let buffs = session?.food.liveBuffs, !buffs.isEmpty {
                ForEach(buffs, id: \.id) { buff in
                    let remainingMs = Double(buff.expiresAtSec - relayNowSec) * 1_000
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(buff.name ?? "buff #\(buff.id)") — \(Format.mmss(max(0, remainingMs))) left")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ForEach(buff.stats, id: \.self) { stat in
                            Text("\(stat.label) \(stat.displayValue)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("No live buffs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
    }
    // MARK: - Nearby resources (live resource map)

    /// Compact rendering of the live resource map: nearby counts from the
    /// player-anchored window plus the spawn/despawn feed from the change
    /// stream (relay §6–7 endpoints, integrated in the core).
    @ViewBuilder
    private func nearbyCard(nowMs: Double) -> some View {
        if let map = session?.resourceMap,
           map.stream != .off || !map.nearby.isEmpty || !map.feed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Nearby resources", systemImage: "map")
                        .font(.subheadline.bold())
                    Spacer()
                    StreamPill(status: map.stream)
                }

                if map.nearby.isEmpty {
                    Text("Loading the resource window…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(map.nearby.prefix(6).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(resourceID: entry.resourceID ?? 0))
                                .frame(width: 8, height: 8)
                            Text(entry.name ?? "resource")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("×\(entry.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !map.feed.isEmpty {
                    Rectangle()
                        .fill(Color(white: 0.25))
                        .frame(height: 1)
                    ForEach(Array(map.feed.prefix(3).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 6) {
                            Image(systemName: event.spawned ? "plus.circle.fill" : "minus.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(event.spawned ? .green : .red)
                            Text(event.name ?? "resource")
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Format.ago(nowMs - event.atMs)) · (\(event.tileX), \(event.tileZ))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - Stream pill

/// Live change-stream state, mirroring the CLI/ViewRep status.
private struct StreamPill: View {
    let status: ViewRep.Session.ResourceMap.StreamStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2).bold()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.25), in: Capsule())
        .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .off: "MAP OFF"
        case .connecting: "MAP…"
        case .live: "LIVE MAP"
        case .reconnecting: "RECONNECTING"
        }
    }

    private var color: Color {
        switch status {
        case .off: .gray
        case .connecting: .orange
        case .live: .cyan
        case .reconnecting: .orange
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

private struct ReconnectingBanner: View {
    var body: some View {
        Label("Player not present in any mirrored region — the mirror may be reseeding. Countdowns below may be stale.",
              systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DegradedBanner: View {
    var body: some View {
        Label("Relay unreachable — retrying. Showing last known state.",
              systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
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

/// Full attention when a Citric bush is up: the 30-second rare window.
private struct CitricBanner: View {
    let alert: ViewRep.Session.Citric?
    let nowMs: Double

    var body: some View {
        if let alert {
            let remaining = max(0, alert.expiresAtMs - nowMs)
            let hot = alert.isNewlySpawned || (nowMs - alert.spawnedAtMs) < 10_000
            VStack(spacing: 4) {
                Label(hot ? "CITRIC BUSH UP!" : "Citric bush active",
                      systemImage: "sparkles")
                    .font(.title2).bold()
                Text("\(Format.mmss(remaining)) left")
                    .font(.title3.monospacedDigit())
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(hot ? Color.red : Color.purple, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
        }
    }
}

extension Color {
    /// Stable distinct hue per resource id — golden-angle spacing of the id,
    /// matching the reference web map's resource palette (dark variant).
    init(resourceID: Int) {
        let hue = abs(Double(resourceID) * 137.508).truncatingRemainder(dividingBy: 360)
        self.init(hue: hue / 360, saturation: 0.72, brightness: 0.62)
    }
}
