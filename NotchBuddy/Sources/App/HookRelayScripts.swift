import Foundation

// MARK: - Scripts and plugins Coucou writes for the agents
// Kept out of HookServer.swift and free of app types: everything here is plain text,
// generated from the path of the nb-hook relay. scripts/test-hook-relay.sh compiles
// this file on its own and runs the generated Python against a fake socket.

// MARK: - nb-hook shell wrapper (same for both GitHub and App Store)
// Invoked by Claude Code via /bin/sh or directly via shebang.
// Always exits 0 — never blocks Claude Code.
// Checks xcode-select before running python3 to avoid triggering the
// "install developer tools" dialog on machines without Xcode CLI tools.

let nbHookShellWrapper = """
#!/bin/sh
# Coucou hook relay — always exits 0, never blocks Claude Code
HOOK_DIR="$(dirname "$0")"
out=""
if xcode-select -p >/dev/null 2>&1; then
    out=$(/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        out=""
    fi
fi
if [ -n "$out" ]; then
    printf '%s\\n' "$out"
else
    # Copilot is fail-closed — must always output valid JSON even when python3 is absent or crashes.
    _cop=0; _perm=0
    for _a in "$@"; do
        case "$_a" in
            copilot) _cop=1 ;;
            permissionRequest|PermissionRequest) _perm=1 ;;
        esac
    done
    if [ "$_cop" -eq 1 ]; then
        if [ "$_perm" -eq 1 ]; then
            printf '{"permissionDecision":"ask"}\\n'
        else
            printf '{}\\n'
        fi
    fi
fi
exit 0
"""

// MARK: - nb-hook Python relay
// One script for both builds: only the header and the socket path differ.

/// GitHub / non-sandboxed build: socket in ~/Library/Application Support/NotchBuddy.
let nbHookPythonGitHub = nbHookPython(
    header: """
    # nb-hook.py — Coucou hook relay for Claude Code and third-party agents (GitHub version)
    # Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
    """,
    socketPath: "~/Library/Application Support/NotchBuddy/nb.sock")

/// App Store build: the socket lives inside the sandboxed container; the script runs outside it.
let nbHookPythonAppStore = nbHookPython(
    header: """
    # nb-hook.py — Coucou (App Store) hook relay for Claude Code and third-party agents
    # Socket lives inside the sandboxed container; script runs outside the sandbox.
    """,
    socketPath: "~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock")

