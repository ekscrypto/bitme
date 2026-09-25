import BitMeCore
import Foundation

// bitme-cli — headless driver for the Bit-Me core state machine. Same
// machine, adapters, and ViewRep stream the iOS app consumes; no UI, so
// flows can be exercised and observed from a terminal.
//
//   bitme-cli resolve <name>        resolve a character, print outcome, exit
//   bitme-cli watch <name>          stream session ViewReps (incl. the live
//                                   resource map: window, nearby counts,
//                                   spawn/despawn feed, stream status)
//   bitme-cli watch <name> --json   same, one JSON ViewRep per line

@main
struct BitMeCLI {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0) // line-buffer even when piped
        let args = Array(CommandLine.arguments.dropFirst())
        let json = args.contains("--json")
        let positional = args.filter { $0 != "--json" }

        guard let command = positional.first else {
            print(usage)
            exit(2)
        }

        let machine = StateMachine(adapters: .production())
        let stream = machine.viewRep.values

        switch command {
        case "resolve", "watch":
            guard positional.count >= 2 else {
                print("error: \(command) requires a character name\n\(usage)")
                exit(2)
            }
            let name = positional[1]
            await machine.start()
            // A persisted identity makes the machine jump straight into the
            // OLD character's session — clear it before resolving the name
            // this invocation was asked about.
            await machine.ingest(Intent.SignOut())
            await machine.ingest(Intent.ResolvePlayer(name: name))

            var lastRep: ViewRep?
            for await rep in stream {
                if rep == lastRep { continue }
                lastRep = rep

                switch rep {
                case .onboarding(let onboarding):
                    renderOnboarding(onboarding)
                    if onboarding.error != nil {
                        print("exit: resolve failed")
                        exit(1)
                    }
                case .session(let session):
                    if command == "resolve" {
                        // Wait for the first poll so signed_in is live.
                        guard session.nowMs != nil else { continue }
                        print(json
                            ? encode(rep)
                            : "resolved \(session.username ?? "?") → entity \(session.entityID ?? "?") region \(session.region.map(String.init) ?? "?") signed_in=\(session.signedIn.map(String.init) ?? "unknown")")
                        exit(0)
                    }
                    if lastRep != nil && session.nowMs != nil {
                        renderSession(session, json: json)
                    }
                }

                if Task.isCancelled { break }
            }
        default:
            print("error: unknown command “\(command)”\n\(usage)")
            exit(2)
        }
    }

    static var usage: String {
        """
        usage:
          bitme-cli resolve <name>      resolve a character, print outcome, exit
          bitme-cli watch <name> [--json]
                                        resolve, then stream session ViewReps
        """
    }

    static func renderOnboarding(_ onboarding: ViewRep.Onboarding) {
        if onboarding.isResolving, let name = onboarding.lookingUpName {
            print("looking up “\(name)”…")
        } else if let error = onboarding.error {
            print("error: \(error)")
        }
    }

    static func renderSession(_ s: ViewRep.Session, json: Bool) {
        guard !json else {
            print(encode(.session(s)))
            return
        }
        var lines: [String] = []
        lines.append("── \(s.username ?? "?") · region \(s.region.map(String.init) ?? "?") · \(s.connection.rawValue.uppercased())\(s.signedIn == false ? " · OFFLINE" : "") ──")
        if let claim = s.claimName { lines.append("claim: \(claim)") }
        if let citric = s.citric {
            let remaining = max(0, Int((citric.expiresAtMs - (s.nowMs ?? 0)) / 1_000))
            lines.append("🍯 CITRIC \(citric.name) — \(format(seconds: remaining)) left (\(citric.isNewlySpawned ? "NEW" : "active"))")
        }
        if let bush = s.bush {
            var line = "bush: \(bush.name)"
            if let depletes = bush.depletesAtMs, let now = s.nowMs {
                line += " — \(format(seconds: Int(max(0, depletes - now) / 1_000))) to depletion"
            } else if let pct = bush.harvestedPct {
                line += String(format: " — %.0f%% harvested (waiting for pacing)", pct * 100)
            }
            if let window = bush.windowEndsAtMs, let now = s.nowMs {
                line += String(format: " (window %ds)", Int(max(0, window - now) / 1_000))
            }
            lines.append(line)
        } else {
            lines.append("bush: none targeted")
        }
        if let stamina = s.stamina {
            let full: String? = stamina.fullAtMs.flatMap { fullAt in
                s.nowMs.map { now in format(seconds: Int(max(0, now - fullAt) / 1_000)) }
            }
            lines.append(String(format: "stamina: %.0f/%.0f (%.0f%%)%@", stamina.projected, stamina.max, stamina.pct * 100,
                                full.map { " — full in \($0)" } ?? (stamina.pct >= 1 ? " — full" : "")))
        }
        if s.food.configured {
            if s.food.active, let expires = s.food.expiresAtSec {
                let nowSec = Int64((s.nowMs ?? 0) / 1_000)
                lines.append("food: ACTIVE — \(format(seconds: Int(max(0, expires - nowSec)))) left")
            } else {
                lines.append("food: none — eat before the citric phase")
            }
        } else {
            lines.append("food: gamedata pending (\(s.food.liveBuffs.count) live buffs)")
        }
        let map = s.resourceMap
        if map.region != nil || map.stream != .off {
            var line = "map: "
            if let region = map.region, let width = map.width,
               let ox = map.originTileX, let oz = map.originTileZ {
                line += "region \(region) · \(width)×\(width) @ (\(ox),\(oz)) · \(map.populatedTiles) resource tiles"
            } else {
                line += "waiting for window"
            }
            line += " · stream \(map.stream.rawValue.uppercased())"
            lines.append(line)
        }
        if !map.nearby.isEmpty {
            let counts = map.nearby.prefix(6).map { entry in
                "\(entry.name ?? entry.resourceID.map(String.init) ?? "?") ×\(entry.count)"
            }
            lines.append("nearby: " + counts.joined(separator: " · "))
        }
        for event in map.feed.prefix(4) {
            let name = event.name ?? event.resourceID.map(String.init) ?? "?"
            let age = s.nowMs.map { now in max(0, Int((now - event.atMs) / 1_000)) }
            lines.append("feed: \(event.spawned ? "+" : "-")\(name) @ (\(event.tileX),\(event.tileZ))\(age.map { " · \($0)s ago" } ?? "")")
        }
        print(lines.joined(separator: "\n"))
    }

    static func format(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func encode(_ rep: ViewRep) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rep), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
