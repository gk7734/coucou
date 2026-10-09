import Foundation

// MARK: - SessionCardText
//
// What the island's session cards say about the sessions behind a pill (SessionBook):
// which agent, which project, which app, which session to show, and how long a silent
// session has been quiet. Foundation only, so it can be tested without AppKit
// (see scripts/test-session-card-text.sh).

enum SessionCardText {

    /// UserDefaults key of the stall threshold, in minutes (0 = off). Shared with the stall monitor.
    static let stallThresholdKey = "stallThresholdMinutes"
    static let defaultStallThresholdMinutes = 3

    /// "Claude Code", "Codex", or a third-party agent's name capitalised ("gemini" → "Gemini").
    static func agentName(_ agent: String) -> String {
        if let kind = AgentKind(rawValue: agent.lowercased()) { return kind.displayName }
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "Agent" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// "Claude Code · my-api", or just the agent when the project is unknown.
    static func agentAndProject(agent: String, project: String) -> String {
        let name = agentName(agent)
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? name : "\(name) · \(project)"
    }

    /// "Codex in WebStorm", or just the agent when the app isn't worth naming.
    static func who(agent: String, hostName: String?) -> String {
        let name = agentName(agent)
        guard let host = hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
              host.caseInsensitiveCompare(name) != .orderedSame else { return name }
        return String(localized: "\(name) in \(host)")
    }

    /// The grey label next to a session card's title. The title is the pill's name: the
    /// project for VS Code / Cursor / terminal pills, the IDE for IDE pills. Neither the app
    /// nor the project is repeated when the title already says it:
    ///   VS Code pill "my-api"           → "Claude Code"
    ///   Cursor pill "my-api"            → "Codex in Cursor"
    ///   WebStorm pill                   → "Codex · my-api"
    static func subtitle(agent: String, project: String, title: String, hostName: String?) -> String {
        let host = hostName.flatMap { $0.caseInsensitiveCompare(title) == .orderedSame ? nil : $0 }
        let lead = who(agent: agent, hostName: host)
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.isEmpty || project.caseInsensitiveCompare(title) == .orderedSame { return lead }
        return "\(lead) · \(project)"
    }

    // MARK: Which sessions

    /// The sessions as the card lists them: most urgent first, the most recent among equals
    /// (so the book's lead is always the first row).
    static func listOrder(_ book: SessionBook) -> [AgentSession] {
        book.sessions.enumerated().sorted { a, b in
            if a.element.phase.urgency != b.element.phase.urgency {
                return a.element.phase.urgency > b.element.phase.urgency
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The session a card is about: the one with `id` when it is still in the book, else the
    /// most recently active one in `phase` (e.g. the session that just finished), else the lead.
    static func session(in book: SessionBook?, id: String? = nil, phase: SessionPhase? = nil) -> AgentSession? {
        guard let book, !book.isEmpty else { return nil }
        if let id, let s = book.session(id) { return s }
        if let phase,
           let s = book.sessions.filter({ $0.phase == phase }).max(by: { $0.lastEventAt < $1.lastEventAt }) {
            return s
        }
        return book.lead
    }

    // MARK: Stalls

    /// The stall threshold the user set, in minutes; 0 means off. A missing or negative value
    /// reads as the default.
    static func stallThresholdMinutes(_ defaults: UserDefaults = AppDefaults.store) -> Int {
        guard let value = defaults.object(forKey: stallThresholdKey) as? Int, value >= 0 else {
            return defaultStallThresholdMinutes
        }
        return value
    }

    /// Whole minutes a working session has been silent, or nil when it isn't stalled
    /// (same rule as `SessionBook.stalled`: working, no event for the threshold).
    static func stalledMinutes(_ session: AgentSession, now: Date, thresholdMinutes: Int) -> Int? {
        guard thresholdMinutes > 0, session.phase == .working else { return nil }
        let silent = now.timeIntervalSince(session.lastEventAt)
        guard silent >= TimeInterval(thresholdMinutes) * 60 else { return nil }
        return max(1, Int(silent / 60))
    }

    /// "No activity for 4 min".
    static func noActivity(minutes: Int) -> String {
        String(localized: "No activity for \(minutes) min")
    }
}
