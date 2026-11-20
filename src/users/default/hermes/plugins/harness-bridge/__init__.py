"""Harness bridge — remote control for the coding harnesses nucleus provisions.

The Hermes gateway already owns the messaging platforms (Telegram, ntfy, …),
their credentials and their allowlists.  This plugin adds the missing other half:
deterministic slash commands that act on the *coding harnesses* (pi, opencode,
Cursor, VS Code Copilot Chat) running on this machine, without involving the
agent or an LLM turn.

Commands (available in CLI and gateway sessions alike):

    /harness status              pending approval requests across harnesses
    /harness approve <id>        allow a pending request
    /harness deny <id>           deny a pending request
    /harness send <harness> <t>  queue a prompt for a harness session
    /harness sessions            per-harness activity summary
    /harness help                command list

State lives under the nucleus user root (``<root>/state/harness-bridge``):

    requests/<id>.json    written by a harness adapter when it needs a decision
    responses/<id>.json   written by /harness approve|deny, read by the adapter
    commands/<harness>/   written by /harness send, read by the harness adapter

The adapter side is a hook in each harness plus the shared
``harness-notify``/``harness-approval`` scripts; the plugin never talks to a
harness process directly, so a harness that is not running simply leaves its
requests unanswered and the adapter falls back to asking locally.
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

COMMAND_NAME = "harness"

# Stale-request housekeeping deliberately lives in the writer/consumer rather
# than here: harness-approval sweeps entries older than four times its approval
# window and removes its own request once it is answered or times out, so the
# plugin has nothing to expire and must not grow a second, drifting lifetime.

_HELP_TEXT = """Harness bridge

