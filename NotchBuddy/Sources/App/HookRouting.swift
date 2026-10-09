import Foundation

// MARK: - HookRouting
//
// Where a hook event goes, decided in one place for every kind of event (plain events,
// permission requests, questions):
//   - the pill it lands on and the agent behind it (HookRoute),
//   - what it does to its session (SessionChange) and how a session phase shows on Mochi,
//   - whether an approval / question card is shown in the notch.
// Foundation only, on top of HostResolver and SessionBook, so it can be tested without
// AppKit (see scripts/test-hook-routing.sh).

struct HookRoute: Equatable, Sendable {
    let pillId: String
    /// Claude Code or Codex; nil for a third-party agent routed by `coucou_agent`.
    let agentKind: AgentKind?
    /// The validated `coucou_agent` of a third-party agent, nil otherwise.
    let externalAgent: String?
    /// The app the session runs in, when known. Third-party agents keep their own pill, the
    /// host is only recorded for them (alerts).
    let host: HostIdentity?

    var isExternalAgent: Bool { externalAgent != nil }
    /// The session has an IDE pill of its own (`ide_…`).
    var isIDE: Bool { HostResolver.isIDEPill(pillId) }
    /// "claude", "codex" or the third-party agent's name (SessionBook's `agent`).
    var agentName: String { externalAgent ?? agentKind?.rawValue ?? AgentKind.claude.rawValue }
}

enum HookRouting {

    // MARK: Payload keys

    /// Added by the app to every payload before routing: the regular apps above the relay
    /// in the process tree, nearest first (ProcessAncestry).
    static let hostBundleIdsKey = "coucou_host_bundle_ids"
    /// DEBUG builds only: a bundle id that replaces the process-tree result ("" = no app),
    /// so recorded payloads can be replayed as if they came from another host.
    static let hostOverrideKey = "coucou_host_override"

    // MARK: Agents

