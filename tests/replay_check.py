"""Checks scripts/coucou-replay.py against a throwaway fake Coucou socket (scripts/test-replay.sh).

The fake server runs in this process, in a temp dir; the tool always gets --socket and a
temp HOME, so the real ~/Library/Application Support/NotchBuddy/nb.sock is never touched.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(REPO, "scripts", "coucou-replay.py")
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAIL: " + what)


class FakeCoucou:
    """Answers like HookServer: {"ok":true} for plain events; holds PermissionRequest and
    ask_user_question for a moment, then replies (deny when the command says "deny")."""

    def __init__(self, path):
        self.path = path
        self.received = []          # (monotonic time, payload, replied at)
        self.lock = threading.Lock()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(64)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        raw = b""
        conn.settimeout(5)
        try:
            while b"\n" not in raw:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            pass
        line = raw.split(b"\n")[0]
        if not line:
            conn.close()
            return
        payload = json.loads(line)
        arrived = time.monotonic()
        reply = '{"ok":true}'
        replied = None
        if payload.get("coucou_kind") == "ask_user_question":
            time.sleep(0.15)
            q = payload["tool_input"]["questions"][0]["question"]
            reply = json.dumps({"permissionDecision": "answer", "answers": {q: "Skip them"}})
            replied = time.monotonic()
        elif payload.get("hook_event_name") == "PermissionRequest":
            time.sleep(0.15)
            command = payload.get("tool_input", {}).get("command", "")
            reply = json.dumps({"permissionDecision": "deny" if "deny" in command else "allow"})
            replied = time.monotonic()
        with self.lock:
            self.received.append((arrived, payload, replied))
        try:
            conn.sendall((reply + "\n").encode())
        except OSError:
            pass
        conn.close()

    def payloads(self):
        with self.lock:
            return [p for _, p, _ in sorted(self.received, key=lambda r: r[0])]

    def reset(self):
        with self.lock:
            self.received = []


def run(args, home, timeout=20):
    env = dict(os.environ, HOME=home)
    return subprocess.run([sys.executable, "-I", TOOL] + args, capture_output=True, text=True,
                          timeout=timeout, env=env)


SCENARIO = r"""
{"_meta": {"description": "test", "host": "com.example.Meta", "relay": {"bundle_id": "${HOST}", "terminal_emulator": "JetBrains-JediTerm"}}}
# a comment line
{"_comment": "start", "_delay": 0.05, "hook_event_name": "SessionStart", "session_id": "t-${RUN}", "cwd": "${ROOT}/proj"}
{"_delay": 0.02, "_repeat": 2, "hook_event_name": "PreToolUse", "session_id": "t-${RUN}", "tool_name": "Read", "tool_input": {"file_path": "${ROOT}/proj/f${I}.txt"}}
{"_delay": 0.02, "hook_event_name": "PermissionRequest", "session_id": "t-${RUN}", "tool_name": "Bash", "tool_input": {"command": "npm test"}, "permission_suggestions": [{"type": "addRules"}]}
{"_if_allowed": true, "hook_event_name": "PostToolUse", "session_id": "t-${RUN}", "tool_name": "Bash", "tool_input": {"command": "npm test"}}
{"_delay": 0.02, "hook_event_name": "PermissionRequest", "session_id": "t-${RUN}", "tool_name": "Bash", "tool_input": {"command": "please deny"}}
{"_if_allowed": true, "hook_event_name": "PostToolUse", "session_id": "t-${RUN}", "tool_name": "Bash", "tool_input": {"command": "please deny"}}
{"_delay": 0.02, "hook_event_name": "PreToolUse", "coucou_kind": "ask_user_question", "session_id": "t-${RUN}", "tool_name": "AskUserQuestion", "tool_input": {"questions": [{"question": "Which way?", "options": [{"label": "Skip them"}, {"label": "Fail"}]}]}}
{"_delay": 0.02, "hook_event_name": "Stop", "session_id": "t-${RUN}", "coucou_host_override": "com.example.Line", "last_assistant_message": "done — ok"}
"""


def main():
    tmp = tempfile.mkdtemp(prefix="coucou-replay-")
    if len(os.path.join(tmp, "missing.sock").encode()) > 100:     # sun_path is 104 bytes
        shutil.rmtree(tmp)
        tmp = tempfile.mkdtemp(prefix="coucou-replay-", dir="/tmp")
    home = os.path.join(tmp, "home")
    os.makedirs(home)
    sock_path = os.path.join(tmp, "s.sock")
    server = FakeCoucou(sock_path)
    scenario = os.path.join(tmp, "test.jsonl")
    with open(scenario, "w") as f:
        f.write(SCENARIO)
    common = [scenario, "--socket", sock_path, "--root", "/r", "--host", "com.jetbrains.WebStorm", "--agent", "codex"]

    # --dry-run: prints every payload, connects to nothing.
    dry = run(common + ["--dry-run"], home)
    check(dry.returncode == 0, "dry-run exits 0 (%s)" % dry.stderr.strip())
    time.sleep(0.1)
    check(server.payloads() == [], "dry-run sends nothing")
    dry_payloads = [json.loads(l) for l in dry.stdout.splitlines() if l.strip()]
    check(len(dry_payloads) == 9, "dry-run prints 9 payloads (got %d)" % len(dry_payloads))

    # Real run.
    started = time.monotonic()
    res = run(common, home)
    elapsed = time.monotonic() - started
    check(res.returncode == 0, "replay exits 0 (rc %d, %s)" % (res.returncode, res.stderr.strip()))
    got = server.payloads()
    events = [(p.get("hook_event_name"), p.get("tool_input", {}).get("command")) for p in got]
    check(len(got) == 8, "8 events arrive (the denied request's follow-up is skipped), got %d: %s" % (len(got), events))
    for p in got:
        check(not any(k.startswith("_") for k in p), "control keys stripped: %s" % sorted(p))
        check(p.get("coucou_agent") == "codex", "--agent codex adds coucou_agent")
        check(p.get("terminal_emulator") == "JetBrains-JediTerm", "_meta.relay fields added")
    overrides = [p.get("coucou_host_override") for p in got]
    check(overrides[:-1] == ["com.jetbrains.WebStorm"] * 7, "--host beats _meta.host: %s" % overrides)
    check(overrides[-1] == "com.example.Line", "a line's own coucou_host_override wins")
    check(got[0].get("bundle_id") == "com.jetbrains.WebStorm", "${HOST} in _meta.relay is the host in effect")
    if got:
        check(got[0]["cwd"] == "/r/proj", "${ROOT} substituted in cwd")
        check(got[1]["cwd"] == "/r", "cwd defaults to --root")
        check(re.match(r"^t-[0-9a-f]{6}$", got[0]["session_id"] or "") is not None, "${RUN} is a hex run id")
        check(len({p["session_id"] for p in got}) == 1, "one session id for the whole pass")
        check([p["tool_input"]["file_path"] for p in got[1:3]] == ["/r/proj/f0.txt", "/r/proj/f1.txt"],
              "_repeat with ${I}")
        check(got[-1].get("last_assistant_message") == "done — ok", "unicode payload intact")
        check(got[3]["permission_suggestions"] == [{"type": "addRules"}], "nested payload intact")
    # Same payloads as the dry run (minus the skipped line), run id aside.
    def norm(p):
        return json.loads(json.dumps(p).replace(got[0]["session_id"] if got else "x", "t-RUN").replace("t-dryrun", "t-RUN"))
    expected = [norm(p) for p in dry_payloads if p.get("tool_input", {}).get("command") != "please deny"
                or p.get("hook_event_name") == "PermissionRequest"]
    check([norm(p) for p in got] == expected, "payloads arrive exactly as the dry run printed them")
    # Held requests: the next event waits for the reply.
    with server.lock:
        rec = sorted(server.received, key=lambda r: r[0])
    for i, (_, p, replied) in enumerate(rec[:-1]):
        if replied is not None:
            check(rec[i + 1][0] >= replied, "event after a held request waits for its reply (%s)" % p.get("hook_event_name"))
    out = res.stdout
    check(": allow" in out and ": deny" in out, "decisions printed")
    check('answered {"Which way?": "Skip them"}' in out, "answers printed")
    check('"behavior": "allow"' in out and '"behavior": "deny"' in out, "relay output printed (Codex format)")
    check("(skipped, deny)" in out, "_if_allowed line skipped after deny")
    check("8 events sent, 0 dropped" in out, "summary line: %s" % out.strip().splitlines()[-1:])
    check(elapsed < 5, "fast run (%.1f s)" % elapsed)

    # --host none: no override at all.
    server.reset()
    res = run([scenario, "--socket", sock_path, "--host", "none", "-q"], home)
    check(res.returncode == 0, "--host none run exits 0")
    check([p for p in server.payloads() if "coucou_host_override" in p and p["hook_event_name"] != "Stop"] == [],
          "--host none sends no override")
    check(all("coucou_agent" not in p for p in server.payloads()), "no coucou_agent without --agent")

    # Rate and --parallel: 2 workers x 21 events, 20 ms apart = ~100 events/s.
    rate_scn = os.path.join(tmp, "rate.jsonl")
    with open(rate_scn, "w") as f:
        f.write('{"_meta": {"parallel_hosts": ["a.one", "b.two"]}}\n')
        f.write('{"_delay": 0.02, "_repeat": 21, "hook_event_name": "PreToolUse", "session_id": "w${WORKER}-${RUN}", '
                '"tool_name": "Read", "_cycle": [{"tool_input": {"n": "${C}"}}, {"tool_input": {"n": "${C}"}}]}\n')
    server.reset()
    res = run([rate_scn, "--socket", sock_path, "--parallel", "2", "-q"], home)
    got = server.payloads()
    check(res.returncode == 0 and len(got) == 42, "--parallel 2 sends 42 events (got %d)" % len(got))
    check(len({p["session_id"] for p in got}) == 2, "--parallel: one session per worker")
    check({p["coucou_host_override"] for p in got} == {"a.one", "b.two"}, "parallel_hosts per worker")
    check(sorted(p["tool_input"]["n"] for p in got if p["session_id"].startswith("w0"))[:4] == ["0", "0", "1", "1"],
          "${C} counts cycle passes")
    m = re.search(r"([0-9.]+) events/s", res.stdout)
    rate = float(m.group(1)) if m else 0
    check(50 <= rate <= 130, "achieved rate close to 100 events/s (got %s)" % rate)

    # Missing socket: clear error, nothing created.
    missing = os.path.join(tmp, "missing.sock")
    res = run([scenario, "--socket", missing], home)
    check(res.returncode == 2 and "no Coucou socket" in res.stderr, "missing socket: exit 2 with a message")
    check(not os.path.exists(missing), "missing socket is not created")
    check(not os.path.exists(os.path.join(home, "Library")), "default socket folder untouched")

    # The shipped scenarios parse and expand.
    res = run(["--list"], home)
    check(res.returncode == 0 and "webstorm-claude" in res.stdout, "--list works")
    for name in sorted(os.listdir(os.path.join(REPO, "tests", "replay"))):
        if name.endswith(".jsonl"):
            res = run([name[:-6], "--dry-run"], home)
            check(res.returncode == 0 and res.stdout.strip(), "%s dry-runs (%s)" % (name, res.stderr.strip()))

    server.sock.close()
    shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print("%d replay check(s) failed" % len(failures))
        sys.exit(1)
    print("Replay tool: all checks passed")


if __name__ == "__main__":
    main()
