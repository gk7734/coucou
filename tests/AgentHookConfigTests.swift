import Foundation

@main
enum AgentHookConfigTests {
    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func text(_ object: [String: Any]) -> String {
        String(data: (try? AgentHookConfig.encoded(object)) ?? Data(), encoding: .utf8) ?? ""
    }

    /// Every command string anywhere in the object (keys "command" and "bash").
    static func commands(_ value: Any) -> [String] {
        if let dict = value as? [String: Any] {
            return dict.flatMap { key, v -> [String] in
                if (key == "command" || key == "bash"), let s = v as? String { return [s] }
                return commands(v)
            }
        }
        if let list = value as? [Any] { return list.flatMap(commands) }
        return []
    }

    static func failure(_ body: () throws -> Void) -> ClaudeSettingsFile.Failure? {
        do { try body() } catch let error as ClaudeSettingsFile.Failure { return error } catch { return nil }
        return nil
    }

    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }

        let ghCmd = #""/Users/me/Library/Application Support/NotchBuddy/nb-hook""#
        let base = #"/bin/sh "/Users/me/Library/Application Support/NotchBuddy/nb-hook""#
        let userHooks = [
            "/Volumes/x/orca/coucou/my-hook.sh",
            "/Users/me/NotchBuddy/notify.sh",
            "~/bin/nb-hook-lint.sh",
        ]

        // ── Claude Code ─────────────────────────────────────────────────────────
        // The user's hooks — whatever their paths mention — survive an install,
        // a reinstall and an uninstall. This is the bug that deleted them.
        let claudeUser = object("""
        {"model":"opus",
         "hooks":{
           "Stop":[{"hooks":[{"type":"command","command":"/Volumes/x/orca/coucou/my-hook.sh"}]}],
           "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/Users/me/NotchBuddy/notify.sh"},
                                                    {"type":"command","command":"~/bin/nb-hook-lint.sh"}]}],
           "CustomEvent":[{"hooks":[{"type":"command","command":"/bin/sh \\"/Users/me/.claude/coucou/nb-hook\\""}]}]}}
        """)
        let installed = try AgentHookConfig.claudeInstalling(into: claudeUser, command: ghCmd, name: "settings.json")
        let installedCommands = commands(installed)
        for user in userHooks {
            check(installedCommands.contains(user), "install kept \(user)")
        }
        check(installed["model"] as? String == "opus", "other settings kept")
        // An older Coucou hook, even on an event Coucou no longer uses, is replaced.
        check(!installedCommands.contains(#"/bin/sh "/Users/me/.claude/coucou/nb-hook""#), "old Coucou hook replaced")
        check((installed["hooks"] as? [String: Any])?["CustomEvent"] == nil, "event left empty by the replacement removed")
        let ours = installedCommands.filter { isCoucouHookCommand($0) }
        check(ours.count == AgentHookConfig.claudeEvents.count + 1, "one hook per event + AskUserQuestion")
        check(ours.filter { $0 == ghCmd }.count == AgentHookConfig.claudeEvents.count, "event hooks")
        check(ours.contains("\(ghCmd) --ask"), "AskUserQuestion hook")
        let permission = ((installed["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.last
        check(((permission?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int) == 120, "PermissionRequest timeout")
        check(coucouHooksPresent(inSettings: installed), "detected after install")
        check(!coucouHooksNeedUpdate(inSettings: installed), "fresh install is current")

        // Reinstalling changes nothing.
        let reinstalled = try AgentHookConfig.claudeInstalling(into: installed, command: ghCmd, name: "settings.json")
        check(text(reinstalled) == text(installed), "reinstall is idempotent")

        // Switching build (App Store command) replaces ours, keeps theirs.
        let appStore = try AgentHookConfig.claudeInstalling(into: installed, command: #"/bin/sh "/Users/me/.claude/coucou/nb-hook""#,
                                                            name: "settings.json")
        check(!commands(appStore).contains(ghCmd), "GitHub command replaced")
        for user in userHooks { check(commands(appStore).contains(user), "switch kept \(user)") }

        // Uninstall removes exactly Coucou's hooks.
        let removed = AgentHookConfig.claudeRemoving(from: installed)
        check(removed != nil, "something to remove")
        let removedCommands = commands(removed ?? [:])
        check(!removedCommands.contains { isCoucouHookCommand($0) }, "no Coucou hook left")
        check(Set(removedCommands) == Set(userHooks), "only the user's hooks left: \(removedCommands)")
        check(!coucouHooksPresent(inSettings: removed ?? [:]), "not detected after uninstall")
        // A group shared with the user's hook keeps the user's hook.
        let shared = object("""
        {"hooks":{"Stop":[{"hooks":[{"command":"\\"/u/Library/Application Support/NotchBuddy/nb-hook\\""},
                                    {"command":"/Volumes/x/orca/coucou/my-hook.sh"}]}]}}
        """)
        check(commands(AgentHookConfig.claudeRemoving(from: shared) ?? [:]) == ["/Volumes/x/orca/coucou/my-hook.sh"], "shared group")
        check(AgentHookConfig.claudeRemoving(from: object(#"{"model":"opus"}"#)) == nil, "no hooks object → nothing to do")

        // "hooks" in a shape we do not know is refused, never replaced.
        for bad in [#"{"hooks":[1]}"#, #"{"hooks":{"Stop":"x"}}"#, #"{"hooks":{"PreToolUse":{}}}"#] {
            check(failure { _ = try AgentHookConfig.claudeInstalling(into: object(bad), command: ghCmd, name: "settings.json") }
                  == .unexpectedHooks("settings.json"), "refused: \(bad)")
        }
        // An unknown shape on an event Coucou does not use is left alone.
        let otherShape = try AgentHookConfig.claudeInstalling(into: object(#"{"hooks":{"Custom":"x"}}"#), command: ghCmd, name: "s")
        check((otherShape["hooks"] as? [String: Any])?["Custom"] as? String == "x", "unknown event kept")

        // Escaped slashes in Claude's settings.json, as it has always been written.
        let encodedClaude = String(data: try AgentHookConfig.encoded(["a": "/b"], escapingSlashes: true), encoding: .utf8) ?? ""
        check(encodedClaude.contains(#"\/b"#), "escaped slashes for Claude")
        check(text(["a": "/b"]).contains(#""/b""#), "plain slashes for the others")

        // ── Gemini CLI ──────────────────────────────────────────────────────────
        let geminiUser = object("""
        {"theme":"dark","hooks":{
          "BeforeTool":[{"matcher":"*","hooks":[{"type":"command","command":"/Volumes/x/orca/coucou/my-hook.sh"}]}],
          "AfterAgent":[{"command":"\(base.replacingOccurrences(of: "\"", with: "\\\"")) --agent gemini Stop"}]}}
        """)
        let gemini = try AgentHookConfig.geminiInstalling(into: geminiUser, base: base, name: "~/.gemini/settings.json")
        check(commands(gemini).contains("/Volumes/x/orca/coucou/my-hook.sh"), "gemini kept user hook")
        check(commands(gemini).filter { isCoucouHookCommand($0, agent: "gemini") }.count == AgentHookConfig.geminiEvents.count,
              "gemini: one hook per event, legacy flat entry replaced")
        check(commands(gemini).contains("\(base) --agent gemini PreToolUse"), "gemini normalized event")
        check(AgentHookConfig.hasGeminiHooks(gemini), "gemini detected")
        check(!AgentHookConfig.hasCodexHooks(gemini), "not codex")
        let geminiRemoved = try AgentHookConfig.removingAgentHooks(from: gemini, name: "g")
        check(commands(geminiRemoved) == ["/Volumes/x/orca/coucou/my-hook.sh"], "gemini uninstall keeps user hook")
        check(geminiRemoved["theme"] as? String == "dark", "gemini settings kept")
        let geminiOnlyOurs = try AgentHookConfig.geminiInstalling(into: [:], base: base, name: "g")
        check(try AgentHookConfig.removingAgentHooks(from: geminiOnlyOurs, name: "g")["hooks"] == nil, "emptied hooks removed")
        check(failure { _ = try AgentHookConfig.geminiInstalling(into: object(#"{"hooks":"x"}"#), base: base, name: "~/.gemini/settings.json") }
              == .unexpectedHooks("~/.gemini/settings.json"), "gemini refuses unknown hooks")
        check(failure { _ = try AgentHookConfig.removingAgentHooks(from: object(#"{"hooks":"x"}"#), name: "g") }
              == .unexpectedHooks("g"), "uninstall refuses unknown hooks")
        let untouched = object(#"{"hooks":{},"x":1}"#)
        check(text(try AgentHookConfig.removingAgentHooks(from: untouched, name: "g")) == text(untouched), "nothing of ours: unchanged")

        // ── Antigravity ─────────────────────────────────────────────────────────
        let agy = AgentHookConfig.antigravityInstalling(into: object(#"{"mine":{"PreToolUse":[]}}"#), base: base)
        check(agy["mine"] != nil, "agy kept other keys")
        check(AgentHookConfig.hasAntigravityHooks(agy), "agy detected")
        check(commands(agy).count == 5 && commands(agy).allSatisfy { isCoucouHookCommand($0, agent: "antigravity") }, "agy hooks")
        let agyRemoved = AgentHookConfig.antigravityRemoving(from: agy)
        check(agyRemoved["coucou"] == nil && agyRemoved["mine"] != nil, "agy uninstall")
        check(!AgentHookConfig.hasAntigravityHooks(object(#"{"coucou":{"Stop":[{"command":"/Users/me/coucou/nb-hook"}]}}"#)),
              "agy: a look-alike is not ours")

        // ── Codex ───────────────────────────────────────────────────────────────
        let codex = try AgentHookConfig.codexInstalling(into: object("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/me/NotchBuddy/notify.sh"}]}]}}
        """), base: base, name: "~/.codex/hooks.json")
        check(commands(codex).contains("/Users/me/NotchBuddy/notify.sh"), "codex kept user hook")
        check(AgentHookConfig.hasCodexHooks(codex), "codex detected")
        let codexPermission = ((codex["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.last
        let codexHook = (codexPermission?["hooks"] as? [[String: Any]])?.first
        check(codexHook?["statusMessage"] as? String == "Waiting for your answer in the notch (Coucou)", "codex status message")
        check(codexHook?["timeout"] as? Int == 120, "codex timeout")
        check(commands(try AgentHookConfig.removingAgentHooks(from: codex, name: "c")) == ["/Users/me/NotchBuddy/notify.sh"],
              "codex uninstall")

        // ── Copilot CLI ─────────────────────────────────────────────────────────
        let copilot = try AgentHookConfig.copilotInstalling(into: object("""
        {"hooks":{"preToolUse":[{"type":"command","bash":"~/bin/nb-hook-audit.sh"},
                                {"type":"command","bash":"\(base.replacingOccurrences(of: "\"", with: "\\\"")) --agent copilot preToolUse"}]}}
        """), base: base, name: "~/.copilot/hooks/coucou.json")
        check(copilot["version"] as? Int == 1, "copilot version")
        check(commands(copilot).contains("~/bin/nb-hook-audit.sh"), "copilot kept look-alike user entry")
        check(commands(copilot).filter { isCoucouHookCommand($0, agent: "copilot") }.count == AgentHookConfig.copilotEvents.count,
              "copilot: one entry per event")
        check(AgentHookConfig.hasCopilotHooks(copilot), "copilot detected")
        check(!AgentHookConfig.hasCopilotHooks(object(#"{"hooks":{"x":[{"bash":"~/bin/nb-hook --agent copilot"}]}}"#)),
              "copilot look-alike not detected")

        // ── Muse ────────────────────────────────────────────────────────────────
        let museNew = try AgentHookConfig.museInstalling(into: [:], base: base, name: "m", isNewFile: true)
        check(museNew["schema_version"] as? Int == 1, "muse new file gets schema_version")
        let museExisting = try AgentHookConfig.museInstalling(into: object(#"{"x":1}"#), base: base, name: "m", isNewFile: false)
        check(museExisting["schema_version"] == nil, "existing muse settings: no schema_version")
        let musePermission = ((museNew["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.last
        check(((musePermission?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int) == 120_000, "muse timeout in ms")
        check(AgentHookConfig.hasMuseHooks(museNew), "muse detected")
        check(try AgentHookConfig.removingAgentHooks(from: museNew, name: "m")["hooks"] == nil, "muse uninstall")

        print("Agent hook config: \(count) checks passed")
    }
}
