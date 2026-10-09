import Foundation

// MARK: - Which hook commands are Coucou's
// Agent settings files hold the user's own hooks next to Coucou's. Install,
// uninstall and detection must only ever touch the commands Coucou wrote itself,
// so they are recognised by their exact shape, never by a substring: a user
// script under /Users/me/dev/coucou/ or ~/NotchBuddy-tools/nb-hook-lint.sh is
// not Coucou's and must survive an install or an uninstall.
//
// Kept free of file access so it can be tested on fixtures (scripts/test-claude-hooks.sh).

/// A hook command line Coucou installed, parsed.
///
/// Every form Coucou has written since its first release:
/// - GitHub build, Claude Code:  `"<home>/Library/Application Support/NotchBuddy/nb-hook"`
///   (+ ` --ask` for the AskUserQuestion hook, ` --statusline` for the plan relay)
/// - App Store build, Claude Code: `/bin/sh "<home>/.claude/coucou/nb-hook"` (+ ` --ask`).
///   Early App Store builds wrote the sandbox container's home instead of the real one
///   (`…/Library/Containers/fr.louisraille.Coucou/Data/.claude/coucou/nb-hook`) and the
///   status line used the container's Application Support — both still end the same way.
/// - Third-party agents: `/bin/sh "<…>/NotchBuddy/nb-hook" --agent <name> [<Event>]`
/// - docs/AGENTS.md: the same unquoted with an escaped space, `~/Library/Application\ Support/…`
struct CoucouHookCommand: Equatable {
    enum Mode: Equatable {
        /// Plain event relay (Claude Code, or a third-party agent with `--agent`).
        case events
        /// `--ask`: the AskUserQuestion PreToolUse hook.
        case ask
        /// `--statusline`: the Claude plan usage relay.
        case statusLine
    }

    var mode: Mode
    /// The `--agent` name, nil for Claude Code's own hooks.
    var agent: String?
    /// The event name some agents pass after `--agent <name>`.
    var event: String?

    init?(_ command: String) {
        guard var words = Self.shellWords(command), !words.isEmpty else { return nil }
        if words[0] == "/bin/sh" { words.removeFirst() }
        guard let path = words.first, Self.isCoucouScriptPath(path) else { return nil }
        let args = Array(words.dropFirst())
        switch args.count {
        case 0:
            mode = .events
        case 1 where args[0] == "--ask":
            mode = .ask
        case 1 where args[0] == "--statusline":
            mode = .statusLine
        case 2, 3:
            guard args[0] == "--agent", Self.isAgentName(args[1]) else { return nil }
            if args.count == 3 { guard Self.isEventName(args[2]) else { return nil } }
            mode = .events
            agent = args[1]
            event = args.count == 3 ? args[2] : nil
        default:
            return nil
        }
    }

    /// True when `path` is where Coucou writes its `nb-hook` relay: the GitHub
    /// build's Application Support folder, or the App Store build's ~/.claude/coucou.
    /// Matched on whole path components, so `my-nb-hook`, `nb-hook.sh` or a
    /// `coucou` folder elsewhere never count.
    static func isCoucouScriptPath(_ path: String) -> Bool {
        let anchored = path.hasPrefix("/") || path.hasPrefix("~/")
            || path.hasPrefix("$HOME/") || path.hasPrefix("${HOME}/")
        guard anchored else { return false }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains("..") else { return false }
        return parts.hasSuffix(["Library", "Application Support", "NotchBuddy", "nb-hook"])
            || parts.hasSuffix([".claude", "coucou", "nb-hook"])
    }

