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

    /// Brings the app forward with its windows, launching it if needed, like clicking its Dock
    /// icon. false when it can't be found.
    ///
    /// `NSRunningApplication.activate()` is not enough: since macOS 14 activation is
    /// cooperative and a request from an app that isn't active itself (Coucou is an accessory
    /// app behind a non-activating panel) can be ignored, and it never brings back a
    /// minimised or hidden window. Opening the app through Launch Services activates it and
    /// sends it the "reopen" event, which shows its window again.
    @discardableResult
    static func activate(_ bundleId: String) -> Bool {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleId)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            return true
        }
        // Running from somewhere Launch Services doesn't index: ask it directly.
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return false
        }
        running.unhide()
        return running.activate(from: .current, options: [.activateAllWindows])
    }
}
