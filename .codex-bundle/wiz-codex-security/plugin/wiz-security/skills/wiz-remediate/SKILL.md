---
name: wiz-remediate
description: Use Wiz to scan a repository, explain active findings, and remediate one issue at a time. Prefer Wiz MCP when it is available in the current Codex session. If Wiz MCP is unavailable or does not return detailed findings, fall back to a published wizcli scan plus direct Wiz GraphQL fetch so the analysis stays specific and Wiz-based.
disable-model-invocation: true
---

# Wiz Remediate

Use Wiz as the source of truth for repository security review and remediation.

## Workflow

1. Prefer Wiz MCP first.
   If the current Codex session exposes Wiz MCP tools or resources, use them to retrieve detailed findings and issue context.

2. Fall back to published Wiz scan + API fetch when MCP is unavailable.
   Read [references/wiz-codex-fallback.md](references/wiz-codex-fallback.md) and run:

   ```bash
   ../../../../scripts/wiz_scan_fetch.sh . "Codex Wiz Review"
   ```

3. Analyze only returned Wiz findings.
   Do not infer risks from the repo alone when the user asked for a Wiz-based answer.

4. Rank findings by severity first, then by affected resource count.

5. If the user asks for fixes, remediate one finding at a time and rerun Wiz after each meaningful fix.

## What to include in the answer

- Wiz rule name
- Wiz severity
- Affected file paths and line numbers when present
- Found vs expected text
- Short explanation of why the finding matters
- Whether the finding was policy-filtered or below threshold, if that is visible

## Remediation rules

- Show the planned fix before changing code.
- Apply one issue at a time.
- After edits, rerun the fallback scan or Wiz MCP query to verify the result changed.
- If Wiz data is incomplete, say so clearly instead of guessing.
