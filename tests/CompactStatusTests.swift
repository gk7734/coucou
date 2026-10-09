import Foundation
import CoreGraphics

// CompactStatus (App/CompactStatus.swift): which pill the compact island's status line is
// about, how a step reads back, the rate limit, the elapsed label, and the compact layout
// (width, offset, hit regions) on notched and notchless screens. Also SessionBook's turn start.

@main @MainActor
enum CompactStatusTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func session(_ id: String, _ phase: SessionPhase, steps: [String] = [], final: String? = nil,
                        last: TimeInterval = 0) -> AgentSession {
        var s = AgentSession(id: id, agent: "claude", projectName: "p", cwd: "", phase: phase,
                             startedAt: at(0), lastEventAt: at(last))
        s.steps = steps
        s.finalLine = final
        return s
    }

    static func book(_ sessions: AgentSession...) -> SessionBook { SessionBook(sessions: sessions) }

    static let en = CompactStatusVocabulary.english

    static func main() {
        print("which pill")
        check("no books: no line", CompactStatus.pickPill(focusId: "a", books: [:]) == nil)
        check("only idle sessions: no line",
              CompactStatus.pickPill(focusId: "a", books: ["a": book(session("1", .idle))]) == nil)
        check("focused pill working",
              CompactStatus.pickPill(focusId: "a", books: ["a": book(session("1", .working)),
                                                           "b": book(session("2", .working, last: 9))]) == "a")
        check("focused idle: another working pill",
              CompactStatus.pickPill(focusId: "a", books: ["a": book(session("1", .idle)),
                                                           "b": book(session("2", .working))]) == "b")
        check("a pill waiting on the user wins over a working focus",
              CompactStatus.pickPill(focusId: "a", books: ["a": book(session("1", .working)),
                                                           "b": book(session("2", .waitingApproval))]) == "b")
        check("a waiting focus stays",
              CompactStatus.pickPill(focusId: "a", books: ["a": book(session("1", .waitingAnswer)),
                                                           "b": book(session("2", .waitingApproval))]) == "a")
        check("most urgent among others",
              CompactStatus.pickPill(focusId: "z", books: ["a": book(session("1", .finished, last: 9)),
                                                           "b": book(session("2", .working))]) == "b")
        check("most recent among equals",
              CompactStatus.pickPill(focusId: "z", books: ["a": book(session("1", .working, last: 1)),
                                                           "b": book(session("2", .working, last: 5))]) == "b")
        check("focused finished pill (Done) stays",
              CompactStatus.pickPill(focusId: "a", books: ["a": book(session("1", .finished)),
                                                           "b": book(session("2", .working))]) == "a")

        print("steps read back")
        func kind(_ step: String) -> CompactActivity { CompactStatus.classify(step: step, vocabulary: en) }
        check("edit", kind("Edits · HookServer.swift") == CompactActivity(kind: .edit, detail: "HookServer.swift"))
        check("write", kind("Writes · notes.md") == CompactActivity(kind: .edit, detail: "notes.md"))
        check("diff step", kind(String.makeDiffStep(filename: "Sources/App/AppState.swift", added: 3, removed: 1, diffId: 2))
              == CompactActivity(kind: .edit, detail: "AppState.swift"))
        check("command", kind("Runs · git status") == CompactActivity(kind: .command, detail: "git status"))
        check("tests", kind("Tests · npm test") == CompactActivity(kind: .command, detail: "npm test"))
        check("read", kind("Reads · README.md") == CompactActivity(kind: .read, detail: "README.md"))
        check("read through the shell keeps the command",
              kind("Reads · cat a.txt") == CompactActivity(kind: .read, detail: "cat a.txt"))
        check("search", kind("Searches · TODO") == CompactActivity(kind: .search, detail: "TODO"))
        check("search without detail", kind("Searches") == CompactActivity(kind: .search, detail: "Searches"))
        check("edit without detail", kind("Edits") == CompactActivity(kind: .edit, detail: "Edits"))
        check("list is a search", kind("Lists · src") == CompactActivity(kind: .search, detail: "src"))
        check("web", kind("Searches the web · swift observation") == CompactActivity(kind: .web, detail: "swift observation"))
        check("unknown step as it is", kind("⚠ failed") == CompactActivity(kind: .other, detail: "⚠ failed"))
        check("mcp tool as it is", kind("github · create_issue") == CompactActivity(kind: .other, detail: "github · create_issue"))
        check("a detail with ' · ' stays whole",
              kind("Runs · echo a · b") == CompactActivity(kind: .command, detail: "echo a · b"))
        check("long command tail-truncated", {
            let a = kind("Runs · " + String(repeating: "x", count: 80))
            return a.detail.count == CompactStatus.maxDetailLength && a.detail.hasSuffix("…")
        }())
        check("long file name middle-truncated, extension kept", {
            let a = kind("Edits · " + String(repeating: "Long", count: 15) + ".swift")
            return a.detail.count == CompactStatus.maxFileLength && a.detail.hasSuffix(".swift") && a.detail.contains("…")
        }())
        check("multi-line collapsed", kind("Runs · a\n  b") == CompactActivity(kind: .command, detail: "a b"))
        let fr = CompactStatusVocabulary(runs: "Exécute", tests: "Teste", reads: "Lit", writes: "Écrit",
                                         edits: "Modifie", searches: "Cherche", lists: "Liste",
                                         webSearch: "Cherche sur le web", fetches: "Récupère")
        check("another language", CompactStatus.classify(step: "Modifie · a.swift", vocabulary: fr)
              == CompactActivity(kind: .edit, detail: "a.swift"))

        print("session → activity")
        check("idle: none", CompactStatus.activity(session: session("1", .idle), thinking: false, vocabulary: en) == nil)
        check("working, thinking", CompactStatus.activity(session: session("1", .working, steps: ["fix the bug"]),
                                                         thinking: true, vocabulary: en)?.kind == .thinking)
        check("working, no step yet", CompactStatus.activity(session: session("1", .working), thinking: false,
                                                            vocabulary: en)?.kind == .thinking)
        check("working, last step", CompactStatus.activity(session: session("1", .working, steps: ["Reads · a", "Runs · ls -la"]),
                                                          thinking: false, vocabulary: en)
              == CompactActivity(kind: .command, detail: "ls -la"))
        check("approval", CompactStatus.activity(session: session("1", .waitingApproval), thinking: false,
                                                 approvalCommand: "rm -rf dist", vocabulary: en)
              == CompactActivity(kind: .needsOK, detail: "rm -rf dist"))
        check("question", CompactStatus.activity(session: session("1", .waitingAnswer), thinking: false,
                                                 question: "Which DB?", vocabulary: en)
              == CompactActivity(kind: .asks, detail: "Which DB?"))
        check("finished", CompactStatus.activity(session: session("1", .finished, final: "All tests pass."),
                                                 thinking: false, vocabulary: en)
              == CompactActivity(kind: .done, detail: "All tests pass."))
        check("error", CompactStatus.activity(session: session("1", .error), thinking: false, vocabulary: en)?.kind == .error)

        print("texts")
        check("thinking", CompactStatus.text(CompactActivity(kind: .thinking, detail: "")) == "Thinking…")
        check("done", CompactStatus.text(CompactActivity(kind: .done, detail: "ok")) == "Done: ok")
        check("done, no line", CompactStatus.text(CompactActivity(kind: .done, detail: "")) == "Done")
        check("needs OK", CompactStatus.text(CompactActivity(kind: .needsOK, detail: "rm -rf dist")) == "Needs your OK: rm -rf dist")
        check("asks", CompactStatus.text(CompactActivity(kind: .asks, detail: "Which DB?")) == "Asks: Which DB?")
        check("error", CompactStatus.text(CompactActivity(kind: .error, detail: "")) == "Error")
        check("file", CompactStatus.text(CompactActivity(kind: .edit, detail: "a.swift")) == "a.swift")
        check("waiting kinds", CompactActivityKind.needsOK.waitsOnUser && CompactActivityKind.asks.waitsOnUser
              && !CompactActivityKind.edit.waitsOnUser)
        check("elapsed only while working", CompactActivityKind.command.showsElapsed && !CompactActivityKind.done.showsElapsed
              && !CompactActivityKind.needsOK.showsElapsed)

        print("elapsed")
        check("under a minute", CompactStatus.elapsedLabel(since: at(0), now: at(59)) == "<1m")
        check("minutes", CompactStatus.elapsedLabel(since: at(0), now: at(150)) == "2m")
        check("59 minutes", CompactStatus.elapsedLabel(since: at(0), now: at(3599)) == "59m")
        check("hours", CompactStatus.elapsedLabel(since: at(0), now: at(7300)) == "2h")
        check("clock behind", CompactStatus.elapsedLabel(since: at(10), now: at(0)) == "<1m")

        print("rate limit")
        check("first change now", CompactStatus.changeDelay(lastChange: nil, now: at(0)) == 0)
        check("0.1 s after: wait 0.3 s", abs(CompactStatus.changeDelay(lastChange: at(0), now: at(0.1)) - 0.3) < 1e-6)
        check("0.5 s after: now", CompactStatus.changeDelay(lastChange: at(0), now: at(0.5)) == 0)

        print("turn start (SessionBook)")
        var b = SessionBook()
        b.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .idle, at: at(0))
        check("SessionStart: no turn yet", b.session("s")?.turnStartedAt == nil)
        b.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(10))
        check("prompt starts the turn", b.session("s")?.turnStartedAt == at(10))
        b.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(20))
        check("tool events keep it", b.session("s")?.turnStartedAt == at(10))
        b.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .waitingApproval, at: at(30))
        b.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(40))
        check("an approval is the same turn", b.session("s")?.turnStartedAt == at(10))
        b.finish(id: "s", finalLine: "ok", at: at(50))
        b.record(id: "s", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(60))
        check("next prompt starts a new turn", b.session("s")?.turnStartedAt == at(60))
        b.record(id: "n", agent: "claude", projectName: "p", cwd: "", phase: .working, at: at(70))
        check("a session born working", b.session("n")?.turnStartedAt == at(70))

        print("layout: no line is the island as before")
        let plainNotch = CompactIslandLayout(notchWidth: 185, hasNotch: true, status: .none)
        check("notch: nw + 160, centred", plainNotch.width == 345 && plainNotch.offsetX == 0 && !plainNotch.hasStatus)
        check("notch: minis at width - 40", plainNotch.miniGridCenterX == 305)
        let plainBar = CompactIslandLayout(notchWidth: 80, hasNotch: false, status: .none)
        check("bar: 240, centred", plainBar.width == 240 && plainBar.offsetX == 0)

        print("layout: notched screen (the right ear grows)")
        let n = CompactIslandLayout(notchWidth: 185, hasNotch: true,
                                    status: CompactStatusMetrics(statusWidth: 150, hasMinis: true))
        check("right ear = 10 + 150 + 8 + 54", n.width == 80 + 185 + 222)
        check("offset: half the growth", n.offsetX == 71)
        check("left edge stays where it was", -n.width / 2 + n.offsetX == -plainNotch.width / 2)
        check("line starts 10 pt after the notch", n.statusX == 80 + 185 + 10)
        check("line width", n.statusWidth == 150)
        check("line ends 8 pt before the mini grid", n.statusX + n.statusWidth + 8 == n.miniGridCenterX - 14)
        check("Mochi stays in the left ear", CompactIslandLayout.botCenterX == 40)
        let long = CompactIslandLayout(notchWidth: 185, hasNotch: true,
                                       status: CompactStatusMetrics(statusWidth: 900, hasMinis: true))
        check("capped inside the 720 pt panel", long.width / 2 + long.offsetX <= 360 - CompactIslandLayout.panelMargin + 0.001)
        check("right ear never past 300", long.width - 80 - 185 <= 300)
        check("capped line fits the ear", long.statusX + long.statusWidth + 62 <= long.width + 0.001)
        let narrowNotch = CompactIslandLayout(notchWidth: 100, hasNotch: true,
                                              status: CompactStatusMetrics(statusWidth: 900, hasMinis: true))
        check("narrow notch: ear capped at 300", narrowNotch.width - 80 - 100 == 300)
        let tiny = CompactIslandLayout(notchWidth: 185, hasNotch: true,
                                       status: CompactStatusMetrics(statusWidth: 4, hasMinis: true))
        check("short line: the ear never shrinks", tiny.width == 345 && tiny.offsetX == 0)
        let noMinis = CompactIslandLayout(notchWidth: 185, hasNotch: true,
                                          status: CompactStatusMetrics(statusWidth: 150, hasMinis: false))
        check("no minis: 14 pt margin instead", noMinis.width == 80 + 185 + 10 + 150 + 14)

        print("layout: no notch (the bar widens around its centre)")
        let bar = CompactIslandLayout(notchWidth: 80, hasNotch: false,
                                      status: CompactStatusMetrics(statusWidth: 200, hasMinis: true))
        check("58 + 200 + 8 + 54", bar.width == 320)
        check("centred", bar.offsetX == 0)
        check("line after Mochi", bar.statusX == 58 && bar.statusWidth == 200)
        let barLong = CompactIslandLayout(notchWidth: 80, hasNotch: false,
                                          status: CompactStatusMetrics(statusWidth: 900, hasMinis: true))
        check("capped at 420", barLong.width == 420 && barLong.statusWidth == 420 - 58 - 62)
        let barShort = CompactIslandLayout(notchWidth: 80, hasNotch: false,
                                           status: CompactStatusMetrics(statusWidth: 40, hasMinis: true))
        check("never narrower than before", barShort.width == 240 && barShort.statusWidth == 240 - 58 - 62)

        print("hit regions")
        check("on the line", n.statusContains(x: n.statusX + 5))
        check("before the line", !n.statusContains(x: n.statusX - 1))
        check("no line, no region", !plainNotch.statusContains(x: 300))
        check("one mini: left cell, centred row", CompactIslandLayout.miniCellOffsets(count: 1) == [CGPoint(x: -8, y: 0)])
        check("three minis: two rows", CompactIslandLayout.miniCellOffsets(count: 3)
              == [CGPoint(x: -8, y: -8), CGPoint(x: 8, y: -8), CGPoint(x: -8, y: 8)])
        check("at most four", CompactIslandLayout.miniCellOffsets(count: 7).count == 4)
        let h: CGFloat = 32
        let cx = n.miniGridCenterX
        check("mini 0 hit", n.miniIndex(atX: cx - 8, y: h / 2 - 8, height: h, count: 4, scale: 1) == 0)
        check("mini 3 hit", n.miniIndex(atX: cx + 8, y: h / 2 + 8, height: h, count: 4, scale: 1) == 3)
        check("missing mini: no hit", n.miniIndex(atX: cx + 8, y: h / 2 + 8, height: h, count: 3, scale: 1) == nil)
        check("beside the grid: no hit", n.miniIndex(atX: cx - 20, y: h / 2, height: h, count: 4, scale: 1) == nil)
        check("scaled grid", n.miniIndex(atX: cx + 8 * 0.7, y: 12 - 8 * 0.7, height: 24, count: 4, scale: 0.7) == 1)

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All compact status tests passed.")
    }
}
