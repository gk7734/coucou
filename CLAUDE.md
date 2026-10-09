# Coucou — AI 코딩 에이전트용 가이드

Coucou는 MacBook 노치에 사는 캐릭터 **Mochi**가 AI 코딩 에이전트 세션(Claude Code, Codex, Gemini CLI, Cursor 등)을 보여 주고, 노치에서 바로 승인·질문 응답·채팅·파일 드롭을 할 수 있게 해 주는 네이티브 macOS 앱이다. iPhone 앱(CloudKit 동기화, Live Activity, 위젯)이 같은 저장소에 있다.

이 브랜치(`refactor/mac-only`)는 **macOS + iPhone만 대상으로 하는 포크다.** Windows/Linux Tauri 앱(`windows/`, `linux/`, 관련 CI)은 삭제했다(fb73e00). 원본은 git 히스토리(`main`)에 있다. 이 포크에서 더해진 큰 기능: IDE별 pill과 pill당 여러 세션(§12), macOS 알림과 정지 감지(§12), Auto 메인 pill(§12), compact 섬의 상태 줄과 사운드 시각화(§3, §13), 자동 음악 pill과 TIDAL(§13), 이벤트 기반 hook 소켓과 성능 작업(§4, §3).

이 문서는 대규모 리팩터링·재작성을 전제로 쓴 지도다. "무엇이 어디 있나"보다 **무엇이 무엇에 묶여 있고, 무엇을 깨면 안 되는가**에 집중한다. 코드와 다르면 코드를 확인하고 이 문서를 고친다.

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

# 테스트 전부 (XCTest 없음 — swiftc로 소스 몇 개를 직접 컴파일해 실행하는 스크립트 45개, §8)
bash scripts/test-all.sh
bash scripts/test-auto-close.sh      # 하나만

# 실행 중인 앱에 가짜 hook 이벤트 재생 (§12)
python3 scripts/coucou-replay.py --list
python3 scripts/coucou-replay.py webstorm-claude

# 성능 측정·벤치 (테스트 아님, 손으로 실행, §14)
bash scripts/measure-cpu.sh          # 앱을 다시 띄운다: 유휴 / burst 재생 중 / 그 뒤 CPU
bash scripts/bench-mochi.sh          # Mochi 프레임 비용 (오프스크린)
bash scripts/bench-hook-socket.sh    # bench-diff.sh, bench-audio-analysis.sh

# 릴리스 노치/외곽 렌더 확인 (수동)
bash scripts/render-outfits.sh       # /tmp/coucou-outfits.png

# relay (Cloudflare Worker)
cd relay && npm install && npm run typecheck
```

**기준선 (2026-10-10, Xcode 27.0 / Swift 6.4, 커밋 339a0f5 + 문서·번역 커밋):** 5개 스킴 빌드 성공(`NotchBuddy` Debug, `CoucouAppStore` Debug, `NotchBuddyCloud` DebugCloud, `CoucouPhone`). Swift 경고 0개(처음 40개 → 3098a64에서 8개 → 289ae73에서 0개. `CoucouNotificationContent`의 효과 없는 `@preconcurrency` 1개도 제거). 남는 건 `appintentsmetadataprocessor`의 "no AppIntents.framework" 안내 1줄뿐이다. `test-all.sh` 45개 스크립트 전부 통과. 리팩터링 중 이 기준보다 나빠지면 안 된다.

> `project.yml`을 바꾸거나 파일을 추가·이동하면 **항상 `xcodegen` 후 생성물(`project.pbxproj`, `Resources/Info*.plist`)까지 커밋**한다(과거에 커밋된 `project.pbxproj`가 `project.yml`보다 뒤처져 파일이 누락된 적이 있다).

---

## 2. 저장소 구조

| 경로 | 내용 |
|---|---|
| `NotchBuddy/project.yml` | XcodeGen 정의. 타깃·스킴·버전·Info.plist 속성·빌드 플래그·`CFBundleLocalizations`의 단일 출처 |
| `NotchBuddy/Sources/App/` | Mac 전용 코드 (~95 파일) |
| `NotchBuddy/Sources/App/PhoneLink/` | Mac→iPhone CloudKit 동기화 (`#if PHONE_LINK`) |
| `NotchBuddy/Sources/CoucouKit/` | Mac·iPhone·익스텐션이 **소스로** 공유 (프레임워크 아님, `public` 없음) |
| `NotchBuddy/Sources/Phone/` | iPhone 앱 (`CoucouPhone`) |
| `NotchBuddy/Sources/Widgets/`, `NotificationContent/` | iOS 익스텐션 |
| `NotchBuddy/Resources/` | Info*.plist(생성물), *.entitlements, `Localizable.xcstrings`(11개 언어: en, ar, bn, es, fr, hi, id, ko, pt-BR, ru, zh-Hans. Mac 두 타깃만 씀), `sounds/`(WAV 28개) |
| `tests/*.swift` + `scripts/test-*.sh` | 순수 로직 테스트 (§8). 보조: `tests/fake_local_llm.py`, `tests/hook_relay_check.py`, `tests/replay_check.py` |
| `scripts/coucou-replay.py` + `tests/replay/*.jsonl` | 실행 중인 앱에 hook 이벤트를 재생하는 개발 도구와 시나리오 (§12) |
| `scripts/measure-cpu.sh`, `scripts/bench-*.sh` (+ `scripts/bench/`, `BenchDiff.swift`, `HookSocketBench.swift`) | 성능 측정 도구 (§14). `test-all.sh`가 집어 가지 않는다 |
| `relay/` | Live Activity APNs 푸시를 중계하는 무상태 Cloudflare Worker (APNs 키 보관) |
| `docs/SPEC.md`, `docs/INTEGRATIONS.md` | 동작·뷰·상태 명세 (프랑스어, SPEC은 일부 오래됨) |
| `docs/AGENTS.md` | 서드파티 에이전트 hook 연동 문서 (IDE 감지 포함) |
| `docs/*.html` | GitHub Pages 사이트 (Windows/Linux 언급은 3e6ef85에서 제거) |
| `design/prototype/notch-buddy.html` | 원본 프로토타입. 치수·타이밍의 시각적 기준 |
| `design/outfits/`, `design/animations/` | 의상·인사·업로드 애니메이션의 Canvas 2D 레퍼런스 (빌드에 안 쓰임) |

### Hook·세션 런타임 파일 (`Sources/App/`)

| 파일 | 역할 |
|---|---|
| `HookServer.swift` | 이벤트 라우팅, approval/question 큐 운용, 세션 북 미러링·trim, 에이전트 설치기 (~2,150줄) |
| `HookSocketServer.swift` | Foundation만. 소켓 전송 계층: accept·읽기·연결 슬롯·전달 순서 (`test-hook-socket`, 벤치 `scripts/bench-hook-socket.sh`) |
| `PendingRequestQueue.swift` | 순수. 보관 중인 요청의 FIFO 큐 + `AcceptRecovery`(accept 실패 복구 정책) |
| `OrderedDelivery.swift` | 순수. 큰 diff가 백그라운드에서 계산되는 동안 뒤 메시지를 붙잡아 도착 순서대로 넘김 (§4) |
| `HookFileDiff.swift` | Edit/MultiEdit/Write 페이로드 → `FileDiff`. 16KB 넘으면 백그라운드 큐에서 계산 (`test-hook-file-diff`) |
| `HookRelayScripts.swift` | 순수. `nb-hook` 셸 래퍼, Python 릴레이(GitHub/App Store 두 버전을 한 템플릿에서 생성), OpenCode(v1/v2)/Amp/Hermes 플러그인 소스 |
| `ClaudeHookDetection.swift` | 순수. `CoucouHookCommand`/`isCoucouHookCommand`: Coucou hook 명령을 **정확한 형태**로 인식, `removingCoucouHooks` |
| `AgentHookConfig.swift` | 순수. Claude·Gemini·Antigravity·Codex·Copilot·Muse 설정 JSON 병합/제거 |
| `HermesConfigMerger.swift` | 순수. `~/.hermes/config.yaml` 줄 단위 병합 |
| `ClaudeSettingsFile.swift` | 모든 에이전트 설정 파일 쓰기(미리보기 바이트 비교, 고유 백업, temp→rename, 권한 유지, 심볼릭 링크 추적, `/`를 이스케이프하지 않음) |
| `ClaudeHost.swift` | 터미널 이름·표시, `integration_claude` pill 이름 (`test-claude-host`) |
| `HostResolver.swift` | 순수. 호스트 앱 판별과 pill 매핑, `ProcessTree.ancestors` (§12) |
| `ProcessAncestry.swift` | `accept()` 직후 피어 프로세스의 부모 사슬을 잡아 `coucou_host_bundle_ids`를 만든다. 오디오 헬퍼의 소유 앱 찾기에도 쓰인다 (§12, §13) |
| `HookRouting.swift` | 순수. 이벤트 → 호스트 → pill 라우팅 결정 (`test-hook-routing`) (§12) |
| `SessionBook.swift` | 순수. pill 하나 뒤의 세션 목록, 긴급도, 보관·만료, 정지 감지 (§12) |
| `SessionCardText.swift` | 순수. 카드의 세션 목록 문구 (`test-session-card-text`) |
| `AutoMainPill.swift` | 순수. Auto 메인 pill: 활동 이벤트, flip-flop 방지 전환, 해석 (`test-auto-main-pill`) (§12) |
| `SessionAlert.swift` | `SessionAlert` + `SessionAlertCenter`(알림 진입점) (§12) |
| `NotificationPolicy.swift`, `MacNotifier.swift` | 알림을 띄울지 결정(토글·억제·중복) / 무음 macOS 배너 (§12) |
| `StallMonitor.swift` | 정지 감지. 예약된 검사 하나 (§12) |
| `NotificationsSettingsView.swift` | 설정의 알림·정지 임계값 화면 |
| `HostAppInfo.swift` | 임의 앱의 이름·아이콘·frontmost·**활성화**(`activate`, §3) (AppKit) |
| `ServicePollGate.swift` | 서비스 폴러 공통 스케줄·가드 (§5) |
| `CoucouKit/CloudSchema.swift` | CloudKit 컨테이너·존·레코드 타입 이름의 단일 정의 (§6) |

### 섬·성능·음악 파일 (`Sources/App/`)

| 파일 | 역할 |
|---|---|
| `CompactStatus.swift` | 순수. compact 섬의 상태 줄: 어느 pill, 단계 → 활동(아이콘+짧은 글), 턴 경과 시간, 0.4초 변경 제한, **compact 폭·오프셋·히트 영역(`CompactIslandLayout`)** (`test-compact-status`) |
| `CompactStatusModel.swift` | 상태 줄·시각화 슬롯을 AppState에서 계산(`ChangeObserver`), 글자 폭 측정(NSFont), 미니 Mochi hover 라벨, `AudioSpectrum.isWanted`를 정하는 **유일한 곳**. AppState 밖의 `@Observable`(파생 상태라 데모 Snapshot 불필요) |
| `CompactVisualizer.swift` | 순수(Foundation+CoreGraphics). 슬롯에 상태 줄과 음악 중 무엇을 보일지, 제목 줄, 막대 높이, 30fps 제한 (`test-compact-visualizer`) (§13) |
| `NowPlaying.swift` | 계약. `NowPlayingSource`/`NowPlayingInfo`, `NowPlayingCenter`·`AudioSpectrum`(메인 액터 `@Observable` 싱글턴) (§13) |
| `NowPlayingViews.swift` | TIDAL pill의 작은 카드 등 지금 재생 뷰 |
| `MusicPillDriver.swift` | `AutoMusicPill` 결정을 AppState에 적용, `NowPlayingFeed.publish` (GitHub 빌드) |
| `AutoMusicPill.swift` | 순수. 자동 음악 pill의 등장·30초 잔류·퇴장 (`test-auto-music-pill`) |
| `MusicController.swift`, `SpotifyController.swift` | Apple Music·Spotify 피드(distributed notification + AppleScript) (GitHub 빌드) |
| `TidalController.swift`, `TidalNowPlaying.swift` | TIDAL을 손쉬운 사용(AX)으로 읽고 버튼·미디어 키로 제어 / 순수 파서 (`test-tidal-now-playing`) (GitHub 빌드) |
| `SystemAudioCapture.swift` | Core Audio 리스너로 `isAudible`·재생 앱, 프로세스 탭으로 스펙트럼 (탭은 GitHub 빌드만) (§13) |
| `SpectrumAnalyzer.swift`, `AudioSpectrumMath.swift` | 잠금 없는 샘플 링 + vDSP FFT / 순수 대역·dB·평활 수학 (`test-audio-spectrum`, `bench-audio-analysis`) |
| `VisualizerDebugFeed.swift` | DEBUG 전용 가짜 음악·스펙트럼 (`debugFakeMusic`, 메뉴 "Debug: fake music") |
| `ChangeObserver.swift` | Observation용 `$x.sink` 대체 (`test-change-observer`) (§3) |
| `MochiFrameRate.swift` | 순수. 작은 Mochi가 조용할 때 30fps (`test-mochi-frame-rate`) (§3) |
| `AppLog.swift` | 백그라운드 큐 하나에서 로그 쓰기 (`test-app-log`) |
| `KeychainStore.swift` | Keychain 래퍼 + 키별 지연 읽기 캐시 (`test-keychain-store`) |

### 타깃

| 타깃 | 번들 ID | OS | 소스 | 플래그 |
|---|---|---|---|---|
| `NotchBuddy` (제품명 Coucou, GitHub 배포) | `fr.louisraille.NotchBuddy` | macOS 15 | `Sources/` − Phone/Widgets/NotificationContent | Release·DebugCloud에서 `PHONE_LINK`. 샌드박스 없음 |
| `CoucouAppStore` | `fr.louisraille.Coucou` | macOS 15 | 위와 동일 | `APPSTORE` (+`PHONE_LINK`). 샌드박스 |
| `CoucouPhone` | `fr.louisraille.Coucou` (유니버설 구매) | iOS 18 | `Phone/`, `CoucouKit/` | `COUCOU_APNS_ENV` |
| `CoucouWidgets` | `…Coucou.Widgets` | iOS 18 | `Widgets/`, `CoucouKit/` + `Phone/`의 **개별 파일 5개** | `WIDGET_EXTENSION` |
| `CoucouNotificationContent` | `…Coucou.NotificationContent` | iOS 18 | `NotificationContent/`, `CoucouKit/` + `Phone/MochiLive.swift`, `Phone/MacStubs.swift` | |

