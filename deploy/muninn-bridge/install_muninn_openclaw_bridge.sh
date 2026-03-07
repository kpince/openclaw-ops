#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_STATE_DIR/openclaw.json}"
EXT_DIR="$OPENCLAW_STATE_DIR/extensions/muninn-bridge"
USER_OVERRIDE_DIR="$HOME/.config/systemd/user/openclaw-gateway.service.d"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

require_cmd systemctl
require_cmd node

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

if [[ ! -f "$OPENCLAW_CONFIG_PATH" ]]; then
  echo "OpenClaw config not found: $OPENCLAW_CONFIG_PATH" >&2
  exit 1
fi

echo "[1/8] Ensuring Muninn is installed"
ensure_muninn_installed

echo "[2/8] Installing muninn-bridge extension files"
mkdir -p "$EXT_DIR"
cp -f "$FILES_DIR/muninn-bridge/index.ts" "$EXT_DIR/index.ts"
cp -f "$FILES_DIR/muninn-bridge/openclaw.plugin.json" "$EXT_DIR/openclaw.plugin.json"

echo "[3/8] Installing systemd units/overrides"
install -m 0644 "$FILES_DIR/systemd/muninndb.service" /etc/systemd/system/muninndb.service
mkdir -p "$USER_OVERRIDE_DIR"
cp -f "$FILES_DIR/systemd/openclaw-gateway.override.conf" "$USER_OVERRIDE_DIR/override.conf"

echo "[4/8] Updating OpenClaw config"
node - <<'NODE' "$OPENCLAW_CONFIG_PATH"
const fs = require('fs');
const p = process.argv[2];
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
j.plugins = j.plugins || {};
j.plugins.allow = Array.isArray(j.plugins.allow) ? j.plugins.allow : [];
if (!j.plugins.allow.includes('muninn-bridge')) j.plugins.allow.push('muninn-bridge');
j.plugins.entries = j.plugins.entries || {};
const e = j.plugins.entries['muninn-bridge'] || {};
e.enabled = true;
e.config = {
  ...(e.config || {}),
  baseUrl: 'http://127.0.0.1:8475',
  defaultVault: 'default',
  timeoutMs: 5000,
  autoInject: true,
  autoStore: true,
};
j.plugins.entries['muninn-bridge'] = e;
fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
NODE

echo "[5/8] Reloading systemd"
systemctl daemon-reload
systemctl --user daemon-reload

echo "[6/8] Enabling and starting Muninn"
systemctl enable muninndb.service >/dev/null
systemctl restart muninndb.service

echo "[7/8] Restarting OpenClaw gateway"
systemctl --user restart openclaw-gateway

echo "[8/8] Smoke checks"
systemctl is-active muninndb.service
systemctl --user is-active openclaw-gateway

if command -v curl >/dev/null 2>&1; then
  echo "Health:"
  curl -sS -m 5 http://127.0.0.1:8475/api/health || true
  echo
fi

echo "Done. Muninn bridge installed."
