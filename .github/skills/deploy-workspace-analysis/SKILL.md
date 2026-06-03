---
name: deploy-workspace-analysis
description: 'Deep analysis of workspace source code structure, multi-module detection, per-module app type classification, test inventory, and existing Bicep discovery. Use when: analyze workspace, detect modules, source code analysis, find components, multi-module detection, test discovery, Bicep discovery, workspace scan, project structure analysis, pre-pipeline workspace assessment.'
---

# Workspace Source Analysis

Deep-analyzes the target workspace to discover all deployable modules, classify each one by app type, inventory test suites, and detect existing infrastructure-as-code — producing a comprehensive workspace manifest that drives pipeline generation and Bicep coordination.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Multi-module detection** | Recursively scans the workspace to find all deployable modules (apps, libraries, functions) |
| **App type classification** | Classifies each module by framework (.NET, Node.js, Python, Java, Go, etc.) using marker files |
| **Test inventory** | Discovers unit, integration, and e2e test suites and their frameworks per module |
| **Bicep discovery** | Detects existing `infra/main.bicep`, catalogs declared resources, and flags coverage gaps |
| **Pipeline stage mapping** | Identifies which pipeline stages (Build, Deploy) each module requires |
| **Workspace manifest output** | Produces `workspace-manifest.json` consumed by pipeline authoring and build readiness |
| **Component extraction** | Extracts deployable components with Azure service targets for EV2 handover |

## When to Use

- Before generating pipeline YAML, to understand what the pipeline must build and deploy
- When the orchestrator or preflight did not pass a `Components` array
- When the user says "analyze my workspace", "what's in my project", or "detect my modules"
- Before delegating to `vibeshield-bicep` to provide a complete picture of deployable modules
- When the pipeline author needs to determine how many Build/Deploy stages to generate

## Hard Constraints

- MUST use the `deploy-app-type-select` skill's Detection Table and canonical AppType values for every module classification. Do NOT invent app type detection logic.
- MUST NOT modify any source file, project file, or Bicep file during analysis. This skill is **read-only**.
- MUST scan the entire workspace tree — not just the root directory. Modules can live at any depth.
- **EXCEPTION**: When `-SourcePath` is provided, scan ONLY that subdirectory (and its children). Ignore the rest of the workspace. The scoped subdirectory becomes the primary module.
- MUST report the analysis results to the user before acting on them. The user can correct misdetections.
- MUST respect the `deploy-app-type-select` precedence rules (e.g., `host.json` wins over language markers for Functions detection).
- If the user specifies a source path (e.g., *"my code is in src/MyApp"*), the orchestrator passes it as `-SourcePath`. The script scopes discovery to that directory only.

---

## Script Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-WorkspacePath` | No (default: `$PWD`) | Workspace root |
| `-SourcePath` | No | Relative subdirectory to scope analysis to. When set, only this directory is scanned. |
| `-PipelineYmlPath` | No | Pipeline YAML relative path |
| `-OutputPath` | No | Where to write workspace-manifest.json |

---

## Analysis Procedure

### Phase 1: Source Code Discovery

Scan the workspace to identify all directories containing deployable source code.

**Step 1.1 — Root-level scan**

Check the workspace root for marker files from the `deploy-app-type-select` Detection Table:
- `host.json`, `Dockerfile`, `*.csproj`, `*.fsproj`, `*.vbproj`, `package.json`, `pom.xml`, `build.gradle`, `requirements.txt`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `index.html`

Record any matches as the **primary module** at path `.` (workspace root).

**Step 1.2 — Recursive subdirectory scan**

Search all subdirectories (excluding `node_modules`, `bin`, `obj`, `.git`, `.github`, `.azdo`, `.vibeshield`, `infra`, `dist`, `build`, `out`, `target`, `__pycache__`, `.venv`, `venv`, and backup/recovery directories like `_recovered`, `_backup`, `_bak`, `_old`, `_archive`, `_deprecated`) for the same marker files.

For each directory containing one or more marker files, record it as a **candidate module** with:
- `Path` — relative path from workspace root (e.g., `src/MyApi`, `functions/OrderProcessor`)
- `MarkerFiles` — list of detected marker files

**Step 1.3 — Deduplication**

