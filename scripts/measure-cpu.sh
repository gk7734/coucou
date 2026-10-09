#!/usr/bin/env bash
# Measures Coucou's CPU while idle and under a replayed burst of hook events.
# Usage: bash scripts/measure-cpu.sh [path/to/Coucou.app]
# Build it optimised first, e.g.:
#   xcodebuild -project NotchBuddy/NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug \
#     SWIFT_OPTIMIZATION_LEVEL=-O -derivedDataPath /tmp/coucou-perf build
# The app is (re)launched; keep the pointer away from the notch while it runs.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/tmp/coucou-perf/Build/Products/Debug/Coucou.app}"
IDLE_SECONDS="${IDLE_SECONDS:-30}"

pkill -f "Coucou.app/Contents/MacOS/Coucou" 2>/dev/null || true
sleep 1
open "$APP"
sleep "${SETTLE_SECONDS:-80}"   # greeting, then the compact island hides after 60 s
PID=$(pgrep -f "Coucou.app/Contents/MacOS/Coucou" | head -1)
[ -n "$PID" ] || { echo "Coucou is not running"; exit 1; }

avg_cpu() {  # seconds → average %CPU over that window (top, 1 s samples, first sample dropped)
    top -l "$(( $1 + 1 ))" -s 1 -pid "$PID" -stats cpu 2>/dev/null \
        | awk '/^%CPU/{getline; n++; if (n>1) {s+=$1; c++}} END {if (c) printf "%.1f", s/c; else print "n/a"}'
}
rss_mb() { ps -o rss= -p "$PID" | awk '{printf "%.0f", $1/1024}'; }

echo "Idle (no sessions, ${IDLE_SECONDS}s): $(avg_cpu "$IDLE_SECONDS") % CPU, $(rss_mb) MB"

python3 scripts/coucou-replay.py burst -q > /tmp/coucou-burst.log 2>&1 &
REPLAY=$!
sleep 2
echo "Burst (3 sessions, ~10 events/s, 50s): $(avg_cpu 50) % CPU, $(rss_mb) MB"
wait "$REPLAY" || true
tail -1 /tmp/coucou-burst.log
sleep "${SETTLE_SECONDS:-80}"
echo "After burst, island hidden again (20s): $(avg_cpu 20) % CPU, $(rss_mb) MB"
