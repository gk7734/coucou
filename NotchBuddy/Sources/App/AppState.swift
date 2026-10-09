import Foundation
import Observation
import SwiftUI

// Observation (not ObservableObject): a view redraws only when a property it read changes,
// so a hook event that touches `tasks` no longer re-evaluates every island view. Code that
// is not a view follows changes with ChangeObserver, or with the two hooks below.
// Fields marked @ObservationIgnored never redraw anything: per-frame values read inside
// TimelineViews/Canvases, and bookkeeping no view shows.
// Unlike a plain class's, an @Observable's property observers also run for assignments in
// init: init writes the persisted values to their backing storage (`_name`) to skip them.

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // Island state
    var mode: IslandMode = .hidden {
        willSet { modeWillSet?(newValue) }
    }
    var view: IslandView = .overview {
        didSet { viewDidSet?(view) }
    }
    /// Called synchronously on every assignment of `mode`, before it is stored (as the
    /// @Published sink was): IslandWindowController keeps its state machine in step.
    @ObservationIgnored var modeWillSet: (@MainActor (IslandMode) -> Void)?
    /// Called on every assignment of `view`, the same value included (Observation skips
    /// those): IslandWindowController makes the panel key for the chat.
    @ObservationIgnored var viewDidSet: (@MainActor (IslandView) -> Void)?

    // Tasks
    var tasks: [AgentTask] = [] {
        didSet { refreshFocus() }
    }
    /// The sessions behind each pill, by pill id (see SessionBook). A pill's own name, state
    /// and steps mirror its book's lead session, so views that predate the book keep working.
    var sessionBooks: [String: SessionBook] = [:] {
        didSet { refreshFocusBook() }
    }
    var focusId: String? = nil {
        didSet { refreshFocus(); refreshFocusBook() }
    }

    // Bot state override
    var stateOverride: BotState? = nil {
        didSet { refreshFocus() }
    }

    // Real notch dimensions (set by IslandWindowController on launch and when the island
    // changes screen). Observed: the views that place Mochi follow a new screen.
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before NotchBuddy (for window context capture). Read on click only.
    @ObservationIgnored var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    var isDraggingBot: Bool = false

    // Desktop Mochi: true while Mochi lives on the desktop instead of the notch
    var mochiOnDesktop: Bool = false

    // Mouse tracking — written 60 times a second, read inside the bots' TimelineViews.
    @ObservationIgnored var mousePosition: CGPoint = .zero
    /// False once the pointer has not moved for `absenceInterval` (IslandStateMachine):
    /// work events then leave the island hidden, alerts still open it (SPEC §3 rules 6–7).
    @ObservationIgnored var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close). Observed: the countdown bar hides.
    var isPinned: Bool = false

    // Keyboard navigation — index of the selected item within the current card's list (nil = none)
    var cardSelection: Int? = nil
    // Number of navigable items in the card currently on screen (0 = no list)
    var cardItemCount: Int = 0

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    var uploadProgress: Double = 0

    // Upload animation timing (not observed — TimelineViews read these directly)
    @ObservationIgnored var uploadStartTime: Date?
    @ObservationIgnored var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    var fileDragOver: Bool = false

    // Sound enabled — persisted
    var soundEnabled: Bool = true {
        didSet { AppDefaults.store.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Weekly recap — persisted
    var recapEnabled: Bool = (AppDefaults.store.object(forKey: "recapEnabled") as? Bool) ?? true {
        didSet { AppDefaults.store.set(recapEnabled, forKey: "recapEnabled") }
    }
    var recapHideProjects: Bool = AppDefaults.store.bool(forKey: "recapHideProjects") {
        didSet { AppDefaults.store.set(recapHideProjects, forKey: "recapHideProjects") }
    }

    // Mochi outfit selection — persisted
    var mochiOutfitSelection: Outfit = .auto {
        didSet { Outfit.stored = mochiOutfitSelection }
    }
    // A colour of the user's own for each pill's Mochi (pill id → "#RRGGBB") — persisted.
    // Empty means the catalog's colours. PillDefinition.color reads the stored value, so
    // what is built from the catalog follows on its own; the tasks already on the island
    // hold a copy of their colour and are repainted here.
    var pillColors: [String: String] = [:] {
        didSet {
            PillColors.stored = pillColors
            var repainted = tasks
            var changed = false
            for i in repainted.indices {
                guard let color = Self.pillColor(for: repainted[i].id, in: pillColors),
                      repainted[i].color != color else { continue }
                repainted[i].color = color
                changed = true
            }
            if changed { tasks = repainted }
        }
    }
    /// Picks a colour for a pill's Mochi; nil, or the pill's own catalog colour, goes back to the default.
    func setPillColor(_ id: String, _ hex: String?) {
        guard let defaultColor = Self.defaultPillColor(for: id) else { return }
        pillColors = PillColors.picking(hex, for: id, catalogColor: defaultColor, in: pillColors)
    }
    /// A pill's colour before the user picks one: the catalog's, or for an IDE pill (`ide_…`,
    /// not in the catalog) a stable palette colour. nil for other undeclared pills.
    static func defaultPillColor(for id: String) -> String? {
        if let def = PillCatalog.definition(for: id) { return def.defaultColor }
        if HostResolver.isIDEPill(id) { return HookRouting.defaultIDEColor(pillId: id) }
        return nil
    }
    /// The colour a pill is painted with, given the user's choices.
    static func pillColor(for id: String, in colors: [String: String]) -> String? {
        defaultPillColor(for: id).map { PillColors.color(for: id, catalogColor: $0, in: colors) }
    }
    // Transient: outfit preview while hovering in wardrobe (overrides resolvedOutfit in
    // BotCanvasView, which reads it every frame)
    @ObservationIgnored var wardrobePreviewOutfit: Outfit? = nil
    // Per-day seasonal cache — avoids recomputing Easter and date math on every frame.
    // Written while a view draws: must never be observed.
    @ObservationIgnored private var _seasonalCache: (dayOfYear: Int, year: Int, outfit: Outfit)?
    var resolvedOutfit: Outfit {
        if let preview = wardrobePreviewOutfit { return preview }
        guard mochiOutfitSelection == .auto else { return mochiOutfitSelection }
        let cal = Calendar.current
        let now = Date()
        let day  = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        let year = cal.component(.year, from: now)
        if let c = _seasonalCache, c.dayOfYear == day && c.year == year { return c.outfit }
        let outfit = Outfit.seasonal(for: now, calendar: cal)
        _seasonalCache = (dayOfYear: day, year: year, outfit: outfit)
        return outfit
    }

    // Claude model used by the chat and the search — persisted
    static let defaultClaudeModel = "claude-sonnet-4-6"
    var claudeModel: String = AppState.defaultClaudeModel {
        didSet { AppDefaults.store.set(claudeModel, forKey: "claudeModel") }
    }

    // In-chat provider + model — picked via the model selector in the prompt view
    var chatProvider: ChatProvider = .anthropic {
        didSet { AppDefaults.store.set(chatProvider.rawValue, forKey: "chatProvider") }
    }
    var googleChatModel: String = ChatProvider.google.defaultModel {
        didSet { AppDefaults.store.set(googleChatModel, forKey: "googleChatModel") }
    }
    var openAIChatModel: String = ChatProvider.openai.defaultModel {
        didSet { AppDefaults.store.set(openAIChatModel, forKey: "openAIChatModel") }
    }
    var ollamaChatModel: String = ChatProvider.ollama.defaultModel {
        didSet { AppDefaults.store.set(ollamaChatModel, forKey: "ollamaChatModel") }
    }
    var lmstudioChatModel: String = ChatProvider.lmstudio.defaultModel {
        didSet { AppDefaults.store.set(lmstudioChatModel, forKey: "lmstudioChatModel") }
    }
    var ollamaServerURL: String = "" {
        didSet { AppDefaults.store.set(ollamaServerURL, forKey: "ollamaServerURL") }
    }
    var lmstudioServerURL: String = "" {
        didSet { AppDefaults.store.set(lmstudioServerURL, forKey: "lmstudioServerURL") }
    }

    // The main pill (Settings → Active pills → Main), persisted as `mainPill`:
    // `PillCatalog.autoMainPillId` (the default, also when the key is missing) or a
    // "Where you code" pill the user picked.
    var mainPillChoice: String = PillCatalog.autoMainPillId {
        didSet {
            AppDefaults.store.set(mainPillChoice, forKey: "mainPill")
            // A picked main is never one of the active pills (as before Auto).
            if mainPillChoice != PillCatalog.autoMainPillId { activeIntegrations.remove(mainPillChoice) }
            refreshMainPill()
        }
    }

    /// The always-on workspace pill on the island: the picked one, or for Auto the last
    /// workspace pill the user worked in (AutoMainPill; `integration_claude` before any).
    /// Never removed (only reset, see removeTask) nor toggled. Stored, and reassigned only
    /// when it changes, so views reading it don't redraw on every hook event.
    private(set) var mainPillId: String = PillCatalog.defaultMainPillId

    /// The last workspace pill a session event moved the Auto main to, and for an IDE pill
    /// its app's bundle id (an `ide_` id can't be turned back into one): after a relaunch the
    /// Auto main shows that IDE again. Persisted as `lastActiveWorkspacePill` and
    /// `lastActiveWorkspaceBundleId`. Not observed: views read mainPillId.
    @ObservationIgnored private var lastActiveWorkspacePill: String?
    @ObservationIgnored private var lastActiveWorkspaceBundleId: String?

    // Dynamically fetched model lists for the in-chat picker (keyed by provider)
    var fetchedProviderModels: [ChatProvider: [(id: String, label: String)]] = [:]
    var providerModelFetchError: [ChatProvider: String] = [:]
    var loadingProviderModels: Set<ChatProvider> = []

    /// Fetches models for `provider` if not already loaded or loading.
    /// Sets `providerModelFetchError` if the key is absent or the request fails.
    func fetchModelsIfNeeded(for provider: ChatProvider) {
        guard !loadingProviderModels.contains(provider),
              fetchedProviderModels[provider] == nil else { return }
        // Local providers: fetch from server URL (no API key needed)
        if provider.isLocal {
            let baseURL = provider == .ollama ? ollamaServerURL : lmstudioServerURL
            let normalised = LocalChat.normaliseURL(baseURL)
            guard !normalised.isEmpty else {
                providerModelFetchError[provider] = provider == .ollama
                    ? "Connect Ollama in Settings → Chat first."
                    : "Connect LM Studio in Settings → Chat first."
                return
            }
            loadingProviderModels.insert(provider)
            providerModelFetchError.removeValue(forKey: provider)
            Task {
                let result = await LocalChat.fetchModelsResult(baseURL: normalised)
                loadingProviderModels.remove(provider)
                switch result {
                case .success(let models) where models.isEmpty:
                    providerModelFetchError[provider] = provider == .ollama
                        ? "No models yet. Download one in Ollama first."
                        : "No models yet. Download one in LM Studio first."
                case .success(let models):
                    fetchedProviderModels[provider] = models
                    let current = provider == .ollama ? ollamaChatModel : lmstudioChatModel
                    if !models.contains(where: { $0.id == current }) {
                        let first = models.first!.id
                        if provider == .ollama { ollamaChatModel = first }
                        else                   { lmstudioChatModel = first }
                    }
                case .failure:
                    providerModelFetchError[provider] = "Cannot reach \(normalised). Is the server running?"
                }
            }
            return
        }
        // Remote providers: require API key
        guard let apiKey = KeychainStore.shared.get(provider.keychainKey), !apiKey.isEmpty else {
            providerModelFetchError[provider] = "No API key — add it in Settings."
            return
        }
        loadingProviderModels.insert(provider)
        providerModelFetchError.removeValue(forKey: provider)
        Task {
            let models: [(id: String, label: String)]
            switch provider {
            case .anthropic: models = await ClaudeService.fetchModels(apiKey: apiKey)
            case .google:    models = await ClaudeService.fetchGoogleModels(apiKey: apiKey)
            case .openai:    models = await ClaudeService.fetchOpenAIModels(apiKey: apiKey)
            case .ollama, .lmstudio: models = []  // handled above
            }
            loadingProviderModels.remove(provider)
            if models.isEmpty {
                providerModelFetchError[provider] = "Failed to load models. Check your API key."
            } else {
                fetchedProviderModels[provider] = models
                switch provider {
                case .anthropic:
                    if !models.contains(where: { $0.id == claudeModel }) {
                        claudeModel = models.first(where: { $0.id.contains("sonnet") })?.id ?? models.first!.id
                    }
                case .google:
                    if !models.contains(where: { $0.id == googleChatModel }) {
                        googleChatModel = models.first(where: { $0.id.contains("flash") })?.id ?? models.first!.id
                    }
                case .openai:
                    if !models.contains(where: { $0.id == openAIChatModel }) {
                        openAIChatModel = models.first(where: { $0.id.contains("mini") })?.id ?? models.first!.id
                    }
                case .ollama, .lmstudio: break
                }
            }
        }
    }

    /// The model currently active for chat (provider-aware).
    var activeChatModel: String {
        switch chatProvider {
        case .anthropic: return claudeModel
        case .google:    return googleChatModel
        case .openai:    return openAIChatModel
        case .ollama:    return ollamaChatModel
        case .lmstudio:  return lmstudioChatModel
        }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    var soundVolume: Double = 0.12 {
        didSet {
            AppDefaults.store.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Selected app language ("" = System, else BCP-47 code e.g. "fr")
    var appLanguage: String = {
        let bundleId = Bundle.main.bundleIdentifier ?? "fr.louisraille.NotchBuddy"
        let langs = UserDefaults.standard.persistentDomain(forName: bundleId)?["AppleLanguages"] as? [String]
        return langs?.first ?? ""
    }()

    // Context for prompt (window attach / file)
    var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    var noteMessage: String? = nil

    // Auto-close delay — persisted
    // Hovering the island opens it (folds shortly after the pointer leaves) — persisted, off by default
    var openOnHover: Bool = false {
        didSet { AppDefaults.store.set(openOnHover, forKey: "openOnHover") }
    }
    var autoCloseInterval: TimeInterval = 15 {
        didSet { AppDefaults.store.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // No pointer movement for this long hides the compact island (SPEC §3 rule 6) — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { AppDefaults.store.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    var hotkeyEnabled: Bool = false {
        didSet { AppDefaults.store.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { AppDefaults.store.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { AppDefaults.store.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Screen hosting the island (notch screen by default) — persisted
    var islandDisplay: IslandDisplayChoice = .notch {
        didSet { AppDefaults.store.set(islandDisplay.storageValue, forKey: "islandDisplay") }
    }

    // Vercel project filter — empty = watch all projects
    var vercelProjectFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(vercelProjectFilter)) {
                AppDefaults.store.set(data, forKey: "vercelProjectFilter")
            }
        }
    }

    // n8n workflow filter — empty = watch all workflows
    var n8nWorkflowFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(n8nWorkflowFilter)) {
                AppDefaults.store.set(data, forKey: "n8nWorkflowFilter")
            }
        }
    }

    // Active integration pills (main workspace pill excluded). Max 4.
    var activeIntegrations: Set<String> = ["integration_resend", "integration_n8n", "integration_vercel", "integration_github"] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(activeIntegrations)) {
                AppDefaults.store.set(data, forKey: "activeIntegrations")
            }
            // Clear stale GitHub data when the integration is disabled
            if !activeIntegrations.contains("integration_github") && oldValue.contains("integration_github") {
                githubPulse = nil
                githubActivity = nil
            }
        }
    }

    /// The music pill on the island because music plays (AutoMusicPill), not because the
    /// user declared it: not in activeIntegrations, so it doesn't count against their 4.
    /// Set by MusicPillDriver through setAutoMusicPill (GitHub build); nil otherwise.
    @ObservationIgnored private(set) var autoMusicPillId: String? = nil

    // Pending API result
    var searchResult: SearchResult? = nil

    // Vercel deployments (populated by VercelPoller)
    var vercelDeployments: [VercelDeployment] = []

    // Resend emails (populated by ResendPoller)
    var resendEmails: [ResendEmail] = []
    var resendTotal: Int? = nil

    // GitHub stats + pulse + activity (populated by GithubPoller)
    var githubStats: GitHubStats? = nil
    var githubPulse: GitHubPulse? = nil
    var githubActivity: GitHubActivity? = nil

    // Stripe (populated by StripePoller)
    var stripePayments: [StripePayment] = []
    var stripeBalance: Int = 0           // raw balance in cents
    var stripeDisplayBalance: Int = 0    // animated balance target
    var stripeCurrency: String = "eur"
    var stripeLoaded: Bool = false       // true after first successful poll
    var stripeError: String? = nil      // last API error (nil = ok)

    // Cal.com (populated by CalcomPoller)
    var calcomBookings: [CalcomBooking] = []
    var calcomLoaded: Bool = false
    var calcomError: String? = nil

    // Notion (populated by NotionPoller)
    var notionPages: [NotionPage] = []
    var notionLoaded: Bool = false
    var notionError: String? = nil

    // n8n — the last executions, newest first (for the iPhone; the notch shows only the latest)
    var n8nRuns: [N8nRun] = []

    // Chat conversation history
    var chatHistory: [ChatMessage] = []

    // Pending approval request from Claude Code hook
    var pendingApproval: ApprovalInfo? = nil

    // Pending AskUserQuestion from Claude Code hook
    var pendingQuestion: AskQuestion? = nil {
        didSet {
            // A new question starts from the estimate until its card has been measured.
            questionContentHeight = nil
            QuestionLayout.height = pendingQuestion?.estimatedIslandHeight
        }
    }

    /// Measured height of the question card's content (QuestionView), so the island fits
    /// the question actually shown: the current one of several, the "Other…" field, wide
    /// scripts like Korean that the character-count estimate gets wrong.
    var questionContentHeight: CGFloat? = nil {
        didSet {
            guard let h = questionContentHeight else { return }
            QuestionLayout.height = QuestionLayout.islandHeight(contentHeight: h)
        }
    }

    // Per-pill flat list of FileDiffs, in order of reception.
    // Not observed — the steps[] change that comes with each diff already redraws.
    @ObservationIgnored var sessionDiffs: [String: [FileDiff]] = [:]
    @ObservationIgnored private var sessionDiffTimers: [String: DispatchWorkItem] = [:]
    // Monotonically increasing — never reset, not even in clearSessionDiffs.
    @ObservationIgnored private var nextDiffId: Int = 0

    @discardableResult
    func appendSessionDiff(_ diff: FileDiff, for pillId: String) -> Int {
        var d = diff
        d.id = nextDiffId
        nextDiffId += 1
        if sessionDiffs[pillId] == nil { sessionDiffs[pillId] = [] }
        sessionDiffs[pillId]!.append(d)
        // Keep at most 50 diffs per pill; drop oldest first
        while sessionDiffs[pillId]!.count > 50 {
            sessionDiffs[pillId]!.removeFirst()
        }
        resetSessionDiffTimer(for: pillId)
        return d.id
    }

    func clearSessionDiffs(for pillId: String) {
        sessionDiffTimers[pillId]?.cancel()
        sessionDiffTimers.removeValue(forKey: pillId)
        sessionDiffs.removeValue(forKey: pillId)
        // nextDiffId intentionally NOT reset — ids remain unique across sessions
    }

    private func resetSessionDiffTimer(for pillId: String) {
        sessionDiffTimers[pillId]?.cancel()
        // The closure is MainActor-isolated (AppState is @MainActor): it must run on the main
        // queue. Scheduled on a global queue, Swift 6's isolation check traps and the app quits.
        let work = DispatchWorkItem { [weak self] in
            self?.clearSessionDiffs(for: pillId)
        }
        sessionDiffTimers[pillId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600, execute: work)
    }

    #if !APPSTORE
    var musicPlaying: Bool = false
    var musicAutomationDenied: Bool = false
    #endif

    // Claude plan gauge (from statusline hook)
    var claudePlanUsage: PlanUsage? = nil {
        didSet {
            if let u = claudePlanUsage,
               let data = try? JSONEncoder().encode(u) {
                AppDefaults.store.set(data, forKey: "claudePlanUsage")
            }
        }
    }

    // Plan gauge: show pill in notch header — persisted
    #if !APPSTORE
    var showPlanInNotch: Bool = false {
        didSet { AppDefaults.store.set(showPlanInNotch, forKey: "showPlanInNotch") }
    }
    // In-memory plan usage override for demo mode. Never persisted. Set by DemoEngine.
    var demoPlanUsageOverride: PlanUsage? = nil
    // Cached relay-installed state — updated at launch, after install/uninstall, on Settings open
    var planRelayInstalled: Bool = false
    // Transient — reset when island closes or view changes
    var showingPlanDetail: Bool = false

    // Codex plan gauge (from `codex app-server`) — fetched when the pill shows
    var showCodexPlanInNotch: Bool = false {
        didSet { AppDefaults.store.set(showCodexPlanInNotch, forKey: "showCodexPlanInNotch") }
    }
    var codexPlanUsage: CodexPlanUsage? = nil
    // Which card showingPlanDetail opens
    var planDetailIsCodex: Bool = false

    func refreshCodexPlanUsage() {
        if let u = codexPlanUsage, Date().timeIntervalSince(u.updatedAt) < 60 { return }
        Task {
            if let u = await CodexPlanGauge.fetch() { codexPlanUsage = u }
        }
    }

    func refreshPlanRelayState() {
        planRelayInstalled = HookServer.statusLineInstalled()
    }
    #endif

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = AppDefaults.store

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { _soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { _soundVolume  = v }
        _mochiOutfitSelection = Outfit.stored
        _pillColors = PillColors.stored
        if let v = ud.string(forKey: "claudeModel"),
           !v.trimmingCharacters(in: .whitespaces).isEmpty { _claudeModel = v }
        if let v = ud.string(forKey: "chatProvider"), let p = ChatProvider(rawValue: v) { _chatProvider = p }
        if let v = ud.string(forKey: "googleChatModel"), !v.isEmpty { _googleChatModel = v }
        if let v = ud.string(forKey: "openAIChatModel"), !v.isEmpty { _openAIChatModel = v }
        if let v = ud.string(forKey: "ollamaChatModel"), !v.isEmpty { _ollamaChatModel = v }
        if let v = ud.string(forKey: "lmstudioChatModel"), !v.isEmpty { _lmstudioChatModel = v }
        if let v = ud.string(forKey: "ollamaServerURL"), !v.isEmpty { _ollamaServerURL = v }
        if let v = ud.string(forKey: "lmstudioServerURL"), !v.isEmpty { _lmstudioServerURL = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "openOnHover") as? Bool { _openOnHover = v }
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            _autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { _absenceInterval   = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { _hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { _hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { _hotkeyCode = UInt16(v) }
        if let v = ud.string(forKey: "islandDisplay") { _islandDisplay = IslandDisplayChoice(storageValue: v) }
        if let d = ud.data(forKey: "vercelProjectFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { _vercelProjectFilter = Set(a) }
        if let d = ud.data(forKey: "n8nWorkflowFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { _n8nWorkflowFilter = Set(a) }
        if let d = ud.data(forKey: "activeIntegrations"),
           let a = try? JSONDecoder().decode([String].self, from: d) { _activeIntegrations = Set(a) }
        // Missing, "auto", or a pill this build doesn't have: Auto.
        if let v = ud.string(forKey: "mainPill"), PillCatalog.workspaceIds.contains(v) {
            _mainPillChoice = v
        }
        lastActiveWorkspacePill = ud.string(forKey: "lastActiveWorkspacePill")
        lastActiveWorkspaceBundleId = ud.string(forKey: "lastActiveWorkspaceBundleId")
        _mainPillId = resolveMainPill()
        if let d = ud.data(forKey: "claudePlanUsage"),
           let u = try? JSONDecoder().decode(PlanUsage.self, from: d) { _claudePlanUsage = u }
        #if !APPSTORE
        if let v = ud.object(forKey: "showPlanInNotch") as? Bool { _showPlanInNotch = v }
        if let v = ud.object(forKey: "showCodexPlanInNotch") as? Bool { _showCodexPlanInNotch = v }
        _planRelayInstalled = HookServer.statusLineInstalled()
        #endif

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Focus (derived, stored)

    /// The focused pill's task (the first one when none is focused). Stored, and reassigned
    /// only when it changes: views that show the focused pill don't redraw for every event
    /// of the other pills.
    private(set) var focusTask: AgentTask?

    /// What the main Mochi shows: the override, else the focused pill's state. Stored like
    /// focusTask, so Mochi's views redraw when the state changes, not on every step.
    private(set) var effectiveState: BotState = .idle

    /// The focused pill's session book, `sessionBooks[focusId]`. Stored like focusTask.
    private(set) var focusBook: SessionBook?

    /// A pill's session book. The focused pill's is read from focusBook, so a view showing
    /// it only redraws when that book changes, not when another pill's does.
    func sessionBook(for pillId: String) -> SessionBook? {
        pillId == focusId ? focusBook : sessionBooks[pillId]
    }

    /// Keeps focusTask and effectiveState in step with tasks, focusId and stateOverride.
    private func refreshFocus() {
        let task = tasks.first { $0.id == focusId } ?? tasks.first
        if task != focusTask { focusTask = task }
        let state = stateOverride ?? task?.state ?? .idle
        if state != effectiveState { effectiveState = state }
    }

    /// Keeps focusBook in step with sessionBooks and focusId.
    private func refreshFocusBook() {
        let book = focusId.flatMap { sessionBooks[$0] }
        if book != focusBook { focusBook = book }
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        // mainPillId: always reset, never remove (the active workspace tool)
        // activeIntegrations: also reset (user declared it active, keep it as idle)
        let isProtected = id == mainPillId
        let isActiveDecl = PillCatalog.definition(for: id) != nil && activeIntegrations.contains(id)
        if isProtected || isActiveDecl {
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                let catalogName = PillCatalog.definition(for: id)?.name
                tasks[idx].state      = .idle
                tasks[idx].steps      = []
                tasks[idx].stepIndex  = 0
                tasks[idx].pillBadge  = nil
                if let n = catalogName { tasks[idx].name = n }
                // The Claude Code pill names its session's app ("VS Code", "Warp"…): that
                // session is gone. (An IDE pill keeps its app, it is the pill's name and icon.)
                if id == "integration_claude" {
                    tasks[idx].hostApp = nil
                    tasks[idx].sessionBundleId = nil
                }
            }
            return
        }
        // Undeclared or declared-but-not-active: remove
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = mainPillId }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func setPillBadge(_ badge: PillBadge, for id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].pillBadge = badge
    }

    /// Called on main thread after each GitHub pulse poll. Fires badge + sound based on events.
    func handleGitHubEvents(_ events: [GitHubEvent]) {
        guard !events.isEmpty else { return }
        // Priority: error > question (reviewRequested) > finish (ciPassed)
        var level = 0          // 0 = none, 1 = finish, 2 = question, 3 = error
        var badge: PillBadge?
        var sound: String?
        for event in events {
            switch event {
            case .ciFailed, .mainFailed:
                if level < 3 { level = 3; badge = .error;    sound = "error"    }
            case .reviewRequested:
                if level < 2 { level = 2; badge = .finished; sound = "question" }
            case .ciPassed:
                if level < 1 { level = 1; badge = .finished; sound = "finish"   }
            }
        }
        // Only set badge when the GitHub pill is not currently in focus
        if let b = badge, focusId != "integration_github" { setPillBadge(b, for: "integration_github") }
        if let s = sound { SoundEngine.shared.play(s) }
    }

    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load catalog pills into tasks, respecting activeIntegrations. Safe to call multiple times.
    func loadIntegrationTasks() {
        let catalog = PillCatalog.available
        // Sanitize: remove saved IDs not in catalog
        let catalogIds = Set(catalog.map { $0.id })
        activeIntegrations = activeIntegrations.filter { catalogIds.contains($0) }
        // A picked main is never in activeIntegrations (migration + invariant). The Auto main
        // may be: it stays declared, so it doesn't vanish when the main moves on.
        if mainPillChoice != PillCatalog.autoMainPillId { activeIntegrations.remove(mainPillId) }
        ensureMainTask()
        for def in catalog {
            // mainPillId always loads; activeIntegrations load; so does the auto music pill
            let shouldLoad = def.id == mainPillId || activeIntegrations.contains(def.id)
                || def.id == autoMusicPillId
            let loaded = tasks.contains(where: { $0.id == def.id })
            if shouldLoad && !loaded {
                let task = AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source, isIntegration: true)
                tasks.append(task)
            }
            // A pill with sessions stays: it goes with them (HookServer).
            if !shouldLoad && loaded && !hasSessions(def.id) {
                tasks.removeAll { $0.id == def.id }
            }
        }
        sortTasksByCatalog()
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    /// Toggle a catalog pill on/off.
    /// mainPillId: never toggleable (change via the Main picker first).
    /// Max 4 non-main pills active at once.
    func toggleIntegration(_ id: String) {
        guard id != mainPillId else { return }
        guard PillCatalog.available.contains(where: { $0.id == id }) else { return }
        if activeIntegrations.contains(id) {
            activeIntegrations.remove(id)
            // The music pill showing because music plays stays until the music stops.
            if id != autoMusicPillId {
                tasks.removeAll { $0.id == id }
                if focusId == id { focusId = mainPillId }
            }
        } else {
            guard activeIntegrations.count < 4 else { return }
            activeIntegrations.insert(id)
            if let def = PillCatalog.available.first(where: { $0.id == id }),
               !tasks.contains(where: { $0.id == id }) {
                let task = AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source, isIntegration: true)
                tasks.append(task)
                sortTasksByCatalog()
            }
        }
        syncMode()
    }

    /// Sort tasks: the main pill first, then the pills the catalog doesn't declare (IDEs,
    /// third-party agents: HookServer inserts them right after the main pill), then the
    /// catalog's pills in catalog order. Writes `tasks` only when the order changes.
    private func sortTasksByCatalog() {
        let order = PillCatalog.available.enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        // The auto music pill, undeclared, goes with the undeclared pills: the overview shows
        // the first four after the main, and it would otherwise come last.
        let autoMusic       = autoMusicPillId.flatMap { activeIntegrations.contains($0) ? nil : $0 }
        let isUndeclared    = { (t: AgentTask) in order[t.id] == nil || t.id == autoMusic }
        let main            = tasks.filter { $0.id == mainPillId }
        let others          = tasks.filter { $0.id != mainPillId }
        let undeclaredPills = others.filter(isUndeclared)
        let sortedCatalog   = others.filter { !isUndeclared($0) }
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        let result = main + undeclaredPills + sortedCatalog
        if result.map(\.id) != tasks.map(\.id) { tasks = result }
    }

    #if !APPSTORE
    /// Shows `id` as the auto music pill (nil: none), as AutoMusicPill decided. The pill
    /// it replaces leaves unless it is declared, the main pill or has sessions.
    func setAutoMusicPill(_ id: String?) {
        let old = autoMusicPillId
        guard id != old else { return }
        autoMusicPillId = id
        var kept = activeIntegrations
        kept.insert(mainPillId)
        if let old, hasSessions(old) { kept.insert(old) }
        let change = AutoMusicPill.transition(from: old, to: id, kept: kept)
        if let remove = change.remove {
            tasks.removeAll { $0.id == remove }
            if focusId == remove { focusId = mainPillId }
        }
        if let add = change.add, !tasks.contains(where: { $0.id == add }),
           let def = PillCatalog.available.first(where: { $0.id == add }) {
            tasks.append(AgentTask(id: def.id, name: def.name, color: def.color,
                                   state: .idle, steps: [], source: def.source, isIntegration: true))
        }
        sortTasksByCatalog()
        if focusId == nil { focusId = mainPillId }
        syncMode()
        syncView()
    }
    #endif

    // MARK: - Main pill (Auto)

    /// The main pill for the current choice and the last active workspace pill.
    private func resolveMainPill() -> String {
        AutoMainPill.resolve(
            explicit: mainPillChoice == PillCatalog.autoMainPillId ? nil : mainPillChoice,
            lastActive: lastActiveWorkspacePill, lastActiveBundleId: lastActiveWorkspaceBundleId,
            catalogWorkspaceIds: PillCatalog.workspaceIds, fallback: PillCatalog.defaultMainPillId,
            isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    /// A session event on a pill (HookServer): makes it the last active workspace pill when
    /// AutoMainPill.shouldSwitch says so, which moves the Auto main there.
    /// `hostBundleId`: the app the session runs in (an IDE pill needs it to be shown again).
    func noteWorkspaceActivity(pillId: String, hostBundleId: String?, activity: AutoMainPill.Activity) {
        guard AutoMainPill.isWorkspacePill(pillId, catalogWorkspaceIds: PillCatalog.workspaceIds) else { return }
        let current = lastActiveWorkspacePill
        let currentIsBusy = current.map { id in
            sessionBooks[id]?.sessions.contains { $0.phase == .working || $0.phase.waitsOnUser } ?? false
        } ?? false
        guard AutoMainPill.shouldSwitch(current: current, to: pillId, activity: activity,
                                        currentIsBusy: currentIsBusy) else { return }
        var bundleId: String? = nil
        if HostResolver.isIDEPill(pillId) {
            guard let id = hostBundleId, !id.isEmpty, HostResolver.idePillId(bundleId: id) == pillId else { return }
            bundleId = id
        }
        lastActiveWorkspacePill = pillId
        lastActiveWorkspaceBundleId = bundleId
        let ud = AppDefaults.store
        ud.set(pillId, forKey: "lastActiveWorkspacePill")
        if let bundleId { ud.set(bundleId, forKey: "lastActiveWorkspaceBundleId") }
        else { ud.removeObject(forKey: "lastActiveWorkspaceBundleId") }
        refreshMainPill()
    }

    /// Recomputes the main pill. When it moves, the new main's pill shows (created if
    /// needed) and the former one leaves unless it is still declared or has sessions: no
    /// pill is lost, none doubled. Not during the demo, which restores the island around the
    /// main pill it started with (DemoEngine.stop calls this again).
    func refreshMainPill() {
        guard !DemoEngine.shared.isActive else { return }
        let resolved = resolveMainPill()
        guard resolved != mainPillId else { return }
        let former = mainPillId
        mainPillId = resolved
        ensureMainTask()
        if former != resolved, !activeIntegrations.contains(former), !hasSessions(former),
           tasks.contains(where: { $0.id == former }) {
            tasks.removeAll { $0.id == former }
            if focusId == former { focusId = mainPillId }
        }
        sortTasksByCatalog()
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    /// The main pill's name as Settings shows it ("Orca", "VS Code", "Claude Code"…).
    var mainPillDisplayName: String {
        let id = mainPillId
        let task = tasks.first { $0.id == id }
        if id == "integration_claude" {
            return ClaudeHost.pillName(hostApp: task?.hostApp, sessionBundleId: task?.sessionBundleId)
        }
        if let def = PillCatalog.definition(for: id) { return def.name }
        if let task, !task.name.isEmpty { return task.name }
        return lastActiveWorkspaceBundleId.map(HostAppInfo.name(for:)) ?? id
    }

    /// Adds the main pill's task when it isn't on the island: a catalog pill from the
    /// catalog, an IDE pill from its app (as HookServer creates it).
    private func ensureMainTask() {
        let id = mainPillId
        guard !tasks.contains(where: { $0.id == id }) else { return }
        if let def = PillCatalog.definition(for: id) {
            tasks.append(AgentTask(id: def.id, name: def.name, color: def.color,
                                   state: .idle, steps: [], source: def.source, isIntegration: true))
        } else if HostResolver.isIDEPill(id), let bundleId = lastActiveWorkspaceBundleId, !bundleId.isEmpty {
            var task = AgentTask(id: id, name: HostAppInfo.name(for: bundleId),
                                 color: Self.pillColor(for: id, in: pillColors) ?? HookRouting.defaultIDEColor(pillId: id),
                                 state: .idle, steps: [], source: .agent, isIntegration: true)
            task.sessionBundleId = bundleId
            tasks.append(task)
        }
    }

    /// True when a pill's book holds sessions.
    private func hasSessions(_ pillId: String) -> Bool {
        !(sessionBooks[pillId]?.isEmpty ?? true)
    }

}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
}

struct DroppedFile {
    var url: URL
    var name: String
}

struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

struct VercelDeployment: Identifiable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // "READY", "ERROR", "CANCELED"
    let createdAt: Date
    let commitMessage: String?
    let branch: String?

    var isSuccess: Bool { state == "READY" }
    var statusLabel: String { isSuccess ? "Ready" : (state == "CANCELED" ? "Canceled" : "Error") }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Resend

struct ResendEmail: Identifiable {
    let id: String
    let to: [String]
    let subject: String
    let createdAt: Date
    let lastEvent: String   // "delivered", "bounced", "complained", "opened", etc.

    var recipientShort: String {
        guard let first = to.first else { return "?" }
        return first.components(separatedBy: "@").first ?? first
    }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
    var isDelivered: Bool { lastEvent == "delivered" }
}

// MARK: - GitHub

struct GitHubStats {
    let totalRepos: Int
    let totalStars: Int
}

// MARK: - Stripe

struct StripePayment: Identifiable, Equatable {
    let id: String
    let amount: Int         // in cents/smallest unit
    let currency: String
    let description: String?
    let createdAt: Date
    let status: String      // "succeeded", "pending", "failed"

    var amountFormatted: String { String(format: "%.2f", Double(amount) / 100.0) }
    var isSuccess: Bool { status == "succeeded" }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Cal.com

struct CalcomBooking: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Date
    let endTime: Date
    let status: String
    let attendeeName: String?
    let attendeeEmail: String?
    let attendeeNotes: String?

    /// API v2 sends lowercase statuses ("accepted"), the demo data uppercase ones.
    var isActive: Bool {
        let s = status.uppercased()
        return s == "ACCEPTED" || s == "PENDING"
    }
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: startTime)
    }
    var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: startTime)
        return "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
    }
}

// MARK: - Notion

struct N8nRun: Equatable {
    let workflow: String
    let detail: String?
    let success: Bool
    let date: Date
}

struct NotionPage: Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let lastEditedAt: Date
    let url: String

    var timeAgo: String {
        let diff = Date().timeIntervalSince(lastEditedAt)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Chat

enum ChatRole { case user, assistant }

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var content: String   // var for streaming updates
}
