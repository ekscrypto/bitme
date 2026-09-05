import SwiftUI
import BitMeCore

/// The glanceable activity screen: renders `ViewRep.Session` and interpolates
/// countdowns locally between machine publications (4 Hz ticks, 1 Hz polls).
struct ActivityScreen: View {
    let session: ViewRep.Session
    let ingest: @Sendable (Sendable) async -> Void

    /// Converts device time to relay-clock ms (snapshot anchors are relay ms).
    private var relayOffsetMs: Double {
        session.nowMs.map { now in now - Date().timeIntervalSince1970 * 1_000 } ?? 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = Date().timeIntervalSince1970 * 1_000 + relayOffsetMs
            ZStack {
                Color(white: 0.05).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        header
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
                    }
                    .padding()
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
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
            ConnectionPill(connection: session.connection)
        }
    }

    // MARK: - Bush countdown

    private func bushCard(nowMs: Double) -> some View {
        VStack(spacing: 8) {
            if let bush = session.bush {
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
                if let stamina = session.stamina {
                    Text("\(Int(stamina.projected.rounded())) / \(Int(stamina.max.rounded()))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let stamina = session.stamina {
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

            if !session.food.configured {
                Label("Food tracking pending gamedata — live buffs below",
                      systemImage: "clock.badge.questionmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if session.food.active, let expiresAtSec = session.food.expiresAtSec {
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

            if session.food.liveBuffs.isEmpty {
                Text("No live buffs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.food.liveBuffs, id: \.id) { buff in
                    let remainingMs = Double(buff.expiresAtSec - relayNowSec) * 1_000
                    Text("buff #\(buff.id) — \(Format.mmss(max(0, remainingMs))) left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
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
