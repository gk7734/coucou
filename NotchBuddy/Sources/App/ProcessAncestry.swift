import AppKit
import Darwin

// MARK: - ProcessAncestry
//
// The apps above a hook relay in the process tree: the strongest signal of where an agent
// session runs (HostResolver). Runs on the hook server's client threads, never the main one.
//
// - The relay's pid comes from the connected socket (LOCAL_PEERPID), and the pid chain is
//   captured as soon as the connection is accepted: a fire-and-forget relay closes and exits
//   right after writing, and an exited process has no parent to walk from.
// - Parents come from sysctl(KERN_PROC_PID). In the sandboxed App Store build, or for a
//   process that is already gone, a lookup fails and the walk simply stops: the result is
//   then [] and HostResolver falls back on the payload's bundle_id / TERM_PROGRAM.
// - Only regular apps (activationPolicy == .regular) count: helpers, daemons and Coucou
//   itself (an accessory app) are skipped.
// - The first non-empty result per session is cached for the session's life, so a session
//   never flips pills and later events skip the app lookups.

enum ProcessAncestry {

    /// The pid of the process at the other end of a connected Unix socket, nil when unknown.
    static func peerPid(fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The parent of `pid`, nil when the process is gone or the lookup is not allowed.
    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        // A pid that no longer exists returns 0 with an empty buffer.
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// The peer itself followed by its ancestors, nearest first (launchd excluded).
    /// Only sysctl calls: cheap enough to run on every connection.
    static func pidChain(fd: Int32) -> [pid_t] {
        guard let peer = peerPid(fd: fd) else { return [] }
        return [peer] + ProcessTree.ancestors(of: peer, maxDepth: 24, parent: parentPid(of:))
    }

    /// Bundle ids of the regular apps among `pids`, nearest first, without duplicates.
    /// Stops after `limit` apps: HostResolver only needs the nearest ones.
    static func regularAppBundleIds(pids: [pid_t], limit: Int = 4) -> [String] {
        var ids: [String] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, !id.isEmpty, !ids.contains(id) else { continue }
            ids.append(id)
            if ids.count >= limit { break }
        }
        return ids
    }

    // MARK: Per-session cache

    private static let cache = HostAncestryCache(capacity: 512)

    /// The host apps of a session: the cached ones when the session already resolved,
    /// else the apps above `pids` (cached when there are any).
    static func hostBundleIds(sessionId: String, pids: [pid_t]) -> [String] {
        if !sessionId.isEmpty, let cached = cache.value(for: sessionId) { return cached }
        let ids = regularAppBundleIds(pids: pids)
        if !sessionId.isEmpty, !ids.isEmpty { cache.store(ids, for: sessionId) }
        return ids
    }
}

/// A bounded session id → host bundle ids map, safe to use from any thread.
/// The first value stored for a session wins; the oldest sessions are dropped past `capacity`.
final class HostAncestryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]   // guarded by lock
    private var order: [String] = []                // insertion order, guarded by lock
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func value(for key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: [String], for key: String) {
        lock.lock(); defer { lock.unlock() }
        guard values[key] == nil else { return }
        values[key] = value
        order.append(key)
        if order.count > capacity {
            let drop = order.count - capacity
            for old in order.prefix(drop) { values.removeValue(forKey: old) }
            order.removeFirst(drop)
        }
    }
}
