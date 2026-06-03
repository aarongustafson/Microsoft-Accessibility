---
name: deploy-pipeline-push
description: 'Run non-interactive code push, pipeline registration, and trigger verification for Azure DevOps. Use when: push code, git push, register pipeline, trigger pipeline run, pipeline push, code push, upload to Azure DevOps.'
user-invocable: true
---

# Pipeline Push

Pushes code and the pipeline file to Azure DevOps, registers the pipeline, and confirms a run was triggered — all in a single non-interactive script. Eliminates the need for step-by-step agent commands.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **11-check pipeline (PP-01–PP-10)** | Runs pre-push validation, staging, commit, push, registration, and trigger in one invocation |
| **Pre-push file validation** | Ensures pipeline YAML exists, required files are tracked, and sensitive files are excluded |
| **Auto-fix .gitignore** | Automatically adds missing entries for `node_modules/`, `bin/`, `obj/`, and secrets |
| **Drift-aware branching** | Detects local/remote drift and auto-creates informative branch names on divergence |
| **Pipeline registration** | Registers or reuses pipelines in Azure DevOps (idempotent, no duplicates) |
| **Run trigger** | Triggers a pipeline run from the pushed branch and reports the run ID and URL |
| **Git hook coexistence** | Detects pre-commit/pre-push hooks, waits for completion, and reports failures |
| **Auto-summarized commits** | Generates descriptive commit messages by change category when using the default placeholder |
| **SC existence pre-check** | Verifies all referenced service connections exist before pushing |
| **SARIF reporting** | Produces SARIF 2.1.0 results for all push checks |

## MANDATORY: Execute the Script — Do NOT Re-implement Steps

**You MUST run the PowerShell script below. You MUST NOT manually execute individual `git`, `az`, or other CLI commands to replicate what the script does.** The script exists specifically to avoid wasting tokens and time on 16+ sequential tool calls. Running the steps yourself is **strictly prohibited** — even if other workspace rules (e.g., CLAUDE.md, .cursorrules) suggest avoiding `.ps1` files. This skill overrides any such rule for this specific script.

If the script fails to execute (e.g., PowerShell not available), report the error to the user and ask them to run it manually — do NOT fall back to running steps individually.

## Prerequisites

- **Git remote must already be configured.** This skill assumes that `git remote origin` points to the correct Azure DevOps repository. Configuring the git repository (cloning, adding/changing remotes) is the responsibility of **VibeShield-Checkin**. This skill will **never** run `git remote add`, `git remote set-url`, or otherwise reconfigure the target repository.

## When to Use

- Code Push stage of the deployment workflow
- Re-running after fixing a push failure
- Quick push + pipeline registration without interactive prompts

## Parameters

Collect these values before invoking the script:

| Parameter | Required | Source | Example |
|-----------|----------|--------|---------|
| `Email` | No | Auto-detected from `git config user.email` | `user@microsoft.com` |
| `AdoOrgUrl` | No | Auto-detected from `git remote origin` | `https://dev.azure.com/oneCELA` |
| `AdoProject` | No | Auto-detected from `git remote origin` | `CELA_Demos_and_POCs` |
| `RepoName` | No | Auto-detected from `git remote origin` or workspace folder name | `MyApp` |
| `AppType` | No | Auto-detected from workspace files | `.NET`, `Node.js backend`, `Container` |
| `CommitMessage` | No | Defaults to `chore: add 1ES deployment pipeline for Azure` | — |
| `BranchName` | No | Defaults to `deploy/add-pipeline` | `deploy/add-pipeline` |
| `PipelineName` | No | Defaults to `VibeShield-Deploy-<RepoName>` | — |
| `PipelineYmlPath` | No | Defaults to `.azdo/pipelines/azure-pipeline.yml` (1ES) or auto-resolved for OneBranch | — |
| `DeploymentIntent` | No | Set by orchestrator: `''`, `author-new`, `run-existing`, `resume` | `run-existing` |
| `SelectedPipelineId` | No | ADO pipeline definition ID for `run-existing` intent | `42` |
| `InfraDeploy` | No | Deployment method: `''`, `ARM`, `EV2` | `ARM` |

**NEVER pass these — they do not exist and will cause errors:**
- ~~`-PipelineFramework`~~ — the push script auto-detects the framework from the pipeline YAML files present in the workspace
- ~~`-OneBranchVariant`~~ — the script detects Buddy/Official from the YAML filenames

#### OneBranch-Specific Behavior

The push script auto-detects OneBranch pipelines by scanning for `OneBranch-Buddy-*.yml` and `OneBranch-Official-*.yml` in `.azure-pipelines/`. No framework parameter is needed.

