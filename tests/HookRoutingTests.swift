import Foundation

// HookRouting (App/HookRouting.swift): which pill a hook event lands on, what it does to its
// session, how a pill follows its sessions, and which requests get a card.

/// Stand-in for BotEngine's `EyeShape` (SwiftUI file): IslandTypes only stores it.
enum EyeShape: String { case normal }

@main @MainActor
enum HookRoutingTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let webStorm = "com.jetbrains.WebStorm"
    static let vscode = "com.microsoft.VSCode"
    static let cursor = HostResolver.cursorBundleId
    static let iterm = "com.googlecode.iterm2"

    static func route(agent: String = "", codex: Bool = true, bundle: String = "", term: String = "",
                      emulator: String = "", ancestors: [String] = []) -> HookRoute? {
        HookRouting.route(coucouAgent: agent, codexSupported: codex, payloadBundleId: bundle,
                          termProgram: term, terminalEmulator: emulator, ancestorBundleIds: ancestors)
    }

    static func main() {
        print("Claude Code")
        check("VS Code → integration_claude", route(ancestors: [vscode])?.pillId == "integration_claude")
        check("VS Code by TERM_PROGRAM → integration_claude", route(term: "vscode")?.pillId == "integration_claude")
        check("Cursor → agent_cursor", route(ancestors: [cursor])?.pillId == "agent_cursor")
        check("Cursor by bundle id → agent_cursor", route(bundle: cursor, term: "vscode")?.pillId == "agent_cursor")
        check("iTerm → integration_claude", route(ancestors: [iterm])?.pillId == "integration_claude")
        check("WebStorm → its own pill", route(ancestors: [webStorm])?.pillId == "ide_com-jetbrains-webstorm")
        check("Zed → its own pill", route(term: "zed")?.pillId == "ide_dev-zed-zed")
        check("JetBrains terminal without bundle id → JetBrains pill",
              route(emulator: "JetBrains-JediTerm")?.pillId == HostResolver.idePillId(bundleId: HostResolver.jetBrainsFallbackId))
        check("a new editor → its own pill", route(ancestors: ["app.gram.Gram"])?.pillId == "ide_app-gram-gram")
        check("process tree beats the inherited bundle id",
              route(bundle: "com.apple.Terminal", ancestors: ["com.jetbrains.pycharm"])?.pillId == "ide_com-jetbrains-pycharm")
        check("no host → ignored", route(term: "tmux") == nil)
        let ws = route(ancestors: [webStorm])
        check("IDE route flags", ws?.isIDE == true && ws?.isExternalAgent == false && ws?.agentKind == .claude)
        check("IDE route keeps the host", ws?.host == HostIdentity(bundleId: webStorm, kind: .ide))
        check("agent name claude", ws?.agentName == "claude")
        check("Claude inside the Claude desktop app → its pill, as a third-party agent",
              route(ancestors: [HookRouting.claudeDesktopBundleId]).map { $0.pillId == "agent_claude-desktop" && $0.isExternalAgent } == true)
        check("terminal route is not IDE", route(ancestors: [iterm])?.isIDE == false)
        check("VS Code route is not an ide_ pill", route(ancestors: [vscode])?.isIDE == false)

        print("Codex")
        check("terminal → agent_codex", route(agent: "codex", ancestors: [iterm])?.pillId == "agent_codex")
        check("no host → agent_codex", route(agent: "codex")?.pillId == "agent_codex")
        check("Codex app → agent_codex", route(agent: "codex", ancestors: [HookRouting.codexAppBundleId])?.pillId == "agent_codex")
        check("WebStorm → the WebStorm pill", route(agent: "codex", ancestors: [webStorm])?.pillId == "ide_com-jetbrains-webstorm")
        check("VS Code → integration_claude (pills are per IDE)",
              route(agent: "codex", ancestors: [vscode])?.pillId == "integration_claude")
        check("Codex route", route(agent: "codex")?.agentKind == .codex && route(agent: "codex")?.agentName == "codex")
        let store = route(agent: "codex", codex: false, ancestors: [webStorm])
        check("App Store build: Codex is a third-party agent on its own pill",
              store?.pillId == "agent_codex" && store?.isExternalAgent == true)

        print("Third-party agents (unchanged)")
        let gemini = route(agent: "gemini", ancestors: [webStorm])
        check("gemini → agent_gemini even in an IDE", gemini?.pillId == "agent_gemini")
        check("gemini is external and keeps its host", gemini?.isExternalAgent == true && gemini?.host?.bundleId == webStorm)
        check("gemini agent name", gemini?.agentName == "gemini")
        check("claude-desktop", route(agent: "claude-desktop")?.pillId == "agent_claude-desktop")
        check("\"claude\" is reserved", route(agent: "claude", ancestors: [webStorm])?.pillId == "ide_com-jetbrains-webstorm")
        check("invalid agent falls back to Claude routing", route(agent: "Bad Agent!", ancestors: [iterm])?.pillId == "integration_claude")
        check("validateAgent", HookRouting.validateAgent("my-agent2") == "my-agent2"
              && HookRouting.validateAgent("") == nil
              && HookRouting.validateAgent(String(repeating: "a", count: 25)) == nil
              && HookRouting.validateAgent("Agent") == nil)

        print("Payload")
        let payload: [String: Any] = [
            "coucou_agent": "", "bundle_id": "com.apple.Terminal", "term_program": "Apple_Terminal",
            "terminal_emulator": "", HookRouting.hostBundleIdsKey: [webStorm],
        ]
        check("route(payload:) reads coucou_host_bundle_ids",
              HookRouting.route(payload: payload, codexSupported: true)?.pillId == "ide_com-jetbrains-webstorm")
        check("route(payload:) reads terminal_emulator",
              HookRouting.route(payload: ["terminal_emulator": "JetBrains-JediTerm"], codexSupported: true)?.isIDE == true)
        check("raw session id", HookRouting.rawSessionId(["session_id": "s1"]) == "s1")
        check("conversation_id (Codex)", HookRouting.rawSessionId(["conversation_id": "c1"]) == "c1")
        check("no id → unknown", HookRouting.rawSessionId([:]) == "unknown"
              && HookRouting.rawSessionId(["session_id": ""]) == "unknown")
        check("session key = id", HookRouting.sessionKey(rawSessionId: "s1", pillId: "p", cwd: "/x") == "s1")
        check("anonymous session key = pill+cwd",
              HookRouting.sessionKey(rawSessionId: "unknown", pillId: "ide_x", cwd: "/a") == "ide_x+/a")

        print("Session changes")
        check("SessionStart → idle", HookRouting.sessionChange(event: "SessionStart") == .record(.idle))
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop"] {
            check("\(event) → working", HookRouting.sessionChange(event: event, tool: "Bash") == .record(.working))
        }
        check("PreToolUse AskUserQuestion keeps the phase",
              HookRouting.sessionChange(event: "PreToolUse", tool: "AskUserQuestion") == .record(nil))
        check("Notification keeps the phase", HookRouting.sessionChange(event: "Notification") == .record(nil))
        check("StopFailure → error", HookRouting.sessionChange(event: "StopFailure") == .record(.error))
        check("Interrupt → idle", HookRouting.sessionChange(event: "Interrupt") == .record(.idle))
        check("Stop → finish", HookRouting.sessionChange(event: "Stop") == .finish)
        check("SessionEnd → remove", HookRouting.sessionChange(event: "SessionEnd") == .remove)
        check("unknown event → none", HookRouting.sessionChange(event: "Whatever") == .none)
        check("a waiting session stays waiting on its other events",
              HookRouting.sessionChange(event: "PostToolUse", tool: "Read", waiting: .waitingApproval) == .record(.waitingApproval))
        check("…even on a Notification", HookRouting.sessionChange(event: "Notification", waiting: .waitingAnswer) == .record(.waitingAnswer))
        check("…but an error still shows", HookRouting.sessionChange(event: "StopFailure", waiting: .waitingApproval) == .record(.error))
        check("…and Stop still finishes", HookRouting.sessionChange(event: "Stop", waiting: .waitingApproval) == .finish)

        print("Phase → Mochi")
        check("working", HookRouting.botState(for: .working) == .working)
        check("waitingApproval", HookRouting.botState(for: .waitingApproval) == .approval)
        check("waitingAnswer", HookRouting.botState(for: .waitingAnswer) == .question)
        check("error", HookRouting.botState(for: .error) == .error)
        check("finished", HookRouting.botState(for: .finished) == .finished)
        check("idle", HookRouting.botState(for: .idle) == .idle)

        print("Mirroring")
        check("the only session leads: its event applies",
              HookRouting.mirrorPlan(eventSession: "a", leadBefore: "a", leadAfter: "a")
                == .init(applyEvent: true, resetState: false))
        check("a new session takes the lead",
              HookRouting.mirrorPlan(eventSession: "b", leadBefore: "a", leadAfter: "b")
                == .init(applyEvent: true, resetState: true))
        check("another session's event does not touch the pill",
              HookRouting.mirrorPlan(eventSession: "b", leadBefore: "a", leadAfter: "a")
                == .init(applyEvent: false, resetState: false))
        check("the lead finishing hands over to a working session",
              HookRouting.mirrorPlan(eventSession: "a", leadBefore: "a", leadAfter: "b")
                == .init(applyEvent: false, resetState: true))
        check("first session of a pill", HookRouting.mirrorPlan(eventSession: "a", leadBefore: nil, leadAfter: "a")
                == .init(applyEvent: true, resetState: true))
        check("book emptied", HookRouting.mirrorPlan(eventSession: "a", leadBefore: "a", leadAfter: nil)
                == .init(applyEvent: false, resetState: false))

        // Two Claude Code sessions in one WebStorm, end to end on a SessionBook.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var book = SessionBook()
        func apply(_ session: String, _ event: String, at offset: TimeInterval, waiting: SessionPhase? = nil) -> HookRouting.MirrorPlan {
            let before = book.lead?.id
            switch HookRouting.sessionChange(event: event, tool: "Bash", waiting: waiting) {
            case .record(let phase):
                book.record(id: session, agent: "claude", projectName: session, cwd: "/\(session)",
                            phase: phase, step: event, at: t0.addingTimeInterval(offset))
            case .finish: book.finish(id: session, finalLine: "done", at: t0.addingTimeInterval(offset))
            case .remove: book.remove(id: session)
            case .none: break
            }
            return HookRouting.mirrorPlan(eventSession: session, leadBefore: before, leadAfter: book.lead?.id)
        }
        _ = apply("api", "UserPromptSubmit", at: 0)
        _ = apply("web", "UserPromptSubmit", at: 1)
        check("two sessions on one pill are both kept", book.count == 2)
        check("most recent working session leads", book.lead?.id == "web")
        book.record(id: "api", agent: "claude", projectName: "api", cwd: "/api", phase: .waitingApproval, at: t0.addingTimeInterval(2))
        let plan = apply("web", "PreToolUse", at: 3)
        check("a waiting approval keeps the lead over the other session's work",
              book.lead?.id == "api" && plan == .init(applyEvent: false, resetState: false))
        let finished = apply("web", "Stop", at: 4)
        check("the other session finishing does not touch the pill", !finished.applyEvent && book.session("web")?.phase == .finished)
        book.setPhase(id: "api", .working)
        check("approval answered: api leads again (working beats finished)", book.lead?.id == "api")
        _ = apply("api", "SessionEnd", at: 5)
        check("SessionEnd leaves the other session", book.count == 1 && book.lead?.id == "web")

        print("Cards")
        let none: Set<String> = []
        func card(_ kind: HookRouting.CardKind, _ r: HookRoute?, terminalCards: Bool = false,
                  external: Set<String> = none) -> Bool {
            guard let r else { return false }
            return HookRouting.showsCard(kind, route: r, terminalCardsEnabled: terminalCards, externalApprovalAgents: external)
        }
        check("VS Code approval", card(.approval, route(ancestors: [vscode])))
        check("Cursor question", card(.question, route(ancestors: [cursor])))
        check("IDE approval, terminal cards off", card(.approval, route(ancestors: [webStorm])))
        check("IDE question, terminal cards off", card(.question, route(ancestors: [webStorm])))
        check("terminal approval needs the setting", !card(.approval, route(ancestors: [iterm]))
              && card(.approval, route(ancestors: [iterm]), terminalCards: true))
        check("terminal question needs the setting", !card(.question, route(ancestors: [iterm]))
              && card(.question, route(ancestors: [iterm]), terminalCards: true))
        check("Codex in a terminal", card(.approval, route(agent: "codex", ancestors: [iterm])))
        check("Codex in an IDE", card(.approval, route(agent: "codex", ancestors: [webStorm])))
        check("Copilot approval when allowed", card(.approval, route(agent: "copilot"), external: ["copilot"]))
        check("Copilot question never", !card(.question, route(agent: "copilot"), external: ["copilot"]))
        check("Gemini approval never", !card(.approval, route(agent: "gemini", ancestors: [webStorm]), external: ["copilot"]))
        check("Claude desktop never", !card(.approval, route(ancestors: [HookRouting.claudeDesktopBundleId])))
        check("App Store Codex never", !card(.approval, route(agent: "codex", codex: false), external: []))
        check("approval timeout", HookRouting.approvalTimeout(route: route(agent: "copilot")!) == 110
              && HookRouting.approvalTimeout(route: route(agent: "muse")!) == 110
              && HookRouting.approvalTimeout(route: route(ancestors: [webStorm])!) == 115)

        print("IDE pill colour")
        let color = HookRouting.defaultIDEColor(pillId: "ide_com-jetbrains-webstorm")
        check("from the palette", PillColors.palette.contains(color))
        check("stable", color == HookRouting.defaultIDEColor(pillId: "ide_com-jetbrains-webstorm"))
        let spread = Set((0..<40).map { HookRouting.defaultIDEColor(pillId: "ide_app-\($0)") })
        check("spread over the palette", spread.count > 3)
        check("a user colour wins", PillColors.color(for: "ide_x", catalogColor: HookRouting.defaultIDEColor(pillId: "ide_x"),
                                                     in: ["ide_x": "#F4505E"]) == "#F4505E")

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
