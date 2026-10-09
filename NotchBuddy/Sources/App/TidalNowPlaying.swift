#if !APPSTORE
import Foundation

// MARK: - TIDAL now playing (pure)
//
// TIDAL desktop (Electron, com.tidal.desktop) has no AppleScript dictionary and posts no
// distributed notifications, so TidalController reads its UI through Accessibility. This
// file holds everything that does not touch AX, so the tests can run it on plain values:
// the simplified tree model, picking the player bar and its nodes, the window title and
// play/pause label parsing, and the media key event payload.
//
// Shape of TIDAL's AX tree (TIDAL 2.x, read on a running copy):
//
//   AXWindow  title "Blue Ambience - Mrs. Green Apple, Asmi"   (the playing track)
//    … AXGroup ×5 (Electron's native views)
//      AXWebArea  title "<page> - TIDAL"
//       AXGroup #wimp
//        AXGroup …  ── AXLandmarkComplementary #sidebar, AXLandmarkMain #main,
//                      #playQueueSidebar: the heavy parts, never walked
//        AXGroup #footerPlayer
//         AXButton "Now Playing" (artwork)
//         AXGroup ._trackContent_…
//          AXLink d="Blue Ambience"              ← title
//          AXGroup ._artistRow_…
//           AXLink d="Mrs. Green Apple"          ← artists, joined with ", "
//           AXLink d="Asmi"
//          AXLink d="Mrs. Green Apple"           (where it plays from: not the artist)
//         AXGroup #playbackControlBar
//          AXCheckBox Shuffle
//          AXButton d="Previous"                 ← 1st button
//          AXGroup > AXButton d="Pause"|"Play"   ← 2nd button: "Pause" while playing
//          AXButton d="Next"                     ← 3rd button
//          AXCheckBox Repeat
//
// The buttons are picked by their order (language-proof); the play/pause label, which
// TIDAL localizes, only says whether it plays, and an unknown label falls back to whether
// the Mac is audible.

/// A simplified AX element: what the parser needs, with `id` pointing back to the live
/// element (its index in the reader's preorder walk).
struct TidalAXNode: Equatable, Sendable {
    var id: Int = 0
    var role: String = ""
    var subrole: String = ""
    var title: String = ""
    var description: String = ""
    var value: String = ""
    var domIdentifier: String = ""
    var domClasses: [String] = []
    var children: [TidalAXNode] = []

    /// The visible text: AXDescription for links and buttons, else AXTitle, else AXValue.
    var label: String {
        for text in [description, title, value] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// This node and every descendant, in document order.
    var preorder: [TidalAXNode] {
        var out: [TidalAXNode] = []
        func visit(_ node: TidalAXNode) {
            out.append(node)
            node.children.forEach(visit)
        }
        visit(self)
        return out
    }

    /// True when one of the DOM classes starts with `prefix` (TIDAL's CSS modules add a
    /// hash: `_trackContent_7b758a9`).
    func hasClass(prefix: String) -> Bool {
        domClasses.contains { $0.hasPrefix(prefix) }
    }

    /// First node in document order (self included) matching `predicate`.
    func first(where predicate: (TidalAXNode) -> Bool) -> TidalAXNode? {
        if predicate(self) { return self }
        for child in children {
            if let found = child.first(where: predicate) { return found }
        }
        return nil
    }
}

/// What the player bar says.
struct TidalPlayerReading: Equatable, Sendable {
    var title: String?
    var artist: String?
    /// nil: the play/pause label is not one we know.
    var isPlaying: Bool?
    /// Node ids of the transport buttons, nil when not found.
    var previousId: Int?
    var playPauseId: Int?
    var nextId: Int?
}

/// What Coucou publishes for TIDAL.
struct TidalTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
}

enum TidalNowPlaying {
    static let bundleId = "com.tidal.desktop"

    static let footerIdentifier = "footerPlayer"
    static let controlBarIdentifier = "playbackControlBar"

