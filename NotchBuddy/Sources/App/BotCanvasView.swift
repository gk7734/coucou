import SwiftUI
import QuartzCore

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    var state: AppState
    var particleOverhang: CGFloat = 0
    /// When set, overrides island-based eye-tracking (used by desktop Mochi).
    /// CGPoint in the same coord space as state.mousePosition (DesktopSpace, y-down).
    var lookOriginOverride: CGPoint? = nil
    /// False while this Mochi is mounted but not seen (the island's own Mochi while it is
    /// dragged or lives on the desktop): no frames are drawn for nobody.
    var isShown: Bool = true

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()
    @StateObject private var cadence = MochiCadence()

    var body: some View {
        // 30 fps while calm outside the expanded island, the display's rate otherwise
        // (MochiFrameRate).
        TimelineView(.animation(
            minimumInterval: MochiFrameRate.minimumInterval(
                fast: cadence.fast, alwaysFull: state.mode == .expanded || state.isDraggingBot),
            paused: state.mode == .hidden || !isShown
        )) { timeline in
            Canvas { context, size in
                _ = timeline.date
                // Same clock as the engine's tweens (the frame's own date counts from 2001).
                let dt = min(0.05, max(0, CACurrentMediaTime() - engine.lastTime))
                engine.lookX = lookX(state: state, size: size)
                engine.lookY = lookY(state: state, size: size)
                engine.particleOverhang = particleOverhang
                // Widen slot when file is hovering over the mailbox (morph > 0.5)
                // Open mouth (hover=0.20R) when file dragged over box; close when not
                if engine.morph > 0.3 {
                    engine.slotHTarget = state.fileDragOver ? 0.20 : 0
                } else {
                    engine.slotHTarget = 0
                    if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
                }
                // Integration pills have a fixed brand color → use it as bodyColor.
                // Claude Code tasks use state-based gradient (working=blue, thinking=purple, etc.).
                #if !APPSTORE
                if state.showingPlanDetail {
                    let hex = state.planDetailIsCodex
                        ? CodexPlanGauge.color(state.codexPlanUsage)
                        : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
                    engine.bodyColor = cgColorFromHex(hex)
                } else {
                    engine.bodyColor = (state.focusTask?.isIntegration == true)
                        ? cgColorFromHex(state.focusTask!.color)
                        : nil
                }
                #else
                engine.bodyColor = (state.focusTask?.isIntegration == true)
                    ? cgColorFromHex(state.focusTask!.color)
                    : nil
                #endif

                // Compute shouldDance per-frame (no observer lag)
                let dancing: Bool = {
                    #if !APPSTORE
                    let active = AppState.shared.activeIntegrations
                    let music = AppState.shared.musicPlaying && active.contains("integration_music")
                    let spotify = SpotifyController.shared.isPlaying && active.contains(SpotifyController.pillId)
                    guard music || spotify else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    guard allowed.contains(state.effectiveState) else { return false }
                    if state.mode == .compact { return true }
                    guard state.mode == .expanded && state.view == .overview else { return false }
                    return (music && state.focusId == "integration_music")
                        || (spotify && state.focusId == SpotifyController.pillId)
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)
                let isWardrobe = state.mode == .expanded && state.view == .wardrobe
                let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
                let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
                engine.setOutfit(showOutfit ? state.resolvedOutfit : .none,
                                 animated: state.view != .wardrobe)

                engine.update(dt: dt)
                cadence.track(engine)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                // Rigid-roll: when Mochi wears an outfit (presence > 0.05) and is rolling,
                // rotate the entire body+accessories context around the body center so the
                // whole character genuinely turns. Particles/badge (drawHandsAndExtras) are
                // drawn outside the rotated context and do not spin.
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigidCtx = ctx
                    rigidCtx.translateBy(x: center.x, y: center.y)
                    rigidCtx.rotate(by: .radians(engine.roll))
                    rigidCtx.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigidCtx, size: size)
                    engine.drawOutfitBehind(context: rigidCtx, size: size)
                    engine.draw(context: rigidCtx, size: size)
                    engine.drawOutfitFront(context: rigidCtx, size: size)
                } else {
                    engine.drawHandsBehind(context: ctx, size: size)
                    engine.drawOutfitBehind(context: ctx, size: size)
                    engine.draw(context: ctx, size: size)
                    engine.drawOutfitFront(context: ctx, size: size)
                }
                engine.drawHandsAndExtras(context: ctx, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
            cadence.kick()
        }
        .onChange(of: state.view) { _, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim(.morph, keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
                cadence.kick()
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim(.morph, keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
                cadence.kick()
            }
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.cancelTween(.morph)
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
                cadence.kick()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
            cadence.kick()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            engine.gulp()
            cadence.kick()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim(.morph, keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
                cadence.kick()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            engine.greet()
            cadence.kick()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
            let isWardrobe = state.mode == .expanded && state.view == .wardrobe
            let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
            let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
            engine.setOutfit(showOutfit ? state.resolvedOutfit : .none, animated: false)
        }
    }

    private func lookX(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return tanh((state.mousePosition.x - origin.x) / 260)
        }
        return tanh((state.mousePosition.x - islandBotPoint(state: state).x) / 260)
    }

    private func lookY(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return -tanh((state.mousePosition.y - origin.y) / 200)
        }
        return -tanh((state.mousePosition.y - islandBotPoint(state: state).y) / 200)
    }

    /// Bot centre in DesktopSpace, like state.mousePosition. The island is centred at the
    /// top of its screen, which can be any display, anywhere in the arrangement.
    /// Same size and position as BotPlacement draws, notchless screens included.
    private func islandBotPoint(state: AppState) -> CGPoint {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight,
                                             chatCount: state.chatHistory.count)
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                islandW: islandW, islandH: islandH,
                                                uploadProgress: state.uploadProgress,
                                                hasNotch: state.hasNotch)
        let screen = IslandWindowController.islandScreen().frame
        return DesktopSpace.topDown(CGPoint(x: screen.midX - islandW / 2 + botCx,
                                            y: screen.maxY - botCy),
                                    desktopTop: IslandWindowController.desktopTop)
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine
    @StateObject private var cadence = MochiCadence()
    /// False in an island view that is mounted but not showing: no frames drawn for nobody.
    @Environment(\.islandViewActive) private var isActive

    init(task: AgentTask, isDancing: Bool = false) {
        self.task = task
        self.isDancing = isDancing
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        // 30 fps while calm, the display's rate during a hop or a head shake (MochiFrameRate).
        TimelineView(.animation(
            minimumInterval: MochiFrameRate.minimumInterval(fast: cadence.fast, alwaysFull: false),
            paused: !isActive
        )) { timeline in
            Canvas { context, size in
                _ = timeline.date
                let dt = min(0.05, max(0, CACurrentMediaTime() - engine.lastTime))
                engine.setDancing(isDancing)
                engine.update(dt: dt)
                cadence.track(engine)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.draw(context: ctx, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        // The colour is set once, when the engine is made: a colour picked in
        // Settings has to reach a mini Mochi that is already on screen.
        .onChange(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}

/// Publishes MochiFrameRate's switches, so the TimelineView picks up its new cadence.
@MainActor
final class MochiCadence: ObservableObject {
    @Published private(set) var fast = false
    private var rate = MochiFrameRate()

    /// Called by the Canvas after each update. The switch is published once the frame is
    /// drawn: a view must not change state while it renders.
    func track(_ engine: BotEngine) {
        if rate.update(now: CACurrentMediaTime(), fastMotion: engine.hasFastMotion) { publish() }
    }

    /// Something is about to move Mochi fast: full rate from the next frame.
    func kick() {
        if rate.kick(now: CACurrentMediaTime()) { publish() }
    }

    private func publish() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fast != self.rate.fast else { return }
            self.fast = self.rate.fast
        }
    }
}
