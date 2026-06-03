---
name: deploy-monitor
description: 'Monitor & Verify: poll pipeline status, health check deployed app, verify deployed version, diagnose failures, retry logic with max 3 attempts, escalation summary. Use when: monitor pipeline, check deployment status, pipeline failed, health check, verify deployment, troubleshoot deployment error.'
user-invocable: true
---

# Deploy Monitor Skill

Monitor an Azure DevOps pipeline run, perform post-deployment health checks, verify the deployed version, and retry on failure.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Pipeline status polling** | Polls Azure DevOps pipeline run status at configurable intervals until terminal state |
| **Stage-level monitoring** | Tracks Build, Test, Deploy, and Compliance stages individually with duration and progress |
| **Health check probing** | Verifies deployed app responds with HTTP 200 at its public URL after deployment |
| **Version verification** | Confirms deployed source commit matches the local HEAD |
| **Failure diagnosis** | Classifies pipeline errors and provides actionable remediation guidance |
| **Bounded retry logic** | Retries failed runs up to 3 times with per-category deduplication |
| **Structured escalation** | Produces a comprehensive failure summary after exhausting retries |
| **SARIF reporting** | Emits SARIF 2.1.0 results for pipeline run outcomes |

## Script

**MANDATORY**: Execute `Invoke-DeployMonitor.ps1` for all monitoring operations. Do NOT run individual `az` CLI commands to replicate what the script does.

This is a **long-running script** (10–60 minutes). Follow the async protocol in `deploy-shared-rules.prompt.md` → "Script Execution Modes" → "Long-Running Scripts".

```
.github/skills/deploy-monitor/scripts/Invoke-DeployMonitor.ps1
```

Supporting functions (dot-sourced automatically):
```
.github/skills/deploy-monitor/scripts/DeployMonitor.Functions.ps1
```

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `-RunId` | Pipeline run ID to monitor (auto-detected if omitted) |
| `-PipelineName` | Pipeline name, e.g. `VibeShield-Deploy-<repo>` (defaults to repo-derived name) |
| `-BranchName` | Branch the code was pushed to (defaults to current git branch) |
| `-AdoOrgUrl` | Azure DevOps organization URL |
| `-AdoProject` | Azure DevOps project name |
| `-AppUrl` | Deployed application URL for health check |
| `-TargetService` | `AppService`, `ContainerApps`, `Functions`, or `StaticWebApps` |
| `-AppName` | Azure resource name of the deployed app |
| `-ResourceGroup` | Azure resource group containing the app (auto-detected from `infra/config.ps1` if available) |

### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-PollIntervalSec` | 30 | Seconds between status polls |
| `-ReportIntervalSec` | 60 | Seconds between detailed progress reports (stage breakdown) |
| `-TimeoutMinutes` | 60 | Max minutes to wait per pipeline run |
| `-TotalTimeoutMinutes` | 90 | Max minutes across ALL retries combined (prevents 3 × 60 min = 180 min blocking) |
| `-MaxRetries` | 3 | Maximum retry attempts on failure |
| `-SkipHealthCheck` | false | Skip HTTP health check |
| `-SkipVersionCheck` | false | Skip source version verification |
| `-SarifPath` | `.vibeshield/results/deploy-monitor-results.sarif` | Custom SARIF output path |

## Example

```powershell
./.github/skills/deploy-monitor/scripts/Invoke-DeployMonitor.ps1 `
    -RunId 12345 `
    -PipelineName 'VibeShield-Deploy-MyApp' `
    -BranchName 'users/alice/deploy' `
    -AdoOrgUrl 'https://dev.azure.com/my-org' `
    -AdoProject 'MyProject' `
    -AppUrl 'https://myapp.azurewebsites.net' `
    -TargetService 'AppService' `
    -AppName 'myapp' `
    -ResourceGroup 'rg-myapp-dev-eus'
