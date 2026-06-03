---
name: deploy-1es-pipeline-authoring
description: 'Generate and validate 1ES Azure DevOps pipeline YAML (currently Unofficial variant). Use when: creating pipeline YAML, 1ES template, pipeline authoring, azure-pipeline.yml, build and deploy stages, CI/CD pipeline generation, pipeline validation.'
---

# 1ES Pipeline Authoring

> **Scope**: This skill covers **1ES pipelines only** (variants: `1ES.Unofficial@1` and `1ES.Official@1`). For OneBranch pipelines (`v2/OneBranch.*.CrossPlat.yml`), use the `deploy-onebranch-pipeline-authoring` skill instead. The pipeline-author agent selects the correct skill based on the resolved framework from `Get-PipelineFramework`.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **1ES template generation** | Generates pipeline YAML using `1ES.Unofficial@1` or `1ES.Official@1` templates |
| **Skeleton selection** | Chooses the correct pipeline skeleton based on app type and deployment target |
| **Build stage templates** | Generates app-type-specific Build stage tasks (.NET, Node.js, Python, Java, Docker) |
| **Deploy stage templates** | Generates Provision (Bicep) + Deploy (zip/slot-swap) stages with service connection |
| **SDL compliance** | Configures CredScan, PoliCheck, submodule suppression, and source analysis pool |
| **Pool configuration** | Sets the correct 1ES-BuildPool image for the OS and app type |
| **Service connection injection** | Injects the resolved `azureSubscription` into all deploy tasks |
| **Multi-module pipeline** | Generates per-module Build and Deploy stages for multi-module workspaces |
| **Structural constraints** | Enforces 1ES rules: regular jobs (no deployment jobs), checkout-before-deploy, etc. |
| **Incremental fix support** | Fixes existing pipeline issues without regenerating from scratch |

## When to Use

- Generating `/.azdo/pipelines/azure-pipeline.yml` from scratch
- Validating an existing pipeline against 1ES structural and semantic requirements
- Incrementally fixing issues in an existing pipeline
- Modifying pipeline stages, jobs, or deployment tasks
- Post-authoring verification of pipeline correctness

## Hard Constraints

- MUST NOT generate pipeline YAML unless the workspace manifest (`.vibeshield/results/workspace-manifest.json`) exists on disk and was produced by `Invoke-WorkspaceAnalysis.ps1` in the current session. An inferred, cached, or preflight `AppType` result (e.g., from state file) is NOT a substitute — run workspace analysis first if the manifest is absent or stale. If the manifest is missing, **stop** and tell the orchestrator to run workspace analysis before returning to pipeline authoring.
- MUST NOT generate pipeline YAML unless the `Components` array used for stage generation was **explicitly confirmed by the user** through the structured confirmation protocol (see `deploy-workspace-analysis` SKILL.md, "User Confirmation of Module List"). If the components were inferred, narrowed, or assumed by the agent without user confirmation, **stop** and surface the full component list to the user for explicit confirmation before generating any YAML. A leading question that presupposes exclusion (e.g., *"Should we deploy only X?"*) does NOT count as valid confirmation — the user must have seen a neutral table of ALL components and explicitly confirmed or excluded items.
- MUST extend a governed 1ES pipeline template — `1ES.Unofficial@1` (variant `Unofficial`) or `1ES.Official@1` (variant `Official`). No ungoverned or raw pipelines
- MUST use regular `job` (not `deployment` job) in deploy stages — do NOT use `environment`, `templateContext`, or `strategy.runOnce`
- MUST set `submodules: false` on every `checkout: self` step — git submodule repos listed in `.gitmodules` must NOT be checked out or added as `resources.repositories` entries
- MUST set `persistCredentials: true` and `fetchDepth: 1` on every `checkout: self` step
- MUST configure submodule suppression in the SDL section (`sdl.git.submodules: false`, `sdl.checkout.submodules: false`) — this replaces the need for strip submodules scripts in individual stages
- MUST NOT hardcode secrets, tokens, or connection strings — use pipeline variables or Key Vault references
- MUST authenticate with the project's configured package feed before installing packages — every language has a required auth task (see Package Feed Authentication below)
- Service connection name MUST follow `sc-vibe-<name>-ARM` convention
- Pipeline file MUST be at `/.azdo/pipelines/1ES-<Variant>-<appName>.yml` (e.g., `1ES-Unofficial-MyApp.yml`). Use `Get-PipelineFileNames` to resolve.
- Pipeline `variables` block MUST be defined at the top level (between `resources` and `extends`), NOT inside `extends.parameters`
- Pipeline `appName` variable MUST be sourced from `stageDependencies.Provision.ProvisionJob.outputs['bicepOutput.appName']` — NEVER from `$(appName)` pipeline variable or hardcoded values. All Deploy stages (primary and secondary) use the same `stageDependencies` pattern to read their app name from Bicep Provision outputs. This ensures the deployed resource name matches what Bicep actually provisioned, even when dynamic naming (`uniqueString()`, `toLower()`) is used
- All Deploy stage app names (primary and secondary) MUST come from `stageDependencies` referencing Provision outputs — NEVER from `$(appName)` pipeline variables or hardcoded values
- On Windows pools, MUST use `- pwsh:` instead of `- script:` for inline commands — `- script:` runs in cmd.exe which mishandles `$(...)` pipeline variable expansion. This applies to build stages with `dotnet`, `npm`, `pip` commands. The validation script (PA-40) detects and auto-fixes this when run with `-AutoFix`.

