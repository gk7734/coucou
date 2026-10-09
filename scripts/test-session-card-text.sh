#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-session-card-text.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete NotchBuddy/Sources/App/SessionCardText.swift \
    NotchBuddy/Sources/App/SessionBook.swift NotchBuddy/Sources/App/HostResolver.swift \
    tests/SessionCardTextTests.swift -o "$TEST_DIR/session-card-text-tests"
"$TEST_DIR/session-card-text-tests"