/harness status                pending approval requests
/harness approve <id>          allow a pending request
/harness deny <id>             deny a pending request
/harness send <harness> <text> queue a prompt for a harness session
/harness prompts [index]       list queued prompts, or copy prompt <index>
/harness sessions              per-harness activity summary
/harness help                  this text"""


def _nucleus_user_root() -> Path:
    """Nucleus user root for this platform, mirroring the documented layout."""
    system = platform.system()
    if system == "Darwin":
        return Path.home() / "Library" / "Application Support" / "nucleus"
    if system == "Windows":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            return Path(local_app_data) / "nucleus"
        return Path.home() / "AppData" / "Local" / "nucleus"
    return Path.home() / ".local" / "share" / "nucleus"


def _state_dir() -> Path:
    return _nucleus_user_root() / "state" / "harness-bridge"


def _requests_dir() -> Path:
    return _state_dir() / "requests"


def _responses_dir() -> Path:
    return _state_dir() / "responses"


def _commands_dir() -> Path:
    return _state_dir() / "commands"


def _read_json(path: Path) -> Optional[Dict[str, Any]]:
    """Read a JSON object, or None when the file is absent or unreadable."""
    try:
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, indent=2)
        handle.write("\n")
    tmp.replace(path)


def _pending_requests() -> List[Dict[str, Any]]:
    """Requests that have no response yet, newest last."""
    pending: List[Dict[str, Any]] = []
    if not _requests_dir().is_dir():
        return pending
    for path in sorted(_requests_dir().glob("*.json")):
        request = _read_json(path)
        if request is None:
            continue
        request_id = str(request.get("id", path.stem))
        if (_responses_dir() / f"{request_id}.json").exists():
            continue
        pending.append(request)
    return pending


def _describe(request: Dict[str, Any]) -> str:
    harness = request.get("harness", "?")
    tool = request.get("tool", "?")
    summary = request.get("summary", "")
    age = int(max(0, time.time() - float(request.get("created_at", 0))))
    line = f"{request.get('id', '?')}  {harness}  {tool}  {age}s ago"
    return f"{line}\n    {summary}" if summary else line


def _cmd_status() -> str:
    pending = _pending_requests()
    if not pending:
        return "No pending harness approvals."
    return "Pending harness approvals:\n" + "\n".join(_describe(item) for item in pending)


def _cmd_sessions() -> str:
    """Activity summary per harness, derived from the request store."""
    seen: Dict[str, Dict[str, Any]] = {}
    if _requests_dir().is_dir():
        for path in sorted(_requests_dir().glob("*.json")):
            request = _read_json(path)
            if request is None:
                continue
            harness = str(request.get("harness", "?"))
            created = float(request.get("created_at", 0))
            entry = seen.setdefault(harness, {"count": 0, "last": 0.0})
            entry["count"] += 1
            entry["last"] = max(entry["last"], created)
    if not seen:
        return "No harness activity recorded yet."
    now = time.time()
    lines = [
        f"{harness}: {entry['count']} request(s), last {int(max(0, now - entry['last']))}s ago"
        for harness, entry in sorted(seen.items())
    ]
    return "Harness activity:\n" + "\n".join(lines)


def _cmd_decide(args: List[str], decision: str) -> str:
    if not args:
        return f"Usage: /{COMMAND_NAME} {'approve' if decision == 'allow' else 'deny'} <id>"
    request_id = args[0]
    pending = {str(item.get("id", "")): item for item in _pending_requests()}
    if request_id not in pending:
        return f"No pending request '{request_id}'."
    _write_json(
        _responses_dir() / f"{request_id}.json",
        {
            "decision": decision,
            "decided_by": "chat",
            "decided_at": time.time(),
        },
    )
    request = pending[request_id]
    return f"{decision} — {request.get('harness', '?')} {request.get('tool', '?')} ({request_id})"


def _cmd_send(args: List[str]) -> str:
    if len(args) < 2:
        return f"Usage: /{COMMAND_NAME} send <harness> <text>"
    harness = args[0].lower()
    text = " ".join(args[1:])
    command_id = uuid.uuid4().hex[:8]
    _write_json(
        _commands_dir() / harness / f"{int(time.time())}-{command_id}.json",
        {
            "id": command_id,
            "harness": harness,
            "text": text,
            "created_at": time.time(),
            "source": "chat",
        },
    )
    return f"Queued for {harness} ({command_id}): {text}"


def _queued_prompts(harness: str = "hermes") -> List[Dict[str, Any]]:
    """Queued bridge prompts for a harness, newest first. Never consumes files."""
    directory = _commands_dir() / harness
    if not directory.is_dir():
        return []
    prompts: List[Dict[str, Any]] = []
    for path in directory.glob("*.json"):
        payload = _read_json(path)
        if payload is None:
            continue
        text = payload.get("text")
        if not isinstance(text, str):
            continue
        text = text.strip()
        if text == "":
            continue
        created = payload.get("created_at")
        if not isinstance(created, (int, float)):
            try:
                created = path.stat().st_mtime
            except OSError:
                created = 0.0
        prompts.append({"text": text, "created_at": float(created), "name": path.name})
    prompts.sort(key=lambda item: (item["created_at"], item["name"]), reverse=True)
    return prompts


def _format_prompts(prompts: List[Dict[str, Any]]) -> str:
    lines = [f"{index}. queued · {item['text']}" for index, item in enumerate(prompts, start=1)]
    if not lines:
        lines.append("No queued prompts.")
    lines.append("Sent history unavailable: Hermes plugin cannot read message history.")
    return "\n".join(lines)


def _copy_with_harness_clipboard(text: str) -> bool:
    command = os.environ.get("NUCLEUS_HARNESS_CLIPBOARD") or "harness-clipboard"
    try:
        subprocess.run(
            [command],
            input=text,
            text=True,
            check=True,
            timeout=5,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def _cmd_prompts(args: List[str]) -> str:
    prompts = _queued_prompts("hermes")
    if not args:
        return _format_prompts(prompts)
    raw = args[0].strip()
    if not raw.isdigit():
        return f'Invalid index "{raw}". Enter a number from 1 to {len(prompts) or 1}.'
    index = int(raw)
    if index < 1 or index > len(prompts):
        return f"Index {index} out of range. Enter a number from 1 to {len(prompts) or 1}."
    choice = prompts[index - 1]
    if _copy_with_harness_clipboard(choice["text"]):
        return f"Copied queued prompt to clipboard. ({choice['text']})"
    return f"Clipboard unavailable. Prompt:\n{choice['text']}"


def _record_sandbox_context_best_effort() -> None:
    """Best-effort sandbox-state recording so transitions seen by other harnesses
    are reported when Hermes is next used. Never raises and never affects command
    handling."""
    try:
        subprocess.run(
            ["nucleus-utils", "sandbox-context", "hermes", "--format", "check"],
            check=False,
            timeout=5,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def _handle_command(raw_args: str) -> str:
    """Dispatch one /harness invocation. Never raises: the gateway shows the text."""
    _record_sandbox_context_best_effort()
    args = (raw_args or "").split()
    if not args:
        return _HELP_TEXT
    subcommand = args[0].lower()
    rest = args[1:]
    if subcommand in {"help", "-h", "--help"}:
        return _HELP_TEXT
    if subcommand == "status":
        return _cmd_status()
    if subcommand == "sessions":
        return _cmd_sessions()
    if subcommand == "prompts":
        return _cmd_prompts(rest)
    if subcommand == "approve":
        return _cmd_decide(rest, "allow")
    if subcommand == "deny":
        return _cmd_decide(rest, "deny")
    if subcommand == "send":
        return _cmd_send(rest)
    return f"Unknown subcommand '{subcommand}'.\n\n{_HELP_TEXT}"


def register(ctx) -> None:
    """Called once by the plugin loader."""
    ctx.register_command(
        COMMAND_NAME,
        handler=_handle_command,
        description="Approve, deny, or redirect coding-harness sessions running on this machine.",
        args_hint="status|approve|deny|send|prompts|sessions",
    )
