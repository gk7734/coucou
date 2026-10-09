import Foundation
import CoreGraphics

// MARK: - CompactStatus
//
// The live status line of the compact island: which pill it is about, what that pill's lead
// session is doing (from the human-readable steps HookServer records), how long the turn has
// run, and how wide the island must be to show it. Foundation + CoreGraphics only, so it can
// be tested without AppKit (see scripts/test-compact-status.sh).

/// What a session is doing, as the status line shows it (an icon, then a short text).
enum CompactActivityKind: String, Equatable, Sendable {
    case thinking, edit, command, search, read, web, other
    case done, error, needsOK, asks

    /// The user is the one holding it up: the line turns amber and opens the card on click.
    var waitsOnUser: Bool { self == .needsOK || self == .asks }

    /// The agent is at work: the line shows how long the turn has run.
    var showsElapsed: Bool {
        switch self {
        case .thinking, .edit, .command, .search, .read, .web, .other: true
        case .done, .error, .needsOK, .asks: false
        }
    }

    /// SF Symbol drawn before the text.
    var symbolName: String {
        switch self {
        case .thinking: "sparkles"
        case .edit:     "pencil"
        case .command:  "play.fill"
        case .search:   "magnifyingglass"
        case .read:     "book"
        case .web:      "globe"
        case .other:    "ellipsis"
        case .done:     "checkmark"
        case .error:    "exclamationmark.triangle.fill"
        case .needsOK:  "hand.raised.fill"
        case .asks:     "questionmark.bubble.fill"
        }
    }
}

struct CompactActivity: Equatable, Sendable {
    var kind: CompactActivityKind
    /// The file, command, query… already shortened. Empty when there is nothing to add.
    var detail: String
}

/// One status line: the pill it is about and what its lead session does.
struct CompactStatusLine: Equatable, Sendable {
    var pillId: String
    /// The pill's name as its pill shows it ("Orca", "VS Code", "Claude Code"…), shortened.
    var pillName: String
    var activity: CompactActivity
    /// Start of the current turn while the agent works (the line shows "3m"), else nil.
    var turnStartedAt: Date?

    var text: String { CompactStatus.text(activity) }
}

/// The step verbs HookServer.localizedStep writes before " · ", in the app's language, so
/// the steps can be read back whatever the language.
struct CompactStatusVocabulary: Sendable {
    var runs: String
    var tests: String
    var reads: String
    var writes: String
    var edits: String
    var searches: String
    var lists: String
    var webSearch: String
    var fetches: String

    static let english = CompactStatusVocabulary(
        runs: "Runs", tests: "Tests", reads: "Reads", writes: "Writes", edits: "Edits",
        searches: "Searches", lists: "Lists", webSearch: "Searches the web", fetches: "Fetches")

    /// Same keys and defaults as HookServer.localizedStep.
    static var current: CompactStatusVocabulary {
        CompactStatusVocabulary(
            runs:      String(localized: "step.runs",       defaultValue: "Runs"),
            tests:     String(localized: "step.tests",      defaultValue: "Tests"),
            reads:     String(localized: "step.reads",      defaultValue: "Reads"),
            writes:    String(localized: "step.writes",     defaultValue: "Writes"),
            edits:     String(localized: "step.edits",      defaultValue: "Edits"),
            searches:  String(localized: "step.searches",   defaultValue: "Searches"),
            lists:     String(localized: "step.lists",      defaultValue: "Lists"),
            webSearch: String(localized: "step.web-search", defaultValue: "Searches the web"),
            fetches:   String(localized: "step.fetches",    defaultValue: "Fetches"))
    }

    func kind(forVerb verb: String) -> CompactActivityKind? {
        switch verb {
        case edits, writes:     .edit
        case runs, tests:       .command
        case reads:             .read
        case searches, lists:   .search
        case webSearch, fetches: .web
        default:                nil
        }
    }
}

enum CompactStatus {

    /// Shortest time between two changes of the line: a burst of tool events doesn't flicker.
    static let minimumChangeInterval: TimeInterval = 0.4

    static let maxNameLength = 18
    static let maxFileLength = 30
    static let maxDetailLength = 44

    // MARK: Which pill

    /// The pill the line is about, nil when no session is doing anything (the compact
    /// island then looks as before). In order:
    ///   1. a session waiting on the user, when the focused pill's isn't (the most urgent,
    ///      the most recent among equals);
    ///   2. the focused pill, the one the big Mochi shows, when its lead session isn't idle;
    ///   3. the most urgent other pill whose lead isn't idle (the most recent among equals).
    static func pickPill(focusId: String?, books: [String: SessionBook]) -> String? {
        let active = books.compactMap { id, book -> (id: String, lead: AgentSession)? in
            guard let lead = book.lead, lead.phase != .idle else { return nil }
            return (id, lead)
        }
        func best(_ list: [(id: String, lead: AgentSession)]) -> String? {
            list.max { a, b in
                if a.lead.phase.urgency != b.lead.phase.urgency { return a.lead.phase.urgency < b.lead.phase.urgency }
                if a.lead.lastEventAt != b.lead.lastEventAt { return a.lead.lastEventAt < b.lead.lastEventAt }
                return a.id > b.id   // a stable choice between equals
            }?.id
        }
        let focused = active.first { $0.id == focusId }
        if focused?.lead.phase.waitsOnUser != true,
           let waiting = best(active.filter { $0.lead.phase.waitsOnUser }) {
            return waiting
        }
        if let focused { return focused.id }
        return best(active)
    }

