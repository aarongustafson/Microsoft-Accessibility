---
agent: vsd
description: "Defines when and how the orchestrator loops back to a previous stage to fix issues discovered in a later stage. Covers loop-back routing table, max 2 loop-backs, and non-loopable failures. Referenced by vibeshield-deploy-orchestrator and vsd."
---

# Cross-Stage Retry Protocol

When a later stage discovers an issue that can only be fixed by re-running an earlier stage, the orchestrator follows this protocol.

## When to Loop Back

> **Scripted implementation:** The routing table below is implemented in the `Get-CrossStageRetryTarget` function in `.github/scripts/SharedHelpers.ps1`. Call it with `-DiscoveringStage` (1-4) and `-IssueType` to get `@{ TargetStage; Path; Loopable; Reason }`. Non-loopable issue types (RBAC, Quota, Compliance, SecretFound, SCMissing, RGMissing) return `Loopable = $false`.

| Discovering Stage | Issue Type | Loop-Back Target | Path |
|-------------------|-----------|-----------------|------|
| **Stage 4 (Monitor)** | Bicep/infrastructure error | Stage 1 (Preflight) | Monitor → Orchestrator → Preflight → vibeshield-bicep → Preflight re-validates → Orchestrator resumes at Stage 3 |
| **Stage 4 (Monitor)** | Pipeline YAML error (wrong task, missing step) | Stage 2 (Pipeline Author) | Monitor → Orchestrator → Pipeline Author fixes YAML → Orchestrator resumes at Stage 3 |
| **Stage 4 (Monitor)** | Build error requiring code fix | Stage 3 (Code Push) | Monitor applies code fix → Orchestrator re-delegates to Pipeline Push → resumes at Stage 4 |
| **Stage 4 (Monitor)** | SC authorization failure | Stage 2 (Pipeline Author) | Monitor → Orchestrator → Pipeline Author re-authorizes SC → Orchestrator resumes at Stage 3 |
| **Stage 3 (Push)** | Missing `infra/main.bicep` | Stage 1 (Preflight) | Push → Orchestrator → Preflight → vibeshield-bicep → Preflight re-validates → Orchestrator resumes at Stage 2 |
| **Stage 3 (Push)** | Bicep lacks required resources (PP-06c) | Stage 1 (Preflight) | Push → Orchestrator → Preflight → vibeshield-bicep adds resources → Preflight re-validates → Orchestrator resumes at Stage 3 |
| **Stage 3 (Push)** | Bicep invalid or not deployable | Stage 1 (Preflight) | Push → Orchestrator → Preflight → vibeshield-bicep fixes templates → Preflight re-validates → Orchestrator resumes at Stage 3 |
| **Stage 3 (Push)** | Pipeline YAML issue (missing stage, wrong task) | Stage 2 (Pipeline Author) | Push → Orchestrator → Pipeline Author fixes YAML → Orchestrator resumes at Stage 3 |

## Loop-Back Rules

1. **Always re-push after a fix** — If a loop-back modifies any file (Bicep, pipeline YAML, source code), Stage 3 (Code Push) must re-run before Stage 4 monitors the new run.
2. **Maximum 2 loop-backs per deployment** — Enforced by the `LoopBackCount` field in `deploy-state.json` and the `Get-CrossStageRetryTarget` function (which returns `Loopable = $false` when count ≥ 2). If the same issue recurs after 2 loop-back cycles, escalate to the user with the full error history. Do not loop indefinitely.
3. **Preserve retry count** — Loop-backs do NOT reset the monitor's 3-retry counter. If 2 retries were used before the loop-back, only 1 retry remains after.
4. **Update state file** — After a loop-back, update `deploy-state.json` with:
   - `LastCompletedStage` set to the stage that was re-run (e.g., if looping back to Stage 2, set `LastCompletedStage = 1`)
   - `LoopBackCount` incremented by 1
   - `LastLoopBackError` set to the `IssueType` that triggered the loop-back
   - `LoopBackErrorMessage` set to the specific error message from pipeline logs
   - `LoopBackFailedStage` set to the pipeline stage name that failed (e.g., `Provision`, `Deploy`)
   - `LoopBackFailedResource` set to the resource name/type from the error (if identifiable)
   - `LoopBackRunId` set to the pipeline RunId that failed
5. **Announce the loop-back** — Always explain to the user:
   > 🔄 **Going back to fix something.**
   > The pipeline found an issue with [plain-language description]. I need to go back to [Stage N] to fix it, then re-upload the changes.
   > This is normal — it happens when the pipeline discovers something that wasn't caught earlier.

## Loop-Back Communication Template

```
🔄 **Loop-back: Stage 4 → Stage N**

**What happened**: [Plain-language description of the failure]
**Root cause**: [Why this wasn't caught earlier]
**What I'm doing**: Going back to Stage N to [specific fix action]
**After the fix**: I'll re-upload the code (Stage 3) and restart monitoring (Stage 4)

This adds about [N] minutes to the deployment. You don't need to do anything — I'll handle it.
```

## Non-Loopable Failures

These failures cannot be fixed by looping back — they require user or admin action:

| Failure Type | Action |
|-------------|--------|
| RBAC/permission errors | Escalate to AI4CELA SPEAR team |
| Quota exceeded | User must request quota increase or change region |
| Compliance failures (CredScan, PoliCheck) | User must fix source code |
| Service connection missing | Direct user to contact CELA SPEAR team to provision the SC |
| Resource group missing | Direct user to contact CELA SPEAR team — agents must **never** create resource groups directly |
