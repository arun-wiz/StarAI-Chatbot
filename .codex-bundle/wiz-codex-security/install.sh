#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_src="${repo_root}/plugin"
skill_src="${repo_root}/skill/wiz-security"

plugin_dst="${HOME}/plugins/wiz-security"
skill_dst="${HOME}/.codex/skills/wiz-security"
codex_config="${HOME}/.codex/config.toml"
marketplace_dir="${HOME}/.agents/plugins"
marketplace_file="${marketplace_dir}/marketplace.json"
mcp_url="${WIZ_MCP_URL:-https://mcp.app.wiz.io}"

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required but not installed." >&2
  exit 127
fi

mkdir -p "${HOME}/plugins" "${HOME}/.codex/skills" "${HOME}/.codex" "${marketplace_dir}"

rsync -a "${plugin_src}/" "${plugin_dst}/"
rsync -a "${skill_src}/" "${skill_dst}/"

chmod +x \
  "${plugin_dst}/scripts/wiz_scan_fetch.sh" \
  "${skill_dst}/scripts/wiz_scan_fetch.sh"

python3 - "$marketplace_file" <<'PY'
import json
import pathlib
import sys

marketplace_path = pathlib.Path(sys.argv[1])

default = {
    "name": "local-plugins",
    "interface": {"displayName": "Local Plugins"},
    "plugins": [],
}

if marketplace_path.exists():
    data = json.loads(marketplace_path.read_text())
else:
    data = default

plugins = data.setdefault("plugins", [])
entry = {
    "name": "wiz-security",
    "source": {
        "source": "local",
        "path": "./plugins/wiz-security",
    },
    "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL",
    },
    "category": "Coding",
}

for idx, plugin in enumerate(plugins):
    if plugin.get("name") == "wiz-security":
        plugins[idx] = entry
        break
else:
    plugins.append(entry)

marketplace_path.write_text(json.dumps(data, indent=2) + "\n")
PY

python3 - "$codex_config" "$mcp_url" <<'PY'
import os
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
mcp_url = sys.argv[2]
existing = config_path.read_text() if config_path.exists() else ""

service_env = ("WIZ_CLIENT_ID", "WIZ_CLIENT_SECRET", "WIZ_DATACENTER")
present = [name for name in service_env if os.environ.get(name)]
use_service_account = len(present) == len(service_env)

if present and not use_service_account:
    missing = ", ".join(name for name in service_env if name not in present)
    print(
        f"warning: incomplete Wiz service-account environment; missing {missing}. "
        "Falling back to OAuth MCP config.",
        file=sys.stderr,
    )

block_lines = [
    "[mcp_servers.wiz]",
    f'url = "{mcp_url}"',
]

if use_service_account:
    block_lines.append(
        'env_http_headers = { "Wiz-Client-Id" = "WIZ_CLIENT_ID", '
        '"Wiz-Client-Secret" = "WIZ_CLIENT_SECRET", '
        '"Wiz-DataCenter" = "WIZ_DATACENTER" }'
    )

block = "\n".join(block_lines) + "\n"
pattern = re.compile(r"(?ms)^\[mcp_servers\.wiz\]\n(?:.*\n)*?(?=^\[|\Z)")

if pattern.search(existing):
    updated = pattern.sub(block, existing)
else:
    updated = existing
    if updated and not updated.endswith("\n"):
        updated += "\n"
    if updated and not updated.endswith("\n\n"):
        updated += "\n"
    updated += block

config_path.write_text(updated)
PY

if [[ -n "${WIZ_CLIENT_ID:-}" && -n "${WIZ_CLIENT_SECRET:-}" && -n "${WIZ_DATACENTER:-}" ]]; then
  mcp_auth_mode="service-account env_http_headers"
else
  mcp_auth_mode="oauth"
fi

cat <<EOF
Installed Wiz Codex bundle.

Plugin:
  ${plugin_dst}

Standalone skill:
  ${skill_dst}

Marketplace:
  ${marketplace_file}

Codex MCP config:
  ${codex_config}

Wiz MCP URL:
  ${mcp_url}

MCP auth mode:
  ${mcp_auth_mode}

Next steps:
1. If you are using service-account auth, make sure WIZ_CLIENT_ID, WIZ_CLIENT_SECRET, and WIZ_DATACENTER are available before starting Codex
2. Fully quit VS Code
3. Reopen VS Code
4. Start a brand new Codex session
5. Optional: run codex mcp list to verify the Wiz server is registered
6. Ask Codex: Use Wiz to scan this repo and walk me through the top risks
EOF
