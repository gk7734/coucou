import Foundation

// MARK: - AutoMainPill
//
// The "Auto" main pill (Settings → Active pills → Main): the workspace pill the user last
// worked in. Workspace pills are the catalog's "Where you code" pills (Claude Code, Cursor,
// Codex, Antigravity) and every IDE's own `ide_…` pill.
// Foundation only (plus HostResolver for `ide_` ids), tested by scripts/test-auto-main-pill.sh.
//
// Anti flip-flop: with two IDEs busy at once, the main follows the user, not the agents.
// A prompt the user sends (UserPromptSubmit) always moves it; an agent's own activity
// (tool use, approval, question) moves it only when the current one has nothing going on.

enum AutoMainPill {

    /// What a session event says about where the user works.
    enum Activity: Equatable, Sendable {
        /// The user sent a prompt there.
        case userPrompt
        /// The agent works there: a tool use, an approval or a question.
        case agent
    }

    /// The activity a hook event stands for; nil for events that don't count
    /// (SessionStart, Stop, SessionEnd, Notification, subagents…).
    /// Approval and question requests arrive on their own path and count as `.agent`.
    static func activity(forEvent name: String) -> Activity? {
        switch name {
        case "UserPromptSubmit":                                return .userPrompt
        case "PreToolUse", "PostToolUse", "PostToolUseFailure": return .agent
        default:                                                return nil
        }
    }

    /// True for the pills the auto main can land on.
    static func isWorkspacePill(_ id: String, catalogWorkspaceIds: Set<String>) -> Bool {
        catalogWorkspaceIds.contains(id) || HostResolver.isIDEPill(id)
    }

    /// Whether an event on `candidate` makes it the last active workspace pill.
    /// - current: the last active workspace pill so far (nil before any).
    /// - currentIsBusy: the current one has a session working or waiting on the user.
    static func shouldSwitch(current: String?, to candidate: String, activity: Activity,
                             currentIsBusy: Bool) -> Bool {
        guard let current, current != candidate else { return current == nil }
        switch activity {
        case .userPrompt: return true
        case .agent:      return !currentIsBusy
        }
    }

    /// The main pill to show.
    /// - explicit: the pill the user picked, nil for Auto. Honoured when it is a catalog
    ///   workspace pill of this build, else Auto applies.
    /// - lastActive / lastActiveBundleId: the last active workspace pill. An `ide_` pill
    ///   needs its IDE's bundle id (its id can't be turned back into one) to be shown.
    /// - fallback: before anything was active (or when it no longer can be shown).
    /// `isInstalled` answers for an IDE pill's app: a remembered IDE that has since been
    /// uninstalled (or was never on this Mac) is not brought back as the main pill.
    static func resolve(explicit: String?, lastActive: String?, lastActiveBundleId: String?,
                        catalogWorkspaceIds: Set<String>, fallback: String,
                        isInstalled: (String) -> Bool = { _ in true }) -> String {
        if let explicit, catalogWorkspaceIds.contains(explicit) { return explicit }
        if let last = lastActive {
            if catalogWorkspaceIds.contains(last) { return last }
            if HostResolver.isIDEPill(last), let bundle = lastActiveBundleId, !bundle.isEmpty,
               HostResolver.idePillId(bundleId: bundle) == last, isInstalled(bundle) {
                return last
            }
        }
        return fallback
    }
}
