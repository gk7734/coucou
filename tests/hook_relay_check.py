"""Runs the relay scripts and the Hermes plugin written by HookRelayScriptsTests.

Usage: python3 -I tests/hook_relay_check.py <dir>

HOME points at an empty folder, so the relay never reaches a real Coucou socket: every
check here is the "Coucou is not answering" path, which must never block or deny.
"""
import importlib.util
import json
import os
import py_compile
import subprocess
import sys

DIR = sys.argv[1]
HOME = os.path.join(DIR, 'home')
os.makedirs(HOME, exist_ok=True)
ENV = {'HOME': HOME, 'PATH': '/usr/bin:/bin'}
checks = 0


def check(condition, message):
    global checks
    if not condition:
        print('FAIL ' + message)
        sys.exit(1)
    checks += 1


def relay(args, stdin, script='nb-hook.py', env=None, timeout=20):
    return subprocess.run([sys.executable, os.path.join(DIR, script)] + args,
                          input=stdin.encode(), capture_output=True,
                          env=env or ENV, timeout=timeout)


# Everything generated is valid Python.
for name in ['nb-hook.py', 'nb-hook-appstore.py', os.path.join('hermes_coucou', '__init__.py')]:
    py_compile.compile(os.path.join(DIR, name), doraise=True)
    checks += 1

# ── Coucou not running: nothing blocks, nothing is decided ─────────────────────────
r = relay([], json.dumps({'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash'}))
check(r.returncode == 0 and r.stdout == b'', 'Claude PermissionRequest: no output, exit 0')
r = relay(['--ask'], json.dumps({'tool_name': 'AskUserQuestion', 'tool_input': {'questions': []}}))
check(r.returncode == 0 and r.stdout == b'', 'AskUserQuestion: no output, exit 0')
r = relay(['--agent', 'copilot', 'permissionRequest'], json.dumps({'toolName': 'bash'}))
check(r.stdout.strip() == b'{"permissionDecision":"ask"}', 'Copilot (fail-closed) re-asks: %r' % r.stdout)
r = relay(['--agent', 'antigravity', 'PreToolUse'], json.dumps({}))
check(r.stdout.strip() == b'{"decision":"ask"}', 'Antigravity keeps its own prompt: %r' % r.stdout)
r = relay(['--agent', 'hermes'], json.dumps({'hook_event_name': 'PermissionRequest'}))
check(r.stdout == b'', 'Hermes: no output (the plugin falls back)')
r = relay([], '')
check(r.returncode == 0 and r.stdout == b'', 'empty stdin')
r = relay([], 'not json')
check(r.returncode == 0 and r.stdout == b'', 'invalid stdin')

# The shell wrapper too, and Copilot's answer even when the Python relay is missing.
wrapper = os.path.join(DIR, 'nb-hook')
r = subprocess.run(['/bin/sh', wrapper, '--agent', 'copilot', 'permissionRequest'], input=b'{}',
                   capture_output=True, env=ENV, timeout=20)
check(r.returncode == 0 and r.stdout.strip() == b'{"permissionDecision":"ask"}', 'wrapper: Copilot re-asks: %r' % r.stdout)

# ── Status line: a previous command that runs the relay again does not loop ────────
prev = os.path.join(DIR, 'statusline-previous.json')
with open(prev, 'w') as f:
    json.dump({'type': 'command',
               'command': "printf 'prev'; '%s' '%s' --statusline" % (sys.executable, os.path.join(DIR, 'nb-hook.py'))}, f)
try:
    r = relay(['--statusline'], json.dumps({'session_id': 's', 'rate_limits': {}}), timeout=30)
except subprocess.TimeoutExpired:
    check(False, 'status line chain loops')
check(r.stdout == b'prev', 'previous status line runs once: %r' % r.stdout)
os.remove(prev)
r = relay(['--statusline'], json.dumps({'session_id': 's'}))
check(r.returncode == 0 and r.stdout == b'', 'no previous status line')

# ── Hermes approval transport: errors fall back to Hermes' own prompt ──────────────
spec = importlib.util.spec_from_file_location('hermes_coucou', os.path.join(DIR, 'hermes_coucou', '__init__.py'))
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class Ctx:
    def __init__(self):
        self.hooks, self.transport = {}, None

    def register_hook(self, name, fn):
        self.hooks[name] = fn

    def register_approval_transport(self, name, fn):
        self.transport = (name, fn)


class Request:
    session_id = 's1'
    command = 'rm -rf build'
    description = 'dangerous'
    timeout_seconds = 10.0
    allowed_choices = ('once', 'session', 'deny')

    def respond(self, choice):
        return ('decision', choice)


ctx = Ctx()
plugin.register(ctx)
check(ctx.transport is not None and ctx.transport[0] == 'coucou', 'transport registered')
present = ctx.transport[1]
fake_hook = os.path.join(DIR, 'fake-hook')


def hermes_with_relay_output(output):
    with open(fake_hook, 'w') as f:
        f.write('#!/bin/sh\ncat >/dev/null\nprintf %s \'' + output + '\'\n')
    os.chmod(fake_hook, 0o755)
    try:
        return ('returned', present(Request()))
    except Exception as e:  # Hermes counts a raising transport as failed → builtin fallback
        return ('raised', type(e).__name__)


check(hermes_with_relay_output('{"choice":"once"}') == ('returned', ('decision', 'once')), 'allow from the notch')
check(hermes_with_relay_output('{"choice":"deny"}') == ('returned', ('decision', 'deny')), 'deny from the notch')
for output in ['', 'garbage', '{"choice":"always"}', '{}']:
    outcome = hermes_with_relay_output(output)
    check(outcome[0] == 'raised', 'no decision (%r) must fall back, not answer: %r' % (output, outcome))
os.remove(fake_hook)
try:
    present(Request())
    check(False, 'missing relay must fall back')
except Exception:
    checks += 1

print('Hook relay (Python): %d checks passed' % checks)
