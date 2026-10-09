#!/usr/bin/env bash
# bench-mochi.sh — offline benchmark of the animated Mochi (BotEngine update + draw).
# NOT in CI (timings depend on the machine). Everything is rendered offscreen (no window).
# Run manually:
#   bash scripts/bench-mochi.sh                       # ms per frame, per state and size
#   bash scripts/bench-mochi.sh --frames 1200 --only compact
#   bash scripts/bench-mochi.sh --png DIR             # deterministic frames, for a visual diff
#   bash scripts/bench-mochi.sh --compare DIR_A DIR_B # pixel comparison of two --png dumps
# MOCHI_SRC=path/to/CoucouKit compiles another copy of the sources (e.g. an older commit,
# extracted with `git archive`), to compare before/after.
# BENCH_BIN=path only builds the binary and copies it there.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${MOCHI_SRC:-NotchBuddy/Sources/CoucouKit}"
SDK=$(xcrun --sdk macosx --show-sdk-path)
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-bench-mochi.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc -O -g \
  -parse-as-library \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macosx15.0" \
  "$SRC/IslandScreenGeometry.swift" \
  "$SRC/IslandTypes.swift" \
  "$SRC/MochiWardrobe.swift" \
  "$SRC/ColorHex.swift" \
  "$SRC/BotEngine.swift" \
  "$SRC/MochiOutfitDrawing.swift" \
  scripts/bench/BenchMochi.swift \
  -framework AppKit -framework SwiftUI \
  -o "$OUT_DIR/bench-mochi"

if [ -n "${BENCH_BIN:-}" ]; then   # keep the binary (e.g. to run it under `sample`)
  cp "$OUT_DIR/bench-mochi" "$BENCH_BIN"
  exit 0
fi
"$OUT_DIR/bench-mochi" "$@"
