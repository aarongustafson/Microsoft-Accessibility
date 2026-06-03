---
name: deploy-deployment-diagnostics
description: 'Diagnose and remediate Azure DevOps pipeline failures and post-deployment issues. Use when: pipeline failed, deployment error, build error, authentication failure, 1ES compliance failure, health check failure, app not responding, retry logic, troubleshooting deployment.'
---

# Deployment Diagnostics

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Error classification** | Categorizes failures into auth, build, deploy, compliance, infra, and config buckets |
| **Root cause analysis** | Parses pipeline logs and error messages to identify the specific failure point |
| **Resolution lanes** | Routes failures to auto-fix, user-fix, Bicep-fix, or SPEAR-team handover |
| **Retry policy** | Applies per-category retry limits with backoff to prevent infinite loops |
| **Remediation guidance** | Provides specific, actionable fix steps for each classified error type |
| **Health check diagnostics** | Diagnoses post-deployment failures (HTTP errors, timeouts, cold-start issues) |
| **Escalation summaries** | Produces structured escalation reports when retries are exhausted |

## When to Use

- A pipeline run has failed (build, deploy, or compliance stage)
- A deployment succeeded but the app is not responding (health check failure)
- The deployed version does not match the expected commit
- Retry logic needs to be applied (up to 3 attempts max)

## Retry Policy

- Maximum **3 retry attempts** per **same failure category** — this aligns with and is enforced by `deploy-monitor`'s bounded retry limit. This skill MUST NOT recommend or perform retries beyond this cap.
- Track retry count **per failure category** using a `FailureHistory[]` array: `[{RetryNum, FailureCategory, Resolution}]`.
- **Distinct-failure awareness**: If each retry fails with a *different* root cause that is successfully fixed, the per-category counter does not increment toward escalation. Escalation triggers when: (a) the same `FailureCategory` appears 3 times, OR (b) total retries reach **2×MaxRetries (6)** (hard cap across all categories), whichever comes first.
- When a failure category has not been seen before, announce: *"New issue detected (attempt 1 for this category)."*
- When a previously-seen category recurs, announce: *"Retry attempt N of 3 for {FailureCategory}."*
- After the per-category or hard cap is reached, **stop retrying** and present an escalation summary.
- Each retry must include a diagnostic pass — never retry blindly.

## Diagnostic Workflow

```
Pipeline fails
  → Identify failed stage/job/task
  → Retrieve error logs
  → Classify failure type
  → Assign resolution lane
  → Execute resolution (auto-fix, user prompt, or handover)
  → Verify fix (if applicable)
  → Re-trigger pipeline (or escalate if non-retryable)
  → Monitor result
  → If still failing, increment retry counter
```

## Remediation Policy

Every diagnosed failure is assigned a **resolution lane** that determines who fixes it and how. This removes ambiguity about whether the agent acts, asks, or delegates.

### Resolution Lanes