## 1ES Template Structure

Read the skeleton based on the resolved variant:

| Variant | Skeleton File | Template |
|---------|--------------|----------|
| `Unofficial` | `.github/templates/1es-skeleton.yml` | `v1/1ES.Unofficial.PipelineTemplate.yml@1ESPipelineTemplates` |
| `Official` | `.github/templates/1es-skeleton-official.yml` | `v1/1ES.Official.PipelineTemplate.yml@1ESPipelineTemplates` |

The variant is determined by `Get-PipelineFramework` from the `frameworkSelection` table in `deploy-config.json`. Select the correct pool using the **`deploy-build-pool-image`** skill, and insert the appropriate build and deploy stages from the other template files.

### Differences Between Unofficial and Official

| Aspect | Unofficial | Official |
|--------|-----------|----------|
| Template | `1ES.Unofficial@1` | `1ES.Official@1` |
| Trigger | `main` only | `main` + `release/*` |
| PoliCheck | `enabled: true` | `enabled: true`, `break: true` |
| BinSkim | Not configured | `enabled: true`, `break: true` |

Two pool configurations exist:
- **Windows**: `pool: name: 1ES-BuildPool` with `os: windows`
- **Linux**: Not yet available — use Windows (`1ES-BuildPool` + `os: windows`) for all app types

Load the **`deploy-build-pool-image`** skill for the full image selection table and validation rules.

### SDL Section

The SDL section MUST include all of the following properties to properly suppress submodule processing and enable security scanning:

```yaml
    sdl:
      git:
        submodules: false
      sourceAnalysisPool:
        name: 1ES-BuildPool
        os: windows
      credscan:
        enabled: true
      policheck:
        enabled: true
      checkout:
        submodules: false
```

- `sdl.git.submodules: false` — Prevents 1ES SDL from processing submodule repos
- `sdl.sourceAnalysisPool` — Must always use `name: 1ES-BuildPool` with `os: windows` regardless of the main pool configuration
- `sdl.checkout.submodules: false` — Prevents the 1ES template from initializing submodules
- These SDL-level settings replace the need for strip submodules scripts in individual stages

## Agent Pool Selection

Load the **`deploy-build-pool-image`** skill for OS selection. Do NOT duplicate its table here — that skill is the single source of truth for pool OS per app type. Currently all app types use `os: windows` (Linux image not yet available). Static Web App deployments use the SWA CLI, which runs natively on Windows — no Linux pool override is needed.

## Build Stage Templates

Select the correct template file based on the detected app type and read it from `.github/templates/`:

> **SDK version rule**: Use the SDK Detection Priority defined in the `deploy-build-readiness` skill (BR-03). For .NET, NEVER derive SDK version solely from `<TargetFramework>` — always check `global.json` first, then `dotnet --version`.

| App Type | Template File | Notes |
|----------|--------------|-------|
| .NET | `build-dotnet.yml` | Also used for Functions with .NET runtime |
| Node.js | `build-node.yml` | Also used for Functions with Node.js runtime |
| Python | `build-python.yml` | Also used for Functions with Python runtime |
| Java | `build-java.yml` | Also used for Functions with Java runtime |
| Container | `build-container.yml` | Docker build + ACR push. Also used for Go and Rust |
| Go | `build-container.yml` | Requires Dockerfile — uses container build pipeline |
| Rust | `build-container.yml` | Requires Dockerfile — uses container build pipeline |
| Static frontend | *(inline)* | `npm install && npm run build`, publish `dist/` or `build/` folder |
| Static website | *(none)* | No build step needed — deploy static files directly |

