import Foundation

@main
enum MochiFrameRateTests {
    static func main() {
        // Calm by default: 30 fps, unless the view always wants the full rate.
        var rate = MochiFrameRate()
        precondition(!rate.fast)
        precondition(MochiFrameRate.minimumInterval(fast: false, alwaysFull: false) == 1.0 / 30)
        precondition(MochiFrameRate.minimumInterval(fast: false, alwaysFull: true) == nil)
        precondition(MochiFrameRate.minimumInterval(fast: true, alwaysFull: false) == nil)

        // Calm frames change nothing.
        precondition(!rate.update(now: 10, fastMotion: false))
        precondition(!rate.fast)

        // A fast motion switches to the full rate, once.
        precondition(rate.update(now: 10.1, fastMotion: true))
        precondition(rate.fast)
        precondition(!rate.update(now: 10.11, fastMotion: true))

        // The full rate is held a little after the motion ends…
        precondition(!rate.update(now: 10.2, fastMotion: false))
        precondition(rate.fast)
        // …so a gap between chained tweens doesn't flip it.
        precondition(!rate.update(now: 10.3, fastMotion: true))
        precondition(!rate.update(now: 10.3 + MochiFrameRate.hold - 0.01, fastMotion: false))
        precondition(rate.fast)

        // Then it drops back to 30 fps, once.
        precondition(rate.update(now: 10.3 + MochiFrameRate.hold + 0.01, fastMotion: false))
        precondition(!rate.fast)
        precondition(!rate.update(now: 11, fastMotion: false))

        // An event kicks the full rate right away.
        var kicked = MochiFrameRate()
        precondition(kicked.kick(now: 5))
        precondition(kicked.fast)
        precondition(!kicked.kick(now: 5.1))
        precondition(kicked.update(now: 5.1 + MochiFrameRate.hold + 0.01, fastMotion: false))
        precondition(!kicked.fast)

        print("MochiFrameRateTests passed")
    }
}
