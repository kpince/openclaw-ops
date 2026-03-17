#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$OPENCLAW_DIR/workspace}"
EXT_DIR="$OPENCLAW_DIR/extensions/muninn-backbone"
SKILL_DIR="$WORKSPACE_DIR/skills/memory-muninn"
SCRIPT_DIR="$OPENCLAW_DIR/scripts"
MCP_JSON="$OPENCLAW_DIR/mcp.json"
OPENCLAW_JSON="$OPENCLAW_DIR/openclaw.json"
CODEX_BIN_DIR="${CODEX_BIN_DIR:-$HOME/.local/bin}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$CODEX_HOME/skills}"
CODEX_INIT_PATH="${CODEX_INIT_PATH:-$HOME/codex.init}"
ROOT_AGENTS_PATH="${ROOT_AGENTS_PATH:-$HOME/AGENTS.md}"
OPENCLAW_OPS_SKILL_DIR="$CODEX_SKILLS_DIR/openclaw-ops"
CODEX_VAULT_NAME="${CODEX_VAULT_NAME:-codex}"
OPENCLAW_VAULT_NAME="${OPENCLAW_VAULT_NAME:-default}"
MUNINN_DATA_DIR="${MUNINN_DATA_DIR:-$HOME/.muninn/data}"
MUNINN_HOST="${MUNINN_HOST:-127.0.0.1}"
MUNINN_MCP_PORT="${MUNINN_MCP_PORT:-8750}"
MUNINN_REST_PORT="${MUNINN_REST_PORT:-8475}"
MUNINN_MCP_URL="http://${MUNINN_HOST}:${MUNINN_MCP_PORT}/mcp"
MUNINN_REST_URL="http://${MUNINN_HOST}:${MUNINN_REST_PORT}"
MUNINN_SERVICE_NAME="${MUNINN_SERVICE_NAME:-muninndb.service}"
MUNINN_BIN="${MUNINN_BIN:-$(command -v muninn || true)}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This installer must run as root." >&2
    exit 1
  fi
}

copy_tree() {
  local src="$1"
  local dest="$2"
  mkdir -p "$dest"
  cp -R "$src"/. "$dest"/
}

ensure_muninn_binary() {
  if [[ -n "$MUNINN_BIN" && -x "$MUNINN_BIN" ]]; then
    return 0
  fi

  if [[ -n "${MUNINN_SOURCE_BIN:-}" && -x "${MUNINN_SOURCE_BIN:-}" ]]; then
    install -Dm755 "$MUNINN_SOURCE_BIN" /usr/local/bin/muninn
    MUNINN_BIN=/usr/local/bin/muninn
    return 0
  fi

  echo "muninn binary not found." >&2
  echo "Provide one of:" >&2
  echo "  1. Install muninn first so 'muninn' is on PATH" >&2
  echo "  2. Run with MUNINN_SOURCE_BIN=/path/to/muninn" >&2
  exit 1
}

render_systemd_files() {
  local token="${MUNINN_MCP_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token="$(openssl rand -hex 24)"
  fi
  export MUNINN_MCP_TOKEN="$token"

  export INSTALL_MUNINN_BIN="$MUNINN_BIN"
  export INSTALL_MUNINN_DATA_DIR="$MUNINN_DATA_DIR"
  export INSTALL_MUNINN_OPENAI_KEY="${MUNINN_OPENAI_KEY:-}"
  export INSTALL_MUNINN_ENRICH_URL="${MUNINN_ENRICH_URL:-openai://gpt-4o-mini}"
  export INSTALL_MUNINN_ENRICH_API_KEY="${MUNINN_ENRICH_API_KEY:-${MUNINN_OPENAI_KEY:-}}"

  mkdir -p "/etc/systemd/system/${MUNINN_SERVICE_NAME}.d"
  envsubst \
    < "$ROOT_DIR/systemd/muninndb.service" \
    > "/etc/systemd/system/${MUNINN_SERVICE_NAME}"

  envsubst \
    < "$ROOT_DIR/templates/muninndb.override.conf.template" \
    > "/etc/systemd/system/${MUNINN_SERVICE_NAME}.d/override.conf"
}

render_codex_files() {
  mkdir -p "$CODEX_BIN_DIR"
  install -Dm755 "$ROOT_DIR/scripts/codex-muninn.mjs" "$CODEX_BIN_DIR/codex-muninn"
  mkdir -p "$OPENCLAW_OPS_SKILL_DIR"
  copy_tree "$ROOT_DIR/skills/openclaw-ops" "$OPENCLAW_OPS_SKILL_DIR"

  if [[ -d "$OPENCLAW_OPS_SKILL_DIR/scripts" ]]; then
    find "$OPENCLAW_OPS_SKILL_DIR/scripts" -type f -name '*.sh' -exec chmod 755 {} +
  fi

  export INSTALL_CODEX_VAULT="$CODEX_VAULT_NAME"
  export INSTALL_WORKSPACE_DIR="$WORKSPACE_DIR"
  export INSTALL_CODEX_BIN_DIR="$CODEX_BIN_DIR"
  export INSTALL_OPENCLAW_DIR="$OPENCLAW_DIR"
  envsubst \
    < "$ROOT_DIR/templates/codex.init.template" \
    > "$CODEX_INIT_PATH"

  envsubst \
    < "$ROOT_DIR/templates/root.AGENTS.md.template" \
    > "$ROOT_AGENTS_PATH"
}