    // MARK: What it does

    /// What the line says about a session, nil for an idle one.
    /// - thinking: the pill's Mochi thinks (a prompt was just sent, no tool yet).
    /// - approvalCommand: the command of the approval waiting for this pill, if known.
    /// - question: the question waiting for this pill, if known.
    static func activity(session: AgentSession, thinking: Bool,
                         approvalCommand: String? = nil, question: String? = nil,
                         vocabulary: CompactStatusVocabulary = .current) -> CompactActivity? {
        switch session.phase {
        case .idle:
            return nil
        case .waitingApproval:
            return CompactActivity(kind: .needsOK, detail: truncateTail(oneLine(approvalCommand ?? ""), max: maxDetailLength))
        case .waitingAnswer:
            return CompactActivity(kind: .asks, detail: truncateTail(oneLine(question ?? ""), max: maxDetailLength))
        case .error:
            return CompactActivity(kind: .error, detail: "")
        case .finished:
            return CompactActivity(kind: .done, detail: truncateTail(oneLine(session.finalLine ?? ""), max: maxDetailLength))
        case .working:
            guard !thinking, let step = session.steps.last, !oneLine(step).isEmpty else {
                return CompactActivity(kind: .thinking, detail: "")
            }
            return classify(step: step, vocabulary: vocabulary)
        }
    }

    /// Reads one step back: "Edits · HookServer.swift" → edit, "Tests · npm test" → command…
    /// A step it doesn't know is shown as it is, shortened.
    static func classify(step: String, vocabulary: CompactStatusVocabulary = .current) -> CompactActivity {
        if let diff = step.parseDiffStep() {
            return CompactActivity(kind: .edit, detail: shortFileName(diff.filename))
        }
        let line = oneLine(step)
        let parts = line.components(separatedBy: " · ")
        let verb = parts[0]
        let rest = parts.dropFirst().joined(separator: " · ")
        guard let kind = vocabulary.kind(forVerb: verb) else {
            return CompactActivity(kind: .other, detail: truncateTail(line, max: maxDetailLength))
        }
        switch kind {
        case .edit, .read:
            // A file from the tool's input; "Reads · cat a.txt" (a shell command) stays a command line.
            if rest.isEmpty { return CompactActivity(kind: kind, detail: verb) }
            let isPath = !rest.contains(" ")
            return CompactActivity(kind: kind, detail: isPath ? shortFileName(rest)
                                                              : truncateTail(rest, max: maxDetailLength))
        default:
            return CompactActivity(kind: kind, detail: truncateTail(rest.isEmpty ? verb : rest, max: maxDetailLength))
        }
    }

    /// The text after the icon.
    static func text(_ activity: CompactActivity) -> String {
        let detail = activity.detail
        switch activity.kind {
        case .thinking:
            return String(localized: "Thinking…")
        case .done:
            return detail.isEmpty ? String(localized: "Done") : String(localized: "Done: \(detail)")
        case .error:
            return String(localized: "Error")
        case .needsOK:
            return detail.isEmpty ? String(localized: "Needs your OK") : String(localized: "Needs your OK: \(detail)")
        case .asks:
            return detail.isEmpty ? String(localized: "Has a question") : String(localized: "Asks: \(detail)")
        case .edit, .command, .search, .read, .web, .other:
            return detail
        }
    }

    /// How long the turn has run: "<1m", "2m", "1h".
    static func elapsedLabel(since start: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }

    /// Seconds to wait before showing a new line, so two changes are at least
    /// `minimumChangeInterval` apart. 0: show it now.
    static func changeDelay(lastChange: Date?, now: Date) -> TimeInterval {
        guard let lastChange else { return 0 }
        return max(0, minimumChangeInterval - now.timeIntervalSince(lastChange))
    }

    // MARK: Text helpers

    /// Whitespace and newlines collapsed to single spaces, trimmed.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The file name of a path, middle-truncated so its extension stays visible.
    static func shortFileName(_ path: String) -> String {
        let trimmed = oneLine(path)
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return truncateMiddle(name, max: maxFileLength)
    }

