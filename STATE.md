# State Snapshot (Muninn + OpenClaw Integration)

Last updated: 2026-03-07 (UTC)

## What exists

- Public repo: `kpince/openclaw-ops`
- Deploy pack: `deploy/muninn-bridge`
- One-command installer: `deploy/muninn-bridge/install_muninn_openclaw_bridge.sh`
- Skill file: `deploy/muninn-bridge/skills/muninn-native-memory/SKILL.md`

## Integration model

- Muninn is auto-started whenever OpenClaw gateway starts (systemd drop-in).
- OpenClaw loads `muninn-bridge` extension from `~/.openclaw/extensions/muninn-bridge`.
- Extension provides tools:
  - `muninn_health`
  - `muninn_search`
  - `muninn_store`
  - `muninn_list_recent`
- Native-style recall injection:
  - Hook: `before_prompt_build` -> calls Muninn `/api/activate` -> injects `prependContext`.
- Auto write-back attempt:
  - Hook: `llm_output` -> stores compact memory to Muninn `/api/engrams`.

## Critical target files on deployed host

- `~/.openclaw/extensions/muninn-bridge/index.ts`
- `~/.openclaw/extensions/muninn-bridge/openclaw.plugin.json`
- `~/.openclaw/openclaw.json` (plugins.allow + plugins.entries.muninn-bridge)
- `~/.config/systemd/user/openclaw-gateway.service.d/override.conf`
- `/etc/systemd/system/muninndb.service`

## Update-proofing notes

- OpenClaw service behavior is preserved via user drop-in override (not by editing main unit).
- Extension + config live under `~/.openclaw`, outside app repo tree.

## Install on a new droplet

```bash
git clone git@github.com:kpince/openclaw-ops.git /root/openclaw-ops && \
cd /root/openclaw-ops/deploy/muninn-bridge && \
./install_muninn_openclaw_bridge.sh
```

## Verify on a host

```bash
systemctl is-active muninndb.service
systemctl --user is-active openclaw-gateway
curl -s http://127.0.0.1:8475/api/health
```

Optional recall check:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"concept":"native_inject_test","content":"TOKEN-123","vault":"default","confidence":0.99}' \
  http://127.0.0.1:8475/api/engrams

openclaw agent --session-id native-inject-check \
  --message "What is the token from native_inject_test? Reply token only." --json
```

## How to resume in a future session

Prompt the agent with:

- "Read `/root/openclaw-ops/STATE.md` and continue from current deployment state."

If working on another host, clone repo first, then point agent to that host's checked-out `STATE.md`.
