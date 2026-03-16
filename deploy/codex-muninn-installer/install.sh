#!/usr/bin/env bash
set -euo pipefail

CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
MUNINN_DIR="${MUNINN_DIR:-$HOME/.muninn}"
INIT_PATH="${INIT_PATH:-$HOME/init.md}"
VAULT_NAME="${MUNINN_VAULT:-codex}"
API_HOSTPORT="${MUNINN_API_HOSTPORT:-127.0.0.1:8475}"
MCP_ADDR="${MUNINN_MCP_ADDR:-127.0.0.1:8750}"
SKIP_MUNINN_INSTALL=0
SKIP_MUNINN_START=0
FORCE=0
VAULT_TOKEN="${MUNINN_TOKEN:-}"
MCP_TOKEN="${MUNINN_MCP_TOKEN:-}"

MEMORY_DIR=""
MUNINN_DATA_DIR=""
API_BASE_URL=""
MCP_URL=""

usage() {
  cat <<'USAGE'
Usage:
  bash install.sh [options]

Options:
  --codex-dir <path>          Codex config dir (default: ~/.codex)
  --muninn-dir <path>         Muninn home dir (default: ~/.muninn)
  --init-path <path>          init.md output path (default: ~/init.md)
  --vault <name>              Vault name (default: codex)
  --api-hostport <host:port>  Muninn API address (default: 127.0.0.1:8475)
  --mcp-addr <host:port>      Muninn MCP address (default: 127.0.0.1:8750)
  --mcp-token <token>         Reuse a specific MCP token
  --vault-token <token>       Reuse a specific vault API token
  --skip-muninn-install       Do not install muninn if missing
  --skip-muninn-start         Do not start or probe muninn
  --force                     Overwrite managed files without prompting
  --help                      Show this message
USAGE
}

log() {
  printf '[codex-muninn] %s\n' "$*"
}

die() {
  printf '[codex-muninn] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$path" "$backup"
    log "Backed up $path -> $backup"
  fi
}

random_token() {
  local prefix="$1"
  if command -v openssl >/dev/null 2>&1; then
    printf '%s%s\n' "$prefix" "$(openssl rand -hex 24)"
    return 0
  fi
  if command -v od >/dev/null 2>&1; then
    printf '%s%s\n' "$prefix" "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
    return 0
  fi
  die "Need openssl or od to generate random tokens"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --codex-dir)
        CODEX_DIR="$2"
        shift 2
        ;;
      --muninn-dir)
        MUNINN_DIR="$2"
        shift 2
        ;;
      --init-path)
        INIT_PATH="$2"
        shift 2
        ;;
      --vault)
        VAULT_NAME="$2"
        shift 2
        ;;
      --api-hostport)
        API_HOSTPORT="$2"
        shift 2
        ;;
      --mcp-addr)
        MCP_ADDR="$2"
        shift 2
        ;;
      --mcp-token)
        MCP_TOKEN="$2"
        shift 2
        ;;
      --vault-token)
        VAULT_TOKEN="$2"
        shift 2
        ;;
      --skip-muninn-install)
        SKIP_MUNINN_INSTALL=1
        shift
        ;;
      --skip-muninn-start)
        SKIP_MUNINN_START=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

set_derived_paths() {
  MEMORY_DIR="${CODEX_DIR%/}/memories"
  MUNINN_DATA_DIR="${MUNINN_DIR%/}/data"
  API_BASE_URL="http://${API_HOSTPORT}"
  MCP_URL="http://${MCP_ADDR}/mcp"
}

install_muninn_if_needed() {
  if command -v muninn >/dev/null 2>&1; then
    log "muninn already installed"
    return 0
  fi

  (( SKIP_MUNINN_INSTALL == 1 )) && die "muninn not found and --skip-muninn-install was set"

  need_cmd curl
  log "Installing muninn"
  curl -fsSL https://muninndb.com/install.sh | bash
  command -v muninn >/dev/null 2>&1 || die "muninn install completed but binary is still missing from PATH"
}

ensure_layout() {
  mkdir -p "$CODEX_DIR" "$MEMORY_DIR" "$MUNINN_DIR"
  chmod 700 "$CODEX_DIR" "$MEMORY_DIR" "$MUNINN_DIR"
}

