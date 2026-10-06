"""green-harness thin capture: a hook that appends one record per event to the repo journal.

No harness logic, no network, stdlib only: a digest of what happened, chained to the
previous record (REQ-022, b-318). Contract v1: docs/v1/UNIVERSAL.md in the harness repo.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

# CHOSEN (b-318): the journal contract version; the server refuses others as unmeasurable.
VERSION = 1
# CHOSEN: the prev of the first record, 64 zeros like the hex of a sha256.
GENESIS = "0" * 64
# CHOSEN: the repo's own namespace, apart from a user's ledger/ and the local .harness/.
CAPTURE_DIR = ".green-harness/capture"
# CHOSEN (b-318): the events that carry a session's start, prompts, tool calls and dialog.
EVENTS = ("SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure")
# MEASURED (harness constants, the local dialog hook): the tool that asks the user.
DIALOG_TOOL = "AskUserQuestion"
# MEASURED from the Claude Code binary: the response keys of the dialog; `options` UNVERIFIED.
DIALOG_KEYS = ("answers", "questions", "response")
# CHOSEN: a path or command naming this (journal, config, this script) is marked.
TOUCH_MARK = "green-harness/"
# CHOSEN: the input keys naming what a tool acts on; content and question text are not.
TOUCH_KEYS = ("file_path", "path", "notebook_path", "command")
# CHOSEN: only `git add`/`git commit` joined by `&&`, no other shell syntax: not marked.
GIT_ONLY = re.compile(r"git (?:add|commit)(?: [^;&|`$<>()\\\n\r]*)?"
                      r"(?: && git (?:add|commit)(?: [^;&|`$<>()\\\n\r]*)?)*")
# CHOSEN: hex characters of an input digest, as the server's provenance hashes.
INPUT_CHARS = 16


def canon(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def digest16(value) -> str:
    return hashlib.sha256(canon(value)).hexdigest()[:INPUT_CHARS]


def link(prev: str, body: dict) -> str:
    return hashlib.sha256(prev.encode() + b"\n" + canon(body)).hexdigest()


def session_file_name(raw: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]", "-", raw).strip("-")
    return name or "s-" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def touches(tool_input) -> bool:
    if not isinstance(tool_input, dict):
        return False
    for key in TOUCH_KEYS:
        value = tool_input.get(key)
        if not isinstance(value, str) or TOUCH_MARK not in value:
            continue
        if key == "command" and GIT_ONLY.fullmatch(value.strip()):
            continue
        return True
    return False


def record_of(payload: dict, env: dict, at: str) -> dict | None:
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    if event not in EVENTS or not isinstance(session, str) or not session:
        return None
    body = {"at": at, "session": session, "event": event}
    if event == "SessionStart":
        body["start"] = {"source": payload.get("source", ""),
                         "remote": env.get("CLAUDE_CODE_REMOTE") == "true"}
    elif event == "UserPromptSubmit":
        prompt = str(payload.get("prompt", ""))
        body["prompt"] = {"sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
                          "chars": len(prompt)}
    else:
        tool_input = payload.get("tool_input")
        body["tool"] = str(payload.get("tool_name", ""))
        body["use"] = str(payload.get("tool_use_id") or "")
        body["input"] = "" if tool_input is None else digest16(tool_input)
        body["touches"] = touches(tool_input)
        response = payload.get("tool_response")
        if body["tool"] == DIALOG_TOOL and isinstance(response, dict):
            body["dialog"] = {k: v for k, v in response.items() if k in DIALOG_KEYS}
    return body


def project_root(payload: dict, env: dict) -> Path | None:
    root = env.get("CLAUDE_PROJECT_DIR") or payload.get("cwd")
    return Path(root) if isinstance(root, str) and root else None


class BrokenJournal(Exception):
    pass


def _tail(handle) -> bytes:
    size = handle.seek(0, os.SEEK_END)
    start = size
    while start > 0:
        start = max(0, start - 65536)
        handle.seek(start)
        data = handle.read(size - start)
        cut = data.rstrip(b"\n").rfind(b"\n")
        if cut >= 0 or start == 0:
            return data[cut + 1:]
    return b""


def append(path: Path, body: dict) -> dict:
    """Append the record under an exclusive lock: parallel tool calls run hooks at once."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        last = _tail(handle)
        if not last:
            seq, prev = 1, GENESIS
        else:
            try:
                tail = json.loads(last)
                seq, prev = int(tail["seq"]) + 1, str(tail["chain"])
            except (ValueError, KeyError, TypeError) as err:
                raise BrokenJournal(f"{path}: the last line is not a record ({err})") from err
            if not last.endswith(b"\n"):
                raise BrokenJournal(f"{path}: the last line has no newline")
        record = {"v": VERSION, "seq": seq, **body, "prev": prev}
        record["chain"] = link(prev, record)
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        handle.seek(0, os.SEEK_END)
        handle.write(line.encode("utf-8"))
        handle.flush()
    return record


def capture(stdin: str, env: dict, at: str) -> str:
    try:
        payload = json.loads(stdin)
    except ValueError:
        return "green-harness capture: the hook payload is not JSON; nothing recorded"
    if not isinstance(payload, dict):
        return "green-harness capture: the hook payload is not an object; nothing recorded"
    body = record_of(payload, env, at)
    if body is None:
        return ""
    root = project_root(payload, env)
    if root is None:
        return "green-harness capture: no CLAUDE_PROJECT_DIR and no cwd; nothing recorded"
    path = root / CAPTURE_DIR / (session_file_name(body["session"]) + ".jsonl")
    try:
        append(path, body)
    except (BrokenJournal, OSError) as err:
        return f"green-harness capture: journal not appended: {err}"
    return ""


def main(stdin: str, env: dict, at: str = "") -> int:
    note = capture(stdin, env, at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    if note:
        print(note, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.stdin.read(), dict(os.environ)))
