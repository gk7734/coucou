import Foundation

// MARK: - NotificationPolicy
//
// Whether a SessionAlert becomes a macOS banner, and what it says. Also the stall-episode
// bookkeeping the StallMonitor relies on. Foundation only, so it can be tested without
// AppKit (see scripts/test-notification-policy.sh); MacNotifier and StallMonitor do the
// AppKit / UserNotifications side.

// MARK: Settings

struct NotificationSettings: Equatable, Sendable {
    static let enabledKey   = "macNotificationsEnabled"
    static let finishedKey  = "notifyFinished"
    static let errorsKey    = "notifyErrors"
    static let waitingKey   = "notifyWaiting"
    static let stalledKey   = "notifyStalled"
    static let stallThresholdKey = "stallThresholdMinutes"
    static let defaultStallMinutes = 3
    /// The choices offered in Settings (0 = off).
    static let stallMinuteChoices = [0, 2, 3, 5, 10]

    var enabled  = true
    var finished = true
    var errors   = true
    /// Approvals and questions.
    var waiting  = true
    var stalled  = true

    init(enabled: Bool = true, finished: Bool = true, errors: Bool = true,
         waiting: Bool = true, stalled: Bool = true) {
        self.enabled = enabled
        self.finished = finished
        self.errors = errors
        self.waiting = waiting
        self.stalled = stalled
    }

    /// Every key defaults to true when absent.
    init(defaults: UserDefaults) {
        func flag(_ key: String) -> Bool { (defaults.object(forKey: key) as? Bool) ?? true }
        self.init(enabled: flag(Self.enabledKey), finished: flag(Self.finishedKey),
                  errors: flag(Self.errorsKey), waiting: flag(Self.waitingKey),
                  stalled: flag(Self.stalledKey))
    }

    func allows(_ kind: SessionAlert.Kind) -> Bool {
        switch kind {
        case .finished:                       finished
        case .error:                          errors
        case .waitingApproval, .waitingAnswer: waiting
        case .stalled:                        stalled
        }
    }

    /// Minutes without an event before a working session counts as stalled; 0 = off.
    static func stallMinutes(defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: stallThresholdKey) as? Int else { return defaultStallMinutes }
        return max(0, value)
    }

    static func stallThreshold(defaults: UserDefaults) -> TimeInterval {
        TimeInterval(stallMinutes(defaults: defaults) * 60)
    }
}

// MARK: Decision

/// What the user can see right now, and the clock.
struct NotificationContext: Equatable, Sendable {
    /// Bundle id of the frontmost app.
    var frontmostBundleId: String?
    /// The pill the island shows expanded, nil when the island isn't expanded.
    var islandPillId: String?
    var now: Date
}

/// How a banner is named, once the AppKit side has looked up the host app.
struct NotificationNames: Equatable, Sendable {
    /// "WebStorm", "VS Code"… nil when unknown.
    var hostName: String?
    /// The pill's name, used when there is no host app.
    var pillName: String
}

struct NotificationPlan: Equatable, Sendable {
    /// One per session: a new banner for the same session replaces the old one.
    var identifier: String
    /// One per pill, so Notification Center groups an IDE's sessions.
    var threadId: String
    var title: String
    var body: String
}

enum NotificationSkipReason: String, Equatable, Sendable {
    case disabled, kindOff, duplicate, hostFrontmost, islandShowsPill
}

enum NotificationDecision: Equatable, Sendable {
    case show(NotificationPlan)
    case skip(NotificationSkipReason)

    /// A skipped alert still means the session moved on: its older banner is out of date.
    /// Only a duplicate leaves it alone (it is that very banner).
    var clearsPrevious: Bool {
        if case .skip(.duplicate) = self { return false }
        return true
    }
}

/// When each (pill, session, kind) was last shown, to fold repeats into one banner.
struct NotificationLedger: Equatable, Sendable {
    static let dedupeWindow: TimeInterval = 5
    private(set) var lastSent: [String: Date] = [:]

    static func key(_ alert: SessionAlert) -> String {
        "\(alert.pillId)|\(alert.sessionId)|\(alert.kind.rawValue)"
    }

    func isDuplicate(_ alert: SessionAlert, now: Date) -> Bool {
        guard let last = lastSent[Self.key(alert)] else { return false }
        return now.timeIntervalSince(last) < Self.dedupeWindow
    }

    mutating func record(_ alert: SessionAlert, now: Date) {
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < Self.dedupeWindow }
        lastSent[Self.key(alert)] = now
    }
}

enum NotificationPolicy {

    static func decide(_ alert: SessionAlert, settings: NotificationSettings,
                       context: NotificationContext, names: NotificationNames,
                       ledger: NotificationLedger) -> NotificationDecision {
        guard settings.enabled else { return .skip(.disabled) }
        guard settings.allows(alert.kind) else { return .skip(.kindOff) }
        if ledger.isDuplicate(alert, now: context.now) { return .skip(.duplicate) }
        if let host = alert.hostBundleId, !host.isEmpty, host == context.frontmostBundleId {
            return .skip(.hostFrontmost)
        }
        if context.islandPillId == alert.pillId { return .skip(.islandShowsPill) }
        return .show(plan(alert, names: names))
    }

    static func plan(_ alert: SessionAlert, names: NotificationNames) -> NotificationPlan {
        NotificationPlan(identifier: identifier(pillId: alert.pillId, sessionId: alert.sessionId),
                         threadId: "coucou.pill.\(alert.pillId)",
                         title: title(alert, names: names),
                         body: body(alert))
    }

    static func identifier(pillId: String, sessionId: String) -> String {
        "coucou.session.\(pillId).\(sessionId)"
    }

