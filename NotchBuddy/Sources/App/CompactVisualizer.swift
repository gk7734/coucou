import Foundation
import CoreGraphics

// MARK: - CompactVisualizer
//
// The sound visualizer of the compact island: when no agent is at work or waiting on the
// user and music plays, the slot of the status line shows 12 bars of the audio spectrum and
// "♪ Title · Artist". Agents take the slot back as soon as one works or waits. Foundation +
// CoreGraphics only, so it can be tested without AppKit (see scripts/test-compact-visualizer.sh).

/// The music the visualizer is about: what its title line says, and the pill a click opens.
struct CompactMusicLine: Equatable, Sendable {
    /// The music app Coucou reads, nil for any other app making sound (a video, a call…).
    var source: NowPlayingSource?
    /// The title, or the app's name ("TIDAL", "Safari") when no title is known. Shortened.
    var headline: String
    /// The artist, shortened; empty when unknown.
    var subline: String
    /// The app making the sound when no music feed knows it (a click brings it forward).
    var appBundleId: String? = nil

    /// "Title · Artist", "Title", or "TIDAL".
    var text: String { subline.isEmpty ? headline : headline + " · " + subline }
    /// The music pill a click opens, nil for an app without one.
    var pillId: String? { source.map(CompactVisualizer.pillId(for:)) }
}

/// What the compact island's slot (right of the notch, or after Mochi on a bar) shows.
enum CompactSlot: Equatable, Sendable {
    case status(CompactStatusLine)
    case music(CompactMusicLine)
}

enum CompactVisualizer {

    // MARK: Geometry (the bars before the title)

    static let barCount = 12              // AudioSpectrum.bandCount
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2
    /// The bars' fixed width: 12 bars and the 11 gaps between them.
    static let barsWidth: CGFloat = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    /// Room between the bars and "♪".
    static let barsToText: CGFloat = 6
    static let maxBarHeight: CGFloat = 14
    static let minBarHeight: CGFloat = 2

    static let maxTitleLength = 32
    static let maxArtistLength = 24

    /// The bars redraw at most this often, whatever rate the capture writes at.
    static let frameInterval: TimeInterval = 1.0 / 30
    /// Bands all at or under this read as silence (or no capture yet): the idle pattern shows.
    static let silenceLevel: Float = 0.01

    /// A gentle static skyline (fractions of the bar range) for music playing while no
    /// levels come in (capture permission not granted yet): no animation, no cost.
    static let idleLevels: [CGFloat] = [0.30, 0.45, 0.35, 0.55, 0.40, 0.30,
                                        0.50, 0.35, 0.45, 0.30, 0.40, 0.25]

    // MARK: What the slot shows

    /// An agent session is at work or waits on the user, on any pill: the status line has
    /// priority. A finished or failed session (whose "Done" line lingers for minutes) is not.
    static func agentsBusy(books: [String: SessionBook]) -> Bool {
        books.values.contains { book in
            book.sessions.contains { $0.phase == .working || $0.phase.waitsOnUser }
        }
    }

    /// The slot's content, nil when it has nothing to show (the plain compact island):
    ///   1. agents busy → their status line;
    ///   2. music playing and the visualizer on → the visualizer;
    ///   3. else the status line if any ("Done", "Error").
    static func slot(line: CompactStatusLine?, agentsBusy: Bool,
                     music: CompactMusicLine?, visualizerEnabled: Bool) -> CompactSlot? {
        if agentsBusy, let line { return .status(line) }
        if visualizerEnabled, let music { return .music(music) }
        return line.map(CompactSlot.status)
    }

    /// Audio capture runs exactly while the visualizer is on screen: compact island, music slot.
    static func wantsCapture(compact: Bool, showsMusic: Bool) -> Bool {
        compact && showsMusic
    }

    // MARK: Title line

    /// The line for what plays, nil when nothing plays. A music feed (Music, Spotify, TIDAL)
    /// gives the title; otherwise any other app's sound that lasted (AudioSpectrum.isAudible)
    /// shows under that app's name — the visualizer works for any app, with or without a feed.
    static func musicLine(_ info: NowPlayingInfo?,
                          audibleApp: (bundleId: String, name: String)? = nil) -> CompactMusicLine? {
        guard let info, info.isPlaying else {
            guard let app = audibleApp else { return nil }
            let known = NowPlayingSource.allCases.first { $0.bundleId == app.bundleId }
            return CompactMusicLine(source: known,
                                    headline: CompactStatus.truncateTail(CompactStatus.oneLine(app.name), max: maxTitleLength),
                                    subline: "", appBundleId: app.bundleId.isEmpty ? nil : app.bundleId)
        }
        let title = CompactStatus.oneLine(info.title)
        let artist = CompactStatus.truncateTail(CompactStatus.oneLine(info.artist), max: maxArtistLength)
        if title.isEmpty {
            return CompactMusicLine(source: info.source, headline: info.source.displayName, subline: artist)
        }
        return CompactMusicLine(source: info.source,
                                headline: CompactStatus.truncateTail(title, max: maxTitleLength),
                                subline: artist)
    }

    /// The pill a click on the visualizer opens.
    static func pillId(for source: NowPlayingSource) -> String {
        switch source {
        case .music:   "integration_music"
        case .spotify: "integration_spotify"
        case .tidal:   "integration_tidal"
        }
    }

    // MARK: Bars

    static func isSilent(_ bands: [Float]) -> Bool {
        !bands.contains { $0 > silenceLevel }
    }

    /// The 12 bar heights for band levels 0…1: the idle pattern when they are all silent,
    /// else each level (clamped) between `minBarHeight` and `maxBarHeight`. Missing bands
    /// count as 0, extra ones are ignored.
    static func barHeights(_ bands: [Float], maxHeight: CGFloat = maxBarHeight,
                           minHeight: CGFloat = minBarHeight) -> [CGFloat] {
        let range = maxHeight - minHeight
        if isSilent(bands) {
            return idleLevels.map { minHeight + range * $0 }
        }
        return (0..<barCount).map { i in
            let level = i < bands.count ? bands[i] : 0
            let clamped = level.isFinite ? min(1, max(0, CGFloat(level))) : 0
            return minHeight + range * clamped
        }
    }

    /// Seconds to wait before showing new levels, so frames are at least `frameInterval`
    /// apart. 0: show them now.
    static func frameDelay(lastFrame: Date?, now: Date) -> TimeInterval {
        guard let lastFrame else { return 0 }
        return max(0, frameInterval - now.timeIntervalSince(lastFrame))
    }
}
