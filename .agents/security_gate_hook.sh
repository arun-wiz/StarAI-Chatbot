#!/bin/bash
set -e

# Read JSON payload from stdin
PAYLOAD=$(cat)
COMMAND_LINE=$(echo "$PAYLOAD" | jq -r '.toolCall.args.CommandLine // empty' 2>/dev/null || true)

# Only intercept git push commands; allow everything else immediately
if [[ ! "$COMMAND_LINE" =~ (^|[[:space:];&|])git([[:space:]].*)?[[:space:]]push([[:space:]]|$) ]]; then
  echo '{"decision": "allow"}'
  exit 0
fi

echo "Security Gate: Intercepting git push command..." >&2

# 1. Discover modified files (compare against remote tracking or previous commit)
MODIFIED_FILES=$(git diff --name-only origin/main 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || true)
if [ -z "$MODIFIED_FILES" ]; then
  echo '{"decision": "allow", "reason": "No modified files detected."}'
  exit 0
fi

# 2. Run CodeMender Scan
echo "Running CodeMender scan on changed files: $MODIFIED_FILES" >&2
cm find $MODIFIED_FILES -y --bypass-warning >/dev/null 2>&1 || true

# Get all open findings in JSON format, and filter for files in $MODIFIED_FILES
SCAN_RESULT=$(cm report --status OPEN --format json 2>/dev/null | jq --arg files "$MODIFIED_FILES" '
  ($files | split(" ")) as $mod_files |
  [ .[] | select(.FilePath as $fp | any($mod_files[]; $fp | endswith(.))) ]
' 2>/dev/null || echo '[]')
FINDINGS_COUNT=$(echo "$SCAN_RESULT" | jq 'length' 2>/dev/null || echo '0')

if [ -z "$FINDINGS_COUNT" ] || [ "$FINDINGS_COUNT" -eq 0 ]; then
  echo "No vulnerabilities found. Allowing push." >&2
  echo '{"decision": "allow", "reason": "No vulnerabilities found. Allowing push."}'
  exit 0
fi

echo "Detected $FINDINGS_COUNT vulnerabilities. Attempting automatic remediation..." >&2

# 3. Remediate & Test Loop (RED-GREEN)
RETRY_COUNT=0
MAX_RETRIES=1

# Save findings to a temp file in /tmp to parse robustly with spaces
echo "$SCAN_RESULT" | jq -c '.[]' > /tmp/findings.jsonl

while read -r finding <&3; do
  FINDING_ID=$(echo "$finding" | jq -r '.FindingID')
  
  # RED step: Prompt agent/developer to write a reproduction test
  echo "Vulnerability detected: $FINDING_ID" >&2
  echo "Before applying the fix, you must write a reproducing test that fails (RED)." >&2
  read -p "Add the test and press Enter once it is verified failing..." </dev/tty >&2 || true
  
  while [ $RETRY_COUNT -le $MAX_RETRIES ]; do
    echo "Attempting cm fix for: $FINDING_ID (Attempt: $((RETRY_COUNT+1)))" >&2
    cm fix "$FINDING_ID" -y --bypass-warning >&2
    
    # GREEN step: Run tests to verify the reproduction test now passes
    if python3 -m unittest discover -s tests >&2; then
      echo "Fix successful and tests passed (GREEN)!" >&2
      break
    else
      echo "Fix broke the tests. Reverting changes..." >&2
      git checkout -- . >&2
      RETRY_COUNT=$((RETRY_COUNT+1))
    fi
  done

  # 4. Conflict / Repeated Failure Escalation to HITL
  if [ $RETRY_COUNT -gt $MAX_RETRIES ]; then
    echo "Conflict detected: Fix for $FINDING_ID repeatedly broke tests." >&2
    echo "Escalating to Human-in-the-Loop..." >&2
    
    # Prompt the user
    echo "Select action for finding $FINDING_ID:" >&2
    echo "1) Mute/ignore finding with explanation (gets appended to commit message)" >&2
    echo "2) Verify finding exploitability via cm verify" >&2
    read -p "Enter choice [1-2]: " Choice </dev/tty >&2 || Choice=1

    if [ "$Choice" -eq 1 ]; then
      read -p "Enter suppression justification: " Justification </dev/tty >&2 || Justification="Manually suppressed"
      # Mute the finding in the local db and append suppression to the git commit message
      python3 -c "import sqlite3, sys, os; conn = sqlite3.connect(os.path.expanduser('~/.codemender/state.db')); conn.cursor().execute('UPDATE findings SET status=\"DISMISSED\", dismiss_reason=? WHERE finding_id LIKE ?', (sys.argv[1], sys.argv[2] + \"%\")); conn.commit(); conn.close()" "$Justification" "$FINDING_ID"
      git commit --amend -m "$(git log -1 --pretty=%B) - Suppressed finding $FINDING_ID: $Justification" >&2
    elif [ "$Choice" -eq 2 ]; then
      # Run cm verify to check exploitability
      if cm verify "$FINDING_ID" -y --bypass-warning >&2; then
        echo "Vulnerability confirmed as exploitable! Blocking push." >&2
        rm -f /tmp/findings.jsonl
        echo '{"decision": "deny", "reason": "Exploitable vulnerability '$FINDING_ID' blocking push"}'
        exit 0
      else
        echo "Vulnerability verified as non-exploitable (False Positive). Proceeding." >&2
      fi
    else
      echo "Invalid choice. Blocking push." >&2
      rm -f /tmp/findings.jsonl
      echo '{"decision": "deny", "reason": "Verification failed or cancelled."}'
      exit 0
    fi
  fi
done 3< /tmp/findings.jsonl

# Clean up temp file
rm -f /tmp/findings.jsonl

echo '{"decision": "allow", "reason": "Security gate checks passed."}'