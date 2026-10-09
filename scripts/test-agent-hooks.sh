#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agent-hooks.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
    NotchBuddy/Sources/App/ClaudeSettingsFile.swift \
    NotchBuddy/Sources/App/ClaudeHookDetection.swift \
    NotchBuddy/Sources/App/AgentHookConfig.swift \
    tests/AgentHookConfigTests.swift -o "$TEST_DIR/agent-hooks-tests"
"$TEST_DIR/agent-hooks-tests"
