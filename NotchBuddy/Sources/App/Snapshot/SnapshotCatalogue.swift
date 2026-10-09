#if DEBUG
import AppKit
import SwiftUI

/// One snapshot: its file name (`<name>.png`) and how to build its state and view.
struct SnapshotCase {
    let name: String
    let make: @MainActor () throws -> SnapshotScenePlan
}

/// The fixed list of states scripts/snapshot.sh renders and compares (tests/snapshots/).
/// Each case builds AppState from scratch: the same input gives the same pixels.
@MainActor
enum SnapshotCatalogue {
    static var cases: [SnapshotCase] {
        compactCases + expandedCases + settingsCases
    }

    // MARK: Screens

    /// A MacBook's notch, and a screen without one (a bar at the top centre).
    private struct Screen {
        let suffix: String
        let width: CGFloat
        let height: CGFloat
        let hasNotch: Bool
        static let notch = Screen(suffix: "notch", width: 185, height: 32, hasNotch: true)
        static let bar   = Screen(suffix: "bar", width: 80, height: 24, hasNotch: false)
    }

    // MARK: Fixtures

    static let webStormBundleId = "com.jetbrains.WebStorm"
    static var webStormPillId: String { HostResolver.idePillId(bundleId: webStormBundleId) }

    /// "Now": every date is relative to it, so elapsed times read the same on every run.
    private static var now: Date { Date() }

    private static func catalogTask(_ id: String, state: BotState = .idle) -> AgentTask {
        let def = PillCatalog.definition(for: id)!
        return AgentTask(id: id, name: def.name, color: def.color, state: state, steps: [],
                         source: def.source, isIntegration: true)
    }

    private static func webStormTask(state: BotState, steps: [String] = []) -> AgentTask {
        var task = AgentTask(id: webStormPillId, name: "WebStorm",
                             color: HookRouting.defaultIDEColor(pillId: webStormPillId),
                             state: state, steps: steps, source: .agent, isIntegration: true)
        task.sessionBundleId = webStormBundleId
        return task
    }

    /// The pills of a fresh install: Claude Code (the main pill) and the four default services.
    private static func defaultTasks(claude: BotState = .idle) -> [AgentTask] {
        [catalogTask("integration_claude", state: claude),
         catalogTask("integration_resend"), catalogTask("integration_n8n"),
         catalogTask("integration_vercel"), catalogTask("integration_github")]
    }

    private static func session(_ id: String, agent: String = "claude", project: String,
                                phase: SessionPhase, steps: [String] = [], finalLine: String? = nil,
                                startedMinutesAgo: Double, lastEventMinutesAgo: Double = 0.2,
                                turnMinutesAgo: Double? = nil) -> AgentSession {
        AgentSession(id: id, agent: agent, projectName: project, cwd: "/Users/dev/\(project)",
                     phase: phase, steps: steps, finalLine: finalLine,
                     startedAt: now.addingTimeInterval(-startedMinutesAgo * 60),
                     lastEventAt: now.addingTimeInterval(-lastEventMinutesAgo * 60),
                     turnStartedAt: turnMinutesAgo.map { now.addingTimeInterval(-$0 * 60) })
    }

    /// Puts AppState (and the compact line) back to a known state for one case.
    private static func reset(mode: IslandMode, view: IslandView = .overview, screen: Screen = .notch,
                              tasks: [AgentTask], focus: String, books: [String: SessionBook] = [:]) {
        let s = AppState.shared
        SnapshotScene.questionShowsOther = false
        s.pendingApproval = nil
        s.pendingQuestion = nil
        s.questionContentHeight = nil
        s.chatHistory = []
        s.promptContext = nil
        s.stateOverride = nil
        s.isPinned = false
        s.cardSelection = nil
        s.isDraggingBot = false
        s.mochiOnDesktop = false
        s.fileDragOver = false
        #if !APPSTORE
        s.showingPlanDetail = false
        #endif
        s.notchWidth = screen.width
        s.notchHeight = screen.height
        s.hasNotch = screen.hasNotch
        s.tasks = tasks
        s.sessionBooks = books
        s.focusId = focus
        s.view = view
        s.mode = mode
        CompactStatusModel.shared.showForSnapshot(line: nil, music: nil, levels: nil, hasMinis: tasks.count > 1)
    }

    private static func island() -> SnapshotScenePlan {
        SnapshotScenePlan(view: AnyView(IslandRootView()
                                            .environment(AppState.shared)
                                            .environment(\.layoutDirection, .leftToRight)),
                          size: CGSize(width: IslandConst.panelWidth, height: IslandConst.panelHeight),
                          cropToContent: true)
    }

    // MARK: Compact

    static let bands: [Float] = [0.35, 0.62, 0.88, 0.71, 0.95, 0.52, 0.78, 0.4, 0.6, 0.3, 0.48, 0.22]

