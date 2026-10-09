#if !APPSTORE
import AppKit
import ApplicationServices

// MARK: - TIDAL controller
//
// Feeds NowPlayingCenter with what TIDAL desktop plays, read from its UI through
// Accessibility (TIDAL has no AppleScript and posts nothing), and carries out play/pause,
// next and previous by pressing TIDAL's own buttons, else with the media keys.
// The parsing lives in TidalNowPlaying.swift; this file only talks to AX and schedules.
//
// Cost: nothing while TIDAL is not running (NSWorkspace launch/terminate notifications),
// nothing without the Accessibility permission (Coucou never prompts for it here), and
// while TIDAL runs, one read every 2 s only while the Mac is audible
// (AudioSpectrum.isAudible), plus one read when the sound stops (to see "paused") and one
// after a control. A read is the window title plus a snapshot of the player bar
// (~60 elements), a few milliseconds; the player bar is found once and cached.
//
// AX calls can block on a hung app: they all run on `TidalAXReader`'s queue with a short
// messaging timeout, and results are published on the main actor.

@MainActor
final class TidalController: NowPlayingControlling {
    static let shared = TidalController()

    /// Reads at most this often while the Mac is audible.
    static let pollInterval: TimeInterval = 2
    /// The read made once the sound stops, after TIDAL updated its button.
    static let silenceReadDelay: TimeInterval = 0.4
    /// The read made after a control, once TIDAL reacted.
    static let controlReadDelay: TimeInterval = 0.5

    private let reader = TidalAXReader()
    private var pid: pid_t?
    private var started = false
    private var tokens: [NSObjectProtocol] = []
    private var audibleObserver: ChangeObserver<Bool>?
    private var scheduledRead: DispatchWorkItem?
    private var readInFlight = false
    private var readAgainAfterFlight = false
    private var published: TidalTrack?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NowPlayingCenter.shared.register(self, for: .tidal)

        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                         object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == TidalNowPlaying.bundleId else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { TidalController.shared.tidalLaunched(pid: pid) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == TidalNowPlaying.bundleId else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { TidalController.shared.tidalTerminated(pid: pid) }
        })
        audibleObserver = ChangeObserver({ AudioSpectrum.shared.isAudible }, removeDuplicates: true) { audible in
            TidalController.shared.audibleChanged(audible)
        }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: TidalNowPlaying.bundleId).first {
            tidalLaunched(pid: app.processIdentifier)
        }
    }

    // MARK: NowPlayingControlling

    func playPause() { control(.playPause) }
    func next()      { control(.next) }
    func previous()  { control(.previous) }

    private func control(_ key: MediaKey) {
        guard let pid, AXIsProcessTrusted() else { return }
        reader.press(key, pid: pid, completion: Self.pressCompletion())
    }

    /// Made outside the main actor: the reader calls it on its queue.
    private nonisolated static func pressCompletion() -> @Sendable (MediaKey, Bool) -> Void {
        { key, pressed in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TidalController.shared.pressFinished(key, pressed: pressed) }
            }
        }
    }

    private func pressFinished(_ key: MediaKey, pressed: Bool) {
        // TIDAL's button was not found or did not take the press: the media key goes to the
        // app macOS routes it to, which is TIDAL when it played last.
        if !pressed { MediaKeyPoster.post(key) }
        scheduleRead(after: Self.controlReadDelay)
    }

    // MARK: Lifecycle

    private func tidalLaunched(pid: pid_t) {
        self.pid = pid
        reader.forget()
        // TIDAL needs a moment to build its window: the first read waits a little.
        scheduleRead(after: 1)
    }

    private func tidalTerminated(pid: pid_t) {
        guard self.pid == pid else { return }
        self.pid = nil
        cancelScheduledRead()
        reader.forget()
        publish(nil)
    }

    private func audibleChanged(_ audible: Bool) {
        guard pid != nil else { return }
        if audible {
            // Read now; the read schedules the next one while it stays audible.
            scheduleRead(after: 0)
        } else {
            // Once more, to catch "paused".
            scheduleRead(after: Self.silenceReadDelay)
        }
    }

    // MARK: Reading

    /// Replaces any pending read with one in `delay` seconds.
    private func scheduleRead(after delay: TimeInterval) {
        cancelScheduledRead()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { TidalController.shared.readNow() }
        }
        scheduledRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScheduledRead() {
        scheduledRead?.cancel()
        scheduledRead = nil
    }

    private func readNow() {
        scheduledRead = nil
        guard let pid else { return }
        guard AXIsProcessTrusted() else {
            // No permission: publish nothing; the UI explains how to grant it.
            publish(nil)
            return
        }
        guard !readInFlight else {
            readAgainAfterFlight = true
            return
        }
        readInFlight = true
        reader.read(pid: pid, completion: Self.readCompletion())
    }

    /// Made outside the main actor: the reader calls it on its queue.
    private nonisolated static func readCompletion() -> @Sendable (TidalAXSnapshot?) -> Void {
        { snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TidalController.shared.readFinished(snapshot) }
            }
        }
    }

    private func readFinished(_ snapshot: TidalAXSnapshot?) {
        readInFlight = false
        guard pid != nil else { return }
        let audible = AudioSpectrum.shared.isAudible
        if let snapshot {
            publish(TidalNowPlaying.resolve(windowTitle: snapshot.windowTitle,
                                            reading: snapshot.reading, audible: audible))
        }
        // A failed read (TIDAL busy, no window) keeps what was published; the next one retries.
        if readAgainAfterFlight {
            readAgainAfterFlight = false
            scheduleRead(after: 0)
        } else if audible, scheduledRead == nil {
            scheduleRead(after: Self.pollInterval)
        }
    }

    /// Publishes only changes: NowPlayingCenter picks the source updated last, so an
    /// unchanged TIDAL must not look fresher on every read.
    private func publish(_ track: TidalTrack?) {
        guard track != published else { return }
        published = track
        guard let track else {
            NowPlayingCenter.shared.update(nil, for: .tidal)
            return
        }
        NowPlayingCenter.shared.update(NowPlayingInfo(source: .tidal, title: track.title,
                                                      artist: track.artist, isPlaying: track.isPlaying),
                                       for: .tidal)
    }
}

