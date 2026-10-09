import Foundation

// MARK: - HostResolver
//
// Which app an agent session runs in, and which pill it belongs to.
// Foundation only, so it can be tested without AppKit (see scripts/test-host-resolver.sh).
//
// Signals, strongest first:
//   1. `ancestorBundleIds`: the regular apps found walking up the hook relay's process tree
//      (nearest first). Works for any IDE, including ones Coucou has never heard of.
//   2. the payload's `bundle_id` (`__CFBundleIdentifier` inherited by the agent's shell).
//   3. `TERM_PROGRAM` / `TERMINAL_EMULATOR` for hooks that run without either.
//
// Pills are per IDE: VS Code keeps `integration_claude`, Cursor keeps `agent_cursor`, any
// other IDE gets a dynamic `ide_<bundle id>` pill. Plain terminals keep the per-agent pills
// (`integration_claude` for Claude Code, `agent_codex` for Codex).

enum HostKind: String, Equatable, Sendable {
    case vscode, cursor, ide, terminal
}

struct HostIdentity: Equatable, Sendable {
    /// Bundle id of the host app. For a JetBrains terminal seen without a bundle id this is
    /// `HostResolver.jetBrainsFallbackId`.
    let bundleId: String
    let kind: HostKind
}

/// The coding agent behind a hook event.
enum AgentKind: String, Equatable, Sendable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex:  "Codex"
        }
    }
}

enum HostResolver {

    static let cursorBundleId = "com.todesktop.230313mzl4w4u92"
    static let jetBrainsFallbackId = "com.jetbrains.ide"
    static let idePillPrefix = "ide_"

    /// VS Code and its forks that keep the "VS Code" pill. Cursor has its own pill; other
    /// forks (Windsurf, Trae…) are ordinary IDEs and get their own pill.
    static let vscodeBundleIds: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
    ]

    /// Plain terminals, by bundle id. Sessions there stay on the per-agent pills.
    static let terminals: [String: String] = [
        "dev.warp.Warp-Stable":   "Warp",
        "dev.warp.Warp-Preview":  "Warp",
        "com.apple.Terminal":     "Terminal",
        "com.googlecode.iterm2":  "iTerm",
        "com.mitchellh.ghostty":  "Ghostty",
        "net.kovidgoyal.kitty":   "kitty",
        "org.alacritty":          "Alacritty",
        "com.github.wez.wezterm": "WezTerm",
        "co.zeit.hyper":          "Hyper",
        "com.cmuxterm.app":       "cmux",
    ]

    /// TERM_PROGRAM (lowercased) → bundle id, for hooks that run without __CFBundleIdentifier.
    static let termPrograms: [String: String] = [
        "warpterminal":   "dev.warp.Warp-Stable",
        "apple_terminal": "com.apple.Terminal",
        "iterm.app":      "com.googlecode.iterm2",
        "ghostty":        "com.mitchellh.ghostty",
        "kitty":          "net.kovidgoyal.kitty",
        "alacritty":      "org.alacritty",
        "wezterm":        "com.github.wez.wezterm",
        "hyper":          "co.zeit.hyper",
        "zed":            "dev.zed.Zed",
    ]

    /// Apps that can show up in a process tree without being where the user works.
    static let ignoredAncestors: Set<String> = [
        "fr.louisraille.NotchBuddy", "fr.louisraille.Coucou",
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
    ]

    /// Classifies one bundle id. Any bundle id that isn't VS Code, Cursor or a known terminal
    /// is an IDE: that is what makes new editors work without a list.
    static func kind(of bundleId: String) -> HostKind {
        if bundleId == cursorBundleId { return .cursor }
        if vscodeBundleIds.contains(bundleId) { return .vscode }
        if terminals[bundleId] != nil { return .terminal }
        return .ide
    }

    /// The host of a session, or nil when nothing identifies one (e.g. a daemonized tmux
    /// server with no bundle id and an unknown TERM_PROGRAM).
    static func resolve(payloadBundleId: String,
                        termProgram: String,
                        terminalEmulator: String = "",
                        ancestorBundleIds: [String] = []) -> HostIdentity? {
        // 1. Nearest regular app in the process tree.
        if let id = ancestorBundleIds.first(where: { !$0.isEmpty && !ignoredAncestors.contains($0) }) {
            return HostIdentity(bundleId: id, kind: kind(of: id))
        }
        // 2. The inherited bundle id.
        let bundle = payloadBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundle.isEmpty, !ignoredAncestors.contains(bundle) {
            return HostIdentity(bundleId: bundle, kind: kind(of: bundle))
        }
        // 3. Environment hints.
        let term = termProgram.lowercased()
        if term.contains("vscode") {
            return HostIdentity(bundleId: "com.microsoft.VSCode", kind: .vscode)
        }
        if let id = termPrograms[term] {
            return HostIdentity(bundleId: id, kind: kind(of: id))
        }
        if terminalEmulator.lowercased().hasPrefix("jetbrains") {
            return HostIdentity(bundleId: jetBrainsFallbackId, kind: .ide)
        }
        return nil
    }

    /// The pill a session belongs to, or nil when the event should be ignored
    /// (a Claude Code session with no identifiable host, as before).
    static func pillId(agent: AgentKind, host: HostIdentity?) -> String? {
        switch host?.kind {
        case .vscode?:   return "integration_claude"
        case .cursor?:   return "agent_cursor"
        case .ide?:      return idePillId(bundleId: host!.bundleId)
        case .terminal?: return agent == .codex ? "agent_codex" : "integration_claude"
        case nil:        return agent == .codex ? "agent_codex" : nil
        }
    }

    /// `ide_` + the bundle id lowercased, every run of characters outside [a-z0-9] as one "-".
    /// Stable across launches; safe in UserDefaults keys and CloudKit record names.
    static func idePillId(bundleId: String) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in bundleId.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return idePillPrefix + (slug.isEmpty ? "unknown" : slug)
    }

    static func isIDEPill(_ pillId: String) -> Bool { pillId.hasPrefix(idePillPrefix) }

    /// A readable name when the app itself can't be asked (no AppKit here, app not installed):
    /// the last bundle id component, e.g. "com.jetbrains.WebStorm" → "WebStorm".
    static func fallbackName(bundleId: String) -> String {
        if bundleId == jetBrainsFallbackId { return "JetBrains" }
        if let name = terminals[bundleId] { return name }
        if bundleId == cursorBundleId { return "Cursor" }
        if vscodeBundleIds.contains(bundleId) { return "VS Code" }
        let last = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        return last.isEmpty ? bundleId : last.prefix(1).uppercased() + last.dropFirst()
    }
}

// MARK: - Process tree walk

enum ProcessTree {
    /// The chain of parent pids above `pid`, nearest first, stopping at launchd (pid 1),
    /// a missing parent, a loop, or `maxDepth`. `parent` is injected so the walk is testable;
    /// the app passes a sysctl(KERN_PROC_PID) lookup.
    static func ancestors(of pid: Int32, maxDepth: Int = 32, parent: (Int32) -> Int32?) -> [Int32] {
        var chain: [Int32] = []
        var seen: Set<Int32> = [pid]
        var current = pid
        while chain.count < maxDepth, let next = parent(current), next > 1, !seen.contains(next) {
            chain.append(next)
            seen.insert(next)
            current = next
        }
        return chain
    }
}
