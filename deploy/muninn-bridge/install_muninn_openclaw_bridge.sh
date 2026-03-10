#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_STATE_DIR/openclaw.json}"
OPENCLAW_MCP_PATH="${OPENCLAW_MCP_PATH:-$OPENCLAW_STATE_DIR/mcp.json}"
MUNINN_DATA_DIR="${MUNINN_DATA_DIR:-$HOME/.muninn/data}"
MUNINN_MCP_TOKEN_PATH="${MUNINN_MCP_TOKEN_PATH:-$HOME/.muninn/mcp.token}"
EXT_DIR="$OPENCLAW_STATE_DIR/extensions/muninn-bridge"
USER_OVERRIDE_DIR="$HOME/.config/systemd/user/openclaw-gateway.service.d"
MUNINN_BASE_URL="${MUNINN_BASE_URL:-http://127.0.0.1:8475}"
MUNINN_MCP_URL="${MUNINN_MCP_URL:-http://localhost:8750/mcp}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

require_cmd systemctl
require_cmd node

if [[ "$EUID" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

ensure_muninn_installed() {
  if command -v muninn >/dev/null 2>&1; then
    echo "muninn binary found: $(command -v muninn)"
    return 0
  fi

  echo "muninn binary not found; installing..."
  if [[ -n "${MUNINN_INSTALL_CMD:-}" ]]; then
    echo "Using custom MUNINN_INSTALL_CMD"
    bash -lc "$MUNINN_INSTALL_CMD"
  else
    require_cmd curl
    require_cmd bash
    curl -fsSL https://raw.githubusercontent.com/scrypster/muninndb/main/install.sh | bash
  fi

  if ! command -v muninn >/dev/null 2>&1; then
    echo "muninn install did not produce a runnable binary in PATH" >&2
    exit 1
  fi
  echo "muninn installed: $(command -v muninn)"
}

backup_file_if_exists() {
  local src="$1"
  if [[ -f "$src" ]]; then
    local ts
    ts="$(date +%Y%m%d%H%M%S)"
    cp -a "$src" "$src.bak.$ts"
    echo "backup: $src.bak.$ts"
  fi
}

wait_for_url() {
  local url="$1"
  local attempts="${2:-20}"
  local sleep_s="${3:-1}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

if [[ ! -f "$OPENCLAW_CONFIG_PATH" ]]; then
  echo "OpenClaw config not found: $OPENCLAW_CONFIG_PATH" >&2
  exit 1
fi

echo "[1/10] Ensuring Muninn is installed"
ensure_muninn_installed

echo "[2/10] Ensuring Muninn data directory"
mkdir -p "$MUNINN_DATA_DIR"

echo "[3/10] Installing muninn-bridge extension files"
mkdir -p "$EXT_DIR"
cp -f "$FILES_DIR/muninn-bridge/index.ts" "$EXT_DIR/index.ts"
cp -f "$FILES_DIR/muninn-bridge/openclaw.plugin.json" "$EXT_DIR/openclaw.plugin.json"

echo "[4/10] Installing systemd units/overrides"
install -m 0644 "$FILES_DIR/systemd/muninndb.service" /etc/systemd/system/muninndb.service
mkdir -p "$USER_OVERRIDE_DIR"
cp -f "$FILES_DIR/systemd/openclaw-gateway.override.conf" "$USER_OVERRIDE_DIR/override.conf"

echo "[5/10] Backing up OpenClaw config files"
backup_file_if_exists "$OPENCLAW_CONFIG_PATH"
backup_file_if_exists "$OPENCLAW_MCP_PATH"

echo "[6/10] Updating OpenClaw config (Muninn-only memory)"
node - <<'NODE' "$OPENCLAW_CONFIG_PATH" "$MUNINN_BASE_URL"
const fs = require('fs');
const p = process.argv[2];
const baseUrl = process.argv[3];
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
j.plugins = j.plugins || {};
j.plugins.allow = Array.isArray(j.plugins.allow) ? j.plugins.allow : [];
j.plugins.allow = j.plugins.allow.filter((name) => name !== 'memory-sqlite');
if (!j.plugins.allow.includes('muninn-bridge')) {
  j.plugins.allow.push('muninn-bridge');
}
j.plugins.entries = j.plugins.entries || {};
if (j.plugins.entries['memory-sqlite']) {
  j.plugins.entries['memory-sqlite'].enabled = false;
}
const e = j.plugins.entries['muninn-bridge'] || {};
e.enabled = true;
e.config = {
  ...(e.config || {}),
  baseUrl,
  defaultVault: 'default',
  timeoutMs: 5000,
  autoInject: true,
  autoStore: true,
};
j.plugins.entries['muninn-bridge'] = e;
fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
NODE

echo "[7/10] Updating MCP config (8750 /mcp)"
node - <<'NODE' "$OPENCLAW_MCP_PATH" "$MUNINN_MCP_URL" "$MUNINN_MCP_TOKEN_PATH"
const fs = require('fs');
const path = process.argv[2];
const mcpUrl = process.argv[3];
const tokenPath = process.argv[4];

let doc = {};
if (fs.existsSync(path)) {
  doc = JSON.parse(fs.readFileSync(path, 'utf8'));
}
doc.mcpServers = doc.mcpServers || {};
doc.mcpServers.muninn = doc.mcpServers.muninn || {};
doc.mcpServers.muninn.url = mcpUrl;

if (fs.existsSync(tokenPath)) {
  const token = fs.readFileSync(tokenPath, 'utf8').trim();
  if (token) {
    doc.mcpServers.muninn.headers = doc.mcpServers.muninn.headers || {};
    doc.mcpServers.muninn.headers.Authorization = `Bearer ${token}`;
  }
}

fs.writeFileSync(path, JSON.stringify(doc, null, 2) + '\n');
NODE

echo "[8/10] Reloading systemd"
systemctl daemon-reload
systemctl --user daemon-reload

echo "[9/10] Enabling and starting services"
systemctl enable muninndb.service >/dev/null
systemctl restart muninndb.service
systemctl --user restart openclaw-gateway

echo "[10/10] Smoke checks"
systemctl is-active muninndb.service
systemctl --user is-active openclaw-gateway

if command -v curl >/dev/null 2>&1; then
  if ! wait_for_url "http://127.0.0.1:8475/api/health" 30 1; then
    echo "WARN: Muninn REST not ready on 127.0.0.1:8475 after waiting" >&2
  fi

  echo "Health:"
  curl -sS -m 5 http://127.0.0.1:8475/api/health || true
  echo

  echo "Write/read test:"
  ts="$(date -u +%FT%TZ)"
  concept="install:muninn-bridge"
  payload="{\"concept\":\"$concept\",\"content\":\"installer smoke at $ts\",\"tags\":[\"install\",\"smoke\"],\"vault\":\"default\",\"confidence\":0.8}"
  curl -sS -m 5 -H 'Content-Type: application/json' -d "$payload" \
    http://127.0.0.1:8475/api/engrams || true
  echo
  curl -sS -m 5 "http://127.0.0.1:8475/api/engrams?vault=default&limit=1&offset=0" || true
  echo
fi

echo "Done. Muninn bridge installed with Muninn-only memory config."
