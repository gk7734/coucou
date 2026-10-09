import Foundation

// MARK: - SessionAlert
//
// Something about an agent session the user may want to hear about outside the notch.
// HookServer (and the stall monitor) post them; SessionAlertCenter decides whether to show a
// macOS notification.

struct SessionAlert: Equatable, Sendable {
    enum Kind: String, Sendable {
        case finished, error, waitingApproval, waitingAnswer, stalled
    }
    var kind: Kind
    var pillId: String
    var sessionId: String
    /// "Claude Code", "Codex"…
    var agentName: String
    var projectName: String
    /// The app the session runs in (IDE or terminal), when known.
    var hostBundleId: String?
    /// One line: the final answer, the error, the command waiting for approval, the question.
    var detail: String
}

@MainActor
final class SessionAlertCenter {
    static let shared = SessionAlertCenter()
    private init() {}

    /// Called on the main actor for every alert-worthy session event.
    func post(_ alert: SessionAlert) {
        // Implemented by the macOS notifications feature.
    }
}