Replace the placeholder version values (e.g., `<sdk-version>`) with the actual version detected from the project's configuration files. For .NET, use the **SDK Detection Priority** defined in the `deploy-build-readiness` skill (BR-03): `global.json` → `dotnet --version` → `.slnx` presence → `<TargetFramework>` fallback. Do NOT assume `<TargetFramework>` equals the required SDK version — a project targeting `net8.0` may require SDK 10.x.

**Always install both SDKs for .NET**: The pipeline MUST always include two `UseDotNet@2` steps — the TargetFramework SDK first, then the build SDK second. Read `<TargetFramework>` from the project's `.csproj` / `.fsproj` / `.vbproj` file and resolve the build SDK via the detection priority above. Install the TargetFramework SDK with `packageType: 'sdk'` (NOT `'runtime'` — runtime omits `Microsoft.AspNetCore.App`). The build SDK installed second takes precedence for `dotnet build` / `dotnet publish`, while the TargetFramework runtime remains available for `dotnet test`. Replace `<target-framework>` and `<sdk-version>` in `build-dotnet.yml` with the resolved versions.

**Functions**: Use the build template matching the Functions runtime language (e.g., .NET Functions → `build-dotnet.yml`), then use `deploy-functions.yml` for the deploy stage.

## Functions Packaging (All Languages)

When the detected AppType is `Functions`, the build stage MUST include `host.json` and all function trigger files in the published artifact — regardless of the Functions runtime language (.NET, Node.js, Python, Java). This is a **common requirement for all Functions apps**. Individual language-specific skills must NOT re-implement this logic.

### Files to include in the artifact

| File | Include? | Notes |
|------|----------|-------|
| `host.json` | **Always** | Functions runtime configuration — must be at the archive root |
| Function folders (e.g., `HttpTrigger/`) | **Always** | Each folder contains `function.json` (or equivalent) and the function code |
| `local.settings.json` | **Never** | Local-only settings — exclude via `.funcignore` or archive filters |
| `.funcignore` | If present | Controls which files are excluded from the deployment package |

### Build template modification for Functions

The build archive step (`ArchiveFiles@2`) in each language template archives from `$(System.DefaultWorkingDirectory)`. For Functions apps, verify:

1. **`host.json` is at the workspace root** and will be captured by the archive's `rootFolderOrFile`
2. **Function code folders** are siblings of `host.json` (standard Functions project layout)
3. **`local.settings.json` is excluded** — add it to `.funcignore` if not already present

No separate copy steps are needed — the standard archive captures everything at the workspace root. The deploy stage uses `deploy-functions.yml` with `AzureFunctionApp@2`, which expects the artifact to be a zip containing `host.json` at its root.

## Deploy Stage Templates

### Three-Stage Pipeline Structure

Every pipeline uses three stages: **Build → Provision → Deploy**.

- **Build** — Compiles/packages the application and publishes an artifact.
- **Provision** — Deploys Bicep infrastructure (`az deployment group create`). Runs as its own stage so infrastructure is guaranteed to exist before app code is deployed.
- **Deploy** — Downloads the build artifact and deploys app code to the Azure service. Depends on Provision, not Build.

### Provision Stage (ALL app types)

The Provision stage MUST contain exactly these steps:

1. **`checkout: self`** — Source code is needed for Bicep templates. Must include `submodules: false`, `persistCredentials: true`, and `fetchDepth: 1`.
2. **`AzureCLI@2`** — Run `az deployment group create` using the service connection for authentication. NEVER use a bare `script` task for `az` commands — it has no credentials. Always use `AzureCLI@2` with `azureSubscription: '$(serviceConnection)'`.

The Provision stage inline script MUST resolve the Bicep parameters file dynamically — check for `parameters.dev.bicepparam` first, then fall back to `dev.bicepparam`. **Before the actual deployment, run a what-if validation (IL-5)** to catch SKU incompatibilities, region restrictions, and RBAC issues early:

