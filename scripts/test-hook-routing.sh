#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hook-routing.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# HookRouting builds on HostResolver and SessionBook; BotState and the pill palette come from
# CoucouKit (the test stubs the one SwiftUI type IslandTypes stores).
swiftc NotchBuddy/Sources/App/HookRouting.swift \
    NotchBuddy/Sources/App/HostResolver.swift \
    NotchBuddy/Sources/App/SessionBook.swift \
    NotchBuddy/Sources/CoucouKit/IslandTypes.swift \
    NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift \
    NotchBuddy/Sources/CoucouKit/PillColors.swift \
    tests/HookRoutingTests.swift -o "$TEST_DIR/hook-routing-tests"
"$TEST_DIR/hook-routing-tests"
