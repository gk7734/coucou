import Foundation

/// The FSM kept in step with what the window shows, the countdown it exposes to the bar,
/// and absence (SPEC §3 rule 6). Timing margins are wide on purpose (slow CI, #376).
@main
enum IslandStateSyncTests {
    @MainActor
    static func main() async throws {
        try await displayedMode()
        try await alertDuringGreeting()
        try await countdown()
        countdownMath()
        try await absence()
        try await alertAutoClose()
        try await leaveClose()
        print("Island state sync: 7 groups passed")
    }

    // MARK: - displayed(_:pointerInside:)

    @MainActor
    static func displayedMode() async throws {
        // A view opened behind the FSM's back (hotkey chat, menu, recap) while compact:
        // the stale 60 s compact timer must not hide it, a hover must not fold it.
        let opened = IslandStateMachine()
        opened.petitToHiddenDelay = 0.2
        var transitions: [(IslandStateMachine.State, IslandStateMachine.State)] = []
        opened.onTransition = { transitions.append(($0, $1)) }
        opened.reveal()
        precondition(opened.state == .petit && transitions.count == 1)
        opened.displayed(.expanded, pointerInside: false)
        precondition(opened.state == .home)
        precondition(transitions.count == 1, "syncing must not fire onTransition")
        try await Task.sleep(for: .milliseconds(700))
        precondition(opened.state == .home, "stale compact timer hid an open island")
        opened.mouseEntered()
        precondition(opened.state == .home, "hovering folded an island opened externally")

        // Shown compact by AppState.syncMode while the FSM thought hidden: it now
        // folds away after the compact delay like any revealed island…
        let shown = IslandStateMachine()
        shown.petitToHiddenDelay = 0.2
        var hiddenByTimer = false
        shown.onTransition = { _, to in if to == .hidden { hiddenByTimer = true } }
        shown.displayed(.compact, pointerInside: false)
        precondition(shown.state == .petit && !hiddenByTimer)
        try await waitFor(.hidden, shown)
        precondition(hiddenByTimer)

        // …but not while the pointer rests on it.
        let under = IslandStateMachine()
        under.petitToHiddenDelay = 0.2
        under.displayed(.compact, pointerInside: true)
        try await Task.sleep(for: .milliseconds(700))
        precondition(under.state == .petit)

        // Hidden by the app (last task gone): the next hover peeks again.
        let gone = IslandStateMachine()
        gone.reveal()
        gone.displayed(.hidden, pointerInside: false)
        precondition(gone.state == .hidden)
        var peeked = false
        gone.onTransition = { from, to in peeked = from == .hidden && to == .petit }
        gone.mouseEntered()
        precondition(gone.state == .petit && peeked)

        // The FSM's own transitions re-enter through the mode observer: no-op.
        let own = IslandStateMachine()
        own.onTransition = { [unowned own] _, to in
            switch to {
            case .hidden: own.displayed(.hidden, pointerInside: false)
            case .petit: own.displayed(.compact, pointerInside: false)
            case .home, .coucou: own.displayed(.expanded, pointerInside: false)
            }
        }
        own.mouseEntered()
        own.click()
        precondition(own.state == .home)
        own.launch()
        precondition(own.state == .coucou, "expanded sync must not turn the greeting into home")

        // A demo snapshot restoring compact over an open island.
        let demo = IslandStateMachine()
        demo.mouseEntered(); demo.click()
        demo.displayed(.compact, pointerInside: false)
        precondition(demo.state == .petit && demo.countdown == nil)
    }

    // MARK: - openedExternally during the greeting

    @MainActor
    static func alertDuringGreeting() async throws {
        let m = IslandStateMachine()
        m.greetHoverCollapseDelay = 0.2
        m.homeToPetitDelay = 3
        m.launch()
        m.openedExternally()        // an approval replaces the greeting
        precondition(m.state == .home)
        m.mouseEntered()             // used to start the greeting's 10 s fold
        m.mouseLeft()                // used to fold it at once
        try await Task.sleep(for: .milliseconds(600))
        precondition(m.state == .home, "the alert was folded like a greeting")
        precondition(m.countdown != nil, "leaving starts the normal auto-close")
    }

    // MARK: - Alerts opened while the pointer is elsewhere

