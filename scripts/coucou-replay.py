#!/usr/bin/env python3
"""coucou-replay: send scripted hook events to a running Coucou.

Reproduces agent activity (Claude Code, Codex…) in any IDE without running the agent or
the IDE: each scenario line is the JSON a hook relay would send to Coucou's socket.
Developer tool, Python 3 standard library only (works with macOS' /usr/bin/python3 3.9).

    python3 scripts/coucou-replay.py --list
    python3 scripts/coucou-replay.py webstorm-claude
    python3 scripts/coucou-replay.py zed-codex --speed 2
    python3 scripts/coucou-replay.py burst -q                 # 3 sessions, ~10 events/s, 60 s
    python3 scripts/coucou-replay.py webstorm-claude --host dev.zed.Zed --dry-run

Protocol (the same as the nb-hook relay, HookRelayScripts.swift):
  - one Unix-socket connection per event, the payload as one JSON line ending in "\\n";
  - plain events are fire-and-forget (0.3 s socket timeout, closed without reading);
  - a PermissionRequest, or a payload with coucou_kind "ask_user_question", keeps the
    connection open and waits for the app's reply line (118 s / 125 s like the relay):
    {"permissionDecision": "allow" | "always" | "deny" | "ask"} or
    {"permissionDecision": "answer", "answers": {...}}. EOF without a line means the app
    gave up or the request was answered elsewhere (the relay prints nothing then).

Scenario files: JSON Lines in tests/replay/*.jsonl. Blank lines and lines starting with
"#" are skipped. Each line is a hook payload plus optional control keys (stripped before
sending, every top-level key starting with "_"):
  _delay        seconds to wait before sending (divided by --speed)
  _delay_fixed  seconds to wait before sending, NOT divided by --speed (stall demos)
  _repeat       send the line n times (the delay applies before each one)
  _cycle        list of objects; repetition i is the line merged with _cycle[i % len]
  _async        for a held request: don't wait for the reply before the next line
  _if_allowed   send only if the previous held request got allow / always / answer
  _comment      free text
A first line {"_meta": {...}} describes the scenario:
  description, host (default coucou_host_override), agent ("codex" adds coucou_agent),
  relay (fields the relay would add, set only when the line lacks them: bundle_id,
  term_program, terminal_emulator…), parallel (default --parallel), parallel_hosts
  (host of worker i), stagger (seconds between worker starts, divided by --speed).
Variables in any string: ${ROOT} (--root), ${RUN} (random per run / loop pass),
${WORKER} (worker index, from 0), ${I} (repetition index, from 0), ${C} (pass through
_cycle: I // len(_cycle), so a Pre/Post pair shares it), ${HOST} (the host override in
effect, "" if none), ${HOME}.

coucou_host_override is honoured by DEBUG builds of Coucou only: it attributes the session
to that app instead of the one found in this script's process tree (your terminal).
"""

import argparse
import copy
import json
import os
import random
import re
import socket
import stat
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENARIO_DIR = os.path.join(REPO, "tests", "replay")
DEFAULT_SOCKET = "~/Library/Application Support/NotchBuddy/nb.sock"
DEFAULT_ROOT = "/tmp/coucou-replay"

# Same timeouts as the nb-hook relay.
PLAIN_TIMEOUT = 0.3
PERMISSION_TIMEOUT = 118.0
QUESTION_TIMEOUT = 125.0

CONTROL_KEYS = {"_delay", "_delay_fixed", "_repeat", "_cycle", "_async", "_if_allowed", "_comment"}
META_KEYS = {"description", "host", "agent", "relay", "parallel", "parallel_hosts", "stagger"}
AGENT_RE = re.compile(r"^[a-z0-9-]{1,24}$")
VAR_RE = re.compile(r"\$\{([A-Z_]+)\}")


class ScenarioError(Exception):
    pass


class AppUnreachable(Exception):
    pass


# MARK: - Scenario loading

class Scenario:
    def __init__(self, path, meta, lines):
        self.path = path
        self.name = os.path.splitext(os.path.basename(path))[0]
        self.meta = meta
        self.lines = lines          # [(line number, dict)]


def resolve_scenario(name):
    if os.path.isfile(name):
        return name
    candidate = os.path.join(SCENARIO_DIR, name if name.endswith(".jsonl") else name + ".jsonl")
    if os.path.isfile(candidate):
        return candidate
    raise ScenarioError("no scenario '%s' (see --list)" % name)


