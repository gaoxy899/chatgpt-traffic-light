#!/usr/bin/env python3
"""Merge only this app's hooks; never change hook trust or existing handlers."""
import argparse
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import tempfile
import time

MARKER = " # gpt-traffic-light"
EVENTS = (
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
    "PermissionRequest", "PostToolUse", "Stop", "Interrupt",
)


def configure(path, binary=None):
    original = json.loads(path.read_text()) if path.exists() else {"hooks": {}}
    updated = copy.deepcopy(original)
    hooks = updated.setdefault("hooks", {})
    for event, groups in list(hooks.items()):
        kept = []
        removed = False
        for group in groups:
            handlers = group.get("hooks", [])
            remaining = [h for h in handlers if not h.get("command", "").endswith(MARKER)]
            if len(remaining) == len(handlers):
                kept.append(group)
            elif remaining:
                removed = True
                group["hooks"] = remaining
                kept.append(group)
            else:
                removed = True
        if not removed:
            continue
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if binary is not None:
        # exec makes the native hook's parent the Codex runtime, not a short-lived shell.
        command = "exec " + shlex.quote(str(binary)) + " --codex-hook" + MARKER
        for event in EVENTS:
            hooks.setdefault(event, []).append({"hooks": [{
                "type": "command", "command": command, "timeout": 3,
            }]})
    if updated == original:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(path.name + ".traffic-light-backup-" + str(time.time_ns()))
        shutil.copy2(path, backup)
        print("已备份原 Codex hooks：", backup)
    fd, temporary = tempfile.mkstemp(prefix=".traffic-light-hooks-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(updated, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    if not args.remove and args.binary is None:
        parser.error("install requires --binary")
    codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    configure(args.config or codex_home / "hooks.json", None if args.remove else args.binary.resolve())


if __name__ == "__main__":
    main()
