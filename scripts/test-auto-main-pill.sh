#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-auto-main-pill.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# AutoMainPill reads `ide_` ids through HostResolver (Foundation only too).
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    NotchBuddy/Sources/App/AutoMainPill.swift \
    NotchBuddy/Sources/App/HostResolver.swift \
    tests/AutoMainPillTests.swift -o "$TEST_DIR/auto-main-pill-tests"
"$TEST_DIR/auto-main-pill-tests"
