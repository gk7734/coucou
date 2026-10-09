#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hook-file-diff.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/App/HookFileDiff.swift \
    NotchBuddy/Sources/App/OrderedDelivery.swift \
    tests/HookFileDiffTests.swift -o "$TEST_DIR/hook-file-diff-tests"
"$TEST_DIR/hook-file-diff-tests"