Remove candidate modules that are subdirectories of another candidate when they share the same project context:
- A `node_modules` subfolder inside a `package.json` module is not a separate module
- A `*.csproj` inside a `bin/` or `obj/` folder is a build artifact, not a module
- Test projects (directories named `*.Tests`, `*.Test`, `tests`, `test`, `__tests__`) are recorded separately (see Phase 3) but NOT counted as deployable modules

### Phase 2: Per-Module App Type Classification

For each discovered module, apply the `deploy-app-type-select` skill's Detection Algorithm:

1. **Load the skill**: Read `.github/skills/deploy-app-type-select/SKILL.md` for the Detection Table and precedence rules.
2. **Classify each module independently** using the marker files found in Step 1.
3. **Record per module**:
   - `ModulePath` — relative path
   - `AppType` — canonical value from the Detection Table
   - `TargetAzureService` — routed via the Target Azure Service Routing rules
   - `MarkerFiles` — the files that led to the classification

4. **Resolve ambiguity within a module** using Step 2 of the Detection Algorithm (e.g., `package.json` with both frontend and backend deps → ask the user).

### Phase 2b: Discovery Filter

After classification, **automatically exclude non-deployable candidates** — do NOT present them to the user for confirmation:

- **Unknown app type** — modules where no recognized project structure was detected. These have marker files but no known project type.
- **Underscore-prefixed paths** — directories like `_recovered/`, `_backup/`, `_old/` are backup/recovery artifacts, not deployable code.
- **Utility/tool projects** — small console apps, code generators, or debug utilities that are not intended for deployment. These are identified by having no web/API/function entry point and being nested under tool-like directory names.

The script logs each exclusion with a reason. Only recognized module types proceed to Phase 3+.

### Phase 3: Test Suite Inventory

For each deployable module, scan for test projects and test files:

| Test Type | Detection Pattern |
|-----------|-------------------|
| Unit tests (.NET) | `*.Tests.csproj`, `*.Test.csproj` in sibling or child directories; references to `xunit`, `nunit`, `mstest` in `.csproj` |
| Unit tests (Node.js) | `test/`, `__tests__/`, `*.test.js`, `*.spec.js`, `*.test.ts`, `*.spec.ts`; `jest`, `mocha`, `vitest` in `package.json` devDependencies |
| Unit tests (Python) | `tests/`, `test/`, `test_*.py`, `*_test.py`; `pytest`, `unittest` imports; `pytest` in `requirements-dev.txt` or `pyproject.toml` |
| Unit tests (Java) | `src/test/java/`, `*Test.java`, `*Tests.java`; `junit`, `testng` in `pom.xml`/`build.gradle` |
| Unit tests (Go) | `*_test.go` files |
| Unit tests (Rust) | `#[test]` annotations in `*.rs`, `tests/` directory |
| Integration tests | `*.integration.test.*`, `integration-tests/`, `tests/integration/` |
| E2E tests | `e2e/`, `cypress/`, `playwright/`, `*.e2e.*` |

Record per module:
- `HasUnitTests` — boolean
- `HasIntegrationTests` — boolean
- `HasE2ETests` — boolean
- `TestFramework` — detected framework name (e.g., `xunit`, `jest`, `pytest`, `junit`)
- `TestPaths` — relative paths to test directories/files

### Phase 4: Existing Bicep Discovery

Scan for existing infrastructure-as-code:

**Step 4.1 — Standard locations**

Check these paths (relative to workspace root):
- `infra/main.bicep` (VibeShield-Deploy standard location)
- `infra/*.bicep` (any Bicep files in `infra/`)
- `infra/*.bicepparam` (parameter files)
- `*.bicep` at workspace root
- `deploy/*.bicep`, `infrastructure/*.bicep`, `azure/*.bicep` (common alternatives)

**Step 4.2 — Bicep content analysis** (read-only)

For each discovered `.bicep` file, read it to determine:
- What Azure resources it provisions (e.g., `Microsoft.Web/sites`, `Microsoft.Web/serverfarms`, `Microsoft.App/containerApps`, `Microsoft.Storage/storageAccounts`)
- Whether it appears to cover all detected modules (e.g., if 2 modules need App Service and Functions, does the Bicep define both?)
- Whether a `parameters.dev.bicepparam` file exists alongside `main.bicep`

**Step 4.3 — Bicep gap analysis**

