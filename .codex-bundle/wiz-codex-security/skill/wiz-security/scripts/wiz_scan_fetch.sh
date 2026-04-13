#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: wiz_scan_fetch.sh [scan_path] [scan_name]

Publishes a Wiz directory scan with wizcli, then fetches the full cicdScan
resultJSON payload from the Wiz GraphQL API using ~/.wiz/auth.json.

Arguments:
  scan_path  Path to scan. Defaults to current directory.
  scan_name  Optional Wiz scan name.
EOF
  exit 0
fi

if ! command -v wizcli >/dev/null 2>&1; then
  echo "wizcli is required but not installed." >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed." >&2
  exit 127
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but not installed." >&2
  exit 127
fi

scan_path="${1:-.}"
scan_name="${2:-Codex Wiz Scan $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
auth_file="${WIZ_AUTH_FILE:-$HOME/.wiz/auth.json}"

tmp_scan="$(mktemp -t wiz-cli-scan.XXXXXX.json)"
tmp_query="$(mktemp -t wiz-graphql-query.XXXXXX.json)"
tmp_response="$(mktemp -t wiz-graphql-response.XXXXXX.json)"
cleanup() {
  rm -f "$tmp_scan" "$tmp_query" "$tmp_response"
}
trap cleanup EXIT

wizcli scan dir "$scan_path" --name "$scan_name" --stdout json >"$tmp_scan"

scan_id="$(jq -r '.id // empty' "$tmp_scan")"
if [[ -z "$scan_id" ]]; then
  echo "Unable to extract a Wiz scan id from wizcli output." >&2
  cat "$tmp_scan" >&2
  exit 1
fi

if [[ ! -f "$auth_file" ]]; then
  echo "Missing Wiz auth file: $auth_file" >&2
  exit 1
fi

access_token="$(jq -r '.access_token // empty' "$auth_file")"
data_center="$(jq -r '.data_center // empty' "$auth_file")"
if [[ -z "$access_token" || -z "$data_center" ]]; then
  echo "Wiz auth file is missing access_token or data_center." >&2
  exit 1
fi

jq -nc \
  --arg id "$scan_id" \
  '{
    query: "query($id: ID!) { cicdScan(id: $id) { id createdAt startedAt status { state verdict } reportUrl resultJSON } }",
    variables: {id: $id}
  }' >"$tmp_query"

curl -sS "https://api.${data_center}.app.wiz.io/graphql" \
  -H "Authorization: Bearer ${access_token}" \
  -H "Content-Type: application/json" \
  --data @"$tmp_query" >"$tmp_response"

if jq -e '.errors? and (.errors | length > 0)' "$tmp_response" >/dev/null; then
  cat "$tmp_response"
  exit 2
fi

jq -n \
  --slurpfile cli "$tmp_scan" \
  --slurpfile api "$tmp_response" \
  '{
    cli_scan: $cli[0],
    api_response: $api[0],
    cicdScan: $api[0].data.cicdScan,
    summary: {
      scan_id: $api[0].data.cicdScan.id,
      verdict: $api[0].data.cicdScan.status.verdict,
      report_url: $api[0].data.cicdScan.reportUrl,
      iac_rule_match_groups: (($api[0].data.cicdScan.resultJSON.iac.ruleMatches // []) | length),
      iac_total_matches: ($api[0].data.cicdScan.resultJSON.iac.scanStatistics.totalMatches // 0),
      sast_total: ($api[0].data.cicdScan.resultJSON.analytics.sast.totalCount // 0),
      secret_total: ($api[0].data.cicdScan.resultJSON.analytics.secrets.totalCount // 0),
      vulnerability_total: ($api[0].data.cicdScan.resultJSON.analytics.vulnerabilities.totalCount // 0)
    }
  }'
