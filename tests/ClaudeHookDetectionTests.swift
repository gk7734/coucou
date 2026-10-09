import Foundation

@main
enum ClaudeHookDetectionTests {
    static func settings(_ json: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return (object as? [String: Any]) ?? [:]
    }

    static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }

        // ── Every command Coucou has ever written is recognised ──────────────────
        let ours: [(String, CoucouHookCommand.Mode, String?)] = [
            // GitHub build, Claude Code (quoted: Application Support has a space)
            (#""/Users/me/Library/Application Support/NotchBuddy/nb-hook""#, .events, nil),
            (#""/Users/me/Library/Application Support/NotchBuddy/nb-hook" --ask"#, .ask, nil),
            (#""/Users/me/Library/Application Support/NotchBuddy/nb-hook" --statusline"#, .statusLine, nil),
            // App Store build, Claude Code
            (#"/bin/sh "/Users/me/.claude/coucou/nb-hook""#, .events, nil),
            (#"/bin/sh "/Users/me/.claude/coucou/nb-hook" --ask"#, .ask, nil),
            // Early App Store builds: the sandbox container's home, and its Application Support
            (#"/bin/sh "/Users/me/Library/Containers/fr.louisraille.Coucou/Data/.claude/coucou/nb-hook""#, .events, nil),
            (#""/Users/me/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/nb-hook" --statusline"#, .statusLine, nil),
            // Third-party agents
            (#"/bin/sh "/Users/me/Library/Application Support/NotchBuddy/nb-hook" --agent gemini SessionStart"#, .events, "gemini"),
            (#"/bin/sh "/Users/me/Library/Application Support/NotchBuddy/nb-hook" --agent codex"#, .events, "codex"),
            (#"/bin/sh "/Users/me/Library/Application Support/NotchBuddy/nb-hook" --agent copilot permissionRequest"#, .events, "copilot"),
            (#"/bin/sh "/Users/me/Library/Application Support/NotchBuddy/nb-hook" --agent claude-desktop"#, .events, "claude-desktop"),
            // A user name with a quote, escaped the way the installers escape it
            (#""/Users/o\"neil/Library/Application Support/NotchBuddy/nb-hook""#, .events, nil),
            // docs/AGENTS.md: unquoted with an escaped space, ~ and $HOME forms
            (#"/bin/sh ~/Library/Application\ Support/NotchBuddy/nb-hook --agent demo"#, .events, "demo"),
            (#"$HOME/.claude/coucou/nb-hook"#, .events, nil),
            (#""${HOME}/.claude/coucou/nb-hook" --ask"#, .ask, nil),
            ("'/Users/me/Library/Application Support/NotchBuddy/nb-hook'", .events, nil),
            // Extra blanks do not matter
            ("  /bin/sh   \"/Users/me/.claude/coucou/nb-hook\"   --ask  ", .ask, nil),
        ]
        for (command, mode, agent) in ours {
            let parsed = CoucouHookCommand(command)
            check(parsed != nil, "must be recognised as Coucou's: \(command)")
            check(parsed?.mode == mode, "wrong mode for \(command)")
            check(parsed?.agent == agent, "wrong agent for \(command)")
            check(isCoucouHookCommand(command), "isCoucouHookCommand: \(command)")
        }
        check(isCoucouHookCommand(#"/bin/sh "/x/Library/Application Support/NotchBuddy/nb-hook" --agent gemini AfterTool"#, agent: "gemini"), "agent match")
        check(!isCoucouHookCommand(#"/bin/sh "/x/Library/Application Support/NotchBuddy/nb-hook" --agent gemini AfterTool"#, agent: "codex"), "agent mismatch")
        check(CoucouHookCommand(#"/bin/sh "/x/Library/Application Support/NotchBuddy/nb-hook" --agent gemini AfterTool"#)?.event == "AfterTool", "event")

        // ── The user's own commands are never Coucou's, whatever their path says ──
        let theirs = [
            // The bug: a script in a folder named coucou (this repository) or NotchBuddy
            "/Volumes/x/orca/coucou/my-hook.sh",
            "\"/Volumes/1M2/dev/orca/coucou/scripts/notify.sh\" --ask",
            "/Users/me/NotchBuddy/hook.sh",
            "python3 /Users/me/dev/coucou/hooks/pre.py",
            "/Users/me/Library/Application Support/NotchBuddy-fork/run.sh",
            // nb-hook as part of another name, or another file next to Coucou's
            "/usr/local/bin/my-nb-hook",
            "/Users/me/bin/nb-hook",
            "/Users/me/bin/nb-hook --agent gemini",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook.py\"",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook-wrapper\"",
            "/Users/me/tools/nb-hook-lint.sh",
            "/Users/me/.claude/coucou-old/nb-hook",
            "/Users/me/coucou/nb-hook",
            "/Users/me/.claude/hooks/nb-hook",
            "/Users/me/project/.claude/coucou/nb-hook.sh",
            // Coucou's relay, but wrapped in something of the user's
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" | tee /tmp/log",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\"; ~/bin/other",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" --statusline && ~/bin/ccline",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" --verbose",
            "bash -c \"/Users/me/Library/Application Support/NotchBuddy/nb-hook\"",
            "/bin/sh -c '\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" --ask'",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" --agent Gemini",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" --agent gemini Session-Start",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\" --agent",
            // Relative, traversing, unterminated or empty
            "Library/Application Support/NotchBuddy/nb-hook",
            "\"/Users/me/Library/Application Support/NotchBuddy/../NotchBuddy/nb-hook\"",
            "\"/Users/me/Library/Application Support/NotchBuddy/nb-hook",
            "/Users/me/Library/Application Support/NotchBuddy/nb-hook",  // unquoted space: two words
            "",
            "/bin/sh",
            "echo coucou NotchBuddy nb-hook",
        ]
        for command in theirs {
            check(!isCoucouHookCommand(command), "must NOT be recognised as Coucou's: \(command)")
        }

        // ── Shell words ──────────────────────────────────────────────────────────
        check(CoucouHookCommand.shellWords(#"a "b c" 'd e' f\ g"#) == ["a", "b c", "d e", "f g"], "words")
        check(CoucouHookCommand.shellWords(#""a\"b\\c\$d\x""#) == [#"a"b\c$d\x"#], "escapes in double quotes")
        check(CoucouHookCommand.shellWords("\"open") == nil, "open quote")
        check(CoucouHookCommand.shellWords("'open") == nil, "open single quote")
        check(CoucouHookCommand.shellWords("\"\"") == [""], "empty word")

        // ── Removing Coucou's hooks keeps the user's ─────────────────────────────
        let gh = #""/Users/me/Library/Application Support/NotchBuddy/nb-hook""#
        let groups: [[String: Any]] = [
            ["hooks": [["type": "command", "command": gh, "timeout": 10]]],
            ["hooks": [["type": "command", "command": "/Volumes/x/orca/coucou/my-hook.sh"]]],
            ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard"],
                                          ["type": "command", "command": "\(gh) --ask"]]],
            ["matcher": "x", "hooks": [[String: Any]]()],
            ["command": "/bin/sh \(gh) --agent gemini Stop"],            // legacy flat entry
            ["command": "/Users/me/NotchBuddy/flat.sh"],
        ]
        let cleaned = removingCoucouHooks(from: groups)
        check(json(cleaned) == json([
            ["hooks": [["type": "command", "command": "/Volumes/x/orca/coucou/my-hook.sh"]]],
            ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard"]]],
            ["matcher": "x", "hooks": [[String: Any]]()],
            ["command": "/Users/me/NotchBuddy/flat.sh"],
        ] as [[String: Any]]), "remove: \(json(cleaned))")

        // Copilot's flat entries use "bash"
        let copilot: [[String: Any]] = [
            ["type": "command", "bash": "/bin/sh \(gh) --agent copilot preToolUse"],
            ["type": "command", "bash": "~/coucou/nb-hook-audit.sh"],
        ]
        check(json(removingCoucouHooks(from: copilot, commandKey: "bash"))
              == json([["type": "command", "bash": "~/coucou/nb-hook-audit.sh"]]), "copilot bash key")

        // Whole events: emptied events go, untouched ones (even empty) stay as they were
        let events = settings("""
        {"Stop":[{"hooks":[{"command":"\\"/u/Library/Application Support/NotchBuddy/nb-hook\\""}]}],
         "SessionEnd":[],
         "PreToolUse":[{"hooks":[{"command":"/Volumes/x/orca/coucou/my-hook.sh"}]}],
         "Weird":"not a list"}
        """)
        let remaining = removingCoucouHooks(fromEvents: events)
        check(remaining["Stop"] == nil, "emptied event removed")
        check((remaining["SessionEnd"] as? [Any])?.isEmpty == true, "untouched empty event kept")
        check(remaining["PreToolUse"] != nil, "user event kept")
        check(remaining["Weird"] as? String == "not a list", "unknown shape kept")

        check(containsCoucouHook(inEvents: events), "contains")
        check(!containsCoucouHook(inEvents: remaining), "nothing left")
        check(!containsCoucouHook(inEvents: events) { $0.agent == "gemini" }, "predicate")

        // ── Installed-state detection (SessionStart) ─────────────────────────────
        check(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"\\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\\""}]}]}}
        """)), "GitHub install")
        check(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"/bin/sh \\"/Users/me/.claude/coucou/nb-hook\\""}]}]}}
        """)), "App Store install")
        check(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)), "unquoted $HOME form")
        check(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[
          {"hooks":[{"type":"command","command":"/usr/local/bin/other-tool"}]},
          {"hooks":[{"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)), "ours alongside somebody else's")

        // Not installed: other tools only — including paths that mention coucou or NotchBuddy
        check(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.vibe-island/bin/vibe-island-bridge"},
          {"type":"command","command":"/Volumes/x/orca/coucou/my-hook.sh"},
          {"type":"command","command":"/Applications/NotchBuddy.app/Contents/MacOS/helper"},
          {"type":"command","command":"python3 /Users/me/.claude/skills/harness/hook.py"}]}]}}
        """)), "other tools only")
        check(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"PreToolUse":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)), "other events do not count")
        for malformed in ["{}", #"{"hooks":{"SessionStart":[]}}"#, #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command"}]}]}}"#,
                          #"{"hooks":{"SessionStart":"not-an-array"}}"#, #"{"hooks":"not-an-object"}"#] {
            check(!coucouHooksPresent(inSettings: settings(malformed)), "malformed: \(malformed)")
        }

        // ── Outdated install ─────────────────────────────────────────────────────
        let current = settings("""
        {"hooks":{
          "PermissionRequest":[{"hooks":[{"command":"\\"/u/Library/Application Support/NotchBuddy/nb-hook\\"","timeout":120}]}],
          "PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"command":"\\"/u/Library/Application Support/NotchBuddy/nb-hook\\" --ask","timeout":130}]}]}}
        """)
        check(!coucouHooksNeedUpdate(inSettings: current), "current install is up to date")
        check(coucouHooksNeedUpdate(inSettings: settings("""
        {"hooks":{"PermissionRequest":[{"hooks":[{"command":"\\"/u/Library/Application Support/NotchBuddy/nb-hook\\"","timeout":60}]}]}}
        """)), "short PermissionRequest timeout")
        check(coucouHooksNeedUpdate(inSettings: settings("""
        {"hooks":{"PermissionRequest":[{"hooks":[{"command":"/bin/sh \\"/u/.claude/coucou/nb-hook\\"","timeout":120}]}]}}
        """)), "missing AskUserQuestion hook")
        check(!coucouHooksNeedUpdate(inSettings: settings("""
        {"hooks":{"PermissionRequest":[{"hooks":[{"command":"/Volumes/x/orca/coucou/approve.sh","timeout":5}]}]}}
        """)), "a user's PermissionRequest hook is not an outdated Coucou install")
        check(!coucouHooksNeedUpdate(inSettings: settings("{}")), "nothing installed")

        print("Claude hook detection: \(count) checks passed")
    }
}
