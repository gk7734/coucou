# Coucou — AI 코딩 에이전트용 가이드

Coucou는 MacBook 노치에 사는 캐릭터 **Mochi**가 AI 코딩 에이전트 세션(Claude Code, Codex, Gemini CLI, Cursor 등)을 보여 주고, 노치에서 바로 승인·질문 응답·채팅·파일 드롭을 할 수 있게 해 주는 네이티브 macOS 앱이다. iPhone 앱(CloudKit 동기화, Live Activity, 위젯)이 같은 저장소에 있다.

이 브랜치(`refactor/mac-only`)는 **macOS + iPhone만 대상으로 한다.** Windows/Linux Tauri 앱(`windows/`, `linux/`, 관련 CI)은 삭제했다. 원본은 git 히스토리(`main`)에 있다.

이 문서는 대규모 리팩터링·재작성을 전제로 쓴 지도다. "무엇이 어디 있나"보다 **무엇이 무엇에 묶여 있고, 무엇을 깨면 안 되는가**에 집중한다.

---

## 1. 명령어

```bash
# 프로젝트 생성 (.xcodeproj는 절대 손으로 편집하지 않는다 — project.yml만 수정)
brew install xcodegen
cd NotchBuddy && xcodegen

# Mac 빌드 (Debug = 본인 Apple Development 인증서로 서명, 프로필 불필요)
xcodebuild -project NotchBuddy/NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug build
# 인증서 없는 환경(CI 등)에서는 끝에 CODE_SIGNING_ALLOWED=NO

# CI가 돌리는 나머지 빌드 (CODE_SIGNING_ALLOWED=NO로 서명 없이)
#   -scheme CoucouAppStore -configuration Debug          (App Store 타깃, APPSTORE 플래그)
#   -scheme NotchBuddyCloud -configuration DebugCloud     (PHONE_LINK 포함)
#   -scheme NotchBuddy -configuration ReleaseCloud
#   -scheme CoucouPhone -destination 'generic/platform=iOS'

# 테스트 전부 (XCTest 없음 — swiftc로 단일 파일을 컴파일해 실행하는 스크립트들)
bash scripts/test-all.sh
bash scripts/test-auto-close.sh      # 하나만

# 릴리스 노치/외곽 렌더 확인 (수동)
bash scripts/render-outfits.sh       # /tmp/coucou-outfits.png

# relay (Cloudflare Worker)
cd relay && npm install && npm run typecheck
```

**기준선 (2026-10-10, Xcode 27.0 / Swift 6.4):** `NotchBuddy` Debug 빌드 성공, 경고 40개(대부분 `IslandWindowController.swift`의 Swift 6 actor 격리 경고). `test-all.sh` 20개 전부 통과. 리팩터링 중 이 기준보다 나빠지면 안 된다.

> 커밋된 `project.pbxproj`가 `project.yml`보다 뒤처져 있었다(SpotifyViews, NowPlayingViews, PillColors, TerminalTarget 누락). `project.yml`을 바꾸거나 파일을 추가·이동하면 **항상 `xcodegen` 후 생성물(`project.pbxproj`, `Resources/Info*.plist`)까지 커밋**한다.

---

## 2. 저장소 구조

| 경로 | 내용 |
|---|---|
| `NotchBuddy/project.yml` | XcodeGen 정의. 타깃·스킴·버전·Info.plist 속성·빌드 플래그의 단일 출처 |
| `NotchBuddy/Sources/App/` | Mac 전용 코드 (~65 파일) |
| `NotchBuddy/Sources/App/PhoneLink/` | Mac→iPhone CloudKit 동기화 (`#if PHONE_LINK`) |
| `NotchBuddy/Sources/CoucouKit/` | Mac·iPhone·익스텐션이 **소스로** 공유 (프레임워크 아님, `public` 없음) |
| `NotchBuddy/Sources/Phone/` | iPhone 앱 (`CoucouPhone`) |
| `NotchBuddy/Sources/Widgets/`, `NotificationContent/` | iOS 익스텐션 |
| `NotchBuddy/Resources/` | Info*.plist(생성물), *.entitlements, `Localizable.xcstrings`(10개 언어), `sounds/`(WAV 28개) |
| `tests/*.swift` + `scripts/test-*.sh` | 순수 로직 테스트 (§8) |
| `NotchBuddy/Tests/HermesConfigMergerTests.swift` | `HookServer.mergedHermesConfig`의 **복사본**을 테스트하는 스크립트 (CI 미포함, pyyaml 필요) |
| `relay/` | Live Activity APNs 푸시를 중계하는 무상태 Cloudflare Worker (APNs 키 보관) |
| `docs/SPEC.md`, `docs/INTEGRATIONS.md` | 동작·뷰·상태 명세 (프랑스어, 일부 오래됨) |
| `docs/AGENTS.md` | 서드파티 에이전트 hook 연동 문서 |
| `docs/*.html` | GitHub Pages 사이트 (Windows/Linux 언급이 아직 남아 있음) |
| `design/prototype/notch-buddy.html` | 원본 프로토타입. 치수·타이밍의 시각적 기준 |
| `design/outfits/`, `design/animations/` | 의상·인사·업로드 애니메이션의 Canvas 2D 레퍼런스 (빌드에 안 쓰임) |

### 타깃

