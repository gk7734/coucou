import AppKit
import CoreAudio
import Foundation

/// Feeds `AudioSpectrum` from what the Mac plays.
///
/// - `isAudible` comes from Core Audio property listeners only (no capture, no timer): the
///   default output device is running, and some process other than Coucou is sending it sound
///   (so Coucou's own sounds and its own capture never count). Free to keep on.
/// - `bands` come from a Core Audio process tap of the system output (Coucou excluded), started
///   only while `AudioSpectrum.isWanted` and the visualizer setting are both on, and torn down
///   as soon as either goes off. The IOProc copies samples into a lock-free ring; a 30 Hz timer
///   on a utility queue runs the FFT (SpectrumAnalyzer) and publishes on the main actor.
/// - The tap needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription).
///   Denied or failing: the bands stay at zero, `isAudible` keeps working.
/// - App Store build: the sandbox only lets an app read audio input with the microphone
///   entitlement, which Coucou doesn't want, so the tap is compiled out; `isAudible` stays.
///
/// Everything below runs on `queue` (a serial utility queue), except the IOProc, which runs on
/// the HAL's real-time thread. Every closure handed to Core Audio, Dispatch or NotificationCenter
/// is formed in nonisolated code (Swift 6 traps a main-actor closure run on another thread);
/// main-actor state is set through `DispatchQueue.main.async` + `MainActor.assumeIsolated`.
final class SystemAudioCapture: @unchecked Sendable {
    static let shared = SystemAudioCapture()

    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.system-audio", qos: .utility)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // MARK: State (confined to `queue`)

    private var enabled = false
    private var wanted = false
    private var bandCount = 12   // AudioSpectrum.bandCount, read on the main actor at start
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var publishedAudible: Bool?
    private var publishedApps: [String] = []
    /// A sound must last this long before it counts: alert sounds and clicks don't show the
    /// visualizer, music and videos do. Silence counts at once.
    private static let audibleDelay: TimeInterval = 2
    private var pendingAudible: DispatchWorkItem?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var deviceRunningListener: AudioObjectPropertyListenerBlock?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processRunningListener: AudioObjectPropertyListenerBlock?
    /// Process objects (other than Coucou) whose "running output" property we listen to.
    private var watchedProcesses: Set<AudioObjectID> = []
    #if !APPSTORE
    private var session: TapSession?
    /// A capture was tried for the current "wanted" stretch: a failure (permission denied) is
    /// not retried on every UserDefaults change, only the next time the visualizer is wanted.
    private var captureTried = false
    #endif

    private init() {}

    // MARK: Entry points

    /// Called once at launch (AppDelegate).
    @MainActor static func start() {
        let capture = shared
        AudioSpectrum.shared.wantedDidChange = { wanted in capture.setWanted(wanted) }
        capture.begin(wanted: AudioSpectrum.shared.isWanted, bandCount: AudioSpectrum.bandCount)
    }