- `APPSTORE` 빌드에서는 Claude Code 외 에이전트 설치기, Spotify, Apple Music, TIDAL, 자동 음악 pill(`MusicPillDriver`), **시스템 오디오 탭**(시각화 막대는 정적 패턴만), 받아쓰기, iPhone 지시(Instruction), `githubOnly` pill이 컴파일에서 빠진다. `InfoAppStore.plist`에는 `NSAudioCaptureUsageDescription`도 없다.
- 익스텐션은 `Phone/`의 파일을 **경로로 하나씩** 집어 온다. 해당 파일을 옮기거나 이름을 바꾸면 익스텐션 빌드가 깨진다.
- Swift 6.0, `-strict-concurrency=complete`, 서드파티 의존성 0개.

---

## 3. Mac 앱 아키텍처

### 시작 순서
`NotchBuddyApp`(`@main`)은 빈 `Settings` 씬만 선언하고, 실제 초기화는 `AppDelegate.applicationDidFinishLaunching`에서 한다.
1. SIGPIPE 무시 → `.accessory` 정책 → 상태바 메뉴(DEBUG면 "Debug: fake music" 하위 메뉴) → `MacNotifier.start()` → `StallMonitor.start()` → `SystemAudioCapture.start()`(무료인 "소리 나는 중" 리스너만. 캡처는 시각화가 보일 때만). **Keychain 워밍업은 없다**(키는 처음 쓸 때 읽는다, 0278aa1).
2. `setupIsland()`: `IslandWindowController` 생성 → `fsm.launch()`(인사 애니메이션) → `HookServer.shared.start()` → 폴러 7개 `.start()` → NotificationCenter 옵저버(`.openFullSettings`, `.greetComplete`, wake, `.checkMondayRecap`) → GitHub 빌드: `MusicController`/`SpotifyController` 접근, `TidalController.start()`, `MusicPillDriver.start()`
3. DEBUG: "Debug" 메인 메뉴(리캡 이미지 렌더), `VisualizerDebugFeed.start()`. `PHONE_LINK`이면 `CloudProbe` 시작 (존·구독 설정이 실패하면 60초마다, 최대 1시간 재시도)
- 종료 시 `AppLog`의 대기 중인 줄을 flush한다.
- 설정 창과 주간 리캡 창은 SwiftUI `Settings` 씬이 아니라 수동 생성하며, **`NSApp.activate()` + `orderFrontRegardless()`로 앞에 띄운다**(`activate(ignoringOtherApps:)`는 macOS 14부터 효과가 없고 Coucou는 accessory 앱이라 뒤에 떴다, b779413).
- **다른 앱 활성화는 `HostAppInfo.activate(bundleId)` 하나로**: `NSApp.yieldActivation` 후 Launch Services(`NSWorkspace.openApplication`, `activates = true`)로 연다. Dock 클릭처럼 활성화 + reopen 이벤트를 보내 최소화·숨김 창도 돌아온다. `NSRunningApplication.activate()`는 macOS 14의 협조적 활성화에서 비활성 앱(비활성 패널 뒤의 Coucou)의 요청이라 무시될 수 있다. "Open <IDE>", Open VS Code/Music/Spotify, `TerminalTarget`, 알림 클릭이 모두 이 경로를 쓴다(2719475, 488a5e2).

### 객체 그래프와 동시성
- 거의 모든 것이 `static let shared` 싱글턴이다.
  - `@MainActor @Observable`: `AppState`, `CompactStatusModel`, `NowPlayingCenter`, `AudioSpectrum`, `MacDictation`, `UploadSequenceEngine`(`isActive`만).
  - 아직 `ObservableObject`: `DemoEngine`, `MusicController`, `SpotifyController`, `MacNotifier`, `BotEngine`(`@Published` 없음), `DesktopBotViewState`, `MochiCadence`, `IslandAutoCloseCountdown`.
  - `@unchecked Sendable`: `HookServer`, `KeychainStore`, `AppLog`, `SystemAudioCapture`, 폴러들, `ServicePollGate`.
- `AppDelegate` → `IslandWindowController` → (`IslandStateMachine` fsm, `IslandPanel`, NSEvent 모니터 전부).
- **뷰가 아닌 코드가 `@Observable` 값을 따라갈 때는 `ChangeObserver`**(`App/ChangeObserver.swift`, 721fd7c): `withObservationTracking`을 다시 거는 `$x.sink` 대체. 값이 저장된 뒤 다음 메인 큐 턴에 한 번 전달, `initial`(=sink의 현재값)/`removeDuplicates`/`debounce`, 해제나 `cancel()`로 멈춤. ServicePollGate, StallMonitor, MacNotifier, Music/Spotify/TIDAL, MusicPillDriver, DemoEngine, DesktopMochi, IslandWindowController 설정, PhoneLink 퍼블리셔·릴레이(debounce 0.5/1/2초 유지)가 쓴다. Combine `.sink`는 1곳만 남았다.
- 그 외 비동기 패턴: **~25개의 NotificationCenter 이름이 사실상의 이벤트 버스**(`IslandWindowController.swift` 하단, `HookServer.swift`의 `.hookExpand`/`.hookReveal`, `KeychainStore`의 `.keychainValueChanged`), 타이머는 대부분 `DispatchWorkItem`+`asyncAfter`, 소켓 → 직렬 전달 큐 → **`DispatchQueue.main.async`(FIFO, §4)**, 폴러 타이머는 메인 큐에서 울리고 폴링 자체는 메인 밖에서 돈다.
- **Swift 6 런타임 트랩 규칙:** 메인 액터에서 만든 클로저(`@MainActor` 메서드 안에서 만든 타이머 핸들러, Observation 변경 핸들러, Core Audio·Dispatch 콜백)가 다른 스레드에서 실행되면 런타임에 트랩한다(b52db3c의 실행 직후 크래시). 백그라운드 큐·실시간 스레드에 넘기는 클로저는 **nonisolated 함수에서 만들고**, 메인 상태는 `DispatchQueue.main.async` + `MainActor.assumeIsolated`로 바꾼다. 메인 큐 옵저버·메인 런루프 콜백 안에서도 `MainActor.assumeIsolated`를 쓴다.

### 상태: FSM과 mode의 동기화
- **`IslandStateMachine`** (`App/IslandStateMachine.swift`, 순수·테스트됨): 상태 `hidden`/`petit`(compact)/`home`(expanded)/`coucou`(인사). 입력 `launch, mouseEntered, mouseLeft, click, reveal, collapse, openedExternally, openedByAlert(pointerInside:), displayed(_:pointerInside:), greetComplete, userInteracted, pointerMoved`. `isHeldOpen = pendingApproval != nil`.
- 닫힘 타이밍: 자동 닫힘 `autoCloseInterval`(기본 15초), hover로 열렸으면 0.6초, petit→hidden 60초. **사용자가 연 섬은 포인터가 떠나고 `leaveCloseDelay`(1초) 뒤 접힌다**. 단 `keepsOpenOnLeave`(채팅, 메일, 질문, 업로드, 검색 결과, 설정, 옷장, 리캡)면 보통 자동 닫힘(카운트다운 막대)을 쓴다(56c5376). 알림(finished, error…)으로 열렸는데 포인터가 섬 밖이면 `openedByAlert`가 자동 닫힘을 건다(전엔 포인터가 들어왔다 나가야 시작해서 섬이 열린 채 ~20% CPU였다, fb61019).
- **`AppState.mode`** (`hidden/compact/expanded`, `CoucouKit/IslandTypes.swift`)와 **`AppState.view`**.
- `IslandWindowController.onTransition`이 FSM 상태를 `setMode`/`expand`로 옮긴다. 반대 방향은 **`AppState.modeWillSet` 훅이 FSM 밖의 모든 mode 변경**(`AppState.syncMode`, 단축키, 메뉴, 리캡, 데스크톱 Mochi, 데모 복원)을 `fsm.displayed(_:pointerInside:)`로 반영한다. 이 훅은 같은 값 대입에도 동기적으로 불린다(예전 `@Published` 타이밍을 유지하려고 Observation이 아닌 훅으로 남겼다). `openedExternally`와 인사 위의 `expand(to:)`는 `.coucou`를 `.home`으로 바꾼다.
- 두 원천은 아직 둘이다. 새 mode 변경 경로를 만들면 `AppState.mode` 대입을 거치게 해야 FSM이 따라온다.
- **카운트다운**: FSM이 실제 자동 닫힘 마감(`countdown`, 순수 `countdownFraction`/`countdownTicks`)을 공개하고, `CountdownBar`는 그것을 `TimelineView(.explicit)`로 그린다. 표시와 실제 닫힘이 같은 값이다.
- **부재(SPEC 3, 규칙 6)**: `absenceInterval`(기본 3분) 동안 포인터가 움직이지 않으면 compact 섬을 조용히 숨기고 작업 reveal을 보류한다. 첫 움직임에 되돌린다. 알림은 여전히 섬을 연다. `AppState.isPresent`가 이 상태를 들고 있고 `HookServer`가 읽는다.

### 뷰
- `IslandView` enum 19개: `overview, empty, approval, question, error, finished, confused, upload, uploading, choose, mail, prompt, searching, result, note, settings, greeting, wardrobe, recap`. 크기·봇 위치는 `IslandConst.viewLayouts`(`IslandTypes.swift`).
- `IslandViewContent.swift`(~5,340줄, 구조체 ~70개)에 거의 모든 뷰가 있다. `IslandContentView`는 **19개 뷰를 ZStack에 동시에 마운트하고 opacity로만 전환**한다. 그래서 `@State`(질문 선택, diff 오버레이 등)가 뷰 전환 사이에 살아남고 `onAppear`는 한 번만 불린다. 보이지 않는 뷰는 `islandViewActive` 환경값(false)으로 `TimelineView`를 멈춘다. 활성 뷰만 마운트하도록 바꾸면 이 동작이 달라진다.
- 뷰는 `AppState`를 일반 프로퍼티(바인딩이 필요하면 `@Bindable`)와 `.environment`로 받는다. Observation이라 **뷰가 읽은 프로퍼티가 바뀔 때만** 다시 그린다. `focusTask`, `effectiveState`, 포커스 pill의 세션 북은 저장 프로퍼티로 두고 값이 실제로 바뀔 때만 대입한다(다른 pill의 단계 때문에 섬·Mochi가 다시 그려지지 않도록).
- **compact 상태 줄** (590f678, 488a5e2): 일하거나 사용자를 기다리는 세션이 있으면 compact 섬이 "Orca · ✎ HookServer.swift  2m"을 보여 준다(`CompactStatus`, `CompactStatusModel`, 뷰는 `IslandRootView`의 `CompactStatusOverlay`). 활동은 단계에서 읽는다(파일 편집, 명령, 검색, 파일 읽기, Thinking…, Done: <마지막 줄>, Error). 사용자 대기면 호박색(Needs your OK / Asks). 변경은 최소 0.4초 간격, 교차 페이드. 노치 화면에서는 **오른쪽 귀만** 넓어지고(최대 300pt, 720pt 패널 안) 섬 중심이 `offsetX`만큼 오른쪽으로 간다. Mochi·왼쪽 귀는 그대로. 노치 없는 화면은 가운데 바가 240→최대 420pt로 넓어진다. 일하는 세션이 없으면 예전 그대로(nw + 160). 줄 클릭 = 그 pill로 열기(사용자 대기면 `.goToAlert`와 같은 경로), 미니 클릭 = 그 pill 포커스, 미니 hover = 섬 아래 라벨(폴링 루프가 기하로 판정). 시간 텍스트는 자기 폭에 고정해서 활동 글이 잘리지 않는다.
- **같은 슬롯의 사운드 시각화**: 에이전트가 일하지도 기다리지도 않고 소리가 나면 슬롯이 막대 12개 + "♪ 제목 · 아티스트"가 된다(§13). 슬롯 폭은 상태 줄과 같은 `CompactStatusModel.metrics`로 재므로 `islandSize`, 히트 테스트, Mochi 시선, 미니 그리드가 함께 움직인다.
- 레이아웃 매직 넘버: 콘텐츠 프레임 98pt, 헤더 34pt, 봇 여백 `padding(.leading, 108/116)`, 업로드 지오메트리 36/526/103(`IslandRootView`, `UploadingView`, `ViewLayout`에서 공유).
- 채팅 높이 공식은 `IslandConst.chatPromptHeight(messageCount:)` 한 곳(테스트됨). `islandSize`(`IslandWindowController.swift` 하단)는 `IslandSize(width, height, offsetX)`를 돌려주고 모든 호출처(IslandContainer, `currentIslandFrame`, `isBotHit`, BotCanvasView 시선)가 그것과 `botPosition`(`IslandRootView.swift`) 하나를 쓴다. **오프셋까지 더해야** 클릭과 "때리기" 판정이 어긋나지 않는다. compact 폭·오프셋의 단일 출처는 `CompactIslandLayout`.
- 질문 카드: `QuestionView`가 실제 내용 높이를 재고 섬이 그 높이를 따라간다(cb243dd. 전엔 가장 긴 질문을 글자 수로 한 번 추정해서 짧은 질문·한국어 같은 넓은 문자가 어긋났다). 높이는 `QuestionLayout.height`(`nonisolated(unsafe)` 전역, `AskQuestion.swift`)로 `islandSize`에 전달된다.
- 통합 카드의 "hook/플러그인 설치됨" 검사(파일 읽기)는 캐시되고, 섬이 열리거나 창이 닫힐 때 갱신된다(body 평가마다 I/O 하지 않음).

### 창
- 720×560 고정 크기 borderless `nonactivatingPanel`, 레벨 `mainMenu+3`, 화면 상단 중앙 고정. 패널은 크기가 변하지 않고 SwiftUI가 안에 검은 `IslandShape`를 그린다. 봇 마스크는 560pt 패널 높이를 쓴다. `placeBelowIsland`의 320은 주석에 이유가 있다.
- 클릭 통과: 폴링 루프(섬 근처/바쁠 때 60Hz, 유휴 8Hz)가 `ignoresMouseEvents`를 토글. "근처"는 720×560 패널이 아니라 **섬 주변**으로 잰다. hover 진입/이탈도 같은 루프가 FSM에 공급. 클릭·드래그는 local/global NSEvent 모니터.
- 다중 디스플레이: `IslandDisplayChoice`(`notch`/`menuBar`/`followMouse`/`display:<UUID>`, 순수·테스트됨), 노치 크기는 `CoucouKit/IslandScreenGeometry.swift`(순수·테스트됨). `relocate`가 관찰되는 `notchWidth`/`notchHeight`/`hasNotch`를 쓰고 `.islandScreenChanged`를 post한다.
- 전역 단축키: Carbon `RegisterEventHotKey`(`HotKeyCenter.swift`). **ID = `ShortcutAction.allCases`의 인덱스**라 enum 순서를 바꾸면 ID가 바뀐다.

