---
name: deploy-strip-submodules
description: 'Prevent git submodules from being fetched during pipeline execution via SDL-level suppression. Use when: submodule error, .gitmodules, git submodule, strip submodules, remove submodules, submodule fetch failure, pipeline submodule, checkout submodules.'
---

# Submodule Suppression (SDL-Level)

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **SDL-level suppression** | Configures `sdl.git.submodules: false` and `sdl.checkout.submodules: false` in pipeline YAML |
| **Source analysis pool** | Sets `sdl.sourceAnalysisPool` to prevent submodule fetch during security scanning |
| **Checkout-level suppression** | Ensures `checkout: self` uses `submodules: false` in all pipeline stages |
| **Failure diagnosis** | Identifies submodule-related pipeline failures and applies the correct fix |

## When to Use

- Generating or validating pipeline YAML that may reference a repo with `.gitmodules`
- Diagnosing pipeline failures caused by submodule fetch errors (e.g., repo not found, access denied on a submodule URL)
- Ensuring submodule repos listed in `.gitmodules` are never checked out or resolved during CI/CD

## Problem

Repositories may contain a `.gitmodules` file referencing external repos (e.g., shared agent definitions, prompt libraries). When Azure DevOps pipelines run `checkout: self`, the agent can attempt to initialize and fetch these submodules. This causes:

- **Auth failures** — the pipeline's service connection may lack access to the submodule repos
- **Slow builds** — large submodule trees are cloned unnecessarily
- **Compliance issues** — external code pulled into the build may not pass SDL scans

## Solution

Submodule suppression is handled at **two levels** — both are required:

### 1. SDL-level suppression (pipeline-wide)

The `sdl` section of the 1ES template MUST include submodule suppression. This prevents the 1ES template infrastructure from processing submodules across all stages:

```yaml
extends:
  template: v1/1ES.Unofficial.PipelineTemplate.yml@1ESPipelineTemplates
  parameters:
    sdl:
      git:
        submodules: false
      checkout:
        submodules: false
```

- `sdl.git.submodules: false` — Prevents 1ES SDL from processing submodule repos
- `sdl.checkout.submodules: false` — Prevents the 1ES template from initializing submodules
- These SDL-level settings **replace the need for strip submodules scripts in individual stages**

### 2. Checkout-level suppression (per-step)

Every `checkout: self` step MUST also set `submodules: false` as a defense-in-depth measure:

```yaml
- checkout: self
  submodules: false
  persistCredentials: true
  fetchDepth: 1
```

> **Important**: Per-stage `git config --remove-section` strip scripts are **NOT needed** and should NOT be added. The SDL-level settings handle submodule suppression globally.

## Pipeline Resources

The `resources.repositories` section MUST contain **only** the `1ESPipelineTemplates` repository. Repos from `.gitmodules` must NEVER be added as pipeline repository resources:

```yaml
resources:
  repositories:
    - repository: 1ESPipelineTemplates
      type: git
      name: 1ESPipelineTemplates/1ESPipelineTemplates
      ref: refs/tags/release
    # Do NOT add submodule repos here
```

## Validation

| # | Check | Pass Criteria |
|---|-------|---------------|
| 1 | SDL `git.submodules` is `false` | `sdl.git.submodules: false` is present in the 1ES template parameters |
| 2 | SDL `checkout.submodules` is `false` | `sdl.checkout.submodules: false` is present in the 1ES template parameters |
| 3 | Every `checkout: self` has `submodules: false` | The `submodules` property is explicitly set to `false` on every checkout step |
| 4 | `resources.repositories` is clean | Only `1ESPipelineTemplates` is listed — no submodule repos |
| 5 | No strip submodules scripts exist | No `git config -f .gitmodules --remove-section` steps in the pipeline (legacy approach — remove if found) |

## Failure Diagnosis

| Symptom | Cause | Fix |
|---------|-------|-----|
| `fatal: No url found for submodule path '...'` | Submodule init attempted during checkout | Verify `sdl.git.submodules: false` and `checkout: self` has `submodules: false` |
| `remote: Repository not found` on submodule URL | Pipeline tried to fetch a submodule repo it lacks access to | Verify `sdl.checkout.submodules: false` is set |
| Pipeline hangs during checkout | Large submodule tree being cloned | Both SDL settings + `submodules: false` on checkout step |
| CredScan flags submodule `.git` files | Submodule metadata checked out | Both SDL settings + `submodules: false` on checkout step |

## Migration from Legacy Approach

If a pipeline contains per-stage strip submodules scripts (e.g., `git config -f .gitmodules --remove-section`), remove them and ensure the SDL-level settings are in place instead. The SDL approach is simpler, less error-prone, and applies globally without needing to update every stage.
