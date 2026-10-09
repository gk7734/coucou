import Foundation

/// Where the app keeps its files, and the launch switches of the live smoke test.
///
/// Release builds always use the user's folders. A DEBUG build honours, at launch:
/// - `COUCOU_SUPPORT_DIR=<dir>`: replaces ~/Library/Application Support/NotchBuddy (socket,
///   nb-hook relay, recap.json, custom sounds, statusline backup); the logs go to `<dir>/Logs`.
///   Keep it short: the socket path must fit in 103 bytes.
/// - `COUCOU_SMOKE=1`: the app runs headless for scripts/smoke.sh (see `isSmokeTest`).
/// UserDefaults are switched separately (`COUCOU_DEFAULTS_SUITE`, see AppDefaults).
enum AppPaths {
    /// The support directory override, nil in Release or when unset.
    static let supportOverride: URL? = {
        #if DEBUG
        // A snapshot run (`--snapshot`) reads agent settings and writes its socket under a
        // fixture home, never the user's.
        if SnapshotMode.isActive {
            return SnapshotMode.home.appendingPathComponent("Library/Application Support/NotchBuddy")
        }
        if let dir = ProcessInfo.processInfo.environment["COUCOU_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return nil
    }()

    /// ~/Library/Application Support/NotchBuddy (in the App Store build, inside its container).
    static var supportDirectory: URL {
        if let supportOverride { return supportOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }

    /// ~/Library/Logs/NotchBuddy, or `<COUCOU_SUPPORT_DIR>/Logs`.
    static var logsDirectory: URL {
        if let supportOverride { return supportOverride.appendingPathComponent("Logs", isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
    }

    /// DEBUG builds launched with `COUCOU_SMOKE=1` (scripts/smoke.sh): the hook server, the
    /// island's state machine and AppState run as usual, but nothing reaches the user's
    /// session — no menu bar item, global hotkeys or monitors, sounds, notifications, audio
    /// capture, music listeners, pollers or iPhone link, and the island panel stays
    /// transparent and click-through, never in front of the user's work. The pointer is
    /// treated as far from the island. Always false in Release.
    static let isSmokeTest: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["COUCOU_SMOKE"] == "1"
        #else
        return false
        #endif
    }()
}
