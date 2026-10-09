#!/usr/bin/env bash
# Times the old LCS line diff against DiffEngine's Myers diff on synthetic files
# (1k, 2k, 5k, 20k lines — 2k vs 2k is the largest the app diffs — with a few changes,
# 10 % of the lines changed, or a full rewrite).
# Not a test (test-all.sh skips it): run it by hand. Takes about ten seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-bench-diff.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -O NotchBuddy/Sources/CoucouKit/DiffEngine.swift scripts/BenchDiff.swift \
    -o "$BUILD_DIR/bench-diff"
"$BUILD_DIR/bench-diff"