def load_scenario(path):
    meta = {}
    lines = []
    with open(path, encoding="utf-8") as f:
        for number, text in enumerate(f, 1):
            text = text.strip()
            if not text or text.startswith("#"):
                continue
            try:
                obj = json.loads(text)
            except ValueError as e:
                raise ScenarioError("%s:%d: invalid JSON (%s)" % (path, number, e))
            if not isinstance(obj, dict):
                raise ScenarioError("%s:%d: each line must be a JSON object" % (path, number))
            if "_meta" in obj:
                if lines or meta or len(obj) != 1 or not isinstance(obj["_meta"], dict):
                    raise ScenarioError("%s:%d: _meta must be alone, on the first line" % (path, number))
                meta = obj["_meta"]
                unknown = set(meta) - META_KEYS
                if unknown:
                    raise ScenarioError("%s:%d: unknown _meta key(s) %s" % (path, number, sorted(unknown)))
                continue
            unknown = {k for k in obj if k.startswith("_")} - CONTROL_KEYS
            if unknown:
                raise ScenarioError("%s:%d: unknown control key(s) %s" % (path, number, sorted(unknown)))
            cycle = obj.get("_cycle")
            if cycle is not None and (not isinstance(cycle, list) or not cycle
                                      or not all(isinstance(c, dict) for c in cycle)):
                raise ScenarioError("%s:%d: _cycle must be a non-empty list of objects" % (path, number))
            lines.append((number, obj))
    return Scenario(path, meta, lines)


def substitute(value, variables, where):
    if isinstance(value, str):
        def repl(m):
            if m.group(1) not in variables:
                raise ScenarioError("%s: unknown variable ${%s}" % (where, m.group(1)))
            return str(variables[m.group(1)])
        return VAR_RE.sub(repl, value)
    if isinstance(value, list):
        return [substitute(v, variables, where) for v in value]
    if isinstance(value, dict):
        return {k: substitute(v, variables, where) for k, v in value.items()}
    return value


def is_held(payload):
    return (payload.get("hook_event_name") == "PermissionRequest"
            or payload.get("coucou_kind") == "ask_user_question")


class Step:
    """One event to send: when (relative delay), what, and how."""
    __slots__ = ("delay", "fixed_delay", "payload", "held", "is_async", "if_allowed", "where")

    def __init__(self, delay, fixed_delay, payload, is_async, if_allowed, where):
        self.delay = delay
        self.fixed_delay = fixed_delay
        self.payload = payload
        self.held = is_held(payload)
        self.is_async = is_async
        self.if_allowed = if_allowed
        self.where = where


