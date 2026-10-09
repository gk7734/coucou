import Foundation

@main
enum PendingRequestQueueTests {

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

    typealias Queue = PendingRequestQueue<String>

    static func entry(_ id: UInt64, pill: String = "integration_claude", session: String = "s1",
                      tool: String = "Bash", input: String = #"{"command":"ls"}"#,
                      deadline: TimeInterval = 115) -> Queue.Entry {
        Queue.Entry(id: id, pillId: pill, sessionId: session, tool: tool, inputKey: input,
                    deadline: deadline, payload: "p\(id)")
    }

    static func ids(_ q: Queue) -> [UInt64] { q.entries.map(\.id) }

    static func main() {
        // ── FIFO ────────────────────────────────────────────────────────────────
        print("FIFO order")
        var q = Queue(capacity: 3)
        check("starts empty", q.isEmpty, true)
        check("no head", q.head?.id, nil)
        check("enqueue 1", q.enqueue(entry(1)), true)
        check("first request is head", q.head?.id, 1)
        q.enqueue(entry(2, session: "s2"))
        q.enqueue(entry(3, session: "s3"))
        check("second request waits, head unchanged", q.head?.id, 1)
        check("arrival order kept", ids(q), [1, 2, 3])
        check("full at capacity", q.isFull, true)
        check("enqueue when full is refused", q.enqueue(entry(4)), false)
        check("refused entry not added", ids(q), [1, 2, 3])

        // ── advance ─────────────────────────────────────────────────────────────
        print("advance")
        check("remove head returns it", q.remove(id: 1)?.payload, "p1")
        check("next request becomes head", q.head?.id, 2)
        check("remove unknown id", q.remove(id: 1)?.id, nil)
        check("remove a waiting request", q.remove(id: 3)?.id, 3)
        check("head kept", ids(q), [2])
        check("contains head", q.contains(id: 2), true)
        q.remove(id: 2)
        check("empty after last", q.isEmpty, true)

        // ── timeouts ────────────────────────────────────────────────────────────
        print("per-request timeout")
        q = Queue(capacity: 16)
        q.enqueue(entry(1, deadline: 100))
        q.enqueue(entry(2, session: "s2", deadline: 110))
        q.enqueue(entry(3, session: "s3", deadline: 105))
        check("nothing expires early", q.removeExpired(now: 99.9).map(\.id), [])
        check("head expires at its deadline", q.removeExpired(now: 100).map(\.id), [1])
        check("next becomes head", q.head?.id, 2)
        check("a waiting request expires on its own deadline", q.removeExpired(now: 106).map(\.id), [3])
        check("head untouched", ids(q), [2])
        check("several expire together, in queue order",
              { var r = Queue(capacity: 4)
                r.enqueue(entry(7, deadline: 5)); r.enqueue(entry(8, deadline: 1)); r.enqueue(entry(9, deadline: 50))
                return r.removeExpired(now: 10).map(\.id) }(), [UInt64]([7, 8]))

        // ── dismissal rules ─────────────────────────────────────────────────────
        print("dismissal by agent events")
        let e = entry(1)
        func resolves(_ event: String, pill: String = "integration_claude", session: String = "s1",
                      tool: String = "Bash", input: String = #"{"command":"ls"}"#) -> Bool {
            Queue.resolves(event: event, pillId: pill, sessionId: session, tool: tool, inputKey: input, entry: e)
        }
        check("PostToolUse of the same call", resolves("PostToolUse"), true)
        check("PostToolUseFailure of the same call", resolves("PostToolUseFailure"), true)
        check("PostToolUse of another input", resolves("PostToolUse", input: #"{"command":"pwd"}"#), false)
        check("PostToolUse of another tool", resolves("PostToolUse", tool: "Edit"), false)
        check("PostToolUse of another session", resolves("PostToolUse", session: "s2"), false)
        for event in ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"] {
            check("\(event) of the same session", resolves(event, tool: "", input: ""), true)
            check("\(event) of another session", resolves(event, session: "s2", tool: "", input: ""), false)
        }
        check("same session on another pill", resolves("Stop", pill: "agent_codex"), false)
        check("PreToolUse never resolves", resolves("PreToolUse"), false)
        check("Notification never resolves", resolves("Notification"), false)

        print("removeResolved")
        q = Queue(capacity: 16)
        q.enqueue(entry(1, session: "a"))
        q.enqueue(entry(2, session: "b"))
        q.enqueue(entry(3, session: "a", tool: "Edit", input: "{}"))
        q.enqueue(entry(4, pill: "agent_codex", session: "a"))
        check("Stop removes every request of that session and pill",
              q.removeResolved(event: "Stop", pillId: "integration_claude", sessionId: "a", tool: "", inputKey: "").map(\.id), [1, 3])
        check("others keep their order", ids(q), [2, 4])
        check("a waiting request can be resolved",
              q.removeResolved(event: "PostToolUse", pillId: "agent_codex", sessionId: "a",
                               tool: "Bash", inputKey: #"{"command":"ls"}"#).map(\.id), [4])
        check("unrelated event removes nothing",
              q.removeResolved(event: "PreToolUse", pillId: "integration_claude", sessionId: "b", tool: "Bash", inputKey: "").map(\.id), [])
        check("head left", ids(q), [2])

        // ── accept() recovery ───────────────────────────────────────────────────
        print("accept() recovery")
        check("EINTR retries", AcceptRecovery.forErrno(EINTR, consecutiveFailures: 1), .retry)
        check("ECONNABORTED retries", AcceptRecovery.forErrno(ECONNABORTED, consecutiveFailures: 1), .retry)
        check("EAGAIN retries", AcceptRecovery.forErrno(EAGAIN, consecutiveFailures: 1), .retry)
        check("EMFILE backs off", AcceptRecovery.forErrno(EMFILE, consecutiveFailures: 1), .backOff)
        check("ENFILE backs off", AcceptRecovery.forErrno(ENFILE, consecutiveFailures: 3), .backOff)
        check("ENOBUFS backs off", AcceptRecovery.forErrno(ENOBUFS, consecutiveFailures: 1), .backOff)
        check("EBADF restarts the listener", AcceptRecovery.forErrno(EBADF, consecutiveFailures: 1), .restartListener)
        check("EINVAL restarts the listener", AcceptRecovery.forErrno(EINVAL, consecutiveFailures: 1), .restartListener)
        check("ENOTSOCK restarts the listener", AcceptRecovery.forErrno(ENOTSOCK, consecutiveFailures: 1), .restartListener)
        check("endless transient errors restart the listener",
              AcceptRecovery.forErrno(EINTR, consecutiveFailures: AcceptRecovery.maxConsecutiveFailures), .restartListener)
        check("back-off starts at 50 ms", AcceptRecovery.backOffDelay(consecutiveFailures: 1), 0.05)
        check("back-off doubles", AcceptRecovery.backOffDelay(consecutiveFailures: 3), 0.2)
        check("back-off capped at 1 s", AcceptRecovery.backOffDelay(consecutiveFailures: 40), 1.0)
        check("restart starts at 0.5 s", AcceptRecovery.restartDelay(attempt: 1), 0.5)
        check("restart doubles", AcceptRecovery.restartDelay(attempt: 4), 4.0)
        check("restart capped at 30 s", AcceptRecovery.restartDelay(attempt: 100), 30.0)

        print("")
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All pending request queue tests passed.")
    }
}
