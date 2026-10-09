import Foundation

// SessionCardText (App/SessionCardText.swift): agent and project labels, which session a card
// shows, list order and the "No activity for N min" hint.

@main @MainActor
enum SessionCardTextTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func main() {
        print("agent names")
        check("claude", SessionCardText.agentName("claude") == "Claude Code")
        check("codex", SessionCardText.agentName("codex") == "Codex")
        check("case-insensitive", SessionCardText.agentName("Codex") == "Codex")
        check("third party capitalised", SessionCardText.agentName("gemini") == "Gemini")
        check("empty", SessionCardText.agentName("  ") == "Agent")

        print("agent · project")
        check("with project", SessionCardText.agentAndProject(agent: "claude", project: "my-api") == "Claude Code · my-api")
        check("without project", SessionCardText.agentAndProject(agent: "codex", project: "") == "Codex")

        print("who")
        check("in an IDE", SessionCardText.who(agent: "codex", hostName: "WebStorm") == "Codex in WebStorm")
        check("no host", SessionCardText.who(agent: "claude", hostName: nil) == "Claude Code")
        check("blank host", SessionCardText.who(agent: "claude", hostName: " ") == "Claude Code")

        print("subtitle")
        check("VS Code pill titled by project",
              SessionCardText.subtitle(agent: "claude", project: "my-api", title: "my-api", hostName: nil) == "Claude Code")
        check("Codex in VS Code",
              SessionCardText.subtitle(agent: "codex", project: "my-api", title: "my-api", hostName: nil) == "Codex")
        check("Cursor pill names the app",
              SessionCardText.subtitle(agent: "claude", project: "web", title: "web", hostName: "Cursor") == "Claude Code in Cursor")
        check("IDE pill titled by the IDE",
              SessionCardText.subtitle(agent: "codex", project: "my-api", title: "WebStorm", hostName: "WebStorm") == "Codex · my-api")
        check("project differs from the title",
              SessionCardText.subtitle(agent: "claude", project: "web", title: "api", hostName: nil) == "Claude Code · web")

        print("list order")
        var book = SessionBook()
        book.record(id: "a", agent: "claude", projectName: "api", cwd: "", phase: .working, at: at(0))
        book.record(id: "b", agent: "codex", projectName: "web", cwd: "", phase: .finished, at: at(1))
        book.record(id: "c", agent: "claude", projectName: "cli", cwd: "", phase: .waitingApproval, at: at(2))
        book.record(id: "d", agent: "codex", projectName: "doc", cwd: "", phase: .working, at: at(3))
        let order = SessionCardText.listOrder(book).map(\.id)
        check("most urgent first, recent first among equals", order == ["c", "d", "a", "b"])
        check("first row is the lead", order.first == book.lead?.id)

        print("which session")
        check("by id", SessionCardText.session(in: book, id: "a")?.id == "a")
        check("unknown id falls back to the lead", SessionCardText.session(in: book, id: "zz")?.id == "c")
        check("by phase", SessionCardText.session(in: book, phase: .finished)?.id == "b")
        check("missing phase falls back to the lead", SessionCardText.session(in: book, phase: .error)?.id == "c")
        check("no book", SessionCardText.session(in: nil) == nil)
        check("empty book", SessionCardText.session(in: SessionBook()) == nil)

        print("stalls")
        let working = AgentSession(id: "w", agent: "claude", projectName: "p", cwd: "", phase: .working,
                                   startedAt: at(0), lastEventAt: at(0))
        check("not yet", SessionCardText.stalledMinutes(working, now: at(179), thresholdMinutes: 3) == nil)
        check("at the threshold", SessionCardText.stalledMinutes(working, now: at(180), thresholdMinutes: 3) == 3)
        check("whole minutes", SessionCardText.stalledMinutes(working, now: at(299), thresholdMinutes: 3) == 4)
        check("threshold 0 is off", SessionCardText.stalledMinutes(working, now: at(10_000), thresholdMinutes: 0) == nil)
        var waiting = working
        waiting.phase = .waitingApproval
        check("waiting on the user is not stalled",
              SessionCardText.stalledMinutes(waiting, now: at(10_000), thresholdMinutes: 3) == nil)
        check("hint", SessionCardText.noActivity(minutes: 4) == "No activity for 4 min")

        print("threshold setting")
        let defaults = UserDefaults(suiteName: "SessionCardTextTests-\(UUID().uuidString)")!
        check("default 3", SessionCardText.stallThresholdMinutes(defaults) == 3)
        defaults.set(0, forKey: SessionCardText.stallThresholdKey)
        check("0 = off", SessionCardText.stallThresholdMinutes(defaults) == 0)
        defaults.set(10, forKey: SessionCardText.stallThresholdKey)
        check("custom", SessionCardText.stallThresholdMinutes(defaults) == 10)
        defaults.set(-2, forKey: SessionCardText.stallThresholdKey)
        check("negative reads as default", SessionCardText.stallThresholdMinutes(defaults) == 3)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All tests passed.")
    }
}
