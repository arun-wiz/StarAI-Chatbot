# Wiz Codex Fallback

Use this reference when Wiz MCP is unavailable or does not expose detailed findings.

## Authoritative fallback

Run:

```bash
../../../../scripts/wiz_scan_fetch.sh . "Codex Wiz Review"
```

The script:

1. Publishes a Wiz directory scan with `wizcli scan dir`
2. Extracts the persisted scan id
3. Calls the Wiz GraphQL API using `~/.wiz/auth.json`
4. Returns the raw `cicdScan.resultJSON` payload plus a compact summary

## Why this fallback exists

`wizcli scan dir --no-publish` and some CLI export formats can hide findings behind
policy filtering. The published-scan + GraphQL path returns the raw grouped finding
objects that are needed for a specific Wiz-based analysis.

## Useful jq snippets

Top-level summary:

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

Flattened IaC matches:

```bash
jq '.cicdScan.resultJSON.iac.ruleMatches[]
| .rule.name as $rule
| .severity as $severity
| .matches[]
| {
    rule: $rule,
    severity: $severity,
    file: .fileName,
    line: .lineNumber,
    found: .found,
    expected: .expected,
    content: .matchContent
  }'
```

## Reporting rules

- Base conclusions only on Wiz-returned findings.
- Include rule name, severity, affected files, and found-vs-expected text.
- If Wiz returns no detailed findings, say that clearly and stop rather than inferring.
