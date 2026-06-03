# deploy-onebranch-pipeline-authoring

Generate and validate OneBranch governed pipeline YAML (both Buddy and Official variants). Parallel to `deploy-1es-pipeline-authoring` but for the OneBranch framework.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Buddy + Official generation** | Generates both OneBranch-Buddy (CI/PR) and OneBranch-Official (release) pipeline YAML |
| **CrossPlat template support** | Uses `v2/OneBranch.NonOfficial.CrossPlat.yml` and `v2/OneBranch.Official.CrossPlat.yml` templates |
| **Multi-app-type build stages** | Generates build stages for .NET, Node.js, Python, Java, and container app types |
| **es-metadata.yml integration** | Validates Service Tree ID and generates OneBranch-specific metadata references |
| **Artifact packaging** | Configures `ob_outputDirectory` and artifact publish tasks for OneBranch |
| **OB validation checks** | Runs OB-01 through OB-30 structural and semantic checks |

## When to Use

When `Get-PipelineFramework` returns `Framework: OneBranch` (i.e., `businessUse` project type for any environment).

## Output

Two pipeline YAML files in `.azure-pipelines/`:
- `OneBranch-Buddy-{appName}.yml` — NonOfficial variant (non-`main` branches, PR validation)
- `OneBranch-Official-{appName}.yml` — Official variant (`main` branch, code signing)

## Hard Constraints

All constraints from `deploy-1es-pipeline-authoring` apply, plus:

> **Scope boundary**: The stage structure depends on `InfraDeployMethod`. ARM pipelines use standard `Build → Provision → Deploy` (same as 1ES, different pool syntax). EV2 pipelines use `Build → EV2 Infra → EV2 App` with different naming, variables, and pool. The EV2-specific requirements in this skill apply **ONLY** when `InfraDeployMethod == 'EV2'`.

1. **Both variants always generated** — never generate only Buddy or only Official.
2. **OneBranch governed templates only** — `v2/OneBranch.NonOfficial.CrossPlat.yml@templates` (Buddy) or `v2/OneBranch.Official.CrossPlat.yml@templates` (Official).
3. **Repository resource** — `OneBranch.Pipelines/GovernedTemplates` at `refs/heads/main` (alias: `templates`).
4. **Pool** — Build: `type: windows`. EV2 stages: `type: release`. ARM Provision/Deploy: `type: windows`. No `name`, `vmImage`, or `demands`.
5. **SDL** — `globalSdl` block (not `sdl`). Minimal required: `policheck.break: true`. All other settings (tsa, sbom, binskim, credscan) default from the template — only override when needed. Buddy vs Official overrides: Official sets `tsa: true` and `binskim.break: true`; Buddy sets `tsa: false`.
6. **Versioning** — `onebranch.pipeline.version@1` required in every build stage.
7. **Artifacts** — `ob_outputDirectory` variable on build job. No explicit publish task (OneBranch auto-publishes). Downstream stages reference artifacts at `$(Pipeline.Workspace)/drop_build_main/`.
8. **Signing** — `onebranch.pipeline.signing@1` with `sign` + `verify` in Official variant only. Omit in Buddy. When EV2, signing runs on EV2 artifacts in the Build stage.
9. **Mandatory top-level variables** — `CDP_DEFINITION_BUILD_COUNT`, `WindowsContainerImage`, `ServiceTreeId`. The `ServiceTreeId` value MUST be auto-populated from `es-metadata.yml` at authoring time: read the `service:` GUID from `accountableOwners.service` and emit it as a literal value (e.g., `ServiceTreeId: '9d3392ae-...'`). Do NOT use `$(CDP_SERVICE_TREE_ID)` — use the resolved GUID directly.
10. **Parameter-gated stages** — `runBuild`, `runProvision`, `runDeploy` boolean parameters with conditional `${{ if }}` blocks and `dependsOn` wiring.
11. **No bare `- script:` tasks** — use `PowerShell@2` with `targetType: inline` and `pwsh: true`.
12. **Trigger rules** — Buddy: exclude `main`, include PR on `main`+`release/*`. Official: include `main`+`release/*`, `pr: none`.
13. **Build stage name** — MUST be `build` (lowercase). Job name MUST be `main`. This determines the artifact path: `drop_build_main`.
14. **`ob_sdl_*` variables are build-only** — NOT applicable to EV2 provision/deploy stages. `ob_release_*` variables are EV2 stage-only — NOT applicable to build stage.

