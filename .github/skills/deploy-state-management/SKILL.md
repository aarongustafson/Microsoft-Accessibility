---
name: deploy-state-management
description: 'Manage the deploy-state.json state file for deployment resume support. Use when: resume deployment, state file, deployment state, check progress, save state, validate state, staleness check, restart deployment, context window reset, resume interrupted deployment.'
user-invocable: false
---

# State File Management

Manages the `.vibeshield/deploy-state.json` state file that provides persistent workspace state for the VibeShield-Deploy agent across conversations, context-window resets, user stops, and VS Code restarts. Provides Read, Write, Validate, and Delete operations in a single non-interactive script.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Persistent state storage** | Saves deployment progress to `.vibeshield/deploy-state.json` across sessions |
| **Resume support** | Enables interrupted deployments to resume from the last completed stage |
| **CRUD operations** | Read, Write, Validate, and Delete state via a single non-interactive script |
| **Staleness detection** | Detects stale state files (>8 hours) and prompts for fresh start vs resume |
| **Field-level updates** | Supports partial updates to specific state fields without overwriting the entire file |
| **Context-window resilience** | Preserves state across VS Code restarts and context-window resets |
| **State validation** | Validates state file schema and required fields before resume |

## ⚠️ MANDATORY: Execute the Script — Do NOT Re-implement Logic

**You MUST run the PowerShell script below. You MUST NOT manually read/write/validate the state file with inline `Get-Content`, `Set-Content`, or `ConvertFrom-Json` commands.** The script exists specifically to handle staleness detection, field validation, `.gitignore` management, and app-type change detection in a single invocation. Running these steps yourself is **strictly prohibited**.

If the script fails to execute (e.g., PowerShell not available), report the error to the user and ask them to run it manually — do NOT fall back to inline file operations.

## When to Use

- **Orchestrator startup**: Read + Validate to check for a resumable session
- **After each stage completes**: Write to persist progress
- **On deployment completion (Stage 4 success)**: Write the final state with `LastCompletedStage = 4` — do NOT delete
- **On user "restart" command**: Delete and begin fresh at Stage 1

### Integrated State Writes via `-UpdateState`

End-of-stage scripts (`Invoke-Stage2PostRunner.ps1`, `Invoke-PipelinePush.ps1`, `Invoke-DeployMonitor.ps1`) accept `-UpdateState` and `-StateJson` parameters. When passed, the script calls `Write-DeployState` from `SharedHelpers.ps1` internally on success — folding the state write into the same terminal call and eliminating a separate confirmation dialog.

**Use `-UpdateState -StateJson '{...}'` on end-of-stage script calls** instead of a separate `Invoke-StateFileManager.ps1 -Action Write` call after the script completes.

Direct `Invoke-StateFileManager.ps1` calls remain the correct approach for:
- **Read** — checking for resumable state at orchestrator startup
- **Validate** — staleness and consistency checks
- **Delete** — user-requested restart
- **Mid-stage check-level writes** — saving individual check results for check-level resume (e.g., preflight check results)

## Parameters

| Parameter | Required | Source | Example |
|-----------|----------|--------|---------|
| `Action` | Yes | One of: `Read`, `Write`, `Validate`, `Delete` | `Read` |
| `WorkspacePath` | No | Defaults to current directory | `.` |
| `State` | Write only | Hashtable of state values to persist | See State Fields below |

## State Fields

The state hashtable supports these keys. **Only workflow-specific fields belong here** — project config values (AppName, ResourceGroup, Email, ServiceConnection, AppType, TargetAzureService, etc.) live in `infra/config.ps1` and must NOT be duplicated in the state file. Similarly, persistent deployment defaults (tenants, ADO org/project, naming conventions, safety patterns, monitor settings) belong in `.github/config/deploy-config.json` — not in state.

| Field | Required for Write | Description |
|-------|-------------------|-------------|
| `LastCompletedStage` | Yes | `0`=none, `1`=environment-readiness, `2`=workspace+pipeline-author, `3`=pipeline-push, `4`=monitor |
| `SchemaVersion` | Auto-set | Schema version for resume compatibility. Current: `2` (Phase 3 restructured stages). Older state files (v1 or missing) trigger a compatibility warning during Validate. |
| `PipelineYamlPath` | No | Path to the **active** pipeline YAML (the one currently being pushed/monitored). For multi-pipeline workspaces, this is the user's selected pipeline. |
| `AdoOrgUrl` | No | Azure DevOps organization URL |
| `AdoProject` | No | Azure DevOps project name |
| `BranchName` | No | Git branch name |
| `PipelineName` | No | Registered pipeline name (active pipeline) |
| `RunId` | No | Latest pipeline run ID (active pipeline) |
| `PipelineId` | No | Pipeline definition ID (active pipeline) |
| `Pipelines` | No | Array of pipeline-file-to-ADO-definition mappings. Each entry: `{ YmlPath, PipelineName, PipelineId, LastRunId, LastRunStatus }`. Persisted across sessions so the agent remembers which pipeline files map to which ADO pipelines. Updated by Stage 3 after pipeline registration. |
| `SubStep` | No | Sub-step within the current stage for mid-stage resume (e.g., `pushed`, `registered`, `triggered`) |
| `Ev2HandoverPending` | No | Boolean. `true` when the orchestrator has presented the EV2 handover prompt to the user and is waiting for them to run `/ev2` and return. Cleared when artifacts are verified or user says "skip ev2". |
| `Ev2HandoverData` | No | Object containing `{ resolved, missing, handoverPrompt }` from `Get-Ev2HandoverData`. Persisted so the handover survives context window resets. Cleared alongside `Ev2HandoverPending`. |