```bash
PARAM_FILE="$(Build.SourcesDirectory)/infra/parameters.dev.bicepparam"
if [ ! -f "$PARAM_FILE" ]; then
  PARAM_FILE="$(Build.SourcesDirectory)/infra/dev.bicepparam"
fi

# What-if validation — catches errors before committing resources
az deployment group what-if \
  --resource-group $(resourceGroup) \
  --template-file "$(Build.SourcesDirectory)/infra/main.bicep" \
  --parameters "$PARAM_FILE" 2>&1 || {
    echo "##vso[task.logissue type=error]Bicep what-if validation failed — review the errors above before deployment proceeds"
    exit 1
  }

az deployment group create \
  --resource-group $(resourceGroup) \
  --template-file "$(Build.SourcesDirectory)/infra/main.bicep" \
  --parameters "$PARAM_FILE" \
  --name vsd-provision

# Emit all Bicep deployment outputs as pipeline variables for Deploy stages
az deployment group show \
  --resource-group $(resourceGroup) \
  --name vsd-provision \
  --query 'properties.outputs' -o json | python3 -c "
import json, sys
outputs = json.load(sys.stdin)
for k, v in outputs.items():
    val = v.get('value', '')
    print(f'##vso[task.setvariable variable={k};isoutput=true]{val}')
"
```

The `AzureCLI@2` task MUST have `name: bicepOutput` so Deploy stages can reference outputs via `stageDependencies.Provision.ProvisionJob.outputs['bicepOutput.<outputName>']`.

### Deploy Stage

The Deploy stage downloads the build artifact and deploys to the target Azure service. It depends on `Provision` (not `Build`).

Submodule suppression is handled at the SDL level (`sdl.git.submodules: false` and `sdl.checkout.submodules: false`), so strip submodules scripts are NOT needed in individual stages.

These stages are already embedded in each deploy template file.

Select the correct deploy template based on the target Azure service and read it from `.github/templates/`:

| Target Azure Service | Template File |
|---------------------|--------------|
| App Service | `deploy-appservice.yml` |
| Container Apps | `deploy-containerapp.yml` |
| Static Web Apps | `deploy-staticwebapp.yml` |
| Azure Functions | `deploy-functions.yml` |

### Static Web App npm Feed Setup

The SWA CLI (`@azure/static-web-apps-cli`) is installed via npm in the Deploy stage. Because 1ES agents block direct access to `registry.npmjs.org`, the project must have an `.npmrc` pointing to the Azure Artifacts npm feed:

1. Check if `.npmrc` exists in the workspace root. If not, create one pointing to the project's Azure Artifacts npm feed (derive the feed URL from the existing `nuget.config`'s `packageSources` — replace `/nuget/v3/index.json` with `/npm/registry/`).
2. Always include `npmAuthenticate@0` before `npm install` in the Deploy stage.
3. Use `npm install` (local) + `npx` invocation — never `npm install -g` (global installs ignore the project `.npmrc`).

### Multi-Component Pipelines

When workspace analysis reports secondary components (the `Components` array in the workspace manifest), the pipeline MUST build and deploy **each component** independently. The Three-Stage Structure expands as follows:

**Stage layout for multi-component workspaces:**

| Stage | Name Pattern | Depends On | Purpose |
|-------|-------------|------------|---------|
| Build (primary) | `Build` | — | Build the primary component (e.g., `.NET` API) |
| Build (secondary) | `Build_Functions` (or `Build_{AppType}`) | — | Build the secondary component (e.g., Functions app). Runs in parallel with primary Build |
| Provision | `Provision` | `Build`, `Build_Functions` | Single Provision stage — all infra is deployed from one Bicep template |
| Deploy (primary) | `Deploy` | `Provision` | Deploy primary component (e.g., `AzureWebApp@1`) |
| Deploy (secondary) | `Deploy_Functions` (or `Deploy_{AppType}`) | `Provision` | Deploy secondary component (e.g., `AzureFunctionApp@2`) |

**Key rules for multi-component pipelines:**

1. Each component gets its **own Build stage** using the template from the Build Stage Templates table matching its AppType.
2. Each Build stage sets its `workingDirectory` to the component's `ComponentPath` (from detection). The primary component uses workspace root; secondary uses the relative path (e.g., `src/MyFunctions`).
3. Each component gets its **own Deploy stage** using the template from the Deploy Stage Templates table matching its TargetAzureService.
4. **Only ONE Provision stage** — all infrastructure is provisioned from a single `infra/main.bicep`. Provision depends on ALL Build stages.
5. Each Deploy stage publishes and downloads its artifact with a **unique artifact name** (e.g., `drop` for primary, `drop-functions` for secondary).
6. **Stage names** MUST be unique — append the component's AppType (e.g., `Build_Functions`, `Deploy_Functions`).
7. All Deploy stage app names (primary AND secondary) MUST be derived from Bicep deployment outputs via `stageDependencies`. Read `main.bicep` outputs to discover the variable names for each component's deployed resource. Every Deploy stage declares a stage-level variable that pulls the app name from Provision outputs:

