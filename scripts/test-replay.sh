#!/usr/bin/env bash
# scripts/coucou-replay.py against a throwaway fake socket server (tests/replay_check.py):
# payloads intact, control keys stripped, host/agent keys added, held requests wait for the
# reply, --dry-run sends nothing, shipped scenarios parse. Never touches Coucou's real socket.
set -euo pipefail
cd "$(dirname "$0")/.."
# /usr/bin/python3 without the Command Line Tools opens an install dialog: check first.
if xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
    /usr/bin/python3 -I tests/replay_check.py
else
    echo "Replay tool: skipped — no python3"
fi
