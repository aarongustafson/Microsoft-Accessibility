---
name: deploy-app-type-select
description: 'Single source of truth for app type detection, canonical naming, service mapping, build commands, required files, deploy tasks, and health checks. Use when: app type detection, identify project type, detect app type, select application type, what type of app, determine AppType, workspace analysis, project detection, build commands, required files, deploy tasks, health checks.'
---

# App Type Detection & Reference

> **This skill is the single source of truth** for app type detection, canonical naming, Azure service mapping, build commands, required files, deploy tasks, and health checks across the entire VibeShield-Deploy system. All agents MUST reference this skill for app type decisions. No agent may maintain an independent app type detection table or AppType→AzureService mapping.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Data-driven detection** | Identifies app types from workspace marker files using rules defined in `deploy-config.json` |
| **12+ app types supported** | .NET, F#, VB.NET, Functions, Node.js backend, Static frontend, Python, Java, Container, Go, Rust, Static website |
| **Canonical naming** | Single source of truth for app type names, Azure service targets, and runtime identifiers |
| **Build/test command mapping** | Maps each app type to its build and test commands |
| **Required file validation** | Defines required project files per app type (e.g., `*.csproj` for .NET, `package.json` for Node.js) |
| **Deploy task mapping** | Maps app types to Azure DevOps deploy tasks and health check endpoints |
| **Ambiguity resolution** | Handles workspaces with multiple marker files (e.g., both `package.json` and `*.csproj`) |
| **Config-driven extensibility** | Adding a new app type requires only a JSON entry in `deploy-config.json` — no code changes |

## Architecture

| Layer | File | Responsibility |
|-------|------|---------------|
| **Contract** | This SKILL.md | Documents the `appTypes` schema, priority rules, and detection behavior |
| **Data** | `.github/config/deploy-config.json` → `appTypes` | All app type definitions — markers, commands, config files, SDK floors. Adding a new app type = adding a JSON entry. |
| **Engine** | `.github/skills/deploy-app-type-select/scripts/Invoke-AppTypeDetect.ps1` | Generic marker-matching engine. Reads `appTypes` from config. Exposes `Get-AppType` (single-path) and `Get-ModuleAppTypes` (multi-module). |

### Consumers
- `Invoke-PreflightChecks.ps1` — PF-01 delegated (emits SKIP); detection moved to workspace analysis
- `Invoke-BuildReadiness.ps1` — BR's `Get-BuildTestCommands` delegates to `Get-AppType`
- `Invoke-WorkspaceAnalysis.ps1` — WA's `Get-ModuleAppType` delegates to `Get-AppType`
- `Invoke-StateFileManager.ps1` — staleness check calls `Get-AppType` for app type comparison
- `PipelinePush.Functions.ps1` — `Get-DetectedAppType` delegates to `Get-AppType`

## When to Use

- Detecting the application type from workspace files during workspace analysis (Stage 2)
- Resolving ambiguous app type when multiple project files are present
- Confirming the canonical AppType value before passing to downstream agents
- Looking up build commands, required files, deploy tasks, or health checks for an app type
- Guiding the user when no supported project type is found

## Hard Constraints

- Detection MUST be based on **file presence** — never on file content heuristics, directory names, or user claims alone.
- Each component's AppType MUST be one of the canonical AppType values defined in the Detection table below. No ad-hoc values.
- If no supported project type is found, **stop** — do not guess or force-fit.
- No other agent or skill may define its own detection algorithm or AppType→AzureService mapping.
- **Multi-component workspaces**: When marker files for **different Azure services** are found in separate subdirectories (e.g., `.csproj` in `MyApi/` and `host.json` in `MyFunctions/`), ALL components MUST be detected — do not stop at the first match. See "Multi-Component Detection" section below.

---

## Detection Table

Determine the app type by searching the workspace for these marker files:

