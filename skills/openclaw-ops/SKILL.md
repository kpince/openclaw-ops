---
name: openclaw-ops
description: OpenClaw workspace operations for session bootstrap and Muninn/MCP troubleshooting. Use when initializing a new session, loading `/root/codex.init` and workspace continuity files, checking `codex-muninn` status, diagnosing MCP connectivity failures (`127.0.0.1:8750`), or producing a concise root-cause summary with safe escalation.
---

# OpenClaw Ops

## Overview
Use this skill to run a repeatable OpenClaw startup flow and troubleshoot Muninn/MCP connectivity issues without guesswork.

## Workflow
1. Confirm baseline context.
- Read `/root/codex.init`.
- Read `/root/.openclaw/workspace/AGENTS.md`, `SOUL.md`, `USER.md`.
- In main session, also read `/root/.openclaw/workspace/MEMORY.md`.
- Read daily notes from `/root/.openclaw/workspace/memory/` for today and yesterday when present.

2. Run startup checks.
- From `/root/.openclaw/workspace`, run:
  - `codex-muninn status --vault codex-agent`
  - `codex-muninn where-left-off --vault codex-agent --limit 5`
- If helper calls fail with connection errors, continue with diagnostics before concluding service outage.

3. Diagnose MCP connectivity.
- Use `scripts/mcp_diagnose.sh` for a structured report.
- Treat sandbox-only failures as environment constraints unless host-level checks (with escalation) also fail.
- When escalation is allowed, verify host service state (`systemctl status muninndb.service`) and rerun `codex-muninn`.

4. Report clearly.
- State what was checked, what succeeded, and what failed.
- Distinguish:
  - sandbox isolation issue
  - service down/crashed
  - wrong config/token/path
- Provide next actions with exact commands.

## Commands
- Full bootstrap:
```bash
scripts/session_bootstrap.sh
```

- Focused MCP diagnosis:
```bash
scripts/mcp_diagnose.sh
```

## Output Contract
When using this skill, produce a compact status block:
- `Context`: loaded files and vault target
- `Connectivity`: `codex-muninn` + direct MCP checks
- `Service`: host service state if escalated
- `Root cause`: one sentence
- `Next actions`: numbered commands

## References
- Use `references/muninn-mcp-troubleshooting.md` for command-level triage and expected outcomes.
