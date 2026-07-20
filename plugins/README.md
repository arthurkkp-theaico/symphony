# Agent guardrail plugin demos

These installable Codex plugins simulate policy controls for agent tool use. They draw on the same
general ideas described in Uber's public agent-security architecture: tool-level policy checks,
redaction or quarantine, provenance, and auditability. They are independent demos and are not Uber
products or production security boundaries.

| Plugin | PreToolUse | PostToolUse |
| --- | --- | --- |
| `agent-guard-web` | Blocks supported web, browser, remote-search, and shell-network calls. | Quarantines results with common prompt-injection markers. |
| `agent-guard-secrets` | Blocks sensitive paths and credential-shaped tool arguments. | Quarantines results that appear to contain private keys or tokens. |
| `agent-guard-destructive` | Blocks destructive commands, edits, and tool names. | Quarantines results that report suspicious high-impact side effects. |

Each plugin writes one JSON object per decision to `$PLUGIN_DATA/audit.jsonl`. Audit entries contain
event metadata, rule IDs, and SHA-256 digests. They do not contain raw tool inputs or outputs.

## Install

From the repository root:

```sh
codex plugin marketplace add "$(pwd)"
codex plugin add agent-guard-web@personal
codex plugin add agent-guard-secrets@personal
codex plugin add agent-guard-destructive@personal
```

Open `/hooks` in Codex to inspect and trust each installed hook definition. Changed hook commands
must be reviewed again.

## Enforcement boundary

Codex lifecycle hooks cover Bash, `apply_patch`, MCP tools, and most local function tools. Hosted
tools such as `WebSearch` do not enter the local hook path. To remove hosted web search as an
enforcement boundary, pair `agent-guard-web` with this user or managed Codex setting:

```toml
web_search = "disabled"
```

Post-tool hooks run after a tool has produced output. They can quarantine that output and halt
normal processing, but they cannot undo side effects. Keep sandboxing, least-privilege credentials,
network policy, approvals, and managed hooks in place for production controls.

## Test

```sh
python3 -m unittest discover -s plugins/tests -v
```

## References

- [Codex lifecycle hooks](https://learn.chatgpt.com/docs/hooks)
- [Uber: Solving the Identity Crisis for AI Agents](https://www.uber.com/us/en/blog/solving-the-agent-identity-crisis/)
- [Uber: Superuser Gateway](https://www.uber.com/blog/superuser-gateway-guardrails/)
