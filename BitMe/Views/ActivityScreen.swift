import SwiftUI

/// The glanceable activity screen: big bush countdown, citric alert,
/// stamina projection, food-buff watch. Rendering runs at 4 Hz locally via
/// `TimelineView`, re-anchored every 1 Hz poll.
struct ActivityScreen: View {
    @Environment(AppModel.self) private var appModel

    @State private var monitor: SessionMonitor
    private let config = GameConfig.shared

    init(identity: StoredIdentity) {
        _monitor = State(initialValue: SessionMonitor(
            client: RelayClient.production,
            entityID: identity.entityID
        ))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = monitor.nowRelayMs
            ZStack {
                Color(white: 0.05).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        switch monitor.connection {
                        case .down: ReconnectingBanner()
                        case .degraded: DegradedBanner()
                        case .ok: EmptyView()
                        }
                        if let snapshot = monitor.snapshot {
                            CitricBanner(
                                alert: HarvestStateEngine.detectCitric(
                                    previous: monitor.previous,
                                    current: snapshot,
                                    citricResourceIDs: config.citricResourceIDs,
                                    fallbackWindowMs: config.citricFallbackWindowMs,
                                    nowMs: now
                                ),
                                now: now,
                                hotWindowMs: config.citricHotWindowMs
                            )
                            if snapshot.signedIn == false {
                                OfflineBanner()
                            }
                            BushCountdownCard(
                                snapshot: snapshot,
                                msPerHealthPoint: monitor.pacingMsPerHealthPoint,
                                now: now
                            )
                            StaminaCard(
                                projection: HarvestStateEngine.staminaProjection(
                                    in: snapshot, rules: config.regen, nowMs: now
                                )
                            )
                            FoodCard(
                                state: HarvestStateEngine.foodBuffState(
                                    in: snapshot,
                                    foodBuffIDs: monitor.foodBuffGamedata?.foodBuffIDs ?? [],
                                    nowMs: now
                                ),
                                rawBuffs: snapshot.buffs,
                                foodTrackingConfigured: monitor.foodBuffGamedata != nil,
                                now: now
                            )
                        } else {
                            Spacer()
                            Text(monitor.connection == .down
                                 ? "Reconnecting…"
                                 : "Connecting to relay…")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .padding()
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.identity?.username ?? monitor.snapshot?.username ?? "—")
                    .font(.headline)
                HStack(spacing: 6) {
                    if let region = monitor.snapshot?.region {
                        Text("Region \(region)")
                    }
                    if let claim = monitor.snapshot?.claim {
                        Text("· \(claim.name)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ConnectionPill(connection: monitor.connection)
        }
    }
}

// MARK: - Banners & pills

private struct ConnectionPill: View {
    let connection: SessionMonitor.Connection

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
    let alert: HarvestStateEngine.CitricAlert?
    let now: Double
    let hotWindowMs: Double

    var body: some View {
        if let alert {
            let remaining = max(0, alert.remainingMs(nowMs: now))
            let hot = alert.isNewlySpawned || (now - alert.spawnedAtMs) < hotWindowMs
            VStack(spacing: 4) {
                Label(hot ? "CITRIC BUSH UP!" : "Citric bush active",
                      systemImage: "sparkles")
                    .font(.title2).bold()
                Text("\(Format.mmss(remaining)) left")
                    .font(.title3.monospacedDigit())
                if let location = alert.location {
                    Text("at tile \(location.tileX), \(location.tileZ)")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(hot ? Color.red : Color.purple, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Cards

/// The big countdown: time left on the resource being harvested.
private struct BushCountdownCard: View {
    let snapshot: SessionSnapshot
    let msPerHealthPoint: Double?
    let now: Double

    var body: some View {
        VStack(spacing: 8) {
            if let target = snapshot.target, target.resourceID != nil {
                Text(target.name ?? "Unknown resource")
                    .font(.title3)
                    .lineLimit(1)

                let pct = depletionPct(target)
                let timeLeft = HarvestStateEngine.depletionCountdownMs(
                    target: target, msPerHealthPoint: msPerHealthPoint
                ) ?? HarvestStateEngine.spawnWindowRemainingMs(
                    in: snapshot,
                    resourceID: target.resourceID ?? -1,
                    nowMs: now
                )

                if let timeLeft, timeLeft > 0 {
                    Text(Format.mmss(timeLeft))
                        .font(.system(size: 96, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("until depleted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let pct {
                    // Health known but pacing not learned yet — show the
                    // percentage ring (tutorial 2, §2).
                    Gauge(value: pct) {
                        Text("depleted")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .font(.system(size: 64))
                    Text("\(Int((pct * 100).rounded()))% harvested")
                        .font(.title3.monospacedDigit())
                } else {
                    Text(target.health == nil ? "Waiting for health data…" : "—")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

                if let health = target.health, let maxHealth = target.maxHealth, maxHealth > 0 {
                    ProgressView(value: 1 - health / maxHealth)
                        .tint(.green)
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

    private func depletionPct(_ target: Target) -> Double? {
        guard let health = target.health, let maxHealth = target.maxHealth, maxHealth > 0 else {
            return nil
        }
        return HarvestStateEngine.clamp01(1 - health / maxHealth)
    }
}

/// Stamina bar + "full at T" projection.
private struct StaminaCard: View {
    let projection: HarvestStateEngine.StaminaProjection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Stamina", systemImage: "bolt")
                    .font(.subheadline.bold())
                Spacer()
                if let projection {
                    Text("\(Int(projection.projected.rounded())) / \(Int(projection.max.rounded()))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let projection {
                ProgressView(value: projection.pct)
                    .tint(projection.pct < 0.15 ? .red : .yellow)
                HStack {
                    if let fullAtMs = projection.fullAtMs {
                        Text("Full at \(Format.clockTime(fullAtMs))")
                    } else if projection.pct >= 1 {
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
}

/// Food-buff watch. Buff ids are classified via gamedata fetched from the
/// relay mirror (`GamedataService`, 48 h cache); until it loads the card
/// stays neutral. Expired-but-lingering rows are filtered and the list
/// capped — only live buffs count, latest expiry first.
private struct FoodCard: View {
    let state: HarvestStateEngine.FoodBuffState
    let rawBuffs: [Buff]
    let foodTrackingConfigured: Bool
    let now: Double

    private static let maxVisible = 4

    private var liveBuffs: [Buff] {
        rawBuffs
            .filter { Double($0.expiresAtUnixSec) * 1_000 > now }
            .sorted { $0.expiresAtUnixSec > $1.expiresAtUnixSec }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Food buff", systemImage: "fork.knife")
                .font(.subheadline.bold())

            if !foodTrackingConfigured {
                // Food buff ids not bundled yet — can't classify, so stay
                // neutral instead of crying wolf.
                Label("Food tracking pending gamedata — live buffs below",
                      systemImage: "clock.badge.questionmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if state.active, let remaining = state.remainingMs {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Active — \(Format.mmss(remaining)) left")
                        .font(.title3.monospacedDigit())
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("No food buff — eat before the citric phase")
                        .font(.subheadline)
                }
            }

            let live = liveBuffs
            if live.isEmpty {
                Text("No live buffs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(live.prefix(Self.maxVisible), id: \.buffID) { buff in
                    let remainingMs = Double(buff.expiresAtUnixSec) * 1_000 - now
                    Text("buff #\(buff.buffID) — \(Format.mmss(remainingMs)) left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if live.count > Self.maxVisible {
                    Text("+\(live.count - Self.maxVisible) more live buffs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Formatting

enum Format {
    /// "2:05" for 125_000 ms; ceiling so a countdown never shows 0:00 early.
    static func mmss(_ ms: Double) -> String {
        let totalSeconds = max(0, Int((ms / 1_000).rounded(.up)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// Relay-clock ms → local-formatted wall clock ("17:32").
    static func clockTime(_ relayMs: Double) -> String {
        let date = Date(timeIntervalSince1970: relayMs / 1_000)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