Compare the Azure resources defined in existing Bicep against the `TargetAzureService` for each module:

| Module TargetAzureService | Required Bicep Resource |
|--------------------------|------------------------|
| Azure App Service | `Microsoft.Web/sites` + `Microsoft.Web/serverfarms` |
| Azure Functions | `Microsoft.Web/sites` (kind: functionapp) + `Microsoft.Web/serverfarms` |
| Azure Container Apps | `Microsoft.App/containerApps` + `Microsoft.App/managedEnvironments` |
| Azure Static Web Apps | `Microsoft.Web/staticSites` |

Record:
- `BicepExists` — boolean
- `BicepPath` — path to main Bicep file
- `BicepCoversAllModules` — boolean
- `BicepGaps` — list of modules whose target service is not defined in the Bicep

### Phase 5: Pipeline Stage Coverage Check

For each detected module, verify that if a pipeline already exists at `/.azdo/pipelines/azure-pipeline.yml`, it contains:
- A **Build stage** for the module (matched by `workingDirectory` or stage name convention)
- A **Deploy stage** for the module (matched by deploy task and target app name)

Record:
- `HasBuildStage` — boolean per module
- `HasDeployStage` — boolean per module
- `MissingStages` — list of modules with no corresponding pipeline stages

---

## Output: Workspace Manifest

Present the analysis results in this format:

### Summary Table

> **Workspace Analysis Results**
>
> | # | Module | Path | AppType | Azure Service | Tests | Build Stage | Deploy Stage |
> |---|--------|------|---------|---------------|-------|-------------|--------------|
> | 1 | Primary | `.` | .NET | App Service | Unit ✅ Integration ❌ E2E ❌ | ✅ | ✅ |
> | 2 | Functions | `src/MyFunctions` | Functions | Azure Functions | Unit ✅ Integration ❌ E2E ❌ | ❌ | ❌ |
>
> **Infrastructure**: Bicep found at `infra/main.bicep` — covers App Service ✅, Functions ❌

### Structured Output

Emit a JSON block for consumption by downstream agents:

```json
{
  "modules": [
    {
      "path": ".",
      "appType": ".NET",
      "targetAzureService": "App Service",
      "markerFiles": ["MyApp.csproj"],
      "tests": { "unit": true, "integration": false, "e2e": false, "framework": "xunit", "paths": ["tests/MyApp.Tests"] },
      "pipelineStages": { "build": true, "deploy": true }
    },
    {
      "path": "src/MyFunctions",
      "appType": "Functions",
      "targetAzureService": "Azure Functions",
      "markerFiles": ["host.json", "MyFunctions.csproj"],
      "tests": { "unit": true, "integration": false, "e2e": false, "framework": "xunit", "paths": ["src/MyFunctions.Tests"] },
      "pipelineStages": { "build": false, "deploy": false }
    }
  ],
  "bicep": {
    "exists": true,
    "path": "infra/main.bicep",
    "coversAllModules": false,
    "gaps": ["src/MyFunctions"]
  },
  "components": [
    { "AppType": "Functions", "TargetAzureService": "Azure Functions", "ComponentPath": "src/MyFunctions" }
  ]
}
```

The `components` array uses the same format as the `deploy-app-type-select` multi-component output, ready for direct handoff to `deploy-pipeline-author` and `Invoke-PipelineAuthorValidation.ps1 -ComponentsJson`.

### User Confirmation of Module List

When multiple modules are discovered, the agent presenting results to the user MUST follow a **two-step structured confirmation protocol**. The workspace manifest on disk is **not modified** — filtering is applied in-memory during pipeline generation.

#### Step A — Deduplication (only when ambiguity exists)

If two or more modules share the same `AppType` AND appear to be the same logical component (e.g., root `.` and `api/` are both Python), ask the user which is the canonical module:

> Modules `.` and `api` are both detected as **Python / App Service**. Which is the canonical Python module?
> 1. `.` (workspace root)
> 2. `api`

Do NOT combine deduplication with scope decisions. Do NOT pre-select a winner. Wait for the user's answer before proceeding.

#### Step B — Full component confirmation (always, after deduplication)

After resolving any duplicates, present **every remaining component** in a neutral table. Do NOT pre-filter, pre-exclude, or assume scope before the user responds.