## OneBranch Template Structure

### Skeleton Selection

| Variant | Skeleton Template | Key Differences |
|---------|------------------|-----------------|
| Buddy (NonOfficial) | `onebranch-skeleton-buddy.yml` | `trigger: exclude main`, `pr: include main`, `tsa: false`, no signing |
| Official | `onebranch-skeleton-official.yml` | `trigger: include main`, `pr: none`, `tsa: true`, `binskim.break: true`, signing steps |

### Build Stage Template Selection

| App Type | OneBranch Build Template | Notes |
|----------|------------------------|-------|
| .NET / Functions (.NET) | `onebranch-build-dotnet.yml` | `DotNetCoreCLI@2`, `NuGetAuthenticate@1`, TFM SDK cross-ref |
| Node.js / Functions (Node) | `onebranch-build-node.yml` | `NodeTool@0`, `npmAuthenticate@0`, `PowerShell@2` |
| Python / Functions (Python) | `onebranch-build-python.yml` | `UsePythonVersion@0`, `PipAuthenticate@1`, `PublishTestResults@2` |
| Java / Functions (Java) | `onebranch-build-java.yml` | `JavaToolInstaller@0`, `MavenAuthenticate@0`, `Maven@4` |
| Container / Go / Rust | `onebranch-build-container.yml` | `Docker@2` validate build |

### Deploy Stage Templates

Deploy stages use the **same** deploy templates as 1ES (pool is inherited from skeleton):
- `deploy-appservice.yml` — App Service
- `deploy-functions.yml` — Azure Functions
- `deploy-containerapp.yml` — Container Apps
- `deploy-staticwebapp.yml` — Static Web Apps

> **Note**: These deploy templates apply ONLY when `InfraDeployMethod == 'ARM'`. When EV2, deploy stages use `Ev2RARollout@2` (see EV2 sections below).

### Build Job Variables

| Variable | Required? | Scope |
|----------|----------|-------|
| `ob_outputDirectory` | Yes | Build only — sets output directory for auto-publish |
| `ob_sdl_binskim_break` | Yes | Build only — break on BinSkim findings |
| `ob_sdl_roslyn_break` | Yes | Build only — break on Roslyn findings |
| `ob_sdl_binskim_enabled` | Optional | Build only — defaults to template setting |
| `ob_sdl_binskim_scanOutputDirectoryOnly` | Optional | Build only — scope scan to output dir |

**These `ob_sdl_*` variables are build job-level only.** They are NOT applicable to EV2 provision or deploy stages. EV2 stages use `ob_release_*` variables instead.

### EV2 Infrastructure + Application Deploy (EV2 pipelines only)

> **This section applies ONLY when `InfraDeployMethod == 'EV2'`.** When ARM, the standard Provision stage (`AzureCLI@2` + Bicep) and standard Deploy stages (deploy templates with `stageDependencies`) are used instead.

When `InfraDeployMethod == 'EV2'`, replace the ARM Provision + Deploy stages with **two EV2 stages** using `deploy-ev2.yml`:

1. **EV2 Infra stage** — provisions Azure resources via EV2 managed rollout
2. **EV2 App stage** — deploys application code via EV2 managed rollout

Each stage uses a **separate ServiceGroupRoot** directory for its EV2 artifacts.

#### EV2 Stage Naming Convention

