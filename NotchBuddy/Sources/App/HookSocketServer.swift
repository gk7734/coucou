import Foundation
import Darwin

// MARK: - HookSocketServer (Foundation-only, testable)
//
// The transport under HookServer: a Unix domain socket that hook relays connect to, one JSON
// line per connection. Event-driven, on one serial background queue (no thread per client):
//
// - Accept: a read source on the non-blocking listening socket accepts every pending client.
//   Each client is checked (same UID via getpeereid), and its process chain capture is queued
//   at once (`captureAncestry`: a fire-and-forget relay exits right after writing, and a gone
//   process has no parent left to walk from). Captures run one at a time on their own queue,
//   while clients are accepted and read; the message waits for its capture. (Run side by side,
//   the sysctl walks contend in the kernel: ~10× the CPU in scripts/bench-hook-socket.sh.)
// - At most `maxConnections` are open, held ones included. At the ceiling the server stops
//   accepting until a slot frees: new clients wait in the listen backlog (their bytes too,
//   the relay is never blocked), and connect() fails at once when the backlog is full.
// - Read: non-blocking, bytes accumulate until a newline, EOF or an error. A relay has usually
//   written its line before it is accepted, so the first read happens right away and most
//   connections never need a read source; the others get one. A line longer than `maxPayload`
//   is rejected; a client silent for `idleTimeout` is cut off (the old SO_RCVTIMEO).
// - Hand-off: a read message goes to `onMessage` on one serial delivery queue, in the order the
//   reads finished (a session's PreToolUse before its PostToolUse). By then the fd is back in
//   blocking mode and belongs to the receiver, which must end it with `closeClient(_:)` — at
//   once for plain events, when the user decides for held requests.
// - Empty or rejected connections are answered `{"ok":true}` and closed here.
// - accept() failures follow AcceptRecovery (PendingRequestQueue.swift): transient errors are
//   retried, descriptor shortages back off, a broken listening socket is closed and created
//   again after a growing delay. A socket path longer than sun_path is given up on.
//
// Every handler here runs on `ioQueue` (ancestry on `ancestryQueue`), formed in nonisolated
// code: nothing touches the main actor (the receiver hops there itself).

final class HookSocketServer: @unchecked Sendable {

    struct Configuration: Sendable {
        var socketPath: String
        var maxPayload = 1_048_576            // 1 MB per message
        var idleTimeout: TimeInterval = 5     // per connection, reset by every read
        var maxConnections = 32               // open client connections, held ones included
        /// Clients waiting to be accepted (kern.ipc.somaxconn caps it, 128 by default). A burst
        /// of relays can connect faster than the queue wakes up; past this connect() is refused.
        var backlog: Int32 = 128
        var queueLabel = "fr.louisraille.NotchBuddy.hook-socket"
    }

    /// A fully read hook message. `data` is the line without its newline (or what arrived
    /// before EOF / the idle timeout). The receiver owns `fd` from now on.
    struct Message: Sendable {
        let fd: Int32
        let data: Data
        /// The peer's process chain, captured at accept (see `captureAncestry`).
        let pids: [pid_t]
    }

    let configuration: Configuration

    private let ioQueue: DispatchQueue          // accept, reads, timers: all state below
    private let deliveryQueue: DispatchQueue    // onMessage, serial, completion order
    private let ancestryQueue: DispatchQueue    // captureAncestry, serial

    private let connectionLock = NSLock()
    private var connectionCount = 0             // guarded by connectionLock
    private var waitingForSlot = false          // guarded by connectionLock: accept paused at the ceiling

    // ioQueue only
    private var captureAncestry: @Sendable (Int32) -> [pid_t] = { _ in [] }
    private var onMessage: @Sendable (Message) -> Void = { _ in }
    private var listenerSource: (any DispatchSourceRead)?
    private var clients: [Int32: Client] = [:]
    private var acceptFailures = 0
    private var acceptedAny = false
    private var listenAttempt = 0
    private var pausedAtCeiling = false         // listenerSource suspended until a slot frees
    private var stopped = false
    private var nextSequence: UInt64 = 0        // given to each message as its read finishes
    private var nextToDeliver: UInt64 = 0
    private var readyToDeliver: [UInt64: Message] = [:]
    private let scratch: UnsafeMutableRawPointer
    private static let scratchSize = 65_536

