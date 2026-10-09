import Foundation

// MARK: - StallMonitor
//
// Notices working sessions that went quiet (no hook event for `stallThresholdMinutes`):
// badges their pill `.stalled` and posts one `.stalled` SessionAlert per episode.
// One DispatchWorkItem armed for the next session that could stall, re-armed on every
// sessionBooks change; nothing armed while no session is working (0 % CPU when idle).

@MainActor
final class StallMonitor {
    static let shared = StallMonitor()

    private var tracker = StallTracker()
    private var books: [String: SessionBook] = [:]
    private var observer: ChangeObserver<[String: SessionBook]>?
    private var timer: DispatchWorkItem?

    private init() {}

    func start() {
        guard observer == nil else { return }
        // Checked now, then once per main-queue turn in which the books changed.
        observer = ChangeObserver({ AppState.shared.sessionBooks }, initial: true) { [weak self] books in
            self?.check(books)
        }
    }

    /// The threshold changed in Settings.
    func refresh() { check(AppState.shared.sessionBooks) }

    private func check(_ books: [String: SessionBook]) {
        self.books = books
        timer?.cancel()
        timer = nil

        let minutes = NotificationSettings.stallMinutes(defaults: AppDefaults.store)
        let threshold = TimeInterval(minutes * 60)
        let now = Date()
        if threshold <= 0 { tracker.reset() }
        let update = tracker.update(books: books, now: now, threshold: threshold)
        apply(update, minutes: minutes)

        guard let next = StallTracker.nextCheck(books: books, now: now, threshold: threshold) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.check(self.books)
            }
        }
        timer = work
        // A little past the threshold so the session is stalled when the check runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next.timeIntervalSince(now)) + 0.25,
                                      execute: work)
    }

    private func apply(_ update: StallUpdate, minutes: Int) {
        let state = AppState.shared
        // Badges: a stalled pill gets one unless it already shows something more urgent
        // (approval, error) or is the focused pill (like the other alert badges); a pill
        // with no stalled session left loses its stall badge.
        let newlyStalledPills = Set(update.newlyStalled.map(\.pillId))
        var tasks = state.tasks
        var changed = false
        for i in tasks.indices {
            let id = tasks[i].id
            if newlyStalledPills.contains(id), id != state.focusId {
                if tasks[i].pillBadge == nil || tasks[i].pillBadge == .finished {
                    tasks[i].pillBadge = .stalled
                    changed = true
                }
            } else if tasks[i].pillBadge == .stalled && !update.stalledPills.contains(id) {
                tasks[i].pillBadge = nil
                changed = true
            }
        }
        if changed { state.tasks = tasks }

        for stalled in update.newlyStalled {
            let session = stalled.session
            let task = state.tasks.first { $0.id == stalled.pillId }
            SessionAlertCenter.shared.post(SessionAlert(
                kind: .stalled,
                pillId: stalled.pillId,
                sessionId: session.id,
                agentName: AgentKind(rawValue: session.agent)?.displayName ?? session.agent,
                projectName: session.projectName,
                hostBundleId: task?.sessionBundleId,
                detail: NotificationPolicy.stallDetail(minutes: minutes)))
        }
    }
}
