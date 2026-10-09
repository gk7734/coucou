# Coucou — third-party agent integration

Any tool that can write to a Unix domain socket can send events to Coucou and have its own pill next to Claude Code.

## The `coucou_agent` field

Add the optional field `coucou_agent` to any hook JSON payload. Coucou will create a pill labelled with the agent name and route all events to it.

**Validation:** the name must match `^[a-z0-9-]{1,24}$` (lowercase letters, digits and hyphens, 1–24 characters). An absent or invalid name routes the event to the Claude Code pill instead.

## Hook command (macOS)

Configure your tool to call the Coucou relay with `--agent <your-name>` after the hook executable:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/path/to/nb-hook --agent my-tool" }
    ]
  }
}
```

The shell wrapper passes `"$@"` to the Python relay, which extracts the agent name and injects it into the payload before forwarding to Coucou.

## Payload format

The relay adds `coucou_agent` to the JSON it forwards. You can also add it yourself if you talk to the socket directly:

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "my-session-1",
  "coucou_agent": "my-tool",
  "prompt": "Running task…"
}
```

Send newline-terminated JSON to the socket:
- **macOS (GitHub build):** `~/Library/Application Support/NotchBuddy/nb.sock`
- **macOS (App Store build):** `~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock`

## Supported events

All standard Claude Code hook events are supported. `PermissionRequest` gets an Allow / Deny
card in the notch for these sources only:

