import AppKit
import SwiftUI

@MainActor
final class IslandWindowController: NSWindowController {

    private var islandPanel: IslandPanel!
    private var state: AppState { AppState.shared }

    // State machine (replaces all hover/absence/auto-close timers)
    let fsm = IslandStateMachine()

    private var wasInIsland = false
    private var frameTimer: Timer?
    private var keyMonitor: Any?
    private var displayObserver: ChangeObserver<IslandDisplayChoice>?
    private var autoCloseObserver: ChangeObserver<TimeInterval>?
    private var openOnHoverObserver: ChangeObserver<Bool>?
    private var absenceObserver: ChangeObserver<TimeInterval>?
    private var heldObserver: ChangeObserver<Bool>?

    // Confused recovery timer (set by handleDizzy)
    private var confusedRecoveryTimer: DispatchWorkItem?

    // Suppress peek sound on next reveal (e.g. musicReveal)
    var silentNextReveal = false

    // Bot-head hover (love emote — mirrors prototype botHover())
    private var botHoverTimer: DispatchWorkItem?
    private var botHovering: Bool = false
    private var lastLoveTime: Double = 0
    private var botHoverStartPos: CGPoint = .zero

    // Window attach drag (M8)
    private var attachDragStart: NSPoint? = nil
    private var pendingIslandClick = false   // any island click → expand on mouseUp
    /// What a click in the compact island landed on (status line, mini Mochi), from mouseDown.
    private var compactClickTarget: CompactClickTarget?
    private var inAttachDrag = false
    private var dragGhostPanel: NSPanel? = nil
    private var dragGhostSize: CGFloat = 0
    private var ghostCurrentOrigin: NSPoint = .zero
    private var highlightPanel: NSPanel? = nil
    private var highlightWindowPid: pid_t = 0

    // Notch real dimensions (set on init)
    private var notchW: CGFloat = IslandConst.notchWidth
    private var notchH: CGFloat = IslandConst.notchHeight
    private var hasNotch = true

    // Island-local key monitor (active only when island is key window)
    private var localKeyMonitor: Any?

    #if DEBUG
    /// The island, for HookServer's debug_state query (scripts/smoke.sh).
    static weak var current: IslandWindowController?
    #endif

    /// Where a smoke-test run (AppPaths.isSmokeTest) sees the pointer: far from every screen,
    /// so the user's real pointer never hovers, opens or holds the test's island.
    private static let smokePointer = NSPoint(x: -100_000, y: -100_000)

