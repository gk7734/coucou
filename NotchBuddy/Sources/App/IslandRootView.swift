import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×560 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
/// Note: drag-drop is handled at the AppKit level in IslandWindowController (FileDropNSView),
/// not in SwiftUI, to avoid interfering with SwiftUI hit-testing.
struct IslandRootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Island container

struct IslandContainer: View {
    var state: AppState
    @ObservedObject private var demoEngine = DemoEngine.shared
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    // topRadius > 0 → convex expanded corners; < 0 → concave ear cutouts
    @State private var islandTopRadius: CGFloat = 0
    /// Island centre minus panel centre: a compact island with its status line on a notched
    /// screen grows its right ear only (CompactIslandLayout). Animated with the width.
    @State private var islandOffsetX: CGFloat = 0
    @State private var greetNotif: Bool = false
    private var compactStatus: CompactStatusModel { CompactStatusModel.shared }

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase  = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    /// Pixels the content must be pushed down to clear the concave ear transparent area.
    /// = 0 in expanded mode (no ears), = earRadius in compact/notch mode.
    private var earOffset: CGFloat { max(0, -islandTopRadius) }

    var body: some View {
        // Canvas active during drag-over (.upload), post-drop animation (.uploading),
        // AND choose overlay (.choose) — canvas handles the full sequence through user action.
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        let uploadActive = state.mode == .expanded
            && UploadSequenceEngine.shared.isActive
            && (state.view == .upload || state.view == .uploading || state.view == .choose)

        let greetingActive = state.mode == .expanded && state.view == .greeting

        return ZStack(alignment: .topLeading) {
            // Black island shape
            IslandShape(width: islandWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius)
                .fill(Color.black)

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(.opacity)
                } else if uploadActive {
                    ZStack(alignment: .topLeading) {
                        UploadCanvasView(state: state)
                            .frame(width: islandWidth, height: islandHeight)
                            .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                                  cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        // Header overlaid: canvas CARD_Y=42 aligns exactly with header bottom,
                        // matching normal view proportions (8pt top + 34pt header + card + 10pt bottom).
                        IslandHeader(state: state)
                            .frame(width: islandWidth, height: 34)
                            .offset(y: 8)
                    }
                    .transition(.opacity)
                } else {
                    IslandContentView(state: state)
                        .frame(width: islandWidth, height: islandHeight - earOffset)
                        .offset(y: earOffset)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(.opacity)
                }
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during upload canvas or greeting (both draw their own Mochi).
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                // Keep idle animations inside the resting strip. Expanded views
                // retain the panel's full height for particles and hands (a tall question
                // card centres Mochi below the old 320 pt limit, which clipped him).
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: islandWidth,
                                      height: state.mode == .expanded ? IslandConst.panelHeight : islandHeight)
                }
                .opacity(uploadActive || greetingActive ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: uploadActive || greetingActive)

            CountdownBar(state: state, islandW: islandWidth)

            if demoEngine.isActive {
                Text(verbatim: "DEMO")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(hex: "#4ADE80"))
                    .clipShape(Capsule())
                    .position(x: 18, y: islandHeight - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: demoEngine.isActive)
            }

            Group {
                if state.mode == .compact {
                    // Own views, so a new line or a hovered mini redraws them, not the island.
                    CompactStatusOverlay(state: state, islandW: islandWidth, islandH: islandHeight,
                                         cornerRadius: cornerRadius, topRadius: islandTopRadius)
                        .transition(.opacity)
                    CompactMiniGrid(state: state)
                        .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                        .position(x: islandWidth - 40, y: islandHeight / 2)
                        .transition(.opacity)
                    CompactMiniTooltipLayer(state: state, islandW: islandWidth, islandH: islandHeight)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.mode == .compact)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        .offset(x: islandOffsetX)
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let size = islandSize(state, mode: newMode)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            let tr: CGFloat = 0
            withAnimation(anim) {
                islandWidth      = size.width
                islandHeight     = size.height
                islandOffsetX    = size.offsetX
                cornerRadius     = cr
                islandTopRadius  = tr
            }
        }
        .onChange(of: compactStatus.metrics) { old, new in
            // The status line came, went or changed width: the compact island follows it.
            guard state.mode == .compact else { return }
            let size = islandSize(state)
            withAnimation(new.statusWidth >= old.statusWidth ? openSpring : closeEase) {
                islandWidth   = size.width
                islandOffsetX = size.offsetX
            }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            // Deactivate engine if user navigates outside the upload flow
            let uploadViews: Set<IslandView> = [.upload, .uploading, .choose]
            if UploadSequenceEngine.shared.isActive && !uploadViews.contains(newView) {
                UploadSequenceEngine.shared.deactivate()
            }
            let size = islandSize(state, mode: .expanded, view: newView)
            withAnimation(openSpring) {
                islandWidth   = size.width
                islandHeight  = size.height
                islandOffsetX = size.offsetX
            }
        }
        .onChange(of: state.questionContentHeight) { _, _ in
            guard state.mode == .expanded, state.view == .question, let h = QuestionLayout.height else { return }
            withAnimation(openSpring) { islandHeight = h }
        }
        .onChange(of: state.chatHistory.count) { _, _ in
            guard state.mode == .expanded, state.view == .prompt else { return }
            withAnimation(openSpring) {
                islandHeight = IslandConst.chatPromptHeight(messageCount: state.chatHistory.count)
            }
        }
        .onAppear {
            let size = islandSize(state)
            islandWidth      = size.width
            islandHeight     = size.height
            islandOffsetX    = size.offsetX
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            islandTopRadius  = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            greetNotif.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandScreenChanged)) { _ in
            // New screen, new resting size (notch ↔ bar): snap without animation.
            let size = islandSize(state)
            islandWidth   = size.width
            islandHeight  = size.height
            islandOffsetX = size.offsetX
        }
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// topRadius > 0  → convex rounded top corners (expanded mode)
// topRadius < 0  → concave ear cutouts, |topRadius| = ear radius (compact/notch mode)
// topRadius = 0  → sharp top corners (transient during animation)

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var topRadius: CGFloat      // see above

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(width, height), cornerRadius), topRadius) }
        set {
            width        = newValue.first.first.first
            height       = newValue.first.first.second
            cornerRadius = newValue.first.second
            topRadius    = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, cornerRadius)
        var p  = Path()

        if topRadius >= 0 {
            // ── Convex rounded top corners (expanded) ──────────────────────────
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            // Top-right convex corner
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            p.addLine(to: CGPoint(x: 0, y: tr))
            // Top-left convex corner
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // ── Concave ear cutouts (compact / notch) ─────────────────────────
            let er = -topRadius   // positive ear radius
            p.move(to: CGPoint(x: 0, y: 0))
            // Top-left ear
            p.addArc(center: CGPoint(x: 0, y: er), radius: er,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Top edge
            p.addLine(to: CGPoint(x: width - er, y: er))
            // Top-right ear
            p.addArc(center: CGPoint(x: width, y: er), radius: er,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge back to top-left corner
            p.addLine(to: CGPoint(x: 0, y: 0))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Bot placement helper

struct BotPlacement: View {
    var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    var body: some View {
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, uploadProgress: state.uploadProgress, hasNotch: state.hasNotch)
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = 40
        // Expanded only: an island folded mid-upload keeps view == .uploading, and the
        // uploading branch then misplaced Mochi and ran its TimelineView while hidden.
        let isUploading = state.mode == .expanded && state.view == .uploading

        Group {
            // No glow in uploading mode — the tiny dot doesn't need it
            if state.mode == .expanded && !isUploading {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: botGlowColor(state.effectiveState), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 1.1
                    ))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                    .blur(radius: 6)
                    .opacity(botGlowOpacity(state.effectiveState))
                    .position(x: cx, y: cy)
                    .animation(.easeInOut(duration: 0.4), value: state.effectiveState)
            }

            // Uploading: no particle overhang (no hearts during upload), positioned directly at cy.
            // BotEngine cy = H/2 + 0 + oy*R + R*0.06 ≈ H/2 (body centered in canvas).
            // With .position(x:y:) placing the frame center at (uploadCx, cy), bot is at cy ✓.
            //
            // Normal: extra 40pt canvas at top for heart particles; position offset up by 20pt;
            // BotEngine compensates with cy = H/2 + particleOverhang/2 + oy*R + R*0.06.
            if isUploading {
                TimelineView(.animation) { tl in
                    let elapsed: Double = {
                        guard let start = state.uploadStartTime else { return 0 }
                        return tl.date.timeIntervalSince(start)
                    }()
                    let t = min(1.0, max(0, elapsed / state.uploadDuration))
                    // cx = 36 + 526*t: bot center at fill right edge (bar left=36, width=526)
                    let uploadCx = 36 + CGFloat(t * (2 - t)) * 526
                    BotCanvasView(state: state, particleOverhang: 0,
                                  isShown: !(state.isDraggingBot || state.mochiOnDesktop))
                        .frame(width: canvasSize, height: canvasSize)
                        .opacity(state.isDraggingBot || state.mochiOnDesktop ? 0 : opacity)
                        .position(x: uploadCx, y: cy)
                }
                .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            } else {
                BotCanvasView(state: state, particleOverhang: overhang,
                              isShown: !(state.isDraggingBot || state.mochiOnDesktop))
                    .frame(width: canvasSize, height: canvasSize + overhang)
                    .opacity(state.isDraggingBot || state.mochiOnDesktop ? 0 : opacity)
                    .position(x: cx, y: cy - overhang / 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cx)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cy)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: canvasSize)
                    .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            }
        }
        // Branch switch (uploading ↔ normal) animates with a fast spring: uploading dot
        // scales out at bar-end while normal bot scales in at choose position.
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: isUploading)
        // Slap, drag, and hover are handled by the AppKit NSEvent monitor in
        // IslandWindowController — not SwiftUI gestures — so this is safe.
        .allowsHitTesting(false)
    }

    private func botGlowColor(_ s: BotState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color.white
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle, .sleeping: return 0.15
        case .dizzy:           return 0.0
        default:               return 0.65
        }
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, uploadProgress: Double, hasNotch: Bool = true) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact: return (40, resting.botCenterY, resting.botDiameter, 1)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        // Uploading: Mochi dot rides the leading edge of the progress fill.
        // Bar in island coords: left=36, width=526. cx = 36 + progress*526 (dot center at fill right edge).
        // cy comes from ViewLayout.botY (bar center in island coords).
        if view == .uploading {
            let cx = 36 + CGFloat(uploadProgress) * 526
            return (cx, layout.botY ?? 103, diameter, 1)
        }
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Center of the fixed 84pt card (VStack top=8, header=34 → content starts at y=42)
            let headerBottom: CGFloat = 42
            let cardH: CGFloat = 84
            cy = headerBottom + (islandH - headerBottom - cardH) / 2 + cardH / 2
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Countdown bar

