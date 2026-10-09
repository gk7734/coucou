#!/usr/bin/env bash
# Live smoke test: runs the real Coucou (DEBUG build) with replayed hook traffic and checks
# what it does, without touching the user's own Coucou:
#   - its own socket, nb-hook, recap.json and logs in a short temp folder (COUCOU_SUPPORT_DIR),
#   - its own UserDefaults suite (COUCOU_DEFAULTS_SUITE), deleted at the end,
#   - headless (COUCOU_SMOKE=1): no menu bar item, hotkeys, global monitors, sounds,
#     notifications, audio capture, music listeners, pollers or iPhone link; the island panel
#     is transparent and click-through, and the pointer is treated as far from it.
# Checks: launch (no crash, alive 10 s), pills and sessions per scenario, approvals and a
# question answered (coucou-replay.py --answer), the island folding after alerts, sessions
# settling to idle, books trimmed, CPU while hidden (< 1 %) and during a burst, memory.
# About 2 minutes after the build. Needs a GUI session (the island is a real window).
# Slower than the unit tests: not run by test-all.sh (its name doesn't start with test-).
#
#   bash scripts/smoke.sh                          # builds Debug first
#   SMOKE_APP=/path/to/Coucou.app bash scripts/smoke.sh   # an existing DEBUG build
#   SMOKE_DERIVED_DATA=/some/dir bash scripts/smoke.sh    # where to build (default /tmp/coucou-smoke-dd)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
REPLAY="$REPO/scripts/coucou-replay.py"
DD="${SMOKE_DERIVED_DATA:-/tmp/coucou-smoke-dd}"
USER_DOMAIN="fr.louisraille.NotchBuddy"

# MARK: - Results

FAILURES=()
NOTES=()
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAILURES+=("$1"); }
note() { printf '  ----  %s\n' "$1"; NOTES+=("$1"); }
check() {  # check "description" command…
    local what="$1"; shift
    if "$@"; then ok "$what"; else bad "$what"; fi
}

# MARK: - Build

if [ -n "${SMOKE_APP:-}" ]; then
    APP="$SMOKE_APP"
else
    echo "Building Coucou (Debug) in ${DD}…"
    (cd NotchBuddy && { command -v xcodegen >/dev/null && xcodegen >/dev/null || true; } \
        && xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug \
            -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build > "$DD.build.log" 2>&1) \
        || { tail -30 "$DD.build.log"; echo "FAIL: build"; exit 1; }
    APP="$DD/Build/Products/Debug/Coucou.app"
fi
BIN="$APP/Contents/MacOS/Coucou"
[ -x "$BIN" ] || { echo "FAIL: no app binary at $BIN"; exit 1; }

# MARK: - Isolated environment

# Short path: a Unix socket path must fit in 103 bytes.
TMP="$(mktemp -d /tmp/coucou-smoke.XXXXXX)"
SOCK="$TMP/nb.sock"
SUITE="$USER_DOMAIN.smoke.$$"
APP_PID=""
MARKER="$TMP/started"

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.3; done
        kill -9 "$APP_PID" 2>/dev/null
    fi
    defaults delete "$SUITE" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$SUITE.plist"
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Shorter delays than the defaults so the run stays short (the suite is this run's only).
defaults write "$SUITE" autoCloseInterval -float 3       # alert auto-close (default 15 s)
defaults write "$SUITE" smokePetitHideDelay -float 3     # compact → hidden (default 60 s)
defaults write "$SUITE" absenceInterval -float 0         # nobody moves the pointer: no absence
defaults write "$SUITE" visualizerEnabled -bool false
defaults write "$SUITE" soundEnabled -bool false

# The user's own preferences, to show the run never wrote them (absent on CI).
USER_BEFORE=""
if defaults export "$USER_DOMAIN" "$TMP/user-before.plist" 2>/dev/null; then USER_BEFORE="$TMP/user-before.plist"; fi

# MARK: - Helpers

# Evaluates a Python expression on the app's debug_state: s (the state), ids (pill ids),
# books (pill → sessions). Prints the result, nothing if the app doesn't answer.
st() {
    python3 "$REPLAY" --socket "$SOCK" --state 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)
ids = [t["id"] for t in s["tasks"]]
books = s["sessionBooks"]
print(eval(sys.argv[1]))' "$1" 2>/dev/null
}
# wait_for EXPR SECONDS: true once EXPR is True within SECONDS.
wait_for() {
    local deadline=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        [ "$(st "$1")" = "True" ] && return 0
        sleep 0.5
    done
    return 1
}
alive() { kill -0 "$APP_PID" 2>/dev/null; }
# Average %CPU of the app over N seconds (top, 1 s samples, the first one dropped).
avg_cpu() {
    top -l "$(( $1 + 1 ))" -s 1 -pid "$APP_PID" -stats cpu 2>/dev/null \
        | awk '/^%CPU/{getline; n++; if (n>1) {s+=$1; c++}} END {if (c) printf "%.2f", s/c; else print "n/a"}'
}
rss_mb() { ps -o rss= -p "$APP_PID" | awk '{printf "%.0f", $1/1024}'; }
summary() { st "'mode=%s view=%s fsm=%s focus=%s books=%s' % (s['mode'], s['view'], s['fsm'], s['focusId'], {k: [x['phase'] for x in v] for k, v in books.items()})"; }
# replay SCENARIO ARGS…: runs a scenario on the test socket, output in $TMP/<scenario>.log.
replay() {
    local name="$1"; shift
    python3 "$REPLAY" "$name" --socket "$SOCK" --root "$TMP/projects" "$@" > "$TMP/$name.log" 2>&1
}
# The island folds after an alert: not expanded, nothing pending, within N seconds.
folds() { wait_for "s['mode'] != 'expanded' and not s['pendingApproval'] and not s['pendingQuestion']" "$1"; }