### AppState (`App/AppState.swift`, ~1,080줄 god object)
UI 상태, `[AgentTask]`, `sessionBooks: [pillId: SessionBook]`(§12), ~30개 설정(각각 `didSet`에서 UserDefaults 저장), 모든 통합의 데이터, 채팅 기록, pending approval/question(큐의 head만), 세션 diff, 플랜 게이지, `autoMusicPillId`(§13)를 다 가진다.
- **`@MainActor @Observable`** (2c58da4). 프레임마다 바뀌거나 UI가 보이지 않는 값은 `@ObservationIgnored`: `mousePosition`, `isPresent`, `lastExternalApp`, 업로드 시각, 옷장 미리보기, 계절 캐시, `sessionDiffs`와 그 장부, `autoMusicPillId`. 노치 기하와 `isPinned`는 관찰된다.
- **`@Observable`의 `didSet`은 `init` 안의 대입에서도 불린다.** 그래서 `init`은 저장된 값을 백킹 스토리지(`_name`)에 직접 쓴다. 새 설정 필드도 이 패턴을 따른다.
- `mode`/`view`에는 동기 훅 `modeWillSet`/`viewDidSet`(`@ObservationIgnored`)이 있다: FSM 동기화와 채팅 패널 key 전환이 같은 값 대입·`@Published` 타이밍에 의존했기 때문.
- 새 필드를 추가하면 **`DemoEngine`의 `Snapshot`에도 추가**해야 데모 모드 진입/복귀가 깨지지 않는다.
- 메인 pill: `mainPillChoice`(저장값, `"auto"` 또는 사용자가 고른 workspace pill)와 `mainPillId`(해석된 값, `private(set)`, 바뀔 때만 대입). 메인 pill을 읽는 코드는 모두 `mainPillId`를 쓴다. **고른** 메인은 `activeIntegrations`에 들어가면 안 된다. Auto 메인은 들어 있을 수 있다(메인이 옮겨 가도 사용자가 켠 pill이 사라지지 않도록). 활성 pill은 최대 4개(메인과 겹쳐도 `activeIntegrations.count` 기준). 자동 음악 pill은 이 4개에 세지 않는다(§13). Auto 규칙은 §12.
- `IslandConst.colorForProject`는 FNV-1a(`stableHash`)라 실행·기기마다 같은 색이다. 부분 일치는 길이·이름 고정 순서.

### Mochi 렌더링
- `CoucouKit/BotEngine.swift`(~1,715줄): `@Published` 없는 `ObservableObject`. 물리·트윈·파티클·눈·의상 상태를 가변으로 보관. 트윈은 **`TweenProp` enum으로 인덱스되는 고정 배열**(예전 문자열 키 딕셔너리), 상태별 설정은 `BotStates`, `slap()` 3번 → `.botDizzy`. 시계는 `CACurrentMediaTime`(aca174b 전에는 TimelineView 날짜가 2001년 기준이라 dt가 늘 0.05로 잘려 평활·스프링·파티클이 2–6배 빨랐다).
- `App/BotCanvasView.swift`: `TimelineView(.animation(minimumInterval:paused:))` + `Canvas`. `isShown`이 false면(데스크톱 Mochi가 나와 있거나 드래그 중인 섬 Mochi) 멈춘다. 매 프레임 `AppState`를 직접 읽고, 춤은 `NowPlayingCenter.current`가 재생 중일 때(어느 소스든). 엔진 명령은 NotificationCenter로만 전달(`triggerEmote`, `triggerSlap`, `botBlink`, `botSetTgEs`, `botGulp`, `botMorphTo`, `botGreet`).
- **프레임 속도 (`MochiFrameRate`, 순수·테스트됨)**: compact·미니 Mochi는 조용할 때 30fps, 빠른 동작(찌그러짐, 홉, 구르기, 흔들기, 이모트, dizzy, approval 바운스, 인사 손짓, 우편함 입) 중엔 디스플레이 속도 + 0.3초 유지. 펼친 섬과 드래그 중인 Mochi는 항상 디스플레이 속도.
- 그리기 캐시: 몸 윤곽(미리 계산한 단위 superellipse), 그라디언트·색, 의상 투영은 포즈별 `PoseMemo`(`MochiOutfitDrawing.swift`, ~1,620줄). `scripts/bench-mochi.sh --png/--compare`로 픽셀 동일성을 확인한다(§14).
- 의상: `MochiWardrobe.swift`(순수·테스트됨, 계절·부활절 로직), `MochiOutfitDrawing.swift`(정적 3D 투영 드로잉). 캐릭터는 코드로만 그린다(이미지·Rive·Lottie 금지).
- **"숨겨졌을 때 CPU 0%"**: 숨김 0.1%(측정, fb61019). 남은 것은 **8Hz 유휴 폴링**(이유는 코드 주석). 새 `TimelineView`·타이머는 숨겨졌을 때 멈추게 만든다(`islandViewActive`, `paused:`, `isShown`). 측정은 `scripts/measure-cpu.sh`.

### 저장소
- **Keychain** (`KeychainStore.swift`): generic password, service `fr.louisraille.NotchBuddy`(App Store 빌드도 동일 문자열), account = 키 이름. 키: `anthropic-api-key, google-api-key, openai-api-key, resend-api-key, resend-from, n8n-url, n8n-api-key, vercel-token, github-token, stripe-api-key, calcom-api-key, notion-api-key`. **키마다 처음 요청될 때 그 호출자 스레드에서 한 번 읽고 메모리에 둔다**(키별 잠금, 실행 시 읽기 없음, 키 목록 없음 — 아무 이름이나 동작). 값이 실제로 바뀌면 `.keychainValueChanged`(object = 키 이름)를 post한다.
- **UserDefaults**: §7 계약 표 참고.
- **디스크**: `~/Library/Application Support/NotchBuddy/`(`nb.sock`, `nb-hook`, `nb-hook.py`, `statusline-previous.json`, `Sounds/`, `recap.json`, `inbox/`), 로그 `~/Library/Logs/NotchBuddy/`(`nb.log` 등). 로그는 **`AppLog`의 직렬 백그라운드 큐**에서 쓴다(호출 시각에 타임스탬프, 파일 핸들 캐시, 폴더 0700·파일 0600, 1MB에서 비우고 다시 시작). `appendAppLog`는 어느 스레드에서나 부를 수 있다. DEBUG 전용: `/tmp/coucou-spectrum.log`(§14).

---

## 4. Hook 파이프라인 (에이전트 → 앱)

### 전송
- **Unix 도메인 소켓** (HTTP 아님). GitHub 빌드 `~/Library/Application Support/NotchBuddy/nb.sock`, App Store 빌드는 샌드박스 컨테이너의 `nb.sock`. 디렉터리 0700, 소켓 0600, `getpeereid`로 같은 UID만 허용. 동시 연결 32(**보관 중인 approval/question fd도 닫힐 때까지 슬롯을 차지**, 그래서 큐 용량이 approval 16 / question 8로 32보다 작다). 32개가 차면 연결을 끊지 않고 accept를 멈춘다: 새 클라이언트는 listen backlog(128)에서 슬롯이 빌 때까지 기다리고(릴레이는 막히지 않는다), backlog도 차면 connect가 즉시 실패한다. 페이로드 1MB(넘으면 `{"ok":true}`로 답하고 닫음), 연결마다 5초 무응답 타임아웃. 메시지는 JSON 한 줄, 연결당 이벤트 하나.
- **전송 계층은 `HookSocketServer`** (Foundation만, 스레드-per-연결 아님, d1770c8): 직렬 큐 하나(`ioQueue`)에서 리스닝 소켓의 `DispatchSourceRead`로 non-blocking accept → 대부분의 릴레이는 accept 시점에 이미 한 줄을 다 썼으므로 바로 읽고, 덜 온 연결만 자기 `DispatchSourceRead` + 무응답 타이머를 받는다. 프로세스 사슬(`ProcessAncestry.pidChain`)은 accept 직후 별도 직렬 큐에서 잡고(읽기를 막지 않는다. 동시에 돌리면 sysctl이 커널에서 경합해 CPU가 ~10배), 메시지는 자기 사슬이 잡힐 때까지 기다린다. 다 읽은 메시지는 fd를 blocking으로 되돌려 직렬 전달 큐에서 `HookServer.handleMessage`로 넘긴다(JSON 파싱, 호스트 조회, 메인 큐로 전달, 일반 이벤트는 답하고 `closeClient`). 보관 연결의 hang-up 감시(`makeHoldSource`)와 큐 로직은 그대로다. 모든 핸들러는 nonisolated 코드에서 만들어진다(§3 트랩 규칙).
- **릴레이는 일반 이벤트에도 앱의 짧은 `{"ok":true}`를 읽고 닫는다**(같은 0.3초 타임아웃 안, 7e3b148). 예전처럼 쓰고 바로 끝나면 앱이 accept하기 전에 릴레이 프로세스가 사라져 `LOCAL_PEERPID`·부모 사슬(가장 강한 IDE 신호)을 거의 잡지 못했다. 지금은 사슬이 대부분 잡히고, 세션별 호스트 캐시가 나머지를 채운다.
- **accept 루프는 죽지 않는다**(`AcceptRecovery`, `PendingRequestQueue.swift`): 일시 errno(EINTR, ECONNABORTED…)는 즉시 재시도, EMFILE/ENFILE/ENOBUFS/ENOMEM은 50ms부터 두 배씩 최대 1초 대기, 그 외(EBADF…)나 연속 50번 실패는 리스닝 소켓을 닫고 0.5초부터 최대 30초 간격으로 다시 만든다(폴더가 지워졌으면 0700으로 재생성). 시작 시 bind/listen 실패도 재시도한다. 경로가 sun_path(103바이트)보다 길면 포기.
- **전달 순서**: 읽기가 끝난 순서대로 번호를 매기고(`HookSocketServer`의 재정렬 버퍼), 직렬 전달 큐 → `DispatchQueue.main.async`(직렬 FIFO)로 넘긴다. 메인 액터 쪽에서는 **`OrderedDelivery`**가 순서를 지킨다: 16KB 넘는 Edit/MultiEdit/Write의 diff는 `HookFileDiff`가 백그라운드 큐에서 계산하고, 그동안 뒤에 온 모든 메시지(이벤트, approval, 질문, statusline)를 붙잡았다가 diff가 오면 도착 순서대로 넘긴다. 작은 diff는 큐 이동 없이 그 자리에서 계산한다(9c25283). 한 세션의 PreToolUse가 PostToolUse보다 먼저 처리된다.
- **Diff**: `CoucouKit/DiffEngine`은 Myers O((N+M)·D), 선형 공간(middle snake), 줄을 Int32로 인턴. 예전 O(m·n) LCS 표(최대 100만 칸, 메인 액터)는 없앴다. 한 이벤트의 diff를 HookServer(라이브 diff 단계)와 TurnRecorder(iPhone 마지막 턴)가 공유한다. `maxBytes`/`maxLines` 상한은 그대로.
- 앱이 시작할 때 `nb-hook`(`/bin/sh` 래퍼)와 `nb-hook.py`(Python 릴레이)를 지원 디렉터리에 **문자열로 써 넣는다**. 소스는 `HookRelayScripts.swift`(앱 타입 없음, 따로 컴파일·테스트됨). 두 Python 릴레이(GitHub/App Store)는 한 템플릿에서 소켓 경로만 바꿔 생성한다. App Store 빌드는 사용자가 NSOpenPanel로 고른 `~/.claude/coucou/`에 쓴다.

### "Claude Code를 절대 막지 않는다"의 구현
- 래퍼는 항상 exit 0. `xcode-select -p`가 실패하면 python3를 건너뛴다(개발자 도구 설치 대화상자 방지).
- 일반 이벤트: 0.3초 소켓 타임아웃(연결·쓰기·`ok` 읽기 모두). 앱이 답하지 않아도 0.3초 안에 끝난다.
- PermissionRequest: 릴레이 118초 대기 / 앱 115초 포기(Copilot·Muse 110초) / 설치된 hook timeout 120초.
- AskUserQuestion: 릴레이 125초 / 앱 120초 / hook 130초.
- 큐에서 기다리는 요청도 **도착 시각부터** 자기 마감이 흐른다. 앞 요청 때문에 늦게 화면에 떠도 릴레이보다 먼저 포기한다.
- 모든 실패 경로는 아무것도 출력하지 않아서 에이전트가 자기 터미널에서 다시 묻는다. Copilot은 fail-closed라 래퍼가 항상 `{"permissionDecision":"ask"}` 또는 `{}`를 출력한다. Antigravity PreToolUse에는 `{"decision":"ask"}`(빈 `{}`는 거부로 읽힌다).
- **이 타임아웃 사다리(앱 < 릴레이 < hook)를 바꿀 때는 세 값을 함께 바꾼다.** (`AgentHookConfig.claudeEvents`, `HookRelayScripts`, `HookServer`)

### 프로토콜
- `handleMessage`가 `coucou_kind`(`statusline`, `ask_user_question`)로 분기 → `hook_event_name == "PermissionRequest"`면 fd를 열어 둔 채 보관 → 나머지는 `processEvent`. 일반 이벤트와 statusline에는 `{"ok":true}\n`으로 답하고 닫는다. 파싱 불가한 줄도 `{"ok":true}`.
- `ask_user_question`: `--ask` PreToolUse hook이 보낸 `tool_name: "AskUserQuestion"` 페이로드에 릴레이가 `coucou_kind`를 붙인 것. `tool_input.questions`(1–4개, 각 옵션 2–4개, `AskQuestion.parse`)가 잘못되면 즉시 `ask`.
- 읽는 필드: `session_id`/`conversation_id`, `cwd`, `coucou_agent`, `term_program`, `bundle_id`, `tool_name`, `tool_input`, `prompt`, `message`, `last_assistant_message`, `platform`, `coucou_has_transport`, `permission_suggestions`, `rate_limits`. 릴레이가 `term_program`, `iterm_session_id`, `term_session_id`, `bundle_id`(`__CFBundleIdentifier`), `terminal_emulator`, `cwd`를 `setdefault`로 추가하고 Gemini/Antigravity/Copilot 이벤트 이름을 Claude 이름으로 정규화한다. 서버가 넣는 `coucou_host_bundle_ids`와 DEBUG 전용 `coucou_host_override`는 §12.
- 앱→릴레이 응답: `{"permissionDecision":"allow|always|deny|ask"}` 또는 `{"permissionDecision":"answer","answers":{…}}`. 응답 없이 닫힘(EOF) = 앱이 포기했거나 다른 곳에서 답함. 릴레이가 에이전트별 형식으로 변환한다(Claude/Codex `hookSpecificOutput.decision.behavior`, Claude의 `always`는 `updatedPermissions`, Copilot/Muse 평면 형식, Hermes `{"choice":…}`, AskUserQuestion은 PreToolUse `allow` + `updatedInput`).
- `coucou_agent`(`^[a-z0-9-]{1,24}$`, `claude` 거부) → pill ID `agent_<name>`. 자세한 건 `docs/AGENTS.md`.