    private func begin(wanted: Bool, bandCount: Int) {
        // Settings toggle the visualizer through UserDefaults; follow it from any thread.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.refresh() }
        }
        queue.async { [self] in
            self.bandCount = bandCount
            self.wanted = wanted
            refresh()
        }
    }

    func setWanted(_ wanted: Bool) {
        queue.async { [self] in
            self.wanted = wanted
            refresh()
        }
    }

    private static func settingEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "visualizerEnabled") as? Bool ?? true
    }

    /// Brings the listeners and the capture in line with the setting and `wanted`.
    private func refresh() {
        let shouldEnable = Self.settingEnabled()
        if shouldEnable != enabled {
            enabled = shouldEnable
            if enabled { installListeners() } else { removeListeners() }
        }
        #if !APPSTORE
        let shouldCapture = enabled && wanted
        if shouldCapture, session == nil, !captureTried {
            captureTried = true
            session = TapSession.start(excluding: ownProcessObject(), bandCount: bandCount, queue: queue)
        } else if !shouldCapture {
            captureTried = false
            session?.stop()
            session = nil
        }
        #endif
    }

    // MARK: isAudible (listeners only)

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private func installListeners() {
        let defaultDevice: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.followDefaultDevice()
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, defaultDevice) == noErr {
            defaultDeviceListener = defaultDevice
        }
        let processList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncProcessListeners()
            self?.updateAudible()
        }
        address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, processList) == noErr {
            processListListener = processList
        }
        processRunningListener = { [weak self] _, _ in self?.updateAudible() }
        deviceRunningListener = { [weak self] _, _ in self?.updateAudible() }
        followDefaultDevice()
        syncProcessListeners()
        updateAudible()
    }

    private func removeListeners() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        if let block = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, queue, block)
        }
        address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if let block = processListListener {
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, queue, block)
        }
        watchDevice(AudioObjectID(kAudioObjectUnknown))
        if let block = processRunningListener {
            address = Self.address(kAudioProcessPropertyIsRunningOutput)
            for process in watchedProcesses {
                AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            }
        }
        watchedProcesses = []
        defaultDeviceListener = nil
        processListListener = nil
        processRunningListener = nil
        deviceRunningListener = nil
        publishAudible(false, apps: [])
    }

    private func followDefaultDevice() {
        var device = AudioObjectID(kAudioObjectUnknown)
        _ = Self.read(Self.systemObject, kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        watchDevice(device)
        updateAudible()
    }

    /// Moves the "is running somewhere" listener to `device` (unknown: no device watched).
    private func watchDevice(_ device: AudioObjectID) {
        guard device != outputDevice else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if outputDevice != kAudioObjectUnknown, let block = deviceRunningListener {
            AudioObjectRemovePropertyListenerBlock(outputDevice, &address, queue, block)
        }
        outputDevice = device
        if device != kAudioObjectUnknown, let block = deviceRunningListener {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        }
    }

    /// Listens to "running output" on every audio process but Coucou, as they come and go.
    private func syncProcessListeners() {
        guard let block = processRunningListener else { return }
        let current = Set(otherProcesses())
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for gone in watchedProcesses.subtracting(current) {
            AudioObjectRemovePropertyListenerBlock(gone, &address, queue, block)
        }
        for new in current.subtracting(watchedProcesses) {
            AudioObjectAddPropertyListenerBlock(new, &address, queue, block)
        }
        watchedProcesses = current
    }

    private func updateAudible() {
        guard enabled else { return }
        var running: UInt32 = 0
        let deviceRunning = outputDevice != kAudioObjectUnknown
            && Self.read(outputDevice, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running)
            && running != 0
        guard deviceRunning, let apps = appsPlaying() else {
            publishAudible(false, apps: [])
            return
        }
        // The process list couldn't be read: trust the device alone (no app names).
        publishAudible(true, apps: apps)
    }

    /// Bundle ids of the processes other than Coucou sending sound out ("" for one without a
    /// bundle id); nil when no other process plays. If the process list can't be read, [] —
    /// "something plays, but we don't know what".
    private func appsPlaying() -> [String]? {
        guard let processes = Self.processObjects() else { return [] }
        var apps: [String] = []
        for process in processes {
            var output: UInt32 = 0
            let processPID = pid(of: process)
            guard Self.read(process, kAudioProcessPropertyIsRunningOutput, into: &output), output != 0,
                  processPID != ownPID else { continue }
            let id = Self.owningAppBundleId(pid: processPID, bundleId: Self.bundleId(of: process)) ?? ""
            if !apps.contains(id) { apps.append(id) }
        }
        return apps.isEmpty ? nil : apps
    }

    /// The app the user knows for a sound-making process: helpers play the sound for many
    /// apps (TIDAL's "TIDALPlayer", browsers' and Electron apps' helpers). The process itself
    /// when it is a regular app, else the nearest regular app above it, else a running
    /// regular app whose bundle id prefixes the helper's ("com.tidal.desktop.player").
    private static func owningAppBundleId(pid: pid_t, bundleId: String?) -> String? {
        let chain = pid > 0 ? ProcessAncestry.pidChain(from: pid) : []
        if let id = ProcessAncestry.regularAppBundleIds(pids: chain, limit: 1).first,
           !id.hasPrefix("fr.louisraille.") { return id }
        guard let bundleId else { return nil }
        let regular = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        return regular.filter { bundleId.hasPrefix($0 + ".") }.max { $0.count < $1.count } ?? bundleId
    }

    private static func bundleId(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    private func otherProcesses() -> [AudioObjectID] {
        (Self.processObjects() ?? []).filter { pid(of: $0) != ownPID }
    }

    private func ownProcessObject() -> AudioObjectID? {
        (Self.processObjects() ?? []).first { pid(of: $0) == ownPID }
    }

    private func pid(of process: AudioObjectID) -> pid_t {
        var pid: pid_t = -1
        _ = Self.read(process, kAudioProcessPropertyPID, into: &pid)
        return pid
    }

    /// Publishes silence at once, sound only once it has lasted `audibleDelay` (re-checked
    /// then), with the apps making it.
    private func publishAudible(_ audible: Bool, apps: [String]) {
        guard audible else {
            pendingAudible?.cancel(); pendingAudible = nil
            send(false, apps: [])
            return
        }
        if publishedAudible == true {
            send(true, apps: apps)   // already audible: just follow which apps play
            return
        }
        guard pendingAudible == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingAudible = nil
            // Still playing after the delay?
            if self.enabled, self.deviceIsRunning(), let apps = self.appsPlaying() {
                self.send(true, apps: apps)
            }
        }
        pendingAudible = item
        queue.asyncAfter(deadline: .now() + Self.audibleDelay, execute: item)
    }

    private func deviceIsRunning() -> Bool {
        var running: UInt32 = 0
        return outputDevice != kAudioObjectUnknown
            && Self.read(outputDevice, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running)
            && running != 0
    }

    private func send(_ audible: Bool, apps: [String]) {
        guard audible != publishedAudible || apps != publishedApps else { return }
        publishedAudible = audible
        publishedApps = apps
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AudioSpectrum.shared.isAudible = audible
                AudioSpectrum.shared.audibleBundleIds = apps
            }
        }
    }

    // MARK: Core Audio helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property; false on any error.
    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    static func processObjects() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !objects.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else { return nil }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

