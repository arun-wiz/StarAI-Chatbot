---
name: wiz-security
description: Use Wiz to scan a repository, explain active findings, verify fixes, or troubleshoot Wiz-based security analysis. Prefer Wiz MCP when available in the current Codex session. If Wiz MCP is unavailable or does not return detailed findings, fall back to a published wizcli scan plus direct Wiz GraphQL fetch so the response remains specific and grounded in Wiz results.
---

# Wiz Security

Use this skill when the user asks to use Wiz, scan a repo with Wiz, explain Wiz findings, or verify security fixes with Wiz.

## Default approach

1. Prefer Wiz MCP when the session exposes Wiz MCP tools or resources.
2. If Wiz MCP is missing, unconfigured, or not returning detailed findings, use the bundled fallback script:

```bash
scripts/wiz_scan_fetch.sh . "Codex Wiz Review"
```

3. Base the answer only on Wiz-returned findings.
4. For risk walkthroughs, include the Wiz rule name, severity, affected files, found-vs-expected text, and a short explanation.
5. For remediation, fix one finding at a time and rerun Wiz afterward.

## Important rules

- Do not rely on `wizcli scan dir --no-publish` for final analysis because it can hide findings behind policy filtering.
- Prefer the published-scan + GraphQL path when you need raw finding detail.
- If Wiz returns no detailed findings, say that clearly and stop instead of guessing.

## Reference

Read [references/wiz-workflow.md](references/wiz-workflow.md) for the fallback workflow and jq examples.