### 세션 모델
- 라우팅은 순수 `HookRouting` + `HostResolver`다: **IDE마다 pill 하나, pill 뒤에 `SessionBook`으로 여러 세션**. 매핑 표는 §12. `coucou_agent`가 붙은 다른 서드파티 에이전트는 `agent_<name>`.
- `session_id`는 RecapStore, TurnRecorder, approval 매칭에 쓰인다(익명 세션 키는 `pillId+cwd`).
- 종료: `Stop` → finished 후 5.2초 뒤 idle/제거, `SessionEnd` → 제거, `Interrupt`(Codex) → idle. 에이전트가 SessionEnd 없이 사라진 세션은 만료된다(§12).
- **Approval·Question은 FIFO 큐**(`PendingRequestQueue`, SPEC §3 규칙 9). 서로 밀어내지 않는다. 화면에는 head 하나만(`AppState.pendingApproval`/`pendingQuestion`, `presentedApprovalId`/`presentedQuestionId`)이고, 결정·끊김·타임아웃·다른 곳에서 답함으로 head가 빠지면 다음 요청이 뜬다. 큐가 가득 차면(approval 16, question 8) 새 요청은 즉시 `ask`.
- 요청은 fd가 아니라 **요청 ID와 단조 시계 마감**으로 식별한다(fd 번호는 재사용되어 오래된 타이머가 새 요청을 닫을 수 있었다).
- 보관 fd는 `DispatchSource` 읽기 소스로 감시하고, **소스의 cancel 핸들러에서만 닫는다**(`finishHeld`: 응답 줄을 쓴 뒤 cancel). 소스가 hang-up을 보면 "Handled in X." 노트.
- 큐에서 빠지는 조건(`PendingRequestQueue.resolves`): 같은 pill·세션의 PostToolUse/PostToolUseFailure 중 **도구 이름과 정렬된 입력 JSON이 같은 것**, 또는 Stop/StopFailure/UserPromptSubmit/SessionEnd/Interrupt. 기다리던 요청은 조용히, 화면의 카드는 노트와 함께 닫힌다. 카드가 떠 있는 동안 그 pill의 다른 이벤트는 건너뛴다(approval 상태를 덮어쓰지 않도록).
- 어느 출처가 approval/question 카드를 받는지는 `HookRouting`이 정한다: Cursor·VS Code·IDE pill의 Claude Code, 터미널의 Claude Code(Settings의 terminal cards가 켜졌을 때), Codex·Copilot·Muse, Hermes(transport가 있을 때). 그 외는 즉시 `ask`.

### 에이전트별 설치 위치 (`HookServer.swift` 1381–2140, `SettingsView`에서 preview/write 쌍으로 호출)

| 에이전트 | 파일 |
|---|---|
| Claude Code (+ Cursor/VS Code, 번들 ID로 구분) | `~/.claude/settings.json` (`hooks`, `statusLine`) |
| Gemini CLI | `~/.gemini/settings.json` |
| Antigravity | `~/.gemini/config/hooks.json` |
| Codex | `~/.codex/hooks.json` |
| Copilot CLI | `~/.copilot/hooks/coucou.json` (Coucou 전용 파일) |
| Muse | `~/.config/muse/settings.json` |
| OpenCode / Amp | `~/.config/opencode/plugins/coucou.js` / `~/.config/amp/plugins/coucou.ts` (생성된 플러그인, 표시 전용) |
| Hermes | `~/.hermes/plugins/coucou/`, `~/.hermes/config.yaml`(`HermesConfigMerger`, 줄 단위 YAML 병합) |

- **모든 에이전트 파일 쓰기가 `ClaudeSettingsFile` 하나를 거친다**: 무효 JSON 거부, 미리보기와 바이트 비교, 고유 이름 백업, temp→rename, 권한 유지, 심볼릭 링크 추적. JSON은 `/`를 이스케이프하지 않고 쓴다(`\/`로 사용자 파일의 모든 경로를 고쳐 쓰던 문제, 097aeac). 읽을 수 없는 `config.yaml`을 빈 파일로 취급하지 않는다.
- **Claude hooks 미리보기**: 설치인지 제거인지 문장으로 밝히고, 같은 방식으로 다시 인코딩한 현재 파일과의 **줄 diff**(+ 초록, − 빨강, 헝크 사이 "…", `SettingsDiffLines`)만 보여 준 뒤 확인을 기다린다. 바뀔 것이 없으면(+0 −0) 빈 diff 대신 "already installed and up to date"와 OK만 보이고 아무것도 쓰지 않는다(b779413). 제거도 같은 확인을 거친다.
- 병합 로직은 순수 `AgentHookConfig.swift`(Hermes는 `HermesConfigMerger.swift`). 설치기는 먼저 기존 Coucou hook(이전 설치, 다른 경로)을 빼고 나머지를 그대로 둔 뒤 자기 것을 붙인다.
- **Coucou hook 인식은 정확한 형태로만** (`CoucouHookCommand`): `Application Support/NotchBuddy` 또는 `.claude/coucou`의 `nb-hook` 경로, 선택적 `/bin/sh`, `--ask` / `--statusline` / `--agent <name> [Event]`. 경로에 "coucou"·"NotchBuddy"·"nb-hook"이 **포함**됐을 뿐인 사용자 hook은 설치·제거·설치 감지에서 건드리지 않는다. 사용자 hook과 같은 그룹에 있던 Coucou hook만 빠지고 그룹은 남는다.
- **OpenCode 플러그인 v1/v2** (f145d9e): OpenCode 1은 export마다 팩토리로 부르고, OpenCode 2는 default `{ id, setup }` 정의가 없으면 플러그인을 거부한다. 둘은 서로 호환되지 않아서 설치기가 `opencode --version`(Homebrew·`/usr/local`·`~/.opencode/bin`·`~/.local/bin`, 3초 제한)으로 메이저 버전을 묻고 맞는 쪽을 쓴다(알 수 없으면 2). v2는 `ctx.event.subscribe()`의 이벤트(`session.execution.*`, `session.next.tool.called`, `permission.asked`…)를 Claude 이벤트 이름으로 옮긴다. 생성물에는 `coucou-opencode-plugin v2` 마커가 있고, **마커 없는 예전 `coucou.js`는 설치 안 됨으로 본다**(설정이 재설치를 권한다).
- Hermes approval transport: 오류가 나면 `raise`(Hermes가 `transport_fallback: builtin`으로 자기 프롬프트를 띄움). `deny`로 답하지 않는다. Hermes approval 감지는 Hermes bash 런처에서 venv Python을 읽는다.
- Status line 릴레이: 이전 status line이 다시 이 릴레이를 실행하면 `COUCOU_STATUSLINE_CHAINED`로 재귀를 막는다.

### 채팅
CLI가 아니라 HTTP API 직접 호출. `ClaudeService.chat`→`api.anthropic.com/v1/messages`(`web_search` 도구, 시스템 프롬프트 "Mochi"). Google/OpenAI/Ollama/LM Studio는 `chatOpenAICompatible`, 로컬 모델은 `LocalChat.streamChat`(SSE, `<think>` 필터). 첫 턴에 창 컨텍스트(`WindowContextCapture`: AX 창 제목 + AppleScript 브라우저 URL)나 파일을 붙인다.
- 저장된 Anthropic 형식 기록 → OpenAI 호환 메시지 변환은 순수 `openAICompatibleChatMessages`(`ClaudeResponseText.swift`, 테스트됨): 모든 텍스트 블록을 잇고, 이미지·PDF는 자리표시자, 텍스트 파일 내용은 로컬 모델에만(클라우드는 자리표시자), 텍스트 없는 턴은 버린다. 대화 중 provider를 바꿔도 질문이 사라지지 않는다.

---

## 5. 서비스 통합 (폴러)

- 폴러 7개(`N8n, Vercel, Resend, Github, Stripe, Calcom, Notion` `*Poller.swift`)는 **`ServicePollGate`를 공유**한다(GithubPoller의 규칙을 일반화): pill이 꺼져 있고 iPhone 동기화도 꺼져 있으면 네트워크 없음(`isWanted`), 서비스당 동시 폴링 하나, 키가 바뀐 뒤 도착한 응답은 버림(메인 스레드 generation 검사), pill을 켜거나 새 키를 저장하면(`.keychainValueChanged`) 즉시 폴링. 완료 핸들러는 async 함수가 되어 게이트가 폴링 끝을 안다. 게이트의 타이머는 **메인 큐에서** 울린다(전역 큐에서 메인 액터 클로저를 부르다 실행 몇 초 뒤 트랩하던 문제, b52db3c).
- 폴러 본문(`KeychainStore.get` + `URLSession` + 무타입 `JSONSerialization` + `AppState` 갱신)은 여전히 서비스마다 따로다. Vercel/N8n/Stripe는 "task 상태 flash + badge + 소리 + 60초 후 idle" 블록을 각자 복사해 갖고 있다.
- 주기·첫 틱 지연·엔드포인트·API 버전 헤더·Stripe 첫 로드 무음은 그대로다. 고정 API 버전 헤더: Cal.com `cal-api-version: 2024-08-13`, Notion `Notion-Version: 2022-06-28`. Cal.com v2는 예약 상태가 소문자("accepted")라 대소문자 무시로 비교한다.
- iPhone 쪽 `PhoneLink/ServiceDetailRunner.swift`가 **모든 서비스 API 클라이언트를 async/await로 한 번 더** 구현한다(상세 조회 + redeploy/rerun/merge 같은 액션).
- 그 외: 음악(Apple Music·Spotify·TIDAL)은 §13. 받아쓰기는 `SFSpeechRecognizer`. `SafeWebURL.safeWebURL()`은 http/https만 `NSWorkspace.open`에 넘기는 보안 가드다(유지할 것). 주간 리캡은 `recap.json`(schemaVersion 1, 12주 보관).

**남은 통합 형태:** `ServiceIntegration` 프로토콜(pillId, keychainKeys, `fetch`, `events(old:new:)`, `phoneSnapshot`, `detail`) + Codable 기반 `ServiceHTTPClient` 하나 + badge/소리/자동 해제를 한 곳에서 하는 `IntegrationEventSink` + 문자열 리터럴 대신 타입 있는 `PillID` 상수. 스케줄·가드는 이미 `ServicePollGate`에 있다.

---

## 6. iPhone 연동

> **이 포크에서는 iPhone 연결이 동작하지 않는다.** CloudKit 컨테이너 `iCloud.fr.louisraille.Coucou`, 번들 ID, APNs 키, relay 배포가 모두 원 저자 팀 것이고, `PHONE_LINK` 구성(DebugCloud·Release·ReleaseCloud·App Store)과 iPhone 타깃은 이 Mac에서 서명되지 않는다(§11). 자기 iCloud 컨테이너·APNs 키·relay를 갖추기 전까지 아래 내용은 코드 지도로만 유효하다. 빌드는 `CODE_SIGNING_ALLOWED=NO`로 계속 확인한다.

- **전송은 CloudKit private DB**. 컨테이너·존·레코드 타입 이름은 **`CoucouKit/CloudSchema.swift` 한 곳**에서 온다(컨테이너 `iCloud.fr.louisraille.Coucou`, 존 `Coucou`, 레코드 타입 12개, 값은 바이트 단위로 계약). 민감 필드는 `encryptedValues`.
- Mac → iPhone: `Session`(`session-<pillId>`), `ApprovalRequest`(`approval-<fp앞32>`), `Turn`(`turn-<pillId>`), `Service`(`service-<pillId>`), `ServiceDetail`(`detail-<pillId>`), `Ping`.
- iPhone → Mac: `Decision`(`allow`/`deny`, 2초 폴링, 지문 일치 시에만 적용, 읽으면 삭제), `Answer`, `Instruction`(15초 폴링 → `claude -p <text> --resume <sid>`, GitHub 빌드만, 10분 이내), `ServiceAction`(마지막 detail에서 제안된 것 + `allowedKinds`만), `PhoneToken`, `Pong`.
- 승인 지문: `pillId, sessionId, tool, command, inputKey`를 `\u{1F}`로 이어 SHA-256. relay는 소문자 hex 64자를 요구한다.
- **필드 매핑은 아직 양쪽에 따로 쓰여 있다.** Mac `SessionSnapshot`(`PhoneLink/SessionPublisher.swift`)과 iPhone `SessionItem`(`Phone/PhoneLink.swift`)이 같은 필드를 독립적으로 매핑한다. 이름(컨테이너·존·레코드 타입)만 `CloudSchema`로 모였다.
- Mac 쪽 리더 6개(ApprovalRelay, QuestionRelay, InstructionRunner, ServiceDetailRunner, LiveActivityRelay, SessionPublisher)가 각자 change token으로 같은 존을 폴링한다. 읽으면 삭제하는 의미론은 각 리더가 레코드 타입으로 필터링한다는 전제 위에 서 있다. AppState 변경은 `ChangeObserver`(debounce 0.5/1/2초)로 따라간다.
- **Live Activity**: iPhone이 push-to-start/update 토큰을 `PhoneToken`에 씀 → Mac `LiveActivityRelay`가 Mac이 20초 잠겨 있으면(에이전트가 대기 중이면 즉시) 시작, 잠금 해제 30초 후 종료 → `https://coucou-relay.raillelouis.workers.dev/v1/live-activity`(기본값, `phoneRelayURL` default로 변경 가능)에 POST → relay가 ES256 JWT로 APNs 호출. 두 APNs 서버가 모두 거부한 토큰(BadDeviceToken)은 푸시마다 다른 서버를 한 번만 시도한다. **Mac과 relay 사이 인증이 없다.** 포크라면 relay를 직접 배포해야 한다(`docs/IPHONE.md`, `relay/README.md`).
- `MacStubs.swift`: CoucouKit의 `BotEngine`이 `SoundEngine.shared`와 `.botDizzy`를 참조하므로 iOS 타깃에 같은 이름의 무음 스텁을 제공한다. CoucouKit을 진짜 패키지로 만들려면 이 의존성을 주입으로 바꿔야 한다. `IslandTypes.swift`도 Mac 전용 타입(IslandMode, ChatProvider, ViewLayout, IslandConst)을 iOS로 끌고 간다.
- 위젯은 앱 그룹 `group.fr.louisraille.Coucou`의 `sessions.json`을 읽는다. `PillColors`는 `UserDefaults.standard`를 써서 위젯에서 사용자 색이 안 보인다.
- iPhone 앱은 `Localizable.xcstrings`를 쓰지 않는다(Mac 두 타깃만).