| 타깃 | 번들 ID | OS | 소스 | 플래그 |
|---|---|---|---|---|
| `NotchBuddy` (제품명 Coucou, GitHub 배포) | `fr.louisraille.NotchBuddy` | macOS 15 | `Sources/` − Phone/Widgets/NotificationContent | Release·DebugCloud에서 `PHONE_LINK`. 샌드박스 없음 |
| `CoucouAppStore` | `fr.louisraille.Coucou` | macOS 15 | 위와 동일 | `APPSTORE` (+`PHONE_LINK`). 샌드박스 |
| `CoucouPhone` | `fr.louisraille.Coucou` (유니버설 구매) | iOS 18 | `Phone/`, `CoucouKit/` | `COUCOU_APNS_ENV` |
| `CoucouWidgets` | `…Coucou.Widgets` | iOS 18 | `Widgets/`, `CoucouKit/` + `Phone/`의 **개별 파일 5개** | `WIDGET_EXTENSION` |
| `CoucouNotificationContent` | `…Coucou.NotificationContent` | iOS 18 | `NotificationContent/`, `CoucouKit/` + `Phone/MochiLive.swift`, `Phone/MacStubs.swift` | |

- `APPSTORE` 빌드에서는 Claude Code 외 에이전트 설치기, Spotify, Apple Music, 받아쓰기, iPhone 지시(Instruction), `githubOnly` pill이 컴파일에서 빠진다.
- 익스텐션은 `Phone/`의 파일을 **경로로 하나씩** 집어 온다. 해당 파일을 옮기거나 이름을 바꾸면 익스텐션 빌드가 깨진다.
- Swift 6.0, `-strict-concurrency=complete`, 서드파티 의존성 0개.

---

## 3. Mac 앱 아키텍처

### 시작 순서
`NotchBuddyApp`(`@main`)은 빈 `Settings` 씬만 선언하고, 실제 초기화는 `AppDelegate.applicationDidFinishLaunching`에서 한다.
1. SIGPIPE 무시 → `KeychainStore.shared` 워밍(키를 메인 스레드에서 한 번 전부 읽음) → `.accessory` 정책 → 상태바 메뉴
2. `setupIsland()`: `IslandWindowController` 생성 → `fsm.launch()`(인사 애니메이션) → `HookServer.shared.start()` → 폴러 7개 `.start()` → NotificationCenter 옵저버(`.openFullSettings`, `.greetComplete`, wake, `.checkMondayRecap`) → `MusicController`/`SpotifyController` 접근(GitHub 빌드)
3. `PHONE_LINK`이면 `CloudProbe` 시작
- 설정 창은 SwiftUI `Settings` 씬이 아니라 `AppDelegate.openSettings`에서 수동 생성한다.

### 객체 그래프와 동시성
- 거의 모든 것이 `static let shared` 싱글턴이다. `@MainActor ObservableObject`: `AppState`, `DemoEngine`, `MusicController`, `SpotifyController`. `@unchecked Sendable`: `HookServer`, `KeychainStore`, 폴러들. `@Observable`은 `MacDictation` 하나뿐.
- `AppDelegate` → `IslandWindowController` → (`IslandStateMachine` fsm, `IslandPanel`, NSEvent 모니터 전부).
- 비동기 패턴이 섞여 있다: Combine `$x.sink`, **~25개의 NotificationCenter 이름이 사실상의 이벤트 버스**(`IslandWindowController.swift` 하단, `HookServer.swift`의 `.hookExpand`), 모든 타이머는 `DispatchWorkItem`+`asyncAfter`, 소켓 스레드→`Task { @MainActor }`, 폴러는 `DispatchSourceTimer`→`DispatchQueue.main.async`.

### 상태: 두 개의 원천 (가장 취약한 부분)
- **`IslandStateMachine`** (`App/IslandStateMachine.swift`, 순수·테스트됨): 상태 `hidden`/`petit`(compact)/`home`(expanded)/`coucou`(인사). 입력 `launch, mouseEntered, mouseLeft, click, reveal, collapse, openedExternally, hiddenExternally, greetComplete, userInteracted`. 자동 닫힘 `autoCloseInterval`(기본 15초, hover로 열렸으면 0.6초), petit→hidden 60초. `isHeldOpen = pendingApproval != nil`.
- **`AppState.mode`** (`hidden/compact/expanded`, `CoucouKit/IslandTypes.swift`)와 **`AppState.view`**.
- `IslandWindowController.onTransition`이 FSM 상태를 `setMode`/`expand`로 옮긴다. 그런데 많은 경로가 `mode`를 직접 바꾸고 `openedExternally`/`hiddenExternally`로 FSM을 "전이 없이 동기화"한다. **이 둘이 어긋나는 것이 이 앱 버그의 주원인이다.** 재작성 시 하나의 상태 원천으로 합치는 것이 1순위.
- `CountdownBar`는 `lastActivity`를 읽지만 실제 닫힘 타이머는 FSM 것이라 표시와 실제가 다를 수 있다.