```yaml
- stage: Deploy
  dependsOn: Provision
  variables:
    appName: $[ stageDependencies.Provision.ProvisionJob.outputs['bicepOutput.appName'] ]
```

```yaml
- stage: Deploy_Functions
  dependsOn: Provision
  variables:
    functionAppName: $[ stageDependencies.Provision.ProvisionJob.outputs['bicepOutput.functionAppName'] ]
```

NEVER use `$(appName)` pipeline variables or hardcode app names — `main.bicep` outputs are the sole source of truth for deployed resource names. This applies uniformly to single-module and multi-module workspaces.

**Example: .NET API + Functions pipeline stages:**

```
Build          → dotnet build MyApi.csproj, publish artifact 'drop'
Build_Functions → dotnet build MyFunctions.csproj (from ComponentPath), publish artifact 'drop-functions'
Provision      → az deployment group create (single Bicep), dependsOn: [Build, Build_Functions]
Deploy         → AzureWebApp@1 using 'drop' artifact, dependsOn: Provision
Deploy_Functions → AzureFunctionApp@2 using 'drop-functions' artifact, dependsOn: Provision
```

## Monorepo Archive and Startup Rules (IL-2)

When a module's `ComponentPath` is a subdirectory (not `.`), the pipeline MUST scope the archive and startup command correctly:

1. **Archive only the module directory** — set `ArchiveFiles@2.rootFolderOrFile` to `$(System.DefaultWorkingDirectory)/{ComponentPath}`. Never archive the full workspace for a single App Service module.
2. **Match startup command to archive root** — if archiving `server/`, the file structure at deployment root is flat (e.g., `index.js` at root, not `server/index.js`). Set `appCommandLine` in the Bicep request accordingly: `node index.js` (not `node server/index.js`).
3. **Install dependencies in the module directory** — run `npm ci --prefix {ComponentPath}` or `cd {ComponentPath} && npm ci` so `node_modules` is inside the archived directory.
4. **Set `SCM_DO_BUILD_DURING_DEPLOYMENT=false`** — when the pipeline installs and archives dependencies, Oryx must not re-run `npm install` during deployment. Pass this as a Bicep `appSettings` requirement.
5. **Always set `appCommandLine` explicitly** — never rely on Oryx auto-detection for monorepos. Read `package.json` `main` or `scripts.start` to determine the entry point. Pass to Bicep as an `appSettings` requirement.

These rules apply to **all app types** with subdirectory modules, not just Node.js.

## Module Selection by Buildability

## EV2 Pipeline Authoring (1ES + EV2)

When `InfraDeployMethod == 'EV2'` and `framework == '1ES'`, the pipeline structure changes significantly. Use the `deploy-ev2-1es.yml` template for deploy stages instead of the ARM templates above.

### Build Stage Additions (EV2)

When authoring a 1ES + EV2 pipeline, the Build stage includes all standard build steps PLUS these EV2-specific steps at the end (before `1ES.PublishBuildArtifacts@1`):

| Step | Task | Script |
|------|------|--------|
| Verify publish output | `PowerShell@2` | `Get-ChildItem` on each module's output directory |
| Zip each module | `PowerShell@2` | `Compress-Archive -Path "{module}/*" -DestinationPath "{module}/{Module}.zip"` |
| Copy EV2 files | `PowerShell@2` | `Copy-Item -Path "$(Build.SourcesDirectory)/ev2" -Destination "$(Build.ArtifactStagingDirectory)/ev2" -Recurse` |
| Bundle shell extension tars | `PowerShell@2` | For each module: copy deploy script + zip → temp dir → `tar -cf "ev2/ServiceGroupRoot/bin/deploy{Module}.tar"` |
| Bundle swap script tars | `PowerShell@2` | For each module with staging slots: copy swap script → temp dir → `tar -cf "ev2/ServiceGroupRoot/bin/swap{Module}Slot.tar"` |
| Set version file | `PowerShell@2` | `"$(Build.BuildNumber)" \| Out-File "ev2/ServiceGroupRoot/version.txt"` |

