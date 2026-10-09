import Foundation

// MARK: - Types

struct DiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed }
    var kind: Kind
    var text: String
    var origLine: Int   // 1-based; -1 for pure adds
    var newLine: Int    // 1-based; -1 for pure removes
}

struct DiffHunk: Equatable {
    var origStart: Int
    var newStart: Int
    var lines: [DiffLine]
}

struct FileDiff: Equatable {
    var id: Int = 0         // stable identifier assigned by AppState.appendSessionDiff
    var path: String
    var added: Int
    var removed: Int
    var hunks: [DiffHunk]
    var tooLarge: Bool
    var isNewFile: Bool     // true when produced by DiffEngine.fromNew (Write tool)

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    static let maxBytes = 200 * 1024
    static let maxLines = 4000
}

// MARK: - DiffEngine

enum DiffEngine {

    // MARK: Public API

    static func fromEdit(old: String, new: String, path: String) -> FileDiff {
        // Size guard
        if old.utf8.count + new.utf8.count > FileDiff.maxBytes {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        if oldLines.count + newLines.count > FileDiff.maxLines {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        // Myers costs O((N+M)·D): within maxLines even two unrelated files stay in the
        // low milliseconds, so no further cap is needed (the old O(N·M) LCS bailed out
        // past 1,000,000 cells).
        let flat = diffLines(oldLines: oldLines, newLines: newLines)
        let hunks = buildHunks(from: flat, context: 3)
        let added   = flat.filter { $0.kind == .added   }.count
        let removed = flat.filter { $0.kind == .removed }.count
        return FileDiff(path: path, added: added, removed: removed, hunks: hunks, tooLarge: false, isNewFile: false)
    }

    static func fromNew(content: String, path: String) -> FileDiff {
        // Size guard (same limits as fromEdit)
        if content.utf8.count > FileDiff.maxBytes {
            let lineCount = content.components(separatedBy: "\n").count
            return FileDiff(path: path, added: lineCount, removed: 0, hunks: [], tooLarge: true, isNewFile: true)
        }
        let lines = splitLines(content)
        if lines.count > FileDiff.maxLines {
            return FileDiff(path: path, added: lines.count, removed: 0, hunks: [], tooLarge: true, isNewFile: true)
        }
        let diffLines = lines.enumerated().map { (i, text) in
            DiffLine(kind: .added, text: text, origLine: -1, newLine: i + 1)
        }
        let hunk = diffLines.isEmpty ? nil : DiffHunk(origStart: 0, newStart: 1, lines: diffLines)
        return FileDiff(
            path: path,
            added: diffLines.count,
            removed: 0,
            hunks: hunk.map { [$0] } ?? [],
            tooLarge: false,
            isNewFile: true
        )
    }

    // MARK: - Line splitting

    private static func splitLines(_ text: String) -> [String] {
        // Normalize CRLF → LF
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parts = normalized.components(separatedBy: "\n")
        // Drop trailing empty element that results from a trailing newline
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - Myers diff

    /// The line-level edit script between two files, as a flat list: context lines in order,
    /// and between two context lines the removed lines first, then the added ones.
    ///
    /// Myers' O((N+M)·D) algorithm, linear-space variant (middle snake, divide and conquer),
    /// so a 4,000-line file with a few changed lines costs a few thousand comparisons instead
    /// of a 16-million-cell table. The common suffix is matched before the common prefix, like
    /// the LCS backtracking this replaced, so one contiguous edit gives the same hunks as before.
    /// When several edit scripts are equally short (repeated lines inside a changed region),
    /// the one picked may differ from the old LCS; `added` and `removed` never do (both are
    /// minimal: N − LCS and M − LCS).
    static func diffLines(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let m = oldLines.count
        let n = newLines.count
        let script = MyersScript(old: oldLines, new: newLines)

        var result: [DiffLine] = []
        result.reserveCapacity(max(m, n) + script.removedCount + script.insertedCount)
        var i = 0, j = 0
        while i < m || j < n {
            let i0 = i, j0 = j
            while i < m && script.removed[i]  { i += 1 }
            while j < n && script.inserted[j] { j += 1 }
            for k in i0..<i {
                result.append(DiffLine(kind: .removed, text: oldLines[k], origLine: k + 1, newLine: -1))
            }
            for k in j0..<j {
                result.append(DiffLine(kind: .added, text: newLines[k], origLine: -1, newLine: k + 1))
            }
            guard i < m && j < n else { break }   // both ends reached (kept lines pair up 1:1)
            result.append(DiffLine(kind: .context, text: oldLines[i], origLine: i + 1, newLine: j + 1))
            i += 1; j += 1
        }
        return result
    }

    /// Which old lines are removed and which new lines are inserted, minimal (Myers 1986, with
    /// the bounded middle-snake search of diff-match-patch's `bisect`).
    private struct MyersScript {
        private(set) var removed: [Bool]
        private(set) var inserted: [Bool]
        private(set) var removedCount = 0
        private(set) var insertedCount = 0

        init(old: [String], new: [String]) {
            removed = [Bool](repeating: false, count: old.count)
            inserted = [Bool](repeating: false, count: new.count)
            // Lines become small integers: comparisons in the inner loop are Int32 compares.
            var ids: [String: Int32] = [:]
            ids.reserveCapacity(old.count + new.count)
            func intern(_ lines: [String]) -> [Int32] {
                lines.map { line in
                    if let id = ids[line] { return id }
                    let id = Int32(ids.count)
                    ids[line] = id
                    return id
                }
            }
            let a = intern(old)
            let b = intern(new)
            // Scratch V arrays, sized for the whole problem and reused by every sub-problem.
            let vSize = 2 * ((a.count + b.count + 1) / 2) + 4
            var v1 = [Int](repeating: -1, count: vSize)
            var v2 = [Int](repeating: -1, count: vSize)
            var removed = self.removed, inserted = self.inserted
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    v1.withUnsafeMutableBufferPointer { v1 in
                        v2.withUnsafeMutableBufferPointer { v2 in
                            removed.withUnsafeMutableBufferPointer { removed in
                                inserted.withUnsafeMutableBufferPointer { inserted in
                                    let w = Walker(a: a, b: b, v1: v1, v2: v2, removed: removed, inserted: inserted)
                                    w.compare(0, a.count, 0, b.count)
                                }
                            }
                        }
                    }
                }
            }
            self.removed = removed
            self.inserted = inserted
            removedCount = removed.reduce(0) { $1 ? $0 + 1 : $0 }
            insertedCount = inserted.reduce(0) { $1 ? $0 + 1 : $0 }
        }

        private struct Walker {
            let a: UnsafeBufferPointer<Int32>
            let b: UnsafeBufferPointer<Int32>
            let v1: UnsafeMutableBufferPointer<Int>
            let v2: UnsafeMutableBufferPointer<Int>
            let removed: UnsafeMutableBufferPointer<Bool>
            let inserted: UnsafeMutableBufferPointer<Bool>

            /// Diffs a[aLo..<aHi] against b[bLo..<bHi].
            func compare(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) {
                var aLo = aLo, aHi = aHi, bLo = bLo, bHi = bHi
                // Common suffix first, then common prefix (see diffLines).
                while aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1 }
                while aLo < aHi && bLo < bHi && a[aLo] == b[bLo] { aLo += 1; bLo += 1 }
                if aLo == aHi {
                    for j in bLo..<bHi { inserted[j] = true }
                    return
                }
                if bLo == bHi {
                    for i in aLo..<aHi { removed[i] = true }
                    return
                }
                if let (x, y) = middleSnake(aLo, aHi, bLo, bHi) {
                    compare(aLo, x, bLo, y)
                    compare(x, aHi, y, bHi)
                } else {
                    // No common line at all.
                    for i in aLo..<aHi { removed[i] = true }
                    for j in bLo..<bHi { inserted[j] = true }
                }
            }

            /// A point (x, y) on a shortest edit path through the box, strictly inside it in
            /// edit distance (both halves need fewer edits than the whole), nil when the two
            /// ranges have nothing in common. Coordinates are absolute indices into a and b.
            private func middleSnake(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> (Int, Int)? {
                let n = aHi - aLo, m = bHi - bLo
                let maxD = (n + m + 1) / 2
                let offset = maxD + 1
                let vLength = 2 * maxD + 3
                for k in 0..<vLength { v1[k] = -1; v2[k] = -1 }
                v1[offset + 1] = 0
                v2[offset + 1] = 0
                let delta = n - m
                let front = delta & 1 != 0   // odd delta: the paths meet on a forward step
                var k1start = 0, k1end = 0, k2start = 0, k2end = 0
                for d in 0..<maxD {
                    // Forward path, from the top-left corner.
                    var k1 = -d + k1start
                    while k1 <= d - k1end {
                        let k1o = offset + k1
                        var x1 = (k1 == -d || (k1 != d && v1[k1o - 1] < v1[k1o + 1])) ? v1[k1o + 1] : v1[k1o - 1] + 1
                        var y1 = x1 - k1
                        while x1 < n && y1 < m && a[aLo + x1] == b[bLo + y1] { x1 += 1; y1 += 1 }
                        v1[k1o] = x1
                        if x1 > n {
                            k1end += 2          // ran off the right edge
                        } else if y1 > m {
                            k1start += 2        // ran off the bottom edge
                        } else if front {
                            let k2o = offset + delta - k1
                            if k2o >= 0 && k2o < vLength && v2[k2o] != -1 {
                                let x2 = n - v2[k2o]
                                if x1 >= x2 { return (aLo + x1, bLo + y1) }
                            }
                        }
                        k1 += 2
                    }
                    // Reverse path, from the bottom-right corner (x2, y2 count from the end).
                    var k2 = -d + k2start
                    while k2 <= d - k2end {
                        let k2o = offset + k2
                        var x2 = (k2 == -d || (k2 != d && v2[k2o - 1] < v2[k2o + 1])) ? v2[k2o + 1] : v2[k2o - 1] + 1
                        var y2 = x2 - k2
                        while x2 < n && y2 < m && a[aHi - x2 - 1] == b[bHi - y2 - 1] { x2 += 1; y2 += 1 }
                        v2[k2o] = x2
                        if x2 > n {
                            k2end += 2
                        } else if y2 > m {
                            k2start += 2
                        } else if !front {
                            let k1o = offset + delta - k2
                            if k1o >= 0 && k1o < vLength && v1[k1o] != -1 {
                                let x1 = v1[k1o]
                                let y1 = x1 - (k1o - offset)
                                if x1 >= n - x2 { return (aLo + x1, bLo + y1) }
                            }
                        }
                        k2 += 2
                    }
                }
                return nil
            }
        }
    }

    // MARK: - Hunk building

    private static func buildHunks(from lines: [DiffLine], context: Int) -> [DiffHunk] {
        guard !lines.isEmpty else { return [] }

        // Find indices of changed lines
        var changedIndices: [Int] = []
        for (i, line) in lines.enumerated() {
            if line.kind != .context { changedIndices.append(i) }
        }
        guard !changedIndices.isEmpty else { return [] }

        // Expand ±context around each changed line
        let ranges: [(Int, Int)] = changedIndices.map {
            (max(0, $0 - context), min(lines.count - 1, $0 + context))
        }

        // Merge overlapping ranges
        var merged: [(Int, Int)] = []
        for r in ranges {
            if let last = merged.last, r.0 <= last.1 + 1 {
                merged[merged.count - 1] = (last.0, max(last.1, r.1))
            } else {
                merged.append(r)
            }
        }

        // Build hunks
        var hunks: [DiffHunk] = []
        for (start, end) in merged {
            let hunkLines = Array(lines[start...end])
            let origStart = hunkLines.first(where: { $0.origLine > 0 })?.origLine ?? 1
            let newStart  = hunkLines.first(where: { $0.newLine > 0 })?.newLine  ?? 1
            hunks.append(DiffHunk(origStart: origStart, newStart: newStart, lines: hunkLines))
        }
        return hunks
    }

    // MARK: - Count fallback (tooLarge)

    private static func countFallback(old: String, new: String, path: String, tooLarge: Bool) -> FileDiff {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let added   = newLines.filter { !$0.isEmpty && !oldSet.contains($0) }.count
        let removed = oldLines.filter { !$0.isEmpty && !newSet.contains($0) }.count
        return FileDiff(path: path, added: added, removed: removed, hunks: [], tooLarge: tooLarge, isNewFile: false)
    }

    // MARK: - toOneLine

    /// Converts a possibly multi-line, markdown-formatted string to a single line of plain text.
    /// Uses only the first non-empty paragraph (stops at blank line, horizontal rule, or table row).
    /// Strips `**`, `__`, backticks, leading `#`, and leading bullet markers.
    static func toOneLine(_ text: String, maxChars: Int = 200) -> String {
        let lines = text.components(separatedBy: "\n")

        // Split into paragraphs. Separators: blank line, HR (3+ repeated -/*/_ chars), table row (starts with |).
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHR = trimmed.count >= 3 && (trimmed.allSatisfy { $0 == "-" } ||
                                               trimmed.allSatisfy { $0 == "*" } ||
                                               trimmed.allSatisfy { $0 == "_" })
            let isSep = trimmed.isEmpty || isHR || trimmed.hasPrefix("|")
            if isSep {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        // Find first paragraph that yields non-empty text after cleaning.
        for paraLines in paragraphs {
            var s = paraLines.joined(separator: "\n")
            s = s.replacingOccurrences(of: "**", with: "")
            s = s.replacingOccurrences(of: "__", with: "")
            s = s.replacingOccurrences(of: "`", with: "")
            let processed: [String] = s.components(separatedBy: "\n").compactMap { line in
                var l = line
                while l.hasPrefix("#") { l = String(l.dropFirst()) }
                l = l.trimmingCharacters(in: .whitespaces)
                // Strip leading bullet markers: -, *, •, or N. (ordered list)
                if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") {
                    l = String(l.dropFirst(2))
                } else if let m = l.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                    l = String(l[m.upperBound...])
                }
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            let joined = processed.joined(separator: " ")
            let collapsed = joined.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty { return String(collapsed.prefix(maxChars)) }
        }
        return ""
    }
}

// MARK: - String diff step encoding

public extension String {
    /// Private-use character used as the diff step marker prefix.
    static let diffStepMarker = "\u{E001}"

    /// True if this step string encodes a file diff.
    var isDiffStep: Bool { hasPrefix(Self.diffStepMarker) }

    /// Parses a diff step string.
    /// Format: `"\u{E001}<filename>\t<added>:<removed>:<diffId>"`
    func parseDiffStep() -> (filename: String, added: Int, removed: Int, diffId: Int)? {
        guard isDiffStep else { return nil }
        let body = String(dropFirst())   // drop the marker character
        guard let tabIdx = body.firstIndex(of: "\t") else { return nil }
        let filename = String(body[body.startIndex..<tabIdx])
        let rest = String(body[body.index(after: tabIdx)...])
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let added  = Int(parts[0]),
              let removed = Int(parts[1]),
              let diffId  = Int(parts[2]) else { return nil }
        return (filename, added, removed, diffId)
    }

    /// Creates a diff step string from its components.
    static func makeDiffStep(filename: String, added: Int, removed: Int, diffId: Int) -> String {
        "\(diffStepMarker)\(filename)\t\(added):\(removed):\(diffId)"
    }
}
