import Foundation
import Darwin
import AppKit
import SwiftUI
import CryptoKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on HookSocketServer's background queues, every message then handed
// to the main queue in the order its read finished (see deliver(_:)).

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL { AppPaths.supportDirectory }
    static var socketPath: String {
        #if APPSTORE
        // A DEBUG run with COUCOU_SUPPORT_DIR (scripts/smoke.sh) listens in that folder.
        if let dir = AppPaths.supportOverride { return dir.appendingPathComponent("nb.sock").path }
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

    // Held requests stay under the transport's 32 connections so short-lived events always
    // find a slot.
    private static let maxQueuedApprovals = 16
    private static let maxQueuedQuestions = 8

    /// The socket: accept, reads, connection slots (1 MB per message, 5 s idle timeout,
    /// 32 connections held ones included — see HookSocketServer).
    private let transport = HookSocketServer(configuration: .init(socketPath: HookServer.socketPath))

    /// Where a hook event goes and which session it belongs to (see HookRouting).
    private struct HookContext {
        let route: HookRoute
        /// `session_id` / `conversation_id`, or "unknown": what the request queues match on.
        let rawSessionId: String
        /// The session's key in SessionBook and RecapStore (`<pillId>+<cwd>` without an id).
        let sessionKey: String
        let cwd: String
        let projectName: String
        /// Sent by scripts/coucou-replay.py (DEBUG host override): a fake session, which must
        /// not move the Auto main pill (it is persisted across launches).
        let isReplay: Bool
    }

    /// A PermissionRequest connection held open while the user decides.
    private struct HeldApproval {
        let fd: Int32
        let source: any DispatchSourceRead           // fires on hang-up; its cancel handler closes fd
        let info: ApprovalInfo
        let context: HookContext
        /// One line for the alert: "Runs · npm test"…
        let summary: String
    }
    /// An AskUserQuestion connection held open while the user answers.
    private struct HeldQuestion {
        let fd: Int32
        let source: any DispatchSourceRead
        let question: AskQuestion
        let context: HookContext
    }

    /// The host of each session in the books, so a pill follows its lead session's app.
    @MainActor private var sessionHosts: [String: HostIdentity] = [:]

    // Pending requests, oldest first. Only the head is shown (AppState.pendingApproval /
    // pendingQuestion); the next one appears when it is resolved.
    @MainActor private var approvals = PendingRequestQueue<HeldApproval>(capacity: maxQueuedApprovals)
    @MainActor private var questions = PendingRequestQueue<HeldQuestion>(capacity: maxQueuedQuestions)
    @MainActor private var presentedApprovalId: UInt64? = nil   // queue entry on screen
    @MainActor private var presentedQuestionId: UInt64? = nil
    @MainActor private var nextRequestId: UInt64 = 1
    /// Ignores the card's buttons right after the next approval replaced the one on screen.
    @MainActor private var approvalSwapGuard = CardSwapGuard()
    /// The same for the question card (a tap on an option answers at once).
    @MainActor private var questionSwapGuard = CardSwapGuard()

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
        transport.closeClient(fd)
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

    /// Where a request waits: "Cursor", "WebStorm", "Warp"… for "Handled in …" notes.
    @MainActor
    private func requestPlaceName(_ context: HookContext) -> String {
        switch context.route.pillId {
        case "agent_cursor":  return "Cursor"
        case "agent_codex":   return "Codex"
        case "agent_copilot": return "Copilot CLI"
        case "agent_muse":    return "Muse Code"
        case "agent_hermes":  return "Hermes"
        default:
            guard let host = context.route.host else { return "Claude Code" }
            switch host.kind {
            case .ide:      return HostAppInfo.name(for: host.bundleId)
            case .terminal: return ClaudeHost.name(for: host.bundleId)
            case .vscode:   return "VS Code"
            case .cursor:   return "Cursor"
            }
        }
    }

    /// "Handled in Cursor." … — shown when the request was answered outside the notch.
    @MainActor
    private func handledNote(_ context: HookContext) -> String {
        "Handled in \(requestPlaceName(context))."
    }

    /// "Still waiting in Cursor." … — shown when the app gives up and the agent asks itself.
    @MainActor
    private func stillWaitingNote(_ context: HookContext) -> String {
        "Still waiting in \(requestPlaceName(context))."
    }

    /// Shows the head of the approval queue if it is not on screen yet.
    @MainActor
    private func presentApprovalHeadIfNeeded() {
        guard let head = approvals.head, head.id != presentedApprovalId else { return }
        presentedApprovalId = head.id
        approvalSwapGuard.cardPresented(at: Self.monotonicNow())
        let state = AppState.shared
        let held = head.payload
        let pillId = head.pillId
        ensureTask(held.context, renameExternal: true)
        mirror(pillId: pillId, resetState: false)
        state.updateTask(id: pillId, state: .approval)
        state.pendingApproval = held.info
        state.isPinned = true
        SoundEngine.shared.play("approval")
        postAlert(.waitingApproval, held.context, detail: held.summary)

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
        approvalSwapGuard.cardClosed(at: Self.monotonicNow())
        let state = AppState.shared
        state.pendingApproval = nil
        state.isPinned = false
        if !mirror(pillId: pillId, resetState: true) { state.updateTask(id: pillId, state: .working) }
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
            NotificationCenter.default.post(name: .heldCardClosed, object: nil)
        }
    }

    /// The relay closed a held approval: the editor or terminal answered it.
    @MainActor
    private func approvalHungUp(id: UInt64) {
        guard let entry = approvals.remove(id: id) else { return }
        entry.payload.source.cancel()
        settleApproval(entry)
        if entry.id == presentedApprovalId {
            closeApprovalCard(pillId: entry.pillId, note: handledNote(entry.payload.context))
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
            settleApproval(entry)
            if entry.id == presentedApprovalId {
                closeApprovalCard(pillId: entry.pillId, note: stillWaitingNote(entry.payload.context))
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
        questionSwapGuard.cardPresented(at: Self.monotonicNow())
        let state = AppState.shared
        let held = head.payload
        let pillId = head.pillId
        ensureTask(held.context, renameExternal: true)
        mirror(pillId: pillId, resetState: false)
        state.updateTask(id: pillId, state: .question)
        state.pendingQuestion = held.question
        state.isPinned = true
        SoundEngine.shared.play("approval")
        postAlert(.waitingAnswer, held.context, detail: held.question.questions.first?.question ?? "")

        if focusBeforeQuestion == nil { focusBeforeQuestion = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .question)
    }

    /// Takes the card of a question that just left the queue off screen; the caller presents
    /// the next one, if any.
    @MainActor
    private func closeQuestionCard(pillId: String) {
        presentedQuestionId = nil
        questionSwapGuard.cardClosed(at: Self.monotonicNow())
        let state = AppState.shared
        state.pendingQuestion = nil
        state.isPinned = false
        if !mirror(pillId: pillId, resetState: true) { state.updateTask(id: pillId, state: .working) }
        clearPillBadge(id: pillId)
        guard questions.isEmpty else { return }
        if let prev = focusBeforeQuestion {
            focusBeforeQuestion = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.view = state.tasks.isEmpty ? .empty : .overview
        NotificationCenter.default.post(name: .heldCardClosed, object: nil)
    }

    /// Removes the question on screen from the queue, nil if there is none.
    @MainActor
    private func takePresentedQuestion() -> PendingRequestQueue<HeldQuestion>.Entry? {
        guard let id = presentedQuestionId, let entry = questions.remove(id: id) else { return nil }
        settleQuestion(entry)
        return entry
    }

    @MainActor
    private func questionHungUp(id: UInt64) {
        guard let entry = questions.remove(id: id) else { return }
        entry.payload.source.cancel()
        settleQuestion(entry)
        if entry.id == presentedQuestionId { closeQuestionCard(pillId: entry.pillId) }
        presentQuestionHeadIfNeeded()
    }

    /// Questions past their deadline get "ask" so nb-hook exits cleanly; Claude Code re-asks in the terminal.
    @MainActor
    private func expireQuestions() {
        let expired = questions.removeExpired(now: Self.monotonicNow() + 0.5)
        for entry in expired {
            finishHeld(fd: entry.payload.fd, source: entry.payload.source, line: #"{"permissionDecision":"ask"}"#)
            settleQuestion(entry)
            if entry.id == presentedQuestionId { closeQuestionCard(pillId: entry.pillId) }
        }
        presentQuestionHeadIfNeeded()
    }

    /// Called by QuestionView (`fromCard`) and QuestionRelay (the iPhone, which checks the
    /// question's fingerprint itself). Sends answers JSON and cleans up.
    @MainActor
    func sendQuestionAnswers(_ answers: [String: Any], fromCard: Bool = true) {
        // The card on screen just replaced another one: the tap was aimed at that one.
        if fromCard, questionSwapGuard.blocksClick(at: Self.monotonicNow()) {
            nbLog("Question answer ignored: the card had just changed")
            return
        }
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
            RecapStore.shared.recordQuestionAnswered(sessionId: entry.payload.context.sessionKey)
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
        // Unpinned unless an approval card holds the island (the next question pins again).
        AppState.shared.isPinned = AppState.shared.pendingApproval != nil
        mirror(pillId: entry.pillId, resetState: true)
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
        // Both closures are formed here, off the main actor: they run on the transport's queues.
        transport.start(captureAncestry: { fd in ProcessAncestry.pidChain(fd: fd) },
                        onMessage: { [self] message in handleMessage(message) })
    }

    // MARK: - Message handler (transport's delivery queue)

    /// A fully read hook message, on its way to the main actor.
    /// @unchecked: the payload is a fresh JSONSerialization tree, never mutated after parsing.
    private enum HookMessage: @unchecked Sendable {
        case statusLine(payload: [String: Any])
        case question(fd: Int32, parsed: AskQuestion, payload: [String: Any])
        case permission(fd: Int32, payload: [String: Any])
        case event(name: String, payload: [String: Any])
        #if DEBUG
        /// `coucou_kind` "debug_…" (scripts/smoke.sh): answered on the main actor, in order.
        case debug(fd: Int32, kind: String, payload: [String: Any])
        #endif
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

    /// Keeps that order when a PostToolUse waits for its diff off the main thread: the
    /// messages behind it wait too (OrderedDelivery), then go in order.
    @MainActor private let delivery = OrderedDelivery<HookMessage>()

    @MainActor
    private func route(_ message: HookMessage) {
        delivery.submit(message, to: handle)
    }

    @MainActor
    private func handle(_ message: HookMessage) {
        switch message {
        case .statusLine(let payload):              processStatusLine(payload: payload)
        case .question(let fd, let parsed, let payload): processQuestionRequest(fd: fd, parsed: parsed, payload: payload)
        case .permission(let fd, let payload):      processPermissionRequest(fd: fd, payload: payload)
        #if DEBUG
        case .debug(let fd, let kind, let payload): processDebugQuery(fd: fd, kind: kind, payload: payload)
        #endif
        case .event(let name, let payload):
            // Edit / MultiEdit / Write: the diff of a big edit is computed off the main thread
            // (the island keeps animating); small ones right here, no queue hop.
            guard name == "PostToolUse",
                  let request = HookFileDiff.Request(tool: payload["tool_name"] as? String ?? "",
                                                     input: payload["tool_input"] as? [String: Any] ?? [:]) else {
                processEvent(name: name, payload: payload, fileDiff: nil)
                return
            }
            if request.isSmall {
                processEvent(name: name, payload: payload, fileDiff: request.compute())
                return
            }
            delivery.hold()
            request.compute { [self] diff in
                if case .event(let name, let payload) = message {
                    processEvent(name: name, payload: payload, fileDiff: diff)
                }
                delivery.resume(to: handle)
            }
        }
    }

    /// One message read by the transport, in the order reads finished. The fd is blocking
    /// again; `pids` is the relay's process chain, captured as soon as it was accepted.
    private func handleMessage(_ message: HookSocketServer.Message) {
        let fd = message.fd
        let raw = message.data
        let pids = message.pids
        // Held requests (approvals, questions) keep the fd and its connection slot until the
        // user decides; everything else is answered and closed here.
        var heldOpen = false
        defer { if !heldOpen { closeClient(fd) } }

        guard !raw.isEmpty,
              var payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            return
        }

        let coucouKind = payload["coucou_kind"] as? String ?? ""

        #if DEBUG
        // Test queries (scripts/smoke.sh): one JSON line back, after every earlier message.
        if coucouKind.hasPrefix("debug_") {
            heldOpen = true   // answered and closed on the main actor
            deliver(.debug(fd: fd, kind: coucouKind, payload: payload))
            return
        }
        #endif

        // statusline payloads are handled separately — no session, no reveal, no sound
        if coucouKind == "statusline" {
            deliver(.statusLine(payload: payload))
            sendLine(fd: fd, text: #"{"ok":true}"#)
            return
        }

        // Where the session runs: the apps above the relay (HookRouting reads this key).
        payload[HookRouting.hostBundleIdsKey] = hostBundleIds(payload: payload, pids: pids)

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

    /// The regular apps above the relay, nearest first (ProcessAncestry), cached per session.
    /// DEBUG builds honour `coucou_host_override` instead (replayed payloads): a bundle id,
    /// or "" for no app at all.
    private func hostBundleIds(payload: [String: Any], pids: [pid_t]) -> [String] {
        #if DEBUG
        if let override = payload[HookRouting.hostOverrideKey] as? String {
            let id = override.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? [] : [id]
        }
        #endif
        let sessionId = payload["session_id"] as? String ?? payload["conversation_id"] as? String ?? ""
        return ProcessAncestry.hostBundleIds(sessionId: sessionId, pids: pids)
    }

    // MARK: - Event → AppState
    // Every event is routed by HookRouting (one place for the pill, the agent and the host):
    // VS Code → integration_claude, Cursor → agent_cursor, any other IDE → its own `ide_…`
    // pill, plain terminals → integration_claude (Claude Code) / agent_codex (Codex), a valid
    // coucou_agent → agent_<name>. Each pill keeps a SessionBook of its sessions; the pill's
    // own task mirrors the book's lead session, so the views that predate the book keep working.
    // View switches only happen if the pill is focused; otherwise a badge shows the alert.

    #if APPSTORE
    private static let codexSupported = false
    #else
    private static let codexSupported = true
    #endif

    /// The route and session of a payload, nil when it is ignored (no identifiable host).
    @MainActor
    private func context(for payload: [String: Any]) -> HookContext? {
        guard let route = HookRouting.route(payload: payload, codexSupported: Self.codexSupported) else { return nil }
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let rawSessionId = HookRouting.rawSessionId(payload)
        return HookContext(route: route, rawSessionId: rawSessionId,
                           sessionKey: HookRouting.sessionKey(rawSessionId: rawSessionId, pillId: route.pillId, cwd: cwd),
                           cwd: cwd,
                           projectName: aliasProjectName(rawName.isEmpty ? "Session" : rawName),
                           isReplay: payload[HookRouting.hostOverrideKey] != nil)
    }

    /// Third-party agents whose permission requests get a card (GitHub build only).
    @MainActor
    private func externalApprovalAgents(payload: [String: Any]) -> Set<String> {
        #if APPSTORE
        return []
        #else
        var agents: Set<String> = ["copilot", "muse"]
        // Hermes only when the plugin sent coucou_has_transport: true, meaning
        // register_approval_transport is wired and Hermes will honour our choice.
        // Without that flag the request is answered "ask" so Hermes handles it natively.
        if AppDefaults.store.bool(forKey: "hermesApprovalsEnabled"),
           payload["coucou_has_transport"] as? Bool == true {
            agents.insert("hermes")
        }
        return agents
        #endif
    }

    /// `fileDiff`: the diff of a PostToolUse file edit, already computed (see handle(_:)).
    @MainActor
    private func processEvent(name: String, payload: [String: Any], fileDiff: FileDiff?) {
        let state = AppState.shared
        guard let ctx = context(for: payload) else {
            let termProgram = payload["term_program"] as? String ?? ""
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? payload["bundle_id"] as? String ?? "" : termProgram)")
            return
        }
        let route = ctx.route
        let agentId = route.pillId
        let sessionId = ctx.rawSessionId
        let recapSessionId = ctx.sessionKey
        let projectName = ctx.projectName
        let isExternalAgent = route.isExternalAgent
        let focused = state.focusId == agentId

        #if PHONE_LINK
        // The iPhone's "last turn" (prompt, actions, diffs, answer).
        if !isExternalAgent { TurnRecorder.shared.record(event: name, payload: payload, pillId: agentId, fileDiff: fileDiff) }
        #endif

        // A request answered in the editor or terminal (this exact tool call finished, or the
        // turn ended — see PendingRequestQueue.resolves) leaves the approval queue: waiting
        // requests go silently, the card on screen shows a note. While the card's session is
        // still waiting, its other events are skipped so they don't overwrite the approval
        // state; other sessions of the same pill go on (their book only — the waiting session
        // leads the pill). Otherwise processing continues, then the next waiting request is shown.
        if !approvals.isEmpty {
            let isToolEnd = name == "PostToolUse" || name == "PostToolUseFailure"
            let resolved = approvals.removeResolved(
                event: name, pillId: agentId, sessionId: sessionId,
                tool: isToolEnd ? (payload["tool_name"] as? String ?? "") : "",
                inputKey: isToolEnd ? Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]) : "")
            var headResolved = false
            for entry in resolved {
                entry.payload.source.cancel()
                settleApproval(entry)
                if entry.id == presentedApprovalId {
                    headResolved = true
                    closeApprovalCard(pillId: entry.pillId, note: handledNote(entry.payload.context))
                }
            }
            if !headResolved, let head = approvals.head, head.id == presentedApprovalId,
               head.pillId == agentId, head.sessionId == sessionId {
                return
            }
        }
        defer { presentApprovalHeadIfNeeded() }

        let tool = payload["tool_name"] as? String ?? ""
        let change = HookRouting.sessionChange(event: name, tool: tool,
                                               waiting: waitingPhase(pillId: agentId, sessionId: sessionId))

        // The pill: third-party agents get theirs on the events that always created it;
        // sessions of an editor or terminal on any event of a live session.
        switch change {
        case .record, .finish:
            if isExternalAgent {
                let creates = name == "SessionStart" || name == "UserPromptSubmit"
                    || (name == "PreToolUse" && tool != "AskUserQuestion")
                if creates { ensureTask(ctx, renameExternal: false) }
            } else {
                ensureTask(ctx, renameExternal: false)
            }
        case .remove, .none:
            break
        }

        // What the event adds to its session's steps (and the side effects that go with it).
        var step: String? = nil
        var finalText = ""
        switch name {
        case "SessionStart":
            if agentId == "agent_hermes", let platform = payload["platform"] as? String,
               !platform.isEmpty, platform != "cli" {
                step = platform.prefix(1).uppercased() + platform.dropFirst()
            }
        case "UserPromptSubmit":
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty { step = String(prompt.prefix(60)) }
        case "PreToolUse":
            // AskUserQuestion is handled via the dedicated --ask hook: no step, so nothing
            // flickers over the question card.
            if tool != "AskUserQuestion" {
                step = localizedStep(tool: tool.isEmpty ? "Tool" : tool, input: payload["tool_input"] as? [String: Any] ?? [:])
            }
        case "PostToolUse":
            // Live diff for Edit / MultiEdit / Write
            if let diff = fileDiff.flatMap(HookFileDiff.shown) {
                let idx = state.appendSessionDiff(diff, for: agentId)
                step = String.makeDiffStep(filename: diff.name, added: diff.added, removed: diff.removed, diffId: idx)
                RecapStore.shared.recordFileDiff(sessionId: recapSessionId, path: diff.name, added: diff.added, removed: diff.removed)
            }
        case "PostToolUseFailure":
            step = "⚠ failed"
        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if !(lower.contains("rate limit") || lower.contains("limite d")), message.hasSuffix("?") { step = message }
        case "Stop":
            let rawFinal = (payload["last_assistant_message"] as? String) ?? (payload["message"] as? String) ?? ""
            finalText = DiffEngine.toOneLine(rawFinal)
            if !finalText.isEmpty { step = finalText }
        case "SubagentStart":
            step = "+ subagent"
        case "SubagentStop":
            step = "• subagent done"
        default:
            break
        }

        // The session book, then the pill from its lead session.
        let leadBefore = state.sessionBooks[agentId]?.lead?.id
        var book = state.sessionBooks[agentId] ?? SessionBook()
        let now = Date()
        switch change {
        case .record(let phase):
            book.record(id: recapSessionId, agent: route.agentName, projectName: projectName, cwd: ctx.cwd,
                        phase: phase, step: step, at: now)
        case .finish:
            book.record(id: recapSessionId, agent: route.agentName, projectName: projectName, cwd: ctx.cwd,
                        phase: nil, step: step, at: now)
            book.finish(id: recapSessionId, finalLine: finalText, at: now)
        case .remove:
            book.remove(id: recapSessionId)
        case .none:
            break
        }
        if change != .none {
            if change != .remove, let host = route.host, sessionHosts[recapSessionId] == nil {
                sessionHosts[recapSessionId] = host
            }
            storeBook(book, for: agentId)
        }
        let plan = HookRouting.mirrorPlan(eventSession: recapSessionId, leadBefore: leadBefore,
                                          leadAfter: state.sessionBooks[agentId]?.lead?.id)
        mirror(pillId: agentId, resetState: plan.resetState)
        let lead = plan.applyEvent

        // The Auto main pill follows the IDE the user works in (AutoMainPill).
        if change != .none, change != .remove, payload[HookRouting.hostOverrideKey] == nil,
           let activity = AutoMainPill.activity(forEvent: name) {
            state.noteWorkspaceActivity(pillId: agentId, hostBundleId: route.host?.bundleId, activity: activity)
        }

        switch name {

        case "SessionStart":
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            if lead { state.updateTask(id: agentId, state: .thinking) }
            RecapStore.shared.userPromptSubmit(sessionId: recapSessionId, pillId: agentId, project: projectName)
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            RecapStore.shared.preToolUse(sessionId: recapSessionId, tool: tool.isEmpty ? "Tool" : tool)
            guard tool != "AskUserQuestion" else { break }
            if lead { state.updateTask(id: agentId, state: .working) }
            nbLog("PreToolUse \(tool)")

        case "PostToolUse", "PostToolUseFailure":
            if lead { state.updateTask(id: agentId, state: .working) }

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                if lead { state.updateTask(id: agentId, state: .ratelimit) }
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                if lead { state.updateTask(id: agentId, state: .question) }
            }

        case "Stop":
            RecapStore.shared.stop(sessionId: recapSessionId)
            SoundEngine.shared.play("finish")
            postAlert(.finished, ctx, detail: finalText)
            if lead {
                state.updateTask(id: agentId, state: .finished)
                if focused {
                    expandIfNeeded(to: .finished)
                } else {
                    setPillBadge(id: agentId, badge: .finished)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in
                self?.settleFinished(ctx)
            }

        case "StopFailure":
            RecapStore.shared.stop(sessionId: recapSessionId)
            SoundEngine.shared.play("error")
            let rawError = (payload["error"] as? String) ?? (payload["message"] as? String)
                ?? (payload["last_assistant_message"] as? String) ?? ""
            postAlert(.error, ctx, detail: DiffEngine.toOneLine(rawError))
            if lead {
                state.updateTask(id: agentId, state: .error)
                if focused {
                    expandIfNeeded(to: .error)
                } else {
                    setPillBadge(id: agentId, badge: .error)
                }
            }

        case "Interrupt":
            // Codex: user stopped the turn
            RecapStore.shared.stop(sessionId: recapSessionId)
            if lead {
                state.updateTask(id: agentId, state: .idle)
                clearPillBadge(id: agentId)
            }

        case "SessionEnd":
            RecapStore.shared.sessionEnd(sessionId: recapSessionId)
            sessionHosts[recapSessionId] = nil
            // The pill goes when its last session does (a declared pill is reset, see removeTask).
            if state.sessionBooks[agentId]?.isEmpty ?? true {
                state.sessionBooks[agentId] = nil
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
                state.clearSessionDiffs(for: agentId)
                state.removeTask(id: agentId)
            }

        default:
            break
        }

        if change != .none { trimBooks(now: now) }
    }

    // MARK: - Sessions → pills

    /// The phase of a request a session still holds open, nil when it holds none.
    @MainActor
    private func waitingPhase(pillId: String, sessionId: String) -> SessionPhase? {
        if approvals.entries.contains(where: { $0.pillId == pillId && $0.sessionId == sessionId }) { return .waitingApproval }
        if questions.entries.contains(where: { $0.pillId == pillId && $0.sessionId == sessionId }) { return .waitingAnswer }
        return nil
    }

    /// Writes a pill's book back, only when it changed (every write redraws the island).
    @MainActor
    private func storeBook(_ book: SessionBook, for pillId: String) {
        let state = AppState.shared
        guard state.sessionBooks[pillId] != book else { return }
        state.sessionBooks[pillId] = book
    }

    /// Records that a session waits on the user (approval or question card queued).
    @MainActor
    private func recordWaiting(_ context: HookContext, phase: SessionPhase) {
        let state = AppState.shared
        let pillId = context.route.pillId
        let leadBefore = state.sessionBooks[pillId]?.lead?.id
        var book = state.sessionBooks[pillId] ?? SessionBook()
        book.record(id: context.sessionKey, agent: context.route.agentName, projectName: context.projectName,
                    cwd: context.cwd, phase: phase, at: Date())
        if let host = context.route.host, sessionHosts[context.sessionKey] == nil {
            sessionHosts[context.sessionKey] = host
        }
        storeBook(book, for: pillId)
        mirror(pillId: pillId, resetState: state.sessionBooks[pillId]?.lead?.id != leadBefore)
    }

    /// A request left its queue: unless another one of the same session still waits, the
    /// session works again, and the pill follows its (maybe new) lead.
    @MainActor
    private func settleWaiting(_ context: HookContext, from phase: SessionPhase) {
        let state = AppState.shared
        let pillId = context.route.pillId
        guard var book = state.sessionBooks[pillId],
              book.session(context.sessionKey)?.phase == phase else { return }
        let stillWaiting = waitingPhase(pillId: pillId, sessionId: context.rawSessionId)
        guard stillWaiting != phase else { return }
        book.setPhase(id: context.sessionKey, stillWaiting ?? .working)
        storeBook(book, for: pillId)
        mirror(pillId: pillId, resetState: true)
    }

    @MainActor
    private func settleApproval(_ entry: PendingRequestQueue<HeldApproval>.Entry) {
        settleWaiting(entry.payload.context, from: .waitingApproval)
    }

    @MainActor
    private func settleQuestion(_ entry: PendingRequestQueue<HeldQuestion>.Entry) {
        settleWaiting(entry.payload.context, from: .waitingAnswer)
    }

    /// 5.2 s after Stop, once the finish view is gone: the session rests (unless it started
    /// again meanwhile). A third-party agent's pill goes when none of its sessions is busy.
    @MainActor
    private func settleFinished(_ context: HookContext) {
        let state = AppState.shared
        let pillId = context.route.pillId
        defer { trimBooks(now: Date()) }
        guard var book = state.sessionBooks[pillId],
              book.session(context.sessionKey)?.phase == .finished else { return }
        let leadBefore = book.lead?.id
        book.setPhase(id: context.sessionKey, .idle)
        storeBook(book, for: pillId)
        if context.route.isExternalAgent {
            let busy = book.sessions.contains { $0.phase == .working || $0.phase.waitsOnUser }
            if !busy {
                state.sessionBooks[pillId] = nil
                for session in book.sessions { sessionHosts[session.id] = nil }
                state.removeTask(id: pillId)
                return
            }
        }
        let leadAfter = book.lead?.id
        if leadAfter == context.sessionKey {
            state.updateTask(id: pillId, state: .idle)
            clearPillBadge(id: pillId)
        }
        mirror(pillId: pillId, resetState: leadAfter != leadBefore)
    }

    /// The one pending trim (main queue), armed for the earliest SessionBook expiry.
    @MainActor private var trimWork: DispatchWorkItem?

    /// Drops ended sessions past their retention and abandoned working ones (SessionBook.trim).
    /// An IDE or third-party agent pill goes with its last session; other pills stay, idle. Runs when
    /// something changed, and once more at the earliest expiry so a session whose agent
    /// vanished without SessionEnd doesn't stay forever; nothing is scheduled when no book
    /// can expire.
    @MainActor
    private func trimBooks(now: Date) {
        defer { scheduleTrim() }
        let state = AppState.shared
        for (pillId, book) in state.sessionBooks {
            var trimmed = book
            trimmed.trim(now: now)
            guard trimmed != book else { continue }
            if trimmed.isEmpty {
                state.sessionBooks[pillId] = nil
                if HostResolver.isIDEPill(pillId) || Self.isExternalAgentPill(pillId) {
                    // As SessionEnd / settleFinished would (a main or declared pill is reset).
                    state.clearSessionDiffs(for: pillId)
                    state.removeTask(id: pillId)
                } else {
                    // No book left to mirror: a session dropped while "working" (its agent
                    // was killed) must not leave the pill working for good.
                    state.updateTask(id: pillId, state: .idle)
                    clearPillBadge(id: pillId)
                }
            } else {
                state.sessionBooks[pillId] = trimmed
                mirror(pillId: pillId, resetState: trimmed.lead?.id != book.lead?.id)
            }
        }
        // Hosts of sessions no book holds any more.
        if sessionHosts.count > 64 {
            let live = Set(state.sessionBooks.values.flatMap { $0.sessions.map(\.id) })
            sessionHosts = sessionHosts.filter { live.contains($0.key) }
        }
    }

    @MainActor
    private func scheduleTrim() {
        trimWork?.cancel()
        trimWork = nil
        guard let next = AppState.shared.sessionBooks.values.compactMap(\.nextExpiry).min() else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.trimWork = nil
                self?.trimBooks(now: Date())
            }
        }
        trimWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow + 1), execute: item)
    }

    /// Copies a pill's lead session onto its task: steps, final line, and (for pills named after
    /// their project) the name; the host app it runs in. `resetState` also sets Mochi's state
    /// from the lead's phase (the lead changed, or a card closed). False when there is nothing
    /// to mirror (no book or no task).
    @MainActor @discardableResult
    private func mirror(pillId: String, resetState: Bool) -> Bool {
        let state = AppState.shared
        guard let lead = state.sessionBooks[pillId]?.lead,
              let idx = state.tasks.firstIndex(where: { $0.id == pillId }) else { return false }
        var task = state.tasks[idx]
        if resetState { task.state = HookRouting.botState(for: lead.phase) }
        if task.steps != lead.steps {
            task.steps = lead.steps
            task.stepIndex = max(0, lead.steps.count - 1)
        }
        if task.finalLine != lead.finalLine { task.finalLine = lead.finalLine }
        let isExternal = Self.isExternalAgentPill(pillId)
        if !HostResolver.isIDEPill(pillId), !isExternal, !lead.projectName.isEmpty {
            task.name = lead.projectName
        }
        if !lead.cwd.isEmpty { task.sessionCwd = lead.cwd }
        if !isExternal, let host = sessionHosts[lead.id] {
            if pillId == "integration_claude" { task.hostApp = host.kind == .terminal ? host.bundleId : nil }
            task.sessionBundleId = host.bundleId
        }
        if task != state.tasks[idx] { state.tasks[idx] = task }
        return true
    }

    /// A third-party agent's own pill (`agent_<coucou_agent>`), named after the agent.
    /// Cursor's pill, and Codex's in the GitHub build, are workspace pills named after the project.
    private static func isExternalAgentPill(_ pillId: String) -> Bool {
        pillId.hasPrefix("agent_") && pillId != "agent_cursor" && !(codexSupported && pillId == "agent_codex")
    }

    // MARK: - Alerts

    /// "Claude Code", "Codex", or a third-party agent's pill name.
    @MainActor
    private func agentDisplayName(_ route: HookRoute) -> String {
        if let kind = route.agentKind { return kind.displayName }
        if let def = PillCatalog.definition(for: route.pillId) { return def.name }
        let agent = route.externalAgent ?? route.pillId
        return agent.prefix(1).uppercased() + agent.dropFirst()
    }

    @MainActor
    private func postAlert(_ kind: SessionAlert.Kind, _ context: HookContext, detail: String) {
        SessionAlertCenter.shared.post(SessionAlert(
            kind: kind, pillId: context.route.pillId, sessionId: context.sessionKey,
            agentName: agentDisplayName(context.route), projectName: context.projectName,
            hostBundleId: context.route.host?.bundleId, detail: detail))
    }

    // MARK: - Dynamic pills

    /// Creates the pill an event lands on when it isn't on the island yet.
    /// `renameExternal`: approval cards of third-party agents name the pill after the project,
    /// as they always did.
    @MainActor
    private func ensureTask(_ context: HookContext, renameExternal: Bool) {
        let route = context.route
        if route.isIDE {
            upsertIDETask(id: route.pillId, bundleId: route.host?.bundleId ?? "")
        } else if let agent = route.externalAgent, !renameExternal {
            upsertExternalAgent(id: route.pillId, name: agent)
        } else {
            upsertWorkspaceTask(id: route.pillId, projectName: context.projectName, cwd: context.cwd,
                                rename: route.isExternalAgent)
        }
    }

    /// Creates a dynamic pill for a third-party agent on first event, then no-ops.
    /// ID format: "agent_<name>" — never collides with "integration_*" pills.
    /// Inserted right after the main pill so it appears in the visible prefix(4).
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
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.append(task)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    /// Creates an IDE's pill (`ide_…`) on its first session: named after the IDE (the project
    /// lives in the session), painted with the user's colour for the pill or a stable default.
    /// Inserted after the main pill so it shows in the visible prefix(4). It goes when its
    /// SessionBook empties (SessionEnd or retention, see trimBooks).
    @MainActor
    private func upsertIDETask(id: String, bundleId: String) {
        let state = AppState.shared
        guard !state.tasks.contains(where: { $0.id == id }) else { return }
        let color = PillColors.color(for: id, catalogColor: HookRouting.defaultIDEColor(pillId: id),
                                     in: state.pillColors)
        var task = AgentTask(id: id, name: HostAppInfo.name(for: bundleId), color: color,
                             state: .idle, steps: [], source: .agent, isIntegration: true)
        if !bundleId.isEmpty { task.sessionBundleId = bundleId }
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
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

    // MARK: - DEBUG socket queries (scripts/smoke.sh)

    #if DEBUG
    /// - `debug_state`: what the island shows and holds (DEBUG builds).
    /// - `debug_answer` (`decision`: allow / deny / always for the approval on screen;
    ///   "answer" picks each question's first option, anything else replies "ask"), and
    ///   `debug_trim` (`advance`: seconds; trims the session books as if that much time had
    ///   passed): smoke-test runs only (COUCOU_SMOKE=1), never in a build someone uses, so
    ///   nothing but a click approves a real request.
    @MainActor
    private func processDebugQuery(fd: Int32, kind: String, payload: [String: Any]) {
        var reply: [String: Any] = ["ok": true]
        switch kind {
        case "debug_state":
            reply = debugState()
        case "debug_answer" where AppPaths.isSmokeTest:
            let decision = payload["decision"] as? String ?? "deny"
            if presentedApprovalId != nil {
                sendApprovalDecision(decision)
                reply["resolved"] = "approval"
            } else if presentedQuestionId != nil, let question = AppState.shared.pendingQuestion {
                if decision == "answer" {
                    let firsts = question.questions.map { $0.options.first.map { [$0.label] } ?? [] }
                    sendQuestionAnswers(AskQuestion.buildAnswers(questions: question.questions, selections: firsts))
                } else {
                    sendQuestionAsk()
                }
                reply["resolved"] = "question"
            } else {
                reply["resolved"] = "none"
            }
        case "debug_trim" where AppPaths.isSmokeTest:
            let advance = payload["advance"] as? Double ?? 0
            trimBooks(now: Date().addingTimeInterval(advance))
        default:
            reply = ["ok": false, "error": "unknown or unavailable query \(kind)"]
        }
        let line = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        answerAndClose(fd: fd, line: line)
    }

    @MainActor
    private func debugState() -> [String: Any] {
        let state = AppState.shared
        let fsm = IslandWindowController.current?.fsm
        let books = state.sessionBooks.mapValues { book in
            book.sessions.map { ["id": $0.id, "phase": $0.phase.rawValue, "agent": $0.agent] }
        }
        return [
            "ok": true,
            "mode": state.mode.rawValue,
            "view": state.view.rawValue,
            "fsm": fsm.map { "\($0.state)" } ?? "none",
            "countdown": fsm?.countdown.map { $0.deadline.timeIntervalSinceNow } ?? NSNull(),
            "focusId": state.focusId ?? NSNull(),
            "mainPillId": state.mainPillId,
            "isPinned": state.isPinned,
            "isPresent": state.isPresent,
            "tasks": state.tasks.map { ["id": $0.id, "name": $0.name, "state": $0.state.rawValue] },
            "sessionBooks": books,
            "pendingApproval": state.pendingApproval != nil,
            "pendingQuestion": state.pendingQuestion != nil,
            "queuedApprovals": approvals.count,
            "queuedQuestions": questions.count,
        ]
    }
    #endif

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        // Who gets a card (HookRouting.showsCard): IDE sessions (VS Code, Cursor, any other
        // IDE) always, terminal sessions when turned on in Settings, Codex, and Copilot CLI /
        // Muse Code / Hermes among third-party agents. Everything else is answered "ask" at
        // once so the agent asks in its own window.
        guard let ctx = context(for: payload),
              HookRouting.showsCard(.approval, route: ctx.route,
                                    terminalCardsEnabled: ClaudeHost.terminalCardsEnabled,
                                    externalApprovalAgents: externalApprovalAgents(payload: payload)) else {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }
        let pillId = ctx.route.pillId
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
        let info = ApprovalInfo(sessionId: ctx.sessionKey, tool: tool,
                                command: command, inputKey: inputKey, pillId: pillId)

        // Safety timeout, counted from arrival even while the request waits behind others:
        // the app gives up before the relay (118 s) so the agent re-asks in its terminal.
        let waitTimeout = HookRouting.approvalTimeout(route: ctx.route)
        let id = makeRequestId()
        // Monitor fd: if the editor closes the connection (handled externally), drop the request.
        let source = makeHoldSource(fd: fd) { [weak self] in self?.approvalHungUp(id: id) }
        approvals.enqueue(.init(id: id, pillId: pillId, sessionId: ctx.rawSessionId, tool: tool, inputKey: inputKey,
                                deadline: Self.monotonicNow() + waitTimeout,
                                payload: HeldApproval(fd: fd, source: source, info: info, context: ctx,
                                                      summary: localizedStep(tool: tool, input: toolInput))))
        if approvals.count > 1 { nbLog("PermissionRequest queued (\(approvals.count) waiting)") }
        // The session waits on the user from now on, even while its card waits behind others.
        if !ctx.route.isExternalAgent { ensureTask(ctx, renameExternal: false) }
        recordWaiting(ctx, phase: .waitingApproval)
        if !ctx.isReplay {
            AppState.shared.noteWorkspaceActivity(pillId: pillId, hostBundleId: ctx.route.host?.bundleId, activity: .agent)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
            self?.expireApprovals()
        }
        presentApprovalHeadIfNeeded()
    }

    /// Called by ApprovalView buttons (`fromCard`) and ApprovalRelay (the iPhone, which
    /// checks the request's fingerprint itself). Writes the decision to the waiting nb-hook
    /// and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String, fromCard: Bool = true) {
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

        // The card on screen just replaced another one: the click was aimed at that one.
        if fromCard, approvalSwapGuard.blocksClick(at: Self.monotonicNow()) {
            nbLog("Approval click ignored: the card had just changed")
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
            settleApproval(entry)
        }

        let pillId = AppState.shared.pendingApproval?.pillId ?? "integration_claude"
        RecapStore.shared.recordDecision(pillId: pillId, decision: decision)
        closeApprovalCard(pillId: pillId, note: nil)
        presentApprovalHeadIfNeeded()
    }

    // MARK: - Question request

    @MainActor
    private func processQuestionRequest(fd: Int32, parsed: AskQuestion, payload: [String: Any]) {
        // Same cards as approvals (HookRouting.showsCard); third-party agents never get one.
        guard let ctx = context(for: payload),
              HookRouting.showsCard(.question, route: ctx.route,
                                    terminalCardsEnabled: ClaudeHost.terminalCardsEnabled,
                                    externalApprovalAgents: []) else {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }
        // Too many questions already waiting: Claude Code asks in the terminal.
        guard !questions.isFull else {
            answerAndClose(fd: fd, line: #"{"permissionDecision":"ask"}"#)
            return
        }

        let id = makeRequestId()
        let source = makeHoldSource(fd: fd) { [weak self] in self?.questionHungUp(id: id) }
        questions.enqueue(.init(id: id, pillId: ctx.route.pillId, sessionId: ctx.rawSessionId,
                                tool: "AskUserQuestion", inputKey: "",
                                deadline: Self.monotonicNow() + 120,
                                payload: HeldQuestion(fd: fd, source: source, question: parsed, context: ctx)))
        ensureTask(ctx, renameExternal: false)
        recordWaiting(ctx, phase: .waitingAnswer)
        if !ctx.isReplay {
            AppState.shared.noteWorkspaceActivity(pillId: ctx.route.pillId, hostBundleId: ctx.route.host?.bundleId,
                                                  activity: .agent)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.expireQuestions()
        }
        presentQuestionHeadIfNeeded()
    }

    /// Updates or transiently creates a workspace pill task (VS Code, Cursor, Codex…).
    /// An existing task keeps its name (it follows its lead session, see mirror) unless
    /// `rename` (third-party agents' approval cards, as before); a missing one is created,
    /// named after the project, and inserted after the main pill.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "", rename: Bool = false) {
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            if rename, state.tasks[idx].name != projectName { state.tasks[idx].name = projectName }
            return
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        var task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
        if !cwd.isEmpty { task.sessionCwd = cwd }
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
        HookSocketServer.sendLine(fd: fd, text: text)
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
        var relay = nbHookPythonGitHub
        if AppPaths.supportOverride != nil {   // DEBUG, COUCOU_SUPPORT_DIR: this run's socket
            relay = relay.replacingOccurrences(of: "~/Library/Application Support/NotchBuddy/nb.sock",
                                               with: Self.socketPath)
        }
        try? relay.write(to: pyURL, atomically: true, encoding: .utf8)
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

    private static var home: URL {
        #if DEBUG
        if SnapshotMode.isActive { return SnapshotMode.home }   // fixtures, never the user's files
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

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
        return (try AgentHookConfig.encoded(merged), snapshot.bytes)
    }

    /// settings.json without Coucou's hooks, or nil when there are none to remove.
    private static func claudeSettingsRemoving(at url: URL) throws -> (data: Data, original: Data?)? {
        let snapshot = try ClaudeSettingsFile.read(at: url)
        guard let hooks = snapshot.object["hooks"] as? [String: Any], containsCoucouHook(inEvents: hooks),
              let cleaned = AgentHookConfig.claudeRemoving(from: snapshot.object) else { return nil }
        return (try AgentHookConfig.encoded(cleaned), snapshot.bytes)
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
        let newText = String(data: change.data, encoding: .utf8) ?? ""
        pendingClaudeHooksDiff = Self.settingsDiff(original: change.original, newText: newText)
        return newText
    }

    /// The previewed change as a line diff against the current file, re-encoded the same way
    /// so only Coucou's own lines show (nil when there is no current file or it is too big).
    private(set) var pendingClaudeHooksDiff: FileDiff?

    private static func settingsDiff(original: Data?, newText: String) -> FileDiff? {
        guard let original,
              let object = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              let oldData = try? AgentHookConfig.encoded(object),
              let oldText = String(data: oldData, encoding: .utf8) else { return nil }
        let diff = DiffEngine.fromEdit(old: oldText, new: newText, path: "settings.json")
        return diff.tooLarge ? nil : diff
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
        AppDefaults.store.set(true, forKey: "coucouHooksInstalled")
    }

    /// Removes Coucou's hooks from the panel-selected settings.json (the user confirmed an alert).
    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        if let removed = try Self.claudeSettingsRemoving(at: settingsURL) {
            try ClaudeSettingsFile.write(removed.data, to: settingsURL, expecting: removed.original)
        }
        AppDefaults.store.set(false, forKey: "coucouHooksInstalled")
    }
    #endif

    // MARK: - Claude Code installed-state detection (both builds)

    /// True when ~/.claude/settings.json already routes Claude Code events to Coucou.
    /// Cursor sessions ride on these same hooks, so they share this state.
    static func claudeHooksInstalled() -> Bool {
        #if APPSTORE
        // Sandboxed: can't read ~/.claude directly — check the install flag set on write.
        return AppDefaults.store.bool(forKey: "coucouHooksInstalled")
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
            && content.contains(openCodePluginMarker)
    }

    /// OpenCode's major version from `opencode --version` ("opencode v2.0.24", "1.4.3"…),
    /// nil when it can't be run. Decides which plugin API coucou.js is written for.
    static func openCodeMajorVersion() -> Int? {
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode",
                          home.appendingPathComponent(".opencode/bin/opencode").path,
                          home.appendingPathComponent(".local/bin/opencode").path]
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = ["--version"]
        // stderr goes nowhere: an unread pipe that fills up would hold the process until the timeout.
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        if task.isRunning { task.terminate(); return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return openCodeMajor(fromVersionOutput: out)
    }

    /// "opencode v2.0.24" → 2, "1.4.3" → 1.
    static func openCodeMajor(fromVersionOutput out: String) -> Int? {
        guard let range = out.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
        return Int(out[range].split(separator: ".").first ?? "")
    }

    private var pendingOpenCode: PendingFileChange?

    func previewOpenCodePlugin(install: Bool) throws -> String {
        try previewGeneratedFile(&pendingOpenCode, url: Self.openCodePluginURL,
                                 label: "~/.config/opencode/plugins/coucou.js",
                                 content: install ? openCodePluginSource(hookPath: Self.hookScriptPath,
                                                                          api: Self.openCodeMajorVersion() ?? 2) : nil,
                                 noop: "No OpenCode plugin to remove.")
    }

    func writeOpenCodePlugin() throws { try writeGeneratedFile(&pendingOpenCode) }
    func removeOpenCodePlugin() throws { try removeGeneratedFile(&pendingOpenCode) }

    // MARK: Amp — ~/.config/amp/plugins/coucou.ts (generated plugin)

    static func ampPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: ampPluginURL, encoding: .utf8) else { return false }
        // A plugin from before the fix answered tool.call with "allow": count it as not
        // installed so Settings offers the safe one.
        return content.contains("nb-hook") && content.contains("'amp'") && !content.contains("action: 'allow'")
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
    /// The last approval / question card was answered: the island may auto-close again.
    static let heldCardClosed = Notification.Name("notchBuddy.heldCardClosed")
}
