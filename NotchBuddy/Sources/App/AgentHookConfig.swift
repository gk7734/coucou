import Foundation

// MARK: - Agent hook settings, merged
// What Coucou adds to, or removes from, each agent's hook settings — computed on
// the parsed JSON, so it is tested on fixtures without a real home folder
// (scripts/test-agent-hooks.sh). Which commands are Coucou's is decided by
// ClaudeHookDetection.swift; reading, the preview check, the backup and the write
// itself are ClaudeSettingsFile's. Only Foundation here.
//
// Every installer first takes out the Coucou hooks already there (an older
// install, another path) and keeps everything else, then appends its own.
// `name` is how the file is called in error messages.

enum AgentHookConfig {

    /// JSON as the installers write it. Claude's settings.json has always been written
    /// with escaped slashes; the other agents' files without.
    static func encoded(_ object: [String: Any], escapingSlashes: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if !escapingSlashes { options.insert(.withoutEscapingSlashes) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    // MARK: Claude Code — ~/.claude/settings.json

    /// (event, timeout in seconds). PermissionRequest waits for a click (timeout ladder: app
    /// 115 s < relay 118 s < hook 120 s).
    static let claudeEvents: [(event: String, timeout: Int)] = [
        ("SessionStart", 10), ("SessionEnd", 10),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
        ("PermissionRequest", 120),
        ("Notification", 10),
        ("Stop", 10), ("StopFailure", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
    ]

    /// settings.json with Coucou's hooks installed. `command` is the quoted relay path
    /// (`"…/nb-hook"`, or `/bin/sh "…/nb-hook"` for the App Store build).
    static func claudeInstalling(into settings: [String: Any], command: String, name: String) throws -> [String: Any] {
        var settings = settings
        // "hooks" in a shape we do not know is refused, never replaced.
        var hooks = try ClaudeSettingsFile.hooks(in: settings, name: name)
        for (event, _) in claudeEvents {
            _ = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: name)
        }
        hooks = removingCoucouHooks(fromEvents: hooks)
        for (event, timeout) in claudeEvents {
            var groups = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: name)
            groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            hooks[event] = groups
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130 s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(command) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        return settings
    }

    /// settings.json without Coucou's hooks, or nil when it has no "hooks" object at all.
    static func claudeRemoving(from settings: [String: Any]) -> [String: Any]? {
        guard let hooks = settings["hooks"] as? [String: Any] else { return nil }
        var settings = settings
        settings["hooks"] = removingCoucouHooks(fromEvents: hooks)
        return settings
    }

    // MARK: Gemini CLI — ~/.gemini/settings.json

    /// (Gemini event key, normalized event passed on the command line, timeout in ms)
    static let geminiEvents: [(event: String, normalized: String, timeout: Int)] = [
        ("SessionStart", "SessionStart", 10000),
        ("SessionEnd",   "SessionEnd",   10000),
        ("BeforeTool",   "PreToolUse",   5000),
        ("AfterTool",    "PostToolUse",  5000),
        ("BeforeAgent",  "UserPromptSubmit", 5000),
        ("AfterAgent",   "Stop",         5000),
    ]

    static func geminiInstalling(into settings: [String: Any], base: String, name: String) throws -> [String: Any] {
        try installingGroups(into: settings, name: name, events: geminiEvents.map { $0.event }) { index in
            let (_, normalized, timeout) = geminiEvents[index]
            return ["matcher": "*", "hooks": [[
                "type": "command",
                "command": "\(base) --agent gemini \(normalized)",
                "timeout": timeout,
            ] as [String: Any]]]
        }
    }

    static func hasGeminiHooks(_ settings: [String: Any]) -> Bool {
        hasAgentHooks(settings["hooks"], agent: "gemini")
    }

    // MARK: Antigravity — ~/.gemini/config/hooks.json (its own "coucou" key)

    static func antigravityInstalling(into root: [String: Any], base: String) -> [String: Any] {
        var root = root
        // PreToolUse / PostToolUse: tool-level hooks — use matcher group
        // PreInvocation / PostInvocation / Stop: lifecycle hooks — direct handler, no matcher
        var coucou: [String: Any] = [:]
        for event in ["PreToolUse", "PostToolUse"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [["matcher": "*", "hooks": [hook]]]
        }
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [hook]
        }
        root["coucou"] = coucou
        return root
    }

    static func antigravityRemoving(from root: [String: Any]) -> [String: Any] {
        var root = root
        root.removeValue(forKey: "coucou")
        return root
    }

    static func hasAntigravityHooks(_ root: [String: Any]) -> Bool {
        hasAgentHooks(root["coucou"], agent: "antigravity")
    }

    // MARK: Codex — ~/.codex/hooks.json

    /// (event, timeout in seconds, status message shown in Codex while waiting)
    static let codexEvents: [(event: String, timeout: Int, statusMessage: String?)] = [
        ("SessionStart",    10,  nil),
        ("UserPromptSubmit", 10, nil),
        ("PreToolUse",      10,  nil),
        ("PermissionRequest", 120, "Waiting for your answer in the notch (Coucou)"),
        ("PostToolUse",     10,  nil),
        ("Stop",            10,  nil),
        ("SubagentStart",   10,  nil),
        ("SubagentStop",    10,  nil),
        ("Interrupt",        3,  nil),
        ("SessionEnd",       3,  nil),
    ]

    static func codexInstalling(into root: [String: Any], base: String, name: String) throws -> [String: Any] {
        try installingGroups(into: root, name: name, events: codexEvents.map { $0.event }) { index in
            let (_, timeout, statusMessage) = codexEvents[index]
            var hook: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent codex",
                "timeout": timeout,
            ]
            if let statusMessage { hook["statusMessage"] = statusMessage }
            return ["hooks": [hook]]
        }
    }