# MARK: - Launch

echo "Smoke test: $APP"
echo "  support dir $TMP, defaults suite $SUITE"
touch "$MARKER"
LAUNCHED=$(date +%s)
COUCOU_SMOKE=1 COUCOU_SUPPORT_DIR="$TMP" COUCOU_DEFAULTS_SUITE="$SUITE" "$BIN" > "$TMP/app.out" 2>&1 &
APP_PID=$!
echo "  pid $APP_PID"

echo "Launch"
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; alive || break; sleep 0.25; done
check "socket in the support dir override" test -S "$SOCK"
sleep "$(( LAUNCHED + 10 - $(date +%s) > 0 ? LAUNCHED + 10 - $(date +%s) : 0 ))"
check "alive 10 s after launch" alive
check "debug_state answers" test "$(st "s['ok']")" = "True"
check "greeting ends, island folds (FSM out of coucou)" \
    wait_for "s['fsm'] != 'coucou' and s['mode'] != 'expanded'" 15
check "nb-hook relay written to the support dir, with this run's socket" \
    grep -q "$SOCK" "$TMP/nb-hook.py"

if ! alive; then
    bad "the app is not running: the scenarios are skipped"
else
    # MARK: - Scenarios
    W="ide_com-jetbrains-webstorm"; P="ide_com-jetbrains-pycharm"; G="ide_app-gram-gram"

    echo "Scenario webstorm-claude (approval allowed from the script)"
    replay webstorm-claude --speed 4 --answer allow
    check "replay ran" grep -q "^Done: 10 events sent, 0 dropped" "$TMP/webstorm-claude.log"
    check "approval answered allow" grep -q "reply: allow" "$TMP/webstorm-claude.log"
    check "WebStorm pill with one session" wait_for "'$W' in ids and len(books.get('$W', [])) == 1" 5
    check "session settles to idle" wait_for "[x['phase'] for x in books.get('$W', [])] == ['idle']" 12
    check "island folds after the approval and the finish" folds 15
    echo "    $(summary)"

    echo "Scenario two-sessions-one-ide (question answered from the script)"
    replay two-sessions-one-ide --speed 4 --answer allow
    check "question answered" grep -q "reply: answered" "$TMP/two-sessions-one-ide.log"
    check "PyCharm pill with two sessions" wait_for "len(books.get('$P', [])) == 2" 5
    check "both sessions settle to idle" wait_for "[x['phase'] for x in books.get('$P', [])] == ['idle', 'idle']" 12
    check "island folds" folds 15
    echo "    $(summary)"

    echo "Scenario zed-codex (approval denied from the script)"
    replay zed-codex --speed 4 --answer deny
    check "approval answered deny" grep -q "reply: deny" "$TMP/zed-codex.log"
    check "Codex session tracked (agent codex)" \
        wait_for "any(x['agent'] == 'codex' and x['id'].startswith('codex-') for v in books.values() for x in v)" 5
    check "Codex session settles to idle" \
        wait_for "all(x['phase'] == 'idle' for v in books.values() for x in v if x['id'].startswith('codex-'))" 12
    echo "    Codex pill: $(st "[k for k, v in books.items() if any(x['id'].startswith('codex-') for x in v)]")"
    check "island folds" folds 15

    echo "Scenario gram-unknown-ide (an IDE nobody declared)"
    replay gram-unknown-ide --speed 4
    check "Gram gets its own pill" wait_for "'$G' in ids and len(books.get('$G', [])) == 1" 5
    check "session settles to idle" wait_for "[x['phase'] for x in books.get('$G', [])] == ['idle']" 12
    check "island folds" folds 15
    check "no approval or question left waiting" \
        test "$(st "s['queuedApprovals'] + s['queuedQuestions']")" = "0"
    echo "    $(summary)"

    # MARK: - Burst
    echo "Scenario burst (3 sessions, ~20 events/s for ~30 s)"
    replay burst --speed 2 -q &
    BURST=$!
    sleep 3
    BURST_CPU=$(avg_cpu 20)
    BURST_RSS=$(rss_mb)
    wait "$BURST"
    note "CPU during the burst: ${BURST_CPU} % (RSS ${BURST_RSS} MB)"
    check "burst sent without drops" grep -Eq "^Done: [0-9]+ events sent, 0 dropped" "$TMP/burst.log"
    tail -1 "$TMP/burst.log" | sed 's/^/    /'
    check "alive after the burst" alive
    check "burst sessions on their three pills" \
        wait_for "sum(1 for v in books.values() for x in v if x['id'].startswith('burst-')) == 3" 5
    check "every session settles (idle)" wait_for "all(x['phase'] == 'idle' for v in books.values() for x in v)" 15
    check "island folds" folds 15

    # MARK: - Trim, idle
    echo "Books trimmed (as if 11 minutes passed)"
    python3 "$REPLAY" --socket "$SOCK" --debug '{"coucou_kind": "debug_trim", "advance": 660}' > /dev/null 2>&1
    check "ended sessions dropped" wait_for "books == {}" 3
    check "IDE pills removed with their last session" \
        wait_for "not any(i.startswith('ide_') for i in ids)" 3

    echo "Idle"
    check "island hidden when nothing happens" wait_for "s['mode'] == 'hidden' and s['fsm'] == 'hidden'" 15
    echo "    $(summary)"
    IDLE_CPU=$(avg_cpu 15)
    note "CPU idle, island hidden (15 s): ${IDLE_CPU} %"
    check "idle CPU < 1 % (${IDLE_CPU} %)" awk -v c="$IDLE_CPU" 'BEGIN { exit !(c != "n/a" && c < 1.0) }'
    RSS=$(rss_mb)
    note "memory: ${RSS} MB RSS"
    check "RSS < 400 MB (${RSS} MB)" test "${RSS:-9999}" -lt 400
    check "still alive at the end" alive