| Source | Pill | Build |
|---|---|---|
| Claude Code in Cursor (Cursor's bundle ID) | `agent_cursor` | every build |
| Claude Code in VS Code | `integration_claude` | every build |
| Claude Code in a known terminal (Terminal, iTerm, Warp…) | `integration_claude` | every build, only when terminal cards are turned on in Settings |
| Codex (`--agent codex`) | `agent_codex` | GitHub build |
| GitHub Copilot CLI (`--agent copilot`) | `agent_copilot` | GitHub build |
| Muse Code (`--agent muse`) | `agent_muse` | GitHub build |
| Hermes (`--agent hermes`) | `agent_hermes` | GitHub build, only when its Approvals toggle is on and the plugin reports an approval transport (see Hermes below) |

A `PermissionRequest` from any other agent (any other `coucou_agent`), or from a source
above whose condition isn't met, is answered immediately with `ask`: the relay writes
nothing (Copilot gets `{"permissionDecision":"ask"}`) and the agent asks again in its own
terminal. The same happens when a card is left unanswered (115 s, 110 s for Copilot and
Muse) or replaced by a newer request.

The pill lifecycle:

| Event | Effect |
|---|---|
| `SessionStart` | Creates the pill (if absent), sets state to idle |
| `UserPromptSubmit` | State → thinking; prompt shown in ticker |
| `PreToolUse` | State → working; tool label shown in ticker |
| `PostToolUse` / `PostToolUseFailure` | State → working |
| `Notification` | Rate-limit or question state if applicable |
| `Stop` | State → finished for 5 s; active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `StopFailure` | State → error |
| `SessionEnd` | Active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `SubagentStart` / `SubagentStop` | Step added to ticker |

## Declared pills

A **declared pill** is a catalog entry (`PillCatalog.swift`) that has been enabled in **Settings → Active pills**. When a session ends for a declared pill, the pill stays visible and resets to idle instead of disappearing.

A catalog pill that is not checked in Settings behaves like any other agent: it gets an automatic pill when a session starts, and that pill is removed when the session ends.

The GitHub build exposes Gemini CLI (`agent_gemini`), Antigravity (`agent_antigravity`),
GitHub Copilot CLI (`agent_copilot`), Muse Code (`agent_muse`), OpenCode (`agent_opencode`),
Amp (`agent_amp`) and Hermes (`agent_hermes`) in Settings → Active pills. Cursor (`agent_cursor`) and Codex
(`agent_codex`, GitHub build only) are there too, and their pills can be set as the main pill.
Claude Code sessions running in Cursor (recognised by Cursor's bundle ID) go to the Cursor pill;
sessions in VS Code go to the Claude Code pill. Codex sessions go to the Codex pill once its hooks
are installed (see Codex below).

Claude Desktop (`agent_claude-desktop`, every build) is there as well. Claude Code sessions started from the Claude desktop app's Code tab carry `CLAUDE_CODE_ENTRYPOINT=claude-desktop`; the relay tags them `coucou_agent: claude-desktop` on its own (an explicit `--agent` still wins), so nothing extra is installed. Declare the pill to keep it after the session ends; the ↗ button opens the Claude app.

## IDE detection

> This describes the per-IDE pills that are being integrated on this branch.

Coucou works out which app a Claude Code or Codex session runs in, and gives every IDE its own
pill. There is no list of IDEs to register with: **any app is detected automatically**, including
ones Coucou has never heard of. Nothing extra goes in your hook payload.

Signals, strongest first:

1. **The process tree.** As soon as the relay connects, Coucou walks up from it to the nearest
   regular app (skipping Coucou itself, Finder, the Dock…) and adds the bundle IDs it found to the
   payload as `coucou_host_bundle_ids`, nearest first. Coucou always sets this key and overwrites
   any value a client sends.
2. **`bundle_id`**, which the relay copies from `__CFBundleIdentifier` (inherited by the agent's
   shell from the app it was started in).
3. **`term_program`** (`TERM_PROGRAM`) and **`terminal_emulator`** (`TERMINAL_EMULATOR`), both added
   by the relay. JetBrains terminals set `TERMINAL_EMULATOR=JetBrains-JediTerm`, which is how a
   JetBrains IDE is still recognised when nothing else identifies it.

Where the session goes:

| Host | Claude Code | Codex |
|---|---|---|
| VS Code (and Insiders, VSCodium) | `integration_claude` | `integration_claude` |
| Cursor | `agent_cursor` | `agent_cursor` |
| Any other app: JetBrains IDEs, Zed, Xcode, Windsurf… | `ide_<slug>` | `ide_<slug>` |
| A known terminal (Terminal, iTerm, Warp, Ghostty, kitty, Alacritty, WezTerm, Hyper…) | `integration_claude` | `agent_codex` |
| The Codex desktop app | | `agent_codex` |
| The Claude desktop app | `agent_claude-desktop` | |
| No app found | ignored | `agent_codex` |

A terminal Coucou doesn't know (Tabby, Rio…) counts as any other app: it gets its own
`ide_<slug>` pill.

`<slug>` is the bundle ID lowercased, with every run of characters other than `a-z0-9` replaced by
one `-`: WebStorm (`com.jetbrains.WebStorm`) gets `ide_com-jetbrains-webstorm`. The pill shows the
app's own name and icon. Several sessions in the same app share its pill; the pill follows the
most urgent one (waiting for approval, then waiting for an answer, then an error, then working).

Third-party agents tagged with `coucou_agent` keep their own `agent_<name>` pill.

### Forcing the host while testing

When you send events yourself (a script, `nc -U`, `scripts/coucou-replay.py`), the process tree
leads to your terminal, so the session lands on the terminal's pill. Add
`coucou_host_override` with the bundle ID of the app you want to simulate:

```json
{
  "hook_event_name": "SessionStart",
  "session_id": "test-1",
  "cwd": "/tmp/shop-front",
  "coucou_host_override": "com.jetbrains.WebStorm"
}
```

The override replaces what the process tree found. An **empty string** means "no app": Coucou
then falls back to `bundle_id`, `term_program` and `terminal_emulator`, which lets you test that
path from a terminal too.

`coucou_host_override` is honoured by **DEBUG builds only** (built from Xcode or with
`-configuration Debug`). Release builds ignore it, so no local process can pass itself off as
another app. The replay tool adds it for you: `python3 scripts/coucou-replay.py webstorm-claude`
(see `--list`, `--host <bundle id>`, `--host ""` for the empty override, and the scenarios in
`tests/replay/`).

### `terminal_emulator`

The relay now sends `terminal_emulator` (the agent's `TERMINAL_EMULATOR`) next to
`term_program` and `bundle_id`. If your tool talks to the socket directly and runs inside a
terminal that sets it, forward it the same way.

## Real-world examples

### Codex (macOS, GitHub build)

Coucou supports Codex out of the box via **Settings → Codex → Install hooks**.
The installer writes to `~/.codex/hooks.json` (timeouts in seconds) and uses `--agent codex`.
Codex uses the same event names and the same `PermissionRequest` answer format as Claude Code,
so Coucou shows a real Allow / Deny card for Codex approval requests (no "always allow" rule is
written for Codex), and answers its questions from the notch too.

| Codex event | Canonical event |
|---|---|
| `SessionStart` | `SessionStart` |
| `UserPromptSubmit` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PermissionRequest` | `PermissionRequest` |
| `PostToolUse` | `PostToolUse` |
| `Stop` | `Stop` |
| `SubagentStart` / `SubagentStop` | `SubagentStart` / `SubagentStop` |
| `Interrupt` | `Interrupt` |
| `SessionEnd` | `SessionEnd` |

### Gemini CLI (macOS)

Coucou supports Gemini CLI out of the box via **Settings → Gemini CLI → Install hooks**.
The installer writes to `~/.gemini/settings.json` and uses `--agent gemini` so
Gemini sessions get their own pill. The relay translates Gemini event names to canonical
Coucou events automatically.

| Gemini CLI event | Canonical event |
|---|---|
| `BeforeTool` | `PreToolUse` |
| `AfterTool` | `PostToolUse` |
| `BeforeAgent` | `UserPromptSubmit` |
| `AfterAgent` | `Stop` |

`AfterModel` is not installed — it fires on every response chunk and would flood the island.

### Antigravity — `agy` (macOS)

Coucou supports Antigravity out of the box via **Settings → Antigravity → Install hooks**.
The installer writes to `~/.gemini/config/hooks.json` (timeouts in seconds) and uses
`--agent antigravity`. The relay translates `toolCall.name` / `conversationId` to the
island's `tool_name` / `session_id`.

| Antigravity event | Canonical event |
|---|---|
| `PreInvocation` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PostToolUse` | `PostToolUse` |
| `PostInvocation` | `PostToolUse` |
| `Stop` | `Stop` |

### GitHub Copilot CLI (macOS)

Coucou supports Copilot CLI out of the box via **Settings → GitHub Copilot CLI Hooks → Install hooks**.
The installer writes to `~/.copilot/hooks/coucou.json` and uses `--agent copilot`.
Copilot CLI uses camelCase event names and `{"bash":"…","timeoutSec":N}` entries.
Copilot CLI is fail-closed on `permissionRequest`: the relay always outputs valid JSON
and returns `{"permissionDecision":"ask"}` on timeout so Copilot re-prompts in the terminal.
Coucou shows a real Allow / Deny card for Copilot approval requests.

| Copilot CLI event | Canonical event |
|---|---|
| `sessionStart` | `SessionStart` |
| `userPromptSubmitted` | `UserPromptSubmit` |
| `preToolUse` | `PreToolUse` |
| `permissionRequest` | `PermissionRequest` |
| `postToolUse` | `PostToolUse` |
| `agentStop` | `Stop` |
| `sessionEnd` | `SessionEnd` |
| `notification` | `Notification` |

### Muse Code (macOS)

Coucou supports Muse Code out of the box via **Settings → Muse Code Hooks → Install hooks**.
The installer merges into `~/.config/muse/settings.json` and uses `--agent muse`.
Muse uses PascalCase event names. Coucou shows a real Allow / Deny card for Muse approval requests.

| Muse Code event | Canonical event |
|---|---|
| `SessionStart` | `SessionStart` |
| `UserPromptSubmit` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PermissionRequest` | `PermissionRequest` |
| `PostToolUse` | `PostToolUse` |
| `Stop` | `Stop` |
| `SessionEnd` | `SessionEnd` |

### OpenCode (macOS)

Coucou supports OpenCode via **Settings → OpenCode Plugin → Install plugin**.
The installer writes a JS plugin to `~/.config/opencode/plugins/coucou.js`.
The plugin maps OpenCode event types to canonical Coucou names and forwards them fire-and-forget; OpenCode is never blocked.

| OpenCode event | Canonical event |
|---|---|
| `session.created` | `SessionStart` |
| `session.idle` | `Stop` |
| `session.error` | `StopFailure` |
| `session.deleted` | `SessionEnd` |
| `tool.execute.before` | `PreToolUse` |
| `tool.execute.after` | `PostToolUse` |
| `permission.asked` | `PermissionRequest` |

### Amp (macOS)

Coucou supports Amp via **Settings → Amp Plugin → Install plugin**.
The installer writes a TypeScript plugin to `~/.config/amp/plugins/coucou.ts`.
The `tool.call` handler returns `{ action: 'allow' }` so Amp always proceeds; all events are forwarded display-only.

| Amp event | Canonical event |
|---|---|
| `session.start` | `SessionStart` |
| `agent.start` | `UserPromptSubmit` |
| `tool.call` | `PreToolUse` |
| `tool.result` | `PostToolUse` |
| `agent.end` | `Stop` |

### Hermes Agent (macOS)

Coucou supports Hermes via **Settings → Agents → Hermes → Install plugin**.
The installer writes a Python plugin to `~/.hermes/plugins/coucou/` and enables it in
`~/.hermes/config.yaml`. The plugin uses `on_session_start` (sends the platform when running
via the gateway), `post_llm_call` (sends the final response), and a `pre_approval_request`
observer hook that fires a `⏳ Approval pending in Hermes` step in the notch.
Approving from the notch requires `register_approval_transport`, which is not yet available
in Hermes 0.15.x; the Approvals toggle activates automatically once Hermes exposes it.
Every event is fire-and-forget: if the app is closed or unreachable, nothing is sent and Hermes carries on, handling approvals itself.

| Hermes event | Canonical event |
|---|---|
| `on_session_start` | `SessionStart` |
| `post_llm_call` | `Stop` |
| `pre_approval_request` | `PreToolUse` (observer only, shows "⏳ Approval pending in Hermes") |

### Any other tool

Follow the generic pattern: call `nb-hook --agent <your-name> <EventName>` and let the relay forward the event.

## Quick test (macOS)

With Coucou running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","coucou_agent":"demo"}' \
  | /bin/sh ~/Library/Application\ Support/NotchBuddy/nb-hook --agent demo
```

A "demo" pill should appear in the island.