    static func hasCodexHooks(_ root: [String: Any]) -> Bool {
        hasAgentHooks(root["hooks"], agent: "codex")
    }

    // MARK: GitHub Copilot CLI — ~/.copilot/hooks/coucou.json (a file of Coucou's own)

    /// Copilot CLI uses camelCase event names; each entry uses "bash" + "timeoutSec".
    /// The event name is passed as a positional arg so the relay can fall back to it.
    /// Copilot is fail-closed on permissionRequest — the relay always outputs valid JSON.
    static let copilotEvents: [(event: String, timeout: Int)] = [
        ("sessionStart",        10),
        ("userPromptSubmitted", 10),
        ("preToolUse",          10),
        ("permissionRequest",  120),
        ("postToolUse",         10),
        ("agentStop",           10),
        ("sessionEnd",           3),
        ("notification",        10),
    ]

    static func copilotInstalling(into root: [String: Any], base: String, name: String) throws -> [String: Any] {
        var root = try installingGroups(into: root, name: name, events: copilotEvents.map { $0.event },
                                        commandKey: "bash") { index in
            let (event, timeout) = copilotEvents[index]
            return ["type": "command", "bash": "\(base) --agent copilot \(event)", "timeoutSec": timeout]
        }
        root["version"] = 1
        return root
    }

    static func hasCopilotHooks(_ root: [String: Any]) -> Bool {
        hasAgentHooks(root["hooks"], agent: "copilot", commandKey: "bash")
    }

    // MARK: Muse Code — ~/.config/muse/settings.json

    /// PascalCase events, timeouts in seconds (written in milliseconds).
    static let museEvents: [(event: String, timeout: Int)] = [
        ("SessionStart",      10),
        ("UserPromptSubmit",   5),
        ("PreToolUse",         5),
        ("PermissionRequest", 120),
        ("PostToolUse",        5),
        ("Stop",               5),
        ("SessionEnd",         3),
    ]

    /// `isNewFile`: there was no settings file yet, so it also gets Muse's schema_version.
    static func museInstalling(into settings: [String: Any], base: String, name: String,
                               isNewFile: Bool) throws -> [String: Any] {
        var settings = try installingGroups(into: settings, name: name, events: museEvents.map { $0.event }) { index in
            let (event, timeout) = museEvents[index]
            return ["matcher": "*", "hooks": [[
                "type": "command",
                "command": "\(base) --agent muse \(event)",
                "timeout": timeout * 1000,
            ] as [String: Any]]]
        }
        if isNewFile { settings["schema_version"] = 1 }
        return settings
    }

    static func hasMuseHooks(_ settings: [String: Any]) -> Bool {
        hasAgentHooks(settings["hooks"], agent: "muse")
    }

    // MARK: Shared

    /// The settings without any Coucou hook (Gemini, Codex, Muse uninstall). A "hooks"
    /// object left empty by it is removed; one that was not Coucou's is untouched.
    static func removingAgentHooks(from settings: [String: Any], name: String) throws -> [String: Any] {
        guard settings["hooks"] != nil else { return settings }
        let hooks = try ClaudeSettingsFile.hooks(in: settings, name: name)
        let cleaned = removingCoucouHooks(fromEvents: hooks)
        var settings = settings
        if cleaned.isEmpty && !hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = cleaned }
        return settings
    }

    /// Appends `entry(i)` to `events[i]` under "hooks", after taking out Coucou's
    /// earlier entries there. "hooks" or an event in a shape we do not know is refused.
    private static func installingGroups(into settings: [String: Any], name: String, events: [String],
                                         commandKey: String = "command",
                                         entry: (Int) -> [String: Any]) throws -> [String: Any] {
        var settings = settings
        var hooks = try ClaudeSettingsFile.hooks(in: settings, name: name)
        for (index, event) in events.enumerated() {
            var groups = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: name)
            groups = removingCoucouHooks(from: groups, commandKey: commandKey)
            groups.append(entry(index))
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    private static func hasAgentHooks(_ hooks: Any?, agent: String, commandKey: String = "command") -> Bool {
        guard let hooks = hooks as? [String: Any] else { return false }
        return containsCoucouHook(inEvents: hooks, commandKey: commandKey) { $0.agent == agent }
    }
}
