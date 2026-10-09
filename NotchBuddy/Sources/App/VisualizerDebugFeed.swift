#if DEBUG
import AppKit

// MARK: - VisualizerDebugFeed (Debug builds only)
//
// Fakes a song and a spectrum to preview the compact island's sound visualizer without the
// music feeds or the audio capture. Driven by the UserDefaults key `debugFakeMusic`:
//   spotify | music | tidal   that source plays a fake song; the bars move while they show
//   tidal-untitled            TIDAL plays with no title known ("♪ TIDAL")
//   idle                      Spotify plays but no levels come in (the static idle bars)
//   (absent or anything else) off
// Set it from the menu bar icon (Debug: fake music) or, live, from a terminal:
//   defaults write fr.louisraille.NotchBuddy debugFakeMusic spotify
//   defaults delete fr.louisraille.NotchBuddy debugFakeMusic
// The fake bands are written only while AudioSpectrum.isWanted, like the real capture.

@MainActor
final class VisualizerDebugFeed: NSObject {
    static let shared = VisualizerDebugFeed()
    static let key = "debugFakeMusic"

    private var keyObserver: DefaultsKeyObserver?
    private var wantedObserver: ChangeObserver<Bool>?
    private var timer: Timer?
    private var fakedSource: NowPlayingSource?
    private var animates = false
    private var phase: Double = 0
    private var menuItems: [(mode: String?, item: NSMenuItem)] = []

    func start() {
        guard keyObserver == nil else { return }
        keyObserver = DefaultsKeyObserver(key: Self.key) { [weak self] in self?.apply() }
        wantedObserver = ChangeObserver({ AudioSpectrum.shared.isWanted }, initial: true,
                                        removeDuplicates: true) { [weak self] _ in
            self?.updateTimer()
        }
        apply()
    }

    private static func info(for mode: String?) -> NowPlayingInfo? {
        switch mode {
        case "spotify":
            NowPlayingInfo(source: .spotify, title: "Harder, Better, Faster, Stronger",
                           artist: "Daft Punk", isPlaying: true)
        case "music":
            NowPlayingInfo(source: .music, title: "Clair de lune", artist: "Claude Debussy", isPlaying: true)
        case "tidal":
            NowPlayingInfo(source: .tidal, title: "Midnight City", artist: "M83", isPlaying: true)
        case "tidal-untitled":
            NowPlayingInfo(source: .tidal, title: "", artist: "", isPlaying: true)
        case "idle":
            NowPlayingInfo(source: .spotify, title: "Weightless", artist: "Marconi Union", isPlaying: true)
        default:
            nil
        }
    }

    private func apply() {
        let mode = UserDefaults.standard.string(forKey: Self.key)
        if let source = fakedSource {
            NowPlayingCenter.shared.update(nil, for: source)
            fakedSource = nil
        }
        if let info = Self.info(for: mode) {
            NowPlayingCenter.shared.update(info, for: info.source)
            fakedSource = info.source
        }
        animates = fakedSource != nil && mode != "idle"
        updateTimer()
        for (itemMode, item) in menuItems { item.state = itemMode == (fakedSource == nil ? nil : mode) ? .on : .off }
    }

    // MARK: Fake bands

    private func updateTimer() {
        let run = animates && AudioSpectrum.shared.isWanted
        if run, timer == nil {
            // Runs on the main run loop; the block only re-enters the main actor there.
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated { VisualizerDebugFeed.shared.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run, let t = timer {
            t.invalidate()
            timer = nil
            AudioSpectrum.shared.bands = Array(repeating: 0, count: AudioSpectrum.bandCount)
        }
    }

    private func tick() {
        phase += 1.0 / 30
        let beat = 0.55 + 0.45 * max(0, cos(phase * 2 * .pi * 2))   // 120 bpm
        AudioSpectrum.shared.bands = (0..<AudioSpectrum.bandCount).map { i in
            let d = Double(i)
            let tilt = 1.0 - d / 16                                     // more bass than treble
            let wave = abs(sin(phase * (1.6 + 0.23 * d) + d * 0.9))
            return Float(min(1, max(0, (0.12 + 0.8 * wave * tilt) * beat)))
        }
    }

    // MARK: Menu

    /// "Debug: fake music" in the menu bar icon's menu.
    func addMenuItems(to menu: NSMenu) {
        let sub = NSMenu(title: "Debug: fake music")
        let choices: [(String, String?)] = [
            ("Off", nil), ("Spotify", "spotify"), ("Apple Music", "music"), ("TIDAL", "tidal"),
            ("TIDAL, no title", "tidal-untitled"), ("Spotify, no levels (idle bars)", "idle"),
        ]
        for (title, mode) in choices {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            sub.addItem(item)
            menuItems.append((mode, item))
        }
        let parent = NSMenuItem(title: "Debug: fake music", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        apply()
    }

    @objc private func pick(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String {
            UserDefaults.standard.set(mode, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        // The key observer applies it (a write of the same value doesn't call it: apply now).
        apply()
    }
}
#endif
