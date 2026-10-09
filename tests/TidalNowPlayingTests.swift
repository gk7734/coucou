import Foundation

// TidalNowPlaying (App/TidalNowPlaying.swift): finding TIDAL's player bar in a model of its
// AX tree (as read on a running TIDAL 2.x), title/artist/play state and transport buttons
// from it, window title parsing, what gets published, and the media key payload.

@main
enum TidalNowPlayingTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var nextId = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    /// A node with the next preorder id (build parents before children, as the reader does).
    static func n(_ role: String, sub: String = "", t: String = "", d: String = "", v: String = "",
                  dom: String = "", cls: [String] = [], _ children: [TidalAXNode] = []) -> TidalAXNode {
        TidalAXNode(role: role, subrole: sub, title: t, description: d, value: v,
                    domIdentifier: dom, domClasses: cls, children: children)
    }

    /// Renumbers ids in preorder, as the reader assigns them.
    static func numbered(_ node: TidalAXNode) -> TidalAXNode {
        var counter = 0
        func visit(_ node: TidalAXNode) -> TidalAXNode {
            var copy = node
            copy.id = counter
            counter += 1
            copy.children = node.children.map(visit)
            return copy
        }
        return visit(node)
    }

    static func footer(playLabel: String = "Pause", artists: [String] = ["Mrs. Green Apple", "Asmi"],
                       title: String = "Blue Ambience") -> TidalAXNode {
        var artistRow: [TidalAXNode] = []
        for (i, artist) in artists.enumerated() {
            artistRow.append(n("AXLink", d: artist, cls: ["_item_39605ae", "_link_6a45a19"],
                               [n("AXStaticText", v: artist)] + (i < artists.count - 1 ? [n("AXStaticText", v: ", ")] : [])))
        }
        return n("AXGroup", dom: "footerPlayer", cls: ["_player_8c80ae6", "_notFullscreen_60c5a14"], [
            n("AXButton", d: "Now Playing", cls: ["_artworkContainer_3cdbf46"], [n("AXGroup", cls: ["_artwork_633cf14"])]),
            n("AXGroup", cls: ["_trackContent_7b758a9"], [
                n("AXLink", d: title, [n("AXStaticText", v: title)]),
                n("AXGroup", cls: ["_artistRow_bd51a79"], artistRow),
                n("AXImage", cls: ["_icon_77f3f89", "_sourceTypeIcon_16ea49f"]),
                n("AXLink", d: "Mrs. Green Apple", [n("AXStaticText", v: "Mrs. Green Apple")]),
                n("AXCheckBox", sub: "AXSwitch", d: "Add to My Collection"),
                n("AXPopUpButton", d: "Show options"),
            ]),
            n("AXGroup", dom: "playbackControlBar", cls: ["_playbackControls_991c4b2"], [
                n("AXCheckBox", sub: "AXSwitch", d: "Shuffle", [n("AXImage")]),
                n("AXButton", d: "Previous", cls: ["_skipButton_abe89ff"], [n("AXImage")]),
                n("AXGroup", cls: ["_playbackButton_c00b950"], [n("AXButton", d: playLabel, [n("AXImage")])]),
                n("AXButton", d: "Next", cls: ["_skipButton_abe89ff"], [n("AXImage")]),
                n("AXCheckBox", sub: "AXSwitch", d: "Repeat", [n("AXImage")]),
            ]),
            n("AXSlider", d: "Progress bar", dom: "progressBar"),
            n("AXCheckBox", sub: "AXToggleButton", d: "Play queue"),
            n("AXButton", d: "Compact mode"),
        ])
    }

    /// The window as TIDAL exposes it, with a content area full of "Play" buttons.
    static func window(footer: TidalAXNode) -> TidalAXNode {
        let contentPlays = (0..<30).map { _ in n("AXButton", d: "Play", cls: ["_playButton_eb70a43"]) }
        return n("AXWindow", sub: "AXStandardWindow", t: "Blue Ambience - Mrs. Green Apple, Asmi", [
            n("AXGroup", t: "Blue Ambience - Mrs. Green Apple, Asmi", cls: ["RootView"], [
                n("AXGroup", cls: ["NonClientView"], [n("AXGroup", cls: ["NativeFrameViewMac"], [
                    n("AXGroup", cls: ["ClientView"], [n("AXGroup", cls: ["View"], [n("AXGroup", cls: ["View"], [
                        n("AXWebArea", t: "Mrs. Green Apple - TIDAL", [
                            n("AXGroup", dom: "fb-root"),
                            n("AXGroup", dom: "wimp", [
                                n("AXGroup", cls: ["_wrapper_356fec4"], [
                                    n("AXButton", t: "Skip to content"),
                                    n("AXButton", t: "Skip to player"),
                                    n("AXGroup", sub: "AXLandmarkComplementary", d: "Navigation sidebar", dom: "sidebar",
                                      [n("AXGroup", dom: "sidebar-content", contentPlays)]),
                                    n("AXGroup", sub: "AXApplicationGroup", dom: "mainHeader", [n("AXButton", d: "Next")]),
                                ]),
                                n("AXGroup", cls: ["_scrollSlot_9510e9e"], [
                                    n("AXGroup", sub: "AXLandmarkMain", dom: "main", contentPlays),
                                ]),
                                n("AXGroup", cls: ["_playQueueWrapper_cbf5aaa"], [
                                    n("AXGroup", sub: "AXLandmarkComplementary", dom: "playQueueSidebar"),
                                ]),
                                n("AXGroup", cls: ["_fullscreen_236d61b"], [n("AXGroup", dom: "nowPlaying")]),
                                footer,
                            ]),
                            n("AXGroup", dom: "tidal-player-root"),
                        ]),
                    ])])]),
                ])]),
            ]),
            n("AXButton", sub: "AXCloseButton"),
        ])
    }

    static func main() {
        print("finding the player bar")
        let win = numbered(window(footer: footer()))
        let found = TidalNowPlaying.findFooter(in: win)
        check("found #footerPlayer", found?.domIdentifier == "footerPlayer")
        var noFooter = window(footer: n("AXGroup", dom: "somethingElse"))
        noFooter = numbered(noFooter)
        check("no player bar: nil", TidalNowPlaying.findFooter(in: noFooter) == nil)
        check("skips #main", !TidalNowPlaying.shouldDescend(role: "AXGroup", subrole: "AXLandmarkMain", domIdentifier: "main"))
        check("skips the sidebar", !TidalNowPlaying.shouldDescend(role: "AXGroup", subrole: "", domIdentifier: "sidebar"))
        check("skips complementary landmarks",
              !TidalNowPlaying.shouldDescend(role: "AXGroup", subrole: "AXLandmarkComplementary", domIdentifier: ""))
        check("does not descend into buttons", !TidalNowPlaying.shouldDescend(role: "AXButton", subrole: "", domIdentifier: ""))
        check("descends into plain groups", TidalNowPlaying.shouldDescend(role: "AXGroup", subrole: "", domIdentifier: "wimp"))
        // Too deep: beyond the depth limit, not found.
        var deep = numbered(footer())
        for _ in 0...TidalNowPlaying.searchMaxDepth { deep = n("AXGroup", [deep]) }
        check("depth limit holds", TidalNowPlaying.findFooter(in: numbered(deep)) == nil)

        print("reading the player bar")
        guard let bar = found else { print("FAILED"); exit(1) }
        let r = TidalNowPlaying.read(footer: bar)
        check("title", r.title == "Blue Ambience")
        check("artists joined", r.artist == "Mrs. Green Apple, Asmi")
        check("Pause shown: playing", r.isPlaying == true)
        let byId = Dictionary(uniqueKeysWithValues: bar.preorder.map { ($0.id, $0) })
        check("previous button", r.previousId.flatMap { byId[$0] }?.label == "Previous")
        check("play/pause button", r.playPauseId.flatMap { byId[$0] }?.label == "Pause")
        check("next button", r.nextId.flatMap { byId[$0] }?.label == "Next")
        check("ids distinct from the content's Play buttons",
              r.playPauseId.map { id in win.preorder.filter { $0.id == id }.count == 1 } == true)

        let paused = TidalNowPlaying.read(footer: numbered(footer(playLabel: "Play")))
        check("Play shown: paused", paused.isPlaying == false)
        let single = TidalNowPlaying.read(footer: numbered(footer(artists: ["Daft Punk"], title: "One More Time")))
        check("single artist", single.artist == "Daft Punk" && single.title == "One More Time")
        let french = TidalNowPlaying.read(footer: numbered(footer(playLabel: "Lecture")))
        check("localized label (fr): paused, button still by position",
              french.isPlaying == false && french.playPauseId != nil && french.nextId != nil)
        let unknown = TidalNowPlaying.read(footer: numbered(footer(playLabel: "Abspelen?")))
        check("unknown label: state nil, buttons by position", unknown.isPlaying == nil && unknown.playPauseId != nil)

        // No class names (another TIDAL build): first link title, second artist; buttons by label.
        let bare = numbered(n("AXGroup", dom: "footerPlayer", [
            n("AXLink", d: "Song"), n("AXLink", d: "Band"),
            n("AXButton", d: "Previous"), n("AXButton", d: "Play"), n("AXButton", d: "Next"), n("AXButton", d: "Volume"),
        ]))
        let b = TidalNowPlaying.read(footer: bare)
        check("bare: title/artist from link order", b.title == "Song" && b.artist == "Band")
        check("bare: buttons by English label", b.previousId == 3 && b.playPauseId == 4 && b.nextId == 5)
        check("bare: paused", b.isPlaying == false)

        let empty = TidalNowPlaying.read(footer: numbered(n("AXGroup", dom: "footerPlayer")))
        check("empty player bar: nothing", empty == TidalPlayerReading())

        print("play/pause labels")
        check("Pause → playing", TidalNowPlaying.playLabelMeansPlaying("Pause") == true)
        check("play → paused (case)", TidalNowPlaying.playLabelMeansPlaying(" play ") == false)
        check("일시정지 → playing", TidalNowPlaying.playLabelMeansPlaying("일시정지") == true)
        check("재생 → paused", TidalNowPlaying.playLabelMeansPlaying("재생") == false)
        check("Wiedergabe → paused", TidalNowPlaying.playLabelMeansPlaying("Wiedergabe") == false)
        check("unknown → nil", TidalNowPlaying.playLabelMeansPlaying("Shuffle") == nil)
        check("labels do not overlap", TidalNowPlaying.pauseLabels.isDisjoint(with: TidalNowPlaying.playLabels))

        print("window title")
        let w = TidalNowPlaying.parseWindowTitle("Blue Ambience - Mrs. Green Apple, Asmi")
        check("title - artists", w?.title == "Blue Ambience" && w?.artist == "Mrs. Green Apple, Asmi")
        let dashed = TidalNowPlaying.parseWindowTitle("Let It Be - Remastered 2009 - The Beatles")
        check("dash in title: split at the last one",
              dashed?.title == "Let It Be - Remastered 2009" && dashed?.artist == "The Beatles")
        check("TIDAL alone: nil", TidalNowPlaying.parseWindowTitle("TIDAL") == nil)
        check("page title: nil", TidalNowPlaying.parseWindowTitle("Mrs. Green Apple - TIDAL") == nil)
        check("no separator: nil", TidalNowPlaying.parseWindowTitle("Blue Ambience") == nil)
        check("empty halves: nil", TidalNowPlaying.parseWindowTitle(" - Artist") == nil)
        check("hyphenated words are not separators", TidalNowPlaying.parseWindowTitle("Jay-Z") == nil)

        print("what gets published")
        let title = "Blue Ambience - Mrs. Green Apple, Asmi"
        check("player bar wins",
              TidalNowPlaying.resolve(windowTitle: "Other - Someone", reading: r, audible: false)
                == TidalTrack(title: "Blue Ambience", artist: "Mrs. Green Apple, Asmi", isPlaying: true))
        check("paused bar while audible stays paused",
              TidalNowPlaying.resolve(windowTitle: title, reading: paused, audible: true)?.isPlaying == false)
        check("unknown state: audible stands for it",
              TidalNowPlaying.resolve(windowTitle: nil, reading: unknown, audible: true)?.isPlaying == true
              && TidalNowPlaying.resolve(windowTitle: nil, reading: unknown, audible: false)?.isPlaying == false)
        check("no player bar: window title, audible",
              TidalNowPlaying.resolve(windowTitle: title, reading: nil, audible: true)
                == TidalTrack(title: "Blue Ambience", artist: "Mrs. Green Apple, Asmi", isPlaying: true))
        check("no player bar, silent: paused",
              TidalNowPlaying.resolve(windowTitle: title, reading: nil, audible: false)?.isPlaying == false)
        check("nothing loaded: nil", TidalNowPlaying.resolve(windowTitle: "TIDAL", reading: empty, audible: true) == nil)
        check("no window: nil", TidalNowPlaying.resolve(windowTitle: nil, reading: nil, audible: true) == nil)

        print("after a read that found nothing")
        let playing = TidalTrack(title: "Blue Ambience", artist: "Asmi", isPlaying: true)
        let stopped = TidalTrack(title: "Blue Ambience", artist: "Asmi", isPlaying: false)
        check("playing and still audible: kept",
              TidalNowPlaying.afterFailedRead(published: playing, audible: true) == playing)
        check("playing but the Mac went silent: paused",
              TidalNowPlaying.afterFailedRead(published: playing, audible: false) == stopped)
        check("paused stays paused", TidalNowPlaying.afterFailedRead(published: stopped, audible: true) == stopped)
        check("nothing published: nothing", TidalNowPlaying.afterFailedRead(published: nil, audible: false) == nil)
        var noArtist = r
        noArtist.artist = nil
        check("artist from the window title when it is the same track",
              TidalNowPlaying.resolve(windowTitle: title, reading: noArtist, audible: true)?.artist == "Mrs. Green Apple, Asmi")
        check("not from another track's title",
              TidalNowPlaying.resolve(windowTitle: "Other - Someone", reading: noArtist, audible: true)?.artist == "")

        print("media keys")
        check("play key code 16, down", MediaKey.playPause.data1(down: true) == 0x10_0A00)
        check("play key up", MediaKey.playPause.data1(down: false) == 0x10_0B00)
        check("next 17", MediaKey.next.data1(down: true) == (17 << 16) | 0x0A00)
        check("previous 18", MediaKey.previous.data1(down: false) == (18 << 16) | 0x0B00)
        check("flags", MediaKey.next.modifierFlagsRawValue(down: true) == 0xA00
              && MediaKey.next.modifierFlagsRawValue(down: false) == 0xB00)
        check("subtype 8", MediaKey.auxControlSubtype == 8)

        if failures > 0 {
            print("FAILED: \(failures)")
            exit(1)
        }
        print("TidalNowPlaying: all passed")
    }
}
