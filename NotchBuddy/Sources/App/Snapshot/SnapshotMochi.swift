#if DEBUG
import AppKit
import SwiftUI

/// Mochi in a snapshot run: one frame of BotEngine with the state already settled (colour,
/// tint, tilt, look, badge), drawn at BotEngine.frozenDrawTime. No timeline, no tween, no
/// random blink: the same pixels on every run. Stands in for BotCanvasView and
/// MiniBotCanvasView while SnapshotMode.isActive.
struct SnapshotMochi: View {
    let state: BotState
    /// The pill's colour for an integration pill's Mochi; nil paints the state's colour.
    var bodyHex: String?
    var particleOverhang: CGFloat = 0
    var mini = false

    var body: some View {
        Canvas { context, size in
            let engine = BotEngine()
            engine.isMini = mini
            engine.particleOverhang = particleOverhang
            engine.bodyColor = bodyHex.flatMap(cgColorFromHex)
            let cfg = BotStates[state]!
            engine.state = state
            engine.cfg = cfg
            let rgb = Self.rgb(cfg.color)
            engine.col = rgb
            engine.colT = rgb
            engine.tint = cfg.tint
            engine.tilt = cfg.tilt
            if let look = cfg.look {
                engine.yaw = look.x * 0.55
                engine.pitch = look.y * 0.5
            }
            engine.draw(context: context, size: size)
            if let badge = cfg.badge {
                engine.badge = badge
                engine.badgeS = 1
            }
            engine.drawHandsAndExtras(context: context, size: size)
        }
    }

    private static func rgb(_ color: CGColor) -> (CGFloat, CGFloat, CGFloat) {
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            ?? color
        let comps = c.components ?? [1, 1, 1]
        if comps.count >= 3 { return (comps[0], comps[1], comps[2]) }
        return (comps[0], comps[0], comps[0])
    }
}
#endif
