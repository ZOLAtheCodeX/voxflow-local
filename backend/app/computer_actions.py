"""Deterministic action registry. Standalone stdlib process; no server or model.

The signed macOS app applies the prepared operation after checking capture
cancellation, local preferences, and the target. This process has no OS effects.
Future planners must use this same registry, never generate executable code.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys

VERSION = 1
MAX_REQUEST_BYTES = 4096
ALLOWED_APPLICATIONS = frozenset({
    "com.apple.finder", "com.apple.Safari", "com.apple.Terminal",
    "com.apple.Notes", "com.apple.calculator",
})
ALLOWED_SHORTCUTS = frozenset({
    "copy", "paste", "selectAll", "undo", "redo", "find", "newTab",
})


def load_registry(path: Path | None = None) -> dict[str, dict]:
    document = json.loads((path or Path(__file__).with_suffix(".json")).read_text())
    if type(document) is not dict or set(document) != {"version", "actions"}:
        raise ValueError("Invalid action registry")
    if type(document["version"]) is not int or document["version"] != VERSION:
        raise ValueError("Unsupported registry version")
    if type(document["actions"]) is not list or len(document["actions"]) > 100:
        raise ValueError("Invalid action list")
    actions = {}
    phrases = set()
    for action in document["actions"]:
        if type(action) is not dict or set(action) != {"id", "name", "phrases", "operation", "argument"}:
            raise ValueError("Invalid action entry")
        for key in ("id", "name", "operation", "argument"):
            value = action[key]
            if type(value) is not str or not value or len(value) > 128 or any(ord(c) < 32 for c in value):
                raise ValueError("Invalid action value")
        if action["id"] in actions:
            raise ValueError("Duplicate action ID")
        if type(action["phrases"]) is not list or not 1 <= len(action["phrases"]) <= 20:
            raise ValueError("Invalid action phrases")
        for phrase in action["phrases"]:
            if type(phrase) is not str or not phrase or len(phrase) > 128 or phrase != phrase.strip().lower():
                raise ValueError("Invalid action phrase")
            if not all(c.isascii() and (c.isalpha() or c == " ") for c in phrase) or phrase in phrases:
                raise ValueError("Invalid or ambiguous action phrase")
            phrases.add(phrase)
        allowed = {"openApplication": ALLOWED_APPLICATIONS, "shortcut": ALLOWED_SHORTCUTS}
        if action["argument"] not in allowed.get(action["operation"], ()):
            raise ValueError("Unregistered computer operation")
        actions[action["id"]] = action
    return actions


def prepare(request: object, registry: dict[str, dict] | None = None) -> dict:
    if type(request) is not dict or set(request) != {"version", "action_id"}:
        raise ValueError("Expected version and action_id only")
    if type(request["version"]) is not int or request["version"] != VERSION:
        raise ValueError("Unsupported action version")
    action_id = request["action_id"]
    if type(action_id) is not str or len(action_id) > 128:
        raise ValueError("Invalid action ID")
    action = (registry if registry is not None else load_registry()).get(action_id)
    if action is None:
        raise ValueError("Unknown computer action")
    return {"version": VERSION, "id": action_id,
            "operation": action["operation"], "argument": action["argument"]}


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
        if len(raw) > MAX_REQUEST_BYTES:
            raise ValueError("Action request too large")
        result = prepare(json.loads(raw))
    except (ValueError, OSError, TypeError, KeyError):
        # Keep arbitrary input and local paths out of the response/log.
        print(json.dumps({"error": "Computer action could not be prepared"}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
