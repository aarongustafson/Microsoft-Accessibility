---
name: deploy-build-readiness
description: 'Verify every workspace module builds and tests locally, validate pipeline SDK alignment, confirm all modules are deployable, and coordinate multi-module Bicep coverage with vibeshield-bicep. Use when: local build verification, SDK matching, pipeline deployability check, multi-module readiness, pre-push build check, test verification, SDK alignment, pipeline-workspace consistency.'
---

# Build & Deploy Readiness

Verifies that every module discovered by `deploy-workspace-analysis` can be built and tested locally, that the pipeline YAML has matching SDKs and stages for each module, and that the infrastructure Bicep covers all modules. This is the final readiness gate before code push.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Per-module build verification (BR-01)** | Runs app-type-specific build commands for each module and reports pass/fail |
| **Per-module test verification (BR-02)** | Runs unit tests for each module with cascading gate (build must pass first) |
| **SDK alignment check (BR-03)** | Validates local SDK versions match pipeline task versions per module |
| **Pipeline stage completeness (BR-04)** | Confirms Build and Deploy stages exist in the pipeline for every module |
| **Composite deployability (BR-05)** | Computes per-module deployability from build + stages + required files |
| **Bicep coverage check (BR-06)** | Verifies Bicep infrastructure covers all confirmed modules |
| **Startup smoke test (BR-07)** | For Node.js modules: starts the server and probes the health endpoint |
| **Three-tier build probe (BR-00)** | Toolchain → SDK compat → restore cascade for early failure detection |
| **Structured JSON report** | Outputs `build-readiness-report.json` with checks, blockers, and deployability |
| **SARIF reporting** | Produces SARIF 2.1.0 results for all readiness checks |

## When to Use

- After `deploy-workspace-analysis` has produced a workspace manifest
- After `deploy-pipeline-author` has generated or validated the pipeline YAML
- Before `deploy-pipeline-push` to confirm the pipeline will succeed
- When the user says "verify my build", "can my pipeline deploy everything", or "check readiness"
- After fixing a build or SDK mismatch to re-verify

## Prerequisites

This skill requires the output of `deploy-workspace-analysis` (the workspace manifest). If the manifest is not available, run `deploy-workspace-analysis` first.

## Hard Constraints

- MUST NOT modify source code, project files, or test files. Build/test failures are **reported**, not fixed.
- MUST use the `deploy-app-type-select` skill's Build/Test Command Reference for the correct build and test commands per AppType. Do NOT invent build commands.
- MUST respect the Script Integrity Protection rule — if a VibeShield-Deploy script fails, report the defect; do not patch it.
- MUST verify **every module** in the manifest — do not skip modules or stop at the first failure.
- SDK version detection is best-effort — if the version cannot be determined from project files, note it as unverifiable and proceed.

---

## Readiness Checks

### Check BR-00: Build Probe (Buildability Gate)

BR-00 is the **sole authority** on module buildability. It runs a lightweight, three-tier probe on each module **before** the full build (BR-01). The `Test-ModuleBuildability` function executes three cascading tiers:

- **Tier 1 — Toolchain Presence**: Checks whether the required SDK/runtime is installed (e.g., `dotnet --version`, `node --version`). If the toolchain is missing, the module is marked `fail` and deeper tiers are skipped.
- **Tier 2 — SDK Version Compatibility**: Verifies the installed SDK version meets the project's requirements (via `global.json`, `.slnx`, `TargetFramework`, `engines.node`, etc.).
- **Tier 3 — Restore Probe**: Runs the lightest dependency-resolution command (e.g., `dotnet restore`, `npm install --package-lock-only`, `pip install --dry-run`) with a 60-second timeout.

**Switch**: Pass `-SkipBuildProbe` to skip BR-00 entirely (all modules default to `unknown`).

**Output**: Each module gains a `buildability` block in the manifest with `status` (`pass` / `fail` / `unknown`), `tier1_toolchain`, `tier2_sdkCompat`, `tier3_restore`, and `failReason`.

