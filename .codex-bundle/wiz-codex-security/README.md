# Wiz Codex Security

Codex-ready Wiz integration bundle with:

- a home-local Codex plugin that exposes Wiz skills
- a standalone `wiz-security` Codex skill
- an installer that configures Wiz MCP in `~/.codex/config.toml`
- a fallback helper that publishes a Wiz scan and fetches raw findings from the Wiz GraphQL API when MCP is unavailable

## Why this repo exists

In some Codex sessions, Wiz MCP may not load immediately even when the plugin is installed.
This bundle is designed to be resilient:

1. Try Wiz MCP first
2. If MCP is unavailable, use `wizcli` plus the Wiz API to get specific Wiz findings

That avoids relying on `wizcli scan dir --no-publish`, which can hide findings behind policy filtering.

## Repo contents

- `plugin/`
  The home-local Codex plugin to install under `~/plugins/wiz-security`
- `skill/`
  A standalone `wiz-security` skill to install under `~/.codex/skills/wiz-security`
- `install.sh`
  Installs the plugin and standalone skill, then configures Wiz MCP in `~/.codex/config.toml`

## Prerequisites

- Codex / Codex VS Code extension
- `wizcli`
- `jq`
- `curl`

For MCP mode:

- Wiz Remote MCP Server enabled in Wiz:
  `Settings > Tenant > AI Features`
- For service-account auth, export these before running `./install.sh`:
  `WIZ_CLIENT_ID`, `WIZ_CLIENT_SECRET`, `WIZ_DATACENTER`
- Optional override for non-default Wiz MCP environments:
  `WIZ_MCP_URL` (defaults to `https://mcp.app.wiz.io`)

For API fallback mode:

- a valid Wiz login stored by `wizcli` in `~/.wiz/auth.json`

If you have not authenticated Wiz CLI yet, run a device-code login flow first by invoking a Wiz scan, for example:

```bash
wizcli scan dir . --use-device-code --no-browser --stdout human
```

## Install in a new environment

From this repo root:

```bash
./install.sh
```

The installer will:

- copy the plugin to `~/plugins/wiz-security`
- copy the standalone skill to `~/.codex/skills/wiz-security`
- create or update `~/.agents/plugins/marketplace.json`
- create or update `[mcp_servers.wiz]` in `~/.codex/config.toml`

Authentication behavior:

- Default install configures OAuth-style MCP access with just the Wiz MCP URL
- If `WIZ_CLIENT_ID`, `WIZ_CLIENT_SECRET`, and `WIZ_DATACENTER` are set, the installer configures `env_http_headers` so Codex reads those values from the environment instead of storing secrets in plain text

## After install

1. Fully quit VS Code.
2. Reopen VS Code.
3. Start a brand new Codex session.
4. Optional: verify the server is registered with `codex mcp list`.
5. Ask Codex something explicit, for example:

```text
Use Wiz to scan this repo and walk me through the top risks
```

## Expected behavior

- Best case: Codex uses Wiz MCP through the global Codex MCP config.
- Fallback case: Codex uses the standalone skill or plugin skill helper script and retrieves raw findings from the Wiz API.

## Important files

- Plugin manifest:
  `plugin/.codex-plugin/plugin.json`
- Legacy plugin-local MCP reference:
  `plugin/.mcp.json`
- Plugin fallback helper:
  `plugin/scripts/wiz_scan_fetch.sh`
- MCP setup skill:
  `plugin/wiz-security/skills/wiz-mcp-setup/SKILL.md`
- Standalone skill:
  `skill/wiz-security/SKILL.md`

## Troubleshooting

If a new Codex session still does not expose Wiz MCP:

1. Confirm the plugin exists at `~/plugins/wiz-security`
2. Confirm the marketplace entry exists in `~/.agents/plugins/marketplace.json`
3. Confirm `~/.codex/config.toml` contains `[mcp_servers.wiz]`
4. If using service-account auth, confirm `WIZ_CLIENT_ID`, `WIZ_CLIENT_SECRET`, and `WIZ_DATACENTER` are available in the same login session that starts Codex
5. Confirm `~/.wiz/auth.json` exists for fallback mode
6. Start a fresh Codex session after fully quitting VS Code

If fallback mode fails, verify:

```bash
bash ~/.codex/skills/wiz-security/scripts/wiz_scan_fetch.sh --help
```

## Example prompts

- `Use Wiz to scan this repo and explain the top findings`
- `Use Wiz to verify whether my last fix removed the highest severity finding`
- `Use Wiz to troubleshoot why MCP is not returning detailed findings`
