#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-compact-visualizer.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    NotchBuddy/Sources/App/CompactVisualizer.swift NotchBuddy/Sources/App/CompactStatus.swift \
    NotchBuddy/Sources/App/SessionBook.swift NotchBuddy/Sources/App/NowPlaying.swift \
    NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/AppDefaults.swift \
    tests/CompactVisualizerTests.swift -o "$TEST_DIR/compact-visualizer-tests"
"$TEST_DIR/compact-visualizer-tests"
