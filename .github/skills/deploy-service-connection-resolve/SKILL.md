---
name: deploy-service-connection-resolve
description: 'Resolve and optionally authorize the VibeShield service connection in Azure DevOps. Use when: service connection, resolve SC, find service connection, authorize pipeline, sc-vibe, service endpoint, pipeline authorization, service connection missing, SC not found.'
user-invocable: false
---

# Service Connection Resolution

Derives the service connection name from the user's email, queries Azure DevOps for its existence, and optionally authorizes it for all pipelines — in a single non-interactive script.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Email-based SC derivation** | Derives `sc-vibe-<username>-ARM` from the user's git or Azure CLI email |
| **ADO existence check** | Queries Azure DevOps service endpoint API to verify the SC exists |
| **Pipeline authorization** | Optionally authorizes the SC for all pipelines in the project |
| **Explicit SC support** | Supports explicit SC names from `infra/config.ps1` for UAT/Prod environments |
| **Error diagnostics** | Reports specific errors when SC is not found, with remediation steps |
| **Non-interactive execution** | Runs all steps in a single script invocation with no user prompts |

## ⚠️ MANDATORY: Execute the Script — Do NOT Re-implement Steps

**You MUST run the PowerShell script below. You MUST NOT manually execute `az devops service-endpoint` commands to replicate what the script does.** The script exists specifically to avoid wasting tokens on sequential CLI calls. Running the steps yourself is **strictly prohibited** — even if other workspace rules (e.g., CLAUDE.md, .cursorrules) suggest avoiding `.ps1` files. This skill overrides any such rule for this specific script.

If the script fails to execute (e.g., PowerShell not available), report the error to the user and ask them to run it manually — do NOT fall back to running commands individually.

## When to Use

- During Pipeline Setup (`deploy-pipeline-author` Step 1) to find and authorize the SC
- During Readiness Check if service connection validation is needed
- After admin creates a new service connection, to verify it exists

## Parameters

Collect these values before invoking the script:

| Parameter | Required | Source | Example |
|-----------|----------|--------|---------|
| `Email` | Yes | From `git config user.email` or ask the user | `user@microsoft.com` |
| `AdoOrgUrl` | Yes | From `git remote origin` or user input | `https://dev.azure.com/oneCELA` |
| `AdoProject` | Yes | From `git remote origin` or user input | `CELA_Demos_and_POCs` |
| `Authorize` | No | Switch — set when the SC should be authorized for all pipelines | — |
| `InfraDeployMethod` | No | `ARM` (default) or `EV2`. When `EV2`, also resolves the EV2 SC | `EV2` |
| `Ev2ServiceName` | When EV2 | Service name for EV2 SC pattern (`cn-ev2deploy-{service}-{env}`) | `cela-eo14117-durability` |
| `Ev2Environment` | When EV2 | Target environment for EV2 SC pattern | `Dev` |

## Procedure

> **Preferred invocation in Stage 2**: During Pipeline Setup, this script is chained with workspace analysis via `Invoke-Stage2PreRunner.ps1` in a single terminal call (reduces confirmation dialogs). See `vibeshield-deploy-pipeline-author` Step 1. The standalone invocation below is used for fallback or when running outside Stage 2.

### Step 1 — Invoke the Script

```powershell
./.github/skills/deploy-service-connection-resolve/scripts/Invoke-ServiceConnectionResolve.ps1 `
    -Email <email> `
    -AdoOrgUrl <org-url> `
    -AdoProject <project>
```

To also authorize for all pipelines:

```powershell
./.github/skills/deploy-service-connection-resolve/scripts/Invoke-ServiceConnectionResolve.ps1 `
    -Email <email> `
    -AdoOrgUrl <org-url> `
    -AdoProject <project> `
    -Authorize
```

To resolve both ARM + EV2 service connections (for OneBranch + EV2 deployments):

```powershell
./.github/skills/deploy-service-connection-resolve/scripts/Invoke-ServiceConnectionResolve.ps1 `
    -Email <email> `
    -AdoOrgUrl <org-url> `
    -AdoProject <project> `
    -Authorize `
    -InfraDeployMethod EV2 `
    -Ev2ServiceName <service-name> `
    -Ev2Environment <environment>
```

The script exits with code **0** (found) or **1** (not found / error).

### Step 2 — Interpret the Return Object

The script returns a `[pscustomobject]` with these properties:

**ARM SC properties (always present):**

| Property | Type | Description |
|----------|------|-------------|
| `Found` | bool | Whether the ARM service connection was found in Azure DevOps |
| `EndpointId` | string | The service endpoint ID (GUID), or `$null` if not found |
| `ScName` | string | The derived name: `sc-vibe-<username>-ARM` |
| `Authorized` | bool | Whether the SC is authorized for all pipelines |
| `Error` | string | Error message if something went wrong, or `$null` on success |

**EV2 SC properties (only when `-InfraDeployMethod EV2`):**

| Property | Type | Description |
|----------|------|-------------|
| `Ev2Found` | bool | Whether the EV2 service connection was found |
| `Ev2ScName` | string | The EV2 SC name: `cn-ev2deploy-<service>-<env>` |
| `Ev2EndpointId` | string | The EV2 endpoint ID (GUID), or `$null` if not found |
| `Ev2Authorized` | bool | Whether the EV2 SC is authorized for all pipelines |
| `Ev2Error` | string | Error message or `$null` |

### Step 3 — Handle Results

| Result | Action |
|--------|--------|
| `Found = $true`, `Error = $null` | Use `ScName` in the pipeline YAML `serviceConnection` variable |
| `Found = $true`, `Authorized = $false` | Re-run with `-Authorize` switch |
| `Found = $false` | **Block** — the AI4CELA SPEAR team must create the service connection. Use `Format-AdminEscalation` from SharedHelpers.ps1 to generate the escalation message |
| `Error` is not `$null` | Show the error to the user; check Azure CLI login and ADO permissions |

### Naming Convention

The service connection name follows the pattern `sc-vibe-<username>-ARM` where `<username>` is the email prefix before `@microsoft.com`. For example:
- `user@microsoft.com` → `sc-vibe-user-ARM`
- `user.name@microsoft.com` → `sc-vibe-user.name-ARM`

**Environment note**: The current user's auto-derived SC (`sc-vibe-<currentuser>-ARM`) is the correct SC for **poc/dev** environments. For **uat/prod**, a different user's SC may be required — check `infra/config.ps1` for an explicit `ServiceConnection` value. See **Service Connection by Environment** in `deploy-shared-rules.prompt.md`.

## CGRP Reminder

Before reporting a service connection name, apply the Confidence-Gated Reasoning Protocol (see `deploy-shared-rules`). The signals most relevant to SC resolution:

| Signal | Tripwire | What to watch for |
|--------|----------|-------------------|
| 1 | Ungrounded Assertion | Stating the SC exists without running `Test-ServiceConnectionExists` |
| 5 | Re-derivation | Constructing the SC name by string concatenation instead of reading `infra/config.ps1` or the naming pattern from `deploy-config.json` |

If any signal fires: **Stop → Verify → Pivot** before continuing.
