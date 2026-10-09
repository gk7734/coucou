import Foundation

// MARK: - AutoMusicPill
//
// The music pill that shows on its own while music plays (GitHub build, "Show music
// automatically" in Settings): no need to declare it in Active pills, and it doesn't count
// against their limit of 4. It is transient like an agent session's pill: it stays a short
// while once nothing plays anymore (pause, end of the queue, the app quits), then leaves.
// A pill the user declared is never removed by it.
//
// Foundation only, so the decisions are tested on their own (tests/AutoMusicPillTests.swift).
// MusicPillDriver applies them to AppState.

enum AutoMusicPill {
    /// How long the pill stays once nothing plays anymore.
    static let linger: TimeInterval = 30

    /// The pill of a music source (`NowPlayingSource.rawValue`). Pill ids are contracts.
    static func pillId(forSource source: String) -> String? {
        switch source {
        case "music":   "integration_music"
        case "spotify": "integration_spotify"
        case "tidal":   "integration_tidal"
        default:        nil
        }
    }

    /// Every pill this can show.
    static let pillIds: Set<String> = ["integration_music", "integration_spotify", "integration_tidal"]

    /// The pill shown on its own, and since when nothing plays (nil while its music plays).
    struct Shown: Equatable, Sendable {
        var pillId: String
        var stoppedAt: Date?
    }

    /// The auto pill after a change of what plays.
    /// - Parameters:
    ///   - shown: the auto pill on the island now (nil: none).
    ///   - playingPillId: the pill of the source playing now (nil: nothing plays).
    ///   - enabled: "Show music automatically".
    ///   - now: the time of the change, or of the linger timer firing.
    static func next(shown: Shown?, playingPillId: String?, enabled: Bool, now: Date,
                     linger: TimeInterval = linger) -> Shown? {
        guard enabled else { return nil }
        // Something plays: its pill shows (and replaces another source's at once).
        if let playingPillId { return Shown(pillId: playingPillId, stoppedAt: nil) }
        guard var shown else { return nil }
        // Nothing plays anymore: the linger starts now…
        guard let stoppedAt = shown.stoppedAt else {
            shown.stoppedAt = now
            return shown
        }
        // …and the pill leaves once it has run out.
        return now.timeIntervalSince(stoppedAt) >= linger ? nil : shown
    }

    /// When the shown pill leaves if nothing plays again (nil: its music plays).
    static func dropDate(of shown: Shown?, linger: TimeInterval = linger) -> Date? {
        shown?.stoppedAt.map { $0.addingTimeInterval(linger) }
    }

    /// What the island does when the auto pill goes from `old` to `new`.
    /// - Parameter kept: the pills that stay on the island whatever happens (declared in
    ///   Active pills, the main pill, a pill with sessions).
    /// - Returns: the pill to add (when not on the island yet: the caller checks) and the one
    ///   to remove.
    static func transition(from old: String?, to new: String?,
                           kept: Set<String>) -> (add: String?, remove: String?) {
        guard old != new else { return (nil, nil) }
        let remove = old.flatMap { kept.contains($0) ? nil : $0 }
        return (new, remove)
    }
}