    @MainActor
    static func alertAutoClose() async throws {
        // A finished/error alert that opens while the pointer is elsewhere folds by itself.
        let away = IslandStateMachine()
        away.homeToPetitDelay = 0.2
        away.openedByAlert(pointerInside: false)
        precondition(away.state == .home && away.countdown != nil, "an alert opened away must auto-close")
        try await Task.sleep(for: .milliseconds(700))
        precondition(away.state == .petit, "the alert stayed open")

        // An approval holds the island open: no countdown.
        let held = IslandStateMachine()
        held.isHeldOpen = { true }
        held.openedByAlert(pointerInside: false)
        precondition(held.state == .home && held.countdown == nil)

        // Pointer on the island: the timer starts when it leaves, as before.
        let hovered = IslandStateMachine()
        hovered.openedByAlert(pointerInside: true)
        precondition(hovered.state == .home && hovered.countdown == nil)
    }

    // MARK: - Leaving an island the user opened

    @MainActor
    static func leaveClose() async throws {
        // Looking at the overview: the island folds about a second after the pointer leaves.
        let quick = IslandStateMachine()
        quick.leaveCloseDelay = 0.2
        quick.homeToPetitDelay = 30
        quick.keepsOpenOnLeave = { false }
        quick.click()
        precondition(quick.state == .home)
        quick.mouseEntered()
        quick.mouseLeft()
        precondition(quick.countdown == nil, "a short leave grace shows no countdown bar")
        try await Task.sleep(for: .milliseconds(700))
        precondition(quick.state == .petit, "the island stayed open after the pointer left")

        // Busy in the chat or a question: the normal auto-close, with its bar.
        let busy = IslandStateMachine()
        busy.leaveCloseDelay = 0.2
        busy.homeToPetitDelay = 30
        busy.keepsOpenOnLeave = { true }
        busy.click()
        busy.mouseEntered()
        busy.mouseLeft()
        try await Task.sleep(for: .milliseconds(500))
        precondition(busy.state == .home && busy.countdown != nil, "a busy view folded too soon")

        // An approval holds it open whatever the view.
        let held = IslandStateMachine()
        held.leaveCloseDelay = 0.2
        held.isHeldOpen = { true }
        held.keepsOpenOnLeave = { false }
        held.click()
        held.mouseEntered()
        held.mouseLeft()
        try await Task.sleep(for: .milliseconds(500))
        precondition(held.state == .home, "an approval card folded")
    }

    // MARK: - Countdown

    @MainActor
    static func countdown() async throws {
        let m = IslandStateMachine()
        m.homeToPetitDelay = 2
        var changes = 0
        m.onCountdownChange = { changes += 1 }
        m.mouseEntered(); m.click()
        precondition(m.countdown == nil, "no countdown while the pointer is on the island")
        let before = Date()
        m.mouseLeft()
        guard let c = m.countdown else { preconditionFailure("leaving must start a countdown") }
        precondition(c.duration == 2)
        let lead = c.deadline.timeIntervalSince(before)
        precondition(lead > 1.9 && lead < 2.5, "deadline \(lead) s away")
        precondition(changes == 1)

        m.mouseEntered()
        precondition(m.countdown == nil && changes == 2)

        // Editing the delay moves the deadline with the real timer.
        m.mouseLeft()
        m.homeToPetitDelay = 0.3
        precondition(m.countdown?.duration == 0.3)
        try await waitFor(.petit, m)
        precondition(m.countdown == nil, "a fired timer leaves no countdown behind")

        // The hover-open grace is not a countdown.
        let hover = IslandStateMachine()
        hover.openOnHover = true
        hover.hoverCloseDelay = 0.3
        hover.mouseEntered()
        hover.mouseLeft()
        precondition(hover.state == .home && hover.countdown == nil)

        // Folding by hand clears it.
        let folded = IslandStateMachine()
        folded.mouseEntered(); folded.click(); folded.mouseLeft()
        precondition(folded.countdown != nil)
        folded.collapse()
        precondition(folded.countdown == nil)

        // An alert opening the island cancels the countdown.
        let alert = IslandStateMachine()
        alert.mouseEntered(); alert.click(); alert.mouseLeft()
        alert.openedExternally()
        precondition(alert.countdown == nil)
    }

    static func countdownMath() {
        typealias FSM = IslandStateMachine
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)
        let c15 = FSM.Countdown(deadline: deadline, duration: 15)   // window 9 s
        precondition(FSM.countdownFraction(c15, at: deadline.addingTimeInterval(-10)) == nil)
        let half = FSM.countdownFraction(c15, at: deadline.addingTimeInterval(-4.5))!
        precondition(abs(half - 0.5) < 1e-9)
        precondition(FSM.countdownFraction(c15, at: deadline) == nil)
        precondition(FSM.countdownFraction(c15, at: deadline.addingTimeInterval(1)) == nil)
        let c60 = FSM.Countdown(deadline: deadline, duration: 60)   // window capped at 10 s
        precondition(abs(FSM.countdownFraction(c60, at: deadline.addingTimeInterval(-5))! - 0.5) < 1e-9)
        precondition(FSM.countdownFraction(c60, at: deadline.addingTimeInterval(-11)) == nil)

