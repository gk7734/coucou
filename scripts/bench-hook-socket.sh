#!/usr/bin/env bash
# Benchmarks the hook socket transport on a temporary socket: the old thread-per-connection
# server (kept only in scripts/HookSocketBench.swift) against HookSocketServer.
# Not a test (not picked up by test-all.sh). Never touches the app's real socket.
#
#   bash scripts/bench-hook-socket.sh            # every scenario, old and new, 3 runs each (~1 min)
#   RUNS=1 bash scripts/bench-hook-socket.sh
#
# paced: 3 sessions × 10 events/s for 5 s (like `coucou-replay.py burst`), one connection
#        per event, fire-and-forget like the nb-hook relay.
# spike: 96 events fired at once by 16 clients, fire-and-forget (what a burst can drop).
# flood: 16 clients × 250 requests back to back, each waiting for its answer (capacity).
# Columns: sent / refused (connect() failed) / delivered (reached the main queue) / lost
# (connected then dropped), throughput while the clients ran, chain (messages whose process
# chain was captured: a fire-and-forget client that closed before accept() has none),
# latency client connect() → main-queue callback in ms, the server process's CPU seconds,
# its thread count before and at peak.
set -euo pipefail
cd "$(dirname "$0")/.."
RUNS="${RUNS:-3}"
BENCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-bench-hook-socket.XXXXXX")"
trap 'rm -rf "$BENCH_DIR"' EXIT
cp scripts/HookSocketBench.swift "$BENCH_DIR/main.swift"
swiftc -O -swift-version 5 \
    NotchBuddy/Sources/App/HookSocketServer.swift \
    NotchBuddy/Sources/App/PendingRequestQueue.swift \
    NotchBuddy/Sources/App/ProcessAncestry.swift \
    NotchBuddy/Sources/App/HostResolver.swift \
    "$BENCH_DIR/main.swift" -o "$BENCH_DIR/bench"
for scenario in paced spike flood; do
    for design in old new; do
        for _ in $(seq "$RUNS"); do
            "$BENCH_DIR/bench" run "$design" "$scenario"
        done
    done
done
