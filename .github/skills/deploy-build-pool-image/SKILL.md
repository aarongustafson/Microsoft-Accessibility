---
name: deploy-build-pool-image
description: 'Select the correct agent pool configuration for a given app type and pipeline framework. Use when: choosing agent pool image, selecting pool OS, determining build pool, 1ES-BuildPool image, OneBranch pool type, windows vs linux, agent pool for .NET, agent pool for Python, pool configuration.'
---

# Build Pool Image Selection

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **App-type-to-pool mapping** | Maps each app type to its correct agent pool OS and image |
| **1ES pool configuration** | Generates `1ES-BuildPool` parameters for 1ES pipelines |
| **OneBranch pool configuration** | Generates `ob_pool_type` and image references for OneBranch pipelines |
| **Windows vs Linux selection** | All app types currently route to Windows pools (`os: windows`). Linux pool support is planned but not yet available. |
| **Custom image support** | Supports custom pool images for specialized build environments |

## When to Use

- Selecting the pool configuration when generating or validating pipeline YAML
- Determining the correct build environment for a detected app type
- Fixing an incorrect agent pool in an existing pipeline
- Verifying that the pipeline uses a supported pool configuration

## Framework-Aware Pool Selection

Pool configuration depends on the pipeline framework:

### 1ES Framework

| Context | Pool Config |
|---------|-------------|
| Build stages | `pool: { name: 1ES-BuildPool, os: windows }` |
| SDL analysis | `sourceAnalysisPool: { name: 1ES-BuildPool, os: windows }` |
| Deploy stages | Same as Build (inherited from skeleton) |

### OneBranch Framework

| Context | Pool Config |
|---------|-------------|
| Build stages | `pool: { type: windows }` |
| Provision/Deploy stages (app code) | `pool: { type: windows }` |
| EV2 rollout stages | `pool: { type: release }` |

## Hard Constraints (1ES)

- All app types MUST use pool name `1ES-BuildPool` with `os: windows`
- The `sourceAnalysisPool` (SDL) MUST always use `name: 1ES-BuildPool` with `os: windows`
- No `image`, `demands`, or `vmImage` fields
- Do NOT use `1ES-BuildPool-Ubuntu` — the Linux build image is not yet ready

## Hard Constraints (OneBranch)

- All build/app-deploy stages MUST use `pool: { type: windows }`
- EV2 deploy stages MUST use `pool: { type: release }`
- No `name`, `os`, `image`, `demands`, or `vmImage` fields — OneBranch uses `type` only
- Do NOT mix 1ES-style `name`/`os` with OneBranch-style `type` in the same pipeline

## Pool YAML Patterns

### 1ES

```yaml
pool:
  name: 1ES-BuildPool
  os: windows
```

This block appears under `extends.parameters.pool` in the 1ES pipeline skeleton.

### OneBranch (Build)

```yaml
pool:
  type: windows
```

This block appears at the job level inside each OneBranch stage.

### OneBranch (EV2 Deploy)

```yaml
pool:
  type: release
```

Used only for EV2 rollout stages (`Ev2RARollout@2`).

## Image Selection — Config-Driven

Pool OS is resolved at runtime from `deploy-config.json` via `Get-BuildPoolOs -AppType <type> -Framework <framework>` (SharedHelpers.ps1):

1. **Per-app-type override** — `pipelineFrameworks.<framework>.poolOverrides.<AppType>` (if present)
2. **Framework default** — `pipelineFrameworks.<framework>.pool.os` (1ES) or `.pool.build.type` (OneBranch)

Currently all app types resolve to `windows` (no overrides configured). When the Linux image becomes available, add overrides to `deploy-config.json`:

```json
"poolOverrides": {
  "Python": "linux",
  "Node.js": "linux"
}
```

Do NOT hardcode OS mappings in skill files or pipeline authoring skills — always call `Get-BuildPoolOs`.

## Decision Logic

1. Determine the pipeline framework (`1ES` or `OneBranch`) from `Get-PipelineFramework`
2. All app types → `windows` for build stages
3. **1ES**: `name: 1ES-BuildPool` with `os: windows`
4. **OneBranch Build**: `type: windows`
5. **OneBranch EV2 Deploy**: `type: release`

## Validation Rules

### 1ES Pipelines

1. `pool.name` equals `1ES-BuildPool` and `pool.os` equals `windows`.
2. No `pool.image` field exists — if present, remove it.
3. No `demands` section exists under the pool — if present, remove it entirely.
4. If `1ES-BuildPool-Ubuntu` is used, replace with `1ES-BuildPool` and add `os: windows`.
5. No `pool.type` field — `type` is OneBranch-only.

### OneBranch Pipelines

1. Build/app-deploy jobs: `pool.type` equals `windows`.
2. EV2 deploy jobs: `pool.type` equals `release`.
3. No `pool.name`, `pool.os`, `pool.image`, or `demands` fields — these are 1ES-only.
4. If `1ES-BuildPool` appears anywhere, replace with `type: windows`.

## Common Mistakes

| Mistake | Framework | Correction |
|---------|-----------|------------|
| Using `pool.image` instead of `pool.os` | 1ES | Remove `image`, use `os: windows` |
| Using `ubuntu-latest` as the OS value | 1ES | Replace with `name: 1ES-BuildPool` and `os: windows` |
| Using `windows-latest` as the OS value | 1ES | Replace with `name: 1ES-BuildPool` and `os: windows` |
| Using `Azure Pipelines` as pool name | 1ES | Replace with `1ES-BuildPool` and `os: windows` |
| Using `1ES-BuildPool-Ubuntu` | 1ES | Replace with `name: 1ES-BuildPool` and `os: windows` |
| Using `1ES-BuildPool` with `os: linux` | 1ES | Replace with `os: windows` |
| Adding `vmImage` under pool | Both | Remove it — governed pools do not use `vmImage` |
| Adding `demands` to select an image | Both | Remove `demands` entirely |
| Using `name: 1ES-BuildPool` in OneBranch | OneBranch | Replace with `type: windows` |
| Using `type: windows` in 1ES | 1ES | Replace with `name: 1ES-BuildPool, os: windows` |
| Using `type: windows` for EV2 deploy | OneBranch | Replace with `type: release` |