**Consumer rule**: `deploy-pipeline-author` includes only `pass` modules in the pipeline, excludes `fail` modules, and warns on `unknown` modules.

### Check BR-01: Per-Module Local Build

For each module in the workspace manifest, attempt a local build using the command from the `deploy-app-type-select` skill's Build/Test Command Reference:

| AppType | Build Command | Working Directory |
|---------|--------------|-------------------|
| `.NET` / `F#` / `VB.NET` | `dotnet build --configuration Release` | Module path |
| `Node.js backend` / `Static frontend` | `npm install && npm run build --if-present` | Module path |
| `Python` | `pip install -r requirements.txt` | Module path |
| `Java` (Maven) | `mvn package -DskipTests -q` | Module path |
| `Java` (Gradle) | `gradle build -x test` | Module path |
| `Container` | `docker build . --quiet` | Module path |
| `Go` | `go build ./...` | Module path |
| `Rust` | `cargo build --release` | Module path |
| `Functions` | Same as Functions runtime language | Module path |
| `Static website` | *(skip — no build step)* | — |

**Per module result**: `PASS` / `FAIL` / `SKIP`

On `FAIL`: Capture the build output and report:
> ❌ **Module `{path}` ({AppType}) — build failed**
> **Why:** [first error line from build output]
> **Fix:** [remediation based on error — e.g., "Install .NET SDK 8.0", "Run `npm install` first"]

### Check BR-02: Per-Module Local Tests

For each module that has tests (per the workspace manifest `tests` field), run the test command:

| AppType | Test Command |
|---------|-------------|
| `.NET` / `F#` / `VB.NET` | `dotnet test --configuration Release --no-build` |
| `Node.js backend` / `Static frontend` | `npm test --if-present` |
| `Python` | `pytest --tb=short` |
| `Java` (Maven) | `mvn test -q` |
| `Java` (Gradle) | `gradle test` |
| `Go` | `go test ./...` |
| `Rust` | `cargo test` |

**Per module result**: `PASS` / `FAIL` / `SKIP`

- `SKIP` — when no tests detected (module has `tests.unit = false`) OR when the module's BR-01 build failed (tests cannot run against a broken build)
- `FAIL` — tests executed and at least one test failed

On `FAIL`: Capture test output, report failing test count and first failure message.

**Impact of test failure**: Test failure does NOT block deployment. When tests fail, the module is still included in the pipeline but **test steps are omitted**. BR-05 reports `WARN` (not `FAIL`) for test-failed modules.

**Cascading gate**: If BR-01 (build) fails for a module, BR-02 MUST be skipped for that module — do not attempt to run tests against code that failed to build.

**Important**: Follow the Test Execution Policy from `deploy-shared-rules.prompt.md`. NEVER run Pester tests. For other test runners (`dotnet test`, `npm test`, `pytest`, etc.), execute normally.

#### Python Test Scaffolding (Copilot-Authored Apps)

When Copilot generates a Python project it frequently omits test infrastructure that pytest needs. **Before running BR-02 on a Copilot-authored Python app, verify and fix each item below:**

| Item | Check | Fix if missing |
|------|-------|---------------|
| `pytest` in deps | `requirements.txt` (or `pyproject.toml` `[project.optional-dependencies]`) lists `pytest` | Append `pytest` to `requirements.txt` and re-run `pip install -r requirements.txt` |
| Test files exist | At least one `test_*.py` or `*_test.py` file exists under the source or `tests/` directory | Create a minimal `tests/test_placeholder.py` with a single passing test, or mark the module as having no tests if it genuinely has none |
| `conftest.py` at project root | A `conftest.py` exists in the project root (even if empty) so pytest can anchor its collection | Create an empty `conftest.py` in the project root |
| Test file naming | All test files follow `test_*.py` or `*_test.py` convention | Rename any non-conforming files |

### Check BR-03: Pipeline SDK Alignment

For each module, verify the pipeline Build stage uses SDK versions compatible with the local project.