    /// DOM ids of the big parts of the page: the search for the player bar skips them.
    static let skippedIdentifiers: Set<String> = [
        "main", "sidebar", "playQueueSidebar", "mainHeader", "nowPlaying",
        "tidal-player-root", "onetrust-consent-sdk", "fb-root",
    ]
    static let skippedSubroles: Set<String> = ["AXLandmarkMain", "AXLandmarkComplementary", "AXLandmarkNavigation"]

    /// Limits of the search for the player bar (the real one is 9 levels and ~35 nodes in).
    static let searchMaxDepth = 16
    static let searchMaxNodes = 400
    /// Limits of the player bar snapshot (~60 nodes).
    static let footerMaxDepth = 8
    static let footerMaxNodes = 200

    // MARK: Searching the tree

    static func isFooterPlayer(domIdentifier: String) -> Bool {
        domIdentifier == footerIdentifier
    }

    /// False for the subtrees that cannot hold the player bar (and are expensive to walk).
    static func shouldDescend(role: String, subrole: String, domIdentifier: String) -> Bool {
        if skippedIdentifiers.contains(domIdentifier) { return false }
        if skippedSubroles.contains(subrole) { return false }
        // Leaves of the web content: nothing below them.
        if ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXCheckBox", "AXSlider",
            "AXPopUpButton", "AXMenuItem", "AXTextField"].contains(role) { return false }
        return true
    }

    /// The player bar inside a (simplified) window tree, walked as the reader walks the
    /// live one: depth-first, skipping what `shouldDescend` rejects, within the limits.
    static func findFooter(in root: TidalAXNode) -> TidalAXNode? {
        var visited = 0
        func search(_ node: TidalAXNode, depth: Int) -> TidalAXNode? {
            visited += 1
            if visited > searchMaxNodes { return nil }
            if isFooterPlayer(domIdentifier: node.domIdentifier) { return node }
            guard depth < searchMaxDepth,
                  shouldDescend(role: node.role, subrole: node.subrole, domIdentifier: node.domIdentifier)
            else { return nil }
            for child in node.children {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(root, depth: 0)
    }

    // MARK: Reading the player bar

    static func read(footer: TidalAXNode) -> TidalPlayerReading {
        var reading = TidalPlayerReading()

        // Title and artists.
        let track = footer.first { $0.hasClass(prefix: "_trackContent") } ?? footer
        let links = track.preorder.filter { $0.role == "AXLink" }
        if let artistRow = track.first(where: { $0.hasClass(prefix: "_artistRow") }) {
            let artistLinks = artistRow.preorder.filter { $0.role == "AXLink" }
            let artistIds = Set(artistLinks.map(\.id))
            reading.title = links.first { !artistIds.contains($0.id) }.map(\.label).flatMap(nonEmpty)
            reading.artist = nonEmpty(artistLinks.map(\.label).filter { !$0.isEmpty }.joined(separator: ", "))
        } else {
            // No class names: the first link is the title, the second the artist.
            reading.title = links.first.map(\.label).flatMap(nonEmpty)
            reading.artist = links.dropFirst().first.map(\.label).flatMap(nonEmpty)
        }

        // Transport buttons.
        let bar = footer.first { $0.domIdentifier == controlBarIdentifier } ?? footer
        let buttons = bar.preorder.filter { $0.role == "AXButton" && !isTrackButton($0, in: footer) }
        if bar.domIdentifier == controlBarIdentifier, buttons.count == 3 {
            reading.previousId = buttons[0].id
            reading.playPauseId = buttons[1].id
            reading.nextId = buttons[2].id
        } else {
            // Not the expected shape: fall back to the English labels.
            for button in buttons {
                switch button.label.lowercased() {
                case "previous": reading.previousId = reading.previousId ?? button.id
                case "next":     reading.nextId = reading.nextId ?? button.id
                default:
                    if playLabelMeansPlaying(button.label) != nil {
                        reading.playPauseId = reading.playPauseId ?? button.id
                    }
                }
            }
        }
        if let id = reading.playPauseId, let button = buttons.first(where: { $0.id == id }) {
            reading.isPlaying = playLabelMeansPlaying(button.label)
        }
        return reading
    }

    /// The artwork button ("Now Playing") is not a transport button.
    private static func isTrackButton(_ button: TidalAXNode, in footer: TidalAXNode) -> Bool {
        button.hasClass(prefix: "_artworkContainer")
    }

    /// The play/pause button's label is the action it would take: "Pause" while playing.
    /// true: playing, false: paused, nil: a label we do not know.
    static func playLabelMeansPlaying(_ label: String) -> Bool? {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pauseLabels.contains(key) { return true }
        if playLabels.contains(key) { return false }
        return nil
    }

    /// "Pause" in the languages TIDAL ships (the label shown while playing).
    static let pauseLabels: Set<String> = [
        "pause", "pausa", "pausar", "pauze", "pauzeren", "pausieren", "mettre en pause",
        "wstrzymaj", "pauza", "tauko", "일시정지", "일시 정지", "一時停止", "暂停", "暫停",
    ]
    /// "Play" in the languages TIDAL ships (the label shown while paused).
    static let playLabels: Set<String> = [
        "play", "lecture", "lire", "reproducir", "reproduzir", "riproduci", "wiedergabe",
        "abspielen", "afspelen", "spill av", "spela", "afspil", "odtwórz", "přehrát",
        "toista", "재생", "再生", "播放",
    ]

    // MARK: Window title

    /// "Title - Artist" (TIDAL's window title while a track is loaded) → (title, artist).
    /// Splits at the last " - ": titles carry dashes ("Song - Remastered") more often than
    /// artist names do. "TIDAL" or anything without the separator → nil.
    static func parseWindowTitle(_ windowTitle: String) -> (title: String, artist: String)? {
        let text = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.caseInsensitiveCompare("TIDAL") != .orderedSame,
              let range = text.range(of: " - ", options: .backwards) else { return nil }
        let title = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let artist = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !artist.isEmpty, artist != "TIDAL" else { return nil }
        return (title, artist)
    }

    // MARK: Resolving

    /// What to publish from the window title and the player bar (either may be missing).
    /// The player bar wins; the window title fills in. When the play state is unknown, the
    /// Mac being audible stands for it. nil: no track.
    static func resolve(windowTitle: String?, reading: TidalPlayerReading?, audible: Bool) -> TidalTrack? {
        let fromWindow = windowTitle.flatMap(parseWindowTitle)
        guard let title = reading?.title ?? fromWindow?.title else { return nil }
        let artist = reading?.artist ?? (fromWindow?.title == title ? fromWindow?.artist : nil) ?? ""
        let isPlaying = reading?.isPlaying ?? audible
        return TidalTrack(title: title, artist: artist, isPlaying: isPlaying)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Media keys (pure part)

/// A system-defined media key (IOKit's ev_keymap.h NX_KEYTYPE_*).
enum MediaKey: Int, Sendable, CaseIterable {
    case playPause = 16   // NX_KEYTYPE_PLAY
    case next = 17        // NX_KEYTYPE_NEXT
    case previous = 18    // NX_KEYTYPE_PREVIOUS

    /// NSEvent subtype of auxiliary control buttons (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    static let auxControlSubtype: Int16 = 8

    /// The `data1` of the NSEvent.otherEvent(.systemDefined, subtype 8): key code in the
    /// high 16 bits, then the key state (0xA down, 0xB up).
    func data1(down: Bool) -> Int {
        (rawValue << 16) | ((down ? 0xA : 0xB) << 8)
    }

    /// The modifier flags those events carry (the key state again, as the system posts them).
    func modifierFlagsRawValue(down: Bool) -> UInt {
        down ? 0xA00 : 0xB00
    }
}
#endif