### 뷰
- `IslandView` enum 19개: `overview, empty, approval, question, error, finished, confused, upload, uploading, choose, mail, prompt, searching, result, note, settings, greeting, wardrobe, recap`. 크기·봇 위치는 `IslandConst.viewLayouts`(`IslandTypes.swift`).
- `IslandViewContent.swift`(4,921줄, 구조체 ~70개)에 거의 모든 뷰가 있다. `IslandContentView`는 **19개 뷰를 ZStack에 동시에 마운트하고 opacity로만 전환**한다. 그래서 `@State`(질문 선택, diff 오버레이 등)가 뷰 전환 사이에 살아남고 `onAppear`는 한 번만 불린다. 활성 뷰만 마운트하도록 바꾸면 이 동작이 달라진다.
- 레이아웃 매직 넘버: 콘텐츠 프레임 98pt, 헤더 34pt, 봇 여백 `padding(.leading, 108/116)`, 업로드 지오메트리 36/526/103(`IslandRootView`, `UploadingView`, `ViewLayout`에서 공유).
- 채팅 높이 공식 `min(300, 240 + 40*count)`이 4곳에 중복(`IslandRootView`, `IslandWindowController` ×2, `BotCanvasView`). `islandSize`/`botPosition` 히트 테스트도 패널·컨트롤러·BotCanvasView에 중복되어 서로 맞아야 클릭과 "때리기" 판정이 어긋나지 않는다.
- `QuestionLayout.height`는 `pendingQuestion.didSet`이 쓰고 `islandSize`가 읽는 `nonisolated(unsafe)` 전역(`AskQuestion.swift`).
- `IslandViewContent.swift`의 "통합 X가 설정됐나" switch가 **body 평가마다 `HookServer.*Installed()`로 파일 I/O를 한다.**

### 창
- 720×560 고정 크기 borderless `nonactivatingPanel`, 레벨 `mainMenu+3`, 화면 상단 중앙 고정. 패널은 크기가 변하지 않고 SwiftUI가 안에 검은 `IslandShape`를 그린다. (주석과 `placeBelowIsland`, 봇 마스크는 아직 320 높이를 가정함.)
- 클릭 통과: 폴링 루프(island 근처/바쁠 때 60Hz, 유휴 8Hz)가 `ignoresMouseEvents`를 토글. hover 진입/이탈도 같은 루프가 FSM에 공급. 클릭·드래그는 local/global NSEvent 모니터.
- 다중 디스플레이: `IslandDisplayChoice`(`notch`/`menuBar`/`followMouse`/`display:<UUID>`, 순수·테스트됨), 노치 크기는 `CoucouKit/IslandScreenGeometry.swift`(순수·테스트됨). `relocate`가 `notchWidth`/`hasNotch`(비-`@Published`)를 쓰고 `.islandScreenChanged`를 post + `objectWillChange.send()`.
- 전역 단축키: Carbon `RegisterEventHotKey`(`HotKeyCenter.swift`). **ID = `ShortcutAction.allCases`의 인덱스**라 enum 순서를 바꾸면 ID가 바뀐다.

### AppState (`App/AppState.swift`, 멤버 ~110개 god object)
UI 상태, `[AgentTask]`, ~30개 설정(각각 `didSet`에서 UserDefaults 저장), 모든 통합의 데이터, 채팅 기록, pending approval/question, 세션 diff, 플랜 게이지를 다 가진다. 뷰는 `IslandRootView`에서 내려받은 `@ObservedObject state`와 `AppState.shared` 직접 접근을 섞어 쓴다. `@Published` 하나만 바뀌어도 트리 전체가 다시 그려진다.
- 새 필드를 추가하면 **`DemoEngine`의 `Snapshot`에도 추가**해야 데모 모드 진입/복귀가 깨지지 않는다.
- `init` 안에서는 `didSet`이 안 불리므로 `SoundEngine` 볼륨은 수동 동기화한다.
- `mainPillId`는 `activeIntegrations`에 들어가면 안 되고, 활성 pill은 최대 4개.

### Mochi 렌더링
- `CoucouKit/BotEngine.swift`: `@Published` 없는 `ObservableObject`. 물리·트윈·파티클·눈·의상 상태를 가변으로 보관. 트윈은 문자열 키 `setProperty`/`getProperty` switch로 접근, 상태별 설정은 `BotStates`, `slap()` 3번 → `.botDizzy`.
- `App/BotCanvasView.swift`: `TimelineView(.animation(paused: mode == .hidden))` + `Canvas`. 매 프레임 `AppState`와 `SpotifyController`를 직접 읽는다. 엔진 명령은 NotificationCenter로만 전달(`triggerEmote`, `triggerSlap`, `botBlink`, `botSetTgEs`, `botGulp`, `botMorphTo`, `botGreet`).
- 의상: `MochiWardrobe.swift`(순수·테스트됨, 계절·부활절 로직), `MochiOutfitDrawing.swift`(정적 3D 투영 드로잉). 캐릭터는 코드로만 그린다(이미지·Rive·Lottie 금지).
- **"숨겨졌을 때 CPU 0%" 위반 지점:** 8Hz 폴링 타이머, `CountdownBar`의 0.1초 `Timer`(멈추지 않음), 일시정지되지 않는 `MiniBotCanvasView`의 `TimelineView`, opacity 0으로 살아 있는 `UploadingView`의 `TimelineView`.

### 저장소
- **Keychain**: generic password, service `fr.louisraille.NotchBuddy`(App Store 빌드도 동일 문자열), account = 키 이름. 키: `anthropic-api-key, google-api-key, openai-api-key, resend-api-key, resend-from, n8n-url, n8n-api-key, vercel-token, github-token, stripe-api-key, calcom-api-key, notion-api-key`. **`KeychainStore.allKeys`에 없는 키는 시작 시 로드되지 않아 `get`이 nil을 돌려준다.**
- **UserDefaults**: §7 계약 표 참고.
- **디스크**: `~/Library/Application Support/NotchBuddy/`(`nb.sock`, `nb-hook`, `nb-hook.py`, `Sounds/`, `recap.json`, `inbox/`), 로그 `~/Library/Logs/NotchBuddy/`.

---

## 4. Hook 파이프라인 (에이전트 → 앱)

