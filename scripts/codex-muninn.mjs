#!/usr/bin/env bash
set -euo pipefail

MCP_CONFIG="${MUNINN_MCP_CONFIG:-$HOME/.openclaw/mcp.json}"
SERVER_NAME="${MUNINN_MCP_SERVER:-muninn}"
DEFAULT_VAULT="${CODEX_MUNINN_VAULT:-codex}"

usage() {
  cat <<EOF
codex-muninn

Usage:
  codex-muninn status [--vault codex]
  codex-muninn where-left-off [--vault codex] [--limit 5]
  codex-muninn recall [--vault codex] [--mode balanced] [--limit 5] <query...>
  codex-muninn remember [--vault codex] [--type fact] [--concept text] [--summary text] [--tag key] <content...>
EOF
}

json_field() {
  local field="$1"
  node -e '
const fs = require("fs");
const input = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const server = input?.mcpServers?.[process.argv[2]];
if (!server) process.exit(2);
const value = server[process.argv[3]];
if (typeof value === "string") process.stdout.write(value);
else process.stdout.write(JSON.stringify(value || {}));
' "$MCP_CONFIG" "$SERVER_NAME" "$field"
}

extract_text() {
  node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8");
if (!raw.trim()) {
  console.error("Empty response from MCP server");
  process.exit(1);
}
const payload = JSON.parse(raw);
if (payload.error) {
  console.error(payload.error.message || JSON.stringify(payload.error));
  process.exit(1);
}
const texts = (payload.result?.content || [])
  .map((entry) => typeof entry?.text === "string" ? entry.text : "")
  .filter(Boolean);
if (texts.length > 0) {
  process.stdout.write(texts.join("\n"));
} else {
  process.stdout.write(JSON.stringify(payload.result ?? payload, null, 2));
}
'
}

call_tool() {
  local name="$1"
  local args_json="$2"
  local url headers
  url="$(json_field url)"
  url="${url/localhost/127.0.0.1}"
  headers="$(json_field headers)"
  local auth_header payload
  auth_header="$(node -e '
const headers = JSON.parse(process.argv[1]);
process.stdout.write(headers.Authorization || "");
' "$headers")"
  payload="$(node -e '
const payload = {
  jsonrpc: "2.0",
  id: `codex-muninn-${Date.now()}`,
  method: "tools/call",
  params: {
    name: process.argv[1],
    arguments: JSON.parse(process.argv[2]),
  },
};
process.stdout.write(JSON.stringify(payload));
' "$name" "$args_json")"
  curl -fsS "$url" \
    -H "Content-Type: application/json" \
    -H "Authorization: ${auth_header}" \
    --data "$payload" | extract_text
}

command="${1:-}"
if [[ -z "$command" || "$command" == "help" || "$command" == "--help" ]]; then
  usage
  exit 0
fi
shift

vault="$DEFAULT_VAULT"
limit=""
mode="balanced"
type="fact"
concept=""
summary=""
tags=()
positionals=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) vault="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --concept) concept="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --tag) tags+=("$2"); shift 2 ;;
    *) positionals+=("$1"); shift ;;
  esac
done

case "$command" in
  status)
    call_tool "muninn_status" "$(node -e 'process.stdout.write(JSON.stringify({ vault: process.argv[1] }))' "$vault")"
    ;;
  where-left-off)
    call_tool "muninn_where_left_off" "$(node -e 'process.stdout.write(JSON.stringify({ vault: process.argv[1], limit: Number(process.argv[2] || 5) }))' "$vault" "${limit:-5}")"
    ;;
  recall)
    if [[ ${#positionals[@]} -eq 0 ]]; then
      echo "codex-muninn: recall requires a query" >&2
      exit 1
    fi
    call_tool "muninn_recall" "$(node -e 'process.stdout.write(JSON.stringify({ vault: process.argv[1], context: [process.argv[2]], mode: process.argv[3], limit: Number(process.argv[4] || 5) }))' "$vault" "${positionals[*]}" "$mode" "${limit:-5}")"
    ;;
  remember)
    if [[ ${#positionals[@]} -eq 0 ]]; then
      echo "codex-muninn: remember requires content" >&2
      exit 1
    fi
    call_tool "muninn_remember" "$(node -e '
const tags = process.argv.slice(6);
const payload = {
  vault: process.argv[1],
  type: process.argv[2],
  concept: process.argv[3] || undefined,
  summary: process.argv[4] || undefined,
  content: process.argv[5],
  tags: tags.length > 0 ? tags : undefined,
};
process.stdout.write(JSON.stringify(payload));
' "$vault" "$type" "$concept" "$summary" "${positionals[*]}" "${tags[@]}")"
    ;;
  *)
    echo "codex-muninn: unknown command: $command" >&2
    exit 1
    ;;
esac
