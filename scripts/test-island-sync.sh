#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-island-sync.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IslandStateMachine.swift \
    tests/IslandStateSyncTests.swift -o "$TEST_DIR/island-sync-tests"
"$TEST_DIR/island-sync-tests"
