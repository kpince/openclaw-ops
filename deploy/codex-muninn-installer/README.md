# Codex Muninn Installer

Legacy pack. The canonical install path is now the repository root:

```bash
git clone git@github.com:kpince/openclaw-ops.git
cd openclaw-ops
sudo -E ./install.sh
```

Use this legacy pack only for comparison or rollback.

One-command installer for giving Codex durable memory backed by MuninnDB.

This pack is intentionally separate from OpenClaw. It installs:

- MuninnDB, if `muninn` is not already available
- a local Muninn daemon for Codex
- a `codex` vault
- a vault API key for Codex memory writes and reads
- Codex-side files under `~/.codex/memories`
- a Muninn MCP entry in `~/.codex/config.toml`
- an `init.md` session bootstrap file

## What it installs

After install, Codex gets:

- `~/.codex/memories/memory.sh`
  - small CLI wrapper over the Muninn REST API
- `~/.codex/memories/.env`
  - Codex memory config: API URL, vault token, vault name
- `~/.codex/memories/start-muninn.sh`
  - helper to start Muninn with the stored MCP token
- `~/.codex/config.toml`
  - Muninn MCP server config for Codex
- `~/init.md`
  - session-start instruction file telling Codex to check memory first

## Legacy Install

Run from this pack directory:

```bash
cd deploy/codex-muninn-installer
./install.sh
```

Remote one-command form after publishing:

```bash
curl -fsSL https://raw.githubusercontent.com/kpince/openclaw-ops/main/deploy/codex-muninn-installer/install.sh | bash
```

## Safe defaults

- If Muninn is already running and reachable on `127.0.0.1:8475`, the installer reuses it.
- If the `codex` vault already exists, the installer reuses it.
- Existing managed files are backed up before overwrite.
- If `~/.codex/config.toml` already contains a user-managed `[mcp_servers.muninn]` block, the installer leaves it alone instead of guessing.

## Optional flags

```bash
./install.sh --help
```

Useful flags:

- `--codex-dir <path>`
- `--muninn-dir <path>`
- `--init-path <path>`
- `--vault <name>`
- `--api-hostport <host:port>`
- `--mcp-addr <host:port>`
- `--mcp-token <token>`
- `--vault-token <token>`
- `--skip-muninn-install`
- `--skip-muninn-start`

These are mainly for testing or advanced layouts.

## Verify

```bash
~/.codex/memories/memory.sh health
~/.codex/memories/memory.sh list 5 0
```

At session start, point Codex to `~/init.md` or tell Codex to use that file as the bootstrap instruction.