/// The FSM's pending auto-close (`IslandStateMachine.countdown`), published for the bar.
/// Its own object so a countdown starting or stopping redraws the bar, not the whole island.
@MainActor
final class IslandAutoCloseCountdown: ObservableObject {
    static let shared = IslandAutoCloseCountdown()
    @Published var countdown: IslandStateMachine.Countdown?
}

/// 2 pt line at the bottom of an open island, 160 pt → 0 over the last seconds before the
/// island really folds. Driven by the FSM's timer: no countdown (pointer on the island,
/// opened by an alert, hover grace) means no bar, and it redraws only inside its window.
struct CountdownBar: View {
    var state: AppState
    let islandW: CGFloat
    @ObservedObject private var autoClose = IslandAutoCloseCountdown.shared

    var body: some View {
        let countdown = state.mode == .expanded ? autoClose.countdown : nil
        let ticks = countdown.map { IslandStateMachine.countdownTicks($0, from: .now) } ?? []
        TimelineView(.explicit(ticks)) { _ in
            GeometryReader { _ in
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: barWidth(countdown), height: 2)
                    .cornerRadius(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// Reads the clock, not the timeline entry: before its first tick the timeline may
    /// already render with that future date.
    private func barWidth(_ countdown: IslandStateMachine.Countdown?) -> CGFloat {
        guard let countdown, !state.isPinned,
              let fraction = IslandStateMachine.countdownFraction(countdown, at: .now) else { return 0 }
        return max(0, CGFloat(fraction) * 160)
    }
}

/// False inside the island views that are mounted but not showing (IslandContentView keeps
/// all of them alive): their animations pause instead of running unseen.
private struct IslandViewActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var islandViewActive: Bool {
        get { self[IslandViewActiveKey.self] }
        set { self[IslandViewActiveKey.self] = newValue }
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: 34)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            ZStack {
                ForEach(IslandView.allCases, id: \.self) { v in
                    let active = state.view == v
                    // Views that fill available height instead of the fixed 98pt content frame:
                    // chat (prompt) is always flexible; mail is flexible only when active so
                    // it doesn't push the ZStack taller when inactive.
                    // The question card fills the island, whose height follows the card's content.
                    let isTall = v == .prompt || ((v == .mail || v == .question) && active)
                    let anim: Animation = active
                        ? .spring(response: 0.4, dampingFraction: 0.8).delay(0.16)
                        : .easeIn(duration: 0.16)
                    IslandViewContent(view: v, state: state)
                        .environment(\.islandViewActive, active)
                        .frame(maxWidth: .infinity)
                        .frame(height: isTall ? nil : 98)
                        .frame(minHeight: (isTall && !active) ? 0 : nil, maxHeight: isTall ? .infinity : nil)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.97)
                        .allowsHitTesting(active)
                        .animation(anim, value: state.view)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    var state: AppState

    // Claude + Codex pills together: tighten the right side so it clears the notch
    private var bothPlans: Bool {
        #if !APPSTORE
        return state.view == .overview && state.showPlanInNotch && state.planRelayInstalled && state.showCodexPlanInNotch
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: tab capsules
            HStack(spacing: 5) {
                TabButton(icon: "house.fill", view: .overview, state: state)
                TabButton(icon: "bubble.left.fill", view: .prompt, state: state, preAction: {
                    #if !APPSTORE
                    if state.promptContext == nil {
                        state.promptContext = WindowContextCapture.captureActive(from: state.lastExternalApp)
                    }
                    #endif
                })
                TabButton(icon: "plus", view: .upload, state: state)
            }
            .padding(.leading, 14)

            Spacer()

            // Right: plan pill (GitHub build, home view only) + action icons
            HStack(spacing: bothPlans ? 5 : 8) {
                #if !APPSTORE
                if state.view == .overview && state.showPlanInNotch && state.planRelayInstalled {
                    ClaudePlanHeaderPill(state: state)
                }
                if state.view == .overview && state.showCodexPlanInNotch {
                    ClaudePlanHeaderPill(state: state, codex: true)
                }
                #endif
                HStack(spacing: bothPlans ? 10 : 14) {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            state.view = .settings
                        }
                    }) {
                        Image(systemName: state.view == .settings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 14))
                            .foregroundColor(state.view == .settings ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)

                    Button(action: { state.soundEnabled.toggle() }) {
                        Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, bothPlans ? 8 : 16)
        }
        .frame(maxHeight: .infinity)
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(
                    isOn ? Color(hex: "#1D1F23") :
                    isHovered ? Color.white.opacity(0.07) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Claude Plan header pill (GitHub build only)

#if !APPSTORE
struct ClaudePlanHeaderPill: View {
    var state: AppState
    var codex: Bool = false
    @State private var isHovered = false

    private var effectiveColor: String {
        if codex { return CodexPlanGauge.color(state.codexPlanUsage) }
        return ClaudePlanGauge.color(for: (state.demoPlanUsageOverride ?? state.claudePlanUsage).flatMap { ClaudePlanGauge.dominantPct($0) })
    }

    private var label: String {
        if codex { return CodexPlanGauge.pillLabel(state.codexPlanUsage) }
        guard let usage = state.demoPlanUsageOverride ?? state.claudePlanUsage,
              let pct = ClaudePlanGauge.dominantPct(usage) else { return "Claude —" }
        return "Claude \(Int(pct.rounded()))%"
    }

    private var isOpen: Bool { state.showingPlanDetail && state.planDetailIsCodex == codex }
    private var isActive: Bool { isOpen || isHovered }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                let open = isOpen
                state.planDetailIsCodex = codex
                state.showingPlanDetail = !open
            }
            if codex { state.refreshCodexPlanUsage() }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: effectiveColor))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isActive
                                     ? Color(hex: effectiveColor).lighter(by: 0.3)
                                     : Color(hex: "#6B7079"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive
                          ? Color(hex: effectiveColor).opacity(0.18)
                          : Color(hex: "#0E0F11"))
            )
            .overlay(
                Capsule()
                    .stroke(Color(hex: effectiveColor).opacity(isActive ? 0.55 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = h }
        }
        .onAppear { if codex { state.refreshCodexPlanUsage() } }
    }
}
#endif