**You MUST use the EXACT table format below — 5 columns, numbered rows.** Do NOT omit the `#` column, rename columns, reorder columns, or use a different table layout. Every row MUST have a sequential number starting from 1.

> These are the deployable components found after deduplication:
>
> | # | Module Path | App Type | Azure Service | Include? |
> |---|-------------|----------|---------------|----------|
> | 1 | `api` | Python | App Service | ✅ |
> | 2 | `frontend` | Node.js | App Service | ✅ |
> | 3 | `public` | Static | Static Web Apps | ✅ |
>
> All components are included by default. Tell me which to **exclude** by number (e.g., "exclude 3"), or say **"looks good"** to confirm all.

**Prohibited patterns:**
- Do NOT ask a leading question that presupposes exclusion (e.g., *"Should we deploy only X?"*).
- Do NOT embed scope reduction into a deduplication question.
- Do NOT collapse Steps A and B into a single question.
- Do NOT omit any component from the table — every module that survived deduplication must appear.
- Do NOT render the table without numbered rows. Every row MUST start with a sequential `#` (1, 2, 3…).
- Do NOT use a different column layout (e.g., Module/Type/Notes). The columns MUST be: `#`, `Module Path`, `App Type`, `Azure Service`, `Include?`.

See also Step 1.5 in `vibeshield-deploy-pipeline-author.agent.md` for the pipeline-author agent's implementation of this protocol.

---

## Automation Script

This skill includes a deterministic PowerShell script that performs Phases 1–5 non-interactively.

> **Preferred invocation in Stage 2**: During Pipeline Setup, this script is chained with SC resolution via `Invoke-Stage2PreRunner.ps1` in a single terminal call (reduces confirmation dialogs). See `vibeshield-deploy-pipeline-author` Step 1. The standalone invocation below is used for fallback or when running outside Stage 2.

### Invocation

```powershell
# Run from workspace root (defaults)
./.github/skills/deploy-workspace-analysis/scripts/Invoke-WorkspaceAnalysis.ps1

# Explicit parameters
./.github/skills/deploy-workspace-analysis/scripts/Invoke-WorkspaceAnalysis.ps1 `
    -WorkspacePath "./my-app" `
    -PipelineYmlPath ".azdo/pipelines/azure-pipeline.yml" `
    -OutputPath ".vibeshield/results/workspace-manifest.json"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `WorkspacePath` | No | `$PWD` | Root directory of the application workspace |
| `PipelineYmlPath` | No | `.azdo/pipelines/azure-pipeline.yml` | Relative path to the pipeline YAML |
| `OutputPath` | No | `.vibeshield/results/workspace-manifest.json` | Path to write the JSON manifest |

### Output

- **Console**: Phase-by-phase progress with per-module classification details
- **JSON manifest**: Written to `OutputPath` — contains `modules[]`, `bicep{}`, `components[]`
- **Exit code**: `0` = analysis complete, `1` = no deployable modules found

### Tests

```powershell
Invoke-Pester -Path ./.github/skills/deploy-workspace-analysis/scripts/Invoke-WorkspaceAnalysis.Tests.ps1 -Output Detailed
```

---

## Downstream Actions

After producing the workspace manifest, the `deploy-pipeline-author` agent uses it to:

1. **Generate Build/Deploy stages** for every module — not just the primary one.
2. **Pass the `components` array** to `Invoke-PipelineAuthorValidation.ps1` via `-ComponentsJson` for PA-34 through PA-39 multi-component checks.
3. **Delegate to `vibeshield-bicep`** with the full module list and Bicep gap analysis, requesting it to either:
   - **Use and fix existing Bicep** if `BicepExists` is true — ask `vibeshield-bicep` to review the existing Bicep and add any missing resources for uncovered modules.
   - **Generate new Bicep** if `BicepExists` is false — provide the complete list of modules and their `TargetAzureService` values.
4. **Inform `deploy-build-readiness`** (the companion skill) which modules need local build/test verification and which SDKs are required.

## CGRP Reminder

Before classifying modules or reporting workspace structure, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to workspace analysis:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 1 | Ungrounded Assertion | Reporting an AppType without verifying marker files exist on disk |
| 7 | Ambiguity | Multiple project files found (e.g., `package.json` + `.csproj`) — classify both, don't pick one silently |

If any signal fires: **Stop → Verify → Pivot** before continuing.
