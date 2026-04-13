---
name: wiz-update
description: Update the Wiz Codex plugin and skills to the latest version. Supports a git-based install from the public repository. Use when the user asks to update or upgrade the Wiz skills.
disable-model-invocation: true
---

# Wiz Skills Updater

Update the Wiz Codex plugin and skills to the latest version.

## Step 1 — Locate the install directory

```bash
INSTALL_DIR="$HOME/plugins/wiz-security"

if [ ! -d "$INSTALL_DIR" ]; then
  echo "❌ Wiz AI skills not found at $INSTALL_DIR"
  echo "   Please install first — see README for installation instructions:"
  echo "   https://github.com/wiz-sec/wiz-ai-skills"
  exit 1
fi
```

## Step 2 — Update from git

```bash
echo "⬇️  Fetching latest changes..."
git -C "$INSTALL_DIR" pull --ff-only origin main
```

## Step 3 — List updated skills

```bash
echo ""
echo "📦 Available skills:"
for skill_dir in "$INSTALL_DIR/wiz-security/skills"/*/; do
  skill_name=$(basename "$skill_dir")
  echo "   • /$skill_name"
done
echo ""
echo "Restart Codex after updating, then run /wiz-remediate to get started."
```
