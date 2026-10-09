#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-session-book.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete NotchBuddy/Sources/App/SessionBook.swift \
    tests/SessionBookTests.swift -o "$TEST_DIR/session-book-tests"
"$TEST_DIR/session-book-tests"
