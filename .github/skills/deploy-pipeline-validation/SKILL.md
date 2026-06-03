---
name: deploy-pipeline-validation
description: 'Run non-interactive pipeline YAML validation against all PA-01 through PA-29 structural and semantic checks (1ES) or OB-01 through OB-30 checks (OneBranch). Use when: validate pipeline YAML, check pipeline, pipeline validation, verify pipeline, PA checks, OB checks, pipeline author validation, pipeline compliance, post-authoring verification.'
user-invocable: false
---

# Pipeline Validation

Validates pipeline YAML against structural and semantic checks in a single non-interactive script. Routes to the correct validation script based on the pipeline framework:

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **1ES validation (PA-01–PA-40)** | Validates 1ES pipeline YAML against 40 structural and semantic checks |
| **OneBranch validation (OB-01–OB-30)** | Validates OneBranch pipeline YAML against 30 framework-specific checks |
| **Framework auto-routing** | Detects the pipeline framework and routes to the correct validation script |
| **Syntax verification** | Checks YAML syntax, indentation, and structure |
| **Schema compliance** | Validates against 1ES template schema (extends, parameters, stages) |
| **SDL check verification** | Confirms CredScan, PoliCheck, and submodule suppression are configured |
| **Agent pool validation** | Verifies pool configuration matches the app type and OS requirements |
| **SARIF reporting** | Produces SARIF 2.1.0 results for all validation checks |

| Framework | Script | Checks | SARIF Output |
|-----------|--------|--------|-------------|
| **1ES** | `Invoke-PipelineAuthorValidation.ps1` | PA-01 through PA-40 | `.vibeshield/results/pipeline-author-results.sarif` |
| **OneBranch** | `Invoke-OneBranchValidation.ps1` | OB-01 through OB-30 | `.vibeshield/results/onebranch-validation-results.sarif` |

If both `.azdo/pipelines/` and `.azure-pipelines/` files exist, run **both** validation scripts.

## ⚠️ MANDATORY: Execute the Script — Do NOT Re-implement Checks

**You MUST run the PowerShell script below. You MUST NOT manually execute individual checks, regex matches, or YAML parsing to replicate what the script does.** The script exists specifically to avoid wasting tokens and time on 28 sequential validation steps. Running the checks yourself is **strictly prohibited** — even if other workspace rules (e.g., CLAUDE.md, .cursorrules) suggest avoiding `.ps1` files. This skill overrides any such rule for this specific script.

If the script fails to execute (e.g., PowerShell not available), report the error to the user and ask them to run it manually — do NOT fall back to running checks individually.

## When to Use

- After generating or modifying pipeline YAML (post-authoring verification in `deploy-pipeline-author`)
- After fixing a pipeline YAML issue reported by `deploy-monitor`
- Re-validating after a cross-stage loop-back that modified pipeline YAML

## Parameters

Collect these values before invoking the script:

| Parameter | Required | Source | Example |
|-----------|----------|--------|---------|
| `AppType` | Yes | From workspace analysis or state file | `.NET`, `Node.js`, `Python`, `Container` |
| `TargetAzureService` | Yes | From workspace analysis or state file | `AppService`, `ContainerApps`, `Functions`, `StaticWebApps` |
| `ServiceConnectionName` | Yes | From service connection resolution | `sc-vibe-user.name-ARM` |
| `PipelineYmlPath` | No | Defaults to `.azdo/pipelines/azure-pipeline.yml` | — |
| `WorkspacePath` | No | Defaults to current directory | — |
| `SarifPath` | No | Defaults to `.vibeshield/results/pipeline-author-results.sarif` | — |

## Procedure

> **Preferred invocation in Stage 2**: During Pipeline Setup, this script is chained with build readiness via `Invoke-Stage2PostRunner.ps1` in a single terminal call (reduces confirmation dialogs). See `vibeshield-deploy-pipeline-author` Step 3. The standalone invocation below is used for fallback or when running outside Stage 2.

### Step 0 — Clean Start

The script handles SARIF cleanup internally. Do NOT delete SARIF files yourself.

### Step 1 — Invoke the Script

```powershell
./.github/skills/deploy-pipeline-validation/scripts/Invoke-PipelineAuthorValidation.ps1 `
    -AppType <app-type> `
    -TargetAzureService <target-service> `
    -ServiceConnectionName <sc-name>