| Lane | Label | Who Acts | Behavior |
|------|-------|----------|----------|
| 🤖 | `auto-fix` | This agent | Agent applies the fix silently (e.g., `az webapp start`, `az devops service-endpoint update`). No user prompt needed. Fix is verified before retry. |
| 🧑‍💻 | `user-fix` | User | Agent explains the problem in plain language, shows the exact change needed, and asks: *"Would you like me to apply this fix? (yes/no)"*. Waits for confirmation before editing any source file. |
| 🏗️ | `bicep-handover` | **vibeshield-bicep** agent | Agent does NOT touch Bicep files. Escalates to the orchestrator with the diagnostic detail, which re-delegates through **vibeshield-deploy-preflight** → **vibeshield-bicep**. Retry pauses until the Bicep agent reports completion. |
| 🔧 | `pipeline-handover` | **vibeshield-deploy-pipeline-author** agent | Agent does NOT modify pipeline YAML. Escalates to the orchestrator with the diagnostic detail, which delegates to **vibeshield-deploy-pipeline-author** to fix the pipeline definition. Retry pauses until the pipeline author reports completion. |
| 🔑 | `onboarding-handover` | **CELA SPEAR team** (external) | Service connection is entirely missing. The agent blocks deployment and directs the user to contact the SPEAR team to provision the SC. Retry pauses until the user confirms infrastructure is ready. |
| � | `ev2-handover` | **ev2-demo-agent** (external) | EV2 rollout failure, ServiceGroupRoot validation error, or EV2 artifact issue. Escalates to the orchestrator, which delegates to the ev2-demo-agent to regenerate or fix EV2 artifacts. Retry pauses until artifacts are verified. For EV2-Auth failures (missing Ev2Endpoint SC), routes to `onboarding-handover` instead. |
| �🔍 | `preflight-handover` | **vibeshield-deploy-preflight** agent | Failure reveals a configuration gap that preflight should have caught (wrong app type, missing config file, incorrect target service). Escalates to the orchestrator, which delegates to **vibeshield-deploy-preflight** for re-validation. Retry pauses until preflight completes. |
| ⏳ | `transient-retry` | None (retry only) | No fix is applied. The failure is transient (timing, throttling, temporary outage). Agent waits the recommended interval and retries the pipeline. |
| 🛑 | `non-retryable` | User (manual) | Agent cannot fix this. Presents the escalation summary immediately (Template 4) without consuming a retry attempt. Examples: quota exhaustion, banned dependency, policy violation. |

### Lane Assignment Rules

1. **`Get-FailureDiagnosis` returns `Transient = $true`** → lane is `transient-retry`.
2. **Error involves Bicep files, ARM templates, or Azure resource provisioning** (`ResourceNotFound`, `DeploymentFailed`, `InvalidTemplate`) → lane is `bicep-handover`.
3. **Error involves pipeline YAML structure, 1ES template, agent pool, or task configuration** (`TaskNotFound`, `InvalidYaml`, `PoolNotFound`, `TemplateError`) → lane is `pipeline-handover`.
4. **Error category is `EV2`** (EV2 rollout failure, ServiceGroupRoot validation, missing OneBranch release variables, EV2 timeout) → lane is `ev2-handover`. Delegate to ev2-demo-agent to regenerate or fix EV2 artifacts.
5. **Error category is `EV2-Auth`** (EV2 service connection missing OR subscription not registered with EV2) → lane is `onboarding-handover`. For subscription registration failures, the fix message includes the `ev2 subscription register --id <SubscriptionId>` command with the GUID from the handover data.
6. **Service connection, managed identity, FIC, or resource group is entirely missing** (`could not find service connection`, `ManagedIdentityNotFound`, `ResourceGroupNotFound`, `FederatedIdentityCredential not found`) → lane is `onboarding-handover`.
7. **Failure reveals a preflight gap** (wrong app type detected at deploy time, missing config file, incorrect target service, app settings mismatch) → lane is `preflight-handover`.
8. **Error requires source code changes** (compilation errors, test failures, missing dependencies, CredScan findings) → lane is `user-fix`.
9. **Error is fixable via CLI command without source changes** (service connection auth refresh, app restart, role assignment, pipeline authorization) → lane is `auto-fix`.
10. **Package feed authentication failure** (`NuGetAuthenticate`, `npmAuthenticate`, `PipAuthenticate`, `401 Unauthorized` on feed URL) → lane is `user-fix` with note: *"Package feed configuration is managed by VibeShield-CFS. Contact the CFS agent for feed setup."*
11. **Error cannot be resolved automatically** (quota, policy, banned component, subscription-level restriction) → lane is `non-retryable`.

When multiple rules match, use the **first matching rule** in the order above.

### Unattended Mode Behavior

In **unattended mode** (poc/dev), `auto-fix` and `transient-retry` lanes execute silently — announce the fix **after** applying it, not before. `user-fix` lanes are also auto-applied without confirmation in unattended mode (the agent announces the change and proceeds). Only `non-retryable` lanes pause for user attention. This eliminates unnecessary confirmation prompts during autonomous fix-deploy-monitor loops.