| Component | Pattern | Dev Example | Prod Example |
|-----------|---------|-------------|-------------|
| **Infra stage** | `{Ev2Env}_Deploy_Infra_{ProjectEnv}` | `Test_Deploy_Infra_Dev` | `Prod_Deploy_Infra_Prod` |
| **App stage** | `{Ev2Env}_Deploy_App_{ProjectEnv}` | `Test_Deploy_App_Dev` | `Prod_Deploy_App_Prod` |
| **Infra display** | `{Ev2Env}: Deploy Infra {ProjectEnv}` | `Test: Deploy Infra Dev` | `Prod: Deploy Infra Prod` |
| **App display** | `{Ev2Env}: Deploy App {ProjectEnv}` | `Test: Deploy App Dev` | `Prod: Deploy App Prod` |
| **Job name** | `{EV2ENV}_Managed_SDP` | `TEST_Managed_SDP` | `PROD_Managed_SDP` |

Where:
- **Ev2Env**: `Test` for Dev/Test/UAT/POC, `Prod` for Prod
- **EV2ENV**: Uppercase (`TEST` or `PROD`)
- **ProjectEnv**: Target environment name

#### EV2 Stage Dependencies

```
build → {Ev2Env}_Deploy_Infra_{ProjectEnv} → {Ev2Env}_Deploy_App_{ProjectEnv}
```

#### EV2 Stage-Level Variables (both Infra and App stages)

```yaml
variables:
  ob_release_environment: Test       # or 'Production' for Prod
  ob_release_servicetreeid: $(ServiceTreeId)
```

These are **required** by the OneBranch release stage templates. Without them, the pipeline fails with `"Stage variable ob_release_environment is not defined"`.

#### EV2 Environment Mapping

| Project Environment | `Ev2Env` (stage name) | `ob_release_environment` |
|--------------------|-----------------------|--------------------------|
| Dev | `Test` | `Test` |
| Test | `Test` | `Test` |
| UAT | `Test` | `Test` |
| POC | `Test` | `Test` |
| Prod | `Prod` | `Production` |

Use the literal value — do NOT use a `replace()` chain on `parameters.environment`.

#### EV2 Job Pool

Both Infra and App jobs MUST use `type: release` — this tells OneBranch to use its release infrastructure for EV2 rollout. Build stage uses `type: windows`.

#### EV2 Service Connection

SC name: `cn-ev2deploy-{service}-{environment}` (derived from `deploy-config.json` → `ev2.serviceConnectionPattern`). Both Infra and App stages use the **same** SC for a given environment.

#### EV2 Artifact Path

`$(Pipeline.Workspace)/drop_build_main/ev2/<ServiceGroupRootDir>`

Derived from: `drop` (prefix) + `build` (stage name) + `main` (job name). The Infra and App stages reference different `<ServiceGroupRootDir>` directories.

#### `ev2ManagedSdpRolloutConfig` Parameter

Required as an `extends.parameters` block (not a stage variable):

```yaml
extends:
  template: v2/OneBranch.NonOfficial.CrossPlat.yml@templates
  parameters:
    ev2ManagedSdpRolloutConfig:
      rolloutType: 'normal'
      overrideManagedValidationDuration: false
      managedValidationOverrideDurationInHours: 0
      icmIncidentId: 0
```

## Pipeline Structure by InfraDeployMethod

### ARM Pipeline (`InfraDeployMethod == 'ARM'`)

Standard three-stage chain, same as 1ES with OneBranch pool syntax:

| Stage | Purpose | Pool | Dependencies |
|-------|---------|------|-------------|
| `build` | Compile, test, publish to `ob_outputDirectory` | `type: windows` | None |
| `Provision` | Deploy infrastructure via `AzureCLI@2` + Bicep | `type: windows` | `build` |
| `Deploy` | Deploy app to Azure service (deploy templates) | `type: windows` | `Provision` |

App names flow from Bicep outputs via `stageDependencies`.

### EV2 Pipeline (`InfraDeployMethod == 'EV2'`)

