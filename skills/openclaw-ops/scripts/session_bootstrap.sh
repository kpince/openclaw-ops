#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/root/.openclaw/workspace"
VAULT="${1:-codex-agent}"

echo "== OpenClaw Session Bootstrap =="
echo "workspace: $WORKSPACE"
echo "vault: $VAULT"

echo
echo "[1/4] Load codex.init"
if [[ -f /root/codex.init ]]; then
  sed -n '1,120p' /root/codex.init
else
  echo "missing: /root/codex.init"
fi

echo
echo "[2/4] Load continuity files"
for f in \
  /root/.openclaw/workspace/AGENTS.md \
  /root/.openclaw/workspace/SOUL.md \
  /root/.openclaw/workspace/USER.md \
  /root/.openclaw/workspace/MEMORY.md; do
  if [[ -f "$f" ]]; then
    echo "--- $f ---"
    sed -n '1,120p' "$f"
  else
    echo "missing: $f"
  fi
  echo
done

echo "[3/4] Recent daily notes"
if [[ -d "$WORKSPACE/memory" ]]; then
  ls -1 "$WORKSPACE/memory" 2>/dev/null | sort | tail -n 2 || true
else
  echo "missing: $WORKSPACE/memory"
fi

echo
echo "[4/4] Muninn quick checks"
cd "$WORKSPACE"
if command -v codex-muninn >/dev/null 2>&1; then
  set +e
  codex-muninn status --vault "$VAULT"
  status_rc=$?
  codex-muninn where-left-off --vault "$VAULT" --limit 5
  left_rc=$?
  set -e

  if [[ $status_rc -ne 0 || $left_rc -ne 0 ]]; then
    echo
    echo "muninn helper failed (status_rc=$status_rc, left_rc=$left_rc)"
    echo "run: scripts/mcp_diagnose.sh"
  fi
else
  echo "codex-muninn not found in PATH"
fi
