import Foundation

@main
enum DiffEngineTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkInt(_ label: String, _ got: Int, _ expected: Int) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func main() {

        // ── DiffEngine.fromEdit — additions ───────────────────────────────────
        print("DiffEngine.fromEdit — additions")
        do {
            let d = DiffEngine.fromEdit(old: "", new: "hello\nworld\n", path: "/a/b.swift")
            checkInt("added == 2",      d.added,    2)
            checkInt("removed == 0",    d.removed,  0)
            checkTrue("!tooLarge",      !d.tooLarge)
            checkTrue("1 hunk",         d.hunks.count == 1)
            checkTrue("name == b.swift", d.name == "b.swift")
        }

        // ── DiffEngine.fromEdit — removals ────────────────────────────────────
        print("DiffEngine.fromEdit — removals")
        do {
            let d = DiffEngine.fromEdit(old: "hello\nworld\n", new: "", path: "/x.py")
            checkInt("added == 0",   d.added,   0)
            checkInt("removed == 2", d.removed, 2)
            checkTrue("1 hunk",      d.hunks.count == 1)
        }

        // ── DiffEngine.fromEdit — replacement ─────────────────────────────────
        print("DiffEngine.fromEdit — replacement")
        do {
            let d = DiffEngine.fromEdit(old: "foo\nbar\nbaz\n",
                                         new: "foo\nqux\nbaz\n",
                                         path: "/f.ts")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 1", d.removed, 1)
            checkTrue("has context lines",
                      d.hunks.first?.lines.contains(where: { $0.kind == .context }) == true)
        }

        // ── DiffEngine.fromNew — new file ──────────────────────────────────────
        print("DiffEngine.fromNew — new file")
        do {
            let d = DiffEngine.fromNew(content: "line1\nline2\nline3\n", path: "/new.rs")
            checkInt("added == 3",   d.added,   3)
            checkInt("removed == 0", d.removed, 0)
            checkTrue("all lines .added",
                      d.hunks.flatMap { $0.lines }.allSatisfy { $0.kind == .added })
        }

        // ── DiffEngine.fromEdit — MultiEdit (two edits) ────────────────────────
        print("DiffEngine.fromEdit — MultiEdit (two edits)")
        do {
            let d1 = DiffEngine.fromEdit(old: "aaa\n", new: "bbb\n", path: "/m.kt")
            let d2 = DiffEngine.fromEdit(old: "ccc\n", new: "ddd\n", path: "/m.kt")
            checkInt("d1 added == 1",   d1.added,   1)
            checkInt("d1 removed == 1", d1.removed, 1)
            checkInt("d2 added == 1",   d2.added,   1)
            checkInt("d2 removed == 1", d2.removed, 1)
        }

        // ── DiffEngine — tooLarge ──────────────────────────────────────────────
        print("DiffEngine — tooLarge")
        do {
            // Generate > 200 KB combined content
            let bigOld = String(repeating: "x", count: 150 * 1024)
            let bigNew = String(repeating: "y", count: 60 * 1024)
            let d = DiffEngine.fromEdit(old: bigOld, new: bigNew, path: "/big.swift")
            checkTrue("tooLarge == true",   d.tooLarge)
            checkTrue("hunks.isEmpty",      d.hunks.isEmpty)
        }

        // ── DiffEngine — CRLF ─────────────────────────────────────────────────
        print("DiffEngine — CRLF")
        do {
            let d = DiffEngine.fromEdit(old: "a\r\nb\r\n", new: "a\r\nc\r\n", path: "/win.txt")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 1", d.removed, 1)
        }

        // ── DiffEngine — no trailing newline ──────────────────────────────────
        print("DiffEngine — no trailing newline")
        do {
            let d = DiffEngine.fromEdit(old: "hello", new: "hello\nworld", path: "/t.txt")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 0", d.removed, 0)
        }

