import Foundation

/// The UserDefaults the app's settings are read from and written to.
///
/// `.standard`, except in DEBUG Mac builds that must never read or change the user's own
/// preferences:
/// - a snapshot run (`--snapshot`, see SnapshotRunner) gets an empty throwaway suite;
/// - a smoke run (`COUCOU_DEFAULTS_SUITE=<suite>`, scripts/smoke.sh) keeps every setting in
///   that suite.
/// Release builds always use `.standard`.
enum AppDefaults {
    /// UserDefaults is thread-safe (Apple documents it so); the SDK just doesn't mark it Sendable.
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG && os(macOS)
        if SnapshotMode.isActive, let suite = UserDefaults(suiteName: SnapshotMode.defaultsSuite) {
            // Start from nothing: a run that crashed may have left values behind.
            suite.removePersistentDomain(forName: SnapshotMode.defaultsSuite)
            return suite
        }
        if let suite = ProcessInfo.processInfo.environment["COUCOU_DEFAULTS_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }()
}

#if DEBUG && os(macOS)
/// A DEBUG run that renders the island and Settings offscreen to PNG files and quits
/// (`Coucou --snapshot <dir>`, scripts/snapshot.sh). Decided from the command line, so it
/// holds from the first line of the process: the Settings scene builds its view (and
/// AppState) before the app delegate runs.
enum SnapshotMode {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--snapshot")

    /// The throwaway UserDefaults suite of a snapshot run (AppDefaults.store).
    static let defaultsSuite = "fr.louisraille.NotchBuddy.snapshot"

    /// The home directory HookServer reads agent settings from in a snapshot run: a fixed
    /// path (it shows in Settings), filled with fixtures by SnapshotRunner.
    static let home = URL(fileURLWithPath: "/tmp/coucou-snapshot-home", isDirectory: true)
}
#endif
