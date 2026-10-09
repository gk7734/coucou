import Foundation

// MARK: - Pending request queue (Foundation-only, testable)
//
// Hook requests the app holds open while the user decides (PermissionRequest approvals,
// AskUserQuestion questions). Several can arrive at once from different sessions:
// they queue and are shown one at a time, in arrival order (docs/SPEC.md §3 rule 9).
// Only the head is on screen. Every entry keeps its own deadline, so a request that waits
// behind others still gives up before its relay does and the agent asks in its terminal.

struct PendingRequestQueue<Payload> {
    struct Entry {
        /// Unique per request. Never the fd: fd numbers are reused as soon as one closes.
        let id: UInt64
        let pillId: String
        let sessionId: String
        let tool: String
        /// tool_input as sorted-keys JSON, "" when absent — matches PostToolUse to the request.
        let inputKey: String
        /// Monotonic seconds after which the app gives up on this request.
        let deadline: TimeInterval
        let payload: Payload
    }

    /// Requests held at most at once; beyond that a new one is answered at once ("ask").
    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The request on screen.
    var head: Entry? { entries.first }
    var isEmpty: Bool { entries.isEmpty }
    var isFull: Bool { entries.count >= capacity }
    var count: Int { entries.count }

    func contains(id: UInt64) -> Bool { entries.contains { $0.id == id } }

    /// Appends at the tail. False when the queue is full (the entry is not added).
    @discardableResult
    mutating func enqueue(_ entry: Entry) -> Bool {
        guard !isFull else { return false }
        entries.append(entry)
        return true
    }

    /// Removes one request (decision sent, connection closed…). Nil if it is no longer queued.
    @discardableResult
    mutating func remove(id: UInt64) -> Entry? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: idx)
    }

    /// Removes and returns, in queue order, every request whose deadline is at or before `now`.
    mutating func removeExpired(now: TimeInterval) -> [Entry] {
        let expired = entries.filter { $0.deadline <= now }
        entries.removeAll { $0.deadline <= now }
        return expired
    }

    /// Removes and returns, in queue order, every request an agent event settles:
    /// see `resolves(event:pillId:sessionId:tool:inputKey:entry:)`.
    mutating func removeResolved(event: String, pillId: String, sessionId: String,
                                 tool: String, inputKey: String) -> [Entry] {
        let settled = entries.filter {
            Self.resolves(event: event, pillId: pillId, sessionId: sessionId, tool: tool, inputKey: inputKey, entry: $0)
        }
        guard !settled.isEmpty else { return [] }
        let ids = Set(settled.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        return settled
    }

    /// True when `event` shows the request was answered elsewhere (in the editor or terminal):
    /// - PostToolUse / PostToolUseFailure of this exact call — same session, tool and input.
    ///   Other tools finishing in parallel must not close it.
    /// - Stop, StopFailure, UserPromptSubmit, SessionEnd, Interrupt of the same session:
    ///   the turn ended, so the request is moot.
    static func resolves(event: String, pillId: String, sessionId: String,
                         tool: String, inputKey: String, entry: Entry) -> Bool {
        guard entry.pillId == pillId, entry.sessionId == sessionId else { return false }
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            return tool == entry.tool && inputKey == entry.inputKey
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
            return true
        default:
            return false
        }
    }
}

// MARK: - A card that changed under the pointer

/// When the approval card on screen is replaced by the next queued one in the same instant
/// (answered in the editor, expired, or decided with a click that a second click follows),
/// a click aimed at the old card must not answer the new one, which the user hasn't read.
/// The card's buttons are ignored for `delay` after such a swap (never approve without an
/// explicit click).
struct CardSwapGuard: Equatable {
    /// How long the buttons of a card that just swapped in ignore clicks.
    static let delay: TimeInterval = 0.6
    /// A card presented this soon after the previous one closed replaced it on screen.
    static let sameInstant: TimeInterval = 0.1

    private var closedAt: TimeInterval = -.infinity
    private var swappedAt: TimeInterval = -.infinity

    init() {}

    /// The card on screen closed (monotonic seconds).
    mutating func cardClosed(at now: TimeInterval) { closedAt = now }

    /// A card was presented: a swap when the previous one closed just before.
    mutating func cardPresented(at now: TimeInterval) {
        if now - closedAt < Self.sameInstant { swappedAt = now }
    }

    /// True while a click on the card on screen must be ignored.
    func blocksClick(at now: TimeInterval) -> Bool {
        now - swappedAt < Self.delay
    }
}

// MARK: - accept() failure recovery

/// What the hook socket server does when accept() fails.
enum AcceptRecovery: Equatable {
    /// Transient (interrupted, client gave up before accept): accept again right away.
    case retry
    /// Out of file descriptors or memory: wait `backOffDelay`, then accept again.
    case backOff
    /// The listening socket itself is broken: close it and create a new one.
    case restartListener

    /// After this many failures in a row, even "transient" ones, start a new listening socket.
    static let maxConsecutiveFailures = 50

    static func forErrno(_ code: Int32, consecutiveFailures: Int) -> AcceptRecovery {
        if consecutiveFailures >= maxConsecutiveFailures { return .restartListener }
        switch code {
        case EINTR, ECONNABORTED, EAGAIN, EPROTO, ECONNRESET:
            return .retry
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return .backOff
        default:   // EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP, EFAULT…
            return .restartListener
        }
    }

    /// Wait before accepting again after the n-th descriptor/memory shortage in a row (n ≥ 1):
    /// 50 ms doubling, capped at 1 s.
    static func backOffDelay(consecutiveFailures n: Int) -> TimeInterval {
        min(1.0, 0.05 * pow(2.0, Double(max(0, min(n, 16) - 1))))
    }

    /// Wait before the n-th attempt in a row (n ≥ 1) at creating the listening socket:
    /// 0.5 s doubling, capped at 30 s.
    static func restartDelay(attempt n: Int) -> TimeInterval {
        min(30.0, 0.5 * pow(2.0, Double(max(0, min(n, 16) - 1))))
    }
}