        // ── DiffEngine — 3-line context ───────────────────────────────────────
        print("DiffEngine — 3-line context")
        do {
            // 10-line file, change line 5
            let oldContent = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let newContent = (1...10).map { $0 == 5 ? "changed" : "line\($0)" }.joined(separator: "\n") + "\n"
            let d = DiffEngine.fromEdit(old: oldContent, new: newContent, path: "/ctx.swift")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 1", d.removed, 1)
            checkTrue("1 hunk",      d.hunks.count == 1)
            let hunk = d.hunks[0]
            let contextLines = hunk.lines.filter { $0.kind == .context }
            checkTrue("has context before change", contextLines.count >= 3)
        }

        // ── DiffEngine — 1001 × 1001 lines: diffed (the old LCS gave up past 1M cells) ──
        print("DiffEngine — 1001 × 1001 lines, one line added")
        do {
            let many = (0..<1001).map { "line\($0)" }.joined(separator: "\n")
            let d = DiffEngine.fromEdit(old: many, new: many + "\nextra", path: "/big.swift")
            checkTrue("!tooLarge",          !d.tooLarge)
            checkInt("added == 1",          d.added, 1)
            checkInt("removed == 0",        d.removed, 0)
            checkInt("1 hunk",              d.hunks.count, 1)
            checkTrue("applies",            applies(d, old: many, new: many + "\nextra"))
        }

        // ── DiffEngine — more than maxLines in all → tooLarge ────────────────
        print("DiffEngine — over maxLines → tooLarge")
        do {
            let many = (0..<2001).map { "l\($0)" }.joined(separator: "\n")
            let d = DiffEngine.fromEdit(old: many, new: many + "\nextra", path: "/big.swift")
            checkTrue("tooLarge",    d.tooLarge)
            checkTrue("hunks empty", d.hunks.isEmpty)
            checkInt("count fallback added == 1", d.added, 1)
        }

        // ── DiffEngine — big file, few scattered edits ───────────────────────
        print("DiffEngine — big file, small edits")
        do {
            let base = (0..<1999).map { "let value\($0) = compute(\($0))" }
            var edited = base
            edited[100] = "let value100 = compute(100) // changed"
            edited[1000] = "let renamed = compute(1000)"
            edited.insert("// inserted", at: 1900)
            edited.remove(at: 1500)
            let old = base.joined(separator: "\n") + "\n"
            let new = edited.joined(separator: "\n") + "\n"
            let d = DiffEngine.fromEdit(old: old, new: new, path: "/big.swift")
            checkTrue("!tooLarge",    !d.tooLarge)
            checkInt("added == 3",    d.added, 3)
            checkInt("removed == 3",  d.removed, 3)
            checkInt("4 hunks",       d.hunks.count, 4)
            checkTrue("applies",      applies(d, old: old, new: new))
            checkTrue("same lines as the old LCS",
                      DiffEngine.diffLines(oldLines: base, newLines: edited) == legacyDiffLines(base, edited))
        }

        // ── DiffEngine — completely different files ──────────────────────────
        print("DiffEngine — completely different files")
        do {
            let old = (0..<1500).map { "old \($0)" }.joined(separator: "\n")
            let new = (0..<1400).map { "new \($0)" }.joined(separator: "\n")
            let d = DiffEngine.fromEdit(old: old, new: new, path: "/x.txt")
            checkTrue("!tooLarge",       !d.tooLarge)
            checkInt("added == 1400",    d.added, 1400)
            checkInt("removed == 1500",  d.removed, 1500)
            checkInt("1 hunk",           d.hunks.count, 1)
            let kinds = d.hunks.flatMap { $0.lines }.map { $0.kind }
            checkTrue("removed lines first, then added",
                      kinds == Array(repeating: .removed, count: 1500) + Array(repeating: .added, count: 1400))
            checkTrue("applies",         applies(d, old: old, new: new))
        }

