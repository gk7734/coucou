#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-notification-policy.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete NotchBuddy/Sources/App/SessionBook.swift \
    NotchBuddy/Sources/App/SessionAlert.swift NotchBuddy/Sources/App/NotificationPolicy.swift \
    tests/NotificationPolicyTests.swift -o "$TEST_DIR/notification-policy-tests"
"$TEST_DIR/notification-policy-tests"
