import AppKit

// MARK: - HostAppInfo
//
// Name, icon and activation for any app a session runs in, asked of macOS at run time so
// IDEs Coucou has never heard of (see HostResolver) show their real name and icon.

@MainActor
enum HostAppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    /// The app's display name ("WebStorm", "Zed"…), falling back to a name derived from
    /// the bundle id when the app isn't installed.
    static func name(for bundleId: String) -> String {
        if let cached = names[bundleId] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        } else {
            name = HostResolver.fallbackName(bundleId: bundleId)
        }
        names[bundleId] = name
        return name
    }

    /// The app's icon, or nil when the app isn't installed.
    static func icon(for bundleId: String) -> NSImage? {
        if let cached = icons[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleId] = icon
        return icon
    }

    /// True when the app is the frontmost one (e.g. to skip a notification the user can see).
    static func isFrontmost(_ bundleId: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
    }

    /// Brings the app forward, launching it if needed. false when it isn't installed.
    @discardableResult
    static func activate(_ bundleId: String) -> Bool {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return running.activate()
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        return true
    }
}
