#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-keychain-store.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/KeychainStore.swift \
    tests/KeychainStoreTests.swift -o "$TEST_DIR/keychain-store-tests"
"$TEST_DIR/keychain-store-tests"
