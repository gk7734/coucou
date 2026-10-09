#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-frame-rate.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/MochiFrameRate.swift \
    tests/MochiFrameRateTests.swift -o "$TEST_DIR/frame-rate-tests"
"$TEST_DIR/frame-rate-tests"
