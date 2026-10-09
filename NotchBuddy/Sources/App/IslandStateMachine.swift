import Foundation

/// Pure 4-state FSM for island open/close logic.
/// No AppKit / AppState dependencies — communicates via `onTransition`.
@MainActor
final class IslandStateMachine {

    enum State: Equatable {
        case hidden   // island invisible (notch size)
        case petit    // compact island (notch + ears)
        case home     // expanded, overview
        case coucou   // expanded, greeting animation
    }

    private(set) var state: State = .hidden

    /// Fired on every transition: (from, to)
    var onTransition: ((State, State) -> Void)?

    /// When non-nil and returns true, timers and mouse-leave never auto-collapse or hide the island.
    var isHeldOpen: (() -> Bool)?

    /// home → petit delay (seconds), kept in sync with the auto-close preference.
    var homeToPetitDelay: TimeInterval = 15 {
        didSet {
            guard homeToPetitDelay != oldValue,
                  state == .home, homeCollapseWork != nil else { return }
            scheduleHomeCollapse()
        }
    }
    /// petit → hidden delay (seconds). Override for debug.
    var petitToHiddenDelay: TimeInterval = 60
    /// coucou → petit delay after greeting animation ends (no hover). ~0.6s syncs with canvas collapse.
    var greetAutoCollapseDelay: TimeInterval = 0.6
    /// coucou → petit delay when mouse is hovering over the greeting.
    var greetHoverCollapseDelay: TimeInterval = 10

    /// Opt-in (Settings → General → Behavior): hovering the island opens it, and an island
    /// opened that way folds shortly after the pointer leaves. Off: hover only peeks (petit).
    var openOnHover = false
    /// Grace period after the pointer leaves a hover-opened island (no flicker at the edge).
    var hoverCloseDelay: TimeInterval = 0.6
    /// The pointer left an island the user opened (click, hotkey…): it folds after this,
    /// unless `keepsOpenOnLeave` says the user is in the middle of something there (chat,
    /// a question, a mail…), which keeps the normal auto-close (`homeToPetitDelay`).
    /// Unset (nil): always the normal auto-close, as before.
    var leaveCloseDelay: TimeInterval = 1.0
    var keepsOpenOnLeave: (() -> Bool)?
    /// True while the island is open because of a hover, until the user clicks inside it.
    private(set) var openedByHover = false

    private var petitHideWork: DispatchWorkItem?
    private var homeCollapseWork: DispatchWorkItem?
    private var greetCollapseWork: DispatchWorkItem?

    // MARK: – Inputs

    /// App launched or debug "launch greeting"
    func launch() {
        cancelTimers()
        transition(to: .coucou)
        pointerMoved()   // starts the absence clock
    }

    /// Mouse entered the island notch area
    func mouseEntered() {
        if openOnHover, state == .hidden || state == .petit, isHeldOpen?() != true {
            cancelTimers()
            openedByHover = true
            transition(to: .home)
            return
        }
        switch state {
        case .hidden:
            if isHeldOpen?() == true {
                // Island already expanded by an external call — sync FSM state without transition
                state = .home
            } else {
                cancelTimers()
                transition(to: .petit)
            }
        case .petit:
            petitHideWork?.cancel()
            petitHideWork = nil
        case .home:
            homeCollapseWork?.cancel()
            homeCollapseWork = nil
            setCountdown(nil)
        case .coucou:
            // Mouse hovering during greeting — cancel short auto-collapse, extend to hover delay
            scheduleGreetCollapse(delay: greetHoverCollapseDelay)
        }
    }

    /// Mouse left the island notch area
    func mouseLeft() {
        switch state {
        case .hidden:
            break
        case .petit:
            schedulePetitHide()
        case .home:
            if isHeldOpen?() != true { scheduleHomeCollapse(afterLeave: true) }
        case .coucou:
            if isHeldOpen?() != true {
                // Interrupt greeting immediately → compact (overrides 10s auto-collapse)
                greetCollapseWork?.cancel(); greetCollapseWork = nil
                transition(to: .petit)
            }
        }
    }

    /// Compact island clicked.
    /// Also accepts `.hidden`: after an alert the island can be on screen while the
    /// FSM never saw the mouse enter (it was already there), and the click must still open it.
    func click() {
        openedByHover = false
        guard state == .petit || state == .hidden else { return }
        cancelTimers()
        transition(to: .home)
    }

    /// What the window shows (`AppState.mode`), in the FSM's terms.
    enum Shown: Equatable { case hidden, compact, expanded }

