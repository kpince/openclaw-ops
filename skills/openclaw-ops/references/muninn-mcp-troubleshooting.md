# Muninn MCP Troubleshooting

## Quick Triage
1. Verify helper path.
```bash
command -v codex-muninn
```

2. Run helper checks.
```bash
cd /root/.openclaw/workspace
codex-muninn status --vault codex-agent
codex-muninn where-left-off --vault codex-agent --limit 5
```

3. Probe direct MCP endpoint with token from `/root/.openclaw/mcp.json`.
- URL is expected to be `http://127.0.0.1:8750/mcp`.
- Connection refused or timeout from sandbox can indicate isolation, not outage.

## Host-Level Verification (Escalated)
If sandbox checks fail, verify service state outside sandbox:
```bash
systemctl status muninndb.service --no-pager -n 80
```

Expected healthy indicators:
- `Active: active (running)`
- log line similar to `mcp listening addr=127.0.0.1:8750`

## Root Cause Labels
Use one label in the summary:
- `sandbox-isolation`: host service healthy; sandbox cannot reach loopback MCP.
- `service-down`: `muninndb.service` not active or crash loop.
- `config-error`: missing/invalid `~/.openclaw/mcp.json` values.
- `auth-error`: endpoint reachable but authorization rejected.

## Recovery Actions
1. Sandbox isolation: rerun key checks with escalation when host verification is required.
2. Service down: restart/fix `muninndb.service` then rerun helper checks.
3. Config/auth issue: correct `mcp.json` server URL/header and retry.