| File Found | Application Type | Canonical AppType | Target Azure Service |
|------------|-----------------|-------------------|---------------------|
| `host.json` + function files | Azure Functions | `Functions` | Azure Functions |
| `Dockerfile` (no `host.json`) | Containerized app | `Container` | Azure Container Apps |
| `*.csproj` | .NET application | `.NET` | Azure App Service |
| `package.json` (React, Angular, Vue, etc.) | Static frontend | `Static frontend` | Azure Static Web Apps |
| `package.json` (express, fastify, nest, etc.) | Node.js backend | `Node.js backend` | Azure App Service |
| `pom.xml` or `build.gradle` | Java application | `Java` | Azure App Service |
| `requirements.txt` or `pyproject.toml` | Python application | `Python` | Azure App Service |
| `go.mod` | Go application | `Go` | Azure Container Apps |
| `Cargo.toml` | Rust application | `Rust` | Azure Container Apps |
| `*.fsproj` | F# / .NET application | `F#` | Azure App Service |
| `*.vbproj` | VB.NET application | `VB.NET` | Azure App Service |
| Static HTML/CSS/JS only | Static website | `Static website` | Azure Static Web Apps |

### Target Azure Service Routing (Deterministic)

`host.json` is the **sole differentiator** between Azure Functions and Azure App Service. Evaluate these rules in order — use the **first match**:

| # | Condition | Target Azure Service | Deploy Template |
|---|-----------|---------------------|------------------|
| 1 | `host.json` present | **Azure Functions** | `deploy-functions.yml` — regardless of what other language markers exist |
| 2 | `Dockerfile` present, no `host.json` | **Azure Container Apps** | `deploy-containerapp.yml` |
| 3 | `go.mod` or `Cargo.toml` present, no `host.json` | **Azure Container Apps** | `deploy-containerapp.yml` (Dockerfile required) |
| 4 | Frontend-only (`package.json` with React/Angular/Vue or static HTML/CSS/JS) | **Azure Static Web Apps** | `deploy-staticwebapp.yml` |
| 5 | Any other language marker (`.csproj`, backend `package.json`, `pom.xml`, `requirements.txt`, etc.) | **Azure App Service** | `deploy-appservice.yml` |

**Key implication**: A Python project with `host.json` → Azure Functions (not App Service). The same Python project without `host.json` → Azure App Service. The `host.json` file is always the deciding factor.

### Canonical AppType Values

When passing app type between agents, always use the **Canonical AppType** value from the table above. These are the only valid values:

`.NET` · `F#` · `VB.NET` · `Node.js backend` · `Static frontend` · `Static website` · `Java` · `Python` · `Container` · `Go` · `Rust` · `Functions`

### Unsupported Project Types

If the workspace contains project files that do not match any row in the Detection table above, the project type is **not currently supported**. In this case:

1. **Do NOT attempt to guess** a deployment strategy or force-fit an unsupported type into a supported category.
2. Inform the user clearly:
   > *"Your project type is not currently supported by VibeShield-Deploy. We're actively working on expanding support. Please contact **AI4CELA SPEAR team** for assistance with deploying this type of application."*
3. Stop the deployment workflow — do not proceed to Pipeline Setup or any later stage.

---

## Build/Test Command Reference

Local build and test commands per AppType. These MUST match the pipeline build stage templates. All agents performing builds or tests MUST use this table — do NOT invent build commands.

| AppType | Local Build Command | Local Test Command | Pipeline Build Template | Pipeline Test Step |
|---------|--------------------|--------------------|------------------------|-------------------|
| `.NET` | `dotnet build --configuration Release` | `dotnet test --configuration Release --no-build` | `build-dotnet.yml` | `dotnet test` |
| `F#` | `dotnet build --configuration Release` | `dotnet test --configuration Release --no-build` | `build-dotnet.yml` | `dotnet test` |
| `VB.NET` | `dotnet build --configuration Release` | `dotnet test --configuration Release --no-build` | `build-dotnet.yml` | `dotnet test` |
| `Node.js backend` | `npm install && npm run build --if-present` | `npm test --if-present` | `build-node.yml` | `npm test` |
| `Static frontend` | `npm install && npm run build --if-present` | `npm test --if-present` | `build-node.yml` | `npm test` |
| `Python` | `pip install -r requirements.txt` | `pytest --tb=short` | `build-python.yml` | `pytest` |
| `Java` (Maven) | `mvn package -DskipTests -q` | `mvn test -q` | `build-java.yml` | `mvn ... -DskipTests=false` |
| `Java` (Gradle) | `gradle build -x test` | `gradle test` | `build-java.yml` | `gradle test` |
| `Container` | `docker build . --quiet` | *(skipped — no standard test)* | `build-container.yml` | *(none)* |
| `Go` | `go build ./...` | `go test ./...` | `build-container.yml` | `go test` |
| `Rust` | `cargo build --release` | `cargo test` | `build-container.yml` | `cargo test` |
| `Functions` | Same as Functions runtime language | Same as Functions runtime language | Matches runtime | Matches runtime |
| `Static website` | *(none — no build step)* | *(none)* | *(none)* | *(none)* |