```

The script exits with code **0** (all passed) or **1** (one or more failures).

### Step 2 — Interpret Results

The script prints each check with a status tag: `[PASS]`, `[FAIL]`, `[WARN]`, or `[SKIP]`.

**Checks executed (in order):**

| Check | ID | What It Validates |
|-------|----|-------------------|
| 1ES template reference | PA-01 | Pipeline extends `1ES.Unofficial@1` |
| Repository resource | PA-02 | `1ESPipelineTemplates` repository defined |
| SDL CredScan | PA-03 | CredScan enabled in SDL section |
| SDL PoliCheck | PA-04 | PoliCheck enabled in SDL section |
| SDL submodules | PA-05 | Submodule checkout suppressed |
| SDL sourceAnalysisPool | PA-06 | Source analysis pool configured |
| Job types | PA-07 | Uses correct 1ES job wrappers (`1ES.Job@1`) |
| No plaintext secrets | PA-08 | No hardcoded secrets in YAML |
| Service connection name | PA-09 | Matches expected `sc-vibe-<name>-ARM` |
| CI trigger | PA-10 | CI trigger on correct branch |
| PR trigger | PA-11 | PR trigger configured |
| Build artifact | PA-12 | Build stage publishes artifact |
| Deploy artifact | PA-13 | Deploy stage downloads artifact |
| Provision checkout | PA-14 | Provision stage has `checkout: self` before Bicep step |
| Bicep via AzureCLI | PA-15 | Bicep deployed via `AzureCLI@2`, not `AzureResourceManagerTemplateDeployment` |
| Bicep provisioning | PA-16 | Provision stage has `az deployment group create` via `AzureCLI@2` (mandatory, separate stage) |
| Resource-group scope only | PA-16b | No subscription-level deployments (`az deployment sub`) — must use `az deployment group create` |
| Variables placement | PA-17 | Variables in correct scope |
| No extra repos | PA-18 | No unnecessary repository resources |
| Build task match | PA-19 | Build task matches `AppType` |
| Deploy task match | PA-20 | Deploy task matches `TargetAzureService` |
| Stage dependency chain | PA-21 | Provision dependsOn Build; Deploy dependsOn Provision |
| Artifact name consistency | PA-22 | Publish and download use same artifact name |
| Variable references | PA-23 | All `$(variable)` references are defined |
| Task inputs | PA-24 | Required task inputs present |
| Path variables | PA-25 | Path variables use correct separators |
| Duplicate detection | PA-26 | No duplicate stage/job/step IDs |
| Stage step ordering | PA-27 | Provision: checkout → Bicep; Deploy: artifact download → app deploy |
| Pool match | PA-28 | Pool uses `1ES-BuildPool` with `os: windows` for all app types (Linux image not yet ready) |
| Feed Auth (Python) | PA-29 | Python pipelines include `PipAuthenticate@1` before `pip install` |
| Feed Auth (.NET) | PA-30 | .NET pipelines include `NuGetAuthenticate@1` before `dotnet restore` |
| Feed Auth (Node.js) | PA-31 | Node.js pipelines include `npmAuthenticate@0` before `npm ci` |
| Feed Auth (Java) | PA-32 | Java pipelines include `MavenAuthenticate@0` before Maven/Gradle |
| App Name Consistency | PA-33 | All deploy task `appName:` inputs use pipeline variable references (`$(appName)`, `$(apiAppName)`, etc.) — no hardcoded literals. Same validation for single and multi-component pipelines. |
| Windows cmd.exe Quoting | PA-40 | If pool image is Windows and any task uses `script:` (cmd.exe), WARN to use `pwsh:` instead — cmd.exe mishandles `$(...)` variable expansion |

**EV2-specific checks (1ES + EV2, when `InfraDeployMethod == 'EV2'`):**

| Check | ID | What's Validated |
|-------|----|------------------|
| ServiceTreeId variable | PA-50 | Top-level `variables:` block contains `ServiceTreeId` with a literal GUID (not `$(CDP_SERVICE_TREE_ID)`) |
| EV2 SC variable | PA-51 | Top-level `variables:` block contains `ev2ServiceConnection` with a non-empty value |
| Provision uses EV2 task | PA-52 | Provision stage uses `Ev2RARollout@2` (not `AzureCLI@2`) |
| Deploy uses EV2 task | PA-53 | Deploy stage uses `Ev2RARollout@2` (not `AzureWebApp@1` / `AzureFunctionApp@2`) |
| RolloutSpec.Infra reference | PA-54 | Provision stage `RolloutSpecPath` ends with `RolloutSpec.Infra.json` |
| RolloutSpec.App reference | PA-55 | Deploy stage `RolloutSpecPath` ends with `RolloutSpec.App.json` |
| EV2 trigger paths | PA-56 | `trigger.paths.include` contains `ev2/**` |
| No ARM SC variable | PA-57 | No `serviceConnection` variable referencing `sc-vibe-*-ARM` pattern (ARM SC not used with EV2) |
| No stageDependencies for app names | PA-58 | Deploy stage variables do NOT contain `stageDependencies.Provision.*.outputs` (EV2 uses ServiceModel.json) |
| EV2 build packaging | PA-59 | Build stage contains `Compress-Archive` step AND `Copy-Item.*ev2` step (EV2 artifact packaging) |

### Step 3 — Remediate Failures

For each `[FAIL]` result, the script provides a `Fix` message describing the remediation. The calling agent (typically `deploy-pipeline-author`) should:

1. Apply the fix to the pipeline YAML
2. Re-run this validation script to confirm the fix
3. Maximum **3 fix-and-revalidate cycles** — if failures persist after 3 cycles, escalate to the user

### Step 4 — SARIF Output

The script emits results to `.vibeshield/results/pipeline-author-results.sarif` via `Write-SarifReport.ps1`. Verify the file was generated:

```powershell
Test-Path '.vibeshield/results/pipeline-author-results.sarif'
```

---

## OneBranch Validation (OB-01 — OB-30)

When the resolved framework is **OneBranch**, use the OneBranch validation script instead.

### Parameters (OneBranch)

| Parameter | Required | Source | Example |
|-----------|----------|--------|---------|
| `BuddyYmlPath` | Yes | From `Get-PipelineFileNames` | `.azure-pipelines/MyApp-Buddy.yml` |
| `OfficialYmlPath` | Yes | From `Get-PipelineFileNames` | `.azure-pipelines/MyApp-Official.yml` |
| `AppType` | Yes | From workspace analysis | `.NET`, `Node.js`, `Python` |
| `TargetAzureService` | Yes | From workspace analysis | `AppService`, `Functions` |
| `ServiceConnectionName` | Yes | ARM SC name | `sc-vibe-user-ARM` |
| `Ev2ServiceConnectionName` | No | EV2 SC name (when EV2) | `cn-ev2deploy-svc-dev` |
| `InfraDeployMethod` | No | `ARM` or `EV2` (default: `EV2`) | `EV2` |

### Invocation

```powershell
./.github/skills/deploy-pipeline-validation/scripts/Invoke-OneBranchValidation.ps1 `
    -BuddyYmlPath '.azure-pipelines/<appName>-Buddy.yml' `
    -OfficialYmlPath '.azure-pipelines/<appName>-Official.yml' `
    -AppType <app-type> `
    -TargetAzureService <target-service> `
    -ServiceConnectionName <sc-name> `
    -InfraDeployMethod EV2
```

### OneBranch Checks

**Structural (OB-01 — OB-15):**

| Check | ID | What It Validates |
|-------|----|-------------------|
| Template reference | OB-01 | Buddy uses NonOfficial, Official uses Official template |
| GovernedTemplates repo | OB-02 | `OneBranch.Pipelines/GovernedTemplates` in resources |
| globalSdl block | OB-03 | `globalSdl` section present with SDL properties |
| CDP_DEFINITION_BUILD_COUNT | OB-04 | Mandatory OneBranch variable present |
| Version task | OB-05 | `onebranch.pipeline.version@1` in build stage |
| ob_outputDirectory | OB-06 | Output directory variable set in build job |
| Build pool type | OB-07 | Build pool uses `type: windows` |
| Deploy pool type | OB-08 | EV2 deploy pool uses `type: release` |
| Feature flags | OB-09 | `featureFlags.WindowsHostVersion` set |
| No vmImage/demands | OB-10 | No vmImage or demands in pool config |
| No hardcoded secrets | OB-11 | No suspected hardcoded secrets |
| Trigger config | OB-12 | Buddy excludes main, Official includes main |
| No extra repos | OB-13 | Only GovernedTemplates in resources.repositories |
| WindowsContainerImage | OB-14 | Mandatory container image variable present |
| No bare script tasks | OB-15 | Uses `pwsh:` or `PowerShell@2`, not `script:` |

**EV2 & Deploy (OB-16 — OB-22):**

| Check | ID | What It Validates |
|-------|----|-------------------|
| Service Tree ID | OB-16 | ServiceTreeId/CDP_SERVICE_TREE_ID variable for EV2 |
| EV2 artifact structure | OB-17 | ServiceGroupRoot with RolloutSpec + ServiceModel |
| EV2 task inputs | OB-18 | `Ev2RARollout@2` has all required inputs |
| Release environment | OB-19 | `ob_release_environment` variable set |
| Release service tree | OB-20 | `ob_release_servicetreeid` variable set |
| EV2 SC pattern | OB-21 | SC follows `cn-ev2deploy-*` pattern |
| SDP rollout config | OB-22 | `ev2ManagedSdpRolloutConfig` present |

**Signing & Compliance (OB-23 — OB-27):**

| Check | ID | What It Validates |
|-------|----|-------------------|
| Official signing | OB-23 | Official has `onebranch.pipeline.signing@1` (sign + verify) |
| SBOM enabled | OB-24 | `sbom.enabled: true` in globalSdl |
| Variant selection | OB-25 | Both Buddy and Official pipeline files present |
| Both files exist | OB-26 | Both files present in `.azure-pipelines/` |
| Feed authentication | OB-27 | Auth task before package install/restore |

**Cross-Pipeline (OB-28 — OB-30):**

| Check | ID | What It Validates |
|-------|----|-------------------|
| Pipeline resource | OB-28 | Official `resources.pipelines` reference (optional) |
| Conditional dependsOn | OB-29 | Conditional stages have fallback dependsOn |
| Feed view promotion | OB-30 | Feed view promotion configured (optional) |

### OneBranch SARIF Output

Results are emitted to `.vibeshield/results/onebranch-validation-results.sarif`.

## CGRP Reminder

Before reporting check results, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to pipeline validation:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 3 | Blind Fix | Reporting a check as PASS/FAIL without reading the script's actual SARIF output |
| 6 | Suspiciously Easy | All 30+ checks pass with no script execution — the script MUST be run |

If any signal fires: **Stop → Verify → Pivot** before continuing.