#### .NET SDK Detection Priority

The .NET SDK version (what *builds* the project) is often different from the `<TargetFramework>` (what the project *runs on*). For example, a project targeting `net8.0` may require SDK 10.x if it uses `.slnx` format or a `global.json` pin. Detect the required .NET SDK version using this priority order:

1. **`global.json`** → `sdk.version` field (most authoritative — this is the project's explicit SDK pin)
2. **`dotnet --version`** output from the local environment (actual installed SDK that successfully builds the project)
3. **`.slnx` file presence** → minimum SDK 9.0 (`.slnx` solution format requires SDK 9.0 or later)
4. **`<TargetFramework>` in `*.csproj`** → **fallback only** (this is the *runtime target*, NOT the SDK version; use only when sources 1-3 are unavailable, and emit a warning that the detected version may be inaccurate)

When the SDK version is determined from source 1 or 2, use the full `Major.Minor.Patch` from that source (e.g., `10.0.x` for SDK 10.0.202). When determined from source 3, use `9.0.x` minimum. When falling back to source 4, use `Major.0.x` from the TargetFramework (e.g., `8.0.x` for `net8.0`) and flag the result as approximate.

| AppType | Local SDK Detection | Pipeline SDK Task | Match Rule |
|---------|--------------------|--------------------|------------|
| `.NET` | `.NET SDK Detection Priority` (see above) | `UseDotNet@2` `version` input | Major.Minor must match the detected SDK version |
| `Node.js` | `engines.node` in `package.json` | `NodeTool@0` `versionSpec` input | Major must match (e.g., `20.x` for `">=20"`) |
| `Python` | `python_requires` in `pyproject.toml`, or `.python-version` file | `UsePythonVersion@0` `versionSpec` input | Major.Minor must match |
| `Java` | `<maven.compiler.source>` in `pom.xml`, or `sourceCompatibility` in `build.gradle` | `JavaToolInstaller@0` `versionSpec` input | Major must match |
| `Go` | `go` directive in `go.mod` | `GoTool@0` `version` input | Major.Minor must match |
| `Rust` | `rust-version` in `Cargo.toml` (or `rustup show`) | Pipeline `rustup` step | Major.Minor must match |

**Per module result**: `PASS` / `WARN` / `SKIP`

- `PASS` — SDK versions match
- `WARN` — SDK version mismatch detected; report the local version vs pipeline version, and recommend updating the pipeline task
- `SKIP` — SDK version could not be determined from project files

#### .NET SDK vs TargetFramework Runtime Mismatch

After checking SDK alignment, for .NET modules also compare the detected **build SDK** major version against the `<TargetFramework>` major version from the project file (`.csproj` / `.fsproj` / `.vbproj`). When they differ (e.g., SDK 10.x but TargetFramework `net8.0`), the pipeline must install the TargetFramework runtime separately — `dotnet test` executes tests against the TargetFramework runtime, not the SDK runtime.

**Detection**: Extract the `<TargetFramework>` value from the project file (e.g., `net8.0` → major `8`). Compare against the build SDK major version (e.g., `10`). If they differ:

- `WARN` — "SDK major version N differs from TargetFramework major version M — pipeline needs a `UseDotNet@2` with `packageType: 'sdk'` and `version: 'M.0.x'` before the build SDK to run tests (do NOT use 'runtime' — it misses Microsoft.AspNetCore.App)"
- Verify the pipeline YAML includes a `UseDotNet@2` step with `packageType: 'sdk'` installing the TargetFramework version before the build SDK. If present → `PASS`. If missing → `WARN` with fix recommendation.

If SDK and TargetFramework majors are the **same**, this sub-check is `PASS` (no extra runtime needed).

### Check BR-04: Pipeline Stage Completeness

Using the workspace manifest's per-module `pipelineStages` data, verify:

1. Every module has a **Build stage** in the pipeline
2. Every module has a **Deploy stage** in the pipeline
3. Each Build stage uses the correct build tasks for the module's AppType
4. Each Deploy stage uses the correct deploy task for the module's TargetAzureService
5. Each secondary module's Build stage sets `workingDirectory` to the module's path
6. Artifact names are unique across all Build stages
7. The Provision stage `dependsOn` includes ALL Build stages
8. Every Deploy stage `dependsOn` Provision

This check cross-references the `deploy-1es-pipeline-authoring` skill's Multi-Component Pipelines rules and the validation checks PA-34 through PA-39.

**Per-module result**: `PASS` / `FAIL`

On `FAIL`: List which stages are missing or misconfigured, and provide the expected stage structure.

### Check BR-05: Module Deployability

For each module, verify end-to-end deployability. The **minimum guarantee** for a module to be added to the pipeline is that it builds successfully.

1. **Build succeeds** — BR-01 passed (module builds locally)
2. **Pipeline has matching stages** — BR-04 passed (Build + Deploy stages exist)
3. **Required files are present and tracked** — Check that files from the `deploy-app-type-select` "Required Files for Push" table are present and not git-ignored
4. **Deploy target is defined** — The module's `TargetAzureService` has a corresponding deploy task in the pipeline's Deploy stage

**Test failure is advisory, not blocking**:
- Build success + tests pass → `PASS` — module deployed with test steps
- Build success + tests fail → `WARN` — module deployed **without test steps** (tests omitted from pipeline)
- Build success + no tests exist → `PASS` — module deployed without test steps
- Build failure → `FAIL` — module NOT deployable (tests skipped, push blocked)

**Per-module result**: `PASS` / `WARN` / `FAIL`

A module is deployable if build, stages, and files conditions are met. Test failure downgrades the result to `WARN` and causes test steps to be omitted from the pipeline.

**Auto-fix missing required files**: When a module is missing a required file (e.g., `host.json` for Functions, `package.json` for Node.js), the agent MUST create the file automatically with sensible defaults — do NOT ask the user for options or present "Option A / Option B" choices. Announce the fix (*"Missing `host.json` in `{path}` — creating with default configuration."*) and re-check deployability. Standard defaults:
- `host.json` (Functions): `{"version": "2.0"}`
- `package.json` (Node.js): `{"name": "<module-name>", "version": "1.0.0", "private": true}`
- Other required files: use the minimal valid template for that file type.

### Check BR-06: Multi-Module Bicep Coverage

BR-06 applies to **all InfraDeployMethods** (ARM and EV2).

**EV2 legacy path**: When `InfraDeployMethod == 'EV2'`, check `ev2/ServiceGroupRoot/Templates/` first. If ARM template JSON files exist there, the project uses pre-authored ARM templates and BR-06 passes without requiring Bicep. If the Templates directory is empty or absent, fall through to the Bicep check below — the project needs Bicep as the source of truth for ARM generation.

**For all other cases (ARM, or EV2 without legacy ARM templates):**

Using the workspace manifest's `bicep` data, verify infrastructure coverage:

**If Bicep exists (`bicep.exists` is true):**

1. Check `bicep.coversAllModules` — does the existing Bicep define resources for every module?
2. If gaps exist (`bicep.gaps` is non-empty):
   - Report which modules lack infrastructure definitions
   - **Delegate to `vibeshield-bicep`**: Request it to review the existing Bicep at `bicep.path` and add the missing resources for the uncovered modules. Provide the full module list with `AppType` and `TargetAzureService` for each.
   - Message to `vibeshield-bicep`:
     > "Existing Bicep at `{path}` covers {N} of {total} modules. The following modules need infrastructure added: {list with AppType and TargetAzureService}. Please review and extend the existing Bicep — do NOT regenerate from scratch."

**If Bicep does not exist (`bicep.exists` is false):**

1. **Delegate to `vibeshield-bicep`**: Request it to generate new Bicep for all modules. Provide the complete module list.
   - Message to `vibeshield-bicep`:
     > "No existing Bicep found. Generate `infra/main.bicep` covering all {N} modules: {list with AppType, TargetAzureService, and path}."

**Result**: `PASS` (Bicep covers all selected installable modules) / `FAIL` (Bicep has gaps or is missing — delegation to vibeshield-bicep is mandatory before proceeding) / `SKIP` (EV2 deployment)

**Enforcement**: BR-06 is a **blocking check**. If any user-selected installable module lacks infrastructure definitions in Bicep, the deployment MUST NOT proceed. The pipeline-author agent auto-delegates to vibeshield-bicep to fix gaps. After vibeshield-bicep completes, BR-06 is re-run to verify coverage. If gaps persist after 3 delegation attempts, escalate to the user.

### Check BR-07: Startup Smoke Test (Node.js only)

For Node.js backend modules (`appType == 'Node.js backend'`), run a local startup smoke test before the first pipeline run. This catches missing env vars, eager SDK crashes, and module resolution failures that would waste a 25-minute pipeline cycle.

**Steps:**
1. Determine the entry point from `package.json` (`main` or `scripts.start`).
2. Start the server process on a random high port (`PORT=19876+random`).
3. Wait up to 8 seconds for the process to respond to an HTTP probe.
4. Kill the process after the probe.

**Results:**
- `PASS` — server started and responded on the probe port.
- `FAIL` — server crashed on startup (exit code ≠ 0). Report the error output. This is a **blocking failure** — the app is guaranteed to crash in production. Fix the startup error before deploying.
- `WARN` — server started but did not respond within 8 seconds. May indicate the server doesn't listen on `PORT` or has no health endpoint.
- `SKIP` — skipped when `--SkipBuild` is set, or no Node.js backend modules exist.

**Not applicable to:** Static frontends (React, Vue, etc.) — they don't have a `node` server to start.

---

## Output: Readiness Report

Present results in this format:

### Summary Table

> **Build & Deploy Readiness**
>
> | Check | Status | Details |
> |-------|--------|---------|
> | BR-01: Local Build | ✅ 2/2 modules pass | `.` (.NET), `src/MyFunctions` (Functions) |
> | BR-02: Local Tests | ⚠️ 1/2 modules pass | `src/MyFunctions` — no tests found |
> | BR-03: SDK Alignment | ✅ 2/2 aligned | .NET 8.0, Node.js 20.x |
> | BR-04: Pipeline Stages | ❌ 1 gap | `src/MyFunctions` missing Build_Functions stage |
> | BR-05: Deployability | ❌ 1 not deployable | `src/MyFunctions` — missing pipeline stage |
> | BR-06: Bicep Coverage | ❌ 1 gap | Delegating to vibeshield-bicep to add Functions resources |

### Per-Module Detail

For each module, show:

> **Module: `src/MyFunctions`** (Functions → Azure Functions)
> - Build: ✅ `dotnet build` succeeded
> - Tests: ⏭️ No tests found
> - SDK: ✅ .NET 8.0 matches pipeline `UseDotNet@2` 8.0.x
> - Pipeline: ❌ Missing Build_Functions and Deploy_Functions stages
> - Deployable: ❌ Blocked by missing pipeline stages

### Structured Output

```json
{
  "checks": {
    "BR-01": { "status": "PASS", "moduleResults": { ".": "PASS", "src/MyFunctions": "PASS" } },
    "BR-02": { "status": "WARN", "moduleResults": { ".": "PASS", "src/MyFunctions": "SKIP" } },
    "BR-03": { "status": "PASS", "moduleResults": { ".": "PASS", "src/MyFunctions": "PASS" } },
    "BR-04": { "status": "FAIL", "moduleResults": { ".": "PASS", "src/MyFunctions": "FAIL" } },
    "BR-05": { "status": "FAIL", "moduleResults": { ".": "PASS", "src/MyFunctions": "FAIL" } },
    "BR-06": { "status": "FAIL", "delegateToVibeshieldBicep": true, "gaps": ["src/MyFunctions"] }
  },
  "allModulesDeployable": false,
  "blockers": [
    { "module": "src/MyFunctions", "reason": "Missing Build_Functions and Deploy_Functions pipeline stages" }
  ]
}
```

---

## Automation Script

This skill includes a deterministic PowerShell script that performs BR-01 through BR-06 non-interactively.

> **Preferred invocation in Stage 2**: During Pipeline Setup, this script is chained with pipeline validation via `Invoke-Stage2PostRunner.ps1` in a single terminal call (reduces confirmation dialogs). See `vibeshield-deploy-pipeline-author` Step 3. The standalone invocation below is used for fallback or when running outside Stage 2.

### Invocation

```powershell
# Run from workspace root (defaults — reads manifest from .vibeshield/results/workspace-manifest.json)
./.github/skills/deploy-build-readiness/scripts/Invoke-BuildReadiness.ps1

# Explicit parameters
./.github/skills/deploy-build-readiness/scripts/Invoke-BuildReadiness.ps1 `
    -ManifestPath ".vibeshield/results/workspace-manifest.json" `
    -WorkspacePath "./my-app" `
    -PipelineYmlPath ".azdo/pipelines/azure-pipeline.yml" `
    -SarifPath ".vibeshield/results/build-readiness-results.sarif"

# Skip build and tests (validation-only mode)
./.github/skills/deploy-build-readiness/scripts/Invoke-BuildReadiness.ps1 -SkipBuild -SkipTests
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ManifestPath` | No | `.vibeshield/results/workspace-manifest.json` | Path to workspace manifest from `Invoke-WorkspaceAnalysis.ps1` |
| `WorkspacePath` | No | `$PWD` | Root directory of the application workspace |
| `PipelineYmlPath` | No | `.azdo/pipelines/azure-pipeline.yml` in workspace | Path to the pipeline YAML |
| `SkipBuild` | No | `$false` | Skip BR-01 local build checks |
| `SkipTests` | No | `$false` | Skip BR-02 local test checks |
| `SarifPath` | No | `.vibeshield/results/build-readiness-results.sarif` | Path to write the SARIF results |

### Output

- **Console**: Per-module check results with ✅/❌/⚠️/⏭️ status icons
- **SARIF**: Written to `SarifPath` with all BR check results
- **Readiness report**: Written to `.vibeshield/results/build-readiness-report.json` with structured check summary, `allModulesDeployable`, and `blockers[]`
- **Exit code**: `0` = all checks passed, `1` = one or more failures

### Tests

```powershell
Invoke-Pester -Path ./.github/skills/deploy-build-readiness/scripts/Invoke-BuildReadiness.Tests.ps1 -Output Detailed
```

---

## Remediation Routing

| Check | On FAIL | Who Fixes |
|-------|---------|-----------|
| BR-01 | Build errors in source code | **User** — show the build error and suggest the fix |
| BR-02 | Failing tests | **User** — show test failures, do not auto-fix test code |
| BR-03 | SDK mismatch | **deploy-pipeline-author** — update the SDK task version in pipeline YAML |
| BR-04 | Missing pipeline stages | **deploy-pipeline-author** — generate the missing Build/Deploy stages using the `deploy-1es-pipeline-authoring` skill |
| BR-05 | Not deployable | Resolve the underlying BR-01/BR-04 blockers first; if the blocker is a missing required file, **auto-create it** (see BR-05 auto-fix rule) |
| BR-06 | Bicep gaps | **vibeshield-bicep** — extend or generate Bicep (delegated automatically) |

After remediation, re-run the affected checks to confirm they now pass. Do NOT proceed to `deploy-pipeline-push` until all modules are deployable (`allModulesDeployable: true`) or the user explicitly acknowledges and accepts the gaps.

## CGRP Reminder

Before reporting build/test results or SDK compatibility, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to build readiness:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 2 | Unknown Command | Using a build command not listed in the appType's `buildCmd`/`testCmd` |
| 4 | Hedging | Saying "the build should pass" without running it or reading the build output |

If any signal fires: **Stop → Verify → Pivot** before continuing.