def expand(scenario, opts, worker, run_id):
    """Yields the scenario's Steps for one worker and one pass, payloads ready to send."""
    meta = scenario.meta
    host = worker_host(scenario, opts, worker)
    agent = opts.agent if opts.agent is not None else meta.get("agent", "")
    if agent == "claude":
        agent = ""      # the relay never tags Claude Code itself
    base_vars = {"ROOT": opts.root, "RUN": run_id, "WORKER": worker,
                 "HOST": host or "", "HOME": os.path.expanduser("~")}
    relay = meta.get("relay") or {}
    for number, line in scenario.lines:
        where = "%s:%d" % (scenario.path, number)
        repeat = line.get("_repeat", 1)
        if not isinstance(repeat, int) or repeat < 0:
            raise ScenarioError("%s: _repeat must be a positive integer" % where)
        cycle = line.get("_cycle") or [{}]
        for i in range(repeat):
            variables = dict(base_vars, I=i, C=i // len(cycle))
            raw = {k: v for k, v in line.items() if not k.startswith("_")}
            raw.update(copy.deepcopy(cycle[i % len(cycle)]))
            payload = substitute(raw, variables, where)
            # What the relay adds: --agent, then its environment fields (setdefault).
            if agent:
                payload.setdefault("coucou_agent", agent)
            for key, value in relay.items():
                payload.setdefault(key, substitute(value, variables, where))
            payload.setdefault("cwd", opts.root)
            if host and "coucou_host_override" not in payload:
                payload["coucou_host_override"] = host
            yield Step(delay=float(line.get("_delay", 0)),
                       fixed_delay=float(line.get("_delay_fixed", 0)),
                       payload=payload,
                       is_async=bool(line.get("_async", False)),
                       if_allowed=bool(line.get("_if_allowed", False)),
                       where=where)


def worker_host(scenario, opts, worker):
    """--host beats the scenario; "none" sends no override at all."""
    if opts.host is not None:
        return None if opts.host.lower() == "none" else opts.host
    hosts = scenario.meta.get("parallel_hosts")
    if hosts:
        return hosts[worker % len(hosts)]
    return scenario.meta.get("host")


# MARK: - Socket I/O

def check_socket(path):
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise AppUnreachable("no Coucou socket at %s. Is Coucou running? (--socket to use another one)" % path)
    if not stat.S_ISSOCK(st.st_mode):
        raise AppUnreachable("%s exists but is not a socket" % path)


def send(path, payload, held):
    """Sends one event. Returns the reply line for held requests ("" on EOF), else None."""
    data = (json.dumps(payload) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if held:
            s.settimeout(QUESTION_TIMEOUT if payload.get("coucou_kind") == "ask_user_question"
                         else PERMISSION_TIMEOUT)
        else:
            s.settimeout(PLAIN_TIMEOUT)
        try:
            s.connect(path)
        except (FileNotFoundError, ConnectionRefusedError) as e:
            raise AppUnreachable("Coucou is not listening on %s (%s)" % (path, e.strerror or e))
        s.sendall(data)
        if not held:
            return None
        chunks = []
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
        return b"".join(chunks).decode("utf-8", "replace").strip()
    finally:
        s.close()


def relay_output(payload, reply):
    """What the nb-hook relay would print to the agent for this reply (None: nothing)."""
    try:
        obj = json.loads(reply) if reply else {}
    except ValueError:
        obj = {}
    decision = obj.get("permissionDecision", "") if isinstance(obj, dict) else ""
    agent = payload.get("coucou_agent", "")
    if payload.get("coucou_kind") == "ask_user_question":
        if decision != "answer":
            return None
        questions = (payload.get("tool_input") or {}).get("questions", [])
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                       "updatedInput": {"questions": questions,
                                                        "answers": obj.get("answers", {})}}}
    if agent == "hermes":
        choice = "once" if decision == "allow" else decision
        return {"choice": choice} if choice in ("once", "always", "deny") else None
    if decision in ("allow", "always"):
        if agent in ("copilot", "muse"):
            return {"permissionDecision": "allow"}
        if decision == "always" and agent != "codex":
            return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
                "behavior": "allow", "updatedPermissions": payload.get("permission_suggestions", [])}}}
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
    if decision == "deny":
        if agent in ("copilot", "muse"):
            return {"permissionDecision": "deny"}
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
            "behavior": "deny", "message": "Denied from Coucou"}}}
    if agent == "copilot":
        return {"permissionDecision": "ask"}
    return None


def reply_decision(reply):
    try:
        obj = json.loads(reply)
        return obj.get("permissionDecision", "") if isinstance(obj, dict) else ""
    except ValueError:
        return ""


# MARK: - Running

class Output:
    def __init__(self, quiet):
        self.quiet = quiet
        self.lock = threading.Lock()
        self.t0 = time.monotonic()

    def line(self, text, force=False):
        if self.quiet and not force:
            return
        with self.lock:
            print("%8.2fs  %s" % (time.monotonic() - self.t0, text), flush=True)


def describe(payload):
    event = payload.get("hook_event_name", "?")
    if payload.get("coucou_kind") == "ask_user_question":
        event = "AskUserQuestion"
    detail = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    extra = (tool_input.get("command") or tool_input.get("file_path") or tool_input.get("pattern")
             or payload.get("prompt") or payload.get("last_assistant_message") or "")
    if event == "AskUserQuestion":
        qs = tool_input.get("questions") or [{}]
        extra = qs[0].get("question", "") if isinstance(qs[0], dict) else ""
    extra = " ".join(str(extra).split())
    if len(extra) > 48:
        extra = extra[:47] + "…"
    sid = str(payload.get("session_id", ""))
    host = payload.get("coucou_host_override", "")
    parts = ["%-17s" % event]
    if detail and event != "AskUserQuestion":
        parts.append(detail)
    if extra:
        parts.append('"%s"' % extra)
    parts.append("[%s%s]" % (sid, (" @ " + host) if host else ""))
    return " ".join(parts)


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.sent = 0
        self.dropped = 0
        self.first = None
        self.last = None

    def record(self, ok):
        now = time.monotonic()
        with self.lock:
            if ok:
                self.sent += 1
            else:
                self.dropped += 1
            if self.first is None:
                self.first = now
            self.last = now


