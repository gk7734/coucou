import Foundation

/// The UserDefaults the app's settings are read from and written to.
///
/// `.standard`, except in a DEBUG Mac build launched with `COUCOU_DEFAULTS_SUITE=<suite>`
/// (scripts/smoke.sh): every setting then lives in that suite, so a test run never reads or
/// changes the user's own preferences. Release builds always use `.standard`.
enum AppDefaults {
    /// UserDefaults is thread-safe (Apple documents it so); the SDK just doesn't mark it Sendable.
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG && os(macOS)
        if let suite = ProcessInfo.processInfo.environment["COUCOU_DEFAULTS_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }()
}