/// `header`: the comment lines under the shebang. `socketPath`: where the app listens,
/// `~`-relative (expanded by the script). Neither may contain a quote.
private func nbHookPython(header: String, socketPath: String) -> String {
    return """
#!/usr/bin/env python3
\(header)
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    socket_path = os.path.expanduser(
        '\(socketPath)'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        # A previous status line that itself runs this relay must not start it again
        # (and again): the chained command is marked, and a marked relay stops here.
        if os.path.exists(prev_file) and not os.environ.get('COUCOU_STATUSLINE_CHAINED'):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    env = dict(os.environ, COUCOU_STATUSLINE_CHAINED='1')
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10, env=env)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        payload.setdefault('terminal_emulator', env.get('TERMINAL_EMULATOR', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)
    # Claude Code sessions from the Claude desktop app (Code tab) report this entrypoint;
    # route them to the Claude Desktop pill instead of dropping them (no VS Code terminal).
    if not payload.get('coucou_agent') and os.environ.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-desktop':
        payload['coucou_agent'] = 'claude-desktop'

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    # JetBrains terminals set TERMINAL_EMULATOR=JetBrains-JediTerm (no TERM_PROGRAM)
    payload.setdefault('terminal_emulator', env.get('TERMINAL_EMULATOR', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if agent == 'hermes':
                    hermes_choice = 'once' if decision == 'allow' else decision
                    if hermes_choice in ('once', 'always', 'deny'):
                        sys.stdout.write(json.dumps({'choice': hermes_choice}) + '\\n')
                        sys.stdout.flush()
                    sys.exit(0)
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        # Hermes: no output → json.loads raises in plugin → transport_fallback: builtin activates
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Antigravity needs a decision on PreToolUse ({} reads as a denial). "ask" keeps its own
    # permission prompt (and the user's Always Allow); Coucou never allows a tool by itself.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""
}

// MARK: - Agent plugins

/// The hook path as a single-quoted JavaScript/Python string literal body.
private func singleQuotedLiteralBody(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
}

/// ~/.config/opencode/plugins/coucou.js
func openCodePluginSource(hookPath: String) -> String {
    let path = singleQuotedLiteralBody(hookPath)
    return """
// Coucou hook plugin for OpenCode — generated by Coucou.app
// Forwards every event to the Coucou notch (fire-and-forget, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';
const EVENT_MAP = {
  'session.created': 'SessionStart',
  'session.idle': 'Stop',
  'session.error': 'StopFailure',
  'session.deleted': 'SessionEnd',
  'permission.asked': 'PermissionRequest',
};

function forward(hook_event_name, payload) {
  const p = spawn('/bin/sh', [HOOK, '--agent', 'opencode'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  p.stdin.on('error', () => {});
  p.stdin.write(JSON.stringify({ hook_event_name, ...payload }) + '\\n');
  p.stdin.end();
  p.unref();
}

export const CoucouPlugin = async (_ctx) => ({
  event: async ({ event }) => {
    const hook_event_name = EVENT_MAP[event.type];
    if (!hook_event_name) return;
    const props = event.properties || {};
    const payload = {
      session_id: event.sessionID || event.session_id || props.sessionID || props.session_id || '',
      cwd: event.cwd || event.directory || props.cwd || props.directory || '',
    };
    if (typeof props.tool === 'string') payload.tool_name = props.tool;
    if (props.input != null) payload.tool_input = props.input;
    forward(hook_event_name, payload);
  },
  'tool.execute.before': async (input) => {
    forward('PreToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
      tool_input: input.input ?? null,
    });
  },
  'tool.execute.after': async (input, _output) => {
    forward('PostToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
    });
  },
});
"""
}

/// ~/.config/amp/plugins/coucou.ts
func ampPluginSource(hookPath: String) -> String {
    let path = singleQuotedLiteralBody(hookPath)
    return """
// Coucou hook plugin for Amp — generated by Coucou.app
// Forwards every event to the Coucou notch (display only, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';

function forward(event_name: string, fields: Record<string, unknown>): void {
  const payload = JSON.stringify({ hook_event_name: event_name, ...fields });
  const p = spawn('/bin/sh', [HOOK, '--agent', 'amp'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  (p.stdin as import('node:stream').Writable).on('error', () => {});
  (p.stdin as import('node:stream').Writable).write(payload + '\\n');
  (p.stdin as import('node:stream').Writable).end();
  p.unref();
}

export default function (amp: any): void {
  amp.on('session.start', (e: any) => { forward('SessionStart',     { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.start',   (e: any) => { forward('UserPromptSubmit', { session_id: e.thread?.id ?? '' }); });
  amp.on('tool.call',     (e: any) => { try { forward('PreToolUse', { session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '' }); } finally { return { action: 'allow' }; } });
  amp.on('tool.result',   (e: any) => { forward('PostToolUse',      { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.end',     (e: any) => { forward('Stop',             { session_id: e.thread?.id ?? '' }); });
}
"""
}

/// ~/.hermes/plugins/coucou/__init__.py
func hermesPluginSource(hookPath: String) -> String {
    let path = singleQuotedLiteralBody(hookPath)
    return """
# Coucou hook plugin for Hermes Agent — generated by Coucou.app
# Session/tool events → Coucou notch (fire-and-forget, never blocks).
# Approval transport: uses register_approval_transport when available (future Hermes),
# falls back to pre_approval_request observer-only hook (hermes 0.15.x).
import json, subprocess, threading
from pathlib import Path

HOOK = Path('\(path)')
_lock = threading.Lock()
# Maps session_id → metadata dict. Keeps correct session when multiple
# sessions run concurrently (gateway mode). _current_session_id is kept as
# a last-seen fallback for hooks that don't supply a session_id.
_sessions: dict = {}
_current_session_id = ''


def _fire(fields: dict) -> None:
    \"\"\"Non-blocking: spawn nb-hook and return immediately. Reaps child to avoid zombies.\"\"\"
    def _run() -> None:
        try:
            p = subprocess.Popen(
                [str(HOOK), '--agent', 'hermes'],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,   # detach from process group
            )
            p.stdin.write(json.dumps(fields).encode() + b'\\n')
            p.stdin.close()
            p.wait(timeout=5)             # reap; 5s >> the 0.3s socket timeout
        except Exception:
            pass
    threading.Thread(target=_run, daemon=True).start()


def register(ctx) -> None:
    def on_session_start(**kwargs) -> None:
        global _current_session_id
        sid = kwargs.get('session_id', '')
        meta = {
            'model': kwargs.get('model', ''),
            'platform': kwargs.get('platform', 'cli') or 'cli',
        }
        with _lock:
            _sessions[sid] = meta
            _current_session_id = sid
        _fire({'hook_event_name': 'SessionStart', 'session_id': sid, 'platform': meta['platform']})

    def on_session_end(**kwargs) -> None:
        sid = kwargs.get('session_id', '')
        with _lock:
            _sessions.pop(sid, None)
        # Stop is sent by post_llm_call (which has the last assistant message).
        # Only send StopFailure here when the session was interrupted abnormally.
        if kwargs.get('interrupted'):
            _fire({'hook_event_name': 'StopFailure', 'session_id': sid})

    def post_llm_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        response = kwargs.get('assistant_response', '')
        _fire({
            'hook_event_name': 'Stop',
            'session_id': sid,
            'last_assistant_message': response,
        })

    def pre_tool_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        _fire({
            'hook_event_name': 'PreToolUse',
            'session_id': sid,
            'tool_name': kwargs.get('tool_name', ''),
            'tool_input': kwargs.get('args') or {},
        })

    def post_tool_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        _fire({
            'hook_event_name': 'PostToolUse',
            'session_id': sid,
            'tool_name': kwargs.get('tool_name', ''),
        })

    ctx.register_hook('on_session_start', on_session_start)
    ctx.register_hook('on_session_end',   on_session_end)
    ctx.register_hook('post_llm_call',    post_llm_call)
    ctx.register_hook('pre_tool_call',    pre_tool_call)
    ctx.register_hook('post_tool_call',   post_tool_call)

    if hasattr(ctx, 'register_approval_transport'):
        # Hermes version supports transport API — Coucou shows a real Allow/Deny card
        # and returns the user's choice to Hermes.
        def _present(request) -> object:
            sid = (getattr(request, 'session_id', None)
                   or getattr(request, 'session_key', None)
                   or _current_session_id)
            cmd     = getattr(request, 'command', '')
            desc    = getattr(request, 'description', '')
            timeout = getattr(request, 'timeout_seconds',
                              getattr(request, 'timeout', 30.0))
            allowed = list(getattr(request, 'allowed_choices', ('once', 'deny')))

            payload = json.dumps({
                'hook_event_name': 'PermissionRequest',
                'session_id': sid,
                'coucou_agent': 'hermes',
                'coucou_has_transport': True,
                'tool_name': cmd,
                'tool_input': {'command': cmd, 'description': desc},
            }).encode()
            try:
                result = subprocess.run(
                    [str(HOOK), '--agent', 'hermes'],
                    input=payload,
                    capture_output=True,
                    timeout=max(1.0, float(timeout) - 2.0),
                )
                data   = json.loads(result.stdout)
                choice = data['choice']
                if choice not in allowed:
                    raise ValueError(f'invalid choice: {choice!r}')
                return request.respond(choice)
            except Exception:
                # Fall back to Hermes' native prompt on any error (Coucou closed, no answer,
                # dismissed card, unexpected output). Hermes treats a transport that raises
                # as failed and, with `transport_fallback: builtin` (which Coucou writes into
                # config.yaml with `transport: coucou`), shows its own prompt. Returning
                # respond('deny') instead would be a real decision: the command would be
                # blocked every time Coucou cannot answer.
                raise

        ctx.register_approval_transport('coucou', _present)
    else:
        # Observer-only hook (hermes 0.15.x): Hermes still controls the decision.
        # Fire a PreToolUse-style step so the notch shows "⏳ Approval pending in Hermes"
        # in the step list without displaying a fake Allow/Deny card.
        def pre_approval_request(**kwargs) -> None:
            sid = kwargs.get('session_key', '') or _current_session_id
            _fire({
                'hook_event_name': 'PreToolUse',
                'session_id': sid,
                'tool_name': '⏳ Approval pending in Hermes',
                'tool_input': {
                    'command': kwargs.get('command', ''),
                    'description': kwargs.get('description', ''),
                },
            })

        ctx.register_hook('pre_approval_request', pre_approval_request)
"""
}

/// ~/.hermes/plugins/coucou/plugin.yaml
let hermesPluginYaml = """
name: coucou
version: "1.0"
description: Coucou notch integration — generated by Coucou.app
"""