#if !APPSTORE
// MARK: - The process tap

/// One capture: a private process tap of the system output (minus Coucou), a private aggregate
/// device holding it, an IOProc writing into a SampleRing, and a 30 Hz analysis timer. Lives on
/// the capture queue; `stop()` tears everything down (no IOProc outlives it).
private final class TapSession: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private let ring = SampleRing()
    private let analyzer: SpectrumAnalyzer
    private var published: [Float]
    private var lastWritten = 0

    private init(sampleRate: Float, bandCount: Int) {
        analyzer = SpectrumAnalyzer(fftSize: 2048, bandCount: bandCount, sampleRate: sampleRate)
        published = [Float](repeating: 0, count: bandCount)
    }

    /// Starts a capture, or returns nil (permission denied, API failure: the bands stay at zero).
    static func start(excluding ownProcess: AudioObjectID?, bandCount: Int, queue: DispatchQueue) -> TapSession? {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.name = "Coucou visualizer"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            return nil
        }
        var format = AudioStreamBasicDescription()
        let formatRead = SystemAudioCapture.read(tap, kAudioTapPropertyFormat, into: &format)
        guard formatRead, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mSampleRate > 0 else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let session = TapSession(sampleRate: Float(format.mSampleRate), bandCount: bandCount)
        session.tapID = tap
        // A tap-only aggregate first (it never starts the output hardware); if the HAL refuses
        // to run it, the same with the output device as its clock.
        if !session.startAggregate(tapUID: description.uuid.uuidString, withOutputDevice: false),
           !session.startAggregate(tapUID: description.uuid.uuidString, withOutputDevice: true) {
            session.stop()
            return nil
        }
        session.startTimer(on: queue)
        return session
    }

    private func startAggregate(tapUID: String, withOutputDevice: Bool) -> Bool {
        var dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Coucou visualizer",
            kAudioAggregateDeviceUIDKey: "fr.louisraille.NotchBuddy.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        if withOutputDevice {
            guard let outputUID = Self.defaultOutputUID() else { return false }
            dictionary[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dictionary[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate) == noErr,
              aggregate != kAudioObjectUnknown else { return false }
        aggregateID = aggregate
        guard let block = Self.makeIOBlock(ring: ring),
              AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil, block) == noErr, procID != nil,
              AudioDeviceStart(aggregate, procID) == noErr else {
            stopAggregate()
            return false
        }
        return true
    }

    /// The IOProc, on the HAL's real-time thread: no allocation, no lock, no Swift concurrency,
    /// no Objective-C. It only mixes the first input buffer into the ring.
    private static func makeIOBlock(ring: SampleRing) -> AudioDeviceIOBlock? {
        unowned(unsafe) let target = ring   // the session outlives the IOProc (stop() destroys it first)
        return { _, inputData, _, _, _ in
            let list = inputData.pointee
            guard list.mNumberBuffers > 0 else { return }
            let buffer = list.mBuffers
            guard let data = buffer.mData else { return }
            let channels = Int(max(buffer.mNumberChannels, 1))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            target.write(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
        }
    }

    private func startTimer(on queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33), leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// One analysis frame (~30 Hz, capture queue).
    private func tick() {
        let written = ring.copyLatest(analyzer.fftSize, into: analyzer.input)
        if written != lastWritten, written >= analyzer.fftSize {
            analyzer.process()
        } else {
            analyzer.decay()   // no new audio (paused IO, permission prompt): bars fall
        }
        lastWritten = written
        #if DEBUG
        debugLogFrame()
        #endif
        guard AudioSpectrumMath.changedEnough(analyzer.levels, since: published) else { return }
        published = analyzer.levels
        Self.publish(published)
    }

    #if DEBUG
    private var debugFrame = 0
    /// `defaults write fr.louisraille.NotchBuddy debugLogSpectrum -bool YES`: twice a second,
    /// the raw band dB and the published levels go to /tmp/coucou-spectrum.log (tuning aid).
    private func debugLogFrame() {
        debugFrame += 1
        guard debugFrame % 15 == 0, UserDefaults.standard.bool(forKey: "debugLogSpectrum") else { return }
        let db = analyzer.decibels.map { String(format: "%6.1f", $0) }.joined(separator: " ")
        let lv = analyzer.levels.map { String(format: "%.2f", $0) }.joined(separator: " ")
        let line = "dB [\(db)]  levels [\(lv)]\n"
        let url = URL(fileURLWithPath: "/tmp/coucou-spectrum.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    #endif

    private static func publish(_ bands: [Float]) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AudioSpectrum.shared.bands = bands }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        stopAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if published.contains(where: { $0 != 0 }) {
            published = [Float](repeating: 0, count: published.count)
            Self.publish(published)
        }
    }

    private func stopAggregate() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)          // synchronous: the IOProc is done after this
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard SystemAudioCapture.read(AudioObjectID(kAudioObjectSystemObject),
                                      kAudioHardwarePropertyDefaultOutputDevice, into: &device),
              device != kAudioObjectUnknown else { return nil }
        var address = SystemAudioCapture.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
#endif
