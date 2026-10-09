#!/usr/bin/env bash
# Offscreen UI snapshots: renders a fixed catalogue of island and Settings states to PNG
# (the DEBUG app's `--snapshot` mode, see NotchBuddy/Sources/App/Snapshot/) and compares
# them with the baselines in tests/snapshots/.
#
#   bash scripts/snapshot.sh              build, render, compare (fails when a case differs)
#   bash scripts/snapshot.sh --update     render and rewrite the baselines
#   bash scripts/snapshot.sh --ci DIR     render (fails only if rendering fails), compare for
#                                         the record, copy the PNGs and diffs to DIR
#   --no-build                            reuse the last build
#   --only case,case                      render (and compare) only these cases
#
# Nothing shows on screen and nothing steals focus: the binary is run directly (not with
# `open`, so Launch Services brings nothing forward), never orders a window in, and quits.
# It never touches the user's settings, Keychain or hook socket, so it runs next to the
# real Coucou. Build products: $SNAPSHOT_DERIVED_DATA (default $TMPDIR/coucou-snapshot/dd).
# A case fails when more than $SNAPSHOT_THRESHOLD % (default 0.5) of its pixels moved by
# more than 16/255 on any channel; failures get a side-by-side image
# (baseline | current | differing pixels in red) in the diff directory printed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=compare
build=1
ci_dir=""
only=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update)   mode=update ;;
        --ci)       mode=ci; ci_dir="${2:?--ci needs a directory}"; shift ;;
        --no-build) build=0 ;;
        --only)     only="${2:?--only needs case names}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

WORK="${SNAPSHOT_WORK_DIR:-${TMPDIR:-/tmp}/coucou-snapshot}"
WORK="${WORK%/}"
DERIVED="${SNAPSHOT_DERIVED_DATA:-$WORK/dd}"
BASELINES="tests/snapshots"
THRESHOLD="${SNAPSHOT_THRESHOLD:-0.5}"
mkdir -p "$WORK"
OUT="$(mktemp -d "$WORK/run.XXXXXX")"
DIFFS="$OUT/diff"
CURRENT="$OUT/current"
mkdir -p "$CURRENT"

start=$(date +%s)
if [ "$build" = 1 ]; then
    echo "── Building NotchBuddy (Debug, unsigned) into $DERIVED"
    if ! xcodebuild -project NotchBuddy/NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug \
            -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
            > "$OUT/build.log" 2>&1; then
        grep -E "error:" "$OUT/build.log" | head -20 >&2 || tail -20 "$OUT/build.log" >&2
        echo "Build failed. Log: $OUT/build.log" >&2
        exit 1
    fi
fi
BIN="$DERIVED/Build/Products/Debug/Coucou.app/Contents/MacOS/Coucou"
[ -x "$BIN" ] || { echo "No build at $BIN" >&2; exit 1; }

echo "── Rendering"
args=(--snapshot "$CURRENT")
[ -n "$only" ] && args+=(--only "$only")
# English whatever the Mac's language; the snapshot run quits by itself (killed after 180 s).
"$BIN" "${args[@]}" -AppleLanguages "(en)" -AppleLocale en_US 2> "$OUT/render.log" &
pid=$!
# The watchdog keeps no output open: a caller piping this script would wait for its sleep.
( sleep 180 && kill "$pid" ) < /dev/null > /dev/null 2>&1 &
watchdog=$!
status=0
wait "$pid" || status=$?
pkill -P "$watchdog" 2>/dev/null || true
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
grep "^snapshot:" "$OUT/render.log" || true
if [ "$status" != 0 ]; then
    echo "Rendering failed (exit $status). Log: $OUT/render.log" >&2
    [ -n "$ci_dir" ] && { mkdir -p "$ci_dir"; cp -R "$CURRENT" "$OUT/render.log" "$ci_dir/"; }
    exit 1
fi

if [ "$mode" = update ]; then
    mkdir -p "$BASELINES"
    if [ -n "$only" ]; then
        cp "$CURRENT"/*.png "$BASELINES/"
    else
        rm -f "$BASELINES"/*.png
        cp "$CURRENT"/*.png "$BASELINES/"
    fi
    echo "Baselines updated in $BASELINES ($(ls "$CURRENT" | wc -l | tr -d ' ') images) in $(( $(date +%s) - start )) s."
    rm -rf "$OUT"
    exit 0
fi

echo "── Comparing with $BASELINES"
COMPARE="$WORK/snapshot-compare"
if [ ! -x "$COMPARE" ] || [ scripts/SnapshotCompare.swift -nt "$COMPARE" ]; then
    swiftc -O scripts/SnapshotCompare.swift -o "$COMPARE"
fi
BASE_DIR="$BASELINES"
if [ -n "$only" ]; then   # compare only the cases rendered
    BASE_DIR="$OUT/baselines"
    mkdir -p "$BASE_DIR"
    for f in "$CURRENT"/*.png; do
        [ -f "$BASELINES/$(basename "$f")" ] && cp "$BASELINES/$(basename "$f")" "$BASE_DIR/"
    done
fi
compare_status=0
"$COMPARE" "$BASE_DIR" "$CURRENT" "$DIFFS" --threshold "$THRESHOLD" || compare_status=$?
echo "Took $(( $(date +%s) - start )) s."

if [ "$mode" = ci ]; then
    mkdir -p "$ci_dir"
    cp -R "$CURRENT" "$ci_dir/"
    [ -d "$DIFFS" ] && cp -R "$DIFFS" "$ci_dir/"
    cp "$OUT/render.log" "$ci_dir/"
    [ "$compare_status" = 0 ] || echo "(CI: differences reported, not failing: see the uploaded artifact)"
    exit 0
fi
if [ "$compare_status" = 0 ]; then
    rm -rf "$OUT"
else
    echo "Current PNGs: $CURRENT"
fi
exit "$compare_status"