---

## 7. 깨면 안 되는 계약

리팩터링의 자유도는 내부 구조에 있다. 아래 값들은 **바꾸는 순간 기존 사용자 데이터·권한·iPhone·relay가 끊긴다.** 바꿔야 한다면 마이그레이션 코드와 함께 의도적으로 바꾼다.

| 범주 | 값 |
|---|---|
| 번들 ID | `fr.louisraille.NotchBuddy`(Mac GitHub), `fr.louisraille.Coucou`(App Store·iPhone), `.Widgets`, `.NotificationContent`. Keychain·UserDefaults·TCC 권한(손쉬운 사용, 자동화, 시스템 오디오 녹음, 알림)이 여기 묶여 있다 |
| Keychain | service `fr.louisraille.NotchBuddy` + §3의 키 이름 12개 |
| Pill ID | `integration_claude, agent_cursor, agent_antigravity, agent_codex, agent_gemini, agent_copilot, agent_muse, agent_opencode, agent_amp, agent_hermes, agent_claude-desktop, ai_anthropic, ai_google, ai_openai, ai_ollama, ai_lmstudio, integration_resend, integration_n8n, integration_vercel, integration_github, integration_notion, integration_calcom, integration_stripe, integration_music, integration_spotify, integration_tidal`(새, 색 `#A3A8B0`), 동적 `agent_<coucou_agent>`, 그리고 동적 패밀리 **`ide_<slug>`**(번들 ID 소문자, `[a-z0-9]` 밖의 연속 문자는 `-` 하나, 예: `com.jetbrains.WebStorm` → `ide_com-jetbrains-webstorm`; JetBrains 폴백은 `ide_com-jetbrains-ide`. 슬러그 규칙 `HostResolver.idePillId`를 바꾸면 저장된 ID가 끊긴다). UserDefaults, CloudKit 레코드 이름, `recap.json`, 위젯 설정에 저장된다. 단일 출처는 `CoucouKit/PillCatalog.swift`지만 코드 곳곳(`AutoMusicPill.pillId(forSource:)`, `CompactVisualizer.pillId(for:)` 등)에 리터럴로 반복된다. `integration_claude`의 카탈로그 이름은 "Claude Code"(ID는 그대로) |
| UserDefaults | `activeIntegrations, mainPill`(workspace pill ID 또는 센티널 **`"auto"`** = `PillCatalog.autoMainPillId`; 키가 없거나 이 빌드에 없는 pill이면 Auto)`, lastActiveWorkspacePill, lastActiveWorkspaceBundleId`(Auto 메인용: 마지막 활성 workspace pill과, `ide_` pill이면 그 앱의 번들 ID — 슬러그는 되돌릴 수 없다)`, pillColors, mochiOutfit, soundEnabled, soundVolume, claudeModel, chatProvider, googleChatModel, openAIChatModel, ollamaChatModel, lmstudioChatModel, ollamaServerURL, lmstudioServerURL, openOnHover, autoCloseInterval, absenceInterval, islandDisplay, hotkeyEnabled, hotkeyFlags, hotkeyCode, shortcut.<action>.{keyCode,flags,enabled}, vercelProjectFilter, n8nWorkflowFilter, claudePlanUsage, showPlanInNotch, showCodexPlanInNotch, settingsSection, coucouHooksInstalled, hermesApprovalsEnabled, terminalCardsEnabled, iPhoneSyncEnabled, iPhoneLiveActivityEnabled, iPhoneInstructionsEnabled, phoneRelayURL, phoneLinkPing, mochiOnDesktop, desktopMochiX, desktopMochiY, dictationLanguage, dictationLastLocale, recapEnabled, recapHideProjects, recapLastShownWeek, coucou.spotifyAutomationGranted, coucou.musicAutomationGranted` + 알림·정지 감지(§12): `macNotificationsEnabled, notifyFinished, notifyErrors, notifyWaiting, notifyStalled`(Bool, 없으면 모두 true)`, stallThresholdMinutes`(Int 분, 기본 3, 설정 선택지 0/2/3/5/10, 0 = 끔) + 음악·시각화(§13): `autoMusicEnabled`(Bool, 기본 true, "Show music automatically"), `visualizerEnabled`(Bool, 기본 true, false면 오디오 캡처 없음) + 시스템 키 `AppleLanguages`(설정의 언어 선택이 앱 도메인에 씀, 코드 `en, zh-Hans, hi, es, ar, fr, bn, pt-BR, ru, id, ko`). DEBUG 전용(계약 아님): `debugFakeMusic`, `debugLogSpectrum` |
| 디스크 경로 | `~/Library/Application Support/NotchBuddy/nb.sock`·`nb-hook` (이미 설치된 사용자의 `~/.claude/settings.json`이 이 경로를 가리킨다. `CoucouHookCommand`가 인식하는 형태이기도 하다). `~/.config/opencode/plugins/coucou.js`의 `coucou-opencode-plugin v2` 마커 |
| Hook 프로토콜 | 이벤트 이름, `coucou_agent`·`coucou_kind` 필드, `permissionDecision` 응답 형식, 일반 이벤트의 `{"ok":true}` 응답(릴레이가 읽고 닫는다), 타임아웃 사다리, 릴레이가 붙이는 `term_program`·`bundle_id`·`terminal_emulator`, 서버가 주입하는 `coucou_host_bundle_ids`(클라이언트 값은 덮어씀), DEBUG 전용 `coucou_host_override`(빈 문자열 = "앱 없음", 있으면 재생으로 보고 Auto 메인을 저장하지 않는다)(§12) |
| Info.plist | `NSAudioCaptureUsageDescription`(GitHub 타깃 `Info.plist`만. 시스템 오디오 녹음 권한 프롬프트 문구), `NSAccessibilityUsageDescription`(창 컨텍스트·TIDAL), `CFBundleLocalizations`(11개, `project.yml`에서 생성) |
| 음악 소스 | `NowPlayingSource` raw 값 `music/spotify/tidal`과 번들 ID `com.apple.Music`, `com.spotify.client`, `com.tidal.desktop`(TIDAL 소리는 헬퍼 `com.tidal.desktop.player`가 낸다) |
| CloudKit | `CloudSchema`의 컨테이너·존 `Coucou`·레코드 타입 12개, 레코드 이름 접두사, 필드 이름과 평문/암호화 구분, 구독 ID(`coucou-zone-mac`, `coucou-zone-phone-silent`, `coucou-approvals`, `coucou-approvals-mochi`), 지문 알고리즘, `BotState` raw 값 |
| Live Activity / relay | Swift 타입 이름 `MochiActivityAttributes`(relay가 하드코딩), `MochiActivityState` 필드(문자열 ≤60자, 정수 0–999; relay에 추가하지 않은 새 필드는 조용히 버려진다), APNs topic `fr.louisraille.Coucou.push-type.liveactivity` |
| iOS 식별자 | 앱 그룹과 `sessions.json`, URL `coucou://mochi/<id>`, 위젯·컨트롤 kind, 알림 카테고리·액션 ID(`COUCOU_APPROVAL` 등), 인텐트 타입 이름, Spotlight `domainIdentifier` `turns`, 사운드 파일 이름 |
| 단축키 | `ShortcutAction` enum 순서 (Carbon hotkey ID) |
| 번역 | `Localizable.xcstrings`의 키(일부는 `hooks.install` 같은 ID, 대부분은 영어 원문). 원문을 바꾸면 11개 언어 번역이 끊긴다: 키를 바꿀 때 번역도 옮긴다 |

---

## 8. 테스트 규칙

- XCTest 타깃은 없다. 각 `scripts/test-X.sh`가 `NotchBuddy/Sources/...`의 **소스 파일 몇 개**와 `tests/XTests.swift`(`@main`)를 `swiftc`로 직접 컴파일해 실행한다. `test-all.sh`가 `scripts/test-*.sh`를 전부(45개, ~1분) 돌리고 실패한 것만 출력한다.
- 따라서 아래 파일은 **Foundation(또는 표에 적힌 프레임워크)만 import하고 다른 앱 타입·싱글턴·AppKit·SwiftUI를 참조하면 안 된다.** 옮기거나 이름을 바꾸면 해당 스크립트의 하드코딩된 경로도 고친다.

| 스크립트 | 컴파일되는 소스 (`App/`·`CoucouKit/`는 `NotchBuddy/Sources/` 기준) |
|---|---|
| test-agent-hooks | `App/ClaudeSettingsFile` + `App/ClaudeHookDetection` + `App/AgentHookConfig` (`-warnings-as-errors`) |
| test-app-log | `App/AppLog` (`-strict-concurrency=complete`. 임시 폴더에서 권한, 회전, 지워진 파일, 여러 스레드 2,000줄) |
| test-ask-question | `App/AskQuestion` |
| test-audio-spectrum | `App/AudioSpectrumMath` + `App/SpectrumAnalyzer` (Accelerate·Synchronization, macOS 15 타깃. 대역 경계, bin 범위, dB 정규화, 평활, 합성 사인 분석) |
| test-auto-close, test-island-hover, test-island-sync | `App/IslandStateMachine` (`-strict-concurrency=complete`) |
| test-auto-main-pill | `App/AutoMainPill` + `App/HostResolver` (`-strict-concurrency=complete -warnings-as-errors`, Auto 메인 pill의 전환·해석) |
| test-auto-music-pill | `App/AutoMusicPill` (`-strict-concurrency=complete -warnings-as-errors`, 등장·30초 잔류·전환) |
| test-change-observer | `App/ChangeObserver` (`-strict-concurrency=complete`) |
| test-chat-history | `App/ClaudeResponseText` (`-warnings-as-errors`, 기록 변환) |
| test-chat-parsing | `App/LocalChat` + `App/ChatMarkdown` (`tests/fake_local_llm.py` 서버 사용) |
| test-claude-hooks | `App/ClaudeHookDetection` |
| test-claude-host | `App/ClaudeHost` + `App/HostResolver` + `App/HostAppInfo` (예외적으로 AppKit import) |
| test-claude-response | `App/ClaudeResponseText` (`-warnings-as-errors`) |
| test-claude-settings | `App/ClaudeSettingsFile` |
| test-compact-status | `App/CompactStatus` + `App/SessionBook` + `CoucouKit/DiffEngine` (`-strict-concurrency=complete -warnings-as-errors`, 상태 줄 pill 선택·단계 분류·경과 시간·compact 폭/오프셋/히트 영역, 턴 시작 시각) |
| test-compact-visualizer | `App/CompactVisualizer` + `App/CompactStatus` + `App/SessionBook` + `App/NowPlaying` + `CoucouKit/DiffEngine` (`-strict-concurrency=complete -warnings-as-errors`, 슬롯 우선순위, 제목 줄, 막대 높이, 프레임 간격) |
| test-desktop-mochi | `App/DesktopMochiLogic` |
| test-diff-engine | `CoucouKit/DiffEngine` (Myers. 큰 파일, 무관한 파일, 빈 쪽, 반복 줄, 예전 LCS와 1,500개 무작위 비교) |
| test-display-choice | `App/IslandDisplayChoice` |
| test-github-activity / -pulse | `App/GitHubActivity` / `App/GitHubPulse` |
| test-hermes-config | `App/HermesConfigMerger` + `App/ClaudeHookDetection` |
| test-hook-file-diff | `CoucouKit/DiffEngine` + `App/HookFileDiff` + `App/OrderedDelivery` (`-strict-concurrency=complete`, 페이로드 파싱, 백그라운드 이동, 순서 유지) |
| test-hook-relay | `App/HookRelayScripts` → 생성된 Python을 `tests/hook_relay_check.py`로 가짜 소켓에 실행 (python3 없으면 Python 부분 건너뜀) |
| test-hook-routing | `App/HookRouting` + `App/HostResolver` + `App/SessionBook` + `CoucouKit/IslandTypes` + `CoucouKit/IslandScreenGeometry` + `CoucouKit/PillColors` (이벤트 → 호스트 → pill, 카드 여부) |
| test-hook-socket | `App/HookSocketServer` + `App/PendingRequestQueue` (`-strict-concurrency=complete -warnings-as-errors`). 임시 소켓에서 동시 클라이언트, 나뉜 쓰기, 1MB 상한, 무응답 타임아웃, 보관 연결, 연결 상한, 전달 순서 (~5초, 실제 소켓은 건드리지 않음) |
| test-host-resolver | `App/HostResolver` (`-strict-concurrency=complete`) |
| test-island-types | `CoucouKit/IslandTypes` + `CoucouKit/IslandScreenGeometry` (프로젝트 색, 채팅 높이) |
| test-keychain-store | `App/KeychainStore` (`-strict-concurrency=complete`. 가짜 백엔드: 지연 읽기, 400개 동시 get에 키당 한 번 읽기, set/remove 알림. 실제 Keychain은 건드리지 않음) |
| test-mochi-frame-rate | `App/MochiFrameRate` |
| test-notification-policy | `App/SessionBook` + `App/SessionAlert` + `App/NotificationPolicy` (`-strict-concurrency=complete`, 토글·억제·중복·문구) |
| test-pending-requests | `App/PendingRequestQueue` (`-strict-concurrency=complete`) |
| test-pill-colors | `CoucouKit/PillColors` |
| test-plan-gauge | `App/ClaudePlanGauge` |
| test-replay | Swift 없음. `scripts/coucou-replay.py`를 `tests/replay_check.py`의 임시 가짜 소켓 서버에 실행 (실제 소켓은 건드리지 않음, ~3초) |
| test-safe-links | `App/SafeWebURL` |
| test-screen-geometry | `CoucouKit/IslandScreenGeometry` |
| test-session-book | `App/SessionBook` (`-strict-concurrency=complete`, 긴급도·보관·만료·정지) |
| test-session-card-text | `App/SessionCardText` + `App/SessionBook` + `App/HostResolver` (`-strict-concurrency=complete`, 카드의 세션 목록 문구) |
| test-shortcuts | `App/ShortcutLogic` |
| test-terminal-target | `App/TerminalTarget` |
| test-tidal-now-playing | `App/TidalNowPlaying` (`-strict-concurrency=complete -warnings-as-errors`, AX 트리 모델·플레이어 바 선택·창 제목·재생 라벨·미디어 키 페이로드) |
| test-wardrobe | `CoucouKit/MochiWardrobe` |

