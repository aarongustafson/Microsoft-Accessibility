---
agent: vsd
description: "Defines how the orchestrator validates, resumes from, and manages the deploy-state.json state file. Covers staleness detection, partial stage completion, and preflight skip logic. Referenced by vibeshield-deploy-orchestrator and vsd."
---

# Resume Protocol

When a deployment is interrupted (context window reset, user stops, VS Code restarts), the orchestrator uses `.vibeshield/deploy-state.json` to resume safely.

## State File Location

`.vibeshield/deploy-state.json` — written by the orchestrator after each stage completes. Must be `.gitignore`d (never pushed to the repository).

## Resume Startup Sequence

On every orchestrator invocation, run the consolidated pre-stage script **before** starting any stage. This performs CLI prerequisites, state read, validation, preflight skip decision, and auto-deletion of invalid state in **one terminal call**:

```powershell
./.github/scripts/Invoke-PreStageChecks.ps1 -WorkspacePath .
```

**Terminal mode:** `mode=sync`, `timeout=30000`

The script outputs a JSON object. Use the `Action` field to determine next steps:

| `Action` value | Meaning | Next step |
|----------------|---------|-----------|
| `cli-failed` | az or git not installed / not logged in | Stop — show `CliCheck.Issues` fix instructions |
| `fresh` | No state file found | Start at Stage 1 |
| `deleted-state` | State file was invalid — auto-deleted | Start at Stage 1 |
| `stale` | State file is older than 8 hours | Follow `Validation.Recommendation` — warn user, offer resume or restart |
| `proceed` | Valid state — safe to resume | Resume from `ReadResult.NextStage` |

The JSON also includes:
- `SkipDecision.Skip` — if `true`, skip Stage 1 preflight and start at Stage 2. Tell the user: *"Your last deployment succeeded earlier today. Skipping the readiness check — your environment is still fresh."*
- `SkipDecision.Reason` — explains why preflight is or isn't being skipped
- `ExistingPipelines` — array of existing pipeline definitions (from state file `Pipelines[]`). Used by the orchestrator for Pipeline Intent Detection (see orchestrator agent).
- The user can always override by explicitly requesting preflight (e.g., *"run preflight"*, *"check readiness"*, *"verify my environment"*)

## DeploymentIntent Awareness

When resuming a deployment, the orchestrator reads `DeploymentIntent` from the state file:

| `DeploymentIntent` | Resume Behavior |
|---------------------|-----------------|
| `author-new` | Resume from `NextStage` through all remaining stages (1 → 2 → 3 → 4) |
| `run-existing` | Resume from `NextStage` but skip Stage 1 and Stage 2. Only Stage 3 → 4 run. |
| _(not set)_ | Treat as `author-new` (backward compatibility with pre-intent state files) |

The orchestrator also reads `SelectedPipelineName` and `SelectedPipelineId` from state to pass to the pipeline-push agent as `-SelectedPipelineId` and `-PipelineName`.

For **individual state operations** (e.g., writing state after a stage, deleting on completion), use `Invoke-StateFileManager.ps1` directly with `-Action Write` or `-Action Delete`.

## Staleness Detection

The `Invoke-StateFileManager.ps1 -Action Validate` script performs all staleness checks automatically:

| Condition | Script Behavior | Action |
|-----------|----------------|--------|
| State file older than 8 hours | Sets `Stale = $true`, adds issue to `Issues` array | Warn user: *"Your last deployment was over 8 hours ago. Your Azure environment may have changed since then. I recommend re-checking everything to be safe. Ready to re-run the readiness check, or would you prefer to continue where you left off?"* |
| App type changed | Compares stored `AppType` with `Get-AppType` detection, adds issue | *"Your project files have changed since the last deployment — I'm detecting a different app type now. Starting fresh to make sure everything is configured correctly."* Delete state and start at Stage 1 |
| Resource group no longer exists | Runs `az group exists`, adds issue | *"The Azure resource group from your previous session no longer exists — it may have been deleted. Starting the readiness check to set things up again."* Delete state and start at Stage 1 |
| Different Git branch | Compares `BranchName` with current `git branch --show-current`, adds informational issue | *"You've switched branches since your last deployment (was: [old], now: [new]). I'll continue with the new branch."* |

## Partial Stage Completion

Some stages can be partially completed when interrupted. The `SubStep` field in `deploy-state.json` tracks progress within a stage so the orchestrator can skip completed sub-steps on resume.

**Write `SubStep` at each critical checkpoint within a stage.** Reset it to `$null` when writing the final stage completion.

| Stage | SubStep Value | Meaning | Resume Behavior |
|-------|--------------|---------|------------------|
| Stage 1 (Preflight) | _(none)_ | Script is idempotent | Re-run full preflight |
| Stage 2 (Pipeline Author) | `yaml-generated` | YAML created but not validated | Re-run validation only (Step 2c) |
| Stage 3 (Push) | `pushed` | Code pushed to remote | Skip push, proceed to pipeline registration |
| Stage 3 (Push) | `registered` | Pipeline registered in ADO | Skip push + registration, trigger run |
| Stage 3 (Push) | `triggered` | Run triggered | Skip to Stage 4 |
| Stage 4 (Monitor) | `polling` | Monitoring in progress | Re-start monitoring — script auto-detects latest run |

## Resume Communication

When resuming, display:

> 🔄 **Resuming deployment** — found saved progress from a previous session.
>
> | Detail | Value |
> |--------|-------|
> | Last completed stage | Stage N — [stage name] |
> | Saved at | [timestamp] |
> | App type | [app type] → [Azure service] |
> | Resource group | [resource group] |
>
> Continuing with **Stage N+1 — [next stage name]**.
>
> *If this looks wrong, say **"restart"** to begin fresh.*

## State File Hygiene

- **Update on completion** — After Stage 4 succeeds (deployment verified), write the final state with `LastCompletedStage = 4`. Do NOT delete `deploy-state.json` — it serves as persistent workspace state for the agent across future conversations.
- **Delete only on explicit user restart** — If the user says "restart", delete the state file and begin at Stage 1.
- **Never store secrets** — The state file must never contain tokens, passwords, connection strings, or other credentials.
- **Overwrite, don't append** — Always write the full state object, replacing the previous file.
