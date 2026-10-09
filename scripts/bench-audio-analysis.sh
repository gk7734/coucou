#!/usr/bin/env bash
# Times the sound visualizer's analysis on synthetic audio (silence, sines, white noise):
# µs per 30 Hz analysis frame (Hann window + 2048-point FFT + 12 bands + smoothing), µs per
# IO buffer written into the ring, and the CPU share that makes. The Core Audio tap and the
# HAL's own IO cost are not included: measure those live with scripts/measure-cpu.sh.
# Not a test (test-all.sh skips it): run it by hand. Takes a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-bench-audio.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx15.0" \
    NotchBuddy/Sources/App/AudioSpectrumMath.swift \
    NotchBuddy/Sources/App/SpectrumAnalyzer.swift \
    scripts/bench/BenchAudioAnalysis.swift \
    -o "$BUILD_DIR/bench-audio-analysis"
"$BUILD_DIR/bench-audio-analysis"
