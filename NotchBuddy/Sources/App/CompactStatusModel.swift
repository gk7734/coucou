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
//
// The same slot shows the sound visualizer (CompactVisualizer) when no agent works or waits
// and music plays: `music` is then set instead of `line`, and `metrics` measures it. This is
// also the one place that sets AudioSpectrum.isWanted (capture runs only while the
// visualizer is on screen), and it hands the bars their levels at most 30 times a second.

@MainActor
@Observable
final class CompactStatusModel {
    static let shared = CompactStatusModel()

    /// The line on screen, nil when no session is doing anything (or the visualizer shows).
    private(set) var line: CompactStatusLine?
    /// The music the visualizer shows, nil when it doesn't show. Never set with `line`.
    private(set) var music: CompactMusicLine?
    /// Band levels for the visualizer's bars, at most `CompactVisualizer.frameInterval`
    /// apart; only updated while capture is wanted.
    private(set) var levels: [Float] = Array(repeating: 0, count: CompactVisualizer.barCount)
    /// Settings → "Sound visualizer in the notch" (AudioSpectrum.visualizerKey), kept in step
    /// with UserDefaults so the slot follows the toggle at once.
    private(set) var visualizerEnabled = AudioSpectrum.visualizerEnabled
    /// What the compact island's size depends on; `.none` without a line.
    private(set) var metrics: CompactStatusMetrics = .none
    /// The mini Mochi under the pointer in the compact island (IslandWindowController's poll).
    var hoveredMiniId: String?

    private struct Target: Equatable {
        var slot: CompactSlot?
        var hasMinis: Bool
    }

    @ObservationIgnored private var observer: ChangeObserver<Target>?
    @ObservationIgnored private var wantedObserver: ChangeObserver<Bool>?
    @ObservationIgnored private var bandsObserver: ChangeObserver<[Float]>?
    @ObservationIgnored private var settingObserver: DefaultsKeyObserver?
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var pendingFrame: DispatchWorkItem?
    @ObservationIgnored private var latest: Target?
    @ObservationIgnored private var lastChange: Date?
    @ObservationIgnored private var pending: DispatchWorkItem?

    private init() {}

    /// Starts following AppState (IslandWindowController, once the island exists).
    func start() {
        guard observer == nil else { return }
        settingObserver = DefaultsKeyObserver(key: AudioSpectrum.visualizerKey) { [weak self] in
            let on = AudioSpectrum.visualizerEnabled
            if self?.visualizerEnabled != on { self?.visualizerEnabled = on }
        }
        observer = ChangeObserver({ Self.target(AppState.shared) }, initial: true,
                                  removeDuplicates: true) { [weak self] target in
            self?.receive(target)
        }
        // The one place that sets isWanted: the compact island shows the visualizer.
        wantedObserver = ChangeObserver({
            CompactVisualizer.wantsCapture(compact: AppState.shared.mode == .compact,
                                           showsMusic: CompactStatusModel.shared.music != nil)
        }, initial: true, removeDuplicates: true) { [weak self] wanted in
            AudioSpectrum.shared.isWanted = wanted
            self?.followBands(wanted)
        }
    }

    // MARK: Visualizer levels

    /// Follows AudioSpectrum.bands while capture is wanted; drops back to silence otherwise.
    private func followBands(_ wanted: Bool) {
        guard wanted else {
            bandsObserver = nil
            pendingFrame?.cancel()
            pendingFrame = nil
            if !CompactVisualizer.isSilent(levels) {
                levels = Array(repeating: 0, count: CompactVisualizer.barCount)
            }
            return
        }
        guard bandsObserver == nil else { return }
        bandsObserver = ChangeObserver({ AudioSpectrum.shared.bands }, initial: true,
                                       removeDuplicates: true) { [weak self] _ in
            self?.scheduleFrame()
        }
    }