### 전송
- **Unix 도메인 소켓** (HTTP 아님). GitHub 빌드 `~/Library/Application Support/NotchBuddy/nb.sock`, App Store 빌드는 샌드박스 컨테이너의 `nb.sock`. 디렉터리 0700, 소켓 0600, `getpeereid`로 같은 UID만 허용. 동시 연결 32, 페이로드 1MB, `SO_RCVTIMEO` 5초. 메시지는 JSON 한 줄.
- 앱이 시작할 때 `nb-hook`(`/bin/sh` 래퍼)와 `nb-hook.py`(Python 릴레이)를 지원 디렉터리에 **문자열로 써 넣는다**(`HookServer.swift` 하단 ~650줄이 임베디드 스크립트). App Store 빌드는 사용자가 NSOpenPanel로 고른 `~/.claude/coucou/`에 쓴다. 두 Python 릴레이는 소켓 경로만 다르다.

### "Claude Code를 절대 막지 않는다"의 구현
- 래퍼는 항상 exit 0. `xcode-select -p`가 실패하면 python3를 건너뛴다(개발자 도구 설치 대화상자 방지).
- 일반 이벤트: 0.3초 소켓 타임아웃, fire-and-forget.
- PermissionRequest: 릴레이 118초 대기 / 앱 115초 포기(Copilot·Muse 110초) / 설치된 hook timeout 120초.
- AskUserQuestion: 릴레이 125초 / 앱 120초 / hook 130초.
- 모든 실패 경로는 아무것도 출력하지 않아서 에이전트가 자기 터미널에서 다시 묻는다. Copilot은 fail-closed라 래퍼가 항상 `{"permissionDecision":"ask"}` 또는 `{}`를 출력한다.
- **이 타임아웃 사다리(앱 < 릴레이 < hook)를 바꿀 때는 세 값을 함께 바꾼다.**

### 프로토콜
- `handleClient`가 `coucou_kind`(`statusline`, `ask_user_question`)로 분기 → `hook_event_name == "PermissionRequest"`면 fd를 열어 둔 채 보관 → 나머지는 `processEvent`.
- 읽는 필드: `session_id`/`conversation_id`, `cwd`, `coucou_agent`, `term_program`, `bundle_id`, `tool_name`, `tool_input`, `prompt`, `message`, `last_assistant_message`, `platform`, `coucou_has_transport`, `permission_suggestions`, `rate_limits`. 릴레이가 `term_program`, `iterm_session_id`, `term_session_id`, `bundle_id`, `cwd`를 추가하고 Gemini/Antigravity/Copilot 이벤트 이름을 Claude 이름으로 정규화한다.
- 앱→릴레이 응답: `{"permissionDecision":"allow|always|deny|ask"}` 또는 `{"permissionDecision":"answer","answers":{…}}`. 릴레이가 에이전트별 형식으로 변환한다(Claude/Codex `hookSpecificOutput.decision.behavior`, Copilot/Muse 평면 형식, Hermes `{"choice":…}`, AskUserQuestion은 PreToolUse `allow` + `updatedInput`).
- `coucou_agent`(`^[a-z0-9-]{1,24}$`, `claude` 거부) → pill ID `agent_<name>`. 자세한 건 `docs/AGENTS.md`.

### 세션 모델
- **세션 = pill.** 별도 세션 객체가 없다. 호스트 판별(`ClaudeHost.swift`): VS Code/알려진 터미널 → `integration_claude`, Cursor 번들 → `agent_cursor`, Codex → `agent_codex`, 그 외 `agent_<coucou_agent>`. 모르는 호스트는 무시.
- `session_id`는 RecapStore, TurnRecorder, approval 매칭에만 쓰인다(익명 세션 키는 `pillId+cwd`).
- 종료: `Stop` → finished 후 5.2초 뒤 idle/제거, `SessionEnd` → 제거.
- **Approval·Question 슬롯은 전역에 하나씩**(`pendingApprovalFD`, `pendingQuestionFD`). 새 요청이 오면 이전 것은 "ask"로 밀려난다. 동시에 두 세션이 승인을 요청하면 서로 카드를 밀어낸다. fd는 `DispatchSource` cancel 핸들러에서만 닫힌다. 같은 세션의 PostToolUse(도구+정렬된 입력 JSON 일치), Stop, UserPromptSubmit, SessionEnd로도 카드가 닫힌다.

### 에이전트별 설치 위치 (`HookServer.swift` 1255–3040, `SettingsView`에서 preview/write 쌍으로 호출)

| 에이전트 | 파일 |
|---|---|
| Claude Code (+ Cursor/VS Code, 번들 ID로 구분) | `~/.claude/settings.json` (`hooks`, `statusLine`) |
| Gemini CLI | `~/.gemini/settings.json` |
| Antigravity | `~/.gemini/config/hooks.json` |
| Codex | `~/.codex/hooks.json` |
| Copilot CLI | `~/.copilot/hooks/coucou.json` |
| Muse | `~/.config/muse/settings.json` |
| OpenCode / Amp | `~/.config/opencode/plugins/coucou.js` / `~/.config/amp/plugins/coucou.ts` (생성된 플러그인, 표시 전용) |
| Hermes | `~/.hermes/plugins/coucou/`, `~/.hermes/config.yaml`(줄 단위 YAML 병합) |

- 설정 파일 쓰기 경로가 두 개다. Claude는 `ClaudeSettingsFile`(무효 JSON 거부, 미리보기와 바이트 비교, 고유 이름 백업, temp→rename, 권한 유지, 심볼릭 링크 추적, 테스트됨). **나머지 에이전트는 SHA-256 지문 + `writeJSONFile`**(심볼릭 링크·권한 처리 없음, 백업 이름 충돌 가능). 통합 시 전부 `ClaudeSettingsFile` 수준으로 올린다.

