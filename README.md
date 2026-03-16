# openclaw-ops

Operational deployment assets for OpenClaw instances.

## Packs

- `deploy/muninn-bridge`: Earlier update-safe Muninn bridge integration for OpenClaw.
- `deploy/codex-muninn-installer`: Earlier one-command Muninn-backed durable memory installer for Codex, separate from OpenClaw.
- Repository root: current Muninn/OpenClaw/Codex bootstrap kit with dedicated Codex vault support.

## Root Kit

The repository root now contains the current installable Muninn/OpenClaw kit.

It packages:
- the `muninn-backbone` OpenClaw plugin
- the `memory-muninn` workspace skill
- a Codex bootstrap file and Muninn helper CLI
- a one-way Muninn backfill importer
- systemd templates for `muninndb`
- install/uninstall scripts

## What It Does

- Makes MuninnDB the long-term memory authority for OpenClaw
- Disables OpenClaw's built-in memory slot
- Wires Muninn into OpenClaw over MCP
- Adds proactive recall before agent runs
- Adds conservative auto-capture after successful agent runs
- Creates a dedicated `codex` vault plus `/root/codex.init` bootstrap for Codex sessions
- Leaves `MEMORY.md` and `memory/*.md` intact

## Requirements

- Linux host with `systemd`
- OpenClaw already installed and configured
- Root access
- `node`, `curl`, `openssl`, and `envsubst`
- A `muninn` binary either:
  - already on `PATH`, or
  - provided via `MUNINN_SOURCE_BIN=/path/to/muninn`

## Install

```bash
git clone git@github.com:kpince/openclaw-ops.git
cd openclaw-ops

export MUNINN_OPENAI_KEY=sk-proj-...
export MUNINN_ENRICH_API_KEY="$MUNINN_OPENAI_KEY"
sudo -E ./install.sh
```

Optional variables:

```bash
export OPENCLAW_DIR=/root/.openclaw
export MUNINN_SOURCE_BIN=/tmp/muninn
export MUNINN_ENRICH_URL=openai://gpt-4o-mini
export MUNINN_MCP_TOKEN="$(openssl rand -hex 24)"
export CODEX_VAULT_NAME=codex
```

## Backfill Existing Memory

After install:

```bash
sudo MUNINN_VAULT=default node /root/.openclaw/scripts/import-muninn-backfill.mjs
```

The importer:
- reads legacy SQLite structured memory if present
- imports `USER.md`, `MEMORY.md`, and the full `workspace/memory/**/*.md` tree
- splits Markdown into section-level memories
- redacts obvious secrets before writing

## Codex Bootstrap

The installer also creates:

- `/root/codex.init`
- `/root/AGENTS.md`
- `/root/.local/bin/codex-muninn`

Typical new-session flow:

```bash
cd /root/.openclaw/workspace
codex-muninn status
codex-muninn where-left-off --limit 5
codex-muninn recall "current task"
```

Then store durable outcomes incrementally:

```bash
codex-muninn remember --type decision --concept "example" --summary "Short summary" "Atomic durable memory content"
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes the plugin, skill, and MCP wiring. It does not remove Muninn data unless you do that separately.

## Repo Layout

```text
README.md                                      Repo index + current root kit docs
install.sh                                     Current root installer
plugin/                                        OpenClaw runtime plugin
skills/memory-muninn/                          Workspace skill
scripts/                                       Backfill/import helpers
templates/                                     Installer-rendered templates
systemd/                                       Base muninndb unit
uninstall.sh                                   Root cleanup script
deploy/muninn-bridge/                          Earlier bridge-based deploy pack
deploy/codex-muninn-installer/                 Earlier Codex-only installer pack
STATE.md                                       Prior state snapshot and integration notes
```

## Notes

- The plugin is upgrade-safe because it lives outside OpenClaw core.
- The installer intentionally does not patch OpenClaw source files.
- The older `deploy/*` packs are preserved for history and comparison.