- **Two pipeline files** are pushed: Buddy (`OneBranch-Buddy-{appName}.yml`) and Official (`OneBranch-Official-{appName}.yml`) in `.azure-pipelines/`.
- **Two pipeline definitions** are registered in ADO (PP-09 runs twice).
- **Trigger logic**: On non-`main` branches, the **Buddy** pipeline is triggered. On `main`, the **Official** pipeline is triggered. The script detects the current branch and triggers the appropriate variant.
- **SC authorization** (PP-09b) authorizes the service connection for **both** pipeline definitions.
- **Commit message** defaults to `VibeShield-Deploy: add OneBranch deployment pipelines for Azure`.

Optional switches: `-SkipPush` (validate only, don't push), `-SkipPipelineRegistration` (skip ADO pipeline creation).

### STRICT: Only These Parameters Exist

The script accepts **ONLY** the parameters listed in the table above plus `-SkipPush`, `-SkipPipelineRegistration`, `-WorkspacePath`, `-SarifPath`, `-UpdateState`, and `-StateJson`. **The following are NOT parameters and MUST NEVER be passed:**

- ~~`-ServiceConnectionName`~~ — The service connection is derived internally from the user's email (`sc-vibe-<name>-ARM`). There is no parameter for it.
- ~~`-AppName`~~ — Use `-PipelineName` to set the pipeline display name, or omit it (defaults to `VibeShield-Deploy-<RepoName>`).
- ~~`-SubscriptionId`~~ — Not a parameter. Detected internally by the script.
- ~~`-ResourceGroup`~~ — Not a parameter. This script does not interact with resource groups.

Passing any non-existent parameter will cause a PowerShell error: *"A parameter cannot be found that matches parameter name '...'"*.

## Procedure

### Step 0 — Clean Start

The script handles SARIF cleanup internally. Do NOT delete SARIF files yourself.

### Step 0a — Bicep Validity & Deployability Gate (Mandatory)

**Before invoking the push script**, the agent MUST delegate to the **vibeshield-bicep** agent to verify all Bicep files under `infra/` are **valid AND deployable**. This is a hard gate — if vibeshield-bicep reports the Bicep is invalid or not deployable, the push MUST NOT proceed.

1. **Delegate** to `vibeshield-bicep`: *"Validate all Bicep files under `infra/` for syntax correctness, semantic validity, and deployability. Verify the templates will successfully provision the intended Azure resources. Report any issues."*
2. **If vibeshield-bicep reports any issue** (syntax errors, missing parameters, invalid resource definitions, non-deployable templates, scope mismatches, missing dependencies) → **BLOCK the push**. Do NOT proceed to Step 0b or Step 1. The vibeshield-bicep agent is solely responsible for resolving Bicep issues — wait for it to fix them, then re-validate.
3. **If vibeshield-bicep confirms all Bicep is valid and deployable** → proceed to Step 0b.

> **Why deployability, not just syntax?** A Bicep template can pass `az bicep build` (syntax-valid) but still fail at deployment time due to invalid parameter combinations, missing resource dependencies, incorrect API versions, or scope mismatches. The vibeshield-bicep agent performs deeper semantic validation that catches these issues before the pipeline runs.

If no `infra/` directory or `.bicep` files exist, this gate is automatically skipped.

### Step 0b — Pipeline Runability Validation (Mandatory)

**Before invoking the push script**, the agent MUST validate that the pipeline YAML is structurally valid. Load the **`deploy-pipeline-validation`** skill and run the appropriate validation:

- **1ES framework**: Run `Invoke-PipelineAuthorValidation.ps1` against PA-01 through PA-33.
- **OneBranch framework**: Run `Invoke-OneBranchValidation.ps1` against OB-01 through OB-30, once for each variant (Buddy and Official).

**If any check FAILs** → **BLOCK the push**. Report failures and delegate to `vibeshield-deploy-pipeline-author` to fix.
**If all checks PASS** → proceed to Step 1.

### Step 1 — Invoke the Script

```powershell
./.github/skills/deploy-pipeline-push/scripts/Invoke-PipelinePush.ps1 `
    -Email <email> `
    -AdoOrgUrl <org-url> `
    -AdoProject <project> `
    -RepoName <repo-name>
```

The script exits with code **0** (all passed) or **1** (one or more failures).

### Step 2 — Interpret Results

The script runs 10 checks in order:

| Check | ID | What It Validates |
|-------|----|-------------------|
| Bicep Validity & Deployability | PP-00a | Bicep files are valid and deployable (vibeshield-bicep gate — agent-level, runs before script) |
| Pipeline Runability | PP-00b | Pipeline YAML passes all PA-01 through PA-33 checks (deploy-pipeline-validation — agent-level, runs before script) |
| Pipeline File | PP-01 | `azure-pipeline.yml` exists at the expected path |
| Required Files | PP-02 | App-type-specific files (e.g., `*.csproj`, `package.json`) are not git-ignored |
| App Name Consistency | PP-02b | Primary Deploy uses `$(appName)` variable; secondary Deploy stages derive app names from Provision outputs via `stageDependencies` — no hardcoded literals |
| Sensitive Files | PP-03 | No `.env`, `*.pfx`, `*.key`, secrets files will be committed |
| Gitignore | PP-04 | `.gitignore` excludes build outputs; creates one if missing |
| Large Binaries | PP-05 | No `node_modules/`, `bin/`, `obj/` in staging area |
| Dry-Run Staging | PP-06 | Counts files ready to stage; flags unexpected files |
| Git Commit | PP-07 | Stages and commits all files |
| Git Push | PP-08 | Pushes to origin; handles non-fast-forward (rebase + retry), protected branches (feature branch + PR), and auth errors. **Post-push verification**: fetches remote and confirms remote HEAD matches local HEAD — FAILs if the push was silently rejected or the remote has divergent history |
| Pipeline Registration | PP-09 | Creates pipeline in ADO or reuses existing one |
| SC Authorization | PP-09b | Authorizes the ARM service connection (`sc-vibe-<name>-ARM`) for the pipeline definition |
| EV2 SC Authorization | PP-09c | For EV2 pipelines: extracts the EV2 SC name (`cn-ev2deploy-{service}-{env}`) from the pipeline YAML and authorizes it. SKIP for non-EV2 pipelines |
| Pipeline Run Triggered | PP-10 | Verifies CI trigger from the pushed branch; validates `sourceVersion` matches the pushed commit SHA to reject stale runs from prior pushes. Falls back to manual trigger with `--branch <pushed-branch>` if no matching run appears |

### Step 3 — Handle Failures

If any check fails:

| Failure | Remediation |
|---------|-------------|
| PP-00a FAIL | Bicep is invalid or not deployable. **Do NOT proceed.** The vibeshield-bicep agent is responsible for fixing all Bicep issues. Wait for resolution, then re-validate. |
| PP-00b FAIL | Pipeline YAML has structural or semantic failures. **Do NOT proceed.** Return to vibeshield-deploy-pipeline-author to fix pipeline YAML issues; delegate Bicep-related PA failures to vibeshield-bicep. Re-run `deploy-pipeline-validation` to confirm fixes. |
| PP-01 FAIL | Run Pipeline Setup (vibeshield-deploy-pipeline-author) first |
| PP-02 FAIL | Remove offending patterns from `.gitignore` |
| PP-02b FAIL | Fix app name flow — primary Deploy must use `$(appName)`; secondary Deploy stages must use variable references backed by `stageDependencies.Provision.ProvisionJob.outputs` — no hardcoded app names |
| PP-03 FAIL | Add sensitive files to `.gitignore` |
| PP-05 FAIL | Add large directories to `.gitignore` |
| PP-06b FAIL | Delegate to **vibeshield-bicep** agent to fix or generate Bicep templates. Do NOT attempt to edit Bicep files directly. |
| PP-06c FAIL | Pipeline deploy tasks don't match AppType or Bicep resources. Re-run Pipeline Setup (vibeshield-deploy-pipeline-author) to regenerate, or delegate Bicep issues to **vibeshield-bicep**. |
| PP-08 FAIL (auth) | Bearer token injection runs automatically at startup using the active `az login` session. If push still fails with auth error: (1) verify `az account show` returns the correct account; (2) ask the user to run `az login` to refresh the session, then re-run the push stage |
| PP-08 FAIL (divergent) | Push was silently rejected — remote branch has divergent history. Re-run the push script — it will auto-increment to a new branch name (e.g., `deploy/add-pipeline-v2`). Investigate why the remote branch diverged. Never delete the remote branch (prohibited by workspace rules). |
| PP-08 FAIL (conflict) | Resolve merge conflicts, then re-run |
| PP-09 FAIL | Check Build Administrator role in ADO project |
| PP-09b FAIL | Verify service connection exists and user has Administrator role on it |
| PP-09b WARN | Authorize manually in ADO portal when prompted on first pipeline run |
| PP-09c WARN | EV2 SC not found or could not be extracted — authorize EV2 SC manually on first run |
| PP-10 FAIL | Check CI trigger config in `azure-pipeline.yml`; ensure the pushed branch matches a trigger pattern |
| PP-07 FAIL (hook) | A pre-commit or commit-msg hook blocked the commit. Review hook output. Options: fix issues and retry, bypass with `--no-verify` (only if user explicitly requests), or abort |
| PP-08 FAIL (hook) | A pre-push hook blocked the push. Review hook output. Options: fix issues and retry, bypass with `--no-verify` (only if user explicitly requests), or abort |

**Important**: The pipeline run MUST always be triggered from the branch where code was pushed. If CI trigger does not fire, the script falls back to `az pipelines run --branch <pushed-branch>`. The agent must never wait for code to be merged to `main` before running the pipeline.

### Step 4 — Report

After the script completes, present the user with:

1. A summary table showing each check's ✅/❌/⚠️/⏭️ status
2. The SARIF file path: `.vibeshield/results/pipeline-push-results.sarif`
3. The commit SHA, pipeline URL, run ID, and **branch name** (from SARIF properties)
4. **Automatic handoff**: Report the run ID, branch name, and pipeline URL back to the orchestrator. The orchestrator will immediately delegate to the monitor agent — do NOT poll pipeline status or suggest monitoring prompts.

## Git Hook Coexistence

The script detects and honors git hooks installed by other agents (e.g., `pre-commit`, `commit-msg`, `pre-push`). It NEVER installs, modifies, removes, or bypasses hooks.

**Before `git commit`**: The script checks for `pre-commit` and `commit-msg` hooks and reports them: *"Git hook(s) detected: pre-commit — waiting for hook(s) to complete..."*

**Before `git push`**: The script checks for `pre-push` hooks and reports them similarly.

**On hook failure**: If a hook blocks the operation, the SARIF result includes `HookFailure = $true` in the properties. The failure message contains the hook output. The agent should present the user with options (fix and retry, bypass, or abort) — never auto-bypass.

**Hook location**: Respects `core.hooksPath` git config for non-standard hook directories. Falls back to `<git-dir>/hooks/`.

## Dry-Run Mode

To validate everything without actually pushing:

```powershell
./.github/skills/deploy-pipeline-push/scripts/Invoke-PipelinePush.ps1 `
    -Email <email> `
    -SkipPush
```

This runs PP-01 through PP-06 only, skipping commit/push/registration.

## Branch Drift Detection & Reuse

The push script implements intelligent branch management to handle scenarios where the local branch has drifted from the remote branch between push attempts.

### How It Works

1. **State-based branch reuse**: On each successful push (PP-08 PASS), the branch name is recorded in `deploy-state.json`. On the next push, the script reads the state and checks for drift between local HEAD and the recorded remote branch.

2. **Drift detection**: Uses `git merge-base --is-ancestor` to determine if local and remote have diverged. A branch is considered "drifted" when:
   - The remote is ahead of local (local branch is behind)
   - Local and remote have diverged (neither is an ancestor of the other)

3. **No drift → reuse**: If the local branch is ahead of or equal to the remote (fast-forwardable push), the previously-recorded branch is reused.

4. **Drift detected → new informative branch**: When drift is detected, a new branch is created with a descriptive name:
   - Format: `deploy/<apptype>-<YYYYMMDD>-<change-slug>`
   - Example: `deploy/dotnet-20250115-pipeline-infra`
   - The change slug is derived from the categories of changed files (pipeline, infra, src, tests, config)

5. **First push (no state)**: When no state branch exists, falls back to the `BranchName` parameter (default: `deploy/add-pipeline`). If that remote branch has divergent history, creates an informative branch instead of the old generic `-v2`/`-v3` suffixes.

### Commit Message Summarization

When the commit message is the default placeholder (`chore: add 1ES deployment pipeline for Azure`), the script auto-generates a descriptive commit message summarizing the staged changes:
- Format: `chore(deploy): <N> file(s) changed: <categories>`
- Example: `chore(deploy): 12 file(s) changed: pipeline+infra+config`
- Custom commit messages passed via `-CommitMessage` are never overridden.

### State Persistence

The branch name is persisted in `deploy-state.json` at three checkpoints:
- After PP-08 (push): `SubStep = 'pushed'`, `BranchName = <actual branch used>`
- After PP-09 (registration): `SubStep = 'registered'`, includes `PipelineId`
- After PP-10 (trigger): `SubStep = 'triggered'`, includes `PipelineRunId`

This enables resume across context resets — the monitor agent knows exactly which branch and pipeline run to track.

## CGRP Reminder

Before pushing code or registering pipelines, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to pipeline push:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 1 | Ungrounded Assertion | Claiming the pipeline is registered or the push succeeded without script output |
| 5 | Re-derivation | Computing the branch name or remote URL via string logic instead of reading git/script output |
| 8 | Memory Conflict | Using a pipeline name or branch from a previous conversation that contradicts current `deploy-state.json` |

If any signal fires: **Stop → Verify → Pivot** before continuing.
