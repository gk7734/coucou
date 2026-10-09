#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-island-types.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# IslandTypes is shared with the iPhone app; the test stubs the one SwiftUI type it stores.
swiftc NotchBuddy/Sources/CoucouKit/IslandTypes.swift \
    NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift \
    tests/IslandTypesTests.swift -o "$TEST_DIR/island-types-tests"
"$TEST_DIR/island-types-tests"