    /// "WebStorm · Claude Code". Just one name when both say the same thing.
    static func title(_ alert: SessionAlert, names: NotificationNames) -> String {
        let place = oneLine(names.hostName ?? "").isEmpty ? oneLine(names.pillName) : oneLine(names.hostName ?? "")
        let agent = oneLine(alert.agentName)
        if place.isEmpty { return agent.isEmpty ? "Coucou" : agent }
        if agent.isEmpty || agent.caseInsensitiveCompare(place) == .orderedSame { return place }
        return "\(place) · \(agent)"
    }

    /// "api — finished: All tests pass". The stall alert's detail is already the sentence.
    static func body(_ alert: SessionAlert) -> String {
        let detail = oneLine(alert.detail, limit: 120)
        let what: String
        switch alert.kind {
        case .finished:
            what = detail.isEmpty ? String(localized: "finished") : String(localized: "finished: \(detail)")
        case .error:
            what = detail.isEmpty ? String(localized: "error") : String(localized: "error: \(detail)")
        case .waitingApproval:
            what = detail.isEmpty ? String(localized: "needs your OK") : String(localized: "needs your OK: \(detail)")
        case .waitingAnswer:
            what = detail.isEmpty ? String(localized: "has a question") : String(localized: "asks: \(detail)")
        case .stalled:
            what = detail
        }
        let project = oneLine(alert.projectName, limit: 40)
        if project.isEmpty { return what }
        if what.isEmpty { return project }
        return "\(project) — \(what)"
    }

    /// The stall alert's detail.
    static func stallDetail(minutes: Int) -> String {
        String(localized: "no activity for \(minutes) min")
    }

    /// Whitespace and newlines folded to single spaces, cut with "…" past `limit` characters.
    static func oneLine(_ text: String, limit: Int = 80) -> String {
        let folded = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard folded.count > limit, limit > 1 else { return folded }
        return String(folded.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Out-of-date banners

    /// A banner on screen for a session, as far as its out-of-date check needs.
    struct Delivered: Equatable, Sendable {
        var pillId: String
        var sessionId: String
        var kind: SessionAlert.Kind
        var deliveredAt: Date
        /// For a stall: the session's last event when it stalled.
        var lastEventAt: Date?
    }

    /// A session that just showed up may not be in its book yet: wait this long before a
    /// missing session counts as gone.
    static let missingGrace: TimeInterval = 3

    /// Banners that no longer say what is going on: a session that waited on the user and
    /// moved on, or a stalled one that got a new event. Finished / error banners stay.
    static func outdated(_ banners: [String: Delivered], books: [String: SessionBook],
                         now: Date) -> [String] {
        banners.compactMap { id, banner in
            guard let session = books[banner.pillId]?.session(banner.sessionId) else {
                let waitsOrStalls = banner.kind != .finished && banner.kind != .error
                return waitsOrStalls && now.timeIntervalSince(banner.deliveredAt) >= missingGrace ? id : nil
            }
            switch banner.kind {
            case .finished, .error:  return nil
            case .waitingApproval:   return session.phase == .waitingApproval ? nil : id
            case .waitingAnswer:     return session.phase == .waitingAnswer ? nil : id
            case .stalled:
                let sameEpisode = session.phase == .working
                    && (banner.lastEventAt.map { session.lastEventAt <= $0 } ?? true)
                return sameEpisode ? nil : id
            }
        }.sorted()
    }
}

// MARK: - Stall episodes

struct StalledSession: Equatable, Sendable {
    var pillId: String
    var session: AgentSession
}

struct StallUpdate: Equatable, Sendable {
    /// Sessions that started a stall episode since the last update: one alert each.
    var newlyStalled: [StalledSession] = []
    /// Pills with at least one stalled session right now.
    var stalledPills: Set<String> = []
}

/// Remembers which stall episodes were already reported. An episode is a session and the
/// time of its last event: the same session stalls again only after a new event.
struct StallTracker: Equatable, Sendable {
    /// "pill|session" → the session's lastEventAt when its stall was reported.
    private(set) var reported: [String: Date] = [:]

    mutating func update(books: [String: SessionBook], now: Date, threshold: TimeInterval) -> StallUpdate {
        var result = StallUpdate()
        var alive: Set<String> = []
        for pillId in books.keys.sorted() {
            guard let book = books[pillId] else { continue }
            for session in book.sessions { alive.insert(Self.key(pillId, session.id)) }
            for session in book.stalled(now: now, threshold: threshold) {
                result.stalledPills.insert(pillId)
                let key = Self.key(pillId, session.id)
                if reported[key] != session.lastEventAt {
                    reported[key] = session.lastEventAt
                    result.newlyStalled.append(StalledSession(pillId: pillId, session: session))
                }
            }
        }
        // Forget sessions that are gone; keep the others so the same episode isn't re-reported.
        reported = reported.filter { alive.contains($0.key) }
        return result
    }

    mutating func reset() { reported = [:] }

    /// When a working session that isn't stalled yet will be, or nil when none: the one
    /// timer the monitor arms. `SessionBook.nextStallCheck` also counts sessions already
    /// stalled (a date in the past), which would re-arm the timer forever.
    static func nextCheck(books: [String: SessionBook], now: Date, threshold: TimeInterval) -> Date? {
        guard threshold > 0 else { return nil }
        return books.values
            .flatMap { $0.sessions }
            .filter { $0.phase == .working }
            .map { $0.lastEventAt.addingTimeInterval(threshold) }
            .filter { $0 > now }
            .min()
    }

    private static func key(_ pillId: String, _ sessionId: String) -> String { "\(pillId)|\(sessionId)" }
}
