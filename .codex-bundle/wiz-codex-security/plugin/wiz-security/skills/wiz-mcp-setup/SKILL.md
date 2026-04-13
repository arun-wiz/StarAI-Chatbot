---
name: wiz-mcp-setup
description: Configure the remote Wiz MCP server in Codex. Supports all Wiz environments (app, demo, test, custom URLs). Default auth is browser-based OAuth; for service-account auth, prefer env_http_headers so secrets stay out of config files. Use when the user wants to set up or reconfigure the Wiz MCP server.
disable-model-invocation: true
---

# Wiz MCP Setup

Configure the remote Wiz MCP server for use with Codex.

> **Prerequisite:** Remote MCP Server must be enabled on the
> **Settings > Tenant > AI Features** page in your Wiz portal before proceeding.

## Step 1 — Determine the Wiz MCP URL

- If an argument was passed (`$ARGUMENTS`):
  - If it contains a `.`: treat it as the full URL. Add `https://` if no scheme is present.
    - Example: `mcp.test.wiz.io` -> `https://mcp.test.wiz.io`
  - If it contains no `.`: treat it as an environment shorthand and construct `https://mcp.<arg>.wiz.io`
    - Example: `test` -> `https://mcp.test.wiz.io`
- Otherwise use the default: `https://mcp.app.wiz.io`

## Step 2 — Locate the Codex MCP config

Codex should read Wiz MCP from:

`~/.codex/config.toml`

Do not treat `~/plugins/wiz-security/.mcp.json` as the source of truth for current Codex installs.

## Step 3 — Update the MCP URL

Edit `~/.codex/config.toml` so it contains:

```toml
[mcp_servers.wiz]
url = "<URL>"
```

Default environment:

`https://mcp.app.wiz.io`

Common alternates:

- `https://mcp.demo.wiz.io`
- `https://mcp.test.wiz.io`
- `https://mcp.<env>.wiz.io`

## Step 4 — Authentication mode

### OAuth path

For standard browser-based OAuth, the URL-only Codex config is enough:

```toml
[mcp_servers.wiz]
url = "<URL>"
```

When Codex first tries to use the server, it should prompt for authorization if your Wiz tenant supports OAuth.

### Service account path

Only use this if the user explicitly asks for service-account auth and already has:

- `WIZ_CLIENT_ID`
- `WIZ_CLIENT_SECRET`
- `WIZ_DATACENTER`

Then export those variables in the environment that starts Codex, and update `~/.codex/config.toml` like this:

```toml
[mcp_servers.wiz]
url = "<URL>"
env_http_headers = { "Wiz-Client-Id" = "WIZ_CLIENT_ID", "Wiz-Client-Secret" = "WIZ_CLIENT_SECRET", "Wiz-DataCenter" = "WIZ_DATACENTER" }
```

Avoid plaintext `http_headers` unless the user explicitly accepts that risk.

## Step 5 — Restart Codex

After changing `~/.codex/config.toml`, restart Codex so it reloads the MCP configuration.

## Step 6 — Confirm and remind

Confirm the configured URL and auth mode, then remind the user:

1. Ensure Remote MCP Server is enabled in Wiz:
   `Settings > Tenant > AI Features`
2. Restart Codex if `~/.codex/config.toml` changed
3. Optional: verify with `codex mcp list`
4. Test with:
   `/wiz-remediate this repo`
