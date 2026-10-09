import Foundation
import Darwin

// Benchmark of the hook socket transport: the thread-per-connection server Coucou used
// before (LegacyThreadedServer, a faithful copy kept only here) against HookSocketServer.
// Run through scripts/bench-hook-socket.sh. Never touches the app's real socket.
//
//   HookSocketBench server <old|new> <socket>   the server, driven over stdin/stdout
//   HookSocketBench run <old|new> <scenario>    starts a server child, plays the scenario
//
// The server does what HookServer does per message: JSON parse, host lookup from the
// process chain (ProcessAncestry, the real code), hand-off to the main queue, {"ok":true}
// and close. The clients behave like the nb-hook relay for events: connect, send one JSON
// line, close without reading (fire-and-forget). Latency = client's clock before connect()
// → main-queue callback in the server (same CLOCK_UPTIME_RAW in both processes).

// MARK: - Shared

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func payload(session: Int, seq: Int) -> String {
    let output = String(repeating: "src/feature/file\(seq % 7).swift ", count: 20)
    let obj: [String: Any] = [
        "t": nowNs(),
        "hook_event_name": seq % 2 == 0 ? "PreToolUse" : "PostToolUse",
        "session_id": "bench-session-\(session)",
        "cwd": "/Users/dev/projects/app\(session)",
        "tool_name": "Bash",
        "tool_input": ["command": "swift build -c release && ./scripts/test-all.sh # \(seq)",
                       "description": "Build and run the tests"],
        "tool_response": ["stdout": output, "stderr": "", "interrupted": false],
        "term_program": "WebStorm",
        "bundle_id": "com.jetbrains.WebStorm",
        "transcript_path": "/Users/dev/.claude/projects/app\(session)/bench-session-\(session).jsonl",
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(decoding: data, as: UTF8.self)
}

func sendLine(_ fd: Int32, _ text: String) {
    let bytes = Array((text + "\n").utf8)
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        sent += n
    }
}

func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cpath = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
    }
    return addr
}

// MARK: - Server side

final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [UInt64] = []
    private var chains = 0
    private var startUsage = rusage()

    func reset() {
        lock.lock(); latencies.removeAll(keepingCapacity: true); chains = 0; lock.unlock()
        getrusage(RUSAGE_SELF, &startUsage)
    }
    func record(_ ns: UInt64, chain: Bool) { lock.lock(); latencies.append(ns); if chain { chains += 1 }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return latencies.count }

    func report() -> String {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
        let user = secs(usage.ru_utime) - secs(startUsage.ru_utime)
        let sys = secs(usage.ru_stime) - secs(startUsage.ru_stime)
        lock.lock(); let sorted = latencies.sorted(); let chains = chains; lock.unlock()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) / 1e6
        }
        return String(format: "count=%d chain=%d p50=%.3f p99=%.3f max=%.3f cpu_user=%.4f cpu_sys=%.4f",
                      sorted.count, chains, pct(0.5), pct(0.99), pct(1.0), user, sys)
    }
}

let stats = Stats()

/// HookServer.handleMessage, minus AppState: parse, host lookup, main-queue hop, answer, close.
func handle(fd: Int32, raw: Data, pids: [pid_t], close closeClient: (Int32) -> Void) {
    defer { closeClient(fd) }
    guard !raw.isEmpty, var payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        sendLine(fd, #"{"ok":true}"#)
        return
    }
    let sessionId = payload["session_id"] as? String ?? ""
    payload["coucou_host_bundle_ids"] = ProcessAncestry.hostBundleIds(sessionId: sessionId, pids: pids)
    let sent = (payload["t"] as? NSNumber)?.uint64Value ?? 0
    nonisolated(unsafe) let message = payload
    DispatchQueue.main.async {
        _ = message.count
        stats.record(nowNs() &- sent, chain: !pids.isEmpty)
    }
    sendLine(fd, #"{"ok":true}"#)
}

/// The transport as it was before HookSocketServer (HookServer.swift at 9950c26): one
/// blocking accept thread, one thread per connection with SO_RCVTIMEO 5 s, byte-wise reads.
final class LegacyThreadedServer: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var connectionCount = 0
    init(path: String) { self.path = path }

    func start() { Thread.detachNewThread { self.serverThread() } }

    private func closeClient(_ fd: Int32) {
        close(fd)
        lock.lock(); connectionCount -= 1; lock.unlock()
    }

    private func serverThread() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = unixAddress(path)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { fatalError("bind failed \(errno)") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { fatalError("listen failed") }
        var failures = 0
        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                let code = errno
                failures += 1
                switch AcceptRecovery.forErrno(code, consecutiveFailures: failures) {
                case .retry: continue
                case .backOff:
                    Thread.sleep(forTimeInterval: AcceptRecovery.backOffDelay(consecutiveFailures: failures))
                    continue
                case .restartListener: return
                }
            }
            failures = 0
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else { close(clientFD); continue }
            lock.lock()
            let count = connectionCount
            if count < 32 { connectionCount += 1 }
            lock.unlock()
            guard count < 32 else { close(clientFD); continue }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    private func handleClient(fd: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let pids = ProcessAncestry.pidChain(fd: fd)
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
            if raw.count > 1_048_576 { break }
        }
        handle(fd: fd, raw: raw, pids: pids, close: closeClient)
    }
}

