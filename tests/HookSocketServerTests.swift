import Foundation
import Darwin

// Tests for HookSocketServer (the hook socket transport) on a temporary socket.
// Never touches ~/Library/Application Support/NotchBuddy/nb.sock.

@main
enum HookSocketServerTests {

    nonisolated(unsafe) static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got)")
            print("    expected: \(expected)")
            failures += 1
        }
    }

    // MARK: - Server side

    /// What the receiver saw, in delivery order.
    final class Recorder: @unchecked Sendable {
        struct Delivered {
            let text: String
            let pids: [pid_t]
            let blocking: Bool
            let sameUser: Bool
        }
        private let lock = NSLock()
        private var items: [Delivered] = []
        private var held: [String: Int32] = [:]
        private var inHandler = 0
        private(set) var overlapped = false
        var ancestryCalls = 0

        func record(_ d: Delivered) { lock.lock(); items.append(d); lock.unlock() }
        var delivered: [Delivered] { lock.lock(); defer { lock.unlock() }; return items }
        var texts: [String] { delivered.map(\.text) }
        func hold(_ key: String, fd: Int32) { lock.lock(); held[key] = fd; lock.unlock() }
        func heldFD(_ key: String) -> Int32? { lock.lock(); defer { lock.unlock() }; return held[key] }
        func enter() { lock.lock(); if inHandler > 0 { overlapped = true }; inHandler += 1; lock.unlock() }
        func leave() { lock.lock(); inHandler -= 1; lock.unlock() }
        func countAncestry() { lock.lock(); ancestryCalls += 1; lock.unlock() }
        var ancestry: Int { lock.lock(); defer { lock.unlock() }; return ancestryCalls }
    }

    static func peerPid(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        return pid
    }

    /// A server on a fresh temporary path. Messages starting with "hold" are kept open
    /// (see `Recorder.hold`); everything else is answered {"ok":true} and closed, like an event.
    static func makeServer(_ dir: String, _ name: String,
                           maxPayload: Int = 4096, idle: TimeInterval = 0.4,
                           maxConnections: Int = 32) -> (HookSocketServer, Recorder) {
        var config = HookSocketServer.Configuration(socketPath: dir + "/" + name + "/nb.sock")
        config.maxPayload = maxPayload
        config.idleTimeout = idle
        config.maxConnections = maxConnections
        config.queueLabel = "test." + name
        let server = HookSocketServer(configuration: config)
        let recorder = Recorder()
        server.start(captureAncestry: { fd in
            recorder.countAncestry()
            return [peerPid(fd)]
        }, onMessage: { [server] message in
            recorder.enter()
            let text = String(decoding: message.data, as: UTF8.self)
            let flags = fcntl(message.fd, F_GETFL)
            recorder.record(.init(text: text, pids: message.pids,
                                  blocking: flags >= 0 && flags & O_NONBLOCK == 0,
                                  sameUser: HookSocketServer.peerIsCurrentUser(fd: message.fd)))
            Thread.sleep(forTimeInterval: 0.001)        // widen any overlap
            recorder.leave()
            if text.hasPrefix("hold") {
                recorder.hold(text, fd: message.fd)
            } else {
                HookSocketServer.sendLine(fd: message.fd, text: #"{"ok":true}"#)
                server.closeClient(message.fd)
            }
        })
        waitUntil(2) { FileManager.default.fileExists(atPath: config.socketPath) }
        return (server, recorder)
    }

    // MARK: - Client side

    static func connectClient(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return }
            sent += n
        }
    }

    /// Everything until EOF (or `timeout`), nil on timeout.
    static func readToEOF(_ fd: Int32, timeout: TimeInterval = 3) -> String? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(contentsOf: buf[..<n]); continue }
            if n == 0 { return String(decoding: out, as: UTF8.self) }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// One relay-like request: connect, send a line, read the reply until EOF.
    static func request(_ path: String, _ line: String) -> String? {
        let fd = connectClient(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        write(fd, line + "\n")
        return readToEOF(fd)
    }

    static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { usleep(5_000) }
    }

    static func mode(_ path: String) -> Int {
        var st = stat()
        guard stat(path, &st) == 0 else { return -1 }
        return Int(st.st_mode & 0o777)
    }

    // MARK: - Tests

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        var template = Array((NSTemporaryDirectory() + "coucou-hss.XXXXXX").utf8CString)
        guard let dirPtr = mkdtemp(&template) else { print("mkdtemp failed"); exit(1) }
        let dir = String(cString: dirPtr)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let started = Date()

        print("Listening socket")
        do {
            let (server, rec) = makeServer(dir, "basic")
            let path = server.configuration.socketPath
            check("socket folder is created owner-only (0700)", mode((path as NSString).deletingLastPathComponent), 0o700)
            check("socket is owner-only (0600)", mode(path), 0o600)
            check("event is answered {\"ok\":true} then closed", request(path, #"{"n":1}"#), "{\"ok\":true}\n")
            waitUntil(1) { rec.delivered.count == 1 }
            let first = rec.delivered.first
            check("message delivered without its newline", first?.text, #"{"n":1}"#)
            check("process chain captured at accept (peer pid)", first?.pids, [getpid()])
            check("peer UID check passes for the current user", first?.sameUser, true)
            check("fd handed over in blocking mode", first?.blocking, true)
            waitUntil(1) { server.openConnections == 0 }
            check("slot freed after the reply", server.openConnections, 0)
            server.stop()
            check("stop() removes the socket file", FileManager.default.fileExists(atPath: path), false)
        }

        print("Concurrent clients")
        do {
            let (server, rec) = makeServer(dir, "concurrent")
            let path = server.configuration.socketPath
            let replies = Recorder()
            DispatchQueue.concurrentPerform(iterations: 64) { i in
                replies.record(.init(text: request(path, #"{"client":\#(i)}"#) ?? "nil", pids: [], blocking: true, sameUser: true))
            }
            check("64 concurrent clients all answered", replies.texts.filter { $0 == "{\"ok\":true}\n" }.count, 64)
            waitUntil(2) { rec.delivered.count == 64 }
            check("64 messages delivered", Set(rec.texts).count, 64)
            // Fire-and-forget, like the relay: write and close without reading.
            DispatchQueue.concurrentPerform(iterations: 40) { i in
                let fd = connectClient(path)
                write(fd, #"{"fire":\#(i)}"# + "\n")
                close(fd)
            }
            waitUntil(2) { rec.delivered.count == 104 }
            check("40 fire-and-forget clients delivered", rec.texts.filter { $0.hasPrefix(#"{"fire""#) }.count, 40)
            check("messages handed over one at a time", rec.overlapped, false)
            check("ancestry captured once per connection", rec.ancestry, 104)
            waitUntil(2) { server.openConnections == 0 }
            check("no slot leaked", server.openConnections, 0)
            server.stop()
        }

        print("Partial writes")
        do {
            let (server, rec) = makeServer(dir, "partial")
            let path = server.configuration.socketPath
            let fd = connectClient(path)
            write(fd, #"{"tool":"#)
            usleep(60_000)
            write(fd, #""Bash","n":"#)
            usleep(60_000)
            write(fd, "2}")
            usleep(60_000)
            check("nothing delivered before the newline", rec.delivered.count, 0)
            write(fd, "\n")
            check("reply after the line completes", readToEOF(fd), "{\"ok\":true}\n")
            close(fd)
            waitUntil(1) { rec.delivered.count == 1 }
            check("line reassembled from 4 packets", rec.texts, [#"{"tool":"Bash","n":2}"#])
            // Bytes after the newline are ignored: one message per connection.
            check("only the first line counts", request(path, "first\nsecond"), "{\"ok\":true}\n")
            waitUntil(1) { rec.delivered.count == 2 }
            check("first line delivered", rec.texts.last, "first")
            server.stop()
        }

        print("Payload cap")
        do {
            let (server, rec) = makeServer(dir, "cap", maxPayload: 4096)
            let path = server.configuration.socketPath
            check("line over the cap rejected with {\"ok\":true}", request(path, String(repeating: "x", count: 10_000)), "{\"ok\":true}\n")
            let fd = connectClient(path)
            write(fd, String(repeating: "y", count: 10_000))           // no newline, keeps sending
            check("oversize without newline cut off at the cap", readToEOF(fd), "{\"ok\":true}\n")
            close(fd)
            check("line exactly at the cap accepted", request(path, String(repeating: "z", count: 4096)), "{\"ok\":true}\n")
            waitUntil(1) { rec.delivered.count == 1 }
            check("only the line within the cap delivered", rec.delivered.map(\.text.count), [4096])
            waitUntil(1) { server.openConnections == 0 }
            check("no slot leaked", server.openConnections, 0)
            server.stop()
        }

        print("Idle timeout")
        do {
            let (server, rec) = makeServer(dir, "idle", idle: 0.4)
            let path = server.configuration.socketPath
            let silent = connectClient(path)
            let t0 = Date()
            let reply = readToEOF(silent)
            let elapsed = Date().timeIntervalSince(t0)
            close(silent)
            check("silent client closed with {\"ok\":true}", reply, "{\"ok\":true}\n")
            check("…after the idle timeout (0.4 s)", elapsed > 0.3 && elapsed < 1.5, true)
            check("silent client never delivered", rec.delivered.count, 0)

            // A client that keeps writing is not idle.
            let slow = connectClient(path)
            for piece in ["{\"s", "low\"", ":", "1}"] { write(slow, piece); usleep(200_000) }
            write(slow, "\n")
            check("slow writer (0.8 s total) not cut off", readToEOF(slow), "{\"ok\":true}\n")
            close(slow)

            // What arrived before the timeout is delivered, as before (SO_RCVTIMEO then parse).
            let partial = connectClient(path)
            write(partial, #"{"half":1}"#)
            _ = readToEOF(partial)
            close(partial)
            waitUntil(1) { rec.delivered.count == 2 }
            check("line without newline delivered at timeout", rec.texts, [#"{"slow":1}"#, #"{"half":1}"#])
            waitUntil(1) { server.openConnections == 0 }
            check("no slot leaked", server.openConnections, 0)
            server.stop()
        }

        print("Held connections")
        do {
            let (server, rec) = makeServer(dir, "held", maxConnections: 3)
            let path = server.configuration.socketPath
            let a = connectClient(path)
            write(a, "hold-a\n")
            waitUntil(1) { rec.heldFD("hold-a") != nil }
            check("held connection keeps its slot", server.openConnections, 1)
            check("events still served while one is held", request(path, #"{"e":1}"#), "{\"ok\":true}\n")

            // Reply after a delay, from another queue, like finishHeld.
            let heldA = rec.heldFD("hold-a")!
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                HookSocketServer.sendLine(fd: heldA, text: #"{"permissionDecision":"allow"}"#)
                server.closeClient(heldA)
            }
            check("held connection receives its reply", readToEOF(a), "{\"permissionDecision\":\"allow\"}\n")
            close(a)

            // Hang-up watcher on a handed-over fd (makeHoldSource): fires when the relay closes.
            let b = connectClient(path)
            write(b, "hold-b\n")
            waitUntil(1) { rec.heldFD("hold-b") != nil }
            let heldB = rec.heldFD("hold-b")!
            let hungUp = DispatchSemaphore(value: 0)
            let watcher = DispatchSource.makeReadSource(fileDescriptor: heldB, queue: .global())
            // @Sendable: a closure formed in main() is main-actor isolated and would trap on
            // a global queue (the same rule HookSocketServer's handlers follow).
            watcher.setEventHandler { @Sendable in hungUp.signal(); watcher.cancel() }
            watcher.setCancelHandler { @Sendable in server.closeClient(heldB) }
            watcher.resume()
            usleep(100_000)
            close(b)
            check("hang-up seen on the held fd", hungUp.wait(timeout: .now() + 2) == .success, true)

            // Connection ceiling counts held fds: 3 held → a 4th client waits in the backlog.
            var holds: [Int32] = []
            for i in 0..<3 {
                let fd = connectClient(path)
                write(fd, "hold-\(i)\n")
                holds.append(fd)
            }
            waitUntil(1) { rec.heldFD("hold-2") != nil && server.openConnections == 3 }
            check("3 held connections fill the ceiling", server.openConnections, 3)
            let waiting = connectClient(path)
            check("4th client connects (listen backlog)", waiting >= 0, true)
            write(waiting, #"{"e":2}"# + "\n")
            check("4th client not served at the ceiling", readToEOF(waiting, timeout: 0.3), nil)
            check("…and not delivered", rec.texts.contains(#"{"e":2}"#), false)
            if let fd = rec.heldFD("hold-0") { server.closeClient(fd) }
            check("a freed slot serves the waiting client", readToEOF(waiting), "{\"ok\":true}\n")
            close(waiting)
            check("next client served", request(path, #"{"e":3}"#), "{\"ok\":true}\n")
            for i in 1..<3 { if let fd = rec.heldFD("hold-\(i)") { server.closeClient(fd) } }
            for fd in holds { close(fd) }
            waitUntil(1) { server.openConnections == 0 }
            check("all slots freed", server.openConnections, 0)
            server.stop()
        }

        print("Delivery order = completion order")
        do {
            let (server, rec) = makeServer(dir, "order")
            let path = server.configuration.socketPath
            // A connects first but finishes last.
            let a = connectClient(path)
            write(a, #"{"who":"#)
            usleep(30_000)
            check("B answered while A is still writing", request(path, #"{"who":"B"}"#), "{\"ok\":true}\n")
            write(a, #""A"}"# + "\n")
            _ = readToEOF(a)
            close(a)
            waitUntil(1) { rec.delivered.count == 2 }
            check("B (finished first) delivered before A", rec.texts, [#"{"who":"B"}"#, #"{"who":"A"}"#])

            // 12 connections opened in order, completed in reverse order.
            var fds: [Int32] = []
            for i in 0..<12 {
                let fd = connectClient(path)
                write(fd, #"{"i":\#(i)"#)
                fds.append(fd)
            }
            usleep(50_000)
            for i in (0..<12).reversed() {
                write(fds[i], "}\n")
                usleep(15_000)
            }
            for fd in fds { _ = readToEOF(fd); close(fd) }
            waitUntil(2) { rec.delivered.count == 14 }
            check("reverse completion → reverse delivery", Array(rec.texts.dropFirst(2)),
                  (0..<12).reversed().map { #"{"i":\#($0)}"# })
            server.stop()
        }

        print("Slow process-chain capture")
        do {
            var config = HookSocketServer.Configuration(socketPath: dir + "/ancestry/nb.sock")
            config.queueLabel = "test.ancestry"
            let server = HookSocketServer(configuration: config)
            let rec = Recorder()
            server.start(captureAncestry: { fd in
                let pid = peerPid(fd)
                Thread.sleep(forTimeInterval: 0.2)      // a slow sysctl walk
                return [pid]
            }, onMessage: { [server] message in
                rec.record(.init(text: String(decoding: message.data, as: UTF8.self), pids: message.pids,
                                 blocking: true, sameUser: true))
                HookSocketServer.sendLine(fd: message.fd, text: #"{"ok":true}"#)
                server.closeClient(message.fd)
            })
            let path = config.socketPath
            waitUntil(2) { FileManager.default.fileExists(atPath: path) }
            for i in 0..<6 {
                let fd = connectClient(path)
                write(fd, #"{"a":\#(i)}"# + "\n")
                close(fd)                               // gone before its chain is captured
                usleep(10_000)
            }
            // 6 captures of 0.2 s queue up; the I/O queue keeps accepting and reading meanwhile.
            waitUntil(0.5) { server.openConnections == 6 }
            check("all 6 accepted while captures run", server.openConnections, 6)
            check("messages wait for their capture", rec.delivered.count < 6, true)
            waitUntil(3) { rec.delivered.count == 6 }
            check("every message delivered with its capture", rec.delivered.allSatisfy { $0.pids.count == 1 }, true)
            check("in completion order", rec.texts, (0..<6).map { #"{"a":\#($0)}"# })
            waitUntil(1) { server.openConnections == 0 }
            check("no slot leaked", server.openConnections, 0)
            server.stop()
        }

        print("Socket path too long")
        do {
            let long = dir + "/" + String(repeating: "l", count: 120)
            let server = HookSocketServer(configuration: .init(socketPath: long + "/nb.sock"))
            server.start(captureAncestry: { _ in [] }, onMessage: { _ in })
            usleep(100_000)
            check("no socket created for a path over sun_path", FileManager.default.fileExists(atPath: long + "/nb.sock"), false)
            server.stop()
        }

        let total = Date().timeIntervalSince(started)
        print(String(format: "Done in %.1f s", total))
        check("suite under 10 s", total < 10, true)
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All HookSocketServer tests passed.")
    }
}
