#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-auto-music-pill.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    NotchBuddy/Sources/App/AutoMusicPill.swift \
    tests/AutoMusicPillTests.swift -o "$TEST_DIR/auto-music-pill-tests"
"$TEST_DIR/auto-music-pill-tests"
