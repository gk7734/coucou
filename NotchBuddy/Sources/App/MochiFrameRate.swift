import Foundation

/// How often an animated Mochi in the island redraws.
///
/// The compact Mochi is ~20 pt tall and the mini Mochis 12–22 pt: at 30 fps their calm
/// motions (looking around, blinking, breathing, the badge dots, particles, dancing) move
/// well under a point per frame, so redrawing them at the display rate (120 Hz on
/// ProMotion screens) costs CPU for nothing. Fast motions — a squash, hop, roll, shake,
/// emote, the greeting wave — get the full rate while they run, plus a short hold so a
/// chain of tweens doesn't flip the rate back and forth. The expanded island (Mochi up to
/// 66 pt) and a dragged Mochi always run at the full rate.
struct MochiFrameRate: Equatable {
    /// Cadence of a calm small Mochi.
    static let calmInterval: Double = 1.0 / 30
    /// How long the full rate is kept after the last fast motion.
    static let hold: Double = 0.3

    /// True while the full rate is wanted.
    private(set) var fast = false
    private var fastUntil: Double = 0

    /// The TimelineView's minimumInterval: nil = the display's rate.
    static func minimumInterval(fast: Bool, alwaysFull: Bool) -> Double? {
        fast || alwaysFull ? nil : calmInterval
    }

    /// Feeds one frame. Returns true when `fast` changed (the view then updates its schedule).
    mutating func update(now: Double, fastMotion: Bool) -> Bool {
        if fastMotion { fastUntil = now + Self.hold }
        let wanted = now < fastUntil
        guard wanted != fast else { return false }
        fast = wanted
        return true
    }

    /// An event is about to move Mochi fast (an emote, a slap…): full rate right away,
    /// without waiting for the next calm frame to notice it.
    mutating func kick(now: Double) -> Bool {
        update(now: now, fastMotion: true)
    }
}
