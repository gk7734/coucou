#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-audio-spectrum.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macosx15.0" \
    NotchBuddy/Sources/App/AudioSpectrumMath.swift \
    NotchBuddy/Sources/App/SpectrumAnalyzer.swift \
    tests/AudioSpectrumTests.swift -o "$TEST_DIR/audio-spectrum-tests"
"$TEST_DIR/audio-spectrum-tests"