## Detection Algorithm

### Step 1: Scan the workspace root

Search for **all** marker files listed in the Detection table. Record every match — do NOT stop at the first match.

Marker files to check:

1. `host.json` + function trigger files → `Functions`
2. `Dockerfile` → `Container`
3. `*.csproj` → `.NET`
4. `*.fsproj` → `F#`
5. `*.vbproj` → `VB.NET`
6. `pom.xml` or `build.gradle` → `Java`
7. `requirements.txt` or `pyproject.toml` → `Python`
8. `go.mod` → `Go`
9. `Cargo.toml` → `Rust`
10. `package.json` with frontend framework (React, Angular, Vue, Svelte, Astro) → `Static frontend`
11. `package.json` with backend framework (express, fastify, nest, hapi, koa) → `Node.js backend`
12. Static HTML/CSS/JS only (no `package.json`, no other markers) → `Static website`

If **exactly one** marker is found, use that as the detected AppType and skip to Step 3.

If **multiple** markers are found, proceed to Step 2.

### Step 2: Resolve ambiguity

If multiple markers are found, use the Target Azure Service Routing rules above. Additionally, for combinations not covered by routing rules:

| Combination | Resolution |
|-------------|------------|
| `package.json` with both frontend and backend deps | **Auto-resolve** by analyzing `package.json` dependencies: if `react`, `vue`, `@angular/core`, `svelte`, or `astro` is a dependency, classify as `Static frontend`; if `express`, `fastify`, `@nestjs/core`, `hapi`, or `koa` is a dependency, classify as `Node.js backend`. If both are present, prefer `Node.js backend` (the frontend is likely bundled as part of the backend build). Only ask the user if neither category of dependency is found. |
| `.csproj` + `package.json` | Prefer `.NET` — the package.json is likely for frontend assets bundled with the .NET app |

### Step 3: Report detected type

After detection, **auto-accept the result** and inform the user without asking for confirmation:

> "Detected application type: **{AppType}**."

Do NOT ask "Is that correct?" — proceed directly to the next step. If the user proactively corrects the type, accept the correction **only if it maps to a valid canonical AppType**. If the corrected type is not in the canonical list, explain which types are supported.

### Step 4: No match — unsupported

If no marker files are found, follow the Unsupported Project Types procedure above.

---

## Multi-Component Detection

A workspace may contain **multiple independently deployable components** that target **different Azure services**. For example, a `.NET` API (`*.csproj` in `src/MyApi/`) and an Azure Functions app (`host.json` in `src/MyFunctions/`). The elseif-based detection algorithm above finds the **primary** component — this section handles detecting **secondary** components.

### When to trigger

After Step 2 resolves a primary AppType, scan for additional components **only** when:

1. The primary AppType targets a **different Azure service** than would be produced by another marker in a subfolder (e.g., primary is `.NET` → App Service, and a `host.json` in a subfolder → Azure Functions).
2. The additional markers live in a **separate subdirectory** from the primary project — they are not part of the same build output.

Do NOT report multi-component when:
- The markers are in the **same directory** (e.g., `host.json` + `*.csproj` together = Functions with .NET runtime, which is already handled by the priority rules).
- Both markers target the **same Azure service** (e.g., two `.csproj` files both targeting App Service = multi-project .NET, handled by Check 1b scaffolding validation).

### Secondary component scan

After the primary component is detected, check for these secondary patterns:

| Primary AppType | Secondary Marker | Condition | Secondary Component |
|----------------|-----------------|-----------|-------------------|
| `.NET` / `F#` / `VB.NET` | `host.json` in a subfolder | `host.json` is NOT in the same directory as the primary `*.csproj` | `Functions` |
| `Node.js backend` | `host.json` in a subfolder | `host.json` is NOT alongside the primary `package.json` | `Functions` |
| `Python` | `host.json` in a subfolder | `host.json` is NOT alongside the primary `requirements.txt` | `Functions` |
| `Functions` | `*.csproj` in a subfolder | `*.csproj` is NOT alongside `host.json` (not the Functions runtime project) | `.NET` |
| Any non-Container | `Dockerfile` in a subfolder | `Dockerfile` is NOT at workspace root and targets a different component | `Container` |