        // ── DiffEngine — empty sides ─────────────────────────────────────────
        print("DiffEngine — empty sides")
        do {
            let both = DiffEngine.fromEdit(old: "", new: "", path: "/e")
            checkInt("both empty: added 0",   both.added, 0)
            checkInt("both empty: removed 0", both.removed, 0)
            checkTrue("both empty: no hunks", both.hunks.isEmpty)
            let add = DiffEngine.fromEdit(old: "", new: "a", path: "/e")
            checkInt("old empty: added 1",    add.added, 1)
            checkTrue("old empty: applies",   applies(add, old: "", new: "a"))
            let rem = DiffEngine.fromEdit(old: "a\n", new: "", path: "/e")
            checkInt("new empty: removed 1",  rem.removed, 1)
            checkTrue("new empty: applies",   applies(rem, old: "a\n", new: ""))
            let same = DiffEngine.fromEdit(old: "x\ny\n", new: "x\ny\n", path: "/e")
            checkTrue("identical: no hunks",  same.hunks.isEmpty && same.added == 0 && same.removed == 0)
        }

        // ── DiffEngine — trailing newline ────────────────────────────────────
        print("DiffEngine — trailing newline")
        do {
            let d1 = DiffEngine.fromEdit(old: "a\nb", new: "a\nb\n", path: "/t")
            checkTrue("only a trailing newline added: no change", d1.added == 0 && d1.removed == 0 && d1.hunks.isEmpty)
            let d2 = DiffEngine.fromEdit(old: "a\nb\n\n", new: "a\nb\n", path: "/t")
            checkInt("trailing blank line removed", d2.removed, 1)
            checkInt("…nothing added",              d2.added, 0)
            let d3 = DiffEngine.fromEdit(old: "a\nb", new: "a\nc", path: "/t")
            checkTrue("last line without newline replaced", d3.added == 1 && d3.removed == 1)
        }

        // ── DiffEngine — many identical lines ────────────────────────────────
        print("DiffEngine — many identical lines")
        do {
            let braces = Array(repeating: "}", count: 500)
            var withInserts = braces
            withInserts.insert("x", at: 400); withInserts.insert("y", at: 250); withInserts.insert("z", at: 10)
            let old = braces.joined(separator: "\n"), new = withInserts.joined(separator: "\n")
            let d = DiffEngine.fromEdit(old: old, new: new, path: "/b")
            checkInt("added == 3",   d.added, 3)
            checkInt("removed == 0", d.removed, 0)
            checkTrue("applies",     applies(d, old: old, new: new))
            let blanks = Array(repeating: "", count: 200).joined(separator: "\n") + "end"
            let fewer  = Array(repeating: "", count: 180).joined(separator: "\n") + "end"
            let d2 = DiffEngine.fromEdit(old: blanks, new: fewer, path: "/b")
            checkInt("20 blank lines removed", d2.removed, 20)
            checkInt("nothing added",          d2.added, 0)
            checkTrue("applies",               applies(d2, old: blanks, new: fewer))
        }

        // ── DiffEngine — randomized against the old LCS ──────────────────────
        // Equally short edit scripts may pair different lines (repeated lines), so random
        // inputs check the counts and that the diff turns old into new; one contiguous edit
        // of distinct lines (the usual Edit tool call) must give exactly the old output.
        print("DiffEngine — randomized against the old LCS")
        do {
            var rng = SplitMix(seed: 42)
            var countMismatches = 0, applyFailures = 0, typicalMismatches = 0
            for _ in 0..<1500 {
                let a = (0..<rng.next(upTo: 40)).map { _ in ["a", "b", "c", "d", "", "}"][rng.next(upTo: 6)] }
                var b = a
                for _ in 0..<rng.next(upTo: 8) {
                    let op = rng.next(upTo: 3)
                    if op == 0 || b.isEmpty { b.insert(["a", "b", "x", ""][rng.next(upTo: 4)], at: rng.next(upTo: b.count + 1)) }
                    else if op == 1 { b.remove(at: rng.next(upTo: b.count)) }
                    else { b[rng.next(upTo: b.count)] = ["c", "y", "}"][rng.next(upTo: 3)] }
                }
                if rng.next(upTo: 10) == 0 { b = (0..<rng.next(upTo: 30)).map { _ in ["a", "q", "r"][rng.next(upTo: 3)] } }
                let mine = DiffEngine.diffLines(oldLines: a, newLines: b)
                let ref = legacyDiffLines(a, b)
                if count(mine, .added) != count(ref, .added) || count(mine, .removed) != count(ref, .removed) {
                    countMismatches += 1
                }
                if !flatApplies(mine, a, b) { applyFailures += 1 }

                // One contiguous edit of distinct lines.
                let base = (0..<(5 + rng.next(upTo: 60))).map { "line \($0)" }
                let start = rng.next(upTo: base.count), len = rng.next(upTo: min(6, base.count - start) + 1)
                var edited = base
                edited.replaceSubrange(start..<(start + len), with: (0..<rng.next(upTo: 6)).map { "new \($0)" })
                if DiffEngine.diffLines(oldLines: base, newLines: edited) != legacyDiffLines(base, edited) {
                    typicalMismatches += 1
                }
            }
            checkInt("added/removed counts equal the old LCS", countMismatches, 0)
            checkInt("every diff turns old into new",          applyFailures, 0)
            checkInt("one contiguous edit: identical output",  typicalMismatches, 0)
        }