    /// The app changed the island's mode on its own: `AppState.syncMode()` when tasks come
    /// and go, a view opened from a hotkey or the menu, the demo restoring its snapshot…
    /// Mirror it without firing `onTransition`, so the next hover, click or timer starts from
    /// what is really on screen. Without this, a hotkey-opened chat was hidden by a stale
    /// 60 s compact timer, and hovering an island opened behind the FSM's back folded it.
    func displayed(_ shown: Shown, pointerInside: Bool) {
        switch shown {
        case .hidden:
            guard state != .hidden else { return }
            cancelTimers()
            openedByHover = false
            state = .hidden
        case .compact:
            guard state != .petit else { return }
            cancelTimers()
            openedByHover = false
            state = .petit
            if !pointerInside { schedulePetitHide() }
        case .expanded:
            guard state == .hidden || state == .petit else { return }
            cancelTimers()
            openedByHover = false
            state = .home
        }
    }

    /// The app expanded the island externally (hookExpand for an alert).
    /// Cancel timers and sync state to `.home` without firing `onTransition`, so the
    /// next hover/mouseLeft behave correctly instead of collapsing the island.
    /// From `.coucou` too: the alert replaces the greeting, whose end then never comes,
    /// and a FSM left in `.coucou` folded the alert on the next hover or pointer exit.
    func openedExternally() {
        cancelTimers()
        openedByHover = false
        state = .home
    }

    /// An alert (finished, error, approval, question…) opened the island.
    /// Like `openedExternally`, plus the normal auto-close when nothing holds it open and the
    /// pointer isn't on it: the close timer is otherwise only armed when the pointer leaves,
    /// so an alert that opened while the pointer was elsewhere stayed open (and drawing at
    /// full frame rate) for good.
    func openedByAlert(pointerInside: Bool) {
        openedExternally()
        if !pointerInside, isHeldOpen?() != true { scheduleHomeCollapse() }
    }

    /// The last approval or question card left the open island (answered in the notch, from
    /// the iPhone…): it no longer holds the island open, so the normal auto-close starts
    /// unless the pointer is on it (then leaving starts it, as usual). No timer ran while
    /// the card waited, and an island answered with the pointer elsewhere stayed open (and
    /// drawing at full frame rate) for good.
    func heldCardClosed(pointerInside: Bool) {
        guard state == .home, !pointerInside, isHeldOpen?() != true, homeCollapseWork == nil else { return }
        scheduleHomeCollapse()
    }

    /// The app folded the island itself (Escape, Settings, OK button, auto-close).
    /// Move to `.petit` right away so hover and click keep working; waiting for the
    /// 15 s home timer left the island compact on screen while the FSM still said `.home`.
    func collapse() {
        openedByHover = false
        guard state == .home || state == .coucou else { return }
        cancelTimers()
        transition(to: .petit)
    }

    /// Greeting animation finished (called at T.end ≈ 4.60 s).
    /// Schedules auto-collapse. Does not override a longer hover timer already running.
    func greetComplete() {
        guard state == .coucou else { return }
        // If mouse entered before this fires (hover timer already running), don't override it
        if greetCollapseWork == nil {
            scheduleGreetCollapse(delay: greetAutoCollapseDelay)
        }
    }

    private func scheduleGreetCollapse(delay: TimeInterval) {
        greetCollapseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .coucou else { return }
            self.transition(to: .petit)
        }
        greetCollapseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Non-alert work event: show compact from hidden (HookServer reveal)
    func reveal() {
        guard state == .hidden else { return }
        // Absent (SPEC §3 rule 6): stay hidden, show the work when the user comes back.
        if isAbsent { revealOnReturn = true; return }
        cancelTimers()
        transition(to: .petit)
        schedulePetitHide()
    }

    // MARK: – Timers