### Handover Protocol

When the resolution lane is `bicep-handover`, `pipeline-handover`, `onboarding-handover`, or `preflight-handover`:

1. **Pause the retry counter** — the handover does not consume a retry attempt.
2. **Prepare a handover payload** with these fields:

| Field | Description |
|-------|-------------|
| `source_agent` | `vibeshield-deploy-monitor` |
| `target_agent` | `vibeshield-bicep`, `vibeshield-deploy-pipeline-author`, or `vibeshield-deploy-preflight` |
| `failure_stage` | The pipeline stage that failed |
| `failure_task` | The specific task that failed |
| `error_message` | Key error line(s) from logs |
| `failure_category` | Classification from the tables below |
| `pipeline_run_url` | Link to the failed run |
| `files_involved` | List of files related to the failure (e.g., `infra/main.bicep`, `.azdo/pipelines/azure-pipeline.yml`) |
| `suggested_fix` | What the diagnostics skill believes needs to change (informational only — the target agent decides) |
| `handover_reason` | For `onboarding-handover`: which resource is missing. For `preflight-handover`: which config gap was detected. |

3. **Escalate to the orchestrator** — the monitor agent passes the handover payload to the orchestrator, which delegates to the appropriate agent.
4. **Wait for completion** — the monitor agent waits for the orchestrator to report that the target agent has finished its fix.
5. **Resume retry** — after the fix is reported complete, the monitor agent re-triggers the pipeline and resumes monitoring.

### User-Fix Confirmation Flow

When the resolution lane is `user-fix`:

1. Show Template 5 (Diagnostic Detail) with the full error context.
2. Present the proposed fix in a code block showing the exact change:
   ```
   📝 Proposed fix:
   
   File: {file_path}
   
   - {line_to_remove}
   + {line_to_add}
   ```
3. Use `vscode_askQuestions` to present the choice:
   ```
   header: "Apply fix"
   question: "Would you like me to apply this change?"
   options: [{label: "Yes, apply the fix", recommended: true}, {label: "No, I'll fix it myself"}]
   ```
4. **If "Yes, apply the fix"**: Apply the change, verify it locally (e.g., run `dotnet build`, `npm run build`), then re-trigger the pipeline.
5. **If "No, I'll fix it myself"**: Tell the user: *"I'll wait — say 'ready' or 'retry' when you're done."* Pause and wait for the user to signal completion.
6. **Local verification** (mandatory before retry): After any code change (auto or user-confirmed), run the appropriate local build command to verify the fix compiles. If local build fails, show the new error and repeat the fix cycle — do NOT re-trigger the pipeline with broken code.

### Auto-Fix Verification

When the resolution lane is `auto-fix`:

1. Run the CLI command.
2. Verify the command succeeded (exit code 0, expected output).
3. If the command fails, reclassify to `non-retryable` and escalate.
4. If succeeded, re-trigger the pipeline.

### No Local Deployment — Absolute Rule

**No resolution lane may deploy code directly from the local machine to Azure.** Never run `az webapp deploy`, `az webapp up`, `az functionapp deployment`, `az containerapp update`, `az containerapp up`, `func azure functionapp publish`, or any command that pushes artifacts or code directly to an Azure resource. All deployments MUST go through the Azure DevOps 1ES pipeline. If a deployment fails, diagnose and fix the root cause (pipeline YAML, Bicep, source code, or configuration), then re-trigger the pipeline. Local deployment bypasses security scanning, compliance checks, and audit trails that the pipeline provides.

## Failure Classification

> **Scripted implementation:** The failure classification tables below are implemented in the `Get-FailureDiagnosis` function in `.github/scripts/SharedHelpers.ps1`. It accepts error text and returns `@{ Category; RootCause; Fix; Transient }`. Agents SHOULD call this function first for automated classification, then fall back to the tables below for edge cases.

### Build Failures