    /// The `coucou_agent` names the relay accepts (see HookServer routing).
    private static func isAgentName(_ s: String) -> Bool {
        (1...24).contains(s.count) && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private static func isEventName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "_" }
    }

    /// Splits a command line the way /bin/sh would, without expanding anything:
    /// double quotes (with \" \\ \$ \` escapes), single quotes, backslash escapes.
    /// Nil when a quote is left open.
    static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var it = command.makeIterator()
        while let c = it.next() {
            switch c {
            case " ", "\t", "\n", "\r":
                if inWord { words.append(current); current = ""; inWord = false }
            case "\"":
                inWord = true
                var closed = false
                while let d = it.next() {
                    if d == "\"" { closed = true; break }
                    if d == "\\" {
                        guard let e = it.next() else { return nil }
                        if e == "\"" || e == "\\" || e == "$" || e == "`" { current.append(e) }
                        else if e != "\n" { current.append("\\"); current.append(e) }
                    } else {
                        current.append(d)
                    }
                }
                if !closed { return nil }
            case "'":
                inWord = true
                var closed = false
                while let d = it.next() {
                    if d == "'" { closed = true; break }
                    current.append(d)
                }
                if !closed { return nil }
            case "\\":
                guard let e = it.next() else { return nil }
                if e != "\n" { current.append(e); inWord = true }
            default:
                current.append(c)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

private extension Array where Element == String {
    func hasSuffix(_ suffix: [String]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}

/// True when `command` is a hook command Coucou installed (any agent, any mode).
func isCoucouHookCommand(_ command: String) -> Bool {
    CoucouHookCommand(command) != nil
}

/// True when `command` is Coucou's relay for one third-party agent (`--agent <agent>`).
func isCoucouHookCommand(_ command: String, agent: String) -> Bool {
    CoucouHookCommand(command)?.agent == agent
}

/// Removes Coucou's hooks from one event's list, leaving everything else as it was.
///
/// Handles the group format (`{"matcher": …, "hooks": [{"command": …}]}`, Claude Code,
/// Gemini, Codex, Muse) and flat entries (`{"command": …}` legacy Gemini, or
/// `{"bash": …}` with `commandKey: "bash"` for Copilot). A group is dropped only when
/// every hook in it was Coucou's; a group shared with the user's own hooks keeps them.
func removingCoucouHooks(from groups: [[String: Any]], commandKey: String = "command") -> [[String: Any]] {
    groups.compactMap { group -> [String: Any]? in
        if let command = group[commandKey] as? String, isCoucouHookCommand(command) { return nil }
        guard let inner = group["hooks"] as? [[String: Any]] else { return group }
        let kept = inner.filter { !isCoucouHookCommand($0[commandKey] as? String ?? "") }
        if kept.count == inner.count { return group }
        if kept.isEmpty { return nil }
        var updated = group
        updated["hooks"] = kept
        return updated
    }
}

/// Removes Coucou's hooks from every event of a "hooks" object. An event left with
/// no entries because of it is removed; events Coucou had nothing in are untouched.
func removingCoucouHooks(fromEvents hooks: [String: Any], commandKey: String = "command") -> [String: Any] {
    var result = hooks
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]],
              containsCoucouHook(inEvents: [event: groups], commandKey: commandKey) else { continue }
        let cleaned = removingCoucouHooks(from: groups, commandKey: commandKey)
        if cleaned.isEmpty { result.removeValue(forKey: event) } else { result[event] = cleaned }
    }
    return result
}

/// True when any hook of a "hooks" object (group or flat format) is Coucou's and
/// matches `predicate`.
func containsCoucouHook(inEvents hooks: [String: Any], commandKey: String = "command",
                        where predicate: (CoucouHookCommand) -> Bool = { _ in true }) -> Bool {
    func matches(_ entry: [String: Any]) -> Bool {
        guard let command = entry[commandKey] as? String, let parsed = CoucouHookCommand(command) else { return false }
        return predicate(parsed)
    }
    return hooks.values.contains { value in
        guard let groups = value as? [[String: Any]] else { return false }
        return groups.contains { group in
            matches(group) || ((group["hooks"] as? [[String: Any]])?.contains(where: matches) ?? false)
        }
    }
}

/// True when a parsed ~/.claude/settings.json routes Claude Code SessionStart events to Coucou.
func coucouHooksPresent(inSettings settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any],
          let sessionStart = hooks["SessionStart"] else { return false }
    return containsCoucouHook(inEvents: ["SessionStart": sessionStart])
}

/// True when the Coucou hooks in a parsed ~/.claude/settings.json are from an older
/// install: a PermissionRequest hook with a timeout under 120 s, or no AskUserQuestion
/// PreToolUse hook (Claude Code 2.1.85+). False when Coucou's hooks are not installed.
func coucouHooksNeedUpdate(inSettings settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any] else { return false }
    var hasCoucouHooks = false
    for group in hooks["PermissionRequest"] as? [[String: Any]] ?? [] {
        for hook in group["hooks"] as? [[String: Any]] ?? [] {
            guard let command = hook["command"] as? String, isCoucouHookCommand(command) else { continue }
            hasCoucouHooks = true
            if let timeout = hook["timeout"] as? Int, timeout < 120 { return true }
        }
    }
    guard hasCoucouHooks else { return false }
    let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
    let hasAskEntry = preToolUse.contains { group in
        (group["matcher"] as? String) == "AskUserQuestion"
            && ((group["hooks"] as? [[String: Any]])?.contains {
                isCoucouHookCommand($0["command"] as? String ?? "")
            } ?? false)
    }
    return !hasAskEntry
}