    static func truncateTail(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func truncateMiddle(_ text: String, max: Int) -> String {
        guard text.count > max, max > 2 else { return text }
        let keep = max - 1
        let head = (keep + 1) / 2
        let tail = keep - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}

// MARK: - Compact island layout

/// What the compact island needs to know about its status line to size itself.
struct CompactStatusMetrics: Equatable, Sendable {
    /// Natural width of the line's content (name, icon, text, elapsed time); 0 = no line.
    var statusWidth: CGFloat
    /// Mini Mochis sit at the right end (the island keeps room for them).
    var hasMinis: Bool

    static let none = CompactStatusMetrics(statusWidth: 0, hasMinis: false)
}

/// Where everything sits in the compact island. The single source of the compact width,
/// its offset and its hit regions: IslandContainer, the panel's hit test, Mochi's gaze and
/// the click handling all read it (through `islandSize`).
///
/// Without a status line it is the island as it always was: notch width + two 80 pt ears,
/// Mochi centred in the left ear, the mini grid in the right one.
///
/// With a line:
/// - Notched screen: the centre of the island is the physical notch, so the line goes in the
///   RIGHT ear, which grows (up to `maxEar`, and never past the 720 pt panel); the left ear and
///   Mochi do not move. The island is no longer centred on the screen: `offsetX` moves its
///   centre right by half the growth, which keeps its notch part on the notch.
///   Right ear = 10 (gap after the notch) + line + 8 + 54 (mini grid and its margin).
/// - No notch (a bar at the top centre): the line sits between Mochi and the minis, the bar
///   widens around its centre: 58 (Mochi) + line + 8 + 54, at least 240, at most 420.
struct CompactIslandLayout: Equatable {
    static let earWidth: CGFloat = 80
    static let botCenterX: CGFloat = 40
    /// Mini grid centre, from the right edge (IslandRestingLayout.miniGridCenterX).
    static let miniInset: CGFloat = 40
    /// The mini grid's left edge, from the right edge (28 pt grid around `miniInset`).
    static let miniZone: CGFloat = 54
    static let notchGap: CGFloat = 10
    /// Start of the line on a notchless bar: Mochi spans 30…50.
    static let barTextStart: CGFloat = 58
    static let textToMinis: CGFloat = 8
    static let trailingWithoutMinis: CGFloat = 14
    static let maxEar: CGFloat = 300
    static let maxBarWidth: CGFloat = 420
    /// Room kept between the island and the panel's edge.
    static let panelMargin: CGFloat = 4

    let width: CGFloat
    /// Island centre minus panel (screen) centre.
    let offsetX: CGFloat
    /// The line's frame, in island coordinates (x from the island's left edge).
    let statusX: CGFloat
    let statusWidth: CGFloat

    var miniGridCenterX: CGFloat { width - Self.miniInset }
    var hasStatus: Bool { statusWidth > 0 }

    /// `panelWidth`: the transparent panel the island is drawn in (IslandConst.panelWidth).
    init(notchWidth nw: CGFloat, hasNotch: Bool, status: CompactStatusMetrics,
         panelWidth: CGFloat = 720) {
        let plain = nw + 2 * Self.earWidth
        guard status.statusWidth > 0 else {
            width = plain; offsetX = 0; statusX = 0; statusWidth = 0
            return
        }
        let trailing = status.hasMinis ? Self.textToMinis + Self.miniZone : Self.trailingWithoutMinis
        if hasNotch {
            let room = panelWidth / 2 - nw / 2 - Self.panelMargin
            let maxEar = max(Self.earWidth, min(Self.maxEar, room))
            let rightEar = min(maxEar, max(Self.earWidth, Self.notchGap + status.statusWidth + trailing))
            width = Self.earWidth + nw + rightEar
            offsetX = (rightEar - Self.earWidth) / 2
            statusX = Self.earWidth + nw + Self.notchGap
            statusWidth = max(0, rightEar - Self.notchGap - trailing)
        } else {
            let maxWidth = max(plain, min(Self.maxBarWidth, panelWidth - 2 * Self.panelMargin))
            width = min(maxWidth, max(plain, Self.barTextStart + status.statusWidth + trailing))
            offsetX = 0
            statusX = Self.barTextStart
            statusWidth = max(0, width - Self.barTextStart - trailing)
        }
    }

    /// The line's hit region (full island height), island coordinates.
    func statusContains(x: CGFloat) -> Bool {
        hasStatus && x >= statusX && x <= statusX + statusWidth
    }

    /// Centres of the mini Mochis around the grid's centre, unscaled: two fixed 12 pt
    /// columns 4 pt apart, rows filled left to right; one row is centred vertically in the
    /// 28 pt grid (CompactMiniGrid's LazyVGrid).
    static func miniCellOffsets(count: Int) -> [CGPoint] {
        let n = min(4, max(0, count))
        let rows = (n + 1) / 2
        return (0..<n).map { i in
            let x: CGFloat = i % 2 == 0 ? -8 : 8
            let y: CGFloat = rows < 2 ? 0 : (i < 2 ? -8 : 8)
            return CGPoint(x: x, y: y)
        }
    }

    /// The mini under a point (island coordinates, y down from the top), nil when none.
    /// `scale`: the grid's scale (IslandRestingLayout.miniGridScale).
    func miniIndex(atX x: CGFloat, y: CGFloat, height: CGFloat, count: Int, scale: CGFloat) -> Int? {
        let cx = miniGridCenterX, cy = height / 2
        let half: CGFloat = 8 * scale   // the 12 pt cell and half the 4 pt gap on each side
        for (i, o) in Self.miniCellOffsets(count: count).enumerated() {
            if abs(x - (cx + o.x * scale)) <= half && abs(y - (cy + o.y * scale)) <= half { return i }
        }
        return nil
    }
}