| Symptom | Root Cause | Fix | Lane |
|---------|-----------|-----|------|
| `MSBUILD : error MSB...` | Missing NuGet packages or incompatible SDK | Run `dotnet restore`; verify SDK version matches `*.csproj` TargetFramework | 🧑‍💻 `user-fix` |
| `npm ERR! code ERESOLVE` | Dependency conflict in `package.json` | Run `npm install --legacy-peer-deps` or resolve version conflicts | 🧑‍💻 `user-fix` |
| `ModuleNotFoundError` | Missing Python package | Add missing package to `requirements.txt` and re-run `pip install` | 🧑‍💻 `user-fix` |
| `BUILD FAILURE` (Maven) | Compilation error or missing dependency | Check `pom.xml` for dependency versions; run `mvn dependency:resolve` | 🧑‍💻 `user-fix` |
| `error TS...` | TypeScript compilation error | Fix the reported type error in the source file | 🧑‍💻 `user-fix` |
| Test failures | Unit tests failing | Show failing test names and assertion errors; explain what the test expected | 🧑‍💻 `user-fix` |

**User explanation**: *"The build step found an error in your code or a missing library. Here's what went wrong and how to fix it."*

### Authentication Failures

| Symptom | Root Cause | Fix | Lane |
|---------|-----------|-----|------|
| `Error: Could not find service connection` | Service connection name mismatch | Verify `sc-vibe-<name>-ARM` exists; check spelling | 🤖 `auto-fix` |
| `AADSTS700016: Application not found` | Service principal deleted or misconfigured | Re-create the service connection in Azure DevOps | 🛑 `non-retryable` |
| `AuthorizationFailed` | Service principal lacks Owner role | Run `az role assignment create --assignee <sp-id> --role Owner --resource-group <rg>` | 🤖 `auto-fix` |
| `The pipeline is not authorized to use this service connection` | Pipeline not authorized | Run `az devops service-endpoint update --id <id> --enable-for-all true` | 🤖 `auto-fix` |

**User explanation**: *"The pipeline couldn't log in to your Azure account. This usually means the saved credential (service connection) is missing or doesn't have permission."*

### Deployment Failures

| Symptom | Root Cause | Fix | Lane |
|---------|-----------|-----|------|
| `ResourceNotFound` | Target Azure resource doesn't exist | Delegate to **vibeshield-bicep** agent to verify and fix the Bicep template, then re-run provisioning: `az deployment group create --resource-group <rg> --template-file infra/main.bicep --parameters infra/parameters.dev.bicepparam`. Do NOT edit Bicep files directly. | 🏗️ `bicep-handover` |
| `Conflict: Cannot modify resource while it is being created` | Previous deployment still in progress | **Transient/Timing failure** — no code fix needed. Wait 2 minutes, then retry the pipeline. Classify as transient (not a code or config error) so the retry counter still increments but no source changes are applied. | ⏳ `transient-retry` |
| `WebsiteError: The site is stopped` | App Service is in stopped state | Run `az webapp start --name <app> --resource-group <rg>` | 🤖 `auto-fix` |
| `ImagePullBackOff` (Container Apps) | Container image not found in registry | Verify image name/tag; check ACR login credentials | 🧑‍💻 `user-fix` |
| `Insufficient quota` | Not enough resources in the subscription | Check quota with `az vm list-usage --location <loc>`; request increase or change SKU | 🛑 `non-retryable` |
| `sqlAdminLogin` param empty / `SqlAdminLoginEmpty` | Bicep expects a SQL admin login but Entra-only auth was intended — the parameter is left blank, causing a validation error | Delegate to **vibeshield-bicep** to remove the `sqlAdminLogin` parameter from the Bicep template (or set a conditional default) when Entra-only authentication is configured. Do NOT hardcode a SQL password. | 🏗️ `bicep-handover` |
| `Conflict: resource name already exists` / `ResourceNameCollision` | `uniqueString()` in Bicep produced a name that collides with an existing resource (e.g., storage account, Key Vault) | Delegate to **vibeshield-bicep** to add a disambiguating suffix (e.g., environment name or short hash) to the `uniqueString()` seed inputs so the generated name is unique. | 🏗️ `bicep-handover` |