fi

# MARK: - Crash reports, isolation

# A crash report of this run's process (by pid), with the crashing thread's frames.
REPORTS=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Coucou*.ips' -newer "$MARKER" 2>/dev/null)
CRASH=""
for r in $REPORTS; do
    if python3 - "$r" "$APP_PID" <<'PY'
import json, sys
path, pid = sys.argv[1], int(sys.argv[2])
text = open(path, encoding="utf-8", errors="replace").read()
header, _, body = text.partition("\n")
try:
    report = json.loads(body)
except ValueError:
    sys.exit(1)
if report.get("pid") != pid:
    sys.exit(1)
exc = report.get("exception", {})
print("    crash report %s: %s %s" % (path, exc.get("type", "?"), exc.get("signal", "")))
term = report.get("termination", {}).get("indicator")
if term:
    print("    %s" % term)
images = report.get("usedImages", [])
thread = report.get("threads", [])[report.get("faultingThread", 0)]
for i, f in enumerate(thread.get("frames", [])[:20]):
    image = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
    print("    %2d %-24s %s" % (i, image, f.get("symbol", "0x%x" % f.get("imageOffset", 0))))
PY
    then CRASH="$r"; fi
done
if [ -n "$CRASH" ]; then bad "no crash report for this run"; else ok "no crash report for this run"; fi

if [ -n "$USER_BEFORE" ] && defaults export "$USER_DOMAIN" "$TMP/user-after.plist" 2>/dev/null; then
    defaults export "$SUITE" "$TMP/suite.plist" 2>/dev/null
    TOUCHED=$(python3 - "$USER_BEFORE" "$TMP/user-after.plist" "$TMP/suite.plist" <<'PY'
import plistlib, sys
load = lambda p: plistlib.load(open(p, "rb"))
before, after = load(sys.argv[1]), load(sys.argv[2])
try:
    ours = set(load(sys.argv[3]))
except Exception:
    ours = set()
changed = {k for k in set(before) | set(after) if before.get(k) != after.get(k)}
# Keys this run wrote (they are in its suite) must be untouched in the user's domain.
print(" ".join(sorted(changed & ours)))
PY
)
    check "the user's preferences untouched by this run${TOUCHED:+ (changed: $TOUCHED)}" test -z "$TOUCHED"
fi
suite_has() { defaults read "$SUITE" "$1" >/dev/null 2>&1; }
check "this run's preferences went to its suite (activeIntegrations)" suite_has activeIntegrations
check "this run's logs went to the support dir override" test -s "$TMP/Logs/nb.log"

# MARK: - Summary

echo
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "App output (last lines):"; tail -20 "$TMP/app.out" | sed 's/^/    /'
    echo "SMOKE FAIL (${#FAILURES[@]}):"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "SMOKE PASS — ${NOTES[*]}"