    convenience init() {
        let screen = Self.targetScreen(for: AppState.shared.islandDisplay)
        Self.currentScreen = screen
        let geometry = Self.screenGeometry(for: screen)
        let nW = geometry.width
        let nH = geometry.height

        let panelW = IslandConst.panelWidth
        let panelH = IslandConst.panelHeight
        let sf = screen.frame
        let panel = IslandPanel(
            contentRect: NSRect(x: sf.midX - panelW/2, y: sf.maxY - panelH,
                                width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.notchWidth  = nW
        panel.notchHeight = nH

        self.init(window: panel)
        self.islandPanel = panel
        self.notchW = nW
        self.notchH = nH
        self.hasNotch = geometry.hasNotch
        setupPanel(screen: screen)
        #if DEBUG
        Self.current = self
        #endif
    }

    private func setupPanel(screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        // Smoke-test run: the panel exists and its views run, but nobody can see or click it.
        if AppPaths.isSmokeTest { panel.alphaValue = 0 }

        // Propagate real notch dimensions to AppState
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch

        let contentSize = panel.contentRect(forFrameRect: panel.frame).size

        // Apple-recommended pattern: put NSHostingView and drag destination as siblings
        // inside a common superview, rather than embedding one inside the other.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: IslandRootView()
            .environment(AppState.shared)
            .environment(\.layoutDirection, .leftToRight))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        // FileDropNSView sits below the hosting view (hitTest returns nil → no mouse interference).
        // AppKit routes NSDraggingDestination events to registered views independently of hitTest.
        let dropView = FileDropNSView(frame: NSRect(origin: .zero, size: contentSize))
        dropView.autoresizingMask = [.width, .height]
        dropView.onDragEntered = { [weak self] loc in
            Task { @MainActor in
                let iLoc = self?.windowToIsland(loc) ?? CGPoint(x: 320, y: 88)
                AppState.shared.fileDragOver = true
                // enterZone sets isActive=true BEFORE hookExpand triggers re-render,
                // so IslandContainer sees isActive=true when state.view becomes .upload.
                UploadSequenceEngine.shared.enterZone(x: iLoc.x, y: iLoc.y)
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.upload)
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(1))
            }
        }
        dropView.onDragUpdated = { [weak self] loc in
            Task { @MainActor in
                let iLoc = self?.windowToIsland(loc) ?? CGPoint(x: 320, y: 88)
                UploadSequenceEngine.shared.updateCursor(x: iLoc.x, y: iLoc.y)
            }
        }
        dropView.onDragExited = {
            Task { @MainActor in
                AppState.shared.fileDragOver = false
                // Do NOT collapse — drag session still active; island stays open.
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(0))
                UploadSequenceEngine.shared.exitZone()
            }
        }
        dropView.onFilesDropped = { urls in
            Task { @MainActor in
                await FileDropHandler.handle(urls: urls, state: AppState.shared)
            }
        }

        container.addSubview(hosting)    // z-bottom: SwiftUI + mouse events
        container.addSubview(dropView)   // z-top: drag only (hitTest→nil, transparent to mouse)
        panel.contentView = container

        CompactStatusModel.shared.start()
        startPolling()
        startKeyMonitor()
        startLocalKeyMonitor()
        startHotKeys()
        wireFSM()

        // Make panel key whenever the prompt/chat view becomes active
        // (nonactivatingPanel never auto-becomes key, but TextField needs it)
        // On every assignment, the same view included, on the next turn of the main queue.
        state.viewDidSet = { [weak self] newView in
            guard newView == .prompt else { return }
            DispatchQueue.main.async { [weak self] in
                self?.islandPanel.makeKey()
            }
        }

        // Screen choice changed in Settings: move right away (explicit user action).
        displayObserver = ChangeObserver({ AppState.shared.islandDisplay }) { [weak self] choice in
            self?.moveToTargetScreen(choice: choice)
        }

        // Screen plugged/unplugged, lid closed, arrangement or resolution changed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.moveToTargetScreen(choice: AppState.shared.islandDisplay) }
        }

        // Settings or an agent installer may have changed what is set up.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { IntegrationSetupCache.invalidate() }
        }
    }

    // MARK: - Screen choice

    private func moveToTargetScreen(choice: IslandDisplayChoice) {
        guard !inAttachDrag, attachDragStart == nil else { return }
        relocate(to: Self.targetScreen(for: choice))
    }

    /// Recomputes the resting geometry for `screen` and moves the panel to its top centre.
    /// Always re-applied, even on the same screen: its menu bar or resolution may have changed.
    private func relocate(to screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        let geometry = Self.screenGeometry(for: screen)
        notchW = geometry.width
        notchH = geometry.height
        hasNotch = geometry.hasNotch
        panel.notchWidth  = notchW
        panel.notchHeight = notchH
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch
        Self.currentScreen = screen

        let sf = screen.frame
        let size = panel.frame.size
        panel.setFrame(NSRect(x: sf.midX - size.width/2, y: sf.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        // The island's size is @State in IslandContainer: tell it to resize. Views that read
        // notchWidth/notchHeight/hasNotch follow on their own (observed properties).
        NotificationCenter.default.post(name: .islandScreenChanged, object: nil)
    }

    /// Follow-the-mouse mode: hop to the cursor's screen while the island is not open,
    /// so an approval or a chat never jumps away mid-click.
    private func followMouseIfNeeded(_ mouse: NSPoint) {
        guard state.islandDisplay == .followMouse,
              state.mode != .expanded, !inAttachDrag, attachDragStart == nil else { return }
        if let current = Self.currentScreen, current.frame.contains(mouse) { return }
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              target != Self.currentScreen else { return }
        relocate(to: target)
    }

    // MARK: - FSM wiring

    private func wireFSM() {
        // Apply the persisted preference immediately and keep live edits in sync.
        autoCloseObserver = ChangeObserver({ AppState.shared.autoCloseInterval }, initial: true) { [weak self] delay in
            self?.fsm.homeToPetitDelay = delay
        }
        openOnHoverObserver = ChangeObserver({ AppState.shared.openOnHover }, initial: true) { [weak self] on in
            self?.fsm.openOnHover = on
        }
        absenceObserver = ChangeObserver({ AppState.shared.absenceInterval }, initial: true) { [weak self] interval in
            self?.fsm.absenceInterval = interval
        }
        #if DEBUG
        // scripts/smoke.sh shortens the compact → hidden delay (60 s) to see a hidden island soon.
        if AppPaths.isSmokeTest, let delay = AppDefaults.store.object(forKey: "smokePetitHideDelay") as? Double {
            fsm.petitToHiddenDelay = delay
        }
        #endif
        fsm.onPresenceChange = { present in
            AppState.shared.isPresent = present
        }
        fsm.onCountdownChange = { [weak self] in
            guard let self else { return }
            IslandAutoCloseCountdown.shared.countdown = self.fsm.countdown
        }

        // Many paths change the mode without going through the FSM (AppState.syncMode, views
        // opened from a hotkey, the menu or the desktop Mochi, the demo restoring its snapshot).
        // Mirror every change so the FSM's hover, click and timers match what is on screen.
        // The FSM's own transitions come back here too and are no-ops.
        // Synchronous, before the new mode is stored, like the @Published sink it replaces.
        let modeWillSet: @MainActor (IslandMode) -> Void = { [weak self] mode in
            guard let self else { return }
            let shown: IslandStateMachine.Shown
            switch mode {
            case .hidden:   shown = .hidden
            case .compact:  shown = .compact
            case .expanded: shown = .expanded
            }
            if mode == .expanded { IntegrationSetupCache.invalidate() }
            self.fsm.displayed(shown, pointerInside: self.wasInIsland)
        }
        state.modeWillSet = modeWillSet
        modeWillSet(state.mode)   // a Combine sink is handed the current value too

        fsm.onTransition = { [weak self] from, to in
            guard let self else { return }
            switch to {
            case .hidden:
                self.setMode(.hidden)

            case .petit:
                if from == .coucou {
                    // Fire interrupt first so canvas collapse starts before mode change
                    NotificationCenter.default.post(name: .greetingInterrupt, object: nil)
                } else if from == .hidden {
                    if self.silentNextReveal {
                        self.silentNextReveal = false
                    } else if !self.fsm.isQuietTransition {   // back from an absence: no sound
                        SoundEngine.shared.play("peek")
                    }
                }
                // setMode BEFORE changing view: onChange(of: state.view) guards on .expanded,
                // so setting view while already compact won't trigger a spurious open animation.
                self.setMode(.compact)
                if from == .coucou { self.state.view = self.defaultView() }
                // Start 60s hide timer if mouse is not currently over the island
                if !self.wasInIsland { self.fsm.mouseLeft() }

            case .home:
                self.show(self.defaultView())
                // Start collapse timer if mouse not currently hovering
                if !self.wasInIsland {
                    self.fsm.mouseLeft()
                }

            case .coucou:
                self.show(.greeting)
            }
        }

        // FSM observes greetComplete notification
        NotificationCenter.default.addObserver(
            forName: .greetComplete, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fsm.greetComplete() }
        }

        // An approval or a question holds the island open: it must not fold (the question's
        // card would hand it back to the terminal) until the user answers it or it goes.
        fsm.isHeldOpen = { AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil }
        // The hold ended without the pointer on the island (answered from the iPhone, in the
        // editor or terminal, or expired): arm the normal auto-close, which nothing else would
        // do, so the island doesn't stay open (drawing at full frame rate) for good.
        heldObserver = ChangeObserver({ AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil },
                                      removeDuplicates: true) { [weak self] held in
            guard let self, !held, self.fsm.state == .home, !self.wasInIsland else { return }
            self.fsm.openedByAlert(pointerInside: false)
        }
        // Views the user is busy in keep the normal auto-close when the pointer leaves;
        // the others (overview, finished, error…) fold right away.
        fsm.keepsOpenOnLeave = {
            let s = AppState.shared
            let busyViews: Set<IslandView> = [.prompt, .mail, .question, .upload, .uploading, .choose,
                                              .searching, .result, .note, .settings, .wardrobe, .recap]
            return busyViews.contains(s.view) || s.pendingQuestion != nil
        }
    }

    // MARK: - Polling loop
    // 60 Hz while the island is on screen, Mochi is on the desktop, a drag is under way or the
    // pointer is near the island; 8 Hz (with timer tolerance) while it is hidden and the pointer
    // is elsewhere, so a hidden island costs next to nothing (CLAUDE.md: 0 % CPU when hidden).
    // Not event-driven: a global mouse-moved monitor would wake the app on every pointer event
    // (more often than 8 Hz whenever the user moves), and file drags from other apps send no
    // mouse-moved events, yet must still reach the island.

    private static let fastPoll: TimeInterval = 1.0 / 60.0
    private static let idlePoll: TimeInterval = 1.0 / 8.0
    private var pollInterval: TimeInterval = 0

    private func startPolling(interval: TimeInterval = IslandWindowController.fastPoll) {
        frameTimer?.invalidate()
        pollInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop: already on the main actor, no Task per tick.
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        timer.tolerance = interval == Self.idlePoll ? 0.04 : 0
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// Picks the polling rate for the next ticks (see startPolling).
    private func adjustPollRate(mouse: NSPoint, islandFrame: NSRect) {
        // Near the island itself, not the 720×560 panel: that one is mostly transparent and
        // a pointer resting anywhere in the top-centre of the screen kept a hidden island at 60 Hz.
        let nearIsland = islandFrame.insetBy(dx: -120, dy: -120).contains(mouse)
        let busy = state.mode != .hidden || state.mochiOnDesktop || inAttachDrag || attachDragStart != nil
            || fsm.state != .hidden || nearIsland
        let wanted = busy ? Self.fastPoll : Self.idlePoll
        if wanted != pollInterval { startPolling(interval: wanted) }
    }

    private func pollFrame() {
        guard let panel = window as? IslandPanel else { return }

        let mouse = AppPaths.isSmokeTest ? Self.smokePointer : NSEvent.mouseLocation
        followMouseIfNeeded(mouse)

        // Convert mouse to panel-local coords (macOS: origin bottom-left)
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)

        // Island rect in panel coords
        let islandRect = panel.currentIslandFrame(nw: notchW, nh: notchH)
        // On a screen without a notch, the resting bar must not intercept clicks
        // in the app window immediately below the menu bar.
        let hoverRect = !hasNotch && state.mode != .expanded
            ? islandRect : islandRect.insetBy(dx: -6, dy: -6)
        let inIsland = hoverRect.contains(local)

        // Toggle click-through
        let shouldAcceptMouse = inIsland || inAttachDrag || attachDragStart != nil
        if panel.ignoresMouseEvents == shouldAcceptMouse {
            panel.ignoresMouseEvents = !shouldAcceptMouse
            if shouldAcceptMouse, let cv = panel.contentView {
                panel.invalidateCursorRects(for: cv)
            }
        }

        // Mouse in desktop space (y-down from the menu-bar screen top) for Bot look-at
        let newPos = DesktopSpace.topDown(mouse, desktopTop: Self.desktopTop)
        let cur = AppState.shared.mousePosition
        if abs(newPos.x - cur.x) > 1 || abs(newPos.y - cur.y) > 1 {
            AppState.shared.mousePosition = newPos
            fsm.pointerMoved()   // absence clock; first movement after an absence brings the island back
        }

        // Feed FSM hover enter/leave
        // Update the hit test before feeding the FSM: its transitions read wasInIsland
        // (a hover-opened island must not start its close timer while the pointer is on it).
        let previouslyInIsland = wasInIsland
        wasInIsland = inIsland
        if inIsland && !previouslyInIsland {
            guard !inAttachDrag else { return }
            // If in coucou: tell greeting to stay open (tc → infinity)
            if fsm.state == .coucou {
                NotificationCenter.default.post(name: .greetingHover, object: nil)
            }
            fsm.mouseEntered()
        }
        if !inIsland && previouslyInIsland {
            fsm.mouseLeft()
        }

        // Mini Mochi under the pointer in the compact island (its label shows under the island).
        var hoveredMini: String? = nil
        if inIsland, state.mode == .compact, case .mini(let id)? = compactTarget(at: local) { hoveredMini = id }
        if CompactStatusModel.shared.hoveredMiniId != hoveredMini {
            CompactStatusModel.shared.hoveredMiniId = hoveredMini
        }

        // Bot-head hover (love emote)
        let overBot = state.mode == .expanded && state.stateOverride == nil && isBotHit(local)
        if overBot && !botHovering { botHoverIn(mousePos: NSEvent.mouseLocation) }
        if !overBot && botHovering { botHoverOut() }
        botHovering = overBot
        if botHovering {
            let m = NSEvent.mouseLocation
            let dist = hypot(m.x - botHoverStartPos.x, m.y - botHoverStartPos.y)
            if dist > 40 {
                botHoverStartPos = m
                botHoverTimer?.cancel()
                scheduleLoveTimer()
            }
        }

        // Ghost Mochi follows cursor + window highlight during drag (60 Hz, no throttle)
        if inAttachDrag {
            updateDragGhost()
            updateWindowHighlight()
        }

        adjustPollRate(mouse: mouse, islandFrame: islandRect.offsetBy(dx: pf.minX, dy: pf.minY))
    }

    // MARK: - Bot-head hover (love emote — mirrors prototype botHover())

    private func botHoverIn(mousePos: CGPoint) {
        guard state.mode == .expanded, state.stateOverride == nil else { return }
        guard CACurrentMediaTime() - lastLoveTime > 6 else { return }
        botHoverStartPos = mousePos
        NotificationCenter.default.post(name: .botBlink, object: nil)
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1.08))
        SoundEngine.shared.play("hover")
        scheduleLoveTimer()
    }

    private func botHoverOut() {
        botHoverTimer?.cancel()
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1))
    }

    private func scheduleLoveTimer() {
        botHoverTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.botHovering, self.state.stateOverride == nil else { return }
            guard CACurrentMediaTime() - self.lastLoveTime > 6 else { return }
            self.lastLoveTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
            SoundEngine.shared.play("love")
        }
        botHoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: item)
    }

    // MARK: - Mode transitions

    private func modeLevel(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }

    func setMode(_ mode: IslandMode) {
        let prev = state.mode
        guard mode != prev else { return }
        let shrinking = modeLevel(mode) < modeLevel(prev)
        let anim: Animation = shrinking
            ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            : .spring(response: 0.5, dampingFraction: 0.72)
        withAnimation(anim) { state.mode = mode }
        if mode == .expanded { SoundEngine.shared.play("open") }
        if prev == .expanded {
            SoundEngine.shared.play("close")
            if fsm.isHeldOpen?() != true { state.isPinned = false }
        }
    }

    /// Opens the island on `view` from outside the FSM (alerts, hotkeys, menu, recap, desktop
    /// Mochi…). The mode change reaches the FSM through `modeSubscription`.
    func expand(to view: IslandView) {
        // Already open on the greeting: the new view replaces it for good, so the FSM must
        // stop treating the island as a greeting (whose end, and auto-fold, never come).
        if fsm.state == .coucou && view != .greeting { fsm.openedExternally() }
        show(view)
    }

    /// Shows `view` expanded. The FSM's own transitions call this directly.
    private func show(_ view: IslandView) {
        state.view = view
        if state.mode != .expanded { setMode(.expanded) }
    }

    func collapse(allowPendingApproval: Bool = false) {
        let keepsApprovalPending = allowPendingApproval && state.pendingApproval != nil
        // The hotkey still folds a question, as before it held the island: its card then
        // hands it back to the terminal.
        let foldsQuestion = allowPendingApproval && state.pendingQuestion != nil
        guard fsm.isHeldOpen?() != true || keepsApprovalPending || foldsQuestion else { return }
        if !keepsApprovalPending { state.isPinned = false }
        // Keep the FSM in step with what is on screen (home/coucou → petit now).
        fsm.collapse()
        setMode(.compact)
        window?.resignKey()
    }

    // MARK: - Global hot keys (Carbon)

    private func startHotKeys() {
        guard !AppPaths.isSmokeTest else { return }   // the user's shortcuts stay with their Coucou
        HotKeyCenter.shared.start { [weak self] action in
            self?.handleHotKey(action)
        }
    }

    func handleHotKey(_ action: ShortcutAction) {
        switch action {
        case .toggleIsland:
            if state.mode == .expanded {
                collapse(allowPendingApproval: true)
            } else {
                islandPanel.makeKey()
                fsm.openedExternally()
                expand(to: defaultView())
            }

        case .openChat:
            islandPanel.makeKey()
            expand(to: .prompt)

        case .goToAlert:
            if !openPendingAlert() {
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
                SoundEngine.shared.play("error")
            }

        case .jumpToTerminal:
            #if !APPSTORE
            performJumpToTerminal()
            #endif

        case .attachFrontWindow:
            #if !APPSTORE
            performAttachFrontWindow()
            #endif

        case .nextPill:
            cyclePill(by: +1)

        case .prevPill:
            cyclePill(by: -1)

        case .muteToggle:
            state.soundEnabled.toggle()
            if state.soundEnabled { SoundEngine.shared.play("tick") }
            NotificationCenter.default.post(
                name: .triggerEmote,
                object: state.soundEnabled ? BotEmote.happy : BotEmote.annoyed)

        case .desktopToggle:
            DesktopMochiController.shared.flyOutOrHome()

        case .wardrobeToggle:
            if state.mode == .expanded && state.view == .wardrobe {
                collapse()
            } else {
                islandPanel.makeKey()
                expand(to: .wardrobe)
            }
        }
    }

    // MARK: - Island-local shortcuts

    private func startLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.islandPanel.isKeyWindow else { return event }
            return self.handleIslandKey(event) ? nil : event
        }
    }

    @discardableResult
    private func handleIslandKey(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let cmd = raw == .command

        // ⌘→ — next pill
        if cmd && event.keyCode == 124 { cyclePill(by: +1); return true }
        // ⌘← — previous pill
        if cmd && event.keyCode == 123 { cyclePill(by: -1); return true }
        // ⌘↓ — navigate list down
        if cmd && event.keyCode == 125 { navigateCard(by: +1); return true }
        // ⌘↑ — navigate list up
        if cmd && event.keyCode == 126 { navigateCard(by: -1); return true }
        // ⌘O — open selected card item
        if cmd && event.keyCode == 31  { openCardSelection(); return true }
        // ⌘E — toggle diff
        if cmd && event.keyCode == 14 && state.view == .overview {
            NotificationCenter.default.post(name: .islandToggleDiff, object: nil)
            return true
        }
        // ⌘↩ — send chat message
        if cmd && event.keyCode == 36 && state.view == .prompt {
            NotificationCenter.default.post(name: .islandSendMessage, object: nil)
            return true
        }
        // ⌘K — new conversation
        if cmd && event.keyCode == 40 && state.view == .prompt {
            NotificationCenter.default.post(name: .islandNewConversation, object: nil)
            return true
        }
        // ⌘, — open Settings
        if cmd && event.keyCode == 43 {
            NotificationCenter.default.post(name: .openFullSettings, object: nil)
            return true
        }
        // ⌘P — pin / unpin
        if cmd && event.keyCode == 35 {
            state.isPinned.toggle()
            return true
        }
        // ⌘1–⌘9 — switch to pill by number
        let digitCodes: [UInt16: Int] = [18:1,19:2,20:3,21:4,23:5,22:6,26:7,28:8,25:9]
        if cmd, let n = digitCodes[event.keyCode] {
            switchToPill(number: n); return true
        }
        // ⎋ Escape — focused views (.onExitCommand) have first crack; fall back to collapse
        if event.keyCode == 53 && raw.isEmpty {
            let consumed = NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
            let canCollapse = !state.isPinned || state.pendingApproval != nil
            if !consumed && state.mode == .expanded && canCollapse {
                collapse(allowPendingApproval: true)
            }
            return true
        }
        return false
    }

    /// Opens the island on the approval or question waiting for the user (the ⌃⌥A hotkey,
    /// a click on the amber status line). false when nothing waits.
    @discardableResult
    private func openPendingAlert() -> Bool {
        if state.pendingApproval != nil {
            islandPanel.makeKey()
            fsm.openedExternally()
            expand(to: .approval)
            return true
        }
        if state.pendingQuestion != nil {
            islandPanel.makeKey()
            expand(to: .question)
            return true
        }
        return false
    }

    // MARK: - Compact island clicks

    enum CompactClickTarget {
        case status(CompactStatusLine)
        case music(CompactMusicLine)
        case mini(String)
    }

    /// The status line (or the visualizer in its slot) or mini Mochi under a point of the panel (AppKit window coordinates),
    /// from the same layout the island is drawn with (CompactIslandLayout). nil elsewhere and
    /// outside the compact island.
    private func compactTarget(at windowPoint: CGPoint) -> CompactClickTarget? {
        guard state.mode == .compact, let panel = window as? IslandPanel else { return nil }
        let rect = panel.currentIslandFrame(nw: notchW, nh: notchH)
        let x = windowPoint.x - rect.minX
        let y = rect.maxY - windowPoint.y   // from the island's top
        let model = CompactStatusModel.shared
        let layout = CompactIslandLayout(notchWidth: notchW, hasNotch: hasNotch, status: model.metrics)
        if let line = model.line, layout.statusContains(x: x) { return .status(line) }
        if let music = model.music, layout.statusContains(x: x) { return .music(music) }
        let others = CompactMiniGrid.others(state)
        let scale = IslandRestingLayout(width: rect.width, height: rect.height).miniGridScale
        if let i = layout.miniIndex(atX: x, y: y, height: rect.height, count: others.count, scale: scale) {
            return .mini(others[i].id)
        }
        return nil
    }

    /// A click in the folded island: the status line opens its pill (or the card waiting on
    /// the user), the visualizer its music's pill, a mini Mochi its pill, anything else the
    /// island as it is.
    private func openFromClick(_ target: CompactClickTarget?) {
        switch target {
        case .status(let line)?:
            if line.activity.kind.waitsOnUser, openPendingAlert() { return }
            focusFromCompact(line.pillId)
        case .music(let music)?:
            if let pillId = music.pillId, AppState.shared.tasks.contains(where: { $0.id == pillId }) {
                focusFromCompact(pillId)
            } else if let app = music.appBundleId ?? music.source?.bundleId {
                HostAppInfo.activate(app)   // no music pill: bring the app making the sound
            }
        case .mini(let id)?:
            focusFromCompact(id)
        case nil:
            break
        }
        if fsm.state == .home {
            // FSM already thinks it's open (e.g. the view folded it): just reopen.
            expand(to: defaultView())
        } else {
            fsm.click()   // FSM petit/hidden→home; onTransition calls expand(to:)
        }
    }

    private func focusFromCompact(_ pillId: String) {
        guard state.tasks.contains(where: { $0.id == pillId }) else { return }
        state.setFocus(pillId)
        state.cardSelection = nil
    }

    // MARK: - Pill cycling helpers

    private func cyclePill(by delta: Int) {
        guard !state.tasks.isEmpty else { return }
        let ids = state.tasks.map { $0.id }
        let cur = ids.firstIndex(of: state.focusId ?? "") ?? 0
        state.setFocus(ids[(cur + delta + ids.count) % ids.count])
        state.cardSelection = nil
        expand(to: .overview)
    }

    private func switchToPill(number: Int) {
        guard number >= 1, number <= state.tasks.count else { return }
        state.setFocus(state.tasks[number - 1].id)
        state.cardSelection = nil
        expand(to: .overview)
    }

    private func navigateCard(by delta: Int) {
        guard state.cardItemCount > 0 else { return }
        state.cardSelection = ShortcutLogic.navigate(
            selection: state.cardSelection, delta: delta, itemCount: state.cardItemCount)
    }

    private func openCardSelection() {
        guard state.cardSelection != nil else { return }
        NotificationCenter.default.post(name: .islandActivateCardSelection, object: nil)
    }

    // MARK: - Terminal jump

    #if !APPSTORE
    private func performJumpToTerminal() {
        guard state.focusTask != nil else {
            SoundEngine.shared.play("error")
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
            return
        }
        // The session's app: its IDE, its terminal, or VS Code; then any known terminal.
        if !SessionHost.activate(state.focusTask) {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
        collapse(allowPendingApproval: true)
    }

    private func performAttachFrontWindow() {
        guard let app = state.lastExternalApp else {
            SoundEngine.shared.play("error"); return
        }
        guard let ctx = WindowContextCapture.captureActive(from: app) else {
            SoundEngine.shared.play("error"); return
        }
        state.promptContext = ctx
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        islandPanel.makeKey()
        expand(to: .prompt)
    }
    #endif

    // MARK: - Keyboard (Escape closes)

    private func startKeyMonitor() {
        // A smoke-test run never watches the user's keys or clicks (global monitors).
        let smoke = AppPaths.isSmokeTest
        keyMonitor = smoke ? nil : NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                if event.keyCode == 53 { // Escape
                    // Escape typed in another app (Claude Code's own interrupt, an editor…)
                    // never folds a pending approval away: only Escape in the notch does.
                    if self.state.mode == .expanded && !self.state.isPinned {
                        self.collapse()
                    }
                }
            }
        }

        // Observers registered on the main queue run on the main thread: assumeIsolated
        // states it to the compiler without an extra hop.

        // Hook server expand requests (alerts only)
        NotificationCenter.default.addObserver(forName: .hookExpand, object: nil, queue: .main) { [weak self] note in
            let view = note.object as? IslandView
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.fsm.openedByAlert(pointerInside: self.wasInIsland)
                self.expand(to: view)
            }
        }

        // The last approval / question card was answered (in the notch, from the iPhone…).
        NotificationCenter.default.addObserver(forName: .heldCardClosed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fsm.heldCardClosed(pointerInside: self.wasInIsland)
            }
        }

        // Hook server compact reveal (non-alert work events: session start, tool use, etc.)
        NotificationCenter.default.addObserver(forName: .hookReveal, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fsm.reveal() }
        }

        // Music started playing: reveal silently (no peek sound)
        NotificationCenter.default.addObserver(forName: .musicReveal, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.silentNextReveal = true
                self.fsm.reveal()
                self.silentNextReveal = false
            }
        }

        // Collapse requests from views (OK button, etc.)
        NotificationCenter.default.addObserver(forName: .islandCollapse, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }

        // Wardrobe open/close from desktop Mochi right-click (does NOT post .hookExpand)
        NotificationCenter.default.addObserver(forName: .openWardrobeFromDesktop, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state.mode == .expanded && self.state.view == .wardrobe {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.state.view = .overview
                    }
                } else {
                    self.expand(to: .wardrobe)
                }
            }
        }

        // .botDizzy — posted by BotEngine.slap() on 3rd hit; show confused view + recover after 3.3s
        NotificationCenter.default.addObserver(forName: .botDizzy, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDizzy() }
        }

        // Window attach drag.
        // Uses MainActor.assumeIsolated (synchronous) to avoid race with pollFrame().
        // Global mouseUp is the reliable fallback when cursor is outside our panel frame.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard self.wasInIsland else { return }
                self.fsm.userInteracted()
                self.pendingIslandClick = true
                self.botHoverTimer?.cancel()
                self.botHovering = false
                let onBot = self.isBotHit(event.locationInWindow)
                self.compactClickTarget = onBot ? nil : self.compactTarget(at: event.locationInWindow)
                // Drag only starts when clicking directly on the bot head
                guard onBot else { return }
                // Notch Mochi is invisible when on desktop — no drag, no slap
                guard !self.state.mochiOnDesktop else { return }
                self.attachDragStart = NSEvent.mouseLocation
                // Post slap only when expanded
                guard self.state.mode == .expanded else { return }
                NotificationCenter.default.post(name: .triggerSlap, object: nil)
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard let start = self.attachDragStart, !self.inAttachDrag else { return }
                let m = NSEvent.mouseLocation
                guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
                self.inAttachDrag = true
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
                self.showDragGhost()
            }
            return event
        }

        // mouseUp — local (cursor still in panel) + global (cursor moved outside panel frame)
        let finishDrag: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.inAttachDrag else { return }
                let mouse = NSEvent.mouseLocation
                self.inAttachDrag = false
                self.attachDragStart = nil
                self.state.stateOverride = nil

                #if !APPSTORE
                let windowCtx = self.windowContextAtPoint(mouse)
                let inNotchZone = self.window?.frame.contains(mouse) == true

                if let ctx = windowCtx {
                    // Drop on a window → attach context as before
                    self.hideDragGhost()
                    self.state.promptContext = ctx
                    SoundEngine.shared.play("approve")
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
                    self.expand(to: .prompt)
                } else if !inNotchZone {
                    // Drop outside notch zone → install Mochi on the desktop.
                    // Prevent hideDragGhost from closing the ghost panel so we can promote it.
                    let ghost = self.dragGhostPanel
                    self.dragGhostPanel = nil   // nil first so hideDragGhost skips close
                    self.hideDragGhost()        // resets isDraggingBot, closes highlight panel
                    DesktopMochiController.shared.install(ghostPanel: ghost, at: mouse)
                } else {
                    // Drop back in notch zone → Mochi returns to notch
                    self.hideDragGhost()
                }
                #else
                let inNotchZoneAS = self.window?.frame.contains(mouse) == true
                if !inNotchZoneAS {
                    let ghost = self.dragGhostPanel
                    self.dragGhostPanel = nil
                    self.hideDragGhost()
                    DesktopMochiController.shared.install(ghostPanel: ghost, at: mouse)
                } else {
                    self.hideDragGhost()
                }
                #endif
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let hadPendingClick = self.pendingIslandClick
                let wasDragging     = self.inAttachDrag
                let target          = self.compactClickTarget
                self.pendingIslandClick = false
                self.compactClickTarget = nil
                if wasDragging {
                    finishDrag()
                } else {
                    self.attachDragStart = nil
                    if hadPendingClick && self.state.mode != .expanded {
                        self.openFromClick(target)
                    }
                }
            }
            return event
        }
        if !smoke {
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
                finishDrag()
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard self.wasInIsland, self.isBotHit(event.locationInWindow) else { return }
                guard !self.state.mochiOnDesktop else { return }
                if self.state.mode == .expanded && self.state.view == .wardrobe {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.state.view = .overview
                    }
                } else {
                    self.expand(to: .wardrobe)
                }
            }
            return event
        }

        // Track last external app for window context capture
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != ourBundle else { return }
            MainActor.assumeIsolated { self?.state.lastExternalApp = app }
        }
    }

    // MARK: - Drag ghost window (Mochi follows cursor during drag)

    private func showDragGhost() {
        guard dragGhostPanel == nil else { return }
        // Same size as compact bot: diameter=20 → canvasSize≈33, scale 2× for grab comfort
        let canvasSize: CGFloat = 40 / 0.6      // ~67
        dragGhostSize = canvasSize

        let mouse = NSEvent.mouseLocation
        let s = dragGhostSize
        ghostCurrentOrigin = NSPoint(x: mouse.x - s/2, y: mouse.y - s/2)

        let panel = NSPanel(
            contentRect: NSRect(x: ghostCurrentOrigin.x, y: ghostCurrentOrigin.y, width: s, height: s),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(
            rootView: GhostBotView(canvasSize: canvasSize)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: s, height: s)
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFront(nil)
        dragGhostPanel = panel
        AppState.shared.isDraggingBot = true

        // Fade + scale-in handled by GhostBotView SwiftUI animation;
        // also fade in the window itself for extra smoothness
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideDragGhost() {
        dragGhostPanel?.close()
        dragGhostPanel = nil
        highlightPanel?.close()
        highlightPanel = nil
        highlightWindowPid = 0
        AppState.shared.isDraggingBot = false
    }

    private func updateDragGhost() {
        guard let panel = dragGhostPanel else { return }
        let s = dragGhostSize
        let mouse = NSEvent.mouseLocation
        // Direct follow — bot is "held", no trailing lag
        ghostCurrentOrigin = NSPoint(x: mouse.x - s/2, y: mouse.y - s/2)
        panel.setFrameOrigin(ghostCurrentOrigin)
    }

    // MARK: - Window highlight overlay (white border on target window during drag)

    private func updateWindowHighlight() {
        let mouse = NSEvent.mouseLocation
        guard let (appKitBounds, pid) = windowBoundsAtScreenPoint(mouse) else {
            // Fade out + close if no window under cursor
            if let old = highlightPanel {
                let captured = old
                highlightPanel = nil
                highlightWindowPid = 0
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    captured.animator().alphaValue = 0
                }, completionHandler: {
                    // AppKit calls animation completions on the main thread.
                    MainActor.assumeIsolated { captured.close() }
                })
            }
            return
        }

        if pid == highlightWindowPid, let existing = highlightPanel {
            // Same window — just track position (windows rarely move, instant is fine)
            existing.setFrame(appKitBounds, display: false)
        } else {
            // New window — close old immediately, fade-in new
            highlightPanel?.close()
            highlightPanel = nil
            highlightWindowPid = pid

            let panel = NSPanel(
                contentRect: appKitBounds,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true

            let hosting = NSHostingView(rootView:
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.75), lineWidth: 3)
                    .shadow(color: Color.white.opacity(0.5), radius: 16)
                    .padding(2)
                    .ignoresSafeArea()
            )
            hosting.frame = CGRect(origin: .zero, size: appKitBounds.size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            panel.alphaValue = 0
            panel.orderFront(nil)
            highlightPanel = panel

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func windowBoundsAtScreenPoint(_ screenPoint: NSPoint) -> (CGRect, pid_t)? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let screenMaxY = screen.frame.maxY
        let cgPoint = CGPoint(x: screenPoint.x, y: screenMaxY - screenPoint.y)

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        for info in list {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            guard CGRect(x: x, y: y, width: w, height: h).contains(cgPoint) else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != ourBundle,
                  app.activationPolicy == .regular else { continue }
            // CG → AppKit: flip Y
            return (CGRect(x: x, y: screenMaxY - y - h, width: w, height: h), pid)
        }
        return nil
    }

    // MARK: - Window context at screen point (for drag-attach)

    func windowContextAtPoint(_ screenPoint: NSPoint) -> PromptContext? {
        let screen = window?.screen ?? NSScreen.main
        // CGWindowList uses top-left origin; NSEvent.mouseLocation uses bottom-left
        let screenMaxY = screen?.frame.maxY ?? NSScreen.main!.frame.maxY
        let cgPoint = CGPoint(x: screenPoint.x, y: screenMaxY - screenPoint.y)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ourBundle = Bundle.main.bundleIdentifier ?? ""

        for info in windowList {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            guard CGRect(x: x, y: y, width: w, height: h).contains(cgPoint) else { continue }

            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != ourBundle,
                  app.activationPolicy == .regular else { continue }

            return WindowContextCapture.captureActive(from: app)
        }
        return nil
    }

    // MARK: - Coordinate conversion: window (AppKit, y-up) → island coords (y-down, 0,0 = island top-left)

    func windowToIsland(_ loc: CGPoint) -> CGPoint {
        let panelH = window?.frame.height ?? IslandConst.panelHeight
        let panelW = window?.frame.width  ?? IslandConst.panelWidth
        let islandLeft = (panelW - IslandConst.expandedWidth) / 2
        // Island is glued to panel top; its bottom in AppKit = panelH - 176
        return CGPoint(
            x: loc.x - islandLeft,
            y: panelH - loc.y                // AppKit y is from bottom; island y from top
        )
    }

    // MARK: - Helpers

    func defaultView() -> IslandView {
        if state.pendingApproval != nil { return .approval }
        return state.tasks.isEmpty ? .empty : .overview
    }

    // MARK: - Dizzy recovery (triggered by BotEngine.slap via .botDizzy)

    private func handleDizzy() {
        let prevView = state.view
        state.stateOverride = .dizzy
        expand(to: .confused)
        confusedRecoveryTimer?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.stateOverride = nil
            if self.state.view == .confused {
                let fallback = self.state.tasks.isEmpty ? IslandView.empty : .overview
                self.state.view = (prevView == .confused) ? fallback : prevView
            }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        }
        confusedRecoveryTimer = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3, execute: recovery)
    }

    // MARK: - Bot hit test (for slap trigger)

    private func isBotHit(_ windowPoint: CGPoint) -> Bool {
        let s = AppState.shared
        let panelH = window?.frame.height ?? IslandConst.panelHeight
        let panelW = window?.frame.width  ?? IslandConst.panelWidth
        let size = islandSize(s, nw: notchW, nh: notchH)
        let (islandW, islandH) = (size.width, size.height)
        let islandMinX = (panelW - islandW) / 2 + size.offsetX
        let (cx, cy, diameter, _) = botPosition(mode: s.mode, view: s.view,
                                                  islandW: islandW, islandH: islandH,
                                                  uploadProgress: s.uploadProgress, hasNotch: s.hasNotch)
        let radius = (diameter / 0.6) / 2
        // botPosition cy is from island TOP; panel AppKit coords have y=0 at bottom
        // island top in AppKit coords = panelH (island glued to top of panel/screen)
        let botX = islandMinX + cx
        let botY = panelH - cy
        let dx = windowPoint.x - botX
        let dy = windowPoint.y - botY
        return dx*dx + dy*dy <= radius * radius
    }

    // MARK: - Notch detection (static)

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Top of the menu-bar screen in AppKit coordinates: origin of `DesktopSpace`.
    static var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// Screen the island currently sits on (Settings window, desktop Mochi flights).
    private(set) static var currentScreen: NSScreen?

    static func islandScreen() -> NSScreen {
        if let s = currentScreen, NSScreen.screens.contains(s) { return s }
        return notchScreen() ?? NSScreen.main!
    }

    /// Screen matching the user's choice; falls back to the notch screen, then the main one.
    static func targetScreen(for choice: IslandDisplayChoice) -> NSScreen {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let candidates = screens.map {
            IslandDisplayCandidate(uuid: displayUUID($0), hasNotch: $0.safeAreaInsets.top > 0,
                                   containsMouse: $0.frame.contains(mouse))
        }
        if let i = IslandDisplayResolver.index(for: choice, in: candidates) { return screens[i] }
        return notchScreen() ?? NSScreen.main ?? screens[0]
    }

    /// Stable display UUID (the NSScreenNumber can change after a reboot or a replug).
    static func displayUUID(_ screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screenGeometry(for screen: NSScreen) -> IslandScreenGeometry {
        let visibleMenuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // visibleFrame includes the menu bar only while it is visible. Keep a
        // small resting bar when menus auto-hide or the app is in full screen.
        let menuBarHeight = visibleMenuBarHeight > 0
            ? visibleMenuBarHeight : NSStatusBar.system.thickness
        return IslandScreenGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight
        )
    }
}