**User explanation**: *"The pipeline built your app successfully but couldn't deploy it to Azure. Here's what happened."*

### 1ES Compliance Failures

| Symptom | Root Cause | Fix | Lane |
|---------|-----------|-----|------|
| `CredScan found N matches` | Hardcoded secrets detected in source code | Remove the secret from code; use Key Vault or pipeline variables instead | 🧑‍💻 `user-fix` |
| `PoliCheck violation` | Non-inclusive or policy-violating terms found | Replace flagged terms with approved alternatives | 🧑‍💻 `user-fix` |
| `Component Governance alert` | Vulnerable or banned dependency detected | Update the dependency to a patched version | 🛑 `non-retryable` |

**User explanation**: *"A security scan found something that needs to be fixed before the deployment can continue. This is a safety check to protect your application."*

### Post-Deployment Health Check Failures

| Symptom | Root Cause | Fix | Lane |
|---------|-----------|-----|------|
| HTTP 502 Bad Gateway | App crashed on startup | Check logs: `az webapp log tail --name <app> --resource-group <rg>` | 🧑‍💻 `user-fix` |
| HTTP 503 Service Unavailable | App still starting or overloaded | Wait 30 seconds and retry; check if app plan has enough resources | ⏳ `transient-retry` |
| Connection refused | App not listening on the expected port | Verify `PORT` environment variable and app configuration | 🧑‍💻 `user-fix` |
| HTTP 500 Internal Server Error | Application runtime error | Check logs for stack trace; inspect app settings for missing environment variables | 🧑‍💻 `user-fix` |
| Timeout | App startup takes too long | Increase startup timeout; check for blocking operations in app initialization | 🧑‍💻 `user-fix` |

**User explanation**: *"Your app was deployed but isn't working correctly yet. Let me check the logs to find out why."*

## Log Retrieval

**Do NOT run any `az` commands locally to retrieve logs.** All log retrieval is done through the Azure Portal or Azure DevOps web UI:

### Pipeline Run Logs

Open the pipeline run URL in Azure DevOps (provided by the monitor agent). Navigate to the failed stage/job/task to view logs inline.

### Application Logs

Guide the user to check logs in the **Azure Portal**:
- **App Service**: App Service → Diagnose and solve problems → Application Logs
- **Container Apps**: Container Apps → Log stream, or Container Apps → Logs (Log Analytics)
- **Function App**: Function App → Monitor → Log stream

### Version Verification

Compare the `sourceVersion` shown on the pipeline run summary page in Azure DevOps with the local `git rev-parse HEAD`.

If versions don't match: *"The deployed version doesn't match your latest code. The pipeline may have run against an older commit. Try pushing again."*

## Escalation Summary Template

After 3 failed retries, the **monitor agent** presents the escalation using its **Template 4** (defined in `vibeshield-deploy-monitor.agent.md` → Standard Status Update Format). This skill MUST NOT define a competing escalation format.

When the monitor agent requests an escalation summary from this skill, return a structured object with these fields — the monitor agent will format it:

| Field | Description |
|-------|-------------|
| `persistent_error` | The exact error message that persisted across all retries |
| `failed_stage` | Build / Deploy / Compliance / etc. |
| `failure_category` | Classification from the tables above |
| `attempts` | Array of `{ attempt_number, fix_applied, result }` for each retry |
| `recommended_actions` | Ordered list of manual next steps |

## Diagnostic Output Format

When the monitor agent invokes this skill to diagnose a failure (before retry), return these fields for the monitor's **Template 5**:

| Field | Description |
|-------|-------------|
| `stage_name` | The pipeline stage that failed |
| `task_name` | The specific task within the stage |
| `failure_category` | From the classification tables above |
| `resolution_lane` | One of: `auto-fix`, `user-fix`, `bicep-handover`, `pipeline-handover`, `transient-retry`, `non-retryable` |
| `handover_target` | Agent name if lane is a handover (`vibeshield-bicep`, `vibeshield-deploy-pipeline-author`), otherwise `null` |
| `retryable` | `true` / `false` |
| `error_message` | Key error line(s) from task logs |
| `plain_language` | The "User explanation" from the matching classification table |
| `fix_applied` | What was done before retry, or "No fix needed — retrying to check if transient" |
| `proposed_fix` | For `user-fix`: the exact code change to propose. For handovers: the `suggested_fix` from the handover payload. For others: `null` |
| `files_involved` | List of files related to the failure (for handover payloads) |

The monitor agent owns all user-facing formatting. This skill provides structured diagnostic data only — never print escalation banners or status tables directly.

## Contingency Matrix

When the primary fix for a resolution lane doesn't work (same error recurs after fix), try the alternative strategy before escalating. This prevents wasting retries on the same ineffective fix.

### auto-fix Contingencies

| Primary Fix | If It Fails | Alternative Strategy |
|-------------|-------------|---------------------|
| `az webapp start` (stopped app) | App stops again immediately | Check app plan quota → `non-retryable` if quota exhausted |
| `az devops service-endpoint update --enable-for-all` (SC auth) | Authorization still fails | SC may be deleted → `onboarding-handover` |
| `az webapp restart` (503 transient) | Still 503 after restart | Check if app crashes on startup → `user-fix` (check logs for missing env var) |

### user-fix Contingencies

| Primary Fix | If It Fails | Alternative Strategy |
|-------------|-------------|---------------------|
| Add missing NuGet package | Build still fails | Check if SDK version mismatch → update `global.json` or pipeline SDK task |
| Fix TypeScript error | Different TS error appears | Check `tsconfig.json` for strict mode / missing `@types` |
| Add missing env var | App still crashes | Check if env var *name* is correct (case-sensitive on Linux) |
| Update `requirements.txt` | Import still fails | Check if package is in a private feed → `user-fix` with feed auth note |

### bicep-handover Contingencies

| Primary Fix | If It Fails | Alternative Strategy |
|-------------|-------------|---------------------|
| Bicep agent adds missing resource | Provision stage still fails | Check if Bicep uses wrong SKU/location → re-delegate with specific error |
| Bicep agent fixes template errors | ARM validation fails | Check if `main.bicep` references non-existent modules → re-delegate with ARM error |

### pipeline-handover Contingencies

| Primary Fix | If It Fails | Alternative Strategy |
|-------------|-------------|---------------------|
| Fix wrong task version | Task still not found | Check if task extension is installed in ADO org → `non-retryable` |
| Fix missing pipeline variable | Build fails with different error | Check if variable references a secret that doesn't exist in pipeline library |
| Pipeline registration name taken | `az pipelines create` fails | Try `az pipelines show --name <name>` first → update existing instead of create |

### transient-retry Contingencies

| After N Retries | Action |
|-----------------|--------|
| 1 retry | Wait 60s and retry (standard) |
| 2 retries (same error) | Reclassify: if error is identical, it may not be transient → re-diagnose with `Get-FailureDiagnosis` |
| 3 retries (same error) | Escalate — transient classification was wrong |

### General Rule

If the same error category recurs after 2 different fix attempts, **stop trying fixes from the same lane** and escalate. The `$script:RetryHistory` in `Invoke-DeployMonitor.ps1` already enforces same-error detection — the contingency matrix guides what to try *before* that detection triggers.

## CGRP Reminder

Before classifying a failure or suggesting a fix, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to diagnostics:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 3 | Blind Fix | Suggesting a fix without reading the full pipeline task log first |
| 4 | Hedging | Saying "this is probably a transient error" without checking `Transient` field |
| 8 | Memory Conflict | Using an AppType or service from a previous conversation turn that contradicts the current handoff data |

If any signal fires: **Stop → Verify → Pivot** before continuing.