### 채팅
CLI가 아니라 HTTP API 직접 호출. `ClaudeService.chat`→`api.anthropic.com/v1/messages`(`web_search` 도구, 시스템 프롬프트 "Mochi"). Google/OpenAI/Ollama/LM Studio는 `chatOpenAICompatible`, 로컬 모델은 `LocalChat.streamChat`(SSE, `<think>` 필터). 첫 턴에 창 컨텍스트(`WindowContextCapture`: AX 창 제목 + AppleScript 브라우저 URL)나 파일을 붙인다.

---

## 5. 서비스 통합 (폴러)

- 폴러 7개(`N8n, Vercel, Resend, Github, Stripe, Calcom, Notion` `*Poller.swift`)는 **공통 추상화 없이 복붙**이다: `@unchecked Sendable` 싱글턴 + `DispatchSourceTimer` + `DemoEngine.isPollerPaused` 체크 + `KeychainStore.get` + `URLSession.dataTask` + 무타입 `JSONSerialization` + `DispatchQueue.main.async`로 `AppState` 갱신.
- GitHub 폴러만 in-flight 가드, `tokenGeneration`(오래된 응답 폐기), `isWanted`(pill 꺼져 있고 iPhone 동기화도 꺼져 있으면 건너뜀)를 갖는다. **나머지 6개는 pill이 꺼져 있어도 키만 있으면 폴링한다.**
- Vercel/N8n/Stripe는 "task 상태 flash + badge + 소리 + 60초 후 idle" 블록을 각자 복사해 갖고 있다.
- iPhone 쪽 `PhoneLink/ServiceDetailRunner.swift`가 **모든 서비스 API 클라이언트를 async/await로 한 번 더** 구현한다(상세 조회 + redeploy/rerun/merge 같은 액션).
- 고정 API 버전 헤더: Cal.com `cal-api-version: 2024-08-13`, Notion `Notion-Version: 2022-06-28`.
- 그 외: Spotify·Apple Music은 OAuth/MediaRemote 없이 distributed notification + AppleScript(`#if !APPSTORE`). 받아쓰기는 `SFSpeechRecognizer`. `SafeWebURL.safeWebURL()`은 http/https만 `NSWorkspace.open`에 넘기는 보안 가드다(유지할 것). 주간 리캡은 `recap.json`(schemaVersion 1, 12주 보관).

**권장 통합 형태:** `ServiceIntegration` 프로토콜(pillId, keychainKeys, schedule, `fetch`, `events(old:new:)`, `phoneSnapshot`, `detail`) + GitHub 구현에서 가져온 가드를 가진 `PollScheduler` actor 하나 + Codable 기반 `ServiceHTTPClient` 하나 + badge/소리/자동 해제를 한 곳에서 하는 `IntegrationEventSink` + 문자열 리터럴 대신 타입 있는 `PillID` 상수.

---

## 6. iPhone 연동

- **전송은 CloudKit private DB**, 컨테이너 `iCloud.fr.louisraille.Coucou`, 커스텀 존 `Coucou`. 민감 필드는 `encryptedValues`.
- Mac → iPhone: `Session`(`session-<pillId>`), `ApprovalRequest`(`approval-<fp앞32>`), `Turn`(`turn-<pillId>`), `Service`(`service-<pillId>`), `ServiceDetail`(`detail-<pillId>`), `Ping`.
- iPhone → Mac: `Decision`(`allow`/`deny`, 2초 폴링, 지문 일치 시에만 적용, 읽으면 삭제), `Answer`, `Instruction`(15초 폴링 → `claude -p <text> --resume <sid>`, GitHub 빌드만, 10분 이내), `ServiceAction`(마지막 detail에서 제안된 것 + `allowedKinds`만), `PhoneToken`, `Pong`.
- 승인 지문: `pillId, sessionId, tool, command, inputKey`를 `\u{1F}`로 이어 SHA-256. relay는 소문자 hex 64자를 요구한다.
- **와이어 계약이 양쪽에 따로 쓰여 있다.** Mac `SessionSnapshot`(`PhoneLink/SessionPublisher.swift`)과 iPhone `SessionItem`(`Phone/PhoneLink.swift`)이 같은 필드를 독립적으로 매핑하고, 레코드 타입 문자열과 컨테이너 ID(~5곳), 존 ID(3곳)가 리터럴로 반복된다. 스키마를 CoucouKit 한 곳으로 모으는 것이 우선 작업이다.
- Mac 쪽 리더 6개(ApprovalRelay, QuestionRelay, InstructionRunner, ServiceDetailRunner, LiveActivityRelay, SessionPublisher)가 각자 change token으로 같은 존을 폴링한다. 읽으면 삭제하는 의미론은 각 리더가 레코드 타입으로 필터링한다는 전제 위에 서 있다.
- **Live Activity**: iPhone이 push-to-start/update 토큰을 `PhoneToken`에 씀 → Mac `LiveActivityRelay`가 Mac이 20초 잠겨 있으면(에이전트가 대기 중이면 즉시) 시작, 잠금 해제 30초 후 종료 → `https://coucou-relay.raillelouis.workers.dev/v1/live-activity`(기본값, `phoneRelayURL` default로 변경 가능)에 POST → relay가 ES256 JWT로 APNs 호출. **Mac과 relay 사이 인증이 없다.** 포크라면 relay를 직접 배포해야 한다(`docs/IPHONE.md`, `relay/README.md`).
- `MacStubs.swift`: CoucouKit의 `BotEngine`이 `SoundEngine.shared`와 `.botDizzy`를 참조하므로 iOS 타깃에 같은 이름의 무음 스텁을 제공한다. CoucouKit을 진짜 패키지로 만들려면 이 의존성을 주입으로 바꿔야 한다. `IslandTypes.swift`도 Mac 전용 타입(IslandMode, ChatProvider, ViewLayout, IslandConst)을 iOS로 끌고 간다.
- 위젯은 앱 그룹 `group.fr.louisraille.Coucou`의 `sessions.json`을 읽는다. `PillColors`는 `UserDefaults.standard`를 써서 위젯에서 사용자 색이 안 보인다.

