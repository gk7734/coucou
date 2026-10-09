import Foundation
import CoreGraphics

// CompactVisualizer (App/CompactVisualizer.swift): what the compact island's slot shows
// (agents first, then the music, then a lingering "Done"), when audio capture is wanted, the
// title line, the bar heights (levels and the idle pattern), the 30 Hz frame limit, and the
// slot's geometry through CompactIslandLayout.

@main @MainActor
enum CompactVisualizerTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func session(_ id: String, _ phase: SessionPhase) -> AgentSession {
        AgentSession(id: id, agent: "claude", projectName: "p", cwd: "", phase: phase,
                     startedAt: t0, lastEventAt: t0)
    }

    static func books(_ phases: SessionPhase...) -> [String: SessionBook] {
        var out: [String: SessionBook] = [:]
        for (i, p) in phases.enumerated() { out["pill\(i)"] = SessionBook(sessions: [session("s\(i)", p)]) }
        return out
    }

    static func line(_ kind: CompactActivityKind) -> CompactStatusLine {
        CompactStatusLine(pillId: "integration_claude", pillName: "Claude Code",
                          activity: CompactActivity(kind: kind, detail: ""), turnStartedAt: nil)
    }

    static func info(_ source: NowPlayingSource = .spotify, _ title: String = "One More Time",
                     _ artist: String = "Daft Punk", playing: Bool = true) -> NowPlayingInfo {
        NowPlayingInfo(source: source, title: title, artist: artist, isPlaying: playing)
    }

    static func main() {
        let music = CompactVisualizer.musicLine(info())!

        print("agents busy")
        check("no sessions: not busy", !CompactVisualizer.agentsBusy(books: [:]))
        check("idle, finished, error: not busy", !CompactVisualizer.agentsBusy(books: books(.idle, .finished, .error)))
        check("working: busy", CompactVisualizer.agentsBusy(books: books(.finished, .working)))
        check("waiting for an OK: busy", CompactVisualizer.agentsBusy(books: books(.waitingApproval)))
        check("waiting for an answer: busy", CompactVisualizer.agentsBusy(books: books(.waitingAnswer)))
        check("a working session behind an errored lead: busy",
              CompactVisualizer.agentsBusy(books: ["a": SessionBook(sessions: [session("1", .error), session("2", .working)])]))

        print("what the slot shows")
        check("nothing at all: nil",
              CompactVisualizer.slot(line: nil, agentsBusy: false, music: nil, visualizerEnabled: true) == nil)
        check("music, no agent: the visualizer",
              CompactVisualizer.slot(line: nil, agentsBusy: false, music: music, visualizerEnabled: true) == .music(music))
        check("music while an agent works: the status line",
              CompactVisualizer.slot(line: line(.edit), agentsBusy: true, music: music, visualizerEnabled: true) == .status(line(.edit)))
        check("music while an agent waits on the user: the status line",
              CompactVisualizer.slot(line: line(.needsOK), agentsBusy: true, music: music, visualizerEnabled: true) == .status(line(.needsOK)))
        check("music over a lingering Done",
              CompactVisualizer.slot(line: line(.done), agentsBusy: false, music: music, visualizerEnabled: true) == .music(music))
        check("music over a lingering Error",
              CompactVisualizer.slot(line: line(.error), agentsBusy: false, music: music, visualizerEnabled: true) == .music(music))
        check("a focused Done while another pill works stays the status line",
              CompactVisualizer.slot(line: line(.done), agentsBusy: true, music: music, visualizerEnabled: true) == .status(line(.done)))
        check("visualizer off: the Done line",
              CompactVisualizer.slot(line: line(.done), agentsBusy: false, music: music, visualizerEnabled: false) == .status(line(.done)))
        check("visualizer off, no line: nil",
              CompactVisualizer.slot(line: nil, agentsBusy: false, music: music, visualizerEnabled: false) == nil)
        check("no music: the Done line",
              CompactVisualizer.slot(line: line(.done), agentsBusy: false, music: nil, visualizerEnabled: true) == .status(line(.done)))

        print("capture wanted")
        check("compact + visualizer", CompactVisualizer.wantsCapture(compact: true, showsMusic: true))
        check("compact, status line", !CompactVisualizer.wantsCapture(compact: true, showsMusic: false))
        check("not compact (hidden or expanded)", !CompactVisualizer.wantsCapture(compact: false, showsMusic: true))

        print("title line")
        check("paused: no line", CompactVisualizer.musicLine(info(playing: false)) == nil)
        check("nothing: no line", CompactVisualizer.musicLine(nil) == nil)
        let safari = CompactVisualizer.musicLine(nil, audibleApp: (bundleId: "com.apple.Safari", name: "Safari"))
        check("any app's sound: its name, no pill", safari?.text == "Safari" && safari?.pillId == nil
              && safari?.appBundleId == "com.apple.Safari")
        let tidalApp = CompactVisualizer.musicLine(nil, audibleApp: (bundleId: "com.tidal.desktop", name: "TIDAL"))
        check("TIDAL heard without its feed: TIDAL's pill", tidalApp?.text == "TIDAL" && tidalApp?.pillId == "integration_tidal")
        check("a feed's track wins over the app's name",
              CompactVisualizer.musicLine(info(.spotify, "Song", "Band"), audibleApp: (bundleId: "com.apple.Safari", name: "Safari"))?.text == "Song · Band")
        check("title · artist", music.text == "One More Time · Daft Punk")
        check("title only", CompactVisualizer.musicLine(info(.music, "Clair de lune", ""))?.text == "Clair de lune")
        check("no title: the source's name", CompactVisualizer.musicLine(info(.tidal, "", ""))?.text == "TIDAL")
        check("no title, an artist: source · artist", CompactVisualizer.musicLine(info(.tidal, "  ", "M83"))?.text == "TIDAL · M83")
        check("whitespace collapsed", CompactVisualizer.musicLine(info(.spotify, "A\n  B", " C  D "))?.text == "A B · C D")
        let long = CompactVisualizer.musicLine(info(.spotify, String(repeating: "x", count: 80), String(repeating: "y", count: 80)))
        check("long title shortened",
              long?.headline.count == CompactVisualizer.maxTitleLength && long?.headline.hasSuffix("…") == true)
        check("long artist shortened",
              long?.subline.count == CompactVisualizer.maxArtistLength && long?.subline.hasSuffix("…") == true)
        check("pills", CompactVisualizer.pillId(for: .music) == "integration_music"
              && CompactVisualizer.pillId(for: .spotify) == "integration_spotify"
              && CompactVisualizer.pillId(for: .tidal) == "integration_tidal")
        check("line's pill", music.pillId == "integration_spotify")

        print("bars")
        let minH = CompactVisualizer.minBarHeight, maxH = CompactVisualizer.maxBarHeight
        let idle = CompactVisualizer.barHeights(Array(repeating: 0, count: 12))
        check("12 bars", idle.count == 12 && CompactVisualizer.idleLevels.count == 12)
        check("silence: the idle pattern", idle == CompactVisualizer.idleLevels.map { minH + (maxH - minH) * $0 })
        check("idle pattern stays low", idle.allSatisfy { $0 > minH && $0 < minH + (maxH - minH) * 0.6 })
        check("near-silence is silence", CompactVisualizer.barHeights(Array(repeating: 0.005, count: 12)) == idle)
        check("no bands at all: idle", CompactVisualizer.barHeights([]) == idle)
        let levels: [Float] = [0, 0.5, 1, 2, -1, .nan, 0.25, 0, 0, 0, 0, 0.75]
        let h = CompactVisualizer.barHeights(levels)
        check("0 → min", h[0] == minH)
        check("0.5 → middle", abs(h[1] - (minH + (maxH - minH) / 2)) < 0.001)
        check("1 → max", h[2] == maxH)
        check("over 1 clamped", h[3] == maxH)
        check("negative clamped", h[4] == minH)
        check("NaN → min", h[5] == minH)
        check("0.75", abs(h[11] - (minH + (maxH - minH) * 0.75)) < 0.001)
        let short = CompactVisualizer.barHeights([1])
        check("missing bands count as 0", short.count == 12 && short[0] == maxH && short[1] == minH)
        check("extra bands ignored", CompactVisualizer.barHeights(Array(repeating: 1, count: 20)).count == 12)
        check("bars width: 12 × 2 + 11 × 2", CompactVisualizer.barsWidth == 46)

        print("frame limit (30 Hz)")
        check("first frame now", CompactVisualizer.frameDelay(lastFrame: nil, now: t0) == 0)
        check("right after one: wait the rest",
              abs(CompactVisualizer.frameDelay(lastFrame: t0, now: t0.addingTimeInterval(0.01)) - (1.0 / 30 - 0.01)) < 0.0001)
        check("a frame later: now", CompactVisualizer.frameDelay(lastFrame: t0, now: t0.addingTimeInterval(0.05)) == 0)

        print("geometry (the visualizer uses the status line's slot)")
        let width: CGFloat = 46 + 6 + 120
        let notch = CompactIslandLayout(notchWidth: 185, hasNotch: true,
                                        status: CompactStatusMetrics(statusWidth: width, hasMinis: false))
        check("notch: right ear grows to fit", notch.width == 80 + 185 + 10 + width + 14)
        check("notch: slot after the notch", notch.statusX == 80 + 185 + 10 && notch.statusWidth == width)
        check("notch: clicks on the bars land in the slot", notch.statusContains(x: notch.statusX + 1))
        let bar = CompactIslandLayout(notchWidth: 185, hasNotch: false,
                                      status: CompactStatusMetrics(statusWidth: width, hasMinis: true))
        check("bar: slot after Mochi, room for it all", bar.statusX == 58 && bar.statusWidth >= width && bar.offsetX == 0)

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All CompactVisualizer tests passed.")
    }
}
