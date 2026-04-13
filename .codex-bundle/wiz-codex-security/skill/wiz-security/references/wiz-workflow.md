# Wiz Workflow

## MCP-first

If Wiz MCP is available in the current Codex session, use it first for detailed finding retrieval.

## API fallback

If Wiz MCP is not available or cannot return detailed findings, run:

```bash
scripts/wiz_scan_fetch.sh . "Codex Wiz Review"
```

This publishes a Wiz scan, extracts the persisted scan id, and queries `cicdScan.resultJSON`
from the Wiz GraphQL API using `~/.wiz/auth.json`.

## jq examples

Summary:

```bash
jq '.summary'
```

Grouped IaC findings:

```bash
jq '.cicdScan.resultJSON.iac.ruleMatches[] | {
  rule: .rule.name,
  severity,
  failedResourceCount,
  affected: [.matches[] | {
    file: .fileName,
    line: .lineNumber,
    found: .found,
    expected: .expected,
    content: .matchContent
  }]
}'
```