| Stage | Purpose | Pool | Dependencies |
|-------|---------|------|-------------|
| `build` | Compile, test, prepare EV2 artifacts, publish to `ob_outputDirectory` | `type: windows` | None |
| `{Ev2Env}_Deploy_Infra_{ProjectEnv}` | Provision infrastructure via `Ev2RARollout@2` | `type: release` | `build` |
| `{Ev2Env}_Deploy_App_{ProjectEnv}` | Deploy application via `Ev2RARollout@2` | `type: release` | Infra stage |

App names are declared in `ServiceModel.json` — no `stageDependencies`.

## Multi-Component Pipeline Handling

Same rules as 1ES (see `deploy-1es-pipeline-authoring`):
- Every confirmed module gets its own Build + Deploy stage pair
- Artifact names must be unique
- Provision depends on all Build stages
- All Deploy stages depend on Provision
- Secondary Deploy app names from `stageDependencies` (Bicep outputs)

## Package Feed Authentication

Same ordering rules as 1ES: SDK installer → Auth task → Package install/restore.

| App Type | SDK Task | Auth Task |
|----------|----------|-----------|
| .NET | `UseDotNet@2` | `NuGetAuthenticate@1` |
| Node.js | `NodeTool@0` | `npmAuthenticate@0` |
| Python | `UsePythonVersion@0` | `PipAuthenticate@1` |
| Java | `JavaToolInstaller@0` | `MavenAuthenticate@0` |

## Validation

After generating both YAML files, run `Invoke-OneBranchValidation.ps1` to validate OB-01 through OB-30. See `deploy-pipeline-validation` skill.

## Procedure

1. Load workspace manifest from `Invoke-WorkspaceAnalysis.ps1`.
2. Get user confirmation of module list.
3. For EACH variant (Buddy, then Official):
   a. Load skeleton template (`onebranch-skeleton-buddy.yml` or `onebranch-skeleton-official.yml`).
   b. Select build template by AppType from table above.
   c. If Official variant: ensure signing steps are included; if Buddy: ensure signing steps are removed.
   d. **If `infraDeploy == 'ARM'`**: select deploy template by TargetAzureService (same as 1ES). Wire `stageDependencies` for Bicep outputs.
   e. **If `infraDeploy == 'EV2'`**:
      - Add EV2 artifact preparation steps to the Build stage (see EV2 Build Steps below).
      - Generate TWO EV2 stages (Infra + App) using `deploy-ev2.yml` with correct naming convention.
      - Add `ev2ManagedSdpRolloutConfig` to `extends.parameters`.
      - Derive EV2 SC name from `deploy-config.json` → `ev2.serviceConnectionPattern`.
      - Do NOT generate an ARM Provision stage or standard Deploy stages.
   f. Replace all placeholders (`<sdk-version>`, `<app-name>`, `<resource-group>`, `<service-connection>`, `<Ev2Env>`, `<ProjectEnv>`, `<ServiceGroupRootDir>`, etc.).
   g. Write to `.azure-pipelines/OneBranch-{Variant}-{appName}.yml`.
4. Run `Invoke-OneBranchValidation.ps1` on both files.
5. Present results to user. If failures, fix and revalidate (max 3 cycles).

## EV2 Build Stage — Artifact Preparation

When `InfraDeployMethod == 'EV2'`, the Build stage must include these additional steps **after** the app build/publish steps:

1. **Copy EV2 files to output**:
   ```yaml
   - task: PowerShell@2
     displayName: 'Copy EV2 files to output'
     inputs:
       targetType: 'inline'
       script: |
         Copy-Item -Path "$(Build.SourcesDirectory)\ev2" -Destination "$(ob_outputDirectory)\ev2" -Recurse -Force
   ```

2. **Set EV2 version file** — write build number to `version.txt` in each ServiceGroupRoot:
   ```yaml
   - task: PowerShell@2
     displayName: 'Set EV2 version file'
     inputs:
       targetType: 'inline'
       script: |
         "$(Build.BuildNumber)" | Out-File "$(ob_outputDirectory)\ev2\<ServiceGroupRootDir>\version.txt" -Encoding ascii
   ```

