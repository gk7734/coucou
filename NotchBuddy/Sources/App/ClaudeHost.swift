import AppKit

// MARK: - ClaudeHost
//
// The terminal a Claude Code session on the `integration_claude` pill runs in. VS Code
// sessions keep the original "VS Code" pill; sessions from a plain terminal route there too
// and the pill says "Claude Code". Which apps are terminals is HostResolver's call (its
// tables are the single source): IDEs, Zed included, have pills of their own.

struct ClaudeHost: Equatable {
    let bundleId: String
    let name: String

    /// UserDefaults key: show terminal sessions' questions and permission requests in the
    /// notch (they then wait for the notch). Off by default: the terminal asks itself.
    /// IDE sessions always get their cards.
    static let terminalCardsKey = "terminalCardsEnabled"
    static var terminalCardsEnabled: Bool { UserDefaults.standard.bool(forKey: terminalCardsKey) }

    /// The terminal a session runs in, from its payload's bundle id or TERM_PROGRAM, or nil
    /// when it isn't a known terminal.
    static func terminal(termProgram: String, bundleId: String) -> ClaudeHost? {
        if let name = HostResolver.terminals[bundleId] { return ClaudeHost(bundleId: bundleId, name: name) }
        if let id = HostResolver.termPrograms[termProgram.lowercased()],
           HostResolver.kind(of: id) == .terminal, let name = HostResolver.terminals[id] {
            return ClaudeHost(bundleId: id, name: name)
        }
        return nil
    }

    /// The app name for a task's host; nil host means VS Code (the original routing).
    static func name(for hostBundleId: String?) -> String {
        guard let id = hostBundleId, let name = HostResolver.terminals[id] else { return "VS Code" }
        return name
    }

    /// Pill label for integration_claude: "VS Code" for editor sessions, "Claude Code" otherwise.
    static func pillName(hostApp: String?) -> String {
        hostApp == nil ? "VS Code" : "Claude Code"
    }

    /// Brings the session's terminal forward (launching it if needed). false when not a terminal host.
    @MainActor @discardableResult
    static func activate(_ hostBundleId: String?) -> Bool {
        guard let id = hostBundleId, HostResolver.kind(of: id) == .terminal else { return false }
        HostAppInfo.activate(id)
        return true
    }
}
