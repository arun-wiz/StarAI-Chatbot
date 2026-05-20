# Wiz MCP Tools Reference

Tools used by the wiz-remediate skill and their purpose.

---

## Step 1 — User Identity Resolution (developer scan only)

| Tool | Purpose |
|------|---------|
| `get_code_owner` | Resolve a VCS username to a Wiz internal user ID. Required before using `vcs_code_author` filters in Step 2. |

---

## Step 2 — Data Collection (run in parallel)

### Repository scan

| Tool | Purpose |
|------|---------|
| `list_code_repositories` | Find repo in Wiz, get resource ID for scoped queries |
| `list_container_images` | Find container images built from this repo |
| `graph_search` | Trace runtime footprint — containers, VMs, serverless, network exposure |
| `list_threats` | Active compromise indicators (cryptominer, C2, lateral movement) |
| `list_issues` | Toxic combinations + cloud configuration issues (CRITICAL/HIGH) |
| `list_vulnerability_findings` | Exploitable CVEs scoped to repo (`has_exploit` or `has_cisa_kev_exploit`) |
| `list_attack_surface_findings` | Externally reachable, scanner-validated endpoints |
| `list_secret_findings` | Exposed credentials and secrets (CRITICAL/HIGH) |
| `list_posture_issues` | Validated exploitable vulnerability posture issues |

### Developer scan (by VCS username)

| Tool | Purpose | Key Filter |
|------|---------|------------|
| `list_vulnerability_findings` | Exploitable CVEs in code authored by this user | `vcs_code_author: [<user_id>]` |
| `list_secret_findings` | Secrets committed by this user | `vcs_code_author: [<user_id>]` |
| `list_sast_findings` | SAST code findings in repos this user has committed to | `repository_id` from `get_code_owner` response |
| `list_posture_issues` | Open posture issues (CRITICAL/HIGH) | — |

---

## Step 3 — AI Enrichment (top 3–5 findings)

| Tool | Purpose | AI Agent |
|------|---------|----------|
| `get_green_agent_analysis` | Fetches the Green Agent's remediation analysis for a given issue ID | **Green Agent** — authoritative fix guidance: steps, priority, rationale. Do not invent remediation steps — use only what Green Agent returns. |
| `get_blue_agent_analysis` | Fetches threat investigation analysis for a given issue ID | **Blue Agent** — returns verdict (e.g. `PLANNED_ACTION`, `SECURITY_TEST`, `REAL_THREAT`), confidence level, and timeline. This is the authoritative source for whether a threat is real or an authorized simulation. |
| `get_issue` | Fetches full issue details (metadata, affected resource, cloud context, remediation strategies) | Context for interpreting AI agent output. Also the **fallback remediation source** — use `remediationStrategies` and `resolutionRecommendation` fields when `get_green_agent_analysis` returns no data. |
| `get_issue_security_graph` | Full exposure path for an issue — what is reachable, what is connected, lateral movement risk | Informs blast radius assessment |
| `get_resource_code_to_cloud_pipeline` | Full code→image→runtime provenance for a resource: repo branch, commit, CI/CD job, registry, deployed runtime | Pinpoints the exact code change needed and confirms the fix will propagate through the pipeline |
