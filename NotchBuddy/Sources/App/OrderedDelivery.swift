import Foundation

/// Hands messages to a handler in arrival order when handling one may first need work done
/// elsewhere (HookServer: a big Edit's diff, computed off the main thread).
///
/// The handler calls `hold()` while it handles a message whose work goes async; until the
/// matching `resume(to:)`, every new message waits in a backlog. `resume` then hands the
/// backlog over in order, and stops again if one of those messages holds. So a later hook
/// event never overtakes an earlier one, and only the messages behind a pending diff wait.
///
/// Not thread-safe: used on one queue (HookServer keeps it on the main actor).
final class OrderedDelivery<Message> {
    private(set) var isHeld = false
    private var backlog: [Message] = []
    private var backlogStart = 0

    init() {}

    /// The number of messages waiting behind a hold.
    var waitingCount: Int { backlog.count - backlogStart }

    /// Handles `message` now, or queues it behind the message being held.
    func submit(_ message: Message, to handle: (Message) -> Void) {
        if isHeld {
            backlog.append(message)
        } else {
            handle(message)
        }
    }

    /// Called by the handler, while it handles a message, when that message finishes later.
    func hold() {
        isHeld = true
    }

    /// Ends the hold, then handles the waiting messages in order until one holds again.
    func resume(to handle: (Message) -> Void) {
        isHeld = false
        while !isHeld && backlogStart < backlog.count {
            let next = backlog[backlogStart]
            backlogStart += 1
            handle(next)
        }
        if backlogStart == backlog.count {
            backlog.removeAll(keepingCapacity: true)
            backlogStart = 0
        }
    }
}
