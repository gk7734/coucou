import Foundation

// MARK: - SessionBook
//
// The sessions behind one pill. A pill used to mirror a single session, so two Claude Code
// sessions in the same IDE overwrote each other; now each pill keeps a book of sessions and
// the pill's own state is derived from them (most urgent first).
// Foundation only, so it can be tested without AppKit (see scripts/test-session-book.sh).

enum SessionPhase: String, Equatable, Sendable {
    case working          // events are flowing
    case waitingApproval  // a PermissionRequest waits on the user
    case waitingAnswer    // an AskUserQuestion waits on the user
    case error
    case finished
    case idle

    /// Higher wins when several sessions share a pill.
    var urgency: Int {
        switch self {
        case .waitingApproval: 6
        case .waitingAnswer:   5
        case .error:           4
        case .working:         3
        case .finished:        2
        case .idle:            1
        }
    }

    /// The user is the one holding it up, so silence is not a stall.
    var waitsOnUser: Bool { self == .waitingApproval || self == .waitingAnswer }
}

struct AgentSession: Identifiable, Equatable, Sendable {
    /// `session_id` from the hook, or `<pillId>+<cwd>` for sessions without one.
    let id: String
    /// "claude", "codex", or a third-party agent name.
    var agent: String
    var projectName: String
    var cwd: String
    var phase: SessionPhase
    var steps: [String] = []
    var finalLine: String? = nil
    var startedAt: Date
    var lastEventAt: Date

    static let maxSteps = 20
}

struct SessionBook: Equatable, Sendable {
    /// Most recently active first.
    private(set) var sessions: [AgentSession] = []

    /// Sessions that ended (finished / error / idle) are dropped after this long, so the list
    /// shows what is going on now rather than the whole day.
    static let endedRetention: TimeInterval = 10 * 60
    /// A working session with no event for this long was abandoned (the agent crashed or was
    /// killed without SessionEnd): it is dropped instead of showing "working" for good.
    /// Long tool runs (a build, a test suite) stay well under it; the next event brings the
    /// session back anyway.
    static let abandonedAfter: TimeInterval = 60 * 60
    /// Hard cap per pill.
    static let maxSessions = 8

    init(sessions: [AgentSession] = []) { self.sessions = sessions }

    var isEmpty: Bool { sessions.isEmpty }
    var count: Int { sessions.count }

    func session(_ id: String) -> AgentSession? { sessions.first { $0.id == id } }

    /// The session the pill shows: the most urgent one, the most recent among equals.
    var lead: AgentSession? {
        sessions.enumerated().max { a, b in
            if a.element.phase.urgency != b.element.phase.urgency {
                return a.element.phase.urgency < b.element.phase.urgency
            }
            return a.offset > b.offset   // earlier in the list = more recent = wins
        }?.element
    }

    /// The pill's phase: the lead session's, or idle when there is none.
    var phase: SessionPhase { lead?.phase ?? .idle }

    // MARK: Events

    /// Records an event for a session, creating it when new, and moves it to the front.
    /// `phase` nil keeps the session's current phase (e.g. a Notification that only adds a step).
    mutating func record(id: String, agent: String, projectName: String, cwd: String,
                         phase: SessionPhase?, step: String? = nil, at now: Date) {
        var session: AgentSession
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            session = sessions.remove(at: idx)
            session.agent = agent
            if !projectName.isEmpty { session.projectName = projectName }
            if !cwd.isEmpty { session.cwd = cwd }
        } else {
            session = AgentSession(id: id, agent: agent, projectName: projectName, cwd: cwd,
                                   phase: phase ?? .working, startedAt: now, lastEventAt: now)
        }
        if let phase {
            if phase == .working && session.phase != .working { session.finalLine = nil }
            session.phase = phase
        }
        if let step, !step.isEmpty {
            session.steps.append(step)
            if session.steps.count > AgentSession.maxSteps {
                session.steps.removeFirst(session.steps.count - AgentSession.maxSteps)
            }
        }
        session.lastEventAt = now
        sessions.insert(session, at: 0)
        trim(now: now)
    }

    mutating func finish(id: String, finalLine: String?, at now: Date) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].phase = .finished
        if let finalLine, !finalLine.isEmpty { sessions[idx].finalLine = finalLine }
        sessions[idx].lastEventAt = now
    }

    /// Sets a phase without counting as activity (e.g. finished → idle after the finish view).
    mutating func setPhase(id: String, _ phase: SessionPhase) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].phase = phase
    }

    /// SessionEnd: the session is gone.
    mutating func remove(id: String) { sessions.removeAll { $0.id == id } }

    /// Moves a session to the front without changing it (the user picked it in the list).
    mutating func bringToFront(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.insert(sessions.remove(at: idx), at: 0)
    }

    /// Drops ended sessions past their retention, abandoned working ones, and keeps the
    /// newest `maxSessions`. Sessions that wait on the user are never dropped.
    mutating func trim(now: Date) {
        sessions.removeAll { s in
            guard let expiry = Self.expiry(of: s) else { return false }
            return now > expiry
        }
        while sessions.count > Self.maxSessions,
              let idx = sessions.lastIndex(where: { !$0.phase.waitsOnUser }) {
            sessions.remove(at: idx)
        }
    }

    /// When a session will be dropped by `trim`, nil for one waiting on the user.
    static func expiry(of session: AgentSession) -> Date? {
        switch session.phase {
        case .finished, .error, .idle: session.lastEventAt.addingTimeInterval(endedRetention)
        case .working:                 session.lastEventAt.addingTimeInterval(abandonedAfter)
        case .waitingApproval, .waitingAnswer: nil
        }
    }

    /// The next time `trim` would drop something, nil when nothing can expire
    /// (the app schedules one check for it, and none at all for an empty book).
    var nextExpiry: Date? { sessions.compactMap(Self.expiry(of:)).min() }

    // MARK: Stalls

    /// Working sessions with no event for `threshold` seconds. Sessions waiting on the user
    /// are not stalled: the agent is waiting on purpose.
    func stalled(now: Date, threshold: TimeInterval) -> [AgentSession] {
        guard threshold > 0 else { return [] }
        return sessions.filter { $0.phase == .working && now.timeIntervalSince($0.lastEventAt) >= threshold }
    }

    /// When the next stall check is worth doing, or nil when nothing is working
    /// (no timer at all then: 0 % CPU when idle).
    func nextStallCheck(threshold: TimeInterval) -> Date? {
        guard threshold > 0 else { return nil }
        return sessions.filter { $0.phase == .working }
            .map { $0.lastEventAt.addingTimeInterval(threshold) }
            .min()
    }
}