def wait_held(opts, out, step, label):
    try:
        reply = send(opts.socket, step.payload, held=True)
    except AppUnreachable:
        raise
    except socket.timeout:
        out.line("%s: no reply (relay timeout) — the agent would ask in its terminal" % label, force=True)
        return ""
    except OSError as e:
        out.line("%s: connection error (%s)" % (label, e), force=True)
        return ""
    decision = reply_decision(reply)
    if not reply:
        out.line("%s: connection closed without a decision (app gave up or answered elsewhere)" % label, force=True)
    elif decision == "answer":
        answers = json.loads(reply).get("answers", {})
        out.line("%s: answered %s" % (label, json.dumps(answers, ensure_ascii=False)), force=True)
    else:
        out.line("%s: %s" % (label, decision or reply), force=True)
    printed = relay_output(step.payload, reply)
    if printed is not None:
        out.line("    the relay would print: %s" % json.dumps(printed, ensure_ascii=False), force=True)
    elif reply:
        out.line("    the relay would print nothing: the agent asks in its own terminal", force=True)
    return decision


def run_worker(scenario, opts, worker, out, stats, stop, errors):
    prefix = ("w%d " % worker) if opts.parallel > 1 else ""
    stagger = float(scenario.meta.get("stagger", 0)) * worker / opts.speed
    pending = []
    try:
        if stagger and stop.wait(stagger):
            return
        while not stop.is_set():
            run_id = "%06x" % random.getrandbits(24)
            target = time.monotonic()
            last_decision = None
            for step in expand(scenario, opts, worker, run_id):
                if stop.is_set():
                    return
                # Absolute schedule: send overhead doesn't slow the rate down.
                target += step.delay / opts.speed + step.fixed_delay
                pause = target - time.monotonic()
                if pause > 0 and stop.wait(pause):
                    return
                if step.if_allowed and last_decision not in ("allow", "always", "answer"):
                    out.line("%s(skipped, %s) %s" % (prefix, last_decision or "no decision", describe(step.payload)))
                    continue
                if step.held:
                    label = "%s%s waits for the notch" % (prefix, describe(step.payload))
                    out.line(label, force=True)
                    if step.is_async:
                        t = threading.Thread(target=wait_held, args=(opts, out, step, prefix + "reply"), daemon=True)
                        t.start()
                        pending.append(t)
                        stats.record(True)
                        continue
                    last_decision = wait_held(opts, out, step, prefix + "reply")
                    stats.record(True)
                    target = time.monotonic()      # the agent was blocked meanwhile
                    continue
                try:
                    send(opts.socket, step.payload, held=False)
                    stats.record(True)
                    out.line(prefix + describe(step.payload))
                except AppUnreachable:
                    raise
                except OSError as e:
                    stats.record(False)
                    out.line("%sDROPPED (%s) %s" % (prefix, e, describe(step.payload)), force=True)
            if not opts.loop:
                break
        for t in pending:
            while t.is_alive() and not stop.is_set():
                t.join(0.2)
    except (AppUnreachable, ScenarioError) as e:
        errors.append(str(e))
        stop.set()


def dry_run(scenario, opts):
    for worker in range(opts.parallel):
        for step in expand(scenario, opts, worker, "dryrun"):
            print(json.dumps(step.payload, ensure_ascii=False))


def scenario_summary(scenario, opts):
    events = 0
    duration = 0.0
    for step in expand(scenario, opts, 0, "list"):
        events += 1
        duration += step.delay + step.fixed_delay
    return events, duration