// MARK: - Reader

/// What one read found: the window title and the player bar, either may be missing.
struct TidalAXSnapshot: Sendable {
    var windowTitle: String?
    var reading: TidalPlayerReading?
}

/// Talks to TIDAL's AX tree, only on its own serial queue (AX calls block while the app
/// answers). Keeps the player bar element and the elements of the last snapshot so the
/// controls can press them.
final class TidalAXReader: @unchecked Sendable {
    /// Per-call messaging timeout: a hung TIDAL costs at most this per AX call.
    static let messagingTimeout: Float = 0.25

    private let queue = DispatchQueue(label: "fr.louisraille.coucou.tidal-ax", qos: .utility)

    // Only touched on `queue`.
    private var pid: pid_t?
    private var footer: AXUIElement?
    private var elements: [AXUIElement] = []
    private var lastReading: TidalPlayerReading?
    private var askedForWebTree = false

    /// Drops what was cached (TIDAL launched or quit).
    func forget() {
        queue.async { self.reset(pid: nil) }
    }

    func read(pid: pid_t, completion: @escaping @Sendable (TidalAXSnapshot?) -> Void) {
        queue.async { completion(self.snapshot(pid: pid)) }
    }

    /// Presses TIDAL's own button for `key`; `pressed` false when it could not.
    func press(_ key: MediaKey, pid: pid_t, completion: @escaping @Sendable (MediaKey, Bool) -> Void) {
        queue.async {
            var pressed = self.pressCached(key, pid: pid)
            if !pressed {
                // The cached elements went stale (TIDAL re-rendered): read again, retry once.
                _ = self.snapshot(pid: pid)
                pressed = self.pressCached(key, pid: pid)
            }
            completion(key, pressed)
        }
    }

    // MARK: On the queue

    private func reset(pid: pid_t?) {
        self.pid = pid
        footer = nil
        elements = []
        lastReading = nil
        askedForWebTree = false
    }