    /// Validates a coucou_agent name: lowercase, digits and hyphens, 1–24 chars.
    /// "claude" is reserved and rejected so it cannot impersonate the Claude Code pill.
    static func validateAgent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24, raw != "claude" else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)   // a-z
                  || (v >= 0x30 && v <= 0x39)   // 0-9
                  || v == 0x2D                   // -
            guard ok else { return nil }
        }
        return raw
    }

    /// Agents' own apps. A session found running inside one stays on that agent's pill
    /// rather than getting an IDE pill of its own.
    static let codexAppBundleId = "com.openai.codex"
    static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    // MARK: Route

    /// The pill of an event, or nil when it is ignored (a Claude Code session with no
    /// identifiable host, as before).
    /// - `codexSupported`: false in the App Store build, where Codex is an ordinary
    ///   third-party agent (its own pill, no cards).
    static func route(coucouAgent: String, codexSupported: Bool,
                      payloadBundleId: String, termProgram: String, terminalEmulator: String,
                      ancestorBundleIds: [String]) -> HookRoute? {
        let host = HostResolver.resolve(payloadBundleId: payloadBundleId, termProgram: termProgram,
                                        terminalEmulator: terminalEmulator,
                                        ancestorBundleIds: ancestorBundleIds)
        // Codex: its IDE's pill inside an IDE, else its own pill (terminal, Codex app, unknown).
        if codexSupported && coucouAgent == "codex" {
            let pill = host?.bundleId == codexAppBundleId
                ? "agent_codex"
                : (HostResolver.pillId(agent: .codex, host: host) ?? "agent_codex")
            return HookRoute(pillId: pill, agentKind: .codex, externalAgent: nil, host: host)
        }
        // Any other valid coucou_agent: the agent's own pill, exactly as before.
        if let agent = validateAgent(coucouAgent) {
            return HookRoute(pillId: "agent_\(agent)", agentKind: nil, externalAgent: agent, host: host)
        }
        // Claude Code. Inside the Claude desktop app it belongs to that app's pill
        // (the relay usually tags those sessions "claude-desktop" already).
        if host?.bundleId == claudeDesktopBundleId {
            return HookRoute(pillId: "agent_claude-desktop", agentKind: nil,
                             externalAgent: "claude-desktop", host: host)
        }
        guard let pill = HostResolver.pillId(agent: .claude, host: host) else { return nil }
        return HookRoute(pillId: pill, agentKind: .claude, externalAgent: nil, host: host)
    }

    /// `route(...)` from a hook payload (after the app added `coucou_host_bundle_ids`).
    static func route(payload: [String: Any], codexSupported: Bool) -> HookRoute? {
        route(coucouAgent: payload["coucou_agent"] as? String ?? "",
              codexSupported: codexSupported,
              payloadBundleId: payload["bundle_id"] as? String ?? "",
              termProgram: payload["term_program"] as? String ?? "",
              terminalEmulator: payload["terminal_emulator"] as? String ?? "",
              ancestorBundleIds: payload[hostBundleIdsKey] as? [String] ?? [])
    }

    // MARK: Sessions

    /// `session_id`, else `conversation_id` (Codex), else "unknown" — the id the approval
    /// queue matches requests on.
    static func rawSessionId(_ payload: [String: Any]) -> String {
        let id = payload["session_id"] as? String ?? payload["conversation_id"] as? String ?? ""
        return id.isEmpty ? "unknown" : id
    }

    /// The session's key in SessionBook and RecapStore: the raw id, or `<pillId>+<cwd>` for
    /// sessions without one so that anonymous sessions in different folders stay apart.
    static func sessionKey(rawSessionId: String, pillId: String, cwd: String) -> String {
        (rawSessionId.isEmpty || rawSessionId == "unknown") ? "\(pillId)+\(cwd)" : rawSessionId
    }

    /// What an event does to its session.
    enum SessionChange: Equatable {
        /// Records the event; nil keeps the current phase (a new session starts working).
        case record(SessionPhase?)
        /// Stop: the turn ended.
        case finish
        /// SessionEnd: the session is gone.
        case remove
        /// Not a session event.
        case none
    }

    /// The session change for a hook event. `waiting` is the phase of a request this session
    /// still holds open (approval or question): its other events must not hide it.
    static func sessionChange(event: String, tool: String = "", waiting: SessionPhase? = nil) -> SessionChange {
        let change: SessionChange
        switch event {
        case "SessionStart":
            change = .record(.idle)
        case "PreToolUse" where tool == "AskUserQuestion":
            change = .record(nil)          // the question card sets the phase
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
             "SubagentStart", "SubagentStop", "PreCompact":
            change = .record(.working)
        case "Notification":
            change = .record(nil)
        case "StopFailure":
            change = .record(.error)
        case "Interrupt":
            change = .record(.idle)
        case "Stop":
            change = .finish
        case "SessionEnd":
            change = .remove
        default:
            change = .none
        }
        if let waiting, case .record(let phase) = change, phase != .error {
            return .record(waiting)
        }
        return change
    }

    /// How a session phase shows on the pill's Mochi.
    static func botState(for phase: SessionPhase) -> BotState {
        switch phase {
        case .working:         .working
        case .waitingApproval: .approval
        case .waitingAnswer:   .question
        case .error:           .error
        case .finished:        .finished
        case .idle:            .idle
        }
    }

    // MARK: Mirroring a book onto its pill

    /// How the pill's task follows its SessionBook after an event.
    struct MirrorPlan: Equatable {
        /// The event's own effects on the task (state, view, badge) apply: its session
        /// leads the pill. Events of other sessions only update the book.
        let applyEvent: Bool
        /// The lead changed: the task's state is reset from the new lead's phase.
        let resetState: Bool
    }

    static func mirrorPlan(eventSession: String, leadBefore: String?, leadAfter: String?) -> MirrorPlan {
        MirrorPlan(applyEvent: leadAfter == eventSession,
                   resetState: leadAfter != nil && leadAfter != leadBefore)
    }

    // MARK: Cards

    enum CardKind { case approval, question }

    /// Whether a permission request / question gets a card in the notch. Without one the
    /// app answers "ask" at once and the agent asks in its own window.
    /// - IDE sessions (VS Code, Cursor, any other IDE) always get it.
    /// - Terminal sessions only when the user turned terminal cards on.
    /// - Codex (GitHub build) always, as before.
    /// - Third-party agents: approvals only, for the agents in `externalApprovalAgents`.
    static func showsCard(_ kind: CardKind, route: HookRoute, terminalCardsEnabled: Bool,
                          externalApprovalAgents: Set<String>) -> Bool {
        if let agent = route.externalAgent {
            return kind == .approval && externalApprovalAgents.contains(agent)
        }
        if route.agentKind == .codex { return true }
        switch route.host?.kind {
        case .vscode?, .cursor?, .ide?: return true
        case .terminal?:                return terminalCardsEnabled
        case nil:                       return false
        }
    }

    /// Seconds the app waits on an approval before giving up (the relay waits 118 s).
    /// Copilot and Muse leave less margin before their own hook timeout.
    static func approvalTimeout(route: HookRoute) -> Double {
        route.externalAgent == "copilot" || route.externalAgent == "muse" ? 110 : 115
    }

    // MARK: IDE pills

    /// The colour an IDE pill gets until the user picks one: a palette colour chosen by a
    /// stable hash of the pill id, so it is the same on every launch.
    static func defaultIDEColor(pillId: String) -> String {
        let palette = PillColors.palette
        return palette[Int(IslandConst.stableHash(pillId) % UInt64(palette.count))]
    }
}
