import AppKit

extension TerminalTarget {
    /// Brings the session's terminal to the front: the app the session runs in first,
    /// then the first running known terminal. Returns false if none is running.
    @MainActor @discardableResult
    static func activate(sessionBundleId: String?) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard let id = pick(sessionBundleId: sessionBundleId, running: running) else { return false }
        return HostAppInfo.activate(id)   // windows come back too (see HostAppInfo.activate)
    }
}