        // ── DiffEngine.fromNew — too large ────────────────────────────────────
        print("DiffEngine.fromNew — too large")
        do {
            let bigContent = String(repeating: "x\n", count: FileDiff.maxLines + 1)
            let d = DiffEngine.fromNew(content: bigContent, path: "/new.swift")
            checkTrue("fromNew tooLarge",    d.tooLarge)
            checkTrue("fromNew isNewFile",   d.isNewFile)
            checkTrue("fromNew hunks empty", d.hunks.isEmpty)
            checkTrue("fromNew added > 0",   d.added > 0)
        }

        // ── String.makeDiffStep / parseDiffStep ───────────────────────────────
        print("String.makeDiffStep / parseDiffStep")
        do {
            let s = String.makeDiffStep(filename: "foo.swift", added: 3, removed: 1, diffId: 7)
            checkTrue("isDiffStep", s.isDiffStep)
            let parsed = s.parseDiffStep()
            checkTrue("parsed != nil",        parsed != nil)
            checkTrue("filename round-trips", parsed?.filename == "foo.swift")
            checkTrue("added round-trips",    parsed?.added    == 3)
            checkTrue("removed round-trips",  parsed?.removed  == 1)
            checkTrue("diffId round-trips",   parsed?.diffId   == 7)

            // id > 9 (multi-digit) round-trips correctly
            let s2 = String.makeDiffStep(filename: "bar.ts", added: 0, removed: 2, diffId: 42)
            checkTrue("diffId 42 round-trips", s2.parseDiffStep()?.diffId == 42)

            // Non-diff step should not parse
            checkTrue("normal step !isDiffStep", !"Edit foo.swift".isDiffStep)
            checkTrue("normal step parseDiffStep == nil", "Edit foo.swift".parseDiffStep() == nil)
        }

