#if !APPSTORE
import Foundation

// MARK: - Music pill driver (GitHub build)
//
// Applies AutoMusicPill to the island: while NowPlayingCenter says something plays (any
// source: Apple Music, Spotify, TIDAL) and "Show music automatically" is on, that source's
// pill shows without being declared; it leaves AutoMusicPill.linger after the music stops.
// Event driven: it wakes on NowPlayingCenter changes, plus one timer while a pill lingers.

@MainActor
final class MusicPillDriver {
    static let shared = MusicPillDriver()
    private init() {}

    private var shown: AutoMusicPill.Shown?
    private var playingObserver: ChangeObserver<String?>?
    private var tidalObserver: ChangeObserver<String?>?
    private var dropWork: DispatchWorkItem?

    func start() {
        guard playingObserver == nil else { return }
        playingObserver = ChangeObserver({ Self.playingPillId() }, initial: true,
                                         removeDuplicates: ==) { [weak self] _ in
            self?.evaluate()
        }
        // The TIDAL feed only publishes into NowPlayingCenter: its pill takes the track's
        // name here (Apple Music and Spotify name theirs).
        tidalObserver = ChangeObserver({ NowPlayingCenter.shared.bySource[.tidal]?.title },
                                       initial: true, removeDuplicates: ==) { _ in
            Self.syncTidalName()
        }
    }

    /// "Show music automatically" was switched in Settings.
    func autoMusicChanged() {
        MusicController.shared.feedSettingChanged()
        SpotifyController.shared.feedSettingChanged()
        evaluate()
    }

    /// The pill of the source playing now, nil when nothing plays.
    private static func playingPillId() -> String? {
        NowPlayingCenter.shared.current.flatMap { AutoMusicPill.pillId(forSource: $0.source.rawValue) }
    }

    private func evaluate() {
        let previous = shown?.pillId
        shown = AutoMusicPill.next(shown: shown, playingPillId: Self.playingPillId(),
                                   enabled: NowPlayingCenter.autoMusicEnabled, now: Date())
        let id = shown?.pillId
        AppState.shared.setAutoMusicPill(id)
        // A pill that just came shows the track at once, not its catalog name.
        if let id, id != previous {
            switch id {
            case "integration_music":   MusicController.shared.syncTaskName()
            case "integration_spotify": SpotifyController.shared.syncTaskName()
            default:                    Self.syncTidalName()
            }
        }
        scheduleDrop()
    }

    /// One timer, only while a pill lingers: it leaves when the linger runs out.
    private func scheduleDrop() {
        dropWork?.cancel()
        dropWork = nil
        guard let date = AutoMusicPill.dropDate(of: shown) else { return }
        // Main queue: the closure is formed on the main actor and must run there.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        dropWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow) + 0.05,
                                      execute: work)
    }

    private static func syncTidalName() {
        let id = "integration_tidal"
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        let title = NowPlayingCenter.shared.bySource[.tidal]?.title ?? ""
        let name = title.isEmpty ? (PillCatalog.definition(for: id)?.name ?? "TIDAL") : title
        if state.tasks[idx].name != name { state.tasks[idx].name = name }
    }
}

// MARK: - Publishing

enum NowPlayingFeed {
    /// Publishes a source's state into NowPlayingCenter. Same track, same play state: keeps
    /// the first `updatedAt` (which source is current doesn't move for a new artwork) and
    /// skips a write that changes nothing.
    @MainActor
    static func publish(_ info: NowPlayingInfo?, for source: NowPlayingSource) {
        let center = NowPlayingCenter.shared
        let old = center.bySource[source]
        guard var info else {
            if old != nil { center.update(nil, for: source) }
            return
        }
        if let old, old.title == info.title, old.artist == info.artist, old.isPlaying == info.isPlaying {
            info.updatedAt = old.updatedAt
            if info == old { return }
        }
        center.update(info, for: source)
    }
}
#endif