---

## 7. 깨면 안 되는 계약

리팩터링의 자유도는 내부 구조에 있다. 아래 값들은 **바꾸는 순간 기존 사용자 데이터·권한·iPhone·relay가 끊긴다.** 바꿔야 한다면 마이그레이션 코드와 함께 의도적으로 바꾼다.

| 범주 | 값 |
|---|---|
| 번들 ID | `fr.louisraille.NotchBuddy`(Mac GitHub), `fr.louisraille.Coucou`(App Store·iPhone), `.Widgets`, `.NotificationContent`. Keychain·UserDefaults·TCC 권한이 여기 묶여 있다 |
| Keychain | service `fr.louisraille.NotchBuddy` + §3의 키 이름 12개 |
| Pill ID | `integration_claude, agent_cursor, agent_antigravity, agent_codex, agent_gemini, agent_copilot, agent_muse, agent_opencode, agent_amp, agent_hermes, agent_claude-desktop, ai_anthropic, ai_google, ai_openai, ai_ollama, ai_lmstudio, integration_resend, integration_n8n, integration_vercel, integration_github, integration_notion, integration_calcom, integration_stripe, integration_music, integration_spotify` 그리고 동적 `agent_<coucou_agent>`. UserDefaults, CloudKit 레코드 이름, `recap.json`, 위젯 설정에 저장된다. 단일 출처는 `CoucouKit/PillCatalog.swift`지만 코드 곳곳에 리터럴로 5–34번씩 반복된다 |
| UserDefaults | `activeIntegrations, mainPill, pillColors, mochiOutfit, soundEnabled, soundVolume, claudeModel, chatProvider, googleChatModel, openAIChatModel, ollamaChatModel, lmstudioChatModel, ollamaServerURL, lmstudioServerURL, openOnHover, autoCloseInterval, islandDisplay, hotkeyEnabled, hotkeyFlags, hotkeyCode, shortcut.<action>.{keyCode,flags,enabled}, vercelProjectFilter, n8nWorkflowFilter, claudePlanUsage, showPlanInNotch, showCodexPlanInNotch, settingsSection, coucouHooksInstalled, hermesApprovalsEnabled, terminalCardsEnabled, iPhoneSyncEnabled, iPhoneLiveActivityEnabled, iPhoneInstructionsEnabled, phoneRelayURL, phoneLinkPing, mochiOnDesktop, desktopMochiX, desktopMochiY, dictationLanguage, dictationLastLocale, recapEnabled, recapHideProjects, recapLastShownWeek, coucou.spotifyAutomationGranted, coucou.musicAutomationGranted` |
| 디스크 경로 | `~/Library/Application Support/NotchBuddy/nb.sock`·`nb-hook` (이미 설치된 사용자의 `~/.claude/settings.json`이 이 경로를 가리킨다) |
| Hook 프로토콜 | 이벤트 이름, `coucou_agent`·`coucou_kind` 필드, `permissionDecision` 응답 형식, 타임아웃 사다리 |
| CloudKit | 컨테이너, 존 `Coucou`, 레코드 타입 12개, 레코드 이름 접두사, 필드 이름과 평문/암호화 구분, 구독 ID(`coucou-zone-mac`, `coucou-zone-phone-silent`, `coucou-approvals`, `coucou-approvals-mochi`), 지문 알고리즘, `BotState` raw 값 |
| Live Activity / relay | Swift 타입 이름 `MochiActivityAttributes`(relay가 하드코딩), `MochiActivityState` 필드(문자열 ≤60자, 정수 0–999; relay에 추가하지 않은 새 필드는 조용히 버려진다), APNs topic `fr.louisraille.Coucou.push-type.liveactivity` |
| iOS 식별자 | 앱 그룹과 `sessions.json`, URL `coucou://mochi/<id>`, 위젯·컨트롤 kind, 알림 카테고리·액션 ID(`COUCOU_APPROVAL` 등), 인텐트 타입 이름, Spotlight `domainIdentifier` `turns`, 사운드 파일 이름 |
| 단축키 | `ShortcutAction` enum 순서 (Carbon hotkey ID) |

---

## 8. 테스트 규칙

- XCTest 타깃은 없다. 각 `scripts/test-X.sh`가 `NotchBuddy/Sources/...`의 **소스 파일 1–2개**와 `tests/XTests.swift`(`@main`)를 `swiftc`로 직접 컴파일해 실행한다.
- 따라서 아래 파일은 **Foundation(또는 CoreGraphics)만 import하고 다른 앱 타입·싱글턴·AppKit·SwiftUI를 참조하면 안 된다.** 옮기거나 이름을 바꾸면 해당 스크립트의 하드코딩된 경로도 고친다.