- 리팩터링의 기본 전략: **로직을 이런 순수 파일로 빼내고, 같은 방식의 테스트 스크립트를 추가**한 뒤 UI를 바꾼다. 새 스크립트는 `scripts/test-*.sh` 이름이면 `test-all.sh`와 CI가 자동으로 집어 간다. 빠르게(수 초) 유지한다. 측정·벤치는 `bench-*.sh`/`measure-cpu.sh` 이름으로 두어 `test-all.sh`가 집어 가지 않게 한다.
- 테스트 없는 영역: AppState, IslandWindowController, HookServer의 AppState 반영(라우팅 결정 자체는 `test-hook-routing`, 소켓 전송은 `test-hook-socket`), MacNotifier·StallMonitor 타이머, 폴러·ServicePollGate, BotEngine(그리기는 `bench-mochi.sh --compare`로 픽셀 비교), `SystemAudioCapture`의 Core Audio 부분, `TidalController`의 AX 부분, MusicPillDriver, PhoneLink, iPhone 앱 전부. 라우팅·UI는 `coucou-replay.py`로 실행 중인 앱에 대고 손으로 확인한다(§12, §14).
- 손으로 동기화해야 하는 복사본(드리프트 위험): `scripts/test-weekly-recap.swift`(→`RecapStore` 모델, `test-all.sh`가 돌리지 않음), `scripts/RenderOutfits.swift`(스텁), `coucou-replay.py`의 `relay_output`(→ `HookRelayScripts`의 응답 변환, 표시용), `scripts/HookSocketBench.swift`의 예전 스레드-per-연결 서버, `scripts/BenchDiff.swift`의 예전 LCS.
- 자동 닫힘 테스트는 타이밍 여유에 의존한다(느린 CI에서 flaky했던 이력, #376).

---

## 9. 리팩터링 지도

### 핫스팟 (큰 순서)
1. `App/IslandViewContent.swift` ~5,340줄 — 뷰 ~70개. 뷰별 파일로 분리(§3의 "동시 마운트" 동작 주의).
2. `App/SettingsView.swift` ~2,150줄 — `@State` ~50개(에이전트마다 installed/showDiff/pendingJSON/pendingInstall), 문자열 switch로 섹션 선택.
3. `App/HookServer.swift` ~2,150줄 — approval/question 큐(143–385), 메시지 처리(`handleMessage`, 462), 이벤트 → AppState(528), 세션 → pill·trim(809), 알림·동적 pill·헬퍼·권한·질문(981–1380), 설치기(1381–2140). 릴레이 스크립트는 `HookRelayScripts.swift`, 병합 로직은 `AgentHookConfig`/`HermesConfigMerger`, 라우팅 결정은 `HookRouting`, 소켓 전송은 `HookSocketServer`, diff는 `HookFileDiff`로 이미 빠졌다. 남은 분리: `PendingDecisionBroker` / `StepFormatter` / 에이전트별 `AgentInstaller`.
4. `CoucouKit/BotEngine.swift` ~1,715줄, `MochiOutfitDrawing.swift` ~1,620줄.
5. `App/IslandWindowController.swift` ~1,400줄 — 창, 폴링, FSM 접착, 단축키, 드래그, dizzy, `islandSize`.
6. `App/AppState.swift` ~1,080줄 — 설정 / UI 상태 / 세션 / 통합 데이터로 분리.

### 알려진 문제 (아직 열려 있음)
- **같은 UID 소켓 신뢰:** `getpeereid`로 같은 UID만 검사하므로 사용자 권한의 아무 프로세스나 가짜 approval 카드를 띄우거나(결정은 사용자 클릭이 필요) 세션을 흉내 낼 수 있다. `coucou_host_override`가 DEBUG 전용인 이유이기도 하다.
- **relay 인증 없음:** Mac → Live Activity relay POST에 인증이 없다(§6).
- **이 포크에서 iPhone 연결은 죽어 있다:** 자기 iCloud 컨테이너·APNs 키·relay를 갖추고 `PHONE_LINK` 구성을 서명하기 전까지 동기화·Live Activity·알림 액션은 동작하지 않는다(§6, §11).
- **OpenCode 2 이벤트 필드 이름은 일부 추측이다:** `V2_EVENTS` 매핑과 `sessionID`/`tool`/`input` 같은 필드는 여러 후보(`d.sessionID || d.session_id || d.info?.id`…)로 읽는다. 실제 OpenCode 2 세션으로 확인하고 고친다(`HookRelayScripts.openCodePluginSource`).
- **TIDAL은 손쉬운 사용 권한이 필요하다:** 권한이 없으면 제목·컨트롤 없이 시각화가 "TIDAL"만 보인다(Coucou는 이 권한을 먼저 요구하지 않는다). TIDAL UI 구조(`#footerPlayer`, 버튼 순서)가 바뀌면 파서가 깨진다(§13).
- **App Store 빌드에는 오디오 캡처가 없다:** 샌드박스에서 오디오 입력을 읽으려면 마이크 entitlement가 필요해 탭을 컴파일에서 뺐다. 시각화는 정적 막대만 보인다. 그런데 설정의 "Sound visualizer in the notch" 토글과 "시스템 오디오 녹음 권한" 설명은 App Store 빌드에도 그대로 보인다(문구 정리 필요).
- **`--statusline`이 저장된 이전 명령을 실행:** 릴레이가 `statusline-previous.json`의 `command`를 `/bin/sh -c`로 실행한다(재귀만 막았다). 이 파일을 쓸 수 있으면 status line마다 임의 명령이 돈다.
- `QuestionLayout.height`가 `nonisolated(unsafe)` 전역이다(§3). 8Hz 유휴 폴링(§3).
- `PillColors`가 `UserDefaults.standard`라 위젯에서 사용자 색이 안 보인다(§6).
- Vercel/N8n/Stripe의 flash 블록 복사, iPhone `ServiceDetailRunner`의 API 클라이언트 중복(§5), `SessionSnapshot`/`SessionItem` 이중 매핑(§6).
- `NSAccessibilityUsageDescription`이 프랑스어 한 문장뿐이다(`project.yml`). `docs/SPEC.md`는 일부 오래됐다(프랑스어).

이 브랜치에서 고친 것(다시 만들지 말 것): 경로 부분 일치로 사용자 hook 삭제, 동작하지 않던 Copilot 제거, Hermes의 `deny` 폴백, 한 번 실패로 끝나던 `accept()`, 연결 수에 안 잡히던 보관 fd, 연결마다 `Task`라 뒤섞이던 이벤트 순서, 서로 밀어내던 approval, provider 전환 시 사라지던 채팅 질문, 실행마다 바뀌던 `colorForProject`, 동작하지 않던 `absenceInterval`, 키만 있으면 돌던 폴러, 숨겨졌을 때 돌던 TimelineView·Timer, 죽은 코드(`greetThreshold`, `pinForFinished`, `ColumnAgentsView`, `washColors`, `scheduleHover`, `baseMode`, `cleanup()`, `activeSessionId`, `ClaudeService.search`), 오래된 `AGENTS.md`/`INTEGRATIONS.md`/사이트 문구. 그리고 이후: 전역 큐에서 메인 액터 클로저를 불러 실행 직후 나던 크래시(b52db3c), 메인 액터의 O(m·n) LCS diff(9c25283), 메인 스레드의 동기 로그 쓰기(6ebd4ab), 실행 시 Keychain 전체 읽기와 목록 밖 키의 nil(0278aa1), accept 전에 끝나 프로세스 사슬을 못 잡던 릴레이(7e3b148), 영원히 "working"으로 남던 버려진 세션(28450cb), 포인터 밖에서 열린 알림이 닫히지 않던 문제(fb61019), 2–6배 빨리 돌던 Mochi 애니메이션 dt(aca174b), 글자 수로 추정하던 질문 카드 높이(cb243dd), 뒤에 뜨던 설정 창, 빈 "+0 −0" hook diff, `\/`로 바뀌던 settings.json 경로, OpenCode 2가 거부하던 `coucou.js`, 무시되던 "Open <app>" 활성화.

### 권장 진행 순서
1. **기준선 고정**: `xcodegen` → 5개 스킴 빌드 → `bash scripts/test-all.sh`. 경고 수(0)를 기록.
2. **계약 상수화**: CloudKit 이름은 `CloudSchema`로 끝났다. 남은 것: pill ID, Keychain 키, UserDefaults 키, NotificationCenter 이름을 각각 한 파일의 상수/enum으로. 동작 변화 0, 이후 모든 단계의 안전망.
3. **순수 로직 추출 + 테스트 추가**: 큐·accept 정책·릴레이·설치기 병합·호스트 판별·세션 북·라우팅·상태 줄·시각화·자동 음악 pill·TIDAL 파서는 끝났다. 남은 것: 폴러 파서.
4. **IDE별 pill·다중 세션·알림·정지 감지·상태 줄(§12, §3)을 `coucou-replay.py`로 확인**한 뒤 AppState 분해. AppState는 이미 `@Observable`이라 쪼갠 조각도 `@Observable` + `ChangeObserver`로 잇는다.
5. **상태 원천 단일화**: FSM과 `AppState.mode/view`는 `modeWillSet` → `displayed(_:pointerInside:)`로 동기화만 된 상태. 하나로 합친다.
6. **HookServer·폴러 분해** (§4, §5의 권장 형태).
7. **뷰 분리**: IslandViewContent, SettingsView를 파일 단위로.
8. **CoucouKit 정리**: CloudKit 필드 매핑을 공유 타입으로, `MacStubs` 대신 의존성 주입, Mac 전용 타입을 CoucouKit 밖으로.
9. 각 단계마다 5개 스킴 빌드(§1)와 `test-all.sh`를 돌린다. iPhone·App Store 스킴은 `#if` 분기 때문에 Mac 빌드만으로는 깨짐을 못 잡는다. UI를 건드렸으면 §14대로 눈으로 확인한다.

---

## 10. 불변 규칙

구조와 모양은 자유롭게 바꿔도 되지만, 아래는 사용자 안전과 신뢰에 관한 것이라 유지한다.

- **Claude Code(및 모든 에이전트)를 절대 막지 않는다.** 앱이 응답하지 않으면 hook은 즉시 아무것도 출력하지 않고 exit 0.
- **사용자의 명시적 클릭 없이** 권한을 승인하거나, 질문에 답하거나, 이메일을 보내지 않는다. (macOS 알림에서도 마찬가지: 알림은 알리기만 한다.)
- **`~/.claude/settings.json`과 다른 에이전트 설정 파일을 덮어쓰지 않는다**: 날짜 붙은 백업 → 병합 → diff 표시 → 사용자 확인 후 쓰기(`ClaudeSettingsFile`).
- 비밀은 Keychain에만. 디스크·git·로그에 남기지 않는다.
- 텔레메트리 없음. 네트워크는 사용자가 설정한 서비스와 relay에만.
- 섬이 숨겨졌을 때 CPU 0%를 목표로 한다(§3). 아무 세션도 일하지 않으면 정지 감지·trim 타이머도 없다(§12). 오디오 캡처는 시각화가 화면에 있는 동안만, TIDAL 읽기는 TIDAL이 돌고 소리가 날 때만(§13).
- 시스템 오디오는 **녹음·저장하지 않는다**: 대역 레벨만 읽고 버린다. 권한(손쉬운 사용 등)을 Coucou가 먼저 요구하지 않는 기능은 그대로 둔다.
- Swift 6 + SwiftUI + AppKit, 서드파티 의존성 없음. Mochi는 `Canvas` + `TimelineView`로 코드로 그린다.
- `.xcodeproj`는 손으로 편집하지 않는다. `project.yml` → `xcodegen` → 생성물 커밋.
- 새 pill은 `PillCatalog.swift`에 선언한다(동적 `agent_*`·`ide_*` 제외). 기존 pill ID는 마이그레이션 없이 바꾸지 않는다(§7).
- 새 UI 문자열은 `Localizable.xcstrings`에 11개 언어로 함께 넣는다(§14).
- 사용자의 포커스를 빼앗지 않는다: 개발 중 확인도 앱을 앞으로 가져오거나 다른 앱을 활성화하지 않고 한다(§14).

## 11. 릴리스 (macOS GitHub 빌드)

`project.yml`의 `CFBundleShortVersionString`/`CFBundleVersion` 올리기 → `xcodegen` → 재생성된 `Info.plist` 커밋 → `CHANGELOG.md`에 `## X.Y.Z — Month D, YYYY` 섹션 → README Versions 표에 행 추가 → `scripts/release.sh <ver>`(Developer ID 서명, `coucou-notary` 키체인 프로필로 공증, 태그 푸시, `gh release create`). 공증이 중간에 끊기면 `--finish`. 업데이트 메커니즘(Sparkle 등)은 없다. App Store·iPhone은 Xcode에서 수동 아카이브하며 버전이 별도다(현재 Mac GitHub 0.2.3, App Store 1.1, iPhone 1.0).

### 서명 현황 (이 포크)
- 팀은 `6HBMRNDGYC`(개인 계정)로 바꿨다. 이 Mac에는 `Apple Development` 인증서만 있다.
- **`Debug`만 서명된다**: Apple Development 인증서, 수동 서명, 프로필 없음. iCloud·push 권한이 없어서 가능하다. 서명이 매번 같아서 손쉬운 사용·자동화·시스템 오디오 녹음·Keychain 권한이 빌드마다 초기화되지 않는다. **UI를 눈으로 확인할 때는 서명된 Debug를 쓴다**(서명 없는 빌드는 TCC 권한이 매번 새로 묻거나 거부된다).
- `DebugCloud`, `Release`, `ReleaseCloud`, `CoucouAppStore`, iPhone 타깃은 아직 서명되지 않는다. 번들 ID `fr.louisraille.*`와 iCloud 컨테이너가 원 저자 팀에 등록되어 있고, Developer ID 인증서·`Coucou Developer ID` 프로필·`coucou-notary` 키체인 프로필이 없기 때문이다.

`release.sh`는 원본 저장소(`Louis-CFM/coucou`), Developer ID 인증서, 프로비저닝 프로필을 전제로 한다. 포크에서 배포하려면 `project.yml`의 팀/번들 접두사, `release.sh`의 저장소 이름, relay URL, CloudKit 컨테이너를 모두 자기 것으로 바꿔야 하고, 그 순간 §7의 계약 대부분이 새로 시작된다.

---

## 12. IDE별 pill · pill당 여러 세션 · macOS 알림 · 정지 감지

> 순수 빌딩 블록(`HostResolver`, `SessionBook`, `HookRouting`, `AutoMainPill`, `NotificationPolicy`)은 테스트로 고정돼 있고, AppState 반영(`HookServer`, `MacNotifier`, `StallMonitor`)은 `coucou-replay.py`로 확인한다.

### 호스트 판별 (`HostResolver.resolve`)
세션이 어느 앱에서 도는지, 강한 신호부터:
1. **프로세스 트리** → `coucou_host_bundle_ids`: `ProcessAncestry`가 **`accept()` 직후** 피어(릴레이)의 pid와 부모 사슬을 잡는다(`ProcessTree.ancestors`, sysctl `KERN_PROC_PID`, 최대 32단계, launchd에서 멈춤). 릴레이가 앱의 `ok`를 기다리므로(§4) 일반 이벤트에서도 사슬이 살아 있다. 일반 앱(`.regular`)의 번들 ID를 가까운 것부터 모아 **앱이 항상 페이로드에 넣고, 클라이언트가 보낸 값은 덮어쓴다.** Coucou 자신, Finder, Dock, loginwindow는 건너뛴다. 처음 보는 IDE도 여기서 잡힌다. 사슬을 못 잡은 이벤트는 세션별 호스트 캐시(`sessionHosts`)로 채운다.
   - **`coucou_host_override`** (DEBUG 빌드만)는 이 프로세스 트리 결과를 **대체**한다: 번들 ID면 그 앱이 호스트, **빈 문자열이면 "앱 없음"**이라 2·3번(`bundle_id`/`term_program`)으로 넘어간다. 릴레이 대신 터미널에서 이벤트를 보낼 때(`coucou-replay.py`) 트리가 그 터미널을 가리키므로 필요하다. Release 빌드는 이 키를 무시한다(같은 UID 프로세스가 아무 앱을 사칭할 수 없도록). override가 있는 이벤트는 **재생으로 보고**(`isReplay`) Auto 메인 활동(`noteWorkspaceActivity`, 저장되는 `lastActiveWorkspacePill`)으로 치지 않는다.
2. **`bundle_id`**: 릴레이가 붙이는 `__CFBundleIdentifier`(에이전트 셸이 상속).
3. **환경 힌트**: `term_program`(`TERM_PROGRAM`; vscode, WarpTerminal, Apple_Terminal, iTerm.app, ghostty, kitty, alacritty, wezterm, hyper, zed), 그다음 `terminal_emulator`(`TERMINAL_EMULATOR`, 릴레이가 붙임. `JetBrains-JediTerm`이면 `com.jetbrains.ide` 폴백).

번들 ID 분류(`HostResolver.kind`): Cursor(`com.todesktop.230313mzl4w4u92`) → cursor, VS Code·Insiders·VSCodium → vscode, 알려진 터미널(Warp, Terminal, iTerm, Ghostty, kitty, Alacritty, WezTerm, Hyper, cmux) → terminal, **나머지 전부 → ide**. **Orca 같은 에이전트 워크스페이스도 IDE**로 자기 `ide_<slug>` pill을 받는다(7c37619. 예전엔 터미널 취급). 목록에 없는 터미널(Tabby, Rio…)도 IDE로 취급된다. IDE 목록이 없다는 것이 새 편집기가 그냥 동작하는 이유다.

### pill 매핑 (`HookRouting` + `HostResolver.pillId`)
| 호스트 | Claude Code | Codex |
|---|---|---|
| VS Code·Insiders·VSCodium | `integration_claude` | `integration_claude` |
| Cursor | `agent_cursor` | `agent_cursor` |
| 그 외 IDE (JetBrains, Zed, Xcode, Windsurf, Orca… 모르는 터미널 포함) | `ide_<slug>` | `ide_<slug>` |
| 알려진 터미널 | `integration_claude` | `agent_codex` |
| Codex 데스크톱 앱 | | `agent_codex` |
| Claude 데스크톱 앱 | `agent_claude-desktop` | |
| 판별 불가 | 무시 | `agent_codex` |

- `coucou_agent`가 붙은 다른 서드파티 에이전트는 계속 `agent_<name>`.
- `ide_<slug>` pill의 이름·아이콘은 `HostAppInfo`(설치된 앱에서, 없으면 `HostResolver.fallbackName`: 번들 ID 마지막 성분, 예: "Gram"). 색은 `HookRouting.defaultIDEColor`(pill ID의 안정 해시로 팔레트에서). 카드의 "Open <IDE>" 버튼은 `HostAppInfo.activate`(§3).
- 어느 pill이 approval/question 카드를 받는지는 `HookRouting.showsCard`가 정한다(§4).
- `integration_claude`의 카탈로그 이름은 **"Claude Code"**(예전 "VS Code", ID는 그대로). 섬의 pill·idle 카드는 세션의 앱 이름을 쓴다: 터미널이면 "Warp"/"iTerm"…, VS Code 계열이면 "VS Code", 모르면 "Claude Code"(`ClaudeHost.pillName(hostApp:sessionBundleId:)`). 마지막 세션이 끝나면(`removeTask`의 리셋) 다시 "Claude Code".

### Auto 메인 pill (`AutoMainPill`, `AppState.noteWorkspaceActivity`)
- Settings → Active pills → Main의 첫 항목 "Auto (last IDE you used)"(기본값). 아래에 "Auto — Orca"처럼 지금 해석된 pill을 보여 준다.
- Auto 메인 = 마지막으로 활동이 있었던 workspace pill(`integration_claude, agent_cursor, agent_codex, agent_antigravity`, 모든 `ide_…`). 아무 활동도 없었으면 `integration_claude`. 기억된 IDE가 이 Mac에 더 이상 설치돼 있지 않으면(`urlForApplication` nil) 되살리지 않는다.
- 활동으로 치는 이벤트: `UserPromptSubmit`(사용자), `PreToolUse`/`PostToolUse`/`PostToolUseFailure`·approval·question(에이전트). SessionStart/Stop/SessionEnd/Notification은 치지 않는다. 재생 이벤트(override)는 치지 않는다.
- **flip-flop 방지**: 사용자 프롬프트는 언제나 메인을 옮긴다. 에이전트 활동은 지금 메인에 바쁜 세션(working 또는 사용자 대기)이 없을 때만 옮긴다. 결정은 순수 함수 `AutoMainPill.shouldSwitch`(test-auto-main-pill).
- 메인이 바뀌면(`refreshMainPill`): 새 메인의 task를 만들고(`ide_`는 저장된 번들 ID로 `HostAppInfo` 이름·아이콘), 이전 메인은 `activeIntegrations`에 없고 세션도 없을 때만 내린다. 순서는 메인 → 자동 음악 pill(§13) → 카탈로그에 없는 pill(IDE·서드파티) → 카탈로그 순(`sortTasksByCatalog`). 데모 중에는 멈췄다가 `DemoEngine.stop`에서 따라잡는다.
- 메인인 `ide_` pill은 `removeTask`에서 보호되어 세션이 없어도 남고, idle 카드("Hooks installed", "Open <IDE>")를 보인다.

### 다중 세션 (`SessionBook`, `AppState.sessionBooks`)
- pill마다 `SessionBook` 하나: 세션 ID(`session_id`, 없으면 `<pillId>+<cwd>`)별 `AgentSession`(agent, 프로젝트, cwd, phase, 최근 단계 20개, finalLine, 시작/마지막 이벤트 시각, 턴 시작 시각 `turnStartedAt`), 최근 활동 순.
- **lead = 가장 긴급한 세션**, 같으면 가장 최근. 긴급도: waitingApproval 6 > waitingAnswer 5 > error 4 > working 3 > finished 2 > idle 1. pill의 phase는 lead의 phase.
- **AgentTask로 미러링**: pill의 이름·상태·단계는 book의 lead 세션을 비춘다(`HookServer.mirror`). 그래서 book 이전에 만든 뷰(pill, ticker, iPhone `Session` 레코드)가 그대로 동작한다. 카드 안의 세션 목록은 book을 직접 읽고(문구는 `SessionCardText`, "Codex in WebStorm"), 고르면 `bringToFront`.
- **보관·만료 (`SessionBook.expiry`/`trim`)**: 끝난 세션(finished/error/idle)은 마지막 이벤트 **10분 뒤**(`endedRetention`), **working 세션은 이벤트 없이 60분이면 버려진 것으로 보고**(`abandonedAfter`, 에이전트가 SessionEnd 없이 죽은 경우. 다음 이벤트가 오면 되살아난다) 제거, pill당 **최대 8개**. 사용자를 기다리는 세션은 절대 버리지 않는다. `SessionEnd`는 즉시 제거.
- **trim 타이머는 하나뿐** (`HookServer.trimBooks`/`scheduleTrim`, 28450cb): 무언가 바뀔 때 trim하고, 모든 book의 `nextExpiry` 중 가장 이른 시각(+1초)에 `DispatchWorkItem` 하나를 메인 큐에 건다. 만료될 수 있는 세션이 없으면 아무것도 예약하지 않는다. book이 비면 IDE pill은 함께 사라진다(메인 제외). 다른 pill은 남는다.
- approval/question 큐(§4)는 그대로 전역 FIFO이고, 대기 중인 세션은 waitingApproval/waitingAnswer phase가 된다.

### 알림 (`SessionAlert`, `SessionAlertCenter`, `NotificationPolicy`, `MacNotifier`)
- HookServer와 StallMonitor가 메인 액터에서 `SessionAlertCenter.shared.post(SessionAlert)`를 부른다. 종류: `finished, error, waitingApproval, waitingAnswer, stalled`. 내용: pillId, sessionId, 에이전트 이름, 프로젝트, 호스트 번들 ID, 한 줄 detail(최종 답, 오류, 대기 중인 명령, 질문).
- `NotificationPolicy.decide`가 띄울지 정하고 `MacNotifier`가 macOS 배너를 띄운다. **배너는 무음**이다(소리는 Mochi의 `SoundEngine`이 이미 낸다). 설정은 `NotificationsSettingsView`(Settings → Notifications).
- 표시 조건: `macNotificationsEnabled`가 켜져 있고 종류별 토글(`notifyFinished` → finished, `notifyErrors` → error, `notifyWaiting` → waitingApproval/waitingAnswer, `notifyStalled` → stalled)이 켜져 있을 때. 키가 없으면 모두 켜짐.
- **억제**: 같은 (pill, 세션, 종류)를 5초 안에 다시 보내면 중복(`NotificationLedger`), 세션의 호스트 앱이 frontmost일 때(`HostAppInfo.isFrontmost`), 섬이 지금 그 pill을 펼쳐 보여 주고 있을 때. 사용자가 이미 보고 있는 것은 알리지 않는다. 배너는 세션당 하나(새 배너가 이전 것을 대체)이고, 세션이 넘어가면 지난 배너를 지운다. pill별로 묶인다.
- 배너 클릭 = 그 앱을 앞으로 가져오고(`HostAppInfo.activate`) 섬을 그 pill로 연다(`.hookExpand`). 알림은 알리기만 한다. 알림에서 승인·답변하지 않는다(§10).

### 정지 감지 (StallMonitor)
- `stalled` = phase가 **working**인데 `stallThresholdMinutes`(Int, 기본 3분, 0이면 끔) 동안 이벤트가 없는 세션. 사용자를 기다리는 세션은 정지가 아니다.
- 타이머 하나만 예약한다: 모든 book의 `nextStallCheck(threshold:)` 중 가장 이른 시각에 한 번 깨어나 `stalled(now:threshold:)`를 보고 다음 시각을 다시 잡는다. 이벤트가 오면 다시 계산한다. **일하는 세션이 없으면 타이머가 없다**(CPU 0%).
- 정지되면 pill에 `PillBadge.stalled`(보라 `#A78BFA`, 모래시계) + `SessionAlert(.stalled)`. 이벤트가 다시 오면 배지가 풀린다. 카드의 세션 줄에는 "No activity for N min".

### 재생 도구 (`scripts/coucou-replay.py`)
실제 에이전트·IDE 없이 실행 중인 앱에 hook 이벤트를 보낸다(Python 3 표준 라이브러리만, macOS `/usr/bin/python3` 3.9 호환).
```bash
python3 scripts/coucou-replay.py --list                        # 시나리오 목록
python3 scripts/coucou-replay.py webstorm-claude               # WebStorm의 Claude Code: 읽기, Edit diff, npm test 승인, 완료
python3 scripts/coucou-replay.py zed-codex --speed 2           # Zed의 Codex
python3 scripts/coucou-replay.py two-sessions-one-ide          # PyCharm 한 pill에 세션 둘, 하나는 질문으로 끝남
python3 scripts/coucou-replay.py stalled                       # 정지 감지 (--speed로 짧아지지 않음, 3분 기다리거나 설정을 낮춤)
python3 scripts/coucou-replay.py gram-unknown-ide              # 처음 보는 IDE(app.gram.Gram)
python3 scripts/coucou-replay.py burst -q                      # 부하: 세션 3개·호스트 3개, 합계 ~10 events/s, 60초, 달성률 출력
python3 scripts/coucou-replay.py webstorm-claude --host dev.zed.Zed --dry-run   # 보낼 페이로드만 출력
```
- 소켓 기본값 `~/Library/Application Support/NotchBuddy/nb.sock`, `--socket`으로 변경. 소켓이 없으면 오류로 끝나고 소켓을 만들거나 지우지 않는다.
- 릴레이와 같은 프로토콜: 이벤트당 연결 하나, JSON 한 줄. 일반 이벤트는 0.3초 타임아웃으로 보내고 닫는다. `PermissionRequest`와 `coucou_kind: "ask_user_question"`은 연결을 열어 두고 응답 줄을 기다려(118초/125초) 결정·답과 릴레이가 에이전트에게 출력했을 JSON을 보여 준다. 노치에서 직접 Allow/Deny를 누르며 확인한다(재생 도구도 사용자 클릭 없이는 승인하지 않는다).
- `--host <bundle id>`(또는 시나리오의 `_meta.host`)가 `coucou_host_override`를, `--agent codex`가 `coucou_agent`를 붙인다. override는 **DEBUG 빌드만** 따른다. Release 빌드에서는 프로세스 트리(=실행한 터미널)로 판별된다. `--host ""`는 빈 override("앱 없음")를 보내 시나리오의 `bundle_id`/`term_program` 폴백 경로를 시험하고, `--host none`은 override를 아예 보내지 않는다.
- 시나리오는 `tests/replay/*.jsonl`(`burst, gram-unknown-ide, stalled, two-sessions-one-ide, webstorm-claude, zed-codex`): 한 줄 = hook 페이로드 + 제어 키(`_delay`, `_delay_fixed`, `_repeat`, `_cycle`, `_async`, `_if_allowed`, `_comment`, 보내기 전에 제거) + 변수(`${ROOT}`, `${RUN}`, `${WORKER}`, `${I}`, `${C}`, `${HOST}`, `${HOME}`). 첫 줄 `{"_meta": {...}}`에 설명·기본 호스트·에이전트·릴레이가 붙일 필드(`bundle_id`, `term_program`, `terminal_emulator`)·`parallel`. 형식 전체는 스크립트 머리 주석.
- `--speed`, `--loop`, `--parallel N`, `-q`. 스케줄은 절대 시각 기준이라 전송 비용이 rate를 늦추지 않는다(`burst`로 최적화 전후 CPU·메인 스레드를 잴 때 같은 부하, `measure-cpu.sh`가 이것을 쓴다).
- 테스트: `scripts/test-replay.sh`(§8).

---

## 13. 음악 · 사운드 시각화

### 지금 재생 중 (`NowPlaying.swift`, GitHub 빌드의 피드)
- **계약**: `NowPlayingSource`(`music, spotify, tidal`), `NowPlayingInfo`(제목, 아티스트, 재생 여부, 선택적 앨범 아트 URL, `updatedAt`), `NowPlayingControlling`(playPause/next/previous). `NowPlayingCenter.shared`(메인 액터 `@Observable`)가 소스별 최신 상태(`bySource`)와 `current`(재생 중이면서 가장 최근에 갱신된 소스)를 들고, 피드가 컨트롤러로 등록한다.
- 피드는 `NowPlayingFeed.publish`로만 쓴다: 같은 곡·같은 재생 상태면 처음 `updatedAt`을 유지하고(앨범 아트가 늦게 와도 현재 소스가 바뀌지 않게) 바뀐 게 없으면 쓰지 않는다.
- **Apple Music·Spotify** (`MusicController`, `SpotifyController`): OAuth/MediaRemote 없이 distributed notification(`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`) + AppleScript 제어. 피드는 "Show music automatically"(`autoMusicEnabled`)가 켜져 있거나 pill을 선언했을 때만 듣는다. 유휴 중 상태를 읽으려고 AppleScript를 돌리지 않는다(Spotify의 추가 읽기는 선언된 pill이거나 자동화 권한이 이미 있을 때만).
- **TIDAL** (`TidalController`, `TidalNowPlaying`, fd8120c): TIDAL 데스크톱(Electron)은 AppleScript도 알림도 없어서 **손쉬운 사용(AX)**으로 플레이어 바(`#footerPlayer`: 제목 링크, 아티스트 행, 이전/재생·일시정지/다음 버튼)와 창 제목("Title - Artist")을 읽는다. AX 호출은 `TidalAXReader`의 큐에서 0.25초 메시징 타임아웃으로(멈춘 앱에 막히지 않게), 결과는 메인 액터에서 발행. 비용: TIDAL이 안 돌면 0(NSWorkspace 실행/종료 알림), 권한이 없으면 0(Coucou는 묻지 않는다), 돌면 **Mac이 소리를 낼 때만 2초마다** + 소리가 멈출 때 한 번 + 컨트롤 뒤 한 번. 컨트롤은 TIDAL 버튼을 `AXPress`(순서로 고른다: 언어와 무관), 실패하면 시스템 미디어 키 이벤트. 재생·일시정지 라벨은 TIDAL이 현지화하므로 모르는 라벨이면 `isAudible`로 판단. 파싱은 순수(`test-tidal-now-playing`).

### 자동 음악 pill (`AutoMusicPill`, `MusicPillDriver`, fba8aa8)
- 소스가 재생되면 그 pill(`integration_music`, `integration_spotify`, `integration_tidal`)이 **선언하지 않아도** 메인 pill 바로 뒤에 나타나고, 활성 pill 4개 한도에 세지 않는다. 재생이 멈추거나 앱이 종료되면 **30초**(`AutoMusicPill.linger`) 뒤 떠난다. 다른 소스가 재생되면 즉시 교체. 사용자가 선언한 pill, 메인, 세션이 있는 pill은 지우지 않는다(`transition(kept:)`).
- 결정은 순수 `AutoMusicPill.next`/`dropDate`/`transition`, 적용은 `MusicPillDriver`(`ChangeObserver`로 `NowPlayingCenter`를 따라가고, 잔류 중일 때만 타이머 하나). AppState 쪽은 `setAutoMusicPill(_:)`/`autoMusicPillId`. TIDAL pill은 `NowPlayingCenter`의 곡 이름을 이름으로 쓰고 작은 카드(`NowPlayingViews`)를 보인다.
- Mochi는 `NowPlayingCenter.current`가 재생 중이면(어느 소스든) 허용된 상태에서 춤춘다: compact 섬, 데스크톱, 재생 중인 소스의 pill이 펼쳐졌을 때.
- 설정: Settings → General → Behavior → "Show music automatically"(`autoMusicEnabled`, 기본 켬, App Store 빌드엔 없음).

### 소리 감지와 스펙트럼 (`SystemAudioCapture`, 5d930a2 · 644c8cd · 9ae3c3f · 339a0f5)
- **`AudioSpectrum.isAudible`**(메인 액터 `@Observable`)은 Core Audio **프로퍼티 리스너만**으로 정한다(캡처·타이머 없음, 켜 둬도 무료): 기본 출력 장치가 돌고 있고 Coucou가 아닌 프로세스가 출력 중. 소리는 **2초 이어져야** 들리는 것으로 친다(알림음·클릭은 제외), 무음은 즉시. 함께 `audibleBundleIds`(소리를 내는 앱들)를 발행한다.
- **소유 앱 해석**: 소리를 내는 프로세스가 헬퍼일 때(TIDAL의 "TIDALPlayer" `com.tidal.desktop.player`, 브라우저·Electron 헬퍼) 사용자가 아는 앱으로 바꾼다: 그 프로세스가 일반 앱이면 그것, 아니면 `ProcessAncestry`로 위쪽의 가장 가까운 일반 앱, 아니면 번들 ID가 헬퍼의 접두사인 실행 중 일반 앱(가장 긴 것). 그래서 시각화가 "TIDAL"과 TIDAL pill·색을 보인다.
- **`AudioSpectrum.bands`**(12개, 0…1): `AudioSpectrum.isWanted`와 `visualizerEnabled`가 **둘 다** 켜져 있을 때만 시스템 출력의 **비공개 프로세스 탭**(Coucou 제외)을 비공개 aggregate 장치에 만든다. IOProc(HAL 실시간 스레드)는 잠금 없는 `SampleRing`(단일 생산자·소비자, 원자적 카운터, 할당 없음)에 모노로 섞어 쓰고, utility 큐의 30Hz 타이머가 `SpectrumAnalyzer`(2048점 Hann 창 + vDSP 실수 FFT → 60Hz–12kHz 로그 간격 12대역 → dB → 0…1 → attack 0.6 / release 0.15)를 돌려 막대가 0.01 넘게 움직였을 때만 메인 액터에 발행한다. 둘 중 하나가 꺼지면 즉시 해체.
- **레벨 범위 −50…−15 dB** (`AudioSpectrumMath.floorDB/ceilingDB`): 실제 음악(TIDAL, `debugLogSpectrum`으로 측정)에서 대역이 대략 −60…−17 dB에 있어서, 예전 −60…−6 dB는 모든 막대를 0.3–0.7에 몰아 똑같아 보였다(339a0f5). 범위를 바꾸면 `test-audio-spectrum`과 실제 음악으로 확인한다.
- 탭은 "시스템 오디오 녹음" 권한(`NSAudioCaptureUsageDescription`)이 필요하다. 거부·실패하면 막대는 0(정적 idle 패턴), `isAudible`은 그대로 동작. 실패는 그 "wanted" 구간에 한 번만 시도한다. **App Store 빌드엔 탭이 없다**(§9).
- 모든 Core Audio·Dispatch·NotificationCenter 클로저는 nonisolated 코드에서 만든다(§3 트랩 규칙). `SystemAudioCapture`의 상태는 직렬 utility 큐에 갇혀 있다.

### compact 시각화 (`CompactVisualizer`, `CompactStatusModel`, 76556a0)
- 슬롯 우선순위(`CompactVisualizer.slot`): ① 어느 pill이든 세션이 working이거나 사용자를 기다리면 → 상태 줄, ② 시각화가 켜져 있고 음악이 있으면 → 시각화, ③ 아니면 남은 상태 줄("Done", "Error"). 남아 있는 Done/Error는 음악에 자리를 내준다. 전환은 교차 페이드.
- 제목 줄(`musicLine`): 피드가 곡을 알면 "♪ 제목 · 아티스트"(제목 32자·아티스트 24자로 자름, 제목이 없으면 소스 이름 "TIDAL"), 피드가 없어도 2초 이상 소리를 낸 앱이 있으면 **그 앱 이름**(동영상, 통화…). 클릭 = 음악 pill 열기, pill이 없는 앱이면 그 앱을 앞으로(`HostAppInfo.activate`).
- 막대: 2pt × 12, 간격 2pt, 높이 2–14pt, 음악 pill 색. **`AudioSpectrum.isWanted`는 `CompactStatusModel` 한 곳에서만** 정한다(compact 섬이 시각화를 보일 때 = `wantsCapture`). 레벨은 최대 30fps로 넘기고, 모든 대역이 0.01 이하면 움직이지 않는 idle 스카이라인을 그린다(아무것도 째깍거리지 않음).
- 설정: Settings → General → Display → "Sound visualizer in the notch"(`visualizerEnabled`, 기본 켬. 끄면 캡처도 없다).

---

## 14. 개발 도구 · UI 변경 확인

### 도구
| 도구 | 용도 |
|---|---|
| `scripts/coucou-replay.py` | 실행 중인 앱에 hook 이벤트 재생 (§12) |
| `scripts/measure-cpu.sh [Coucou.app]` | **앱을 종료하고 다시 띄운 뒤**(`open`) 80초 안정화 → 유휴 CPU·RSS → `burst` 재생 중 → 그 뒤. 최적화 빌드로(`SWIFT_OPTIMIZATION_LEVEL=-O`, 기본 경로 `/tmp/coucou-perf`). 포인터를 노치에서 떨어뜨려 둔다. 사용자가 쓰는 Coucou를 죽이므로 묻고 실행한다. 기준: 숨김 0.1%, compact 10.5%, burst 12.3%(fb61019) |
| `scripts/bench-mochi.sh` | BotEngine 업데이트 + 그리기를 오프스크린 2x 비트맵으로 N프레임(compact/expanded/mini, 상태별). 가상 시간·스크립트된 랜덤이라 `--png DIR` 덤프를 `--compare A B`로 픽셀 비교(그리기 최적화 전후 동일성 확인). `MOCHI_SRC`로 다른 커밋의 CoucouKit 비교 |
| `scripts/bench-hook-socket.sh` | 예전 스레드-per-연결 서버(`scripts/HookSocketBench.swift`) 대 `HookSocketServer`, 임시 소켓 (~1분) |
| `scripts/bench-diff.sh` | 예전 LCS(`scripts/BenchDiff.swift`) 대 Myers, 1k–20k줄 |
| `scripts/bench-audio-analysis.sh` | 30Hz 분석 프레임·IO 버퍼 쓰기 µs와 CPU 비율 (`scripts/bench/BenchAudioAnalysis.swift`). 탭·HAL 비용은 `measure-cpu.sh`로 |
| `scripts/render-outfits.sh` | 의상 렌더 시트 `/tmp/coucou-outfits.png` |
| `defaults write fr.louisraille.NotchBuddy debugFakeMusic spotify` (`music`, `tidal`, `tidal-untitled`, `idle`; `defaults delete`로 끔) | **DEBUG 빌드만.** 가짜 곡과 스펙트럼으로 시각화 미리보기(`VisualizerDebugFeed`). 메뉴 막대 아이콘 → "Debug: fake music"에서도 고른다. 가짜 막대는 `isWanted`일 때만 움직인다 |
| `defaults write fr.louisraille.NotchBuddy debugLogSpectrum -bool YES` | **DEBUG 빌드만, 기본 꺼짐.** 초당 두 번 원시 대역 dB와 발행 레벨을 `/tmp/coucou-spectrum.log`에 덧붙인다(레벨 범위 조정용) |
| `coucou_host_override` / `--host` | DEBUG 빌드만. 재생 이벤트의 호스트 앱 지정 (§12) |

### UI 변경 확인 방법
UI(섬, 카드, 설정, Mochi)를 바꿨다면 빌드·테스트 통과만으로 끝내지 말고 눈으로 확인한다. 기존 화면의 모양은 요청 없이 바꾸지 않는다(루트 규칙).
1. **서명된 Debug로 빌드**한다(`-scheme NotchBuddy -configuration Debug`, `CODE_SIGNING_ALLOWED=NO` 없이). 서명이 매번 같아서 손쉬운 사용·시스템 오디오 녹음·알림 권한이 유지되고, DEBUG라서 `coucou_host_override`·`debugFakeMusic`이 동작한다(§11).
2. 이미 떠 있는 Coucou가 있으면 그것을 쓸지, 새 빌드로 바꿔도 되는지 사용자에게 먼저 묻는다. 앱을 띄울 때도 **앞으로 가져오지 않는다**(`open -g`). 섬은 비활성 패널이라 포커스를 가져가지 않는다.
3. **재생 시나리오로 상태를 만든다**: `python3 scripts/coucou-replay.py webstorm-claude`(IDE pill, diff, 승인 카드), `two-sessions-one-ide`(세션 목록, 질문), `zed-codex`, `gram-unknown-ide`, `stalled`. 승인·질문은 사람이 노치에서 눌러야 끝난다(재생 도구도 자동 승인하지 않는다). 시각화는 `debugFakeMusic`으로, 상태 줄은 재생 중의 compact 섬으로 본다.
4. **섬 영역만 스크린숏**한다: 섬은 섬이 놓인 화면(기본: 노치 화면)의 **위쪽 가운데**, 720×560pt 패널 안에 있다. 예: `screencapture -x -R <x>,0,720,200 out.png`(x = 화면 폭/2 − 360. compact 상태 줄은 오른쪽 귀가 최대 300pt까지 넓어지니 폭을 넉넉히). `-x`로 소리 없이, 창 선택(`-w`)이나 대화형 캡처는 쓰지 않는다.
5. **사용자의 포커스를 빼앗지 않는다**: 확인 중에 다른 앱을 활성화하거나(`osascript activate`, `open`으로 앱을 앞에 띄우기), 키 입력·클릭을 합성하지 않는다. 펼친 상태가 필요하면 재생 이벤트(알림이 섬을 연다)나 사람의 클릭으로 연다.
6. 새 문자열은 `Localizable.xcstrings`에 넣는다. Xcode 문자열 추출 형식이며 11개 언어(en, ar, bn, es, fr, hi, id, ko, pt-BR, ru, zh-Hans) 모두 번역한다. 번역할 것이 없는 문자열(숫자, 기호, 브랜드·언어 이름, 경로)은 `"shouldTranslate": false`. 빠진 키는 `SWIFT_EMIT_LOC_STRINGS=YES`로 빌드해 생긴 `*.stringsdata`와 카탈로그를 비교해 찾는다. 수정 후 `python3 -c "import json; json.load(open('NotchBuddy/Resources/Localizable.xcstrings'))"`로 JSON을 검증한다.
7. 끝나면 §1의 5개 스킴 빌드와 `test-all.sh`.
