#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-pending-requests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/PendingRequestQueue.swift \
    tests/PendingRequestQueueTests.swift -o "$TEST_DIR/pending-requests-tests"
"$TEST_DIR/pending-requests-tests"