    /// One connection while it is being read. Confined to ioQueue.
    private final class Client: @unchecked Sendable {
        let fd: Int32
        var pids: [pid_t]?                      // nil until captureAncestry returns
        var waitsForAncestry = false            // read over, hand-off waits for pids
        var source: (any DispatchSourceRead)?
        var timer: (any DispatchSourceTimer)?
        var buffer = Data()
        var lastActivity: UInt64
        var outcome: Outcome?

        init(fd: Int32, now: UInt64) {
            self.fd = fd
            self.lastActivity = now
        }
    }

    private enum Outcome {
        case deliver(sequence: UInt64, data: Data)
        case reject          // nothing read, or longer than maxPayload
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        ioQueue = DispatchQueue(label: configuration.queueLabel + ".io", qos: .userInitiated)
        deliveryQueue = DispatchQueue(label: configuration.queueLabel + ".delivery", qos: .userInitiated)
        ancestryQueue = DispatchQueue(label: configuration.queueLabel + ".ancestry", qos: .userInitiated)
        scratch = UnsafeMutableRawPointer.allocate(byteCount: Self.scratchSize, alignment: 16)
    }

    deinit { scratch.deallocate() }

    // MARK: - Lifecycle

    /// Starts listening. `captureAncestry` runs on its own serial queue right after each accept,
    /// while the client is read; `onMessage` runs on the delivery queue, one message at a time.
    func start(captureAncestry: @escaping @Sendable (Int32) -> [pid_t],
               onMessage: @escaping @Sendable (Message) -> Void) {
        ioQueue.async { [self] in
            self.captureAncestry = captureAncestry
            self.onMessage = onMessage
            stopped = false
            openListener()
        }
    }

    /// Stops listening and drops the connections still being read (tests and benchmarks;
    /// the app's server runs for its whole life). Connections already handed off stay with
    /// their receiver.
    func stop() {
        ioQueue.sync {
            stopped = true
            resumeAtCeiling()           // a suspended source never runs its cancel handler
            listenerSource?.cancel()
            listenerSource = nil
            for client in clients.values where client.outcome == nil {
                client.outcome = .reject
                client.timer?.cancel()
                client.source?.cancel()
            }
        }
        ioQueue.sync {}                 // let the cancel handlers run
        unlink(configuration.socketPath)
    }

    /// Open client connections, held ones included.
    var openConnections: Int {
        connectionLock.lock(); defer { connectionLock.unlock() }
        return connectionCount
    }

    /// Closes a connection handed to the receiver and frees its slot under maxConnections.
    func closeClient(_ fd: Int32) {
        close(fd)
        connectionLock.lock()
        connectionCount -= 1
        let wake = waitingForSlot
        waitingForSlot = false
        connectionLock.unlock()
        if wake { ioQueue.async { [weak self] in self?.resumeAtCeiling() } }
    }

    /// Takes a connection slot; at the ceiling, pauses accepting until closeClient frees one.
    private func reserveSlot() -> Bool {
        connectionLock.lock()
        let free = connectionCount < configuration.maxConnections
        if free { connectionCount += 1 } else { waitingForSlot = true }
        connectionLock.unlock()
        if !free, !pausedAtCeiling, let source = listenerSource {
            pausedAtCeiling = true
            source.suspend()
        }
        return free
    }

    private func resumeAtCeiling() {
        guard pausedAtCeiling else { return }
        pausedAtCeiling = false
        listenerSource?.resume()
    }

    // MARK: - Helpers shared with HookServer