// MARK: - IslandPanel

final class IslandPanel: NSPanel {
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow panel to sit in the menu bar / notch area — don't let macOS push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    func currentIslandFrame(nw: CGFloat, nh: CGFloat) -> CGRect {
        let size = islandSize(AppState.shared, nw: nw, nh: nh)
        return CGRect(x: (frame.width - size.width) / 2 + size.offsetX, y: frame.height - size.height,
                      width: size.width, height: size.height)
    }
}

// MARK: - Ghost bot view (animated scale-in on appear)

struct GhostBotView: View {
    let canvasSize: CGFloat
    @State private var scale: CGFloat = 0.35

    var body: some View {
        BotCanvasView(state: AppState.shared)
            .frame(width: canvasSize, height: canvasSize)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    scale = 1.0
                }
            }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let triggerEmote     = Notification.Name("notchBuddy.triggerEmote")
    static let triggerSlap      = Notification.Name("notchBuddy.triggerSlap")
    static let botDizzy         = Notification.Name("notchBuddy.botDizzy")
    static let botGreet         = Notification.Name("notchBuddy.botGreet")
    static let botBlink         = Notification.Name("notchBuddy.botBlink")
    static let botSetTgEs       = Notification.Name("notchBuddy.botSetTgEs")
    static let botGulp          = Notification.Name("notchBuddy.botGulp")
    static let botMorphTo       = Notification.Name("notchBuddy.botMorphTo")
    static let islandCollapse      = Notification.Name("notchBuddy.islandCollapse")
    static let islandSendMessage   = Notification.Name("notchBuddy.islandSendMessage")
    static let islandNewConversation = Notification.Name("notchBuddy.islandNewConversation")
    static let islandToggleDiff           = Notification.Name("notchBuddy.islandToggleDiff")
    static let islandActivateCardSelection = Notification.Name("notchBuddy.islandActivateCardSelection")
    static let openFullSettings    = Notification.Name("notchBuddy.openFullSettings")
    static let hookReveal       = Notification.Name("notchBuddy.hookReveal")
    static let musicReveal      = Notification.Name("notchBuddy.musicReveal")
    // Greeting ↔ IslandWindowController
    static let greetComplete    = Notification.Name("notchBuddy.greetComplete")
    static let checkMondayRecap = Notification.Name("notchBuddy.checkMondayRecap")
    static let greetingHover    = Notification.Name("notchBuddy.greetingHover")
    static let greetingInterrupt = Notification.Name("notchBuddy.greetingInterrupt")
    static let openWardrobeFromDesktop = Notification.Name("notchBuddy.openWardrobeFromDesktop")
    // Island moved to another screen (resting size may differ: notch vs bar)
    static let islandScreenChanged = Notification.Name("notchBuddy.islandScreenChanged")
}