    private static var compactCases: [SnapshotCase] {
        [Screen.notch, Screen.bar].flatMap { screen -> [SnapshotCase] in [
            SnapshotCase(name: "compact-plain-\(screen.suffix)") {
                reset(mode: .compact, screen: screen, tasks: defaultTasks(), focus: "integration_claude")
                return island()
            },
            SnapshotCase(name: "compact-status-thinking-\(screen.suffix)") {
                let ide = webStormTask(state: .thinking)
                reset(mode: .compact, screen: screen, tasks: [ide] + defaultTasks(), focus: ide.id)
                CompactStatusModel.shared.showForSnapshot(
                    line: CompactStatusLine(pillId: ide.id, pillName: "WebStorm",
                                            activity: CompactActivity(kind: .thinking, detail: ""),
                                            turnStartedAt: now.addingTimeInterval(-20)),
                    music: nil, levels: nil, hasMinis: true)
                return island()
            },
            SnapshotCase(name: "compact-status-waiting-\(screen.suffix)") {
                let ide = webStormTask(state: .approval)
                reset(mode: .compact, screen: screen, tasks: [ide] + defaultTasks(), focus: ide.id)
                CompactStatusModel.shared.showForSnapshot(
                    line: CompactStatusLine(pillId: ide.id, pillName: "WebStorm",
                                            activity: CompactActivity(kind: .needsOK, detail: "npm test"),
                                            turnStartedAt: nil),
                    music: nil, levels: nil, hasMinis: true)
                return island()
            },
            SnapshotCase(name: "compact-visualizer-tidal-\(screen.suffix)") {
                reset(mode: .compact, screen: screen, tasks: defaultTasks(), focus: "integration_claude")
                CompactStatusModel.shared.showForSnapshot(
                    line: nil, music: CompactMusicLine(source: .tidal, headline: "TIDAL", subline: ""),
                    levels: bands, hasMinis: true)
                return island()
            },
            SnapshotCase(name: "compact-visualizer-track-\(screen.suffix)") {
                reset(mode: .compact, screen: screen, tasks: defaultTasks(), focus: "integration_claude")
                CompactStatusModel.shared.showForSnapshot(
                    line: nil, music: CompactMusicLine(source: .tidal, headline: "Midnight City", subline: "M83"),
                    levels: bands, hasMinis: true)
                return island()
            },
        ] }
    }

    // MARK: Expanded

    /// Two questions in Korean whose options have long descriptions: the card that once
    /// floated in an island far taller than it.
    static let koreanQuestion = AskQuestion(questions: [
        AskQuestionItem(
            question: "인증 미들웨어를 어떤 방식으로 리팩터링할까요? 기존 세션 쿠키와의 호환성을 유지해야 합니다.",
            header: "리팩터링",
            options: [
                AskQuestionOption(label: "JWT로 전환",
                                  description: "세션 쿠키를 JWT 액세스 토큰과 리프레시 토큰으로 바꾸고, 기존 쿠키는 한 번의 배포 주기 동안 계속 받아들입니다."),
                AskQuestionOption(label: "세션 유지",
                                  description: "지금의 서버 세션을 그대로 두고 미들웨어만 작은 함수들로 나누어 테스트하기 쉽게 만듭니다."),
                AskQuestionOption(label: "단계적 이전",
                                  description: "새 엔드포인트에서만 JWT를 쓰고 나머지는 다음 스프린트에서 옮깁니다. 두 방식이 잠시 함께 동작합니다."),
            ],
            multiSelect: false),
        AskQuestionItem(
            question: "테스트는 어디까지 작성할까요?",
            header: "테스트",
            options: [
                AskQuestionOption(label: "단위 테스트만",
                                  description: "미들웨어 함수마다 단위 테스트를 추가합니다. 빠르지만 실제 요청 흐름은 확인하지 않습니다."),
                AskQuestionOption(label: "통합 테스트까지",
                                  description: "로그인부터 토큰 갱신까지 실제 HTTP 요청으로 확인하는 통합 테스트를 함께 작성합니다."),
            ],
            multiSelect: false),
    ])