ensure_mcp_token() {
  local token_file="${MUNINN_DIR%/}/mcp.token"
  if [[ -n "$MCP_TOKEN" ]]; then
    :
  elif [[ -f "$token_file" ]]; then
    MCP_TOKEN="$(tr -d '\r\n' < "$token_file")"
  else
    MCP_TOKEN="$(random_token 'mdb_')"
  fi

  printf '%s\n' "$MCP_TOKEN" > "$token_file"
  chmod 600 "$token_file"
}

muninn_reachable() {
  muninn vault list -h "$API_HOSTPORT" >/dev/null 2>&1
}

start_muninn_if_needed() {
  (( SKIP_MUNINN_START == 1 )) && return 0

  if muninn_reachable; then
    log "Muninn already reachable at ${API_HOSTPORT}"
    return 0
  fi

  log "Starting muninn"
  muninn start --data "$MUNINN_DATA_DIR" --mcp-token "$MCP_TOKEN"

  local i
  for i in $(seq 1 30); do
    if muninn_reachable; then
      log "Muninn is reachable"
      return 0
    fi
    sleep 1
  done

  die "Muninn did not become reachable at ${API_HOSTPORT}"
}

ensure_vault() {
  (( SKIP_MUNINN_START == 1 )) && return 0

  if muninn vault list -h "$API_HOSTPORT" | awk '{print $1}' | grep -Fxq "$VAULT_NAME"; then
    log "Vault ${VAULT_NAME} already exists"
    return 0
  fi

  log "Creating vault ${VAULT_NAME}"
  muninn vault create "$VAULT_NAME" -h "$API_HOSTPORT" >/dev/null
}

create_vault_token_if_needed() {
  if [[ -n "$VAULT_TOKEN" ]]; then
    return 0
  fi

  local env_file="${MEMORY_DIR%/}/.env"
  if [[ -f "$env_file" ]]; then
    local existing=""
    existing="$(sed -n 's/^MUNINN_TOKEN=//p' "$env_file" | head -n1)"
    if [[ -n "$existing" ]]; then
      VAULT_TOKEN="$existing"
      log "Reusing existing vault token from $env_file"
      return 0
    fi
  fi

  (( SKIP_MUNINN_START == 1 )) && die "No vault token available and --skip-muninn-start was set. Pass --vault-token."

  log "Creating vault API key for ${VAULT_NAME}"
  local output=""
  output="$(muninn api-key create --vault "$VAULT_NAME" --label codex-memory --mode full --expires 365d -h "$API_HOSTPORT" 2>&1)"
  VAULT_TOKEN="$(printf '%s\n' "$output" | grep -o 'mk_[A-Za-z0-9._-]*' | head -n1 || true)"
  [[ -n "$VAULT_TOKEN" ]] || die "Could not parse a vault token from muninn api-key output"
}

write_memory_env() {
  local path="${MEMORY_DIR%/}/.env"
  [[ -f "$path" && $FORCE -eq 0 ]] && backup_if_exists "$path"
  cat > "$path" <<EOF
MUNINN_BASE_URL=${API_BASE_URL}
MUNINN_TOKEN=${VAULT_TOKEN}
MUNINN_VAULT=${VAULT_NAME}
EOF
  chmod 600 "$path"
}

