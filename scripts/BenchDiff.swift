import Foundation

// Old (O(m·n) LCS table) vs new (Myers) line diff, on synthetic files.
// Built by scripts/bench-diff.sh with -O together with CoucouKit/DiffEngine.swift.

@main
enum BenchDiff {
    static func main() {
        print("lines   changes        old LCS (table)          new Myers     same counts")
        for size in [1_000, 2_000, 5_000, 20_000] {
            for (label, changes) in [("few (3)", 3), ("many (10%)", size / 10), ("all", -1)] {
                let (old, new) = inputs(size: size, changes: changes)
                let cells = Double(old.count + 1) * Double(new.count + 1)
                let myers = time(runs: size >= 20_000 ? 3 : 7) { DiffEngine.diffLines(oldLines: old, newLines: new) }
                let oldColumn: String
                var same = "-"
                if cells * 8 > 1_000_000_000 {
                    oldColumn = String(format: "n/a (%.1f GB table)", cells * 8 / 1e9)
                } else {
                    let lcs = time(runs: size >= 5_000 ? 1 : 5) { legacyDiffLines(old, new) }
                    oldColumn = String(format: "%9.2f ms (%3.0f MB)", lcs.ms, cells * 8 / 1e6)
                    same = counts(lcs.result) == counts(myers.result) ? "yes" : "NO"
                }
                print(String(format: "%6d  ", size) + pad(label, 12) + "  " + pad(oldColumn, 22)
                      + String(format: "  %9.2f ms     ", myers.ms) + same)
            }
        }
        print("\nIn the app, fromEdit only diffs up to \(FileDiff.maxLines) lines in all (old + new) and")
        print("\(FileDiff.maxBytes / 1024) KB; bigger edits get the count fallback. The old LCS also gave up past")
        print("1,000,000 cells (about 1,000 × 1,000 lines), which Myers no longer needs.")
    }

    /// `size` distinct-looking source lines; `changes` lines replaced, inserted or deleted at
    /// spread positions (-1: a completely different file of the same size).
    static func inputs(size: Int, changes: Int) -> ([String], [String]) {
        let old = (0..<size).map { "    let value\($0) = compute(\($0 % 97), \($0))" }
        if changes < 0 { return (old, (0..<size).map { "    // rewritten line \($0)" }) }
        var new = old
        let step = max(1, size / max(1, changes))
        var index = size - 1
        var n = 0
        while n < changes && index >= 0 {
            switch n % 3 {
            case 0:  new[index] = "    let value\(index) = changed(\(index))"
            case 1:  new.insert("    // inserted \(index)", at: index)
            default: new.remove(at: index)
            }
            n += 1
            index -= step
        }
        return (old, new)
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func counts(_ lines: [DiffLine]) -> (Int, Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }

    /// Median wall time of `runs` runs.
    static func time<T>(runs: Int, _ body: () -> T) -> (ms: Double, result: T) {
        var samples: [Double] = []
        var last: T? = nil
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            last = body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        samples.sort()
        return (samples[samples.count / 2], last!)
    }

    /// The O(m·n) LCS diff DiffEngine used before Myers (verbatim algorithm).
    static func legacyDiffLines(_ oldLines: [String], _ newLines: [String]) -> [DiffLine] {
        let m = oldLines.count, n = newLines.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(1, m) {
            for j in 1...max(1, n) {
                guard i <= m && j <= n else { continue }
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
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