        // ── DiffEngine.toOneLine ──────────────────────────────────────────────
        print("DiffEngine.toOneLine")
        do {
            // multi-line joined with space
            checkTrue("multi-line joined",
                DiffEngine.toOneLine("line one\nline two\nline three") == "line one line two line three")

            // bold stripped
            checkTrue("bold stripped",
                DiffEngine.toOneLine("**hello** world") == "hello world")

            // heading stripped
            checkTrue("heading stripped",
                DiffEngine.toOneLine("## My Title\nsome text") == "My Title some text")

            // empty input → empty
            checkTrue("empty → empty", DiffEngine.toOneLine("").isEmpty)

            // truncation
            let long = DiffEngine.toOneLine(String(repeating: "x ", count: 200), maxChars: 10)
            checkTrue("truncated to maxChars", long.count <= 10)

            // stop at blank line
            checkTrue("blank line → first para only",
                DiffEngine.toOneLine("First para.\n\nSecond para.") == "First para.")

            // stop at --- separator
            checkTrue("--- separator → first para only",
                DiffEngine.toOneLine("Done. Single commit 450a657 on github-pulse.\n\n---\n\nFiles touched (7)…")
                    == "Done. Single commit 450a657 on github-pulse.")

            // stop at *** separator
            checkTrue("*** separator → first para only",
                DiffEngine.toOneLine("Summary line.\n***\nMore details.") == "Summary line.")

            // stop at table row (|)
            checkTrue("table row → first para only",
                DiffEngine.toOneLine("Result:\n| Col1 | Col2 |\n|---|---|\n| A | B |") == "Result:")

            // strip leading bullet -
            checkTrue("strip bullet -",
                DiffEngine.toOneLine("- item one\n- item two") == "item one item two")

            // strip leading bullet *
            checkTrue("strip bullet *",
                DiffEngine.toOneLine("* first\n* second") == "first second")

            // strip ordered list
            checkTrue("strip ordered list",
                DiffEngine.toOneLine("1. step one\n2. step two") == "step one step two")

            // first paragraph empty → fall through to next
            checkTrue("empty first para → next",
                DiffEngine.toOneLine("\n\nActual content.") == "Actual content.")
        }

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }

    // MARK: - Helpers

    static func count(_ lines: [DiffLine], _ kind: DiffLine.Kind) -> Int { lines.filter { $0.kind == kind }.count }

    static func lines(_ text: String) -> [String] {
        var parts = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// The flat diff keeps old's lines (context + removed) and new's lines (context + added),
    /// in order, with their line numbers.
    static func flatApplies(_ flat: [DiffLine], _ old: [String], _ new: [String]) -> Bool {
        let o = flat.filter { $0.kind != .added }
        let n = flat.filter { $0.kind != .removed }
        return o.map(\.text) == old && n.map(\.text) == new
            && o.map(\.origLine) == Array(0..<old.count).map { $0 + 1 }
            && n.map(\.newLine) == Array(0..<new.count).map { $0 + 1 }
    }

    /// Patches `old` with the diff's hunks and checks the result is `new`.
    static func applies(_ d: FileDiff, old: String, new: String) -> Bool {
        let o = lines(old), n = lines(new)
        var out: [String] = []
        var i = 0   // next old line (0-based)
        for hunk in d.hunks {
            if let firstOld = hunk.lines.first(where: { $0.origLine > 0 })?.origLine {
                while i < firstOld - 1 { out.append(o[i]); i += 1 }
            }
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    guard i < o.count, o[i] == line.text, line.origLine == i + 1 else { return false }
                    out.append(o[i]); i += 1
                case .removed:
                    guard i < o.count, o[i] == line.text, line.origLine == i + 1 else { return false }
                    i += 1
                case .added:
                    out.append(line.text)
                }
            }
        }
        while i < o.count { out.append(o[i]); i += 1 }
        return out == n
    }

    /// The O(m·n) LCS diff DiffEngine used before Myers, kept as the reference.
    static func legacyDiffLines(_ oldLines: [String], _ newLines: [String]) -> [DiffLine] {
        let m = oldLines.count, n = newLines.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in 1...m {
                for j in 1...n {
                    dp[i][j] = oldLines[i - 1] == newLines[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var matches: [(Int, Int)] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if oldLines[i - 1] == newLines[j - 1] { matches.append((i - 1, j - 1)); i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 }
            else { j -= 1 }
        }
        matches.reverse()
        var result: [DiffLine] = []
        var prevOld = -1, prevNew = -1
        for (oi, ni) in matches {
            for k in (prevOld + 1)..<oi { result.append(DiffLine(kind: .removed, text: oldLines[k], origLine: k + 1, newLine: -1)) }
            for k in (prevNew + 1)..<ni { result.append(DiffLine(kind: .added, text: newLines[k], origLine: -1, newLine: k + 1)) }
            result.append(DiffLine(kind: .context, text: oldLines[oi], origLine: oi + 1, newLine: ni + 1))
            prevOld = oi; prevNew = ni
        }
        for k in (prevOld + 1)..<m { result.append(DiffLine(kind: .removed, text: oldLines[k], origLine: k + 1, newLine: -1)) }
        for k in (prevNew + 1)..<n { result.append(DiffLine(kind: .added, text: newLines[k], origLine: -1, newLine: k + 1)) }
        return result
    }
}

/// Deterministic generator, so a failure reproduces.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(upTo bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