def list_scenarios(opts):
    if not os.path.isdir(SCENARIO_DIR):
        print("no scenarios in %s" % SCENARIO_DIR)
        return
    for name in sorted(os.listdir(SCENARIO_DIR)):
        if not name.endswith(".jsonl"):
            continue
        scenario = load_scenario(os.path.join(SCENARIO_DIR, name))
        events, duration = scenario_summary(scenario, opts)
        parallel = int(scenario.meta.get("parallel", 1))
        hosts = scenario.meta.get("parallel_hosts") or [scenario.meta.get("host") or "-"]
        print("%-22s %4d events%s, ~%ds, host %s" % (
            scenario.name, events * parallel, (" (%d sessions)" % parallel) if parallel > 1 else "",
            round(duration), ", ".join(hosts)))
        if scenario.meta.get("description"):
            print("    %s" % scenario.meta["description"])


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Send scripted hook events to a running Coucou (see the file header for the format).")
    p.add_argument("scenario", nargs="?", help="scenario name in tests/replay (without .jsonl) or a path")
    p.add_argument("--socket", default=None, help="Coucou's socket (default: %s)" % DEFAULT_SOCKET)
    p.add_argument("--host", default=None,
                   help="bundle id sent as coucou_host_override (DEBUG builds), 'none' for no override")
    p.add_argument("--agent", default=None, help="agent tag, e.g. 'codex' adds coucou_agent like nb-hook --agent")
    p.add_argument("--root", default=DEFAULT_ROOT, help="${ROOT}, the fake projects folder (default %(default)s)")
    p.add_argument("--speed", type=float, default=1.0, help="delay divisor: 2 = twice as fast (not _delay_fixed)")
    p.add_argument("--parallel", type=int, default=None, help="run N copies at once, each its own session")
    p.add_argument("--loop", action="store_true", help="start again at the end, until Ctrl-C")
    p.add_argument("--dry-run", action="store_true", help="print the payloads, send nothing")
    p.add_argument("--list", action="store_true", help="list the scenarios")
    p.add_argument("-q", "--quiet", action="store_true", help="only print held requests, drops and the summary")
    opts = p.parse_args(argv)
    if opts.speed <= 0:
        p.error("--speed must be > 0")
    if opts.agent and opts.agent != "claude" and not AGENT_RE.match(opts.agent):
        p.error("--agent must match ^[a-z0-9-]{1,24}$")
    if opts.parallel is not None and opts.parallel < 1:
        p.error("--parallel must be >= 1")
    if not opts.list and not opts.scenario:
        p.error("a scenario is required (or --list)")
    opts.socket = os.path.expanduser(opts.socket or DEFAULT_SOCKET)
    return opts


def main(argv):
    opts = parse_args(argv)
    try:
        if opts.list:
            opts.parallel = 1
            list_scenarios(opts)
            return 0
        scenario = load_scenario(resolve_scenario(opts.scenario))
        if opts.parallel is None:
            opts.parallel = int(scenario.meta.get("parallel", 1))
        if opts.dry_run:
            dry_run(scenario, opts)
            return 0
        check_socket(opts.socket)
    except (ScenarioError, AppUnreachable) as e:
        print("coucou-replay: %s" % e, file=sys.stderr)
        return 2

    out = Output(opts.quiet)
    stats = Stats()
    stop = threading.Event()
    errors = []
    print("Replaying %s on %s%s%s" % (
        scenario.name, opts.socket,
        (", %d sessions" % opts.parallel) if opts.parallel > 1 else "",
        (", speed x%g" % opts.speed) if opts.speed != 1 else ""), flush=True)
    workers = [threading.Thread(target=run_worker, args=(scenario, opts, w, out, stats, stop, errors), daemon=True)
               for w in range(opts.parallel)]
    for t in workers:
        t.start()
    interrupted = False
    last_report = time.monotonic()
    try:
        while any(t.is_alive() for t in workers):
            for t in workers:
                t.join(0.2)
            if opts.quiet and time.monotonic() - last_report >= 10:
                last_report = time.monotonic()
                out.line("%d events sent" % stats.sent, force=True)
    except KeyboardInterrupt:
        interrupted = True
        stop.set()
        for t in workers:
            t.join(1)

    elapsed = (stats.last - stats.first) if stats.first is not None and stats.last is not None else 0.0
    rate = (stats.sent - 1) / elapsed if elapsed > 0 and stats.sent > 1 else 0.0
    print("%s%d events sent, %d dropped, %.1f s, %.1f events/s" % (
        "Interrupted: " if interrupted else "Done: ", stats.sent, stats.dropped, elapsed, rate), flush=True)
    if errors:
        print("coucou-replay: %s" % errors[0], file=sys.stderr)
        return 2
    return 130 if interrupted else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
