import Foundation

// AutoMusicPill (App/AutoMusicPill.swift): the music pill that shows on its own while music
// plays, which one, and when it leaves.

@main @MainActor
enum AutoMusicPillTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let music   = "integration_music"
    static let spotify = "integration_spotify"
    static let tidal   = "integration_tidal"
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Plays changes through `next`, as MusicPillDriver does; returns the pill after each.
    static func play(_ events: [(seconds: TimeInterval, playing: String?)], enabled: Bool = true,
                     start: AutoMusicPill.Shown? = nil) -> [String?] {
        var shown = start
        var trail: [String?] = []
        for e in events {
            shown = AutoMusicPill.next(shown: shown, playingPillId: e.playing, enabled: enabled, now: at(e.seconds))
            trail.append(shown?.pillId)
        }
        return trail
    }

    static func transition(_ old: String?, _ new: String?, kept: Set<String> = []) -> [String?] {
        let r = AutoMusicPill.transition(from: old, to: new, kept: kept)
        return [r.add, r.remove]
    }

    static func main() {
        print("AutoMusicPill.pillId")
        check("Apple Music", AutoMusicPill.pillId(forSource: "music") == music)
        check("Spotify", AutoMusicPill.pillId(forSource: "spotify") == spotify)
        check("TIDAL", AutoMusicPill.pillId(forSource: "tidal") == tidal)
        check("an unknown source has none", AutoMusicPill.pillId(forSource: "deezer") == nil)
        check("pillIds lists the three", AutoMusicPill.pillIds == [music, spotify, tidal])

        print("AutoMusicPill.next")
        check("nothing plays, nothing shown", play([(0, nil)]) == [nil])
        check("music plays → its pill shows", play([(0, music)]) == [music])
        check("off in Settings → never shows", play([(0, music)], enabled: false) == [nil])
        check("turned off while shown → leaves at once",
              AutoMusicPill.next(shown: .init(pillId: music, stoppedAt: nil), playingPillId: music,
                                 enabled: false, now: t0) == nil)
        check("paused → stays during the linger",
              play([(0, music), (200, nil), (229, nil)]) == [music, music, music])
        check("the linger counts from the stop, not from when the track began",
              play([(0, music), (240, nil)]) == [music, music])
        check("paused → leaves once the linger ran out",
              play([(0, music), (200, nil), (230, nil)]) == [music, music, nil])
        check("plays again during the linger → stays, and the linger restarts",
              play([(0, music), (10, nil), (35, music), (36, nil), (60, nil), (66, nil)])
                == [music, music, music, music, music, nil])
        check("another source starts → its pill replaces the first at once",
              play([(0, music), (5, spotify)]) == [music, spotify])
        check("a source starts during another's linger → replaces it",
              play([(0, spotify), (5, nil), (10, tidal)]) == [spotify, spotify, tidal])
        check("later changes while nothing plays don't move the stop",
              play([(0, music), (10, nil), (20, nil), (40, nil)]) == [music, music, music, nil])
        let stopped = AutoMusicPill.next(shown: .init(pillId: spotify, stoppedAt: nil),
                                         playingPillId: nil, enabled: true, now: at(10))
        check("stopping records when", stopped == .init(pillId: spotify, stoppedAt: at(10)))
        check("custom linger", AutoMusicPill.next(shown: stopped, playingPillId: nil, enabled: true,
                                                  now: at(15), linger: 5) == nil)

        print("AutoMusicPill.dropDate")
        check("none shown → no drop", AutoMusicPill.dropDate(of: nil) == nil)
        check("playing → no drop", AutoMusicPill.dropDate(of: .init(pillId: music, stoppedAt: nil)) == nil)
        check("stopped → linger after the stop",
              AutoMusicPill.dropDate(of: .init(pillId: music, stoppedAt: at(10))) == at(40))

        print("AutoMusicPill.transition")
        check("no change → nothing", transition(music, music) == [nil, nil])
        check("nothing → nothing", transition(nil, nil) == [nil, nil])
        check("appears → add it", transition(nil, music) == [music, nil])
        check("leaves → remove it", transition(music, nil) == [nil, music])
        check("a declared pill leaving the auto role stays", transition(music, nil, kept: [music]) == [nil, nil])
        check("switch of source → add the new, remove the old", transition(music, spotify) == [spotify, music])
        check("switch from a declared pill → it stays", transition(spotify, tidal, kept: [spotify]) == [tidal, nil])

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All AutoMusicPill tests passed.")
    }
}