    /// Writes `text` and a newline. Gives up on any error (the relay may be gone).
    static func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// True when the peer of a connected Unix socket runs as the current user.
    static func peerIsCurrentUser(fd: Int32) -> Bool {
        var euid: uid_t = 0
        var egid: gid_t = 0
        return getpeereid(fd, &euid, &egid) == 0 && euid == getuid()
    }

    private static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: - Listening socket (ioQueue)

    private enum ListenerResult {
        case ready(Int32)
        case failed          // worth trying again later
        case unusable        // will never work (path too long)
    }

    private func openListener() {
        guard !stopped else { return }
        switch makeListener() {
        case .unusable:
            return
        case .failed:
            scheduleListenerRestart()
        case .ready(let fd):
            acceptFailures = 0
            acceptedAny = false
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in self?.acceptPending(listener: fd) }
            source.setCancelHandler { close(fd) }
            listenerSource = source
            source.resume()
        }
    }

    /// The listening socket broke: close it and create a new one after a growing delay.
    private func restartListener() {
        listenerSource?.cancel()        // its cancel handler closes the fd
        listenerSource = nil
        if acceptedAny { listenAttempt = 0 }
        NSLog("HookServer: listening socket failed, recreating it")
        scheduleListenerRestart()
    }

    private func scheduleListenerRestart() {
        listenAttempt += 1
        let delay = AcceptRecovery.restartDelay(attempt: listenAttempt)
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.openListener() }
    }

    /// Creates, binds and listens on the Unix socket (owner-only, non-blocking).
    private func makeListener() -> ListenerResult {
        let path = configuration.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return .unusable
        }
        // The folder may have been deleted since launch; a new one is owner-only.
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700 as NSNumber])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("HookServer: socket() failed, errno \(errno)")
            return .failed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else {
            NSLog("HookServer: bind() failed, errno \(errno)")
            close(fd)
            return .failed
        }
        // Restrict socket to owner only
        chmod(path, 0o600)
        guard Darwin.listen(fd, configuration.backlog) == 0 else {
            NSLog("HookServer: listen() failed, errno \(errno)")
            close(fd)
            return .failed
        }
        Self.setNonBlocking(fd, true)
        return .ready(fd)
    }

    /// Accepts every pending client. Transient errors are retried, descriptor shortages
    /// pause accepting a little; one failed accept() never ends the server.
    private func acceptPending(listener: Int32) {
        guard let source = listenerSource, !source.isCancelled, source.handle == UInt(listener) else { return }
        while true {
            // At the ceiling, pending clients stay in the backlog until a slot frees.
            guard reserveSlot() else { return }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else {
                let code = errno
                releaseSlot()
                if code == EAGAIN || code == EWOULDBLOCK { return }     // all accepted
                acceptFailures += 1
                switch AcceptRecovery.forErrno(code, consecutiveFailures: acceptFailures) {
                case .retry:
                    continue
                case .backOff:
                    if acceptFailures == 1 { NSLog("HookServer: accept() out of resources, errno \(code)") }
                    source.suspend()
                    let delay = AcceptRecovery.backOffDelay(consecutiveFailures: acceptFailures)
                    ioQueue.asyncAfter(deadline: .now() + delay) { source.resume() }
                    return
                case .restartListener:
                    NSLog("HookServer: accept() failed, errno \(code)")
                    restartListener()
                    return
                }
            }
            acceptFailures = 0
            acceptedAny = true
            admit(fd)
        }
    }

    /// Gives back a slot reserved for an accept() that returned no client.
    private func releaseSlot() {
        connectionLock.lock(); connectionCount -= 1; connectionLock.unlock()
    }

    /// Checks a new client (its slot already reserved) and starts reading it. The slot is
    /// freed by closeClient, when the fd closes — right after the reply for plain events,
    /// when the user decides for held requests.
    private func admit(_ fd: Int32) {
        // Reject connections from other users (same-UID check)
        guard Self.peerIsCurrentUser(fd: fd) else { closeClient(fd); return }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Self.setNonBlocking(fd, true)

        let client = Client(fd: fd, now: Self.now())
        clients[fd] = client
        // Started before reading: the relay may exit as soon as it has written. The fd stays
        // open until the capture is back (finish waits for it), so it can't be reused meanwhile.
        let capture = captureAncestry
        ancestryQueue.async { [self] in
            let pids = capture(fd)
            ioQueue.async { [self] in
                client.pids = pids
                if client.waitsForAncestry {
                    client.waitsForAncestry = false
                    finish(client)
                }
            }
        }
        // A relay has usually written its whole line by now: read it without a source.
        readAvailable(client)
        guard client.outcome == nil else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.readAvailable(client) }
        source.setCancelHandler { [weak self] in self?.finish(client) }
        client.source = source

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.setEventHandler { [weak self] in self?.idleCheck(client) }
        timer.schedule(deadline: .now() + configuration.idleTimeout, leeway: .milliseconds(100))
        client.timer = timer

        source.resume()
        timer.resume()
    }

    // MARK: - Reading (ioQueue)

    private func readAvailable(_ client: Client) {
        guard client.outcome == nil else { return }
        client.lastActivity = Self.now()
        let limit = configuration.maxPayload
        while true {
            let n = recv(client.fd, scratch, Self.scratchSize, 0)
            if n > 0 {
                let bytes = UnsafeRawBufferPointer(start: scratch, count: n)
                if let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
                    guard client.buffer.count + newline <= limit else { return end(client, .reject) }
                    client.buffer.append(contentsOf: bytes[..<newline])
                    return end(client, nil)
                }
                guard client.buffer.count + n <= limit else { return end(client, .reject) }
                client.buffer.append(contentsOf: bytes)
                continue
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return }      // wait for more
            }
            return end(client, nil)                                       // EOF or error
        }
    }

    /// Cuts off a client silent for idleTimeout; otherwise checks again when it could be.
    private func idleCheck(_ client: Client) {
        guard client.outcome == nil else { return }
        let timeout = UInt64(configuration.idleTimeout * 1_000_000_000)
        let idle = Self.now() &- client.lastActivity
        if idle >= timeout {
            end(client, nil)
        } else {
            client.timer?.schedule(deadline: .now() + .nanoseconds(Int(timeout - idle)), leeway: .milliseconds(100))
        }
    }

    /// The read is over. Whatever arrived is delivered (or rejected when empty or too long);
    /// the order is fixed now, the hand-off happens once no source watches the fd any more.
    private func end(_ client: Client, _ forced: Outcome?) {
        guard client.outcome == nil else { return }
        if let forced {
            client.outcome = forced
        } else if client.buffer.isEmpty {
            client.outcome = .reject
        } else {
            client.outcome = .deliver(sequence: nextSequence, data: client.buffer)
            nextSequence += 1
        }
        client.buffer = Data()
        client.timer?.cancel()
        client.timer = nil
        if let source = client.source {
            source.cancel()             // its cancel handler calls finish
        } else {
            finish(client)              // read in one go at accept, no source yet
        }
    }

    /// No read source watches the fd any more (cancelled, or never made): it is ours alone.
    private func finish(_ client: Client) {
        client.source = nil
        guard let pids = client.pids else {
            client.waitsForAncestry = true      // finished again once the capture is back
            return
        }
        clients[client.fd] = nil
        switch client.outcome {
        case .deliver(let sequence, let data):
            Self.setNonBlocking(client.fd, false)
            readyToDeliver[sequence] = Message(fd: client.fd, data: data, pids: pids)
            // Hand off in sequence order, even if cancel handlers ran out of order.
            while let message = readyToDeliver.removeValue(forKey: nextToDeliver) {
                nextToDeliver += 1
                let onMessage = onMessage
                deliveryQueue.async { onMessage(message) }
            }
        case .reject, nil:
            Self.sendLine(fd: client.fd, text: #"{"ok":true}"#)
            closeClient(client.fd)
        }
    }
}