configure_openclaw() {
  mkdir -p "$EXT_DIR" "$SKILL_DIR" "$SCRIPT_DIR"
  copy_tree "$ROOT_DIR/plugin" "$EXT_DIR"
  copy_tree "$ROOT_DIR/skills/memory-muninn" "$SKILL_DIR"
  install -Dm644 "$ROOT_DIR/scripts/import-muninn-backfill.mjs" "$SCRIPT_DIR/import-muninn-backfill.mjs"

  if [[ ! -f "$OPENCLAW_JSON" ]]; then
    echo "Missing OpenClaw config: $OPENCLAW_JSON" >&2
    exit 1
  fi

  local mcp_token="$MUNINN_MCP_TOKEN"
  mkdir -p "$OPENCLAW_DIR"
  export OPENCLAW_JSON MCP_JSON MUNINN_MCP_URL MUNINN_MCP_TOKEN OPENCLAW_VAULT_NAME

  node <<'EOF'
const fs = require("fs");
const path = require("path");

const openclawJson = process.env.OPENCLAW_JSON;
const mcpJson = process.env.MCP_JSON;
const mcpUrl = process.env.MUNINN_MCP_URL;
const mcpToken = process.env.MUNINN_MCP_TOKEN;

const cfg = JSON.parse(fs.readFileSync(openclawJson, "utf8"));
cfg.plugins ||= {};
cfg.plugins.allow = Array.from(new Set([...(cfg.plugins.allow || []), "muninn-backbone"]));
cfg.plugins.slots = { ...(cfg.plugins.slots || {}), memory: "none" };
cfg.plugins.entries ||= {};
cfg.plugins.entries["muninn-backbone"] = {
  config: {
    enabled: true,
    mcpConfigPath: "~/.openclaw/mcp.json",
    serverName: "muninn",
    vault: process.env.OPENCLAW_VAULT_NAME || "default",
    recallMode: "balanced",
    recallLimit: 4,
    whereLeftOffLimit: 3,
    injectWhereLeftOff: true,
    autoCapture: {
      enabled: true,
      maxItems: 4,
      maxChars: 500,
      dedupeThreshold: 0.92
    },
    guidance: {
      enabled: true
    }
  }
};
fs.writeFileSync(openclawJson, JSON.stringify(cfg, null, 2) + "\n");

let mcp = { mcpServers: {} };
if (fs.existsSync(mcpJson)) {
  mcp = JSON.parse(fs.readFileSync(mcpJson, "utf8"));
  mcp.mcpServers ||= {};
}
mcp.mcpServers.muninn = {
  headers: {
    Authorization: `Bearer ${mcpToken}`
  },
  url: mcpUrl
};
fs.writeFileSync(mcpJson, JSON.stringify(mcp, null, 2) + "\n");
EOF
}

ensure_vault() {
  local vault_name="$1"
  if muninn show vaults | sed -n 's/^[[:space:]]*•[[:space:]]*//p' | grep -Fxq "$vault_name"; then
    return 0
  fi
  muninn vault create "$vault_name"
}

restart_services() {
  systemctl daemon-reload
  systemctl enable --now "$MUNINN_SERVICE_NAME"

  if systemctl --user status openclaw-gateway.service >/dev/null 2>&1; then
    systemctl --user restart openclaw-gateway.service
  fi
}

postflight() {
  curl -fsS "${MUNINN_REST_URL}/api/health" >/dev/null
  ensure_vault "$CODEX_VAULT_NAME"
  echo "Installed Muninn/OpenClaw integration."
  echo "Muninn MCP: ${MUNINN_MCP_URL}"
  echo "OpenClaw plugin: ${EXT_DIR}"
  echo "Backfill script: ${SCRIPT_DIR}/import-muninn-backfill.mjs"
  echo "Codex helper: ${CODEX_BIN_DIR}/codex-muninn"
  echo "Codex skill: ${OPENCLAW_OPS_SKILL_DIR}"
  echo "Codex init: ${CODEX_INIT_PATH}"
  echo "Root AGENTS: ${ROOT_AGENTS_PATH}"
  echo
  echo "Optional next step:"
  echo "  MUNINN_VAULT=${OPENCLAW_VAULT_NAME} node ${SCRIPT_DIR}/import-muninn-backfill.mjs"
}

need_root
ensure_muninn_binary
render_systemd_files
render_codex_files
configure_openclaw
restart_services
postflight
