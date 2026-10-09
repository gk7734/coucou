#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-compact-status.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    NotchBuddy/Sources/App/CompactStatus.swift NotchBuddy/Sources/App/SessionBook.swift \
    NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    tests/CompactStatusTests.swift -o "$TEST_DIR/compact-status-tests"
"$TEST_DIR/compact-status-tests"