// MARK: - Compact mini mochi grid (2×2 to the right of the notch)

struct CompactMiniGrid: View {
    var state: AppState

    /// The pills shown as mini Mochis, in grid order (IslandWindowController hit-tests them).
    static func others(_ state: AppState) -> [AgentTask] {
        Array(state.tasks.filter { $0.id != state.focusId }.prefix(4))
    }

    private var others: [AgentTask] { Self.others(state) }

    var body: some View {
        let cols = [GridItem(.fixed(12), spacing: 4), GridItem(.fixed(12), spacing: 4)]
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(others) { task in
                MiniBotCanvasView(task: task)
                    .frame(width: 12 / 0.6, height: 12 / 0.6)
                    .frame(width: 12, height: 12, alignment: .center)
                    // Still mounted while it fades out: no animating an island going away.
                    .environment(\.islandViewActive, state.mode == .compact)
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Compact status line ("Orca · ✎ HookServer.swift  2m")

/// The status line inside the compact island, clipped to the island's shape so it never shows
/// outside it while the island grows. Clicks are handled by IslandWindowController (AppKit).
struct CompactStatusOverlay: View {
    var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat
    let cornerRadius: CGFloat
    let topRadius: CGFloat
    private var model: CompactStatusModel { CompactStatusModel.shared }

    /// A new identity for each new thing said: the old line fades out as the new one fades in
    /// (the status line and the visualizer cross-fade the same way).
    private func identity(_ line: CompactStatusLine?, _ music: CompactMusicLine?) -> String {
        if let music { return "♪\u{1F}\(music.source.rawValue)\u{1F}\(music.text)" }
        guard let line else { return "" }
        return "\(line.pillId)\u{1F}\(line.activity.kind.rawValue)\u{1F}\(line.text)\u{1F}\(line.pillName)\u{1F}\(line.turnStartedAt != nil)"
    }

    var body: some View {
        let line = model.line
        let music = model.music
        // Same inputs as islandSize: the line sits where the island made room for it.
        let layout = CompactIslandLayout(notchWidth: state.notchWidth, hasNotch: state.hasNotch,
                                         status: model.metrics)
        ZStack(alignment: .topLeading) {
            if let line, layout.hasStatus {
                CompactStatusView(line: line,
                                  fits: layout.statusWidth + 0.5 >= CompactStatusModel.contentWidth(line))
                    .frame(width: layout.statusWidth, height: islandH, alignment: .leading)
                    .offset(x: layout.statusX)
                    .id(identity(line, nil))
                    .transition(.opacity)
            } else if let music, layout.hasStatus {
                CompactVisualizerView(music: music,
                                      fits: layout.statusWidth + 0.5 >= CompactStatusModel.musicContentWidth(music))
                    .frame(width: layout.statusWidth, height: islandH, alignment: .leading)
                    .offset(x: layout.statusX)
                    .id(identity(nil, music))
                    .transition(.opacity)
            }
        }
        .frame(width: islandW, height: islandH, alignment: .topLeading)
        .clipShape(IslandShape(width: islandW, height: islandH, cornerRadius: cornerRadius, topRadius: topRadius))
        .animation(.easeInOut(duration: 0.25), value: identity(line, music))
        .allowsHitTesting(false)
    }
}

// MARK: - Compact sound visualizer ("▁▃▅▂ ♪ Title · Artist")

/// 12 bars of the audio spectrum, then "♪ Title · Artist", in the status line's slot while no
/// agent works and music plays. Same fonts and spacing as CompactStatusModel.musicContentWidth.
/// Clicks are handled by IslandWindowController (they open the music's pill).
struct CompactVisualizerView: View {
    let music: CompactMusicLine
    /// The island made room for the whole title (see CompactStatusView.fits).
    var fits = false

    /// The music pill's colour (the user's own if they picked one), else the source's.
    private var accent: Color {
        if let def = PillCatalog.definition(for: music.pillId) { return Color(hex: def.color) }
        switch music.source {
        case .music:   return Color(hex: "#FA2D48")
        case .spotify: return Color(hex: "#1DB954")
        case .tidal:   return Color(hex: "#E6E8EB")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            CompactVisualizerBars(accent: accent)
                .frame(width: CompactVisualizer.barsWidth, height: CompactVisualizer.maxBarHeight)
            Spacer().frame(width: CompactVisualizer.barsToText)
            HStack(spacing: CompactStatusModel.spacing) {
                Text(verbatim: "♪")
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                    .fixedSize()
                title
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: fits, vertical: false)
                    .layoutPriority(1)
            }
        }
    }

    private var title: Text {
        let headline = Text(verbatim: music.headline)
            .fontWeight(.semibold)
            .foregroundColor(Color(hex: "#F5F6F8"))
        guard !music.subline.isEmpty else { return headline }
        return headline + Text(verbatim: " · " + music.subline).foregroundColor(Color(hex: "#B0B5BE"))
    }
}

/// The bars, drawn in one Canvas. They redraw only when the model hands new levels (at most
/// 30 a second, only while capture runs): no timeline, so silent bands cost nothing and
/// show a static idle skyline.
struct CompactVisualizerBars: View {
    let accent: Color
    private var model: CompactStatusModel { CompactStatusModel.shared }

    var body: some View {
        let heights = CompactVisualizer.barHeights(model.levels)
        let range = CompactVisualizer.maxBarHeight - CompactVisualizer.minBarHeight
        Canvas { ctx, size in
            let step = CompactVisualizer.barWidth + CompactVisualizer.barGap
            for (i, h) in heights.enumerated() {
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2,
                                  width: CompactVisualizer.barWidth, height: h)
                // Taller bars glow a little brighter.
                let strength = range > 0 ? (h - CompactVisualizer.minBarHeight) / range : 0
                ctx.fill(Path(roundedRect: rect, cornerRadius: CompactVisualizer.barWidth / 2),
                         with: .color(accent.opacity(0.55 + 0.45 * strength)))
            }
        }
    }
}

/// The label under a hovered mini Mochi, right-aligned on the island's right edge so it
/// stays inside the panel. Drawn below the island, where the panel lets clicks through.
struct CompactMiniTooltipLayer: View {
    var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat
    private var model: CompactStatusModel { CompactStatusModel.shared }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let id = model.hoveredMiniId, let task = state.tasks.first(where: { $0.id == id }) {
                CompactMiniTooltip(label: model.miniLabel(for: task, state: state))
                    .id(id)
                    .transition(.opacity)
            }
        }
        .frame(width: max(0, islandW - 4), alignment: .topTrailing)
        .offset(y: islandH + 5)
        .animation(.easeInOut(duration: 0.15), value: model.hoveredMiniId)
        .allowsHitTesting(false)
    }
}

