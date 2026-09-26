import SwiftUI

/// Presentation formatting shared by both apps (moved out of the original
/// combined app's activity screen).
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

    /// Elapsed ms → "now" / "45s ago" / "12m ago".
    static func ago(_ ms: Double) -> String {
        let seconds = max(0, Int(ms / 1_000))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}
