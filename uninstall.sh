#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$OPENCLAW_DIR/workspace}"
EXT_DIR="$OPENCLAW_DIR/extensions/muninn-backbone"
SKILL_DIR="$WORKSPACE_DIR/skills/memory-muninn"
SCRIPT_PATH="$OPENCLAW_DIR/scripts/import-muninn-backfill.mjs"
OPENCLAW_JSON="$OPENCLAW_DIR/openclaw.json"
MCP_JSON="$OPENCLAW_DIR/mcp.json"
MUNINN_SERVICE_NAME="${MUNINN_SERVICE_NAME:-muninndb.service}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This uninstaller must run as root." >&2
  exit 1
fi

rm -rf "$EXT_DIR" "$SKILL_DIR"
rm -f "$SCRIPT_PATH"
rm -f "/etc/systemd/system/${MUNINN_SERVICE_NAME}.d/override.conf"

if [[ -f "$OPENCLAW_JSON" ]]; then
  OPENCLAW_JSON="$OPENCLAW_JSON" node <<'EOF'
const fs = require("fs");
const file = process.env.OPENCLAW_JSON;
const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
if (cfg.plugins?.allow) {
  cfg.plugins.allow = cfg.plugins.allow.filter((id) => id !== "muninn-backbone");
}
if (cfg.plugins?.entries) {
  delete cfg.plugins.entries["muninn-backbone"];
}
if (cfg.plugins?.slots?.memory === "none") {
  delete cfg.plugins.slots.memory;
}
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
EOF
fi

if [[ -f "$MCP_JSON" ]]; then
  MCP_JSON="$MCP_JSON" node <<'EOF'
const fs = require("fs");
const file = process.env.MCP_JSON;
const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
if (cfg.mcpServers) delete cfg.mcpServers.muninn;
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
EOF
fi

systemctl daemon-reload
if systemctl --user status openclaw-gateway.service >/dev/null 2>&1; then
  systemctl --user restart openclaw-gateway.service
fi

echo "Removed Muninn/OpenClaw integration files."
