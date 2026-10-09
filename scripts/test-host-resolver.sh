#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-host-resolver.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete NotchBuddy/Sources/App/HostResolver.swift \
    tests/HostResolverTests.swift -o "$TEST_DIR/host-resolver-tests"
"$TEST_DIR/host-resolver-tests"