    private func pressCached(_ key: MediaKey, pid: pid_t) -> Bool {
        guard self.pid == pid, let reading = lastReading else { return false }
        let id: Int? = switch key {
        case .playPause: reading.playPauseId
        case .next:      reading.nextId
        case .previous:  reading.previousId
        }
        guard let id, elements.indices.contains(id) else { return false }
        let element = elements[id]
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func snapshot(pid: pid_t) -> TidalAXSnapshot? {
        if self.pid != pid { reset(pid: pid) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        // TIDAL busy (timeout) or no window (closed to the Dock while it plays): nothing to
        // read, what was published stays. The controls then go through the media keys.
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement],
              let main = copy(app, kAXMainWindowAttribute).map({ $0 as! AXUIElement }) ?? windows.first
        else {
            footer = nil; elements = []; lastReading = nil
            return nil
        }
        let windowTitle = copy(main, kAXTitleAttribute) as? String

        // The cached player bar, else search the windows for it.
        var tree = footer.flatMap { snapshotTree($0) }
        if tree == nil || !TidalNowPlaying.isFooterPlayer(domIdentifier: tree!.root.domIdentifier) {
            footer = nil
            for window in [main] + windows.filter({ !CFEqual($0, main) }) where footer == nil {
                footer = findFooter(from: window)
            }
            tree = footer.flatMap { snapshotTree($0) }
        }
        guard let tree else {
            elements = []; lastReading = nil
            askForWebTreeIfNeeded(app)
            return TidalAXSnapshot(windowTitle: windowTitle, reading: nil)
        }
        elements = tree.elements
        let reading = TidalNowPlaying.read(footer: tree.root)
        lastReading = reading
        return TidalAXSnapshot(windowTitle: windowTitle, reading: reading)
    }

    /// Chromium builds the web content's AX tree only once an assistive app shows up;
    /// Electron's documented switch for other assistive apps is AXManualAccessibility.
    /// Set once per TIDAL launch when the player bar cannot be found; the next read sees
    /// the tree. It changes nothing in what TIDAL plays.
    private func askForWebTreeIfNeeded(_ app: AXUIElement) {
        guard !askedForWebTree else { return }
        askedForWebTree = true
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Depth-first search for #footerPlayer, skipping the page's big parts (same rules and
    /// limits as TidalNowPlaying.findFooter, which the tests run on a model of the tree).
    private func findFooter(from window: AXUIElement) -> AXUIElement? {
        var visited = 0
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            visited += 1
            guard visited <= TidalNowPlaying.searchMaxNodes else { return nil }
            let a = attributes(element, Self.searchAttributes)
            let domId = a[2] as? String ?? ""
            if TidalNowPlaying.isFooterPlayer(domIdentifier: domId) { return element }
            guard depth < TidalNowPlaying.searchMaxDepth,
                  TidalNowPlaying.shouldDescend(role: a[0] as? String ?? "", subrole: a[1] as? String ?? "",
                                                domIdentifier: domId)
            else { return nil }
            for child in (a[3] as? [AXUIElement]) ?? [] {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(window, depth: 0)
    }

    /// The player bar as a TidalAXNode tree, with its live elements indexed by node id.
    private func snapshotTree(_ root: AXUIElement) -> (root: TidalAXNode, elements: [AXUIElement])? {
        var elements: [AXUIElement] = []
        func build(_ element: AXUIElement, depth: Int) -> TidalAXNode? {
            guard elements.count < TidalNowPlaying.footerMaxNodes else { return nil }
            let a = attributes(element, Self.nodeAttributes)
            guard let role = a[0] as? String else { return nil }   // gone or timed out
            var node = TidalAXNode(id: elements.count, role: role,
                                   subrole: a[1] as? String ?? "",
                                   title: a[2] as? String ?? "",
                                   description: a[3] as? String ?? "",
                                   value: a[4] as? String ?? "",
                                   domIdentifier: a[5] as? String ?? "",
                                   domClasses: a[6] as? [String] ?? [])
            elements.append(element)
            if depth < TidalNowPlaying.footerMaxDepth {
                node.children = ((a[7] as? [AXUIElement]) ?? []).compactMap { build($0, depth: depth + 1) }
            }
            return node
        }
        guard let node = build(root, depth: 0) else { return nil }
        return (node, elements)
    }

    // MARK: AX helpers

    private static let searchAttributes: [String] = [kAXRoleAttribute, kAXSubroleAttribute, "AXDOMIdentifier",
                                                     kAXChildrenAttribute]
    private static let nodeAttributes: [String] = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                                   kAXDescriptionAttribute, kAXValueAttribute, "AXDOMIdentifier",
                                                   "AXDOMClassList", kAXChildrenAttribute]

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Several attributes in one round trip; a missing one comes back as nil.
    private func attributes(_ element: AXUIElement, _ names: [String]) -> [AnyObject?] {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(),
                                                     &values) == .success,
              let array = values as [AnyObject]?, array.count == names.count
        else { return Array(repeating: nil, count: names.count) }
        // Errors come back as AXValue(kAXValueAXErrorType) in their slot.
        return array.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }
}

// MARK: - Media keys

/// Posts system-defined media key events, as the keyboard's play/next/previous keys do.
/// macOS routes them to the app that played last, not necessarily TIDAL: TidalController
/// uses them only when it cannot press TIDAL's own buttons. Needs Accessibility.
@MainActor
enum MediaKeyPoster {
    static func post(_ key: MediaKey) {
        for down in [true, false] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: key.modifierFlagsRawValue(down: down)),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: MediaKey.auxControlSubtype,
                                           data1: key.data1(down: down), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
#endif
