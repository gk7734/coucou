# Contributing to Coucou

Thanks for wanting to help Mochi grow up! 🫶

## Getting started

```bash
brew install xcodegen
cd NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
```

Never edit `NotchBuddy.xcodeproj` by hand: change `project.yml` and run `xcodegen`.

Check resting island dimensions on screens with and without a notch:

```bash
bash scripts/test-screen-geometry.sh
bash scripts/test-display-choice.sh
```

Check auto-close timing and live setting changes:

```bash
bash scripts/test-auto-close.sh
```

Run every test before you open a pull request (CI runs the same thing). Each `scripts/test-*.sh` compiles one or two source files with `swiftc` and runs them, so the whole set takes about a minute and needs no Xcode project:

```bash
bash scripts/test-all.sh
```

A new `scripts/test-<name>.sh` is picked up by `test-all.sh` and CI on its own.

### Replay agent sessions without an agent

`scripts/coucou-replay.py` sends scripted hook events to a running Coucou, so you can reproduce a Claude Code or Codex session in any IDE without running either (Python 3, nothing to install):

```bash
python3 scripts/coucou-replay.py --list               # the scenarios in tests/replay/
python3 scripts/coucou-replay.py webstorm-claude      # Claude Code in WebStorm, with an Allow / Deny card
python3 scripts/coucou-replay.py two-sessions-one-ide # two sessions in one PyCharm pill
python3 scripts/coucou-replay.py burst -q             # ~10 events/s for 60 s, to measure CPU before and after a change
python3 scripts/coucou-replay.py zed-codex --dry-run  # print the payloads, send nothing
```

Approval and question events wait for your click in the notch and print the answer. The IDE a session is attributed to (`--host <bundle id>`) is honoured by Debug builds only; a Release build attributes it to the terminal you run the script from. The scenario format is described at the top of the script; add a `.jsonl` file to `tests/replay/` to reproduce a bug.

## Good first contributions

- A new service integration (a poller + an entry in `PillCatalog.swift` in the `.service` category + a detail card). Look at `StripePoller.swift` for a compact example.
- A new agent: any agent already gets its own automatic pill by sending `coucou_agent` in its hook payload (see `docs/AGENTS.md`). Add an entry in `PillCatalog.swift` in the `.agent` or `.workspace` category only if you want it to be declarable in Settings → Active pills.
- A new emote or sound for Mochi.
- Bug fixes — please describe how to reproduce.

## Rules of the house

- Swift 6, SwiftUI + AppKit, **no third-party dependencies** unless there's really no other way.
- Secrets go in the Keychain, never on disk or in git.
- No telemetry, no network calls except to services the user configured.
- Never block Claude Code: if the app doesn't answer, the hook must exit right away.
- Never write `~/.claude/settings.json` without a backup and the user's confirmation.
- Keep it light: 0 % CPU when the island is hidden.

## Pull requests

- One topic per PR, with a short GIF or screenshot for anything visual.
- Build must pass with no new warnings.
