import AppKit
import Observation

// MARK: - CompactStatusModel
//
// Feeds the compact island's status line (CompactStatus) from AppState: which pill, what its
// lead session does, and the measured width the island grows to (CompactIslandLayout).
// Changes are at least CompactStatus.minimumChangeInterval apart, so a burst of tool events
// doesn't flicker; the last one always shows. Its own @Observable object, not AppState: it is
// derived state (nothing to save or restore in the demo), and only the views that show the
// line redraw when it changes. No timer of its own: it works when AppState changes, the
// elapsed time ticks inside the line's view, which only exists while the compact island shows.

@MainActor
@Observable
final class CompactStatusModel {
    static let shared = CompactStatusModel()

    /// The line on screen, nil when no session is doing anything.
    private(set) var line: CompactStatusLine?
    /// What the compact island's size depends on; `.none` without a line.
    private(set) var metrics: CompactStatusMetrics = .none
    /// The mini Mochi under the pointer in the compact island (IslandWindowController's poll).
    var hoveredMiniId: String?

    private struct Target: Equatable {
        var line: CompactStatusLine?
        var hasMinis: Bool
    }

    @ObservationIgnored private var observer: ChangeObserver<Target>?
    @ObservationIgnored private var latest: Target?
    @ObservationIgnored private var lastChange: Date?
    @ObservationIgnored private var pending: DispatchWorkItem?

    private init() {}

    /// Starts following AppState (IslandWindowController, once the island exists).
    func start() {
        guard observer == nil else { return }
        observer = ChangeObserver({ Self.target(AppState.shared) }, initial: true,
                                  removeDuplicates: true) { [weak self] target in
            self?.receive(target)
        }
    }

    // MARK: Rate limit

    private func receive(_ target: Target) {
        latest = target
        guard pending == nil else { return }   // already scheduled: it shows the latest
        let delay = CompactStatus.changeDelay(lastChange: lastChange, now: Date())
        guard delay > 0 else { applyLatest(); return }
        // Formed on the main actor, run on the main queue (Swift 6 traps on any other).
        let work = DispatchWorkItem { [weak self] in self?.applyLatest() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyLatest() {
        pending = nil
        guard let target = latest else { return }
        latest = nil
        lastChange = Date()
        if target.line != line { line = target.line }
        let newMetrics = target.line.map {
            CompactStatusMetrics(statusWidth: Self.contentWidth($0), hasMinis: target.hasMinis)
        } ?? .none
        if newMetrics != metrics { metrics = newMetrics }
    }

    // MARK: From AppState

    private static let vocabulary = CompactStatusVocabulary.current

    private static func target(_ s: AppState) -> Target {
        let hasMinis = s.tasks.contains { $0.id != s.focusId }
        guard let pillId = CompactStatus.pickPill(focusId: s.focusId, books: s.sessionBooks),
              let task = s.tasks.first(where: { $0.id == pillId }),
              let lead = s.sessionBooks[pillId]?.lead,
              let activity = activity(lead: lead, task: task, state: s)
        else { return Target(line: nil, hasMinis: hasMinis) }
        let start = activity.kind.showsElapsed ? (lead.turnStartedAt ?? lead.startedAt) : nil
        let line = CompactStatusLine(
            pillId: pillId,
            pillName: CompactStatus.truncateTail(pillName(task), max: CompactStatus.maxNameLength),
            activity: activity, turnStartedAt: start)
        return Target(line: line, hasMinis: hasMinis)
    }

    private static func activity(lead: AgentSession, task: AgentTask, state s: AppState) -> CompactActivity? {
        let approval = s.pendingApproval.flatMap { $0.pillId == task.id ? $0.command : nil }
        let question = lead.phase == .waitingAnswer ? s.pendingQuestion?.questions.first?.question : nil
        return CompactStatus.activity(session: lead, thinking: task.state == .thinking,
                                      approvalCommand: approval, question: question,
                                      vocabulary: vocabulary)
    }

    /// The pill's name as its pill shows it (AgentPill): the Claude Code pill names its
    /// session's app ("VS Code", "Warp"…, else "Claude Code"), an IDE pill its IDE.
    static func pillName(_ task: AgentTask) -> String {
        task.id == "integration_claude"
            ? ClaudeHost.pillName(hostApp: task.hostApp, sessionBundleId: task.sessionBundleId)
            : (task.name.isEmpty ? (PillCatalog.definition(for: task.id)?.name ?? task.id) : task.name)
    }

    // MARK: Mini Mochi label

    /// "PyCharm · ▶ npm test" for a pill whose session is doing something, else
    /// "Vercel · idle": the label shown over a hovered mini Mochi.
    func miniLabel(for task: AgentTask, state s: AppState) -> (name: String, activity: CompactActivity?, word: String) {
        let name = CompactStatus.truncateTail(Self.pillName(task), max: CompactStatus.maxNameLength)
        if let lead = s.sessionBooks[task.id]?.lead,
           let activity = Self.activity(lead: lead, task: task, state: s) {
            return (name, activity, "")
        }
        return (name, nil, Self.stateWord(task.state))
    }

    static func stateWord(_ state: BotState) -> String {
        switch state {
        case .idle:      String(localized: "idle")
        case .working:   String(localized: "working")
        case .thinking:  String(localized: "thinking")
        case .searching: String(localized: "searching")
        case .approval:  String(localized: "waiting for your OK")
        case .question:  String(localized: "has a question")
        case .error:     String(localized: "error")
        case .finished:  String(localized: "done")
        case .ratelimit: String(localized: "rate limited")
        case .sleeping:  String(localized: "asleep")
        case .dizzy:     String(localized: "dizzy")
        }
    }

    // MARK: Measure (same fonts and spacing as CompactStatusView)

    static let spacing: CGFloat = 4
    static let iconWidth: CGFloat = 12
    static let timeGap: CGFloat = 6
    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let textFont = NSFont.systemFont(ofSize: 11)
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    /// Room kept for the elapsed time whatever it says, so it never resizes the island.
    private static let timeSlot: CGFloat = ["<1m", "59m", "23h"].map { width($0, timeFont) }.max() ?? 22

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Natural width of the line: name · icon text [time], plus a little slack.
    static func contentWidth(_ line: CompactStatusLine) -> CGFloat {
        var total = width(line.pillName, nameFont) + spacing + width("·", textFont) + spacing
            + iconWidth + spacing + width(line.text, textFont)
        if line.turnStartedAt != nil { total += timeGap + timeSlot }
        return total + 2
    }
}
