#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-history.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
    NotchBuddy/Sources/App/ClaudeResponseText.swift \
    tests/ChatHistoryTests.swift -o "$TEST_DIR/chat-history-tests"
"$TEST_DIR/chat-history-tests"