The script auto-adds `Timestamp` (ISO 8601) on every Write.

## Procedure

### Read — Check for Existing State

```powershell
$result = ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Read -WorkspacePath .
```

**Return object:**

| Property | Type | Description |
|----------|------|-------------|
| `Found` | bool | Whether `deploy-state.json` exists |
| `State` | object | Parsed state object (or `$null`) |
| `LastCompletedStage` | int | Stage number from state (or `0`) |
| `StageName` | string | Human-readable stage name |
| `NextStage` | int | `LastCompletedStage + 1` |
| `Message` | string | Summary message |

### Write — Save Progress After Stage Completion

```powershell
$state = @{
    LastCompletedStage    = 1
    PipelineYamlPath      = '.azdo/pipelines/azure-pipeline.yml'
    AdoOrgUrl             = 'https://dev.azure.com/oneCELA'
    AdoProject            = 'CELA_Demos_and_POCs'
    BranchName            = 'main'
}
./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Write -WorkspacePath . -State $state
```

> **Do NOT include** `AppName`, `ResourceGroup`, `Email`, `ServiceConnectionName`, `AppType`, or `TargetAzureService` — those belong in `infra/config.ps1`.

The script automatically:
- Adds `Timestamp` in ISO 8601 format
- Ensures `.vibeshield/` directory exists
- Adds `.vibeshield/deploy-state.json` to `.gitignore` if not already present

### Write — Save Check-Level Results (Mid-Stage)

After a stage script runs (even if some checks fail), write the individual check results so the agent can resume from the failed check instead of re-running all checks:

```powershell
# Read existing state first to preserve other fields
$readResult = ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Read -WorkspacePath .
$existingState = if ($readResult.Found) { $readResult.State } else { @{} }

# Build check results from script output
$checkResults = @{
    '1' = @{
        'PF-09' = 'PASS'
        'PF-10' = 'PASS'
        'PF-01' = 'PASS'
        'PF-02' = 'FAIL'
        'LastCheckRun' = 'PF-02'
        'Timestamp' = (Get-Date -Format 'o')
    }
}

# Merge with any existing check results from other stages
if ($existingState.PSObject -and $existingState.PSObject.Properties['StageCheckResults']) {
    $existing = $existingState.StageCheckResults
    foreach ($key in $checkResults.Keys) { $existing.$key = $checkResults[$key] }
    $checkResults = $existing
}

$state = @{
    LastCompletedStage = 0   # Stage not yet complete — checks still failing
    StageCheckResults  = $checkResults
}
./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Write -WorkspacePath . -State $state
```

**Rules for `StageCheckResults`:**

- Keys are stage numbers as strings (`"1"`, `"2"`, `"3"`, `"4"`)
- Each stage maps check IDs (e.g., `PF-09`, `PA-01`, `PP-01`, `MO-01`) to their status: `PASS`, `FAIL`, `WARN`, `SKIP`
- Include `LastCheckRun` — the ID of the last check that executed (helps identify resume point)
- Include `Timestamp` — when the check run occurred (stale results older than 8h should be discarded)
- **Clear the stage's check results** when the stage completes successfully (set `LastCompletedStage` and remove the stage key from `StageCheckResults`)
- **Clear all check results** on `Delete` (handled automatically by the script)
- On stage re-run, pass previously-passed check IDs to the script via `-SkipChecks` so it skips them

**Agent workflow for check-level resume:**

