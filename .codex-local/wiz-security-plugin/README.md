# Wiz Security Skills

AI coding skills for code-to-cloud security analysis and remediation, powered by the Wiz MCP server. Works with Claude Code, Cursor, and other AI coding tools.

---

## Skills Included

| Skill | Command | Description |
|-------|---------|-------------|
| **wiz-remediate** | `/wiz-remediate` | Scan a repo for active risks (vulns, threats, secrets, toxic combinations) and apply fixes |
| **wiz-update** | `/wiz-update` | Update the Wiz skills to the latest version |
| **wiz-mcp-setup** | `/wiz-mcp-setup` | Configure the remote Wiz MCP server |

---

## Installation

### Claude Code

Wiz ships as a Claude Code plugin — install it once and the skills are available globally across all your projects.

#### Customer Installation (zip)

```bash
# 1. Download and extract
curl -L https://TBD/wiz-security-latest.zip -o wiz-security-latest.zip
unzip wiz-security-latest.zip -d ~/.claude/plugins/marketplaces/wiz-security/

# 2. Register the marketplace and install the plugin (run inside Claude Code)
/plugin marketplace add ~/.claude/plugins/marketplaces/wiz-security
/plugin install wiz-security@wiz-security

# 3. Set up the Wiz MCP server (one-time)
/wiz-mcp-setup

# 4. Done — skills are live
/wiz-remediate this repo
```

#### Wiz Developer Installation (git)

```bash
# 1. Clone directly into the Claude plugins directory
git clone git@github.com:wiz-sec/wiz-ai-skills.git ~/.claude/plugins/marketplaces/wiz-security

# 2. Register the marketplace and install the plugin (run inside Claude Code)
/plugin marketplace add ~/.claude/plugins/marketplaces/wiz-security
/plugin install wiz-security@wiz-security

# 3. Set up the Wiz MCP server if needed
/wiz-mcp-setup

# 4. Done
/wiz-remediate this repo
```

### Cursor

Copy the skills into your project's `.cursor/rules/` directory and they'll be available via `@wiz-remediate`, `@wiz-mcp-setup`, etc.

```bash
# From your project root
mkdir -p .cursor/rules
cp -r ~/.cursor/wiz-security/wiz-security/skills/* .cursor/rules/
```

Or for global availability across all projects, place them in `~/.cursor/rules/`.

---

## Updating

```bash
/wiz-update
```

Automatically detects whether you installed via zip or git and updates accordingly:
- **Git install (developers):** runs `git pull origin main`
- **Zip install (customers):** downloads and extracts the latest zip from `https://TBD/wiz-security-latest.zip`

---

## Prerequisites

- Wiz tenant with **Remote MCP Server** enabled under **Settings > Tenant > AI Features**
- For current Codex installs, configure Wiz MCP in `~/.codex/config.toml`
- Run `/wiz-mcp-setup` to configure or reconfigure the Wiz MCP server (one-time setup)
