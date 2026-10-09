#!/usr/bin/env bash
# The relay scripts and agent plugins Coucou writes: generated text checks, then the
# generated Python run against an empty HOME (no Coucou socket) when python3 is usable.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hook-relay.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 NotchBuddy/Sources/App/HookRelayScripts.swift \
    tests/HookRelayScriptsTests.swift -o "$TEST_DIR/hook-relay-tests"
"$TEST_DIR/hook-relay-tests" "$TEST_DIR/gen"
# /usr/bin/python3 without the Command Line Tools opens an install dialog: check first.
if xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
    /usr/bin/python3 -I tests/hook_relay_check.py "$TEST_DIR/gen"
else
    echo "Hook relay (Python): skipped — no python3"
fi
