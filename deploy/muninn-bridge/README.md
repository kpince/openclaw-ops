# Muninn Bridge Deployment Pack

This pack deploys update-safe Muninn integration for OpenClaw instances.

## What it installs

- OpenClaw extension:
  - `~/.openclaw/extensions/muninn-bridge/index.ts`
  - `~/.openclaw/extensions/muninn-bridge/openclaw.plugin.json`
- System service:
  - `/etc/systemd/system/muninndb.service`
- Update-proof OpenClaw systemd drop-in:
  - `~/.config/systemd/user/openclaw-gateway.service.d/override.conf`
- OpenClaw config patch in:
  - `~/.openclaw/openclaw.json`

## Install

Run as root on target instance:

```bash
cd deploy/muninn-bridge
./install_muninn_openclaw_bridge.sh
```

If `muninn` is missing, the script auto-installs it from:
`https://raw.githubusercontent.com/scrypster/muninndb/main/install.sh`

Optional override:

```bash
MUNINN_INSTALL_CMD='your custom install command' ./install_muninn_openclaw_bridge.sh
```

## Verify

```bash
systemctl is-active muninndb.service
systemctl --user is-active openclaw-gateway
curl -s http://127.0.0.1:8475/api/health
```

Optional recall smoke test:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"concept":"native_inject_test","content":"TOKEN-123","vault":"default","confidence":0.99}' \
  http://127.0.0.1:8475/api/engrams

openclaw agent --session-id native-inject-check \
  --message "What is the token from native_inject_test? Reply token only." --json
```

## Notes

- This pack is idempotent and safe to re-run.
- The OpenClaw drop-in is used so OpenClaw updates do not wipe Muninn auto-start behavior.

## Included Skill

- `skills/muninn-native-memory/SKILL.md`

Use this SKILL.md in your OpenClaw instance to enforce the session-level
Muninn recall/write-back loop in agent behavior.