    /// New levels: shown now, or at the next frame (at most 30 a second).
    private func scheduleFrame() {
        guard pendingFrame == nil else { return }   // the scheduled frame reads the latest
        let delay = CompactVisualizer.frameDelay(lastFrame: lastFrame, now: Date())
        guard delay > 0 else { showFrame(); return }
        // Formed on the main actor, run on the main queue (Swift 6 traps on any other).
        let work = DispatchWorkItem { [weak self] in self?.showFrame() }
        pendingFrame = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showFrame() {
        pendingFrame = nil
        lastFrame = Date()
        let bands = AudioSpectrum.shared.bands
        if bands != levels { levels = bands }
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
        var newLine: CompactStatusLine? = nil, newMusic: CompactMusicLine? = nil
        switch target.slot {
        case .status(let l)?: newLine = l
        case .music(let m)?:  newMusic = m
        case nil:             break
        }
        if newLine != line { line = newLine }
        if newMusic != music { music = newMusic }
        let width: CGFloat? = switch target.slot {
        case .status(let l)?: Self.contentWidth(l)
        case .music(let m)?:  Self.musicContentWidth(m)
        case nil:             nil
        }
        let newMetrics = width.map { CompactStatusMetrics(statusWidth: $0, hasMinis: target.hasMinis) } ?? .none
        if newMetrics != metrics { metrics = newMetrics }
    }

    // MARK: From AppState

    private static let vocabulary = CompactStatusVocabulary.current

    private static func target(_ s: AppState) -> Target {
        let hasMinis = s.tasks.contains { $0.id != s.focusId }
        let slot = CompactVisualizer.slot(
            line: statusLine(s),
            agentsBusy: CompactVisualizer.agentsBusy(books: s.sessionBooks),
            music: CompactVisualizer.musicLine(NowPlayingCenter.shared.current, audibleApp: audibleApp()),
            visualizerEnabled: CompactStatusModel.shared.visualizerEnabled)
        return Target(slot: slot, hasMinis: hasMinis)
    }

    /// The app making sound when no music feed reports a track: the first one with a bundle
    /// id that isn't a system sound daemon ("Sound" when none is named).
    private static func audibleApp() -> (bundleId: String, name: String)? {
        let spectrum = AudioSpectrum.shared
        guard spectrum.isAudible else { return nil }
        let ignored: Set<String> = ["com.apple.systemsoundserverd", "com.apple.coreaudiod",
                                    "com.apple.audio.SandboxHelper"]
        if let id = spectrum.audibleBundleIds.first(where: { !$0.isEmpty && !ignored.contains($0) }) {
            return (id, HostAppInfo.name(for: id))
        }
        return spectrum.audibleBundleIds.isEmpty ? ("", String(localized: "Sound")) : nil
    }

    private static func statusLine(_ s: AppState) -> CompactStatusLine? {
        guard let pillId = CompactStatus.pickPill(focusId: s.focusId, books: s.sessionBooks),
              let task = s.tasks.first(where: { $0.id == pillId }),
              let lead = s.sessionBooks[pillId]?.lead,
              let activity = activity(lead: lead, task: task, state: s)
        else { return nil }
        let start = activity.kind.showsElapsed ? (lead.turnStartedAt ?? lead.startedAt) : nil
        return CompactStatusLine(
            pillId: pillId,
            pillName: CompactStatus.truncateTail(pillName(task), max: CompactStatus.maxNameLength),
            activity: activity, turnStartedAt: start)
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
        // Slack for SwiftUI's text layout, which renders a few points wider than NSString
        // measures (the line was truncated by about one character without it).
        return total + 6
    }

    /// Natural width of the visualizer: bars, "♪", title (semibold) " · artist", plus slack.
    /// Same fonts and spacing as CompactVisualizerView.
    static func musicContentWidth(_ music: CompactMusicLine) -> CGFloat {
        var total = CompactVisualizer.barsWidth + CompactVisualizer.barsToText
            + width("♪", textFont) + spacing + width(music.headline, nameFont)
        if !music.subline.isEmpty { total += width(" · " + music.subline, textFont) }
        return total + 6
    }
}

// MARK: - DefaultsKeyObserver

/// Calls back on the main actor when a UserDefaults key changes, from this process (an
/// @AppStorage toggle) or another (`defaults write`). KVO may call from any thread: the
/// callback only hops to the main queue. Stops when released.
final class DefaultsKeyObserver: NSObject, @unchecked Sendable {
    private let key: String
    private let onChange: @MainActor () -> Void

    @MainActor
    init(key: String, onChange: @escaping @MainActor () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        AppDefaults.store.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        AppDefaults.store.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        let onChange = self.onChange
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onChange() }
        }
    }
}
