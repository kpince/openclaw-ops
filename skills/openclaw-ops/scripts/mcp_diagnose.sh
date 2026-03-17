#!/usr/bin/env bash
set -euo pipefail

MCP_CONFIG="/root/.openclaw/mcp.json"
MCP_URL="http://127.0.0.1:8750/mcp"
VAULT="${1:-codex-agent}"

print_line() {
  printf '%s\n' "------------------------------------------------------------"
}

get_auth_header() {
  node -e '
const fs = require("fs");
const p = process.argv[1];
const data = JSON.parse(fs.readFileSync(p, "utf8"));
const h = data?.mcpServers?.muninn?.headers?.Authorization || "";
process.stdout.write(h);
' "$MCP_CONFIG"
}

mask_token() {
  local raw="$1"
  local token="${raw#Bearer }"
  if [[ ${#token} -lt 10 ]]; then
    echo "Bearer [masked]"
    return
  fi
  echo "Bearer ${token:0:6}...${token: -4}"
}

echo "OpenClaw MCP Diagnose"
print_line

echo "config: $MCP_CONFIG"
if [[ ! -f "$MCP_CONFIG" ]]; then
  echo "ERROR: missing mcp config"
  exit 1
fi

auth_header="$(get_auth_header)"
if [[ -z "$auth_header" ]]; then
  echo "ERROR: missing Authorization header in mcp config"
  exit 1
fi

echo "url: $MCP_URL"
echo "auth: $(mask_token "$auth_header")"
print_line

echo "1) codex-muninn helper"
set +e
codex-muninn status --vault "$VAULT"
helper_rc=$?
set -e
echo "helper_exit=$helper_rc"
print_line

echo "2) direct MCP POST"
payload='{"jsonrpc":"2.0","id":"diag-where-left-off","method":"tools/call","params":{"name":"muninn_where_left_off","arguments":{"vault":"'"$VAULT"'","limit":2}}}'
set +e
direct_out="$(curl -sS --max-time 4 "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $auth_header" \
  --data "$payload" 2>&1)"
direct_rc=$?
set -e

echo "$direct_out"
echo "direct_exit=$direct_rc"
print_line

echo "3) interpretation"
if [[ $helper_rc -eq 0 && $direct_rc -eq 0 ]]; then
  echo "MCP reachable and healthy from current environment."
elif [[ $helper_rc -ne 0 && $direct_rc -ne 0 ]]; then
  echo "MCP unreachable from current environment (possible sandbox isolation or service/network issue)."
  echo "If available, run host-level checks with escalation:"
  echo "  systemctl status muninndb.service --no-pager -n 80"
else
  echo "Partial failure: helper and direct MCP disagree; verify helper config and vault arguments."
fi