/// name · icon text [elapsed]. Same fonts and spacing as CompactStatusModel.contentWidth.
struct CompactStatusView: View {
    let line: CompactStatusLine
    /// The island made room for the whole line: the text keeps its full width (SwiftUI
    /// otherwise trimmed it by a character — "Thinkin…" — next to a wide gap).
    var fits = false

    private static let amber = Color(hex: "#F5A524")

    private var iconColor: Color {
        switch line.activity.kind {
        case .needsOK, .asks: Self.amber
        case .error:          Color(hex: "#F4505E")
        case .done:           Color(hex: "#34D399")
        case .thinking:       Color(hex: "#A78BFA")
        default:              Color(hex: "#8E939C")
        }
    }

    var body: some View {
        let kind = line.activity.kind
        let waits = kind.waitsOnUser
        HStack(spacing: CompactStatusModel.spacing) {
            Text(verbatim: line.pillName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(waits ? Self.amber : Color(hex: "#F5F6F8"))
                .lineLimit(1)
                .fixedSize()
            Text(verbatim: "·")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .fixedSize()
            Image(systemName: kind.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(iconColor)
                // The gentle pulse of a line waiting on the user (a symbol effect, no redraw loop).
                .symbolEffect(.pulse, options: .repeating, isActive: waits)
                .frame(width: CompactStatusModel.iconWidth)
            Text(verbatim: line.text)
                .font(.system(size: 11))
                .foregroundColor(waits ? Self.amber : Color(hex: "#B0B5BE"))
                .lineLimit(1)
                .truncationMode(kind == .edit || kind == .read ? .middle : .tail)
                .fixedSize(horizontal: fits, vertical: false)
                .layoutPriority(1)
            if let start = line.turnStartedAt {
                Spacer(minLength: CompactStatusModel.timeGap)
                // A TimelineView takes all the width it is offered: pin it to its text, or it
                // squeezes the activity text ("Thinkin…") while leaving a wide gap.
                CompactElapsedText(since: start)
                    .fixedSize()
            }
        }
    }
}

/// "2m": how long the turn has run. Ticks every 30 s, only while it is on screen (it is
/// mounted in the compact island only).
struct CompactElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 30)) { context in
            Text(verbatim: CompactStatus.elapsedLabel(since: since, now: context.date))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(Color(hex: "#6B7079"))
                .fixedSize()
        }
    }
}

/// "PyCharm · thinking" under a hovered mini Mochi.
struct CompactMiniTooltip: View {
    let label: (name: String, activity: CompactActivity?, word: String)

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: label.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(verbatim: "·")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#6B7079"))
            if let activity = label.activity {
                Image(systemName: activity.kind.symbolName)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(activity.kind.waitsOnUser ? Color(hex: "#F5A524") : Color(hex: "#8E939C"))
                Text(verbatim: CompactStatus.text(activity))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#B0B5BE"))
            } else {
                Text(verbatim: label.word)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#B0B5BE"))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