        let all = FSM.countdownTicks(c15, from: deadline.addingTimeInterval(-60))
        precondition(all.count == 91, "\(all.count) ticks")
        precondition(all.last == deadline)
        precondition(abs(all.first!.timeIntervalSince(deadline) + 9) < 1e-9)
        precondition(zip(all, all.dropFirst()).allSatisfy { $0 < $1 })
        let late = FSM.countdownTicks(c15, from: deadline.addingTimeInterval(-1))
        precondition(late.count == 11 && late.last == deadline)
        // Stable when rebuilt a moment later: same instants, minus the past ones.
        let later = FSM.countdownTicks(c15, from: deadline.addingTimeInterval(-0.95))
        precondition(Set(later).isSubset(of: Set(late)))
        precondition(FSM.countdownTicks(c15, from: deadline.addingTimeInterval(1)).isEmpty)
        precondition(FSM.countdownTicks(FSM.Countdown(deadline: deadline, duration: 0), from: deadline).isEmpty)
    }

    // MARK: - Absence

    @MainActor
    static func absence() async throws {
        // Compact island, nobody moves: hidden, quietly; first movement brings it back.
        let away = IslandStateMachine()
        away.petitToHiddenDelay = 60
        var presence: [Bool] = []
        var quiet: [Bool] = []
        away.onPresenceChange = { presence.append($0) }
        away.onTransition = { [unowned away] _, _ in quiet.append(away.isQuietTransition) }
        away.reveal()
        away.absenceInterval = 0.3
        try await waitFor(.hidden, away)
        precondition(away.isAbsent && presence == [false])
        precondition(quiet == [false, true], "absence transitions must be quiet: \(quiet)")
        away.pointerMoved()
        precondition(away.state == .petit && !away.isAbsent && presence == [false, true])
        precondition(quiet == [false, true, true])

        // Work arriving while away stays hidden until the user is back.
        let work = IslandStateMachine()
        work.absenceInterval = 0.2
        try await Task.sleep(for: .milliseconds(600))
        precondition(work.isAbsent && work.state == .hidden)
        work.reveal()
        precondition(work.state == .hidden, "absent: reveal must not show the island")
        work.pointerMoved()
        precondition(work.state == .petit)

        // Hidden before leaving and nothing new: stays hidden on return.
        let idle = IslandStateMachine()
        idle.absenceInterval = 0.2
        try await Task.sleep(for: .milliseconds(600))
        precondition(idle.isAbsent)
        idle.pointerMoved()
        precondition(!idle.isAbsent && idle.state == .hidden)
        // …and the clock runs again.
        try await Task.sleep(for: .milliseconds(600))
        precondition(idle.isAbsent)

        // Alerts still open the island while away; an open island is left alone.
        let alert = IslandStateMachine()
        alert.absenceInterval = 0.2
        try await Task.sleep(for: .milliseconds(600))
        alert.openedExternally()
        precondition(alert.state == .home)
        let open = IslandStateMachine()
        open.mouseEntered(); open.click()
        open.absenceInterval = 0.2
        try await Task.sleep(for: .milliseconds(600))
        precondition(open.isAbsent && open.state == .home)

        // A pending approval holds the compact island too.
        let held = IslandStateMachine()
        held.petitToHiddenDelay = 60
        held.isHeldOpen = { true }
        held.reveal()
        held.absenceInterval = 0.2
        try await Task.sleep(for: .milliseconds(600))
        precondition(held.isAbsent && held.state == .petit)

        // Movement keeps the user present.
        let busy = IslandStateMachine()
        busy.petitToHiddenDelay = 60
        busy.reveal()
        busy.absenceInterval = 1   // > 10× the gap between moves, for a stalling CI runner
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(100))
            busy.pointerMoved()
        }
        precondition(!busy.isAbsent && busy.state == .petit)

        // 0 turns it off, and brings an absent user back.
        let off = IslandStateMachine()
        off.absenceInterval = 0.2
        try await Task.sleep(for: .milliseconds(600))
        precondition(off.isAbsent)
        off.absenceInterval = 0
        precondition(!off.isAbsent)
        try await Task.sleep(for: .milliseconds(400))
        precondition(!off.isAbsent)
    }

    @MainActor
    private static func waitFor(_ s: IslandStateMachine.State, _ m: IslandStateMachine,
                                timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while m.state != s && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(m.state == s, "state \(m.state) after \(timeout) s, expected \(s)")
    }
}