```

## Checks

| ID | Check | Description |
|----|-------|-------------|
| MO-01 | Build stage | Build stage completed successfully |
| MO-02 | Deploy stage | Deploy stage completed successfully |
| MO-03 | Pipeline result | Overall pipeline run result |
| MO-04 | Health check | HTTP GET to app URL returns 200 |
| MO-05 | Version match | Deployed source version matches local HEAD |
| MO-06 | Deployed Resources | Azure resources discovered in the target resource group |

## Behavior

1. **Clean start** — the script handles SARIF cleanup internally
2. **Poll** — checks pipeline status every 30s until terminal state. **Polling is fully autonomous and non-interactive.** The agent never asks the user whether to continue polling, check status, or wait longer. The user may interrupt to stop, but the agent never solicits permission to continue.
3. **Progress report** — every 60s emits a detailed stage-by-stage breakdown with elapsed time, then resumes monitoring automatically
4. **Classify** — determines build vs deploy stage outcomes
4. **Health check** — HTTP GET to app URL (retries once after 30s)
5. **Version verify** — compares pipeline `sourceVersion` with `git rev-parse HEAD`
6. **Retry on failure** — re-triggers pipeline from the same branch. Retries are tracked **per failure category**: the same category escalates after 3 occurrences, and a **hard cap of 2×MaxRetries (6) total retries** (across all categories) prevents runaway loops. Distinct failures that are each fixed on the first attempt do not count against each other.
7. **Escalate** — structured summary after per-category limit or hard cap is reached
8. **SARIF** — emits report to `.vibeshield/results/deploy-monitor-results.sarif`

### OneBranch / EV2 Considerations

The monitor is largely framework-agnostic — it polls by `RunId` regardless of framework. However:

- **OneBranch pipelines**: The Buddy pipeline is typically monitored during CI. The Official pipeline runs on `main` merge and may be monitored separately. The `PipelineName` parameter distinguishes them (e.g., `VibeShield-Deploy-MyApp-Buddy` vs `VibeShield-Deploy-MyApp-Official`).
- **EV2 deploy stages**: When `infraDeploy` is `EV2`, the Provision stage uses `Ev2RARollout@2` instead of `AzureCLI@2`. EV2 failures produce different error patterns (rollout failures, service group validation errors, region-scoped failures). The `deploy-deployment-diagnostics` skill handles EV2-specific failure classification.
- **EV2 stage names**: EV2 deploy stages have parameterized names (e.g., `Test_Deploy_WestUS2`). The monitor should not assume stage names are `Build`, `Provision`, `Deploy` — it reads actual stage names from the pipeline run.

## Failure Diagnosis

On failure, load the **`deploy-deployment-diagnostics`** skill from `.github/skills/deploy-deployment-diagnostics/SKILL.md` for classification patterns and remediation guidance.

### Failure Categories

| Category | Retryable | Action |
|----------|-----------|--------|
| Build | Yes | Fix source errors, re-trigger |
| Authentication | Yes | Re-authenticate, re-trigger |
| SC Authorization Pending | Yes | Authorize in ADO portal, re-trigger |
| Deployment | Yes | Check resource config, re-trigger |
| Bicep/Infrastructure | No | Escalate to vibeshield-bicep agent |
| Compliance | No | Escalate with compliance details |

## Output

The script emits a SARIF 2.1.0 report automatically. After execution:
1. Provide the pipeline run URL from the script's **Run Logs** banner line: `<AdoOrgUrl>/<AdoProject>/_build/results?buildId=<RunId>`
2. Reference the SARIF path for the user
3. Print a check-by-check summary with ✅/❌/⚠️/⏭️ status
4. On success, print a **DEPLOYMENT SUMMARY** block with per-stage task details, deployed resources (from `-ResourceGroup`), and post-deployment check results
5. Suggest related follow-up prompts

## CGRP Reminder

Before classifying errors, retrying, or reporting health-check results, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to monitoring:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 3 | Blind Fix | Retrying or escalating without reading the full error log |
| 4 | Hedging | Saying "the deployment probably succeeded" without a health-check response |
| 8 | Memory Conflict | Using a health-check URL or app name that contradicts the Bicep/pipeline output |

If any signal fires: **Stop → Verify → Pivot** before continuing.
