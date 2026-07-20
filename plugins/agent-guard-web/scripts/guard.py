#!/usr/bin/env python3
"""Evaluate a Codex tool-hook event against this plugin's policy."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any


def compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def plugin_root() -> Path:
    configured = os.environ.get("PLUGIN_ROOT")
    return Path(configured) if configured else Path(__file__).resolve().parents[1]


def first_match(rules: list[dict[str, str]], tool_name: str, text: str) -> dict[str, str] | None:
    for rule in rules:
        if not re.search(rule.get("toolPattern", ".*"), tool_name, re.IGNORECASE):
            continue
        if re.search(rule["pattern"], text, re.IGNORECASE | re.DOTALL):
            return rule
    return None


def audit(payload: dict[str, Any], decision: str, rule_id: str | None) -> None:
    data_dir = os.environ.get("PLUGIN_DATA")
    if not data_dir:
        return

    tool_input = compact(payload.get("tool_input"))
    tool_response = compact(payload.get("tool_response"))
    record = {
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "event": payload.get("hook_event_name"),
        "sessionId": payload.get("session_id"),
        "turnId": payload.get("turn_id"),
        "toolName": payload.get("tool_name"),
        "decision": decision,
        "ruleId": rule_id,
        "inputSha256": digest(tool_input),
        "responseSha256": digest(tool_response),
    }
    try:
        destination = Path(data_dir)
        destination.mkdir(parents=True, exist_ok=True)
        with (destination / "audit.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(compact(record) + "\n")
    except OSError:
        pass


def deny_pretool(reason: str) -> None:
    print(compact({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def quarantine_posttool(reason: str) -> None:
    print(compact({
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": reason,
        },
    }))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        policy = json.loads((plugin_root() / "policy.json").read_text(encoding="utf-8"))
        event = payload.get("hook_event_name")
        tool_name = str(payload.get("tool_name", ""))

        if event == "PreToolUse":
            rule = first_match(policy.get("preToolRules", []), tool_name, tool_name)
            if rule is None:
                rule = first_match(policy.get("preInputRules", []), tool_name, compact(payload.get("tool_input")))
            if rule:
                audit(payload, "deny", rule["id"])
                deny_pretool(rule["reason"])
            else:
                audit(payload, "allow", None)
            return 0

        if event == "PostToolUse":
            rule = first_match(policy.get("postOutputRules", []), tool_name, compact(payload.get("tool_response")))
            if rule:
                audit(payload, "quarantine", rule["id"])
                quarantine_posttool(rule["reason"])
            else:
                audit(payload, "allow", None)
            return 0

        return 0
    except (AttributeError, KeyError, OSError, TypeError, ValueError, re.error) as exc:
        print(f"Agent Guard policy evaluation failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
