import Foundation

// SessionBook (App/SessionBook.swift): several sessions per pill, the pill's derived phase,
// retention and stall detection.

@main @MainActor
enum SessionBookTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func main() {
        print("two sessions in one pill")
        var book = SessionBook()
        book.record(id: "a", agent: "claude", projectName: "api", cwd: "/p/api", phase: .working, step: "Read a.ts", at: at(0))
        book.record(id: "b", agent: "codex", projectName: "web", cwd: "/p/web", phase: .working, step: "npm test", at: at(1))
        check("both kept", book.count == 2)
        check("most recent first", book.sessions.map(\.id) == ["b", "a"])
        check("a keeps its own steps", book.session("a")?.steps == ["Read a.ts"])
        check("pill phase working", book.phase == .working)

        print("urgency decides the lead")
        book.record(id: "a", agent: "claude", projectName: "", cwd: "", phase: .waitingApproval, at: at(2))
        book.record(id: "b", agent: "codex", projectName: "", cwd: "", phase: .working, step: "Edit x", at: at(3))
        check("approval leads although b is more recent", book.lead?.id == "a")
        check("pill phase is the approval", book.phase == .waitingApproval)
        check("empty project name keeps the old one", book.session("a")?.projectName == "api")

        print("finish / working again")
        book.finish(id: "b", finalLine: "All green", at: at(4))
        check("finished with final line", book.session("b")?.phase == .finished && book.session("b")?.finalLine == "All green")
        book.record(id: "b", agent: "codex", projectName: "", cwd: "", phase: .working, at: at(5))
        check("new turn clears the final line", book.session("b")?.finalLine == nil)
        book.record(id: "b", agent: "codex", projectName: "", cwd: "", phase: nil, step: "note", at: at(6))
        check("nil phase keeps the phase", book.session("b")?.phase == .working)

        print("steps are capped")
        var many = SessionBook()
        for i in 0..<30 { many.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .working, step: "step \(i)", at: at(Double(i))) }
        check("20 steps max", many.session("s")?.steps.count == AgentSession.maxSteps)
        check("oldest dropped", many.session("s")?.steps.first == "step 10")

        print("SessionEnd / bringToFront")
        book.remove(id: "a")
        check("removed", book.session("a") == nil && book.count == 1)
        book.record(id: "c", agent: "claude", projectName: "c", cwd: "", phase: .working, at: at(7))
        book.bringToFront(id: "b")
        check("brought to front", book.sessions.first?.id == "b")
        check("empty book is idle", SessionBook().phase == .idle && SessionBook().lead == nil)

        print("retention")
        var old = SessionBook()
        old.record(id: "done", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(0))
        old.finish(id: "done", finalLine: nil, at: at(0))
        old.record(id: "wait", agent: "claude", projectName: "p", cwd: "", phase: .waitingAnswer, at: at(0))
        old.trim(now: at(SessionBook.endedRetention + 1))
        check("ended session dropped after retention", old.session("done") == nil)
        check("waiting session kept", old.session("wait") != nil)
        var full = SessionBook()
        full.record(id: "w", agent: "claude", projectName: "p", cwd: "", phase: .waitingApproval, at: at(0))
        for i in 0..<12 { full.record(id: "s\(i)", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(Double(i + 1))) }
        check("capped at maxSessions", full.count == SessionBook.maxSessions)
        check("cap never drops one waiting on the user", full.session("w") != nil)

        print("stalls")
        var s = SessionBook()
        s.record(id: "busy", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(0))
        s.record(id: "asks", agent: "claude", projectName: "p", cwd: "", phase: .waitingApproval, at: at(0))
        s.record(id: "fresh", agent: "codex", projectName: "p", cwd: "", phase: .working, at: at(100))
        check("silent working session is stalled", s.stalled(now: at(180), threshold: 180).map(\.id) == ["busy"])
        check("waiting on the user is never stalled", !s.stalled(now: at(10_000), threshold: 180).contains { $0.id == "asks" })
        check("threshold 0 disables", s.stalled(now: at(10_000), threshold: 0).isEmpty)
        check("next check is the earliest working deadline", s.nextStallCheck(threshold: 180) == at(180))
        var quiet = SessionBook()
        quiet.record(id: "x", agent: "claude", projectName: "p", cwd: "", phase: .waitingAnswer, at: at(0))
        check("no working session → no timer", quiet.nextStallCheck(threshold: 180) == nil)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All tests passed.")
    }
}