// MARK: - islandSize (takes real notch dimensions)

/// The island's size, and how far its centre sits from the panel's (screen's) centre: only
/// a compact island showing its status line on a notched screen is off-centre (its right
/// ear grows, CompactIslandLayout).
struct IslandSize: Equatable {
    var width: CGFloat
    var height: CGFloat
    var offsetX: CGFloat = 0
}

/// Island size for a mode and view. The single place that knows the sizes: the panel's hit
/// test, the bot hit test, the bot's gaze and IslandContainer must agree, or clicks and slaps
/// land beside the island. `chatCount` is the chat history length (the chat grows with it).
/// `status`: the compact island's status line (CompactStatusModel.metrics).
func islandSize(mode: IslandMode, view: IslandView,
                progress: Double = 0,
                nw: CGFloat = IslandConst.notchWidth,
                nh: CGFloat = IslandConst.notchHeight,
                hasNotch: Bool,
                chatCount: Int,
                status: CompactStatusMetrics) -> IslandSize {
    switch mode {
    case .hidden:   return IslandSize(width: nw, height: nh)
    case .compact:
        let layout = CompactIslandLayout(notchWidth: nw, hasNotch: hasNotch, status: status)
        return IslandSize(width: layout.width, height: nh, offsetX: layout.offsetX)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        if view == .question, let h = QuestionLayout.height {
            return IslandSize(width: IslandConst.expandedWidth, height: h)
        }
        if view == .prompt {
            return IslandSize(width: IslandConst.expandedWidth,
                              height: IslandConst.chatPromptHeight(messageCount: chatCount))
        }
        return IslandSize(width: IslandConst.expandedWidth, height: layout.height)
    }
}

/// The same, from the app's state: every caller reads the same inputs. `nw`/`nh` default to
/// the state's notch (the controller passes its own copy, which `relocate` keeps equal).
@MainActor
func islandSize(_ s: AppState, mode: IslandMode? = nil, view: IslandView? = nil,
                nw: CGFloat? = nil, nh: CGFloat? = nil) -> IslandSize {
    islandSize(mode: mode ?? s.mode, view: view ?? s.view, progress: s.uploadProgress,
               nw: nw ?? s.notchWidth, nh: nh ?? s.notchHeight, hasNotch: s.hasNotch,
               chatCount: s.chatHistory.count, status: CompactStatusModel.shared.metrics)
}