write_memory_readme() {
  local path="${MEMORY_DIR%/}/README.md"
  [[ -f "$path" && $FORCE -eq 0 ]] && backup_if_exists "$path"
  cat > "$path" <<EOF
# Codex Persistent Memory (Muninn-backed)

This folder stores Codex's own long-term memory integration.
It is intentionally separate from OpenClaw.

## Files

- ${MEMORY_DIR}/memory.sh
- ${MEMORY_DIR}/start-muninn.sh
- ${MEMORY_DIR}/.env

## Usage

\`\`\`bash
${MEMORY_DIR}/memory.sh health
${MEMORY_DIR}/memory.sh remember "user-preference" "Use concise, direct responses" 0.95
${MEMORY_DIR}/memory.sh recall "communication style" 20 balanced
${MEMORY_DIR}/memory.sh recall-flat "communication style" 20
${MEMORY_DIR}/memory.sh list 20 0
${MEMORY_DIR}/memory.sh get <engram_id>
\`\`\`
EOF
}

write_memory_script() {
  local path="${MEMORY_DIR%/}/memory.sh"
  [[ -f "$path" && $FORCE -eq 0 ]] && backup_if_exists "$path"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
MEMORY_DIR="${CODEX_HOME%/}/memories"
ENV_FILE="${MEMORY_DIR%/}/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

MUNINN_BASE_URL="${MUNINN_BASE_URL:-http://127.0.0.1:8475}"
MUNINN_TOKEN="${MUNINN_TOKEN:-}"
MUNINN_VAULT="${MUNINN_VAULT:-codex}"

BASE="${MUNINN_BASE_URL%/}"
if [[ "$BASE" == */api ]]; then
  API_BASE="$BASE"
else
  API_BASE="${BASE}/api"
fi

usage() {
  cat <<'USAGE'
Usage:
  memory.sh health
  memory.sh remember <concept> <content> [confidence]
  memory.sh recall <query> [limit] [mode]
  memory.sh recall-flat <query> [limit]
  memory.sh list [limit] [offset]
  memory.sh get <engram_id>
USAGE
}

require_token() {
  [[ -n "$MUNINN_TOKEN" ]] || {
    echo "Error: MUNINN_TOKEN is not set." >&2
    exit 1
  }
}

http() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "${API_BASE}${path}" \
      -H "Authorization: Bearer ${MUNINN_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sS -X "$method" "${API_BASE}${path}" \
      -H "Authorization: Bearer ${MUNINN_TOKEN}"
  fi
}

health() {
  curl -sS "${API_BASE%/api}/api/health" | jq .
}

remember() {
  require_token
  local concept="$1"
  local content="$2"
  local confidence="${3:-0.90}"
  local body
  body="$(jq -nc \
    --arg concept "$concept" \
    --arg content "$content" \
    --argjson confidence "$confidence" \
    '{concept:$concept, content:$content, confidence:$confidence, tags:["codex","persistent"]}')"
  http POST "/engrams?vault=${MUNINN_VAULT}" "$body" | jq .
}

recall_flat() {
  require_token
  local q="$1"
  local limit="${2:-50}"
  local fetch_limit=$((limit * 5))
  if (( fetch_limit < 50 )); then
    fetch_limit=50
  fi
  if (( fetch_limit > 500 )); then
    fetch_limit=500
  fi
  http GET "/engrams?vault=${MUNINN_VAULT}&limit=${fetch_limit}&offset=0" | \
    jq --arg q "$q" --argjson limit "$limit" '
      ($q | ascii_downcase) as $needle
      | .engrams
      | map(select((.concept + " " + .content + " " + (.tags | join(" "))) | ascii_downcase | contains($needle)))
      | .[:$limit]
      | {total_found:length, matches:.}'
}

recall() {
  require_token
  local q="$1"
  local limit="${2:-50}"
  local mode="${3:-balanced}"
  local body
  body="$(jq -nc \
    --arg q "$q" \
    --arg mode "$mode" \
    --argjson limit "$limit" \
    '{context:[$q], limit:$limit, mode:$mode}')"

  local resp=""
  resp="$(http POST "/activate?vault=${MUNINN_VAULT}" "$body" 2>/dev/null || true)"
  if jq -e '.activations' >/dev/null 2>&1 <<<"$resp"; then
    jq '{mode:"semantic", query_id:(.query_id // null), total_found:(.total_found // 0), matches:(.activations // [])}' <<<"$resp"
    return 0
  fi

  recall_flat "$q" "$limit" | jq '. + {mode:"flat-fallback"}'
}

list_engrams() {
  require_token
  local limit="${1:-20}"
  local offset="${2:-0}"
  http GET "/engrams?vault=${MUNINN_VAULT}&limit=${limit}&offset=${offset}" | jq .
}

get_engram() {
  require_token
  local id="$1"
  http GET "/engrams/${id}?vault=${MUNINN_VAULT}" | jq .
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    health)
      health
      ;;
    remember)
      [[ $# -lt 3 ]] && usage && exit 1
      shift
      remember "$1" "$2" "${3:-0.90}"
      ;;
    recall)
      [[ $# -lt 2 ]] && usage && exit 1
      shift
      recall "$1" "${2:-50}" "${3:-balanced}"
      ;;
    recall-flat)
      [[ $# -lt 2 ]] && usage && exit 1
      shift
      recall_flat "$1" "${2:-50}"
      ;;
    list)
      shift || true
      list_engrams "${1:-20}" "${2:-0}"
      ;;
    get)
      [[ $# -lt 2 ]] && usage && exit 1
      shift
      get_engram "$1"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
EOF
  chmod 755 "$path"
}

write_start_script() {
  local path="${MEMORY_DIR%/}/start-muninn.sh"
  [[ -f "$path" && $FORCE -eq 0 ]] && backup_if_exists "$path"
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

MUNINN_DIR="\${MUNINN_DIR:-${MUNINN_DIR}}"
MUNINN_DATA_DIR="\${MUNINN_DATA_DIR:-${MUNINN_DATA_DIR}}"
MCP_TOKEN_FILE="\${MCP_TOKEN_FILE:-\${MUNINN_DIR%/}/mcp.token}"

[[ -f "\$MCP_TOKEN_FILE" ]] || {
  echo "Missing MCP token file: \$MCP_TOKEN_FILE" >&2
  exit 1
}

exec muninn start --data "\$MUNINN_DATA_DIR" --mcp-token "\$(tr -d '\r\n' < "\$MCP_TOKEN_FILE")"
EOF
  chmod 755 "$path"
}

write_init_md() {
  local path="$INIT_PATH"
  [[ -f "$path" && $FORCE -eq 0 ]] && backup_if_exists "$path"
  cat > "$path" <<EOF
# init.md

Session-start instruction file for Codex.

## At The Beginning Of Each Session

Before doing substantive work:

1. Confirm Codex memory is configured from \`${MEMORY_DIR}/.env\`.
2. Treat the MuninnDB vault named \`${VAULT_NAME}\` as the default durable memory for this session.
3. Query the \`${VAULT_NAME}\` vault for recent context and where we left off before making assumptions.
4. Use \`${MEMORY_DIR}/memory.sh\` for direct health, list, and recall checks when needed.

## Purpose

This file exists so the user can explicitly point Codex to it at session start and remind Codex to consult MuninnDB first.
EOF
}

install_managed_mcp_block() {
  local config_path="${CODEX_DIR%/}/config.toml"
  local tmp_path="${config_path}.tmp.$$"
  local begin='# >>> codex-muninn >>>'
  local end='# <<< codex-muninn <<<'
  local existed=0

  mkdir -p "$CODEX_DIR"
  [[ -e "$config_path" ]] && existed=1
  touch "$config_path"

  if grep -Fq '[mcp_servers.muninn]' "$config_path" && ! grep -Fq "$begin" "$config_path"; then
    log "Existing user-managed muninn MCP block found in $config_path; leaving it unchanged"
    return 0
  fi

  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$config_path" > "$tmp_path"

  cat >> "$tmp_path" <<EOF
$begin
[mcp_servers.muninn]
url = '${MCP_URL}'

[mcp_servers.muninn.http_headers]
Authorization = 'Bearer ${MCP_TOKEN}'
$end
EOF

  (( existed == 1 )) && backup_if_exists "$config_path"
  mv "$tmp_path" "$config_path"
  chmod 600 "$config_path"
}

print_summary() {
  cat <<EOF

Installed Codex Muninn memory:
  Codex dir:      ${CODEX_DIR}
  Memory dir:     ${MEMORY_DIR}
  Muninn dir:     ${MUNINN_DIR}
  Vault:          ${VAULT_NAME}
  API base URL:   ${API_BASE_URL}
  MCP URL:        ${MCP_URL}
  init.md:        ${INIT_PATH}

Checks:
  ${MEMORY_DIR}/memory.sh health
  ${MEMORY_DIR}/memory.sh list 5 0
EOF
}

main() {
  parse_args "$@"
  set_derived_paths
  need_cmd awk
  need_cmd grep
  need_cmd jq
  need_cmd sed

  install_muninn_if_needed
  ensure_layout
  ensure_mcp_token
  start_muninn_if_needed
  ensure_vault
  create_vault_token_if_needed
  write_memory_env
  write_memory_readme
  write_memory_script
  write_start_script
  write_init_md
  install_managed_mcp_block
  print_summary
}

main "$@"
