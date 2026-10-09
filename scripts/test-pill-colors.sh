#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-pill-colors.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/CoucouKit/PillColors.swift \
    NotchBuddy/Sources/CoucouKit/AppDefaults.swift \
    tests/PillColorsTests.swift -o "$TEST_DIR/pill-colors-tests"
"$TEST_DIR/pill-colors-tests"