1. Run the stage script
2. Parse the output — collect each check's status (`PASS` / `FAIL` / `WARN` / `SKIP`)
3. Write `StageCheckResults` to state (preserving other stages' results)
4. If all checks passed → set `LastCompletedStage` and clear the stage's check results
5. If any checks failed → keep `LastCompletedStage` unchanged, remediate failures
6. On re-run after remediation → read state, extract passed check IDs, pass them to the script via `-SkipChecks`

### Validate — Check State for Staleness and Consistency

```powershell
$validation = ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Validate -WorkspacePath .
```

**Return object:**

| Property | Type | Description |
|----------|------|-------------|
| `Valid` | bool | Whether state passes all validation checks |
| `Stale` | bool | Whether state is older than 8 hours |
| `Issues` | string[] | List of detected issues |
| `Recommendation` | string | Suggested action (`resume`, `warn-and-offer`, or `restart`) |
| `State` | object | The validated state object |

**Validation checks performed:**
1. All required fields present (`LastCompletedStage`, `Timestamp`)
2. State file age (>8h = stale)
3. App type changed (compares `AppType` from `infra/config.ps1` or `Get-AppType` detection)
4. Resource group still exists (reads `ResourceGroup` from `infra/config.ps1`, not state)
5. Branch mismatch (informational — does not invalidate)

### Delete — Remove State File (User Restart Only)

Only delete the state file when the user explicitly requests a restart. Do NOT delete after successful deployment.

```powershell
./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Delete -WorkspacePath .
```

Also removes all `.sarif` and `.sarif.bak` files from `.vibeshield/results/` to prevent stale reports from prior deployment attempts.

**Return object:**

| Property | Type | Description |
|----------|------|-------------|
| `Deleted` | bool | Whether the state file was successfully deleted |
| `Path` | string | Path that was deleted |
| `CleanedSarif` | string[] | Names of SARIF files removed |

## Resume Decision Flow

Use this flow at orchestrator startup:

```
1. Read state file
   ├─ Not found → Fresh deployment, start Stage 1
   └─ Found → Validate
       ├─ Valid, LastCompletedStage=4, Timestamp is today → Skip Stage 1, start Stage 2
       ├─ Valid, LastCompletedStage=4, Timestamp is older → Start Stage 1 (infra may have changed)
       ├─ Valid, not stale, LastCompletedStage<4 → Resume from NextStage
       │   └─ StageCheckResults present for NextStage?
       │       ├─ Yes, has PASS checks → Pass them via -SkipChecks to skip re-validation
       │       └─ No → Run all checks from scratch
       ├─ Valid, stale → Warn user, offer resume or restart
       │   └─ StageCheckResults present? → Discard (stale) — run all checks fresh
       ├─ Invalid (missing fields) → Delete and start fresh
       ├─ Invalid (app type changed) → Delete and start fresh
       └─ Invalid (RG missing) → Delete and start fresh
```

User can always override the preflight skip by explicitly requesting it (e.g., "run preflight", "check readiness").

## Security Rules

- **Never store secrets, tokens, or passwords** in the state file
- State file is always `.gitignore`d — the script enforces this on every Write
- Do NOT delete state file on deployment completion — it persists as workspace state
- Delete state file only when the user explicitly requests a restart

## Relationship to `infra/config.ps1`

`deploy-state.json` and `infra/config.ps1` serve different purposes and **must not overlap**:

| Aspect | `deploy-state.json` | `infra/config.ps1` |
|--------|--------------------|--------------------|
| **Scope** | Workflow state (`.gitignore`d) | Project config (committed) |
| **Lifetime** | Persists across deployments, deleted only on user restart | Permanent — survives across deployments |
| **Onboarding** | Not used — SC existence is verified at runtime via `Test-ServiceConnectionExists` | Stores provisioned values (`Username`, `UamiClientId`, `ServiceConnection`, etc.) |
| **Tracked in git** | No (`.gitignore`d) | Yes (committed) |
| **Staleness** | No expiry (stage-based resume) | No expiry |
| **Contains** | Deployment progress, stage state, run IDs | User identity, infrastructure names, build pool, AppType, TargetAzureService |
| **Does NOT contain** | AppName, ResourceGroup, Email, ServiceConnection, AppType, TargetAzureService (these are in config.ps1) | Workflow state, pipeline run metadata |

`infra/config.ps1` stores the 14 project keys (`ResourceGroup`, `AppName`, `Location`, `ServiceConnection`, `Username`, `Email`, `UserObjectId`, `MgmtResourceGroup`, `UamiName`, `UamiClientId`, `AppType`, `TargetAzureService`, `BuildPool`, `BuildPoolOs`). This file is **exclusively created and owned by `vibeshield-bicep`** — no VibeShield-Deploy agent or script may write to it. All agents and scripts read these values by dot-sourcing the file: `. ./infra/config.ps1`.

`Get-DeployContext` in `SharedHelpers.ps1` enforces this separation: config.ps1 is tier 1 (highest priority for project config), deploy-state.json is tier 2 (workflow state only). The state file's stateMap only reads `AdoOrgUrl` and `AdoProject` — the only workflow-specific fields not in config.ps1.