| 스크립트 | 컴파일되는 소스 |
|---|---|
| test-auto-close, test-island-hover | `App/IslandStateMachine.swift` (`-strict-concurrency=complete`) |
| test-ask-question | `App/AskQuestion.swift` |
| test-chat-parsing | `App/LocalChat.swift` + `App/ChatMarkdown.swift` (`tests/fake_local_llm.py` 서버 사용) |
| test-claude-hooks | `App/ClaudeHookDetection.swift` |
| test-claude-host | `App/ClaudeHost.swift` (예외적으로 AppKit import) |
| test-claude-response | `App/ClaudeResponseText.swift` (`-warnings-as-errors`) |
| test-claude-settings | `App/ClaudeSettingsFile.swift` |
| test-desktop-mochi | `App/DesktopMochiLogic.swift` |
| test-display-choice | `App/IslandDisplayChoice.swift` |
| test-github-activity / -pulse | `App/GitHubActivity.swift` / `App/GitHubPulse.swift` |
| test-plan-gauge | `App/ClaudePlanGauge.swift` |
| test-safe-links | `App/SafeWebURL.swift` |
| test-shortcuts | `App/ShortcutLogic.swift` |
| test-terminal-target | `App/TerminalTarget.swift` |
| test-diff-engine, test-pill-colors, test-screen-geometry, test-wardrobe | `CoucouKit/DiffEngine`, `PillColors`, `IslandScreenGeometry`, `MochiWardrobe` |

