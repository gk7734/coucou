import Foundation

// NotificationPolicy (App/NotificationPolicy.swift): which session alerts become macOS
// banners and what they say, out-of-date banners, and stall episodes.

@main @MainActor
enum NotificationPolicyTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func alert(_ kind: SessionAlert.Kind, pill: String = "ide_com-jetbrains-webstorm",
                      session: String = "s1", host: String? = "com.jetbrains.WebStorm",
                      project: String = "api", detail: String = "All tests pass") -> SessionAlert {
        SessionAlert(kind: kind, pillId: pill, sessionId: session, agentName: "Claude Code",
                     projectName: project, hostBundleId: host, detail: detail)
    }

    static let names = NotificationNames(hostName: "WebStorm", pillName: "WebStorm")
    static func context(front: String? = "com.apple.Safari", island: String? = nil, now: Date = at(0)) -> NotificationContext {
        NotificationContext(frontmostBundleId: front, islandPillId: island, now: now)
    }

    static func decide(_ a: SessionAlert, _ s: NotificationSettings = .init(),
                       _ c: NotificationContext = context(), ledger: NotificationLedger = .init()) -> NotificationDecision {
        NotificationPolicy.decide(a, settings: s, context: c, names: names, ledger: ledger)
    }

    static func shown(_ d: NotificationDecision) -> NotificationPlan? {
        if case .show(let plan) = d { return plan }
        return nil
    }

    static func main() {
        print("text")
        let plan = shown(decide(alert(.finished)))
        check("title is host · agent", plan?.title == "WebStorm · Claude Code")
        check("finished body", plan?.body == "api — finished: All tests pass")
        check("needs your OK", NotificationPolicy.body(alert(.waitingApproval, detail: "rm -rf build")) == "api — needs your OK: rm -rf build")
        check("asks", NotificationPolicy.body(alert(.waitingAnswer, detail: "Which DB?")) == "api — asks: Which DB?")
        check("error", NotificationPolicy.body(alert(.error, detail: "rate limited")) == "api — error: rate limited")
        check("empty detail", NotificationPolicy.body(alert(.finished, detail: "")) == "api — finished")
        check("empty project", NotificationPolicy.body(alert(.error, project: "", detail: "boom")) == "error: boom")
        check("stall sentence", NotificationPolicy.body(alert(.stalled, detail: NotificationPolicy.stallDetail(minutes: 3))) == "api — no activity for 3 min")
        let long = String(repeating: "word ", count: 60) + "\nsecond line"
        let body = NotificationPolicy.body(alert(.finished, detail: long))
        check("one line", !body.contains("\n"))
        check("cut with an ellipsis", body.hasSuffix("…") && body.count < 200)
        check("pill name without host",
              NotificationPolicy.title(alert(.finished, host: nil), names: .init(hostName: nil, pillName: "VS Code")) == "VS Code · Claude Code")
        check("no doubled name",
              NotificationPolicy.title(SessionAlert(kind: .finished, pillId: "agent_codex", sessionId: "x", agentName: "Codex",
                                                    projectName: "", hostBundleId: nil, detail: ""),
                                       names: .init(hostName: nil, pillName: "Codex")) == "Codex")
        check("identifier per session", plan?.identifier == "coucou.session.ide_com-jetbrains-webstorm.s1")
        check("same session, same identifier", shown(decide(alert(.error)))?.identifier == plan?.identifier)
        check("other session, other identifier", shown(decide(alert(.finished, session: "s2")))?.identifier != plan?.identifier)
        check("thread per pill", plan?.threadId == "coucou.pill.ide_com-jetbrains-webstorm")

        print("suppression")
        check("master off", decide(alert(.finished), .init(enabled: false)) == .skip(.disabled))
        check("finished off", decide(alert(.finished), .init(finished: false)) == .skip(.kindOff))
        check("errors off", decide(alert(.error), .init(errors: false)) == .skip(.kindOff))
        check("waiting off covers approvals", decide(alert(.waitingApproval), .init(waiting: false)) == .skip(.kindOff))
        check("waiting off covers questions", decide(alert(.waitingAnswer), .init(waiting: false)) == .skip(.kindOff))
        check("stalled off", decide(alert(.stalled), .init(stalled: false)) == .skip(.kindOff))
        check("other kinds unaffected", shown(decide(alert(.error), .init(finished: false))) != nil)
        check("host app in front", decide(alert(.finished), .init(), context(front: "com.jetbrains.WebStorm")) == .skip(.hostFrontmost))
        check("no host: frontmost doesn't matter", shown(decide(alert(.finished, host: nil), .init(), context(front: nil))) != nil)
        check("island shows the pill", decide(alert(.finished), .init(), context(island: "ide_com-jetbrains-webstorm")) == .skip(.islandShowsPill))
        check("island shows another pill", shown(decide(alert(.finished), .init(), context(island: "integration_claude"))) != nil)

        print("dedupe")
        var ledger = NotificationLedger()
        ledger.record(alert(.finished), now: at(0))
        check("same alert 2 s later folded", decide(alert(.finished), .init(), context(now: at(2)), ledger: ledger) == .skip(.duplicate))
        check("after the window shown again", shown(decide(alert(.finished), .init(), context(now: at(6)), ledger: ledger)) != nil)
        check("other kind not folded", shown(decide(alert(.error), .init(), context(now: at(1)), ledger: ledger)) != nil)
        check("other session not folded", shown(decide(alert(.finished, session: "s2"), .init(), context(now: at(1)), ledger: ledger)) != nil)
        ledger.record(alert(.error), now: at(20))
        check("old entries pruned", ledger.lastSent.count == 1)
        check("duplicate keeps the old banner", !NotificationDecision.skip(.duplicate).clearsPrevious)
        check("suppressed alert clears the older banner", NotificationDecision.skip(.hostFrontmost).clearsPrevious)

        print("settings from UserDefaults")
        let suite = "coucou-notification-policy-tests-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check("defaults on", NotificationSettings(defaults: defaults) == NotificationSettings())
        check("default threshold 3 min", NotificationSettings.stallThreshold(defaults: defaults) == 180)
        defaults.set(false, forKey: NotificationSettings.waitingKey)
        defaults.set(0, forKey: NotificationSettings.stallThresholdKey)
        check("waiting off read", NotificationSettings(defaults: defaults).waiting == false)
        check("0 = stalls off", NotificationSettings.stallThreshold(defaults: defaults) == 0)
        defaults.set(-4, forKey: NotificationSettings.stallThresholdKey)
        check("negative = off", NotificationSettings.stallMinutes(defaults: defaults) == 0)

        print("out-of-date banners")
        var book = SessionBook()
        book.record(id: "s1", agent: "claude", projectName: "api", cwd: "", phase: .waitingApproval, at: at(0))
        let pill = "ide_com-jetbrains-webstorm"
        let waitingId = NotificationPolicy.identifier(pillId: pill, sessionId: "s1")
        let waiting = [waitingId: NotificationPolicy.Delivered(pillId: pill, sessionId: "s1", kind: .waitingApproval,
                                                               deliveredAt: at(0), lastEventAt: at(0))]
        check("still waiting: kept", NotificationPolicy.outdated(waiting, books: [pill: book], now: at(1)).isEmpty)
        var moved = book
        moved.record(id: "s1", agent: "claude", projectName: "", cwd: "", phase: .working, at: at(2))
        check("approved: removed", NotificationPolicy.outdated(waiting, books: [pill: moved], now: at(2)) == [waitingId])
        check("missing right after delivery: kept", NotificationPolicy.outdated(waiting, books: [:], now: at(1)).isEmpty)
        check("missing later: removed", NotificationPolicy.outdated(waiting, books: [:], now: at(5)) == [waitingId])
        let finished = [waitingId: NotificationPolicy.Delivered(pillId: pill, sessionId: "s1", kind: .finished,
                                                                deliveredAt: at(0), lastEventAt: nil)]
        check("finished banners stay", NotificationPolicy.outdated(finished, books: [pill: moved], now: at(9)).isEmpty)
        var working = SessionBook()
        working.record(id: "s1", agent: "claude", projectName: "api", cwd: "", phase: .working, at: at(0))
        let stall = [waitingId: NotificationPolicy.Delivered(pillId: pill, sessionId: "s1", kind: .stalled,
                                                             deliveredAt: at(200), lastEventAt: at(0))]
        check("stalled, still quiet: kept", NotificationPolicy.outdated(stall, books: [pill: working], now: at(300)).isEmpty)
        working.record(id: "s1", agent: "claude", projectName: "", cwd: "", phase: .working, step: "Edit", at: at(301))
        check("stalled, new event: removed", NotificationPolicy.outdated(stall, books: [pill: working], now: at(301)) == [waitingId])

        print("stall episodes")
        var tracker = StallTracker()
        var books: [String: SessionBook] = [:]
        var b = SessionBook()
        b.record(id: "a", agent: "claude", projectName: "api", cwd: "", phase: .working, at: at(0))
        b.record(id: "q", agent: "claude", projectName: "web", cwd: "", phase: .waitingAnswer, at: at(0))
        books["p"] = b
        var update = tracker.update(books: books, now: at(100), threshold: 180)
        check("not yet", update.newlyStalled.isEmpty && update.stalledPills.isEmpty)
        check("next check at the threshold", StallTracker.nextCheck(books: books, now: at(100), threshold: 180) == at(180))
        update = tracker.update(books: books, now: at(181), threshold: 180)
        check("newly stalled once", update.newlyStalled.map(\.session.id) == ["a"] && update.stalledPills == ["p"])
        check("a question is never a stall", !update.newlyStalled.contains { $0.session.id == "q" })
        check("no timer for a session already stalled", StallTracker.nextCheck(books: books, now: at(181), threshold: 180) == nil)
        update = tracker.update(books: books, now: at(400), threshold: 180)
        check("same episode not reported again", update.newlyStalled.isEmpty && update.stalledPills == ["p"])
        b.record(id: "a", agent: "claude", projectName: "", cwd: "", phase: .working, step: "Read", at: at(410))
        books["p"] = b
        update = tracker.update(books: books, now: at(411), threshold: 180)
        check("recovered: pill no longer stalled", update.stalledPills.isEmpty && update.newlyStalled.isEmpty)
        check("timer re-armed", StallTracker.nextCheck(books: books, now: at(411), threshold: 180) == at(590))
        update = tracker.update(books: books, now: at(600), threshold: 180)
        check("stalls again after a new event", update.newlyStalled.map(\.session.id) == ["a"])
        b.remove(id: "a")
        books["p"] = b
        _ = tracker.update(books: books, now: at(601), threshold: 180)
        check("gone sessions forgotten", tracker.reported.isEmpty)
        check("threshold 0: nothing stalls", tracker.update(books: books, now: at(9999), threshold: 0) == StallUpdate())
        check("threshold 0: no timer", StallTracker.nextCheck(books: books, now: at(0), threshold: 0) == nil)
        check("no working session: no timer", StallTracker.nextCheck(books: ["p": b], now: at(0), threshold: 180) == nil)

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("All notification policy checks passed.")
    }
}
