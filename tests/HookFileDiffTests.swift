import Foundation

// HookFileDiff (the diff of an Edit / MultiEdit / Write hook payload, computed in the
// background when big) and OrderedDelivery (later hook events wait behind a pending diff).

@main
enum HookFileDiffTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    @MainActor
    static func main() {
        print("HookFileDiff.Request — payload parsing")
        do {
            let edit = HookFileDiff.Request(tool: "Edit", input: ["file_path": "/p/a.swift",
                                                                   "old_string": "a\nb\n", "new_string": "a\nc\n"])
            check("Edit parsed", edit != nil && edit?.isMultiEdit == false)
            let d = edit!.compute()
            check("Edit diff: +1 −1", d.added == 1 && d.removed == 1 && !d.isNewFile && d.path == "/p/a.swift")
            check("Edit diff shown", HookFileDiff.shown(d) != nil)

            check("no file_path → nil",
                  HookFileDiff.Request(tool: "Edit", input: ["old_string": "a", "new_string": "b"]) == nil)
            check("missing new_string → nil",
                  HookFileDiff.Request(tool: "Edit", input: ["file_path": "/x", "old_string": "a"]) == nil)
            check("other tool → nil",
                  HookFileDiff.Request(tool: "Read", input: ["file_path": "/x", "content": "a"]) == nil)

            let noop = HookFileDiff.Request(tool: "Edit", input: ["file_path": "/x", "old_string": "", "new_string": ""])!
            check("empty Edit: diff with no change, not shown", HookFileDiff.shown(noop.compute()) == nil)
            let same = HookFileDiff.Request(tool: "Edit", input: ["file_path": "/x", "old_string": "q", "new_string": "q"])!
            check("unchanged Edit: not shown", HookFileDiff.shown(same.compute()) == nil)

            let multi = HookFileDiff.Request(tool: "MultiEdit", input: [
                "file_path": "/m.kt",
                "edits": [["old_string": "aaa", "new_string": "bbb"],
                          ["old_string": "x"],                                  // malformed: skipped
                          ["old_string": "c\nd", "new_string": "c\nd\ne\nf"]],
            ])!
            let md = multi.compute()
            check("MultiEdit: totals of the valid edits", md.added == 3 && md.removed == 1)
            check("MultiEdit: hunks of both edits", md.hunks.count == 2)
            let emptyMulti = HookFileDiff.Request(tool: "MultiEdit", input: ["file_path": "/m", "edits": [[String: Any]]()])!
            check("MultiEdit without edits: not shown", HookFileDiff.shown(emptyMulti.compute()) == nil)

            let write = HookFileDiff.Request(tool: "Write", input: ["file_path": "/n.rs", "content": "1\n2\n3\n"])!
            let wd = write.compute()
            check("Write: new file +3", wd.isNewFile && wd.added == 3 && wd.removed == 0)
            let emptyWrite = HookFileDiff.Request(tool: "Write", input: ["file_path": "/n.rs", "content": ""])!
            check("empty Write: not shown", HookFileDiff.shown(emptyWrite.compute()) == nil)

            check("small edit is diffed inline", edit!.isSmall)
            let big = String(repeating: "0123456789abcdef\n", count: 1100)
            let bigEdit = HookFileDiff.Request(tool: "Edit", input: ["file_path": "/b", "old_string": big, "new_string": big + "x\n"])!
            check("big edit goes to the background", !bigEdit.isSmall)
        }

        print("HookFileDiff.Request.compute(then:) — background, back on main")
        do {
            let old = (0..<1500).map { "line \($0)" }.joined(separator: "\n")
            let new = old.replacingOccurrences(of: "line 700\n", with: "line seven hundred\n")
            let request = HookFileDiff.Request(tool: "Edit", input: ["file_path": "/b.swift", "old_string": old, "new_string": new])!
            nonisolated(unsafe) var result: FileDiff? = nil
            nonisolated(unsafe) var onMain = false
            request.compute { diff in
                onMain = Thread.isMainThread
                result = diff
            }
            spin { result != nil }
            check("completion ran on the main thread", onMain)
            check("same diff as computed inline", result == request.compute())
            check("+1 −1", result?.added == 1 && result?.removed == 1)
        }

        print("OrderedDelivery — synchronous messages pass straight through")
        do {
            let delivery = OrderedDelivery<Int>()
            var handled: [Int] = []
            for i in 0..<5 { delivery.submit(i) { handled.append($0) } }
            check("in order, none held", handled == [0, 1, 2, 3, 4] && !delivery.isHeld && delivery.waitingCount == 0)
        }

        print("OrderedDelivery — messages wait behind a held one")
        do {
            let delivery = OrderedDelivery<Int>()
            var handled: [Int] = []
            var pending: [Int] = []           // held messages, finished by hand below
            func handle(_ m: Int) {
                if m % 3 == 1 {               // 1, 4, 7: "needs a background diff"
                    delivery.hold()
                    pending.append(m)
                } else {
                    handled.append(m)
                }
            }
            for i in 0..<9 { delivery.submit(i, to: handle) }
            check("0 handled, 1 held, 2…8 waiting", handled == [0] && pending == [1] && delivery.waitingCount == 7)
            handled.append(pending.removeFirst()); delivery.resume(to: handle)
            check("1 done → 2, 3 go, 4 holds", handled == [0, 1, 2, 3] && pending == [4] && delivery.waitingCount == 4)
            delivery.submit(9, to: handle)
            check("a new message waits too", delivery.waitingCount == 5)
            handled.append(pending.removeFirst()); delivery.resume(to: handle)
            handled.append(pending.removeFirst()); delivery.resume(to: handle)
            check("everything handled in arrival order", handled == Array(0...9) && !delivery.isHeld && delivery.waitingCount == 0)
        }

        print("OrderedDelivery — with real background diffs")
        do {
            // Every third message is a big Edit diffed off the main thread; the others are
            // handled at once. Whatever the diff timings, the handled order is the arrival order.
            let delivery = OrderedDelivery<Int>()
            nonisolated(unsafe) var handled: [Int] = []
            let base = (0..<1200).map { "row \($0)" }
            func handle(_ m: Int) {
                guard m % 3 == 0 else { handled.append(m); return }
                var edited = base
                edited[(m * 37) % base.count] = "edited \(m)"
                let request = HookFileDiff.Request(tool: "Edit", input: [
                    "file_path": "/f\(m)", "old_string": base.joined(separator: "\n"),
                    "new_string": edited.joined(separator: "\n")])!
                delivery.hold()
                request.compute { diff in
                    if diff.added == 1 && diff.removed == 1 { handled.append(m) }
                    delivery.resume(to: handle)
                }
            }
            for i in 0..<30 {
                delivery.submit(i, to: handle)
                if i % 4 == 0 { spin(for: 0.002) }   // let some diffs finish between arrivals
            }
            spin { handled.count == 30 }
            check("30 messages, arrival order", handled == Array(0..<30))
        }

        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed."); exit(1)
    }

    /// Runs the main run loop (so main-queue blocks execute) until `done` or 10 s.
    @MainActor
    static func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }

    @MainActor
    static func spin(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