    private func schedulePetitHide() {
        petitHideWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .petit, !(self.isHeldOpen?() ?? false) else { return }
            self.transition(to: .hidden)
        }
        petitHideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + petitToHiddenDelay, execute: item)
    }

    private func scheduleHomeCollapse(afterLeave: Bool = false) {
        homeCollapseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.homeCollapseWork = nil
            self.setCountdown(nil)
            guard self.state == .home, !(self.isHeldOpen?() ?? false) else { return }
            self.openedByHover = false
            self.transition(to: .petit)
        }
        homeCollapseWork = item
        let quickLeave = afterLeave && !openedByHover && keepsOpenOnLeave?() == false
        let delay = openedByHover ? hoverCloseDelay : quickLeave ? leaveCloseDelay : homeToPetitDelay
        // A short grace (hover-open, or leaving a view you were only looking at) is not an
        // auto-close countdown: no bar.
        setCountdown(openedByHover || quickLeave
                     ? nil : Countdown(deadline: Date().addingTimeInterval(delay), duration: delay))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The user clicked inside the island: a hover-opened island now stays like any open
    /// island (normal auto-close) instead of folding as soon as the pointer leaves.
    func userInteracted() {
        openedByHover = false
    }

    func cancelTimers() {
        petitHideWork?.cancel();    petitHideWork = nil
        homeCollapseWork?.cancel(); homeCollapseWork = nil
        greetCollapseWork?.cancel(); greetCollapseWork = nil
        setCountdown(nil)
    }

    // MARK: – Auto-close countdown (the bar at the bottom of an open island)

    struct Countdown: Equatable {
        /// When the pending home → petit timer fires.
        let deadline: Date
        /// Its full delay, which sizes the bar's window.
        let duration: TimeInterval
    }

    /// The home → petit timer that will really fold the island, or nil when none runs
    /// (pointer on the island, opened by an alert, hover grace…).
    private(set) var countdown: Countdown?
    /// Fired whenever `countdown` changes.
    var onCountdownChange: (() -> Void)?

    private func setCountdown(_ new: Countdown?) {
        guard new != countdown else { return }
        countdown = new
        onCountdownChange?()
    }

    /// Fill of the countdown bar (1 → 0) at `now`, or nil while it is not shown: it shows
    /// during the last `min(10 s, 60 %)` of the delay.
    nonisolated static func countdownFraction(_ countdown: Countdown, at now: Date) -> Double? {
        let window = min(10, countdown.duration * 0.6)
        let remaining = countdown.deadline.timeIntervalSince(now)
        guard window > 0, remaining > 0, remaining < window else { return nil }
        return remaining / window
    }

    /// Instants at which the bar redraws: every 0.1 s across its window, aligned on the
    /// deadline so the list stays the same when the view is rebuilt. Nothing before the
    /// window opens (no wake-ups) and nothing after the deadline.
    nonisolated static func countdownTicks(_ countdown: Countdown, from now: Date) -> [Date] {
        let window = min(10, countdown.duration * 0.6)
        guard window > 0 else { return [] }
        let steps = Int((window / 0.1).rounded(.down))
        return (0...steps).reversed()
            .map { countdown.deadline.addingTimeInterval(-Double($0) * 0.1) }
            .filter { $0 > now.addingTimeInterval(-0.1) }
    }

    // MARK: – Absence (SPEC §3 rule 6)

    /// No pointer movement for this long hides a compact island, even with tasks running;
    /// the first movement brings it back. Alerts still open it. ≤ 0 turns it off.
    var absenceInterval: TimeInterval = 180 {
        didSet {
            guard absenceInterval != oldValue else { return }
            if absenceInterval <= 0, isAbsent { returnFromAbsence() } else { scheduleAbsenceCheck() }
        }
    }
    private(set) var isAbsent = false
    /// Fired with `false` when the user leaves, `true` when they come back.
    var onPresenceChange: ((Bool) -> Void)?
    /// True during the transitions made by absence, which the app keeps silent.
    private(set) var isQuietTransition = false

    private var lastPointerMove = DispatchTime.now()
    private var absenceWork: DispatchWorkItem?
    /// The island was on screen, or work arrived, while the user was away.
    private var revealOnReturn = false

    /// The pointer moved. Cheap: called on every polled movement.
    func pointerMoved() {
        lastPointerMove = .now()
        if isAbsent { returnFromAbsence() }
        else if absenceWork == nil { scheduleAbsenceCheck() }
    }

    private var secondsSinceMove: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- lastPointerMove.uptimeNanoseconds) / 1_000_000_000
    }

    /// One timer per interval at most: when the pointer moved meanwhile, it re-arms for
    /// the time left instead of being rescheduled on every movement.
    private func scheduleAbsenceCheck() {
        absenceWork?.cancel(); absenceWork = nil
        guard absenceInterval > 0, !isAbsent else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.absenceWork = nil
            if self.secondsSinceMove >= self.absenceInterval - 0.001 {
                self.becomeAbsent()
            } else {
                self.scheduleAbsenceCheck()
            }
        }
        absenceWork = item
        let delay = max(0, absenceInterval - secondsSinceMove)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func becomeAbsent() {
        isAbsent = true
        onPresenceChange?(false)
        // Only the compact island hides: an open one is an alert or a chat, or folds by itself.
        guard state == .petit, isHeldOpen?() != true else { return }
        cancelTimers()
        revealOnReturn = true
        quietly { transition(to: .hidden) }
    }

    private func returnFromAbsence() {
        isAbsent = false
        onPresenceChange?(true)
        if revealOnReturn, state == .hidden {
            cancelTimers()
            quietly { transition(to: .petit) }
            schedulePetitHide()
        }
        revealOnReturn = false
        scheduleAbsenceCheck()
    }

    private func quietly(_ body: () -> Void) {
        isQuietTransition = true
        body()
        isQuietTransition = false
    }

    private func transition(to new: State) {
        guard new != state else { return }
        let old = state
        state = new
        onTransition?(old, new)
    }

}
