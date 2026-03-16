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

## Muninn recall experiment (quick protocol)

Use this when you want to validate live recall behavior.

1. Seed memory A:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"concept":"exp_test","content":"My favorite fallback model is Claude Haiku 4.5","vault":"default","confidence":0.95}' \
  http://127.0.0.1:8475/api/engrams
```

2. Ask agent:
- "What is my favorite fallback model?"

3. Seed conflicting memory B:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"concept":"exp_test","content":"Correction: favorite fallback model is GPT-4o mini","vault":"default","confidence":0.99}' \
  http://127.0.0.1:8475/api/engrams
```

4. Ask again:
- "What is my favorite fallback model now?"

5. Inspect what Muninn returns:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"context":["favorite fallback model"],"vault":"default","limit":5,"mode":"balanced"}' \
  http://127.0.0.1:8475/api/activate
```

Expected: agent response should track top-ranked activation from Muninn recall injection.

## Next phase candidate (WooCommerce sales agent)

Target environment:
- Another droplet running OpenClaw as a customer-facing sales agent for a WordPress/WooCommerce shop.
- Current capabilities include customer chat, customer creation, and order creation.

Why this is the first knowledge-graph candidate:
- High business impact with clear measurable outcomes.
- Repeated entities and relationships already exist (customer, product, order, cart, category).
- Persistent memory + graph grounding can reduce bad recommendations and improve follow-up quality.

Initial design direction:
1. Persistent customer profile memory
- intent, budget range, preferences, objections, language/tone notes.
2. Product relationship graph
- alternatives, complements, substitutes, compatibility.
3. Order/session continuity
- preserve active cart/decision context across sessions and channels.
4. Follow-up intelligence
- abandoned cart, restock interest, upsell/cross-sell timing based on prior interactions.

Execution principle:
- stabilize memory loop first, then layer graph retrieval on top of existing recall path.
