import Foundation
import Observation

// MARK: - Now playing and the audio spectrum (contract)
//
// Shared by the music feeds (Apple Music, Spotify, TIDAL), the system-audio analyser and the
// compact island's visualizer. Feeds publish into NowPlayingCenter; AudioSpectrum publishes
// band levels of what the Mac is playing. Both are main-actor @Observable singletons so the
// views redraw only when what they read changes.

/// A music app Coucou knows how to read and control.
enum NowPlayingSource: String, Equatable, Sendable, CaseIterable {
    case music, spotify, tidal

    var bundleId: String {
        switch self {
        case .music:   "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .tidal:   "com.tidal.desktop"
        }
    }

    var displayName: String {
        switch self {
        case .music:   "Music"
        case .spotify: "Spotify"
        case .tidal:   "TIDAL"
        }
    }
}

struct NowPlayingInfo: Equatable, Sendable {
    var source: NowPlayingSource
    var title: String
    var artist: String
    var isPlaying: Bool
    /// Remote artwork when the source offers one (Spotify oEmbed), nil otherwise.
    var artworkURL: URL? = nil
    var updatedAt: Date = Date()
}

/// Transport commands a feed can carry out for its source.
protocol NowPlayingControlling: AnyObject {
    @MainActor func playPause()
    @MainActor func next()
    @MainActor func previous()
}

@MainActor @Observable
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()
    private init() {}

    /// UserDefaults: show music automatically, without a pill in Active pills (default on).
    static let autoMusicKey = "autoMusicEnabled"
    static var autoMusicEnabled: Bool {
        UserDefaults.standard.object(forKey: autoMusicKey) as? Bool ?? true
    }

    /// The latest state of every source that reported, by source.
    private(set) var bySource: [NowPlayingSource: NowPlayingInfo] = [:]

    /// What the island shows: the playing source updated most recently, else nil.
    var current: NowPlayingInfo? {
        bySource.values.filter(\.isPlaying).max { $0.updatedAt < $1.updatedAt }
    }

    @ObservationIgnored private var controllers: [NowPlayingSource: NowPlayingControlling] = [:]

    /// Feeds call this whenever their source changes (nil: the source stopped or quit).
    func update(_ info: NowPlayingInfo?, for source: NowPlayingSource) {
        if let info { bySource[source] = info } else { bySource[source] = nil }
    }

    func register(_ controller: NowPlayingControlling, for source: NowPlayingSource) {
        controllers[source] = controller
    }

    func playPause() { current.flatMap { controllers[$0.source] }?.playPause() }
    func next()      { current.flatMap { controllers[$0.source] }?.next() }
    func previous()  { current.flatMap { controllers[$0.source] }?.previous() }
}

@MainActor @Observable
final class AudioSpectrum {
    static let shared = AudioSpectrum()
    private init() {}

    /// UserDefaults: show the visualizer (default on). Off: no audio capture at all.
    static let visualizerKey = "visualizerEnabled"
    static var visualizerEnabled: Bool {
        UserDefaults.standard.object(forKey: visualizerKey) as? Bool ?? true
    }

    static let bandCount = 12

    /// Band levels 0…1, low to high frequency, smoothed; all zero when silent or not capturing.
    var bands: [Float] = Array(repeating: 0, count: AudioSpectrum.bandCount)
    /// True while the default output device is running for some process (something plays).
    /// Comes from a Core Audio property listener, not from capture: free to keep on.
    var isAudible = false

    /// Capture runs only while someone wants the levels (the compact island showing the
    /// visualizer): 0 % CPU otherwise. Implemented by the audio capture feature.
    var isWanted = false {
        didSet { if isWanted != oldValue { wantedDidChange?(isWanted) } }
    }
    @ObservationIgnored var wantedDidChange: ((Bool) -> Void)?
}