All steps use `pwsh: true` (never bare `script:`). Module names in zip/tar filenames derive from the selected modules in the workspace manifest.

### Top-Level Variables (EV2)

Replace the ARM variables with:

```yaml
variables:
  ServiceTreeId: '<GUID>'           # literal from es-metadata.yml — auto-populated at authoring time
  ev2ServiceConnection: '<SC name>' # from deploy-config.json ev2.serviceConnectionPattern
```

Do NOT include `serviceConnection` (ARM SC) or `resourceGroup` — EV2 manages these internally.

### Trigger Paths (EV2)

Add `ev2/**` to trigger/PR path includes:

```yaml
trigger:
  paths:
    include: [src/**, ev2/**, .azdo/pipelines/**]
```

### Deploy Stages (EV2)

Replace ARM Provision/Deploy stages with the EV2 stages from `deploy-ev2-1es.yml`:
- **Provision** uses `Ev2RARollout@2` with `RolloutSpec.Infra.json`
- **Deploy** uses `Ev2RARollout@2` with `RolloutSpec.App.json`
- Both use the `ev2ServiceConnection` variable (EV2 Endpoint, not ARM)
- No `stageDependencies` for app names — `ServiceModel.json` declares targets
- `Select: 'regions(<region>)'` uses the target region from `Get-Ev2HandoverData` resolved `Regions`

### What NOT to Include (EV2)

- No `AzureCLI@2` Provision stage
- No `stageDependencies` variable blocks on Deploy stages
- No `AzureWebApp@1` / `AzureFunctionApp@2` deploy tasks
- No ARM `serviceConnection` or `resourceGroup` variables
- No `checkout: self` in Provision/Deploy stages (only `download: current`)



When the workspace manifest contains a `buildability.status` field per module (set by `deploy-build-readiness` BR-00), the pipeline author MUST filter modules accordingly:

- **`pass`** — include the module in the pipeline (generate Build + Deploy stages).
- **`fail`** — exclude the module from the pipeline entirely. Do not generate stages for it. Report the exclusion reason from `buildability.failReason` to the user.
- **`unknown`** — include the module in the pipeline but emit a warning that buildability could not be verified. The module may fail at pipeline runtime.

This filtering happens before stage generation. Only modules with `buildability.status == "pass"` (or `"unknown"` with a warning) receive Build and Deploy stages.

## Test Step Conditionality

Test steps are included in the pipeline **only if tests pass locally** (BR-02=PASS from the `deploy-build-readiness` skill). This prevents pipeline failures from tests that are already known to be broken. The decision chain:

1. Workspace analysis detects test files (`tests.unit` flag per module)
2. Build readiness (BR-02) runs the test command locally
3. If BR-02=PASS → include test steps in the pipeline
4. If BR-02=FAIL, SKIP, or --SkipTests → omit test steps from the pipeline

When test steps are omitted, a SARIF warning is emitted explaining why (e.g., "Tests fail locally; fix and re-run VSD to include tests in the pipeline").

| App Type | When tests are omitted (BR-02 ≠ PASS) |
|----------|----------------------------------------|
| **Python** | Omit the `pip install pytest` / `pytest` script step AND the `PublishTestResults@2` task |
| **Node.js** | Omit the `npm test --if-present` script step |
| **.NET** | Omit the `dotnet test` script step |
| **Java** | Change Maven options to `-DskipTests=true`, set `publishJUnitResults: false`, and remove `testResultsFiles` |
| **Container** | No test steps exist — no change needed |

The build templates under `.github/templates/` contain `# CONDITIONAL:` comments that document these rules inline. Always check the workspace manifest's `tests.unit` flag per module before generating the Build stage.

## Pipeline Variables

Every pipeline MUST define these variables at the **top level** (between `resources` and `extends`), NOT inside `extends.parameters`:

| Variable | Value | Source |
|----------|-------|--------|
| `resourceGroup` | Project resource group name | `$Config.ResourceGroup` from `infra/config.ps1` |
| `appName` | Application name | `$Config.AppName` from `infra/config.ps1` |
| `serviceConnection` | `sc-vibe-<name>-ARM` | `$Config.ServiceConnection` from `infra/config.ps1` |

### Reading values from `infra/config.ps1`