- 리팩터링의 기본 전략: **로직을 이런 순수 파일로 빼내고, 같은 방식의 테스트 스크립트를 추가**한 뒤 UI를 바꾼다. 새 스크립트는 `scripts/test-*.sh` 이름이면 `test-all.sh`와 CI가 자동으로 집어 간다.
- 테스트 없는 영역: AppState, IslandWindowController, HookServer 라우팅·설치기, 폴러, BotEngine, PhoneLink, iPhone 앱 전부.
- 손으로 동기화해야 하는 복사본(드리프트 위험): `NotchBuddy/Tests/HermesConfigMergerTests.swift`(→`HookServer.mergedHermesConfig`), `scripts/test-weekly-recap.swift`(→`RecapStore` 모델), `scripts/RenderOutfits.swift`(스텁).
- 자동 닫힘 테스트는 타이밍 여유에 의존한다(느린 CI에서 flaky했던 이력, #376).

---

## 9. 리팩터링 지도

### 핫스팟 (큰 순서)
1. `App/IslandViewContent.swift` 4,921줄 — 뷰 ~70개. 뷰별 파일로 분리(§3의 "동시 마운트" 동작 주의).
2. `App/HookServer.swift` 3,699줄 — 소켓 서버(204–332), 이벤트 라우팅(342–655), approval/question(660–968), 헬퍼(980–1180), Claude 설치기(1184–1573), 다른 에이전트 설치기(1575–3040), 임베디드 릴레이 스크립트(3049–3699). 권장 분리: `HookSocketServer` / `HookEventRouter` / `PendingDecisionBroker` / `StepFormatter` / 에이전트별 `AgentInstaller`(공통 프로토콜, 전부 `ClaudeSettingsFile` 경유) / 릴레이 스크립트를 번들 리소스로.
3. `App/SettingsView.swift` 2,053줄 — `@State` ~50개(에이전트마다 installed/showDiff/pendingJSON/pendingInstall), 문자열 switch로 섹션 선택.
4. `CoucouKit/BotEngine.swift` 1,659줄, `MochiOutfitDrawing.swift` 1,464줄.
5. `App/IslandWindowController.swift` 1,290줄 — 창, 폴링, FSM 접착, 단축키, 드래그, dizzy. 빌드 경고의 절반이 여기.
6. `App/AppState.swift` 847줄 — 설정 / UI 상태 / 세션 / 통합 데이터로 분리.

### 알려진 버그 (재작성 시 고칠 것)
- **사용자 hook 삭제:** Claude 설치·제거 코드와 `ClaudeHookDetection`이 command에 `"coucou"` 또는 `"NotchBuddy"`가 **포함된** hook을 전부 Coucou 것으로 간주한다(`HookServer.swift:1299, 1326, 1537`, `ClaudeHookDetection.swift:14`). 이 저장소 경로(`…/orca/coucou/`) 아래의 스크립트를 hook으로 쓰면 설치 시 지워진다. 정확한 경로 일치로 바꿔야 한다.
- Copilot 제거 헬퍼 `withoutCopilotHooks`가 `command` 키를 보지만 Copilot 항목은 `bash` 키를 쓴다 → 제거가 동작하지 않음.
- Hermes 폴백 주석은 "네이티브 프롬프트로 폴백"이라 하지만 코드는 `respond('deny')`.
- `accept()`가 한 번 실패하면 서버 루프가 영구 종료되고 재시작이 없다. 보관 중인 approval/question fd는 연결 수 제한에 안 잡힌다. 연결마다 별도 `Task`라 PreToolUse/PostToolUse 순서가 보장되지 않는다.
- 같은 UID 검사만 하므로 사용자 권한의 아무 프로세스나 가짜 승인 카드를 띄울 수 있다. `--statusline` 릴레이는 `statusline-previous.json`의 명령을 `/bin/sh -c`로 실행한다.
- 채팅 중 provider를 바꾸면 OpenAI 호환 경로가 첫 텍스트 블록만 남겨 컨텍스트 줄만 남고 실제 질문이 사라진다.
- `colorForProject`가 실행마다 바뀌는 `hashValue`를 쓴다(`IslandTypes.swift`).
- 죽은 코드·미사용 설정: `absenceInterval`, `greetThreshold`(설정 UI에는 있으나 미사용), `isPresent`, `pinForFinished`, `ColumnAgentsView`, `washColors`, `scheduleHover`, `baseMode`, `cleanup()`, `activeSessionId`, `ClaudeService.search`.
- 문서 낡음: `docs/AGENTS.md`의 "외부 에이전트는 PermissionRequest 미지원"(이미 Codex/Copilot/Muse/Hermes 지원), `docs/INTEGRATIONS.md`의 n8n 5초 폴링(실제 15초)과 Vercel/Stripe/Resend/Notion/Cal.com 누락, Live Activity의 "Allow opens Coucou" 주석.

### 권장 진행 순서
1. **기준선 고정**: `xcodegen` → 빌드 → `bash scripts/test-all.sh`. 경고 수(40)를 기록.
2. **계약 상수화**: pill ID, Keychain 키, UserDefaults 키, NotificationCenter 이름, CloudKit 레코드 타입·필드를 각각 한 파일의 상수/enum으로 모은다. 동작 변화 0, 이후 모든 단계의 안전망.
3. **순수 로직 추출 + 테스트 추가**: HookServer 라우팅(이벤트 → pill/상태), 릴레이 응답 변환, 설치기 병합 로직, 폴러 파서를 순수 파일로 빼고 `scripts/test-*.sh` 추가.
4. **상태 원천 단일화**: FSM과 `AppState.mode/view`를 하나로. 그다음 AppState 분해.
5. **HookServer·폴러 분해** (§4, §5의 권장 형태).
6. **뷰 분리**: IslandViewContent, SettingsView를 파일 단위로.
7. **CoucouKit 정리**: CloudKit 와이어 스키마를 공유 타입으로, `MacStubs` 대신 의존성 주입, Mac 전용 타입을 CoucouKit 밖으로.
8. 각 단계마다 5개 스킴 빌드(§1)와 `test-all.sh`를 돌린다. iPhone·App Store 스킴은 `#if` 분기 때문에 Mac 빌드만으로는 깨짐을 못 잡는다.

---

## 10. 불변 규칙

구조와 모양은 자유롭게 바꿔도 되지만, 아래는 사용자 안전과 신뢰에 관한 것이라 유지한다.

- **Claude Code(및 모든 에이전트)를 절대 막지 않는다.** 앱이 응답하지 않으면 hook은 즉시 아무것도 출력하지 않고 exit 0.
- **사용자의 명시적 클릭 없이** 권한을 승인하거나, 질문에 답하거나, 이메일을 보내지 않는다.
- **`~/.claude/settings.json`과 다른 에이전트 설정 파일을 덮어쓰지 않는다**: 날짜 붙은 백업 → 병합 → diff 표시 → 사용자 확인 후 쓰기.
- 비밀은 Keychain에만. 디스크·git·로그에 남기지 않는다.
- 텔레메트리 없음. 네트워크는 사용자가 설정한 서비스와 relay에만.
- 섬이 숨겨졌을 때 CPU 0%를 목표로 한다(§3의 위반 지점 참고).
- Swift 6 + SwiftUI + AppKit, 서드파티 의존성 없음. Mochi는 `Canvas` + `TimelineView`로 코드로 그린다.
- `.xcodeproj`는 손으로 편집하지 않는다. `project.yml` → `xcodegen` → 생성물 커밋.
- 새 pill은 `PillCatalog.swift`에 선언한다. 기존 pill ID는 마이그레이션 없이 바꾸지 않는다(§7).

## 11. 릴리스 (macOS GitHub 빌드)

`project.yml`의 `CFBundleShortVersionString`/`CFBundleVersion` 올리기 → `xcodegen` → 재생성된 `Info.plist` 커밋 → `CHANGELOG.md`에 `## X.Y.Z — Month D, YYYY` 섹션 → README Versions 표에 행 추가 → `scripts/release.sh <ver>`(Developer ID 서명, `coucou-notary` 키체인 프로필로 공증, 태그 푸시, `gh release create`). 공증이 중간에 끊기면 `--finish`. 업데이트 메커니즘(Sparkle 등)은 없다. App Store·iPhone은 Xcode에서 수동 아카이브하며 버전이 별도다(현재 Mac GitHub 0.2.3, App Store 1.1, iPhone 1.0).

### 서명 현황 (이 포크)
- 팀은 `6HBMRNDGYC`(개인 계정)로 바꿨다. 이 Mac에는 `Apple Development` 인증서만 있다.
- **`Debug`만 서명된다**: Apple Development 인증서, 수동 서명, 프로필 없음. iCloud·push 권한이 없어서 가능하다. 서명이 매번 같아서 손쉬운 사용·자동화·Keychain 권한이 빌드마다 초기화되지 않는다.
- `DebugCloud`, `Release`, `ReleaseCloud`, `CoucouAppStore`, iPhone 타깃은 아직 서명되지 않는다. 번들 ID `fr.louisraille.*`와 iCloud 컨테이너가 원 저자 팀에 등록되어 있고, Developer ID 인증서·`Coucou Developer ID` 프로필·`coucou-notary` 키체인 프로필이 없기 때문이다.

`release.sh`는 원본 저장소(`Louis-CFM/coucou`), Developer ID 인증서, 프로비저닝 프로필을 전제로 한다. 포크에서 배포하려면 `project.yml`의 팀/번들 접두사, `release.sh`의 저장소 이름, relay URL, CloudKit 컨테이너를 모두 자기 것으로 바꿔야 하고, 그 순간 §7의 계약 대부분이 새로 시작된다.