### Output format

When secondary components are found, the output changes from a single AppType to a component array:

| Field | Single Component | Multi-Component |
|-------|-----------------|-----------------|
| `AppType` | `".NET"` | `".NET"` *(primary — used for backward compatibility)* |
| `TargetAzureService` | `"App Service"` | `"App Service"` *(primary)* |
| `Components` | *(absent)* | Array of component objects (see below) |

Each component object:

| Field | Example |
|-------|---------|
| `AppType` | `"Functions"` |
| `TargetAzureService` | `"Azure Functions"` |
| `ComponentPath` | `"src/MyFunctions"` *(relative path to the component's root directory)* |

The primary component is **always** `AppType` / `TargetAzureService` at the top level. The `Components` array contains **only secondary components**. Downstream agents that only understand single-component detection continue to work using the top-level `AppType` field.

### Report detected components

When multiple components are detected, **auto-accept and inform** the user without asking for confirmation:

> "Detected **2 deployable components** in your workspace:
> 1. **{PrimaryAppType}** → {PrimaryAzureService} *(primary)*
> 2. **{SecondaryAppType}** in `{ComponentPath}` → {SecondaryAzureService}"

Do NOT ask "Is that correct?" — proceed directly. If the user proactively corrects the layout, accept the correction.

---

## Functions Runtime Detection

When `host.json` is found, determine the Functions runtime language:

| Additional Marker | Functions Runtime |
|-------------------|-------------------|
| `*.csproj` alongside `host.json` | .NET (C#) |
| `package.json` alongside `host.json` | Node.js |
| `requirements.txt` alongside `host.json` | Python |
| `pom.xml` alongside `host.json` | Java |

The Functions runtime affects build template selection (see `deploy-1es-pipeline-authoring` skill) and pool OS selection (see `deploy-build-pool-image` skill).

---

## .NET Family Note

`F#` and `VB.NET` are distinct canonical AppType values for detection purposes, but they use the **same build/deploy pipeline as `.NET`**:

| AppType | Build Template | Pool OS | Deploy Task |
|---------|---------------|---------|-------------|
| `.NET` | `build-dotnet.yml` | `windows` | `AzureWebApp@1` |
| `F#` | `build-dotnet.yml` | `windows` | `AzureWebApp@1` |
| `VB.NET` | `build-dotnet.yml` | `windows` | `AzureWebApp@1` |

Downstream agents (pipeline author, build pool selector) should treat `F#` and `VB.NET` identically to `.NET` when selecting build templates, pool OS, and deploy tasks.

---

## Build Commands (Pipeline Setup)

> **Note**: `.NET` covers C# (`.csproj`), F# (`.fsproj`), and VB.NET (`.vbproj`) — all use the same `dotnet` build pipeline. F# and VB.NET projects require no special handling.

| App Type | Build Stage Tasks |
|----------|------------------|
| .NET | `UseDotNet` → `dotnet restore` → `dotnet build` → `dotnet test` → `dotnet publish` |
| Node.js | `NodeTool` → `npm ci` → `npm run build` → `npm test` → archive output |
| Python | `UsePythonVersion` → `pip install -r requirements.txt` → `pytest` → archive output |
| Java | `JavaToolInstaller` → `mvn package` / `gradle build` → copy artifacts |
| Container | `Docker@2` build using `Dockerfile` |
| Go | `GoTool` → `go build` → `go test` → archive binary |
| Rust | `RustInstaller` → `cargo build --release` → `cargo test` → archive binary |
| Static | Copy static assets (no compile step) |
| Functions | Same as runtime language (.NET/Node/Python/Java) + Functions Packaging (see `deploy-1es-pipeline-authoring` skill — "Functions Packaging" section) |

## Required Files for Push (Code Push)

| App Type | Required Files (must NOT be git-ignored) |
|----------|------------------------------------------|
| .NET | `*.csproj`, `*.sln`, `nuget.config` (if present) |
| Node.js | `package.json`, `package-lock.json` or `yarn.lock` |
| Python | `requirements.txt` or `pyproject.toml` |
| Java | `pom.xml` or `build.gradle`, `gradle.properties` (if present) |
| Container | `Dockerfile`, `.dockerignore` |
| Go | `go.mod`, `go.sum` |
| Rust | `Cargo.toml`, `Cargo.lock` |
| Static | `index.html`, static assets |
| Functions | `host.json`, function code files |
| All (if Bicep) | `infra/main.bicep`, `infra/parameters.dev.bicepparam` |

## Deploy Tasks (Pipeline Setup)

| Target Azure Service | Deploy Task |
|---------------------|-------------|
| App Service | `AzureWebApp@1` |
| Container Apps | `Docker@2` build/push + `az containerapp update` |
| Static Web Apps | `AzureStaticWebApp@0` |
| Functions | `AzureFunctionApp@2` |

## Health Checks (Monitor & Verify)

| Target Service | Health Check Command |
|---------------|---------------------|
| App Service | `Invoke-WebRequest -Uri "https://<app-name>.azurewebsites.net" -UseBasicParsing` |
| Container Apps | `Invoke-WebRequest -Uri "https://<app-fqdn>" -UseBasicParsing` |
| Static Web Apps | `Invoke-WebRequest -Uri "https://<site-hostname>" -UseBasicParsing` |
| Functions | `Invoke-WebRequest -Uri "https://<app-name>.azurewebsites.net/api/health" -UseBasicParsing` |

## Log Retrieval (Monitor & Verify — on failure)

> **Do NOT run these commands directly.** Log retrieval is handled by the **monitor agent** via the deployment pipeline. The agent must never access Azure resources locally.

| Target Service | Pipeline Retrieval Method |
|---------------|-------------------------|
| App Service | Pipeline task: `AzureCLI@2` runs `az webapp log tail` inside the pipeline |
| Container Apps | Pipeline task: `AzureCLI@2` runs `az containerapp logs show` inside the pipeline |
| Functions | Pipeline task: `AzureCLI@2` runs `az functionapp log tail` inside the pipeline |

## Version Check (Readiness Check)

| App Type | Version Check |
|----------|---------------|
| .NET | `dotnet --version` — compare with `TargetFramework` in `*.csproj` |
| Node.js | `node --version` — compare with `engines` in `package.json` |
| Python | `python --version` — compare with `python_requires` in `pyproject.toml` |
| Java | `java --version` + `mvn --version` — compare with `pom.xml` source/target |

## Azure Resource Existence (Readiness Check)

> **Do NOT run these commands directly.** Azure resource existence is verified by **SC existence checks** in Stage 2/3 (using `Test-ServiceConnectionExists`). Infrastructure provisioning is handled out-of-band by the CELA SPEAR team. The agent must never query Azure resource state locally.

---

## Output

After successful detection, pass the following to downstream agents:

| Field | Value |
|-------|-------|
| `AppType` | Canonical value from the Detection table (e.g., `Python`, `.NET`, `Container`) — always the **primary** component |
| `TargetAzureService` | Corresponding Azure service from the Detection table — always the **primary** component |
| `Components` | *(Optional)* Array of secondary component objects when multi-component workspace is detected. Each object has `AppType`, `TargetAzureService`, and `ComponentPath`. Absent when only one component is found. |

## Validation

After detection, verify readiness by checking:

1. The detected app type has a corresponding entry in the Build Commands table above
2. The required files for the detected type (per Required Files table above) exist and are not git-ignored
3. If the app type requires a specific SDK (e.g., .NET, Node.js, Python), the SDK is available on the build agent OS

## Common Mistakes

| Mistake | Correction |
|---------|------------|
| Detecting by directory name (e.g., `python/` folder) | Detect by marker files only |
| Accepting user's claim without verifying files exist | Always verify marker files are present |
| Returning `JavaScript` as AppType | Use `Node.js backend` or `Static frontend` |
| Returning `C#` as AppType | Use `.NET` |
| Returning `React` or `Angular` as AppType | Use `Static frontend` |
| Missing `host.json` check before other markers | Always check for Functions first |
| Stopping at `.csproj` when `host.json` exists in a different subfolder | Scan for secondary components after primary detection (Multi-Component Detection) |

## CGRP Reminder

Before classifying an application type, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to app type detection:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 1 | Ungrounded Assertion | Asserting an AppType without verifying the required marker files exist on disk |
| 7 | Ambiguity | Multiple marker files found (e.g., `host.json` + `Dockerfile`) — apply priority order, don't guess |

If any signal fires: **Stop → Verify → Pivot** before continuing.