Before populating the variables block, **source `infra/config.ps1`** (generated by vibeshield-bicep) to auto-discover the correct values:

```powershell
$Config = $null
. ./infra/config.ps1
# Now use: $Config.ResourceGroup, $Config.AppName, $Config.ServiceConnection
```

If `infra/config.ps1` is missing, fall back to values provided by the orchestrator or user.

### Container-Specific Variables

Container/Docker app pipelines require these additional variables:

| Variable | Value |
|----------|-------|
| `containerRegistryConnection` | `sc-acrsandboxcuspoc-acr` (fixed — Docker registry service connection for ACR authentication via `Docker@2`) |
| `acrLoginServer` | ACR login server URL (e.g., `acrsandboxcuspoc.azurecr.io`) — used in `az containerapp update --image` references. Set from Bicep output or user input |

NEVER define variables for secrets — use Azure DevOps pipeline variable groups or Key Vault integration instead.

## Package Feed Authentication

Every build pipeline MUST include a package feed authentication task **before** any package install/restore step. The auth task authenticates against whatever feed is configured in the project's package manager config file (`nuget.config`, `.npmrc`, `pip.conf`, etc.).

> **Feed configuration is managed by VibeShield-CFS** (an external agent). This agent must NEVER create, modify, or hardcode package feed URLs. It only ensures the correct auth task is present in the pipeline YAML.

| Language | Auth Task | Key Input | Prerequisite in Repo |
|----------|-----------|-----------|---------------------|
| Python | `PipAuthenticate@1` | `artifactFeeds` (set to the feed configured in your project) | `pip.conf` or `pip.ini` with feed URL |
| .NET | `NuGetAuthenticate@1` | *(none — auto-discovers feeds from `nuget.config`)* | `nuget.config` with feed source |
| Node.js | `npmAuthenticate@0` | `workingFile: '$(Build.SourcesDirectory)/.npmrc'` | `.npmrc` with registry URL |
| Java | `MavenAuthenticate@0` | `artifactsFeeds` (set to the feed configured in your project) | — (settings injected into Maven) |

### Ordering Rules

The auth task MUST appear **after** the SDK/runtime installer and **before** the first package install step:

| Language | Order |
|----------|-------|
| Python | `UsePythonVersion@0` → **`PipAuthenticate@1`** → `pip install` |
| .NET | `UseDotNet@2` → **`NuGetAuthenticate@1`** → `dotnet restore` |
| Node.js | `NodeTool@0` → **`npmAuthenticate@0`** → `npm ci` |
| Java | `JavaToolInstaller@0` → **`MavenAuthenticate@0`** → `Maven@4` |

### Repo Configuration Files

For .NET, Node.js, and Python, the project must contain a feed configuration file pointing to the project's package feed. These files are created and managed by the **VibeShield-CFS** agent — this agent must NOT create or modify them.

- **.NET**: `nuget.config` at repo root with `<packageSources>` pointing to the project feed
- **Node.js**: `.npmrc` at repo root with `registry=` pointing to the project feed
- **Python**: `pip.conf` / `pip.ini` at repo root with `index-url` pointing to the project feed

## Validation

After generating or fixing a pipeline YAML file, run `Invoke-PipelineAuthorValidation.ps1` to validate PA-01 through PA-41 (structural, semantic, and multi-component checks). See the `deploy-pipeline-validation` skill for the full check catalog.

> **Do NOT duplicate the PA check list here.** The validation script is the single source of truth for check definitions. This avoids the checklist drifting out of sync when checks are added or modified.

Key validation concerns for pipeline authoring:
- **Structural**: 1ES template reference, repository resource, SDL configuration, job types, triggers, artifact flow
- **Semantic**: Build/deploy task correctness (per app type), stage dependencies, variable definitions, path references
- **Multi-component**: Per-module Build/Deploy stages, unique artifact names, Provision dependencies, output wiring
- **Feed auth**: Correct auth task before package install for each language (NuGet, npm, pip, Maven)

## CGRP Reminder

Before emitting pipeline YAML, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to pipeline authoring:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 2 | Unknown Command | Using an ADO task name or version that doesn't exist (e.g., `DotNetCoreCLI@3`) |
| 4 | Hedging | Saying "this should work" instead of validating against the task reference |
| 6 | Suspiciously Easy | Generating a full pipeline YAML without reading any skill files or config |

If any signal fires: **Stop → Verify → Pivot** before continuing.