    private static var expandedCases: [SnapshotCase] {
        [
            SnapshotCase(name: "expanded-overview-one-session") {
                var claude = catalogTask("integration_claude", state: .working)
                let steps = ["Reads · auth/middleware.ts", "Edits · LoginForm.tsx", "Runs · npm test"]
                claude.steps = steps
                claude.stepIndex = steps.count - 1
                let book = SessionBook(sessions: [
                    session("s1", project: "coucou", phase: .working, steps: steps,
                            startedMinutesAgo: 12, turnMinutesAgo: 3),
                ])
                reset(mode: .expanded, view: .overview,
                      tasks: [claude] + defaultTasks().dropFirst(), focus: claude.id,
                      books: [claude.id: book])
                return island()
            },
            SnapshotCase(name: "expanded-overview-sessions") {
                let steps = ["Edits · CompactStatus.swift", "Runs · swift test"]
                let ide = webStormTask(state: .working, steps: steps)
                let book = SessionBook(sessions: [
                    session("w1", project: "coucou", phase: .working, steps: steps,
                            startedMinutesAgo: 25, turnMinutesAgo: 4),
                    session("w2", agent: "codex", project: "relay", phase: .waitingApproval,
                            steps: ["Runs · npm run deploy"], startedMinutesAgo: 9, lastEventMinutesAgo: 1,
                            turnMinutesAgo: 2),
                    session("w3", project: "website", phase: .finished, steps: ["Writes · index.html"],
                            finalLine: "Landing page updated, 3 files changed.",
                            startedMinutesAgo: 40, lastEventMinutesAgo: 6),
                ])
                reset(mode: .expanded, view: .overview, tasks: [ide] + defaultTasks(), focus: ide.id,
                      books: [ide.id: book])
                return island()
            },
            SnapshotCase(name: "expanded-approval-codex-webstorm") {
                let ide = webStormTask(state: .approval, steps: ["Runs · npm test"])
                let book = SessionBook(sessions: [
                    session("c1", agent: "codex", project: "coucou", phase: .waitingApproval,
                            steps: ["Runs · npm test"], startedMinutesAgo: 6, turnMinutesAgo: 1),
                ])
                reset(mode: .expanded, view: .approval, tasks: [ide] + defaultTasks(), focus: ide.id,
                      books: [ide.id: book])
                AppState.shared.pendingApproval = ApprovalInfo(
                    sessionId: "c1", tool: "Bash", command: "npm test -- --coverage",
                    inputKey: #"{"command":"npm test -- --coverage"}"#, pillId: ide.id)
                AppState.shared.isPinned = true
                return island()
            },
            SnapshotCase(name: "expanded-question-korean") {
                questionScene(other: false)
            },
            SnapshotCase(name: "expanded-question-korean-other") {
                questionScene(other: true)
            },
            SnapshotCase(name: "expanded-finished") {
                var claude = catalogTask("integration_claude", state: .finished)
                claude.steps = ["Runs · npm test"]
                claude.finalLine = "All 23 tests pass. Auth refactor complete, 94 % coverage."
                let book = SessionBook(sessions: [
                    session("f1", project: "coucou", phase: .finished, steps: claude.steps,
                            finalLine: claude.finalLine, startedMinutesAgo: 18),
                ])
                reset(mode: .expanded, view: .finished,
                      tasks: [claude] + defaultTasks().dropFirst(), focus: claude.id,
                      books: [claude.id: book])
                return island()
            },
            SnapshotCase(name: "expanded-error") {
                var tasks = defaultTasks()
                if let i = tasks.firstIndex(where: { $0.id == "integration_n8n" }) { tasks[i].state = .error }
                reset(mode: .expanded, view: .error, tasks: tasks, focus: "integration_n8n")
                return island()
            },
            SnapshotCase(name: "expanded-chat") {
                reset(mode: .expanded, view: .prompt, tasks: defaultTasks(), focus: "integration_claude")
                AppState.shared.chatHistory = [
                    ChatMessage(role: .user, content: "What did you change in LoginForm?"),
                    ChatMessage(role: .assistant, content: "I moved the validation into `useLoginForm`, so the form only renders fields and errors. The submit button now stays disabled until both fields are valid."),
                ]
                return island()
            },
        ]
    }

    private static func questionScene(other: Bool) -> SnapshotScenePlan {
        var claude = catalogTask("integration_claude", state: .question)
        claude.steps = ["Reads · auth/middleware.ts"]
        let book = SessionBook(sessions: [
            session("q1", project: "coucou", phase: .waitingAnswer, steps: claude.steps,
                    startedMinutesAgo: 8, turnMinutesAgo: 2),
        ])
        reset(mode: .expanded, view: .question,
              tasks: [claude] + defaultTasks().dropFirst(), focus: claude.id,
              books: [claude.id: book])
        SnapshotScene.questionShowsOther = other
        AppState.shared.pendingQuestion = koreanQuestion
        AppState.shared.isPinned = true
        return island()
    }

    // MARK: Settings

    /// ~/.claude/settings.json before Coucou's hooks (in SnapshotMode.home).
    static let claudeSettingsFixture = """
    {
      "model": "opus",
      "permissions": {
        "allow": ["Bash(npm test)", "Bash(git status)"]
      }
    }
    """

    private static var settingsCases: [SnapshotCase] {
        [
            SnapshotCase(name: "settings-agents-install-diff") {
                try writeClaudeSettings(claudeSettingsFixture)
                return try settingsScene()
            },
            SnapshotCase(name: "settings-agents-already-installed") {
                // The settings as the install would write them, then the same install again.
                try writeClaudeSettings(claudeSettingsFixture)
                let installed = try HookServer.shared.previewClaudeHooks()
                try writeClaudeSettings(installed)
                return try settingsScene()
            },
        ]
    }

    private static func writeClaudeSettings(_ text: String) throws {
        let dir = SnapshotMode.home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("settings.json"))
    }

    private static func settingsScene() throws -> SnapshotScenePlan {
        reset(mode: .hidden, tasks: defaultTasks(), focus: "integration_claude")
        AppDefaults.store.set("agents", forKey: "settingsSection")
        let preview = try HookServer.shared.previewClaudeHooks()
        return SnapshotScenePlan(view: AnyView(SettingsView(snapshotHookPreview: preview)
                                                .background(Color(nsColor: .windowBackgroundColor))),
                                 size: CGSize(width: 720, height: 560), cropToContent: false)
    }
}
#endif
