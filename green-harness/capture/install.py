"""Install the green-harness thin capture into a repository; it never commits and never calls out.

    python3 install.py --repo <your repo> --binding <20 hex from the harness connector>

It copies capture.py to <repo>/.claude/green-harness/, merges hooks.json into
<repo>/.claude/settings.json under "hooks" (your own hooks stay; running it again adds
nothing), writes the binding to <repo>/.green-harness/config.json, and prints the git line
for you to commit. Python stdlib only.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ beside the published client
_SPEC = importlib.util.spec_from_file_location("green_harness_capture", HERE / "capture.py")
capture = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(capture)
SCRIPT = ".claude/green-harness/capture.py"
SETTINGS = ".claude/settings.json"
CONFIG = ".green-harness/config.json"
KEEP = capture.CAPTURE_DIR + "/.gitkeep"
# CHOSEN (b-318): 20 lowercase hex, 80 bits of the server's tenant binding.
BINDING = re.compile(r"[0-9a-f]{20}")


class InstallError(Exception):
    pass


def _commands(groups: list) -> set[str]:
    return {h.get("command") for g in groups if isinstance(g, dict)
            for h in g.get("hooks", []) if isinstance(h, dict)}


def merge(settings: dict, entries: dict) -> tuple[dict, int]:
    """Settings with our hook groups appended where their command is absent; and how many."""
    merged = copy.deepcopy(settings)
    hooks = merged.setdefault("hooks", {})
    added = 0
    for event, groups in entries.items():
        have = hooks.setdefault(event, [])
        for group in groups:
            if not _commands([group]) <= _commands(have):
                have.append(copy.deepcopy(group))
                added += 1
    return merged, added


def _settings(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as err:
        raise InstallError(f"{SETTINGS} is not valid JSON ({err}); nothing written") from err
    if not isinstance(data, dict):
        raise InstallError(f"{SETTINGS} is not a JSON object; nothing written")
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError(f'{SETTINGS}: "hooks" is not a JSON object; nothing written')
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise InstallError(f'{SETTINGS}: "hooks.{event}" is not a JSON list; '
                               "nothing written")
    return data


def _no_links(repo: Path) -> None:
    for relative in (SETTINGS, SCRIPT, CONFIG, KEEP):
        parts = Path(relative).parts
        for depth in range(1, len(parts) + 1):
            where = repo.joinpath(*parts[:depth])
            if where.is_symlink():
                raise InstallError(f"{where.relative_to(repo)} is a symbolic link; nothing "
                                   "written - the installer writes only inside the repo")


def _bound(path: Path, binding: str) -> None:
    if not path.exists():
        return
    try:
        old = json.loads(path.read_text(encoding="utf-8")).get("binding")
    except (ValueError, AttributeError):
        old = None
    if old != binding:
        raise InstallError(f"{CONFIG} is bound to {old!r}, not {binding!r}; remove it to rebind")


def install(repo: Path, binding: str) -> list[str]:
    if not BINDING.fullmatch(binding):
        raise InstallError("the binding must be 20 lowercase hex characters")
    _no_links(repo)
    settings = _settings(repo / SETTINGS)
    _bound(repo / CONFIG, binding)
    entries = json.loads((HERE / "hooks.json").read_text(encoding="utf-8"))["hooks"]
    merged, _ = merge(settings, entries)
    (repo / SCRIPT).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HERE / "capture.py", repo / SCRIPT)
    (repo / SETTINGS).write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    (repo / KEEP).parent.mkdir(parents=True, exist_ok=True)
    (repo / CONFIG).write_text(json.dumps({"v": capture.VERSION, "binding": binding},
                                          separators=(",", ":")) + "\n", encoding="utf-8")
    (repo / KEEP).touch()
    return [SETTINGS, SCRIPT, CONFIG, KEEP]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="install the green-harness thin capture")
    parser.add_argument("--repo", default=".", help="the repository root (default: here)")
    parser.add_argument("--binding", required=True, help="20 hex from install_instructions")
    args = parser.parse_args(argv)
    try:
        paths = install(Path(args.repo), args.binding)
    except InstallError as err:
        print(f"green-harness install: {err}", file=sys.stderr)
        return 2
    print("green-harness capture installed. Review and commit these files:")
    print("git add " + " ".join(paths) + ' && git commit -m "green-harness capture"')
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