3. **Archive extension scripts** (if `Scripts/` directory exists):
   ```yaml
   - task: ArchiveFiles@2
     displayName: 'Create extensions tar'
     inputs:
       rootFolderOrFile: '$(ob_outputDirectory)\ev2\<ServiceGroupRootDir>\Scripts'
       includeRootFolder: false
       archiveType: 'tar'
       tarCompression: 'none'
       archiveFile: '$(ob_outputDirectory)\ev2\<ServiceGroupRootDir>\bin\swapSlot.tar'
       replaceExistingArchive: true
   ```

4. **Code signing** on EV2 artifacts:
   ```yaml
   - task: onebranch.pipeline.signing@1
     displayName: 'Sign output files'
     inputs:
       command: 'sign'
       signing_environment: 'azure-ado'
       files_to_sign: '**/*.exe;**/*.dll;**/*.ps1;**/*.psm1;'
       search_root: '$(ob_outputDirectory)\ev2\<ServiceGroupRootDir>'
   ```

5. **Zip built app** for EV2 deployment:
   ```yaml
   - task: ArchiveFiles@2
     displayName: 'Zip signed binaries for EV2'
     inputs:
       rootFolderOrFile: '$(Build.SourcesDirectory)/temp/'
       includeRootFolder: false
       archiveType: 'zip'
       archiveFile: '$(ob_outputDirectory)\ev2\<ServiceGroupRootDir>\bin\app.zip'
       replaceExistingArchive: true
   ```

**Note**: Signing (step 4) runs in the Build stage for EV2 artifacts — even in Buddy variant. This is different from the non-EV2 signing which is Official-only.

## Build + EV2 Deploy Only (infra provisioned separately)

> **Narrow scenario**: When an app's infrastructure is provisioned by a **separate** OneBranch+EV2 pipeline, the app's own pipeline has only `Build → EV2 Deploy` (no Infra stage). This applies when a team has a dedicated infra pipeline and separate app pipelines.

```
build → {Ev2Env}_Deploy_Corp_{ProjectEnv}
```

| Aspect | Detail |
|--------|--------|
| **Stages** | `build` + one EV2 Deploy stage (no Infra) |
| **Stage name** | `{Ev2Env}_Deploy_Corp_{ProjectEnv}` (e.g., `Test_Deploy_Corp_Dev`) |
| **Job name** | `{EV2ENV}_Managed_SDP_Corp_{ProjectEnv}` (e.g., `TEST_Managed_SDP_Corp_Dev`) |
| **Depends on** | Implicit (from `build`) |
| **Pool** | `type: release` |
| **SC** | `cn-ev2deploy-{service}-{environment}` |
| **Scope** | `Corp` (not `Infra` or `App`) |
| **Infra assumption** | Azure resources already exist, provisioned by the separate infra pipeline |

This variant uses the same `ob_release_*` variables, `ev2ManagedSdpRolloutConfig`, and `Ev2RARollout@2` task — the only difference is the absence of the Infra stage.

## OneBranch Pipeline Header

Every generated file MUST start with:

```yaml
#################################################################################
#                               OneBranch Pipelines                              #
# {AppName} - {Variant} Pipeline                                                #
# Documentation:  https://aka.ms/obpipelines                                     #
# Yaml Schema:    https://aka.ms/obpipelines/yaml/schema                         #
# Retail Tasks:   https://aka.ms/obpipelines/tasks                              #
# Support:        https://aka.ms/onebranchsup                                   #
#################################################################################
```

## CGRP Reminder

Before emitting OneBranch pipeline YAML, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to OneBranch authoring:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 2 | Unknown Command | Using a OneBranch task name or version that doesn't exist (e.g., `onebranch.pipeline.signing@2`) |
| 4 | Hedging | Saying "this container image should work" without verifying against the config |
| 6 | Suspiciously Easy | Generating a full OneBranch YAML without reading this skill file or the skeleton template |

If any signal fires: **Stop → Verify → Pivot** before continuing.