func runServer(design: String, path: String) -> Never {
    signal(SIGPIPE, SIG_IGN)
    var keep: [AnyObject] = []
    if design == "old" {
        let server = LegacyThreadedServer(path: path)
        server.start()
        keep.append(server)
    } else {
        var config = HookSocketServer.Configuration(socketPath: path)
        config.queueLabel = "bench"
        let server = HookSocketServer(configuration: config)
        server.start(captureAncestry: { ProcessAncestry.pidChain(fd: $0) },
                     onMessage: { [server] m in handle(fd: m.fd, raw: m.data, pids: m.pids, close: server.closeClient) })
        keep.append(server)
    }
    nonisolated(unsafe) let retained = keep
    // Commands on stdin, answers on stdout: reset, count, report.
    Thread.detachNewThread {
        _ = retained
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine() {
            switch line {
            case "reset": stats.reset(); print("ok")
            case "count": print(stats.count)
            case "report": print(stats.report())
            default: exit(0)
            }
        }
        exit(0)
    }
    dispatchMain()
}

// MARK: - Client side

func threadCount(pid: pid_t) -> Int {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
    return Int(info.pti_threadnum)
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent = 0, refused = 0
    func add(ok: Bool) { lock.lock(); if ok { sent += 1 } else { refused += 1 }; lock.unlock() }
}

/// One relay event: connect, write the line, close without reading.
func fireAndForget(_ path: String, _ line: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 0, tv_usec: 300_000)     // the relay's 0.3 s
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = unixAddress(path)
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return false }
    sendLine(fd, line)
    return true
}

/// A request that waits for its answer (closed loop): connect, write, read until EOF.
func requestReply(_ path: String, _ line: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = unixAddress(path)
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return false }
    sendLine(fd, line)
    var buf = [UInt8](repeating: 0, count: 256)
    var got = 0
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 { got += n; continue }
        if n < 0 && errno == EINTR { continue }
        break
    }
    return got > 0
}

func run(design: String, scenario: String) {
    signal(SIGPIPE, SIG_IGN)
    let dir = NSTemporaryDirectory() + "coucou-bench-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/nb.sock"

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["server", design, path]
    let toChild = Pipe(), fromChild = Pipe()
    child.standardInput = toChild
    child.standardOutput = fromChild
    try! child.run()
    defer { child.terminate() }
    var pending = Data()
    func command(_ c: String) -> String {
        toChild.fileHandleForWriting.write((c + "\n").data(using: .utf8)!)
        while true {
            if let nl = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<nl], as: UTF8.self)
                pending.removeSubrange(...nl)
                return line
            }
            pending.append(fromChild.fileHandleForReading.availableData)
        }
    }
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: path) { break }
        usleep(10_000)
    }

    // Warm-up (first host lookups, page faults), then measure.
    for s in 0..<3 { _ = fireAndForget(path, payload(session: s, seq: 0)) }
    usleep(300_000)
    _ = command("reset")

    let counter = Counter()
    let childPid = child.processIdentifier
    var peakThreads = threadCount(pid: childPid)
    let baseThreads = peakThreads
    // Samples the server's thread count every millisecond until told to stop.
    final class Sampler: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        var peak = 0
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }
    let sampler = Sampler()
    sampler.peak = peakThreads
    let sampling = DispatchQueue(label: "sampler")
    sampling.async {
        while !sampler.isDone {
            let n = threadCount(pid: childPid)
            sampler.lock.lock(); sampler.peak = max(sampler.peak, n); sampler.lock.unlock()
            usleep(1_000)
        }
    }

    let start = Date()
    switch scenario {
    case "paced":   // 3 sessions × 10 events/s for 5 s, like coucou-replay.py burst
        DispatchQueue.concurrentPerform(iterations: 3) { s in
            let begin = DispatchTime.now()
            for i in 0..<50 {
                counter.add(ok: fireAndForget(path, payload(session: s, seq: i)))
                let next = begin + .milliseconds((i + 1) * 100)
                let wait = Int64(next.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                if wait > 0 { usleep(UInt32(wait / 1000)) }
            }
        }
    case "spike":   // 96 events at once from 16 clients, fire-and-forget
        DispatchQueue.concurrentPerform(iterations: 16) { c in
            for i in 0..<6 { counter.add(ok: fireAndForget(path, payload(session: c % 3, seq: i))) }
        }
    default:        // flood: 16 clients × 250 requests back to back, each waiting for its answer
        DispatchQueue.concurrentPerform(iterations: 16) { c in
            for i in 0..<250 { counter.add(ok: requestReply(path, payload(session: c % 3, seq: i))) }
        }
    }
    let clientsDone = Date()
    // Wait for the server to drain (count stable for 300 ms).
    var last = -1
    while true {
        let n = Int(command("count")) ?? 0
        if n == last { break }
        last = n
        usleep(300_000)
    }
    sampler.lock.lock(); sampler.done = true; sampler.lock.unlock()
    sampling.sync {}
    peakThreads = sampler.peak
    let report = command("report")
    let elapsed = clientsDone.timeIntervalSince(start)
    let delivered = last
    print(String(format: "%@ %-5@ sent=%d refused=%d delivered=%d lost=%d  %.0f msg/s  %@  threads base=%d peak=%d",
                 design as NSString, scenario as NSString, counter.sent, counter.refused, delivered,
                 counter.sent - delivered, Double(delivered) / elapsed, report as NSString, baseThreads, peakThreads))
}

// MARK: - Entry

let args = CommandLine.arguments
if args.count == 4, args[1] == "server" {
    runServer(design: args[2], path: args[3])
} else if args.count == 4, args[1] == "run" {
    run(design: args[2], scenario: args[3])
} else {
    print("usage: HookSocketBench run <old|new> <paced|spike|flood>")
    exit(2)
}
