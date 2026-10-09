import Foundation
import Darwin
import AppKit
import SwiftUI
import CryptoKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, every message then handed to the main
// queue in the order its read finished (see deliver(_:)).

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String {
        #if APPSTORE
        // Container home root keeps path ≤ 103 bytes (sun_path limit on macOS is 104 incl. NUL)
        // /Users/louis/Library/Containers/fr.louisraille.Coucou/Data/nb.sock = 66 bytes ✓
        return NSHomeDirectory() + "/nb.sock"
        #else
        return supportDir.appendingPathComponent("nb.sock").path
        #endif
    }
    // hookScriptPath is only used by the non-App Store build.
    // App Store build derives the command from the panel-selected claudeURL in buildHooksData(claudeURL:).
    static var hookScriptPath: String { supportDir.appendingPathComponent("nb-hook").path }

    private static let maxPayload = 1_048_576          // 1 MB — reject oversized messages
    private static let receiveTimeoutSeconds: Int = 5   // SO_RCVTIMEO on client sockets
    private static let maxConnections = 32              // open client connections, held ones included
    // Held requests stay under maxConnections so short-lived events always find a slot.
    private static let maxQueuedApprovals = 16
    private static let maxQueuedQuestions = 8

    private let connectionLock = NSLock()
    private var connectionCount = 0                     // guarded by connectionLock

    /// A PermissionRequest connection held open while the user decides.
    private struct HeldApproval {
        let fd: Int32
        let source: any DispatchSourceRead           // fires on hang-up; its cancel handler closes fd
        let info: ApprovalInfo
        let projectName: String
        let cwd: String
        let hostApp: String?
        let bundleId: String
    }
    /// An AskUserQuestion connection held open while the user answers.
    private struct HeldQuestion {
        let fd: Int32
        let source: any DispatchSourceRead
        let question: AskQuestion
        let recapSessionId: String
        let projectName: String
        let cwd: String
        let hostApp: String?
        let bundleId: String
    }

    // Pending requests, oldest first. Only the head is shown (AppState.pendingApproval /
    // pendingQuestion); the next one appears when it is resolved.
    @MainActor private var approvals = PendingRequestQueue<HeldApproval>(capacity: maxQueuedApprovals)
    @MainActor private var questions = PendingRequestQueue<HeldQuestion>(capacity: maxQueuedQuestions)
    @MainActor private var presentedApprovalId: UInt64? = nil   // queue entry on screen
    @MainActor private var presentedQuestionId: UInt64? = nil
    @MainActor private var nextRequestId: UInt64 = 1

    /// True when a real nb-hook connection is holding an approval open.
    @MainActor var hasRealPendingApproval: Bool { !approvals.isEmpty }
    /// True when a real nb-hook connection is holding a question open.
    @MainActor var hasRealPendingQuestion: Bool { !questions.isEmpty }
    @MainActor private var focusBeforeQuestion: String? = nil    // saved focus to restore after the questions
    @MainActor private var focusBeforeApproval: String? = nil    // saved focus to restore after the approvals

    private init() {}

    /// Monotonic seconds, the clock of the queues' deadlines (same as DispatchTime).
    private static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    @MainActor
    private func makeRequestId() -> UInt64 {
        defer { nextRequestId += 1 }
        return nextRequestId
    }

    // MARK: - Held connection helpers

    /// Closes a client connection and frees its slot under maxConnections.
    private func closeClient(_ fd: Int32) {
        close(fd)
        connectionLock.lock(); connectionCount -= 1; connectionLock.unlock()
    }

    /// Watches a held fd on the main queue: `onHangUp` runs when the relay closes it
    /// (the editor or terminal answered). Cancelling the source closes the fd — never close
    /// a held fd anywhere else (Apple requires it to happen in the cancel handler).
    @MainActor
    private func makeHoldSource(fd: Int32, onHangUp: @escaping @MainActor () -> Void) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onHangUp() } }
        source.setCancelHandler { [self] in closeClient(fd) }
        source.resume()
        return source
    }

    /// Ends a held connection: writes `line` (if any) off the main thread, then cancels the
    /// source, whose cancel handler closes the fd. Without a line the relay reads EOF and
    /// prints nothing, so the agent asks in its own terminal.
    @MainActor
    private func finishHeld(fd: Int32, source: any DispatchSourceRead, line: String?) {
        guard let line else { source.cancel(); return }
        Task.detached { [weak self] in
            self?.sendLine(fd: fd, text: line)
            DispatchQueue.main.async { source.cancel() }
        }
    }

    /// Answers a connection that is not held (not queued, no source) and closes it.
    private func answerAndClose(fd: Int32, line: String) {
        Task.detached { [weak self] in
            self?.sendLine(fd: fd, text: line)
            self?.closeClient(fd)
        }
    }

    // MARK: - Approval queue

    /// "Handled in Cursor." … — shown when the request was answered outside the notch.
    @MainActor
    private func handledNote(pillId: String) -> String {
        switch pillId {
        case "agent_cursor":  return "Handled in Cursor."
        case "agent_codex":   return "Handled in Codex."
        case "agent_copilot": return "Handled in Copilot CLI."
        case "agent_muse":    return "Handled in Muse Code."
        case "agent_hermes":  return "Handled in Hermes."
        default:              return "Handled in \(claudeHostName)."
        }
    }

    /// "Still waiting in Cursor." … — shown when the app gives up and the agent asks itself.
    @MainActor
    private func stillWaitingNote(pillId: String) -> String {
        switch pillId {
        case "agent_cursor":  return "Still waiting in Cursor."
        case "agent_codex":   return "Still waiting in Codex."
        case "agent_copilot": return "Still waiting in Copilot CLI."
        case "agent_muse":    return "Still waiting in Muse Code."
        case "agent_hermes":  return "Still waiting in Hermes."
        default:              return "Still waiting in \(claudeHostName)."
        }
    }

    /// Shows the head of the approval queue if it is not on screen yet.
    @MainActor
    private func presentApprovalHeadIfNeeded() {
        guard let head = approvals.head, head.id != presentedApprovalId else { return }
        presentedApprovalId = head.id
        let state = AppState.shared
        let held = head.payload
        let pillId = head.pillId
        upsertWorkspaceTask(id: pillId, projectName: held.projectName, cwd: held.cwd, hostApp: held.hostApp, bundleId: held.bundleId)
        state.updateTask(id: pillId, state: .approval)
        state.pendingApproval = held.info
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond.
        // Save current focus so we can restore it when the last card is dismissed.
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .approval)
    }

    /// Takes the card of a request that just left the queue off screen. With another request
    /// waiting, the caller presents it next (presentApprovalHeadIfNeeded), so the note,
    /// collapse and focus restore are skipped.
    @MainActor
    private func closeApprovalCard(pillId: String, note: String?) {
        presentedApprovalId = nil
        let state = AppState.shared
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        guard approvals.isEmpty else { return }
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        if let note {
            state.noteMessage = note
            state.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        } else {
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }

    /// The relay closed a held approval: the editor or terminal answered it.
    @MainActor
    private func approvalHungUp(id: UInt64) {
        guard let entry = approvals.remove(id: id) else { return }
        entry.payload.source.cancel()
        if entry.id == presentedApprovalId {
            closeApprovalCard(pillId: entry.pillId, note: handledNote(pillId: entry.pillId))
        }
        presentApprovalHeadIfNeeded()
    }

    /// Gives up on approvals past their deadline, sending no decision: the relay prints
    /// nothing and the agent asks in its terminal (Copilot's relay prints "ask").
    @MainActor
    private func expireApprovals() {
        // Half a second of slack: entries due together are handled by the same pass.
        let expired = approvals.removeExpired(now: Self.monotonicNow() + 0.5)
        for entry in expired {
            entry.payload.source.cancel()
            nbLog("PermissionRequest timed out \(entry.tool) [\(entry.pillId)]")
            if entry.id == presentedApprovalId {
                closeApprovalCard(pillId: entry.pillId, note: stillWaitingNote(pillId: entry.pillId))
            }
        }
        presentApprovalHeadIfNeeded()
    }

    // MARK: - Question queue

    /// Shows the head of the question queue if it is not on screen yet.
    @MainActor
    private func presentQuestionHeadIfNeeded() {
        guard let head = questions.head, head.id != presentedQuestionId else { return }
        presentedQuestionId = head.id
        let state = AppState.shared
        let held = head.payload
        let pillId = head.pillId
        upsertWorkspaceTask(id: pillId, projectName: held.projectName, cwd: held.cwd, hostApp: held.hostApp, bundleId: held.bundleId)
        state.updateTask(id: pillId, state: .question)
        state.pendingQuestion = held.question
        state.isPinned = true
        SoundEngine.shared.play("approval")

        if focusBeforeQuestion == nil { focusBeforeQuestion = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .question)
    }

    /// Takes the card of a question that just left the queue off screen; the caller presents
    /// the next one, if any.
    @MainActor
    private func closeQuestionCard(pillId: String) {
        presentedQuestionId = nil
        let state = AppState.shared
        state.pendingQuestion = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        guard questions.isEmpty else { return }
        if let prev = focusBeforeQuestion {
            focusBeforeQuestion = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// Removes the question on screen from the queue, nil if there is none.
    @MainActor
    private func takePresentedQuestion() -> PendingRequestQueue<HeldQuestion>.Entry? {
        guard let id = presentedQuestionId else { return nil }
        return questions.remove(id: id)
    }

    @MainActor
    private func questionHungUp(id: UInt64) {
        guard let entry = questions.remove(id: id) else { return }
        entry.payload.source.cancel()
        if entry.id == presentedQuestionId { closeQuestionCard(pillId: entry.pillId) }
        presentQuestionHeadIfNeeded()
    }

    /// Questions past their deadline get "ask" so nb-hook exits cleanly; Claude Code re-asks in the terminal.
    @MainActor
    private func expireQuestions() {
        let expired = questions.removeExpired(now: Self.monotonicNow() + 0.5)
        for entry in expired {
            finishHeld(fd: entry.payload.fd, source: entry.payload.source, line: #"{"permissionDecision":"ask"}"#)
            if entry.id == presentedQuestionId { closeQuestionCard(pillId: entry.pillId) }
        }
        presentQuestionHeadIfNeeded()
    }

    /// Called by QuestionView. Sends answers JSON and cleans up.
    @MainActor
    func sendQuestionAnswers(_ answers: [String: Any]) {
        // Only intercept a demo question — real questions always have a live fd.
        if DemoEngine.shared.isActive, questions.isEmpty {
            AppState.shared.pendingQuestion = nil
            AppState.shared.isPinned = false
            AppState.shared.view = AppState.shared.tasks.isEmpty ? .empty : .overview
            DemoEngine.shared.handleQuestionAnswered(answers: answers)
            return
        }
        let entry = takePresentedQuestion()
        if let entry {
            let line = (try? JSONSerialization.data(withJSONObject: ["permissionDecision": "answer", "answers": answers], options: .withoutEscapingSlashes))
                .flatMap { String(data: $0, encoding: .utf8) }
            finishHeld(fd: entry.payload.fd, source: entry.payload.source, line: line)
            if !entry.payload.recapSessionId.isEmpty {
                RecapStore.shared.recordQuestionAnswered(sessionId: entry.payload.recapSessionId)
            }
        }
        closeQuestionCard(pillId: entry?.pillId ?? "integration_claude")
        presentQuestionHeadIfNeeded()
    }

    /// Called by QuestionView.onDisappear — card left screen without an explicit answer.
    /// Sends "ask" immediately to unblock nb-hook; does NOT navigate (view already changed),
    /// unless another question is waiting, which is shown next.
    @MainActor
    func releaseQuestionFD() {
        guard let entry = takePresentedQuestion() else { return }
        presentedQuestionId = nil
        AppState.shared.pendingQuestion = nil
        finishHeld(fd: entry.payload.fd, source: entry.payload.source, line: #"{"permissionDecision":"ask"}"#)
        presentQuestionHeadIfNeeded()
    }

    /// Called by QuestionView "Reply in terminal" button.
    @MainActor
    func sendQuestionAsk() {
        let entry = takePresentedQuestion()
        if let entry {
            finishHeld(fd: entry.payload.fd, source: entry.payload.source, line: #"{"permissionDecision":"ask"}"#)
        }
        closeQuestionCard(pillId: entry?.pillId ?? "integration_claude")
        presentQuestionHeadIfNeeded()
    }

    /// Returns the tool_input serialized as sorted-keys JSON, "" if absent or empty.
    /// Same computation used in processPermissionRequest and processEvent to match PostToolUse.
    private static func approvalInputKey(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    // MARK: - Start

    func start() {
        // Ensure support directory exists (mode 0700 — not world-readable)
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private enum ListenerResult {
        case ready(Int32)
        case failed          // worth trying again later
        case unusable        // will never work (path too long)
    }

    /// Runs for the life of the app: creates the listening socket and accepts on it; if the
    /// socket breaks, closes it and creates a new one after a short, growing delay.
    private func serverThread() {
        var attempt = 0
        while true {
            switch openListener() {
            case .unusable:
                return
            case .failed:
                break
            case .ready(let fd):
                let acceptedAny = acceptLoop(listener: fd)
                close(fd)
                if acceptedAny { attempt = 0 }
                NSLog("HookServer: listening socket failed, recreating it")
            }
            attempt += 1
            Thread.sleep(forTimeInterval: AcceptRecovery.restartDelay(attempt: attempt))
        }
    }

    /// Creates, binds and listens on the Unix socket (owner-only).
    private func openListener() -> ListenerResult {
        let path = Self.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return .unusable
        }
        // The folder may have been deleted since launch; a new one is owner-only.
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700 as NSNumber])
        try? FileManager.default.removeItem(atPath: path)

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
        guard Darwin.listen(fd, 32) == 0 else {
            NSLog("HookServer: listen() failed, errno \(errno)")
            close(fd)
            return .failed
        }
        return .ready(fd)
    }

    /// Accepts clients until the listening socket breaks. Transient errors are retried,
    /// descriptor shortages wait a little; one failed accept() never ends the server.
    /// Returns true if at least one client was accepted.
    private func acceptLoop(listener fd: Int32) -> Bool {
        var acceptedAny = false
        var failures = 0
        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                let code = errno
                failures += 1
                switch AcceptRecovery.forErrno(code, consecutiveFailures: failures) {
                case .retry:
                    continue
                case .backOff:
                    if failures == 1 { NSLog("HookServer: accept() out of resources, errno \(code)") }
                    Thread.sleep(forTimeInterval: AcceptRecovery.backOffDelay(consecutiveFailures: failures))
                    continue
                case .restartListener:
                    NSLog("HookServer: accept() failed, errno \(code)")
                    return acceptedAny
                }
            }
            failures = 0
            acceptedAny = true
            // Reject connections from other users (same-UID check)
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else {
                close(clientFD)
                continue
            }
            // Enforce the connection ceiling. The slot is freed by closeClient, when the fd
            // closes — after handleClient for plain events, when the user decides for held requests.
            connectionLock.lock()
            let count = connectionCount
            if count < Self.maxConnections { connectionCount += 1 }
            connectionLock.unlock()
            guard count < Self.maxConnections else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    /// A fully read hook message, on its way to the main actor.
    /// @unchecked: the payload is a fresh JSONSerialization tree, never mutated after parsing.
    private enum HookMessage: @unchecked Sendable {
        case statusLine(payload: [String: Any])
        case question(fd: Int32, parsed: AskQuestion, payload: [String: Any])
        case permission(fd: Int32, payload: [String: Any])
        case event(name: String, payload: [String: Any])
    }

    /// Hands a message to the main actor. DispatchQueue.main is one serial FIFO queue, so
    /// messages are processed in the order their reads finished: a session's PreToolUse is
    /// always handled before its PostToolUse. (One `Task { @MainActor }` per connection gives
    /// no such ordering guarantee between tasks.)
    private func deliver(_ message: HookMessage) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.route(message) }
        }
    }

    @MainActor
    private func route(_ message: HookMessage) {
        switch message {
        case .statusLine(let payload):              processStatusLine(payload: payload)
        case .question(let fd, let parsed, let payload): processQuestionRequest(fd: fd, parsed: parsed, payload: payload)
        case .permission(let fd, let payload):      processPermissionRequest(fd: fd, payload: payload)
        case .event(let name, let payload):         processEvent(name: name, payload: payload)
        }
    }

    private func handleClient(fd: Int32) {
        // Held requests (approvals, questions) keep the fd and its connection slot until the
        // user decides; everything else is answered and closed here.
        var heldOpen = false
        defer { if !heldOpen { closeClient(fd) } }
        // 5-second receive timeout — unresponsive clients don't hold threads forever
        var tv = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read newline-delimited JSON
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
            if raw.count > Self.maxPayload { break }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            return
        }

        let coucouKind = payload["coucou_kind"] as? String ?? ""

        // statusline payloads are handled separately — no session, no reveal, no sound
        if coucouKind == "statusline" {
            deliver(.statusLine(payload: payload))
            sendLine(fd: fd, text: #"{"ok":true}"#)
            return
        }

        // AskUserQuestion via --ask PreToolUse hook — hold fd open like PermissionRequest
        if coucouKind == "ask_user_question" {
            let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let parsed = AskQuestion.parse(toolInput: toolInput) {
                heldOpen = true
                deliver(.question(fd: fd, parsed: parsed, payload: payload))
            } else {
                // Malformed payload — fall back: send ask so Claude Code re-asks in terminal
                sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
            }
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            heldOpen = true
            deliver(.permission(fd: fd, payload: payload))
        } else {
            deliver(.event(name: eventName, payload: payload))
            sendLine(fd: fd, text: #"{"ok":true}"#)
        }
    }

    // MARK: - Event → AppState
    // Claude Code events route to the permanent "integration_claude" task.
    // Events tagged with a valid coucou_agent route to a dynamic "integration_<agent>" task.
    // View switches only happen if VS Code (or the agent pill) is currently focused.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        // Determine which pill this event belongs to.
        // coucou_agent must be lowercase, digits and hyphens, ≤ 24 chars.
        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let validAgent = Self.validateAgent(rawAgent)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""

        // Cursor identified solely by its stable Electron bundle ID.
        // ToDesktop builds other apps too — do not match on "todesktop" alone.
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))

        // Routing:
        // • "codex" → agent_codex (GitHub build only: workspace pill, approvals in the notch)
        // • other valid coucou_agent → external pill (fire-and-forget, no approval card)
        // • Cursor bundle ID → agent_cursor
        // • VS Code → integration_claude
        // • a known terminal (Warp, Terminal, iTerm…) → integration_claude, host recorded on the task
        #if !APPSTORE
        let isCodexEvent = rawAgent == "codex"
        #else
        let isCodexEvent = false
        #endif
        let agentId: String
        let isExternalAgent: Bool
        var hostApp: String? = nil
        if isCodexEvent {
            agentId = "agent_codex"
            isExternalAgent = false
        } else if let agent = validAgent {
            agentId = "agent_\(agent)"
            isExternalAgent = true
        } else if isCursorEditor {
            agentId = "agent_cursor"
            isExternalAgent = false
        } else if isVSCodeEditor {
            agentId = "integration_claude"
            isExternalAgent = false
        } else if let host = ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId) {
            agentId = "integration_claude"
            isExternalAgent = false
            hostApp = host.bundleId
        } else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == agentId
        // For sessions that carry no id, derive a unique key from pill + cwd so that
        // concurrent anonymous sessions are tracked independently in RecapStore.
        let recapSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(agentId)+\(cwd)"
            : sessionId

        #if PHONE_LINK
        // The iPhone's "last turn" (prompt, actions, diffs, answer).
        if !isExternalAgent { TurnRecorder.shared.record(event: name, payload: payload, pillId: agentId) }
        #endif

        // A request answered in the editor or terminal (this exact tool call finished, or the
        // turn ended — see PendingRequestQueue.resolves) leaves the approval queue: waiting
        // requests go silently, the card on screen shows a note. While the card's pill is still
        // waiting, its other events are skipped so they don't overwrite the approval state.
        // Otherwise processing continues, then the next waiting request is shown.
        if !approvals.isEmpty {
            let isToolEnd = name == "PostToolUse" || name == "PostToolUseFailure"
            let resolved = approvals.removeResolved(
                event: name, pillId: agentId, sessionId: sessionId,
                tool: isToolEnd ? (payload["tool_name"] as? String ?? "") : "",
                inputKey: isToolEnd ? Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]) : "")
            var headResolved = false
            for entry in resolved {
                entry.payload.source.cancel()
                if entry.id == presentedApprovalId {
                    headResolved = true
                    closeApprovalCard(pillId: entry.pillId, note: handledNote(pillId: entry.pillId))
                }
            }
            if !headResolved, let head = approvals.head, head.id == presentedApprovalId, head.pillId == agentId {
                return
            }
        }
        defer { presentApprovalHeadIfNeeded() }

        switch name {

        case "SessionStart":
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd, hostApp: hostApp, bundleId: bundleId) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")
            if agentId == "agent_hermes", let platform = payload["platform"] as? String,
               !platform.isEmpty, platform != "cli" {
                let capitalized = platform.prefix(1).uppercased() + platform.dropFirst()
                appendStep(id: agentId, step: String(capitalized))
            }

        case "UserPromptSubmit":
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd, hostApp: hostApp, bundleId: bundleId) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.updateTask(id: agentId, state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: agentId, step: String(prompt.prefix(60)))
            }
            RecapStore.shared.userPromptSubmit(sessionId: recapSessionId, pillId: agentId, project: projectName)
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            let tool = payload["tool_name"] as? String ?? "Tool"
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            RecapStore.shared.preToolUse(sessionId: recapSessionId, tool: tool)
            // AskUserQuestion is handled via the dedicated --ask hook.
            // Skip state/step update here to avoid flickering over the question card.
            guard tool != "AskUserQuestion" else { break }
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd, hostApp: hostApp, bundleId: bundleId) }
            state.updateTask(id: agentId, state: .working)
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = localizedStep(tool: tool, input: input)
            appendStep(id: agentId, step: step)
            nbLog("PreToolUse \(tool)")

        case "PostToolUse":
            state.updateTask(id: agentId, state: .working)
            // Live diff for Edit / MultiEdit / Write
            let diffTool = payload["tool_name"] as? String ?? ""
            let diffInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let diff = buildFileDiff(tool: diffTool, input: diffInput, pillId: agentId) {
                let idx = state.appendSessionDiff(diff, for: agentId)
                let step = String.makeDiffStep(filename: diff.name, added: diff.added, removed: diff.removed, diffId: idx)
                appendStep(id: agentId, step: step)
                RecapStore.shared.recordFileDiff(sessionId: recapSessionId, path: diff.name, added: diff.added, removed: diff.removed)
            }

        case "PostToolUseFailure":
            state.updateTask(id: agentId, state: .working)
            appendStep(id: agentId, step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: agentId, state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: agentId, state: .question)
                appendStep(id: agentId, step: message)
            }

        case "Stop":
            state.updateTask(id: agentId, state: .finished)
            let rawFinal = (payload["last_assistant_message"] as? String)
                ?? (payload["message"] as? String) ?? ""
            let finalText = DiffEngine.toOneLine(rawFinal)
            if !finalText.isEmpty {
                appendStep(id: agentId, step: finalText)
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                    state.tasks[idx].finalLine = finalText
                }
            }
            RecapStore.shared.stop(sessionId: recapSessionId)
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: agentId, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                if isExternalAgent {
                    AppState.shared.removeTask(id: agentId)
                } else {
                    AppState.shared.updateTask(id: agentId, state: .idle)
                    self.clearPillBadge(id: agentId)
                }
            }

        case "StopFailure":
            RecapStore.shared.stop(sessionId: recapSessionId)
            state.updateTask(id: agentId, state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: agentId, badge: .error)
            }

        case "Interrupt":
            // Codex: user stopped the turn
            RecapStore.shared.stop(sessionId: recapSessionId)
            state.updateTask(id: agentId, state: .idle)
            clearPillBadge(id: agentId)

        case "SessionEnd":
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.clearSessionDiffs(for: agentId)
            state.removeTask(id: agentId)
            RecapStore.shared.sessionEnd(sessionId: recapSessionId)

        case "SubagentStart":
            appendStep(id: agentId, step: "+ subagent")

        case "SubagentStop":
            appendStep(id: agentId, step: "• subagent done")

        default:
            break
        }
    }

    // MARK: - Agent validation + dynamic pill

    /// Validates a coucou_agent name: lowercase, digits and hyphens, 1–24 chars.
    /// "claude" is reserved and rejected so it cannot impersonate the Claude Code pill.
    /// Returns the name unchanged if valid, nil otherwise.
    private static func validateAgent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24, raw != "claude" else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)  // a-z
                  || (v >= 0x30 && v <= 0x39)   // 0-9
                  || v == 0x2D                   // -
            guard ok else { return nil }
        }
        return raw
    }

    /// Creates a dynamic pill for a third-party agent on first event, then no-ops.
    /// ID format: "agent_<name>" — never collides with "integration_*" pills.
    /// Inserted right after integration_claude so it appears in the visible prefix(4).
    @MainActor
    private func upsertExternalAgent(id: String, name: String) {
        let state = AppState.shared
        guard state.tasks.firstIndex(where: { $0.id == id }) == nil else { return }
        let color: String
        if let def = PillCatalog.definition(for: id) {
            color = def.color
        } else {
            color = IslandConst.colorForProject(name)
        }
        let task = AgentTask(id: id, name: name, color: color, state: .idle, steps: [], source: .agent)
        if let claudeIdx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) {
            state.tasks.insert(task, at: claudeIdx + 1)
        } else {
            state.tasks.append(task)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .question, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Approval and question always win; other alerts are blocked while a card is showing
            if view == .approval || view == .question {
                state.view = view
            } else if isAlert && state.pendingApproval == nil {
                state.view = view
            }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Status line (plan gauge)

    @MainActor
    private func processStatusLine(payload: [String: Any]) {
        if let usage = ClaudePlanGauge.parse(payload: payload) {
            AppState.shared.claudePlanUsage = usage
        }
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))

        // Codex, Copilot CLI and Muse Code get the same approval card as Claude Code / Cursor.
        // Other external agents (any other coucou_agent) answer immediately with "ask"
        // so the agent re-asks in its own terminal — they do not get a notch card.
        #if !APPSTORE
        let isCodexRequest   = rawAgent == "codex"
        let isCopilotRequest = rawAgent == "copilot"
        let isMuseRequest    = rawAgent == "muse"
        // isHermesRequest is true only when the plugin sent coucou_has_transport: true,
        // meaning register_approval_transport is wired and Hermes will honour our choice.
        // Without that flag the request falls through to "ask" so Hermes handles it natively.
        let isHermesRequest  = rawAgent == "hermes"
            && UserDefaults.standard.bool(forKey: "hermesApprovalsEnabled")
            && (payload["coucou_has_transport"] as? Bool == true)
        #else
        let isCodexRequest   = false
        let isCopilotRequest = false
        let isMuseRequest    = false
        let isHermesRequest  = false
        #endif
        if !isCodexRequest && !isCopilotRequest && !isMuseRequest && !isHermesRequest && Self.validateAgent(rawAgent) != nil {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }

        // Determine which workspace pill owns the request.
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCopilotRequest {
            pillId = "agent_copilot"
        } else if isMuseRequest {
            pillId = "agent_muse"
        } else if isHermesRequest {
            pillId = "agent_hermes"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else {
            pillId = "integration_claude"
        }
        // Terminal sessions: only when turned on in Settings, else the terminal asks itself.
        let terminalHost = isCursorEditor || isVSCodeEditor ? nil
            : ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId)
        let isTerminal = terminalHost != nil && ClaudeHost.terminalCardsEnabled
        guard isCodexRequest || isCopilotRequest || isMuseRequest || isHermesRequest || isCursorEditor || isVSCodeEditor || isTerminal else {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let inputKey = Self.approvalInputKey(toolInput)
        nbLog("PermissionRequest \(tool) [\(pillId)]")

        // AskUserQuestion is now handled via the dedicated --ask PreToolUse hook.
        // If it still arrives here as a PermissionRequest, reply "ask" so Claude Code
        // re-asks in the terminal — never show the question twice.
        if tool == "AskUserQuestion" {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }

        // Too many requests already waiting: let the agent ask in its own terminal.
        guard !approvals.isFull else {
            nbLog("PermissionRequest queue full, answered ask")
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }

        let command = toolInput["command"] as? String ?? tool
        let info = ApprovalInfo(sessionId: sessionId, tool: tool,
                                command: command, inputKey: inputKey, pillId: pillId)

        // Safety timeout, counted from arrival even while the request waits behind others:
        // the app gives up before the relay (118 s) so the agent re-asks in its terminal.
        // Copilot/Muse use 110s (their relay waits 118s but their hook timeout is 120s, leaving little margin).
        let waitTimeout: Double = (isCopilotRequest || isMuseRequest) ? 110 : 115
        let id = makeRequestId()
        // Monitor fd: if the editor closes the connection (handled externally), drop the request.
        let source = makeHoldSource(fd: fd) { [weak self] in self?.approvalHungUp(id: id) }
        approvals.enqueue(.init(id: id, pillId: pillId, sessionId: sessionId, tool: tool, inputKey: inputKey,
                                deadline: Self.monotonicNow() + waitTimeout,
                                payload: HeldApproval(fd: fd, source: source, info: info, projectName: projectName,
                                                      cwd: cwd, hostApp: terminalHost?.bundleId, bundleId: bundleId)))
        if approvals.count > 1 { nbLog("PermissionRequest queued (\(approvals.count) waiting)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
            self?.expireApprovals()
        }
        presentApprovalHeadIfNeeded()
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        // Only intercept a demo card — a real card always has a held connection.
        if DemoEngine.shared.isActive,
           AppState.shared.pendingApproval?.sessionId == "demo_session",
           approvals.isEmpty {
            let s = AppState.shared
            s.pendingApproval = nil
            s.isPinned = false
            s.view = s.tasks.isEmpty ? .empty : .overview
            DemoEngine.shared.handleApprovalDecision(decision)
            return
        }

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        // The decision answers the card on screen — the head of the queue.
        if let id = presentedApprovalId, let entry = approvals.remove(id: id) {
            // Write decision while fd is still valid, then cancel source → cancel handler closes fd
            finishHeld(fd: entry.payload.fd, source: entry.payload.source, line: json)
        }

        let pillId = AppState.shared.pendingApproval?.pillId ?? "integration_claude"
        RecapStore.shared.recordDecision(pillId: pillId, decision: decision)
        closeApprovalCard(pillId: pillId, note: nil)
        presentApprovalHeadIfNeeded()
    }

    // MARK: - Question request

    @MainActor
    private func processQuestionRequest(fd: Int32, parsed: AskQuestion, payload: [String: Any]) {
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent    = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"]  as? String ?? ""
        let bundleId    = payload["bundle_id"]     as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        #if !APPSTORE
        let isCodexRequest = rawAgent == "codex"
        #else
        let isCodexRequest = false
        #endif
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else {
            pillId = "integration_claude"
        }
        // Terminal sessions: only when turned on in Settings, else the terminal asks itself.
        let terminalHost = isCursorEditor || isVSCodeEditor ? nil
            : ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId)
        let isTerminal = terminalHost != nil && ClaudeHost.terminalCardsEnabled
        guard isCodexRequest || isCursorEditor || isVSCodeEditor || isTerminal else {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }
        // Too many questions already waiting: Claude Code asks in the terminal.
        guard !questions.isFull else {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }

        let recapSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(pillId)+\(cwd)"
            : sessionId
        let id = makeRequestId()
        let source = makeHoldSource(fd: fd) { [weak self] in self?.questionHungUp(id: id) }
        questions.enqueue(.init(id: id, pillId: pillId, sessionId: sessionId, tool: "AskUserQuestion", inputKey: "",
                                deadline: Self.monotonicNow() + 120,
                                payload: HeldQuestion(fd: fd, source: source, question: parsed,
                                                      recapSessionId: recapSessionId, projectName: projectName,
                                                      cwd: cwd, hostApp: terminalHost?.bundleId, bundleId: bundleId)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.expireQuestions()
        }
        presentQuestionHeadIfNeeded()
    }


    /// "VS Code", "Warp"… — where the Claude Code pill's current session runs.
    @MainActor
    private var claudeHostName: String {
        ClaudeHost.name(for: AppState.shared.tasks.first { $0.id == "integration_claude" }?.hostApp)
    }

    /// Updates or transiently creates a workspace pill (VS Code or Cursor) task.
    /// If the task already exists (persistent), just updates name/cwd.
    /// If missing (transient), creates it and inserts after the main pill.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "", hostApp: String? = nil, bundleId: String = "") {
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[idx].name = projectName
            if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
            if id == "integration_claude" { state.tasks[idx].hostApp = hostApp }
            if !bundleId.isEmpty { state.tasks[idx].sessionBundleId = bundleId }
            return
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        var task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
        if id == "integration_claude" { task.hostApp = hostApp }
        if !bundleId.isEmpty { task.sessionBundleId = bundleId }
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - Localized step labels

    private func localizedStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":         String(localized: "step.runs",       defaultValue: "Runs"),
            "Read":         String(localized: "step.reads",      defaultValue: "Reads"),
            "Write":        String(localized: "step.writes",     defaultValue: "Writes"),
            "Edit":         String(localized: "step.edits",      defaultValue: "Edits"),
            "Glob":         String(localized: "step.searches",   defaultValue: "Searches"),
            "Grep":         String(localized: "step.searches",   defaultValue: "Searches"),
            "WebSearch":    String(localized: "step.web-search", defaultValue: "Searches the web"),
            "WebFetch":     String(localized: "step.fetches",    defaultValue: "Fetches"),
            "TodoWrite":    String(localized: "step.tasks",      defaultValue: "Tasks"),
            "Task":         String(localized: "step.agent",      defaultValue: "Agent"),
            "LS":           String(localized: "step.lists",      defaultValue: "Lists"),
            "MultiEdit":    String(localized: "step.edits",      defaultValue: "Edits"),
            "NotebookEdit": String(localized: "step.notebook",   defaultValue: "Notebook"),
            // Codex tools
            "apply_patch":  String(localized: "step.edits",     defaultValue: "Edits"),
            "update_plan":  String(localized: "step.tasks",     defaultValue: "Tasks"),
            "spawn_agent":  String(localized: "step.agent",     defaultValue: "Agent"),
        ]
        var label = labels[tool] ?? tool

        // Codex MCP tools arrive as mcp__server__tool — show "server · tool"
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }

        // Bash: infer a more precise verb from the command
        if tool == "Bash", let cmd = input["command"] as? String {
            return "\(bashVerb(cmd)) · \(oneLine(cmd))"
        }

        // apply_patch: extract the first file name from the patch
        if tool == "apply_patch", let patch = input["command"] as? String {
            for line in patch.split(separator: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                    if line.hasPrefix(prefix) {
                        let path = String(line.dropFirst(prefix.count))
                        return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
                    }
                }
            }
            return label
        }

        if let cmd = input["command"] as? String {
            return "\(label) · \(oneLine(cmd))"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(oneLine(query))"
        }
        return label
    }

    /// Infers a localized verb from a shell command's first word.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return String(localized: "step.reads",    defaultValue: "Reads")
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return String(localized: "step.searches", defaultValue: "Searches")
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return String(localized: "step.tests", defaultValue: "Tests") }
        return String(localized: "step.runs", defaultValue: "Runs")
    }

    // MARK: - Live diff helpers

    @MainActor
    private func buildFileDiff(tool: String, input: [String: Any], pillId: String) -> FileDiff? {
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String,
                  let path = input["file_path"] as? String,
                  !old.isEmpty || !new.isEmpty else { return nil }
            let d = DiffEngine.fromEdit(old: old, new: new, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        case "MultiEdit":
            guard let path = input["file_path"] as? String,
                  let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var totalAdded = 0, totalRemoved = 0, allHunks: [DiffHunk] = [], anyLarge = false
            for edit in edits {
                guard let old = edit["old_string"] as? String,
                      let new = edit["new_string"] as? String else { continue }
                let d = DiffEngine.fromEdit(old: old, new: new, path: path)
                totalAdded += d.added; totalRemoved += d.removed
                allHunks.append(contentsOf: d.hunks); if d.tooLarge { anyLarge = true }
            }
            guard totalAdded > 0 || totalRemoved > 0 else { return nil }
            return FileDiff(path: path, added: totalAdded, removed: totalRemoved,
                            hunks: allHunks, tooLarge: anyLarge, isNewFile: false)

        case "Write":
            guard let path = input["file_path"] as? String,
                  let content = input["content"] as? String, !content.isEmpty else { return nil }
            let d = DiffEngine.fromNew(content: content, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        default:
            return nil
        }
    }

    /// Collapses whitespace so a multi-line command stays one ticker row.
    private func oneLine(_ text: String, limit: Int = 60) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        appendAppLog("nb.log", message)
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires NSOpenPanel to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        // nb-hook: shell wrapper (always exits 0, calls nb-hook.py via python3)
        let wrapperURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        // nb-hook.py: Python relay
        let pyURL = wrapperURL.deletingLastPathComponent().appendingPathComponent("nb-hook.py")
        try? nbHookPythonGitHub.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)
        #endif
    }

    // MARK: - Agent files: preview → confirm → write
    //
    // Every file Coucou changes for an agent goes through ClaudeSettingsFile: the preview
    // keeps the exact bytes it was computed from, and the write after the user's click is
    // refused if the file changed since; otherwise it backs the file up, writes beside it
    // and renames, keeps its permissions and follows a symlink. Which hooks are Coucou's
    // is decided by ClaudeHookDetection.swift, what is merged by AgentHookConfig.swift.

    /// One previewed change to a file, waiting for the user's confirmation.
    private struct PendingFileChange {
        let url: URL
        /// How the file is named in messages, e.g. "~/.gemini/settings.json".
        let label: String
        /// The new content, or nil to delete the file.
        let data: Data?
        /// The bytes the preview was computed from (nil = there was no file).
        let original: Data?
        /// Permissions of a file that did not exist yet.
        var newFileMode: Int = 0o600

        func commit() throws {
            if let data {
                guard data != original else { return }   // already as previewed — nothing to back up
                try ClaudeSettingsFile.write(data, to: url, expecting: original, label: label,
                                             newFileMode: newFileMode)
            } else {
                try ClaudeSettingsFile.remove(at: url, expecting: original, label: label)
            }
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The error the Settings view shows as a plain status, not as a failure.
    private static func noop(_ message: String) -> NSError {
        NSError(domain: "CoucouNoop", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A JSON object from a file, or nil when it is absent or unusable (installed-state checks only).
    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Claude Code settings.json hook installer

    private static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    /// The command Claude Code runs: the relay path, quoted (Application Support has a space).
    /// The App Store build goes through /bin/sh: sandboxed apps create quarantined files,
    /// and /bin/sh bypasses the quarantine flag.
    private static func claudeHookCommand(hookPath: String) -> String {
        let quoted = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #if APPSTORE
        return "/bin/sh \(quoted)"
        #else
        return quoted
        #endif
    }

    /// settings.json with Coucou's hooks (re)installed, and the bytes it was read from.
    /// Unreadable or invalid settings stop here, never count as empty.
    private static func claudeSettingsInstalling(at url: URL, command: String) throws -> (data: Data, original: Data?) {
        let snapshot = try ClaudeSettingsFile.read(at: url)
        let merged = try AgentHookConfig.claudeInstalling(into: snapshot.object, command: command,
                                                          name: url.lastPathComponent)
        return (try AgentHookConfig.encoded(merged, escapingSlashes: true), snapshot.bytes)
    }

    /// settings.json without Coucou's hooks, or nil when there are none to remove.
    private static func claudeSettingsRemoving(at url: URL) throws -> (data: Data, original: Data?)? {
        let snapshot = try ClaudeSettingsFile.read(at: url)
        guard let hooks = snapshot.object["hooks"] as? [String: Any], containsCoucouHook(inEvents: hooks),
              let cleaned = AgentHookConfig.claudeRemoving(from: snapshot.object) else { return nil }
        return (try AgentHookConfig.encoded(cleaned, escapingSlashes: true), snapshot.bytes)
    }

    /// Returns true if settings.json has a Coucou hook that needs updating:
    /// either a PermissionRequest hook with timeout < 120s, or the AskUserQuestion
    /// PreToolUse matcher is missing (requires Claude Code 2.1.85+).
    static func hooksNeedUpdate() -> Bool {
        guard let settings = jsonObject(at: claudeSettingsURL) else { return false }
        return coucouHooksNeedUpdate(inSettings: settings)
    }

    private var pendingClaudeHooks: PendingFileChange?
    /// Whether the pending Claude Code change installs the hooks (true) or removes them.
    private(set) var pendingClaudeHooksInstall = true

    /// Returns the new settings.json without writing — call writeClaudeHooks() to confirm.
    /// Removing when there is nothing of Coucou's throws a "CoucouNoop" error.
    func previewClaudeHooks(install: Bool = true) throws -> String {
        pendingClaudeHooks = nil
        let url = Self.claudeSettingsURL
        let change: (data: Data, original: Data?)
        if install {
            change = try Self.claudeSettingsInstalling(at: url, command: Self.claudeHookCommand(hookPath: Self.hookScriptPath))
        } else {
            guard let removed = try Self.claudeSettingsRemoving(at: url) else {
                throw Self.noop("No Coucou hooks to remove in ~/.claude/settings.json.")
            }
            change = removed
        }
        pendingClaudeHooks = PendingFileChange(url: url, label: "~/.claude/settings.json",
                                               data: change.data, original: change.original)
        pendingClaudeHooksInstall = install
        return String(data: change.data, encoding: .utf8) ?? ""
    }

    /// Writes the previewed settings.json (call after the user confirms the preview).
    /// Refused if settings.json changed since the preview, or cannot be backed up.
    func writeClaudeHooks() throws {
        try commit(&pendingClaudeHooks)
    }

    // MARK: - Claude plan status line installer

    private var statusLinePreviousURL: URL {
        Self.supportDir.appendingPathComponent("statusline-previous.json")
    }

    /// Returns true if our statusLine command is installed in ~/.claude/settings.json.
    static func statusLineInstalled() -> Bool {
        guard let settings = jsonObject(at: claudeSettingsURL),
              let sl = settings["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return CoucouHookCommand(cmd)?.mode == .statusLine
    }

    private var _pendingStatusLineData: Data?
    /// The bytes of settings.json the pending preview was computed from.
    private var _pendingStatusLineOriginal: Data?
    private var _pendingPreviousData: Data?
    private var _pendingDeletePrevious: Bool = false

    /// Returns a diff string (only the statusLine key: before → after) without writing anything.
    func previewStatusLine(install: Bool) throws -> String {
        let settingsURL = Self.claudeSettingsURL
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        let settings = snapshot.object
        let hookPath = Self.hookScriptPath
        let quotedPath = hookPath.replacingOccurrences(of: "\"", with: "\\\"")
        let quotedCmd = "\"\(quotedPath)\" --statusline"

        // Reset pending side-effects
        _pendingStatusLineData = nil
        _pendingStatusLineOriginal = nil
        _pendingPreviousData = nil
        _pendingDeletePrevious = false

        let oldSL = settings["statusLine"] as? [String: Any]
        let oldIsOurs = (oldSL?["command"] as? String).map { isCoucouHookCommand($0) } ?? false
        let newSL: [String: Any]?

        if install {
            // Check that Python 3 is available (requires Command Line Tools)
            let clCheck = Process()
            clCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            clCheck.arguments = ["-p"]
            clCheck.standardOutput = FileHandle.nullDevice
            clCheck.standardError = FileHandle.nullDevice
            try? clCheck.run()
            clCheck.waitUntilExit()
            if clCheck.terminationStatus != 0 {
                throw NSError(domain: "Coucou", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "Command Line Tools are required but not installed. Run: xcode-select --install"])
            }

            if let existing = oldSL, existing["command"] is String, !oldIsOurs {
                // Keep existing object but swap command; save old for later restoration
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
                _pendingPreviousData = try? JSONSerialization.data(withJSONObject: existing,
                                                                   options: [.prettyPrinted, .sortedKeys])
            } else if let existing = oldSL, oldIsOurs {
                // Already installed — rebuild to update path if needed, keep other fields
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
            } else {
                newSL = ["type": "command", "command": quotedCmd]
            }
        } else {
            // Uninstall: only if it's ours
            if oldIsOurs {
                if let prevData = try? Data(contentsOf: statusLinePreviousURL),
                   let prevObj = (try? JSONSerialization.jsonObject(with: prevData)) as? [String: Any] {
                    newSL = prevObj
                    _pendingDeletePrevious = true
                } else {
                    newSL = nil
                }
            } else {
                newSL = oldSL  // not ours — leave unchanged
            }
        }

        // Build the full settings.json with the new statusLine
        var newSettings = settings
        if let sl = newSL {
            newSettings["statusLine"] = sl
        } else {
            newSettings.removeValue(forKey: "statusLine")
        }
        let data = try AgentHookConfig.encoded(newSettings)
        _pendingStatusLineData = data
        _pendingStatusLineOriginal = snapshot.bytes

        // Build a compact diff: show only the statusLine key before → after
        func slJSON(_ val: [String: Any]?) throws -> String {
            guard let v = val else { return "(none)" }
            let d = try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
            return String(data: d, encoding: .utf8) ?? "(none)"
        }
        let before = try slJSON(oldSL)
        let after  = try slJSON(newSL)
        return "statusLine\nBefore:\n\(before)\n\nAfter:\n\(after)"
    }

    /// Writes settings.json and commits side effects (call after user confirms).
    func writeStatusLine() throws {
        guard let data = _pendingStatusLineData else { return }
        try ClaudeSettingsFile.write(data, to: Self.claudeSettingsURL, expecting: _pendingStatusLineOriginal)
        // Commit side effects only after successful write
        if let prevData = _pendingPreviousData {
            try? prevData.write(to: statusLinePreviousURL, options: .atomic)
        }
        if _pendingDeletePrevious {
            try? FileManager.default.removeItem(at: statusLinePreviousURL)
        }
        _pendingStatusLineData = nil
        _pendingStatusLineOriginal = nil
        _pendingPreviousData = nil
        _pendingDeletePrevious = false
    }

    // MARK: - App Store: hooks via the panel-selected ~/.claude

    #if APPSTORE
    /// Writes nb-hook script and updates settings.json in one shot (the user confirmed an alert).
    /// claudeURL must be a URL from NSOpenPanel (sandbox access is granted immediately — no security scope needed).
    func installAndWriteClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        // Derive hook path from the panel-selected claudeURL (real ~/.claude, not container)
        let hookPath = claudeURL.appendingPathComponent("coucou/nb-hook").path
        let (data, original) = try Self.claudeSettingsInstalling(at: settingsURL,
                                                                 command: Self.claudeHookCommand(hookPath: hookPath))

        // Write nb-hook (shell wrapper) + nb-hook.py (Python relay) into ~/.claude/coucou/
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let wrapperURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        let pyURL = coucouDir.appendingPathComponent("nb-hook.py")
        try nbHookPythonAppStore.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)

        // Write settings.json (with backup)
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: original)
        UserDefaults.standard.set(true, forKey: "coucouHooksInstalled")
    }

    /// Removes Coucou's hooks from the panel-selected settings.json (the user confirmed an alert).
    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        if let removed = try Self.claudeSettingsRemoving(at: settingsURL) {
            try ClaudeSettingsFile.write(removed.data, to: settingsURL, expecting: removed.original)
        }
        UserDefaults.standard.set(false, forKey: "coucouHooksInstalled")
    }
    #endif

    // MARK: - Claude Code installed-state detection (both builds)

    /// True when ~/.claude/settings.json already routes Claude Code events to Coucou.
    /// Cursor sessions ride on these same hooks, so they share this state.
    static func claudeHooksInstalled() -> Bool {
        #if APPSTORE
        // Sandboxed: can't read ~/.claude directly — check the install flag set on write.
        return UserDefaults.standard.bool(forKey: "coucouHooksInstalled")
        #else
        guard let json = jsonObject(at: claudeSettingsURL) else { return false }
        return coucouHooksPresent(inSettings: json)
        #endif
    }

    /// Keeps `pending` until confirmed, then writes it. Nothing pending → nothing to do.
    private func commit(_ pending: inout PendingFileChange?) throws {
        guard let change = pending else { return }
        try change.commit()
        pending = nil
    }

    // MARK: - Third-party agent installers  (#if !APPSTORE only)

    #if !APPSTORE
    private static var geminiSettingsURL: URL { home.appendingPathComponent(".gemini/settings.json") }
    private static var agyHooksURL: URL { home.appendingPathComponent(".gemini/config/hooks.json") }
    static var codexHooksURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var copilotHooksURL: URL { home.appendingPathComponent(".copilot/hooks/coucou.json") }
    static var museSettingsURL: URL { home.appendingPathComponent(".config/muse/settings.json") }
    static var openCodePluginURL: URL { home.appendingPathComponent(".config/opencode/plugins/coucou.js") }
    static var ampPluginURL: URL { home.appendingPathComponent(".config/amp/plugins/coucou.ts") }
    static var hermesPluginDir: URL { home.appendingPathComponent(".hermes/plugins/coucou") }
    static var hermesInitPyURL: URL { hermesPluginDir.appendingPathComponent("__init__.py") }
    static var hermesPluginYamlURL: URL { hermesPluginDir.appendingPathComponent("plugin.yaml") }
    static var hermesConfigURL: URL { home.appendingPathComponent(".hermes/config.yaml") }

    /// /bin/sh "<hookScriptPath>" — quoted for paths containing spaces (Application Support).
    private static func hookBase() -> String {
        let path = hookScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/sh \"\(path)\""
    }

    /// Reads a JSON settings file strictly (absent → empty, unreadable or invalid → throws),
    /// applies `transform` and keeps the result pending until the user confirms.
    /// Returns the new content for the preview. Removing from a file that is not
    /// there throws a "CoucouNoop" error with `noop`.
    private func previewJSONChange(_ pending: inout PendingFileChange?, url: URL, label: String,
                                   install: Bool, noop: String,
                                   _ transform: (_ object: [String: Any], _ isNewFile: Bool) throws -> [String: Any]) throws -> String {
        pending = nil
        if !install && !FileManager.default.fileExists(atPath: url.path) { throw Self.noop(noop) }
        let snapshot = try ClaudeSettingsFile.read(at: url, label: label)
        let data = try AgentHookConfig.encoded(transform(snapshot.object, snapshot.bytes == nil))
        pending = PendingFileChange(url: url, label: label, data: data, original: snapshot.bytes)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Keeps a whole generated file (install) or its deletion (`content` nil) pending until
    /// the user confirms. Returns the content for the preview.
    private func previewGeneratedFile(_ pending: inout PendingFileChange?, url: URL, label: String,
                                      content: String?, noop: String) throws -> String {
        pending = nil
        let original = try ClaudeSettingsFile.readBytes(at: url, label: label)
        if content == nil && original == nil { throw Self.noop(noop) }
        pending = PendingFileChange(url: url, label: label, data: content.map { Data($0.utf8) },
                                    original: original, newFileMode: 0o644)
        return content ?? "(will delete \(url.path))"
    }

    /// Commits a pending install of a generated file. A pending removal is left to
    /// `removeGeneratedFile`.
    private func writeGeneratedFile(_ pending: inout PendingFileChange?) throws {
        guard pending?.data != nil else { return }
        try commit(&pending)
    }

    /// Deletes the previewed file (after a backup beside it), only if Coucou generated it.
    private func removeGeneratedFile(_ pending: inout PendingFileChange?) throws {
        guard let change = pending, change.data == nil else { return }
        try Self.requireGeneratedByCoucou(change.original, label: change.label)
        try commit(&pending)
    }

    private static func requireGeneratedByCoucou(_ bytes: Data?, label: String) throws {
        guard let bytes, String(decoding: bytes, as: UTF8.self).contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(label) was not generated by Coucou — not deleting it."
            ])
        }
    }

    // MARK: Gemini CLI — ~/.gemini/settings.json

    static func geminiHooksInstalled() -> Bool {
        jsonObject(at: geminiSettingsURL).map(AgentHookConfig.hasGeminiHooks) ?? false
    }

    private var pendingGemini: PendingFileChange?

    func previewGeminiHooks(install: Bool) throws -> String {
        let label = "~/.gemini/settings.json"
        return try previewJSONChange(&pendingGemini, url: Self.geminiSettingsURL, label: label,
                                     install: install, noop: "No Gemini CLI hooks to remove.") { settings, _ in
            try install ? AgentHookConfig.geminiInstalling(into: settings, base: Self.hookBase(), name: label)
                    : AgentHookConfig.removingAgentHooks(from: settings, name: label)
        }
    }

    func writeGeminiHooks() throws { try commit(&pendingGemini) }

    // MARK: Antigravity — ~/.gemini/config/hooks.json

    static func agyHooksInstalled() -> Bool {
        jsonObject(at: agyHooksURL).map(AgentHookConfig.hasAntigravityHooks) ?? false
    }

    private var pendingAgy: PendingFileChange?

    func previewAgyHooks(install: Bool) throws -> String {
        try previewJSONChange(&pendingAgy, url: Self.agyHooksURL, label: "~/.gemini/config/hooks.json",
                              install: install, noop: "No Antigravity hooks to remove.") { root, _ in
            install ? AgentHookConfig.antigravityInstalling(into: root, base: Self.hookBase())
                    : AgentHookConfig.antigravityRemoving(from: root)
        }
    }

    func writeAgyHooks() throws { try commit(&pendingAgy) }

    // MARK: Codex — ~/.codex/hooks.json

    /// True when ~/.codex/hooks.json already routes Codex events to Coucou's nb-hook.
    static func codexHooksInstalled() -> Bool {
        jsonObject(at: codexHooksURL).map(AgentHookConfig.hasCodexHooks) ?? false
    }

    private var pendingCodex: PendingFileChange?

    func previewCodexHooks(install: Bool) throws -> String {
        let label = "~/.codex/hooks.json"
        return try previewJSONChange(&pendingCodex, url: Self.codexHooksURL, label: label,
                                     install: install, noop: "No Codex hooks to remove.") { root, _ in
            try install ? AgentHookConfig.codexInstalling(into: root, base: Self.hookBase(), name: label)
                    : AgentHookConfig.removingAgentHooks(from: root, name: label)
        }
    }

    func writeCodexHooks() throws { try commit(&pendingCodex) }

    // MARK: GitHub Copilot CLI — ~/.copilot/hooks/coucou.json (a file of Coucou's own)

    /// True when ~/.copilot/hooks/coucou.json already routes Copilot events to Coucou's nb-hook.
    static func copilotHooksInstalled() -> Bool {
        jsonObject(at: copilotHooksURL).map(AgentHookConfig.hasCopilotHooks) ?? false
    }

    private var pendingCopilot: PendingFileChange?

    /// Install merges into coucou.json; uninstall deletes the file (after a backup).
    func previewCopilotHooks(install: Bool) throws -> String {
        let url = Self.copilotHooksURL
        let label = "~/.copilot/hooks/coucou.json"
        guard install else {
            return try previewGeneratedFile(&pendingCopilot, url: url, label: label, content: nil,
                                            noop: "No Copilot hooks to remove.")
        }
        return try previewJSONChange(&pendingCopilot, url: url, label: label,
                                     install: true, noop: "") { root, _ in
            try AgentHookConfig.copilotInstalling(into: root, base: Self.hookBase(), name: label)
        }
    }

    func writeCopilotHooks() throws { try commit(&pendingCopilot) }

    // MARK: Muse Code — ~/.config/muse/settings.json

    /// True when ~/.config/muse/settings.json already routes Muse events to Coucou's nb-hook.
    static func museHooksInstalled() -> Bool {
        jsonObject(at: museSettingsURL).map(AgentHookConfig.hasMuseHooks) ?? false
    }

    private var pendingMuse: PendingFileChange?

    func previewMuseHooks(install: Bool) throws -> String {
        let label = "~/.config/muse/settings.json"
        return try previewJSONChange(&pendingMuse, url: Self.museSettingsURL, label: label,
                                     install: install, noop: "No Muse Code hooks to remove.") { settings, isNew in
            try install ? AgentHookConfig.museInstalling(into: settings, base: Self.hookBase(), name: label,
                                                         isNewFile: isNew)
                    : AgentHookConfig.removingAgentHooks(from: settings, name: label)
        }
    }

    func writeMuseHooks() throws { try commit(&pendingMuse) }

    // MARK: OpenCode — ~/.config/opencode/plugins/coucou.js (generated plugin)

    static func openCodePluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: openCodePluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("opencode")
    }

    private var pendingOpenCode: PendingFileChange?

    func previewOpenCodePlugin(install: Bool) throws -> String {
        try previewGeneratedFile(&pendingOpenCode, url: Self.openCodePluginURL,
                                 label: "~/.config/opencode/plugins/coucou.js",
                                 content: install ? openCodePluginSource(hookPath: Self.hookScriptPath) : nil,
                                 noop: "No OpenCode plugin to remove.")
    }

    func writeOpenCodePlugin() throws { try writeGeneratedFile(&pendingOpenCode) }
    func removeOpenCodePlugin() throws { try removeGeneratedFile(&pendingOpenCode) }

    // MARK: Amp — ~/.config/amp/plugins/coucou.ts (generated plugin)

    static func ampPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: ampPluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("'amp'")
    }

    private var pendingAmp: PendingFileChange?

    func previewAmpPlugin(install: Bool) throws -> String {
        try previewGeneratedFile(&pendingAmp, url: Self.ampPluginURL,
                                 label: "~/.config/amp/plugins/coucou.ts",
                                 content: install ? ampPluginSource(hookPath: Self.hookScriptPath) : nil,
                                 noop: "No Amp plugin to remove.")
    }

    func writeAmpPlugin() throws { try writeGeneratedFile(&pendingAmp) }
    func removeAmpPlugin() throws { try removeGeneratedFile(&pendingAmp) }

    // MARK: Hermes — ~/.hermes/plugins/coucou/ and ~/.hermes/config.yaml

    static func hermesPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: hermesInitPyURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("hermes")
    }

    /// Finds the `hermes` executable in PATH and common install locations.
    private static func hermesExecutablePath() -> String? {
        // Try PATH via `which` first
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["hermes"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError  = Pipe()
        if (try? which.run()) != nil {
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !out.isEmpty && FileManager.default.isExecutableFile(atPath: out) { return out }
            }
        }
        // Explicit common locations
        let homePath = home.path
        for candidate in [
            "\(homePath)/.local/bin/hermes",
            "\(homePath)/.hermes/bin/hermes",
            "/usr/local/bin/hermes",
            "/opt/homebrew/bin/hermes",
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Returns the Python that runs `executablePath` (see `hermesInterpreter(fromExecutable:)`):
    /// from its shebang — `#!/usr/bin/env python3` resolved via `which` — or, for the shell
    /// launcher Hermes' installer writes, the venv Python it execs.
    private static func interpreterFromShebang(_ executablePath: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: executablePath) else { return nil }
        let data = fh.readData(ofLength: 4096)
        try? fh.close()
        // Lossy: the 4 KB cut may fall inside a multi-byte character.
        guard let interpreter = hermesInterpreter(fromExecutable: String(decoding: data, as: UTF8.self))
        else { return nil }
        if !interpreter.hasPrefix("/") {
            let name = interpreter
            let task = Process(); let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            task.arguments = [name]; task.standardOutput = pipe; task.standardError = Pipe()
            if (try? task.run()) != nil {
                task.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return out.isEmpty ? nil : out
            }
            return nil
        }
        return interpreter
    }

    /// Returns true if the installed Hermes version exposes register_approval_transport.
    /// Finds the hermes binary, reads its shebang to get the right interpreter (never uses
    /// system python3), and runs an import check with a 3-second timeout.
    /// Returns false if hermes/interpreter not found, or import fails.
    static func hermesSupportsApprovalTransport() -> Bool {
        guard let hermesPath = hermesExecutablePath(),
              let pythonPath = interpreterFromShebang(hermesPath),
              FileManager.default.isExecutableFile(atPath: pythonPath) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments     = ["-c", "from hermes_cli.approval_transport import ApprovalRequest"]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return false }
        // Wait up to 3 seconds
        if exited.wait(timeout: .now() + 3) == .timedOut { task.terminate(); return false }
        return task.terminationStatus == 0
    }

    /// Pending Hermes plugin install: __init__.py then plugin.yaml. Empty when nothing is pending.
    private var pendingHermesPlugin: [PendingFileChange] = []
    /// Pending Hermes plugin removal: the __init__.py bytes the user was shown.
    private var pendingHermesPluginRemoval: Data?
    private var pendingHermesConfig: PendingFileChange?

    func previewHermesPlugin(install: Bool) throws -> String {
        pendingHermesPlugin = []
        pendingHermesPluginRemoval = nil
        let initLabel = "~/.hermes/plugins/coucou/__init__.py"
        let initBytes = try ClaudeSettingsFile.readBytes(at: Self.hermesInitPyURL, label: initLabel)
        if !install {
            guard let initBytes else { throw Self.noop("No Hermes plugin to remove.") }
            pendingHermesPluginRemoval = initBytes
            return "(will delete \(Self.hermesPluginDir.path))"
        }
        let content = hermesPluginSource(hookPath: Self.hookScriptPath)
        let yamlLabel = "~/.hermes/plugins/coucou/plugin.yaml"
        pendingHermesPlugin = [
            PendingFileChange(url: Self.hermesInitPyURL, label: initLabel, data: Data(content.utf8),
                              original: initBytes, newFileMode: 0o644),
            PendingFileChange(url: Self.hermesPluginYamlURL, label: yamlLabel, data: Data(hermesPluginYaml.utf8),
                              original: try ClaudeSettingsFile.readBytes(at: Self.hermesPluginYamlURL, label: yamlLabel),
                              newFileMode: 0o644),
        ]
        return content
    }

    func writeHermesPlugin() throws {
        guard !pendingHermesPlugin.isEmpty else { return }
        for change in pendingHermesPlugin { try change.commit() }
        pendingHermesPlugin = []
        // Register the plugin with the Hermes CLI so it appears in plugins.enabled.
        // Best-effort — silently ignored if hermes is not on PATH.
        _ = try? Self.runHermesCLI(["plugins", "enable", "coucou"])
    }

    /// Deletes ~/.hermes/plugins/coucou/ — only if Coucou generated it and __init__.py is
    /// still what the preview showed. No backup: the folder holds nothing but the two files
    /// Coucou generates, and a copy left under plugins/ could be loaded as a second plugin.
    func removeHermesPlugin() throws {
        guard let shown = pendingHermesPluginRemoval else { return }
        let label = "~/.hermes/plugins/coucou/__init__.py"
        try Self.requireGeneratedByCoucou(shown, label: label)
        guard try ClaudeSettingsFile.readBytes(at: Self.hermesInitPyURL, label: label) == shown else {
            throw ClaudeSettingsFile.Failure.changed(label)
        }
        // Remove from hermes plugins.enabled first, then delete the files.
        // Best-effort — silently ignored if hermes is not on PATH.
        _ = try? Self.runHermesCLI(["plugins", "disable", "coucou"])
        try FileManager.default.removeItem(at: Self.hermesPluginDir)
        pendingHermesPluginRemoval = nil
    }

    /// Invoke the Hermes CLI with the given arguments.
    /// Searches standard PATH locations for the `hermes` binary.
    @discardableResult
    private static func runHermesCLI(_ args: [String]) throws -> String {
        let hermesPaths = [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "/usr/bin/hermes",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/hermes",
        ]
        guard let hermesBin = hermesPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "hermes CLI not found."
            ])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hermesBin)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError  = Pipe()   // discard stderr
        try proc.run()
        proc.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func previewHermesConfig(enableApprovals: Bool, supportsTransport: Bool) throws -> String {
        pendingHermesConfig = nil
        let url = Self.hermesConfigURL
        let label = "~/.hermes/config.yaml"
        // Unreadable (or not UTF-8) must stop here, never count as an empty config.
        let original = try ClaudeSettingsFile.readBytes(at: url, label: label)
        var base = ""
        if let original {
            guard let text = String(data: original, encoding: .utf8) else {
                throw ClaudeSettingsFile.Failure.unreadable(label)
            }
            base = text
        }
        let effectiveApprovals = enableApprovals && supportsTransport
        guard let merged = mergedHermesConfig(base, enableApprovals: effectiveApprovals) else {
            throw NSError(domain: "Coucou", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/config.yaml uses an unsupported structure (flow maps, YAML anchors, or multi-document). Edit it manually and add:\n  security:\n    approval:\n      transport: coucou\n      transport_fallback: builtin"
            ])
        }
        pendingHermesConfig = PendingFileChange(url: url, label: label, data: Data(merged.utf8), original: original)
        return merged
    }

    func writeHermesConfig() throws { try commit(&pendingHermesConfig) }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}
