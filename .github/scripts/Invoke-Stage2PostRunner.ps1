#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 2 post-runner — validates pipeline YAML and checks build readiness in one terminal call.

.DESCRIPTION
    Chains Invoke-PipelineAuthorValidation.ps1 and Invoke-BuildReadiness.ps1
    into a single terminal invocation, reducing VS Code confirmation dialogs.
    Part of the terminal-dialog reduction initiative (Phase 3).

    The runner:
      1. Runs pipeline YAML validation (PA checks)
      2. If validation succeeds, runs build readiness checks (BR checks)
      3. Optionally writes deploy state on success (-UpdateState)

    Exit code 0 = both scripts succeeded. Exit code 1 = one or more failed.

.PARAMETER AppType
    Canonical app type for pipeline validation (e.g. '.NET', 'Python').

.PARAMETER TargetAzureService
    Target Azure service (e.g. 'App Service', 'Container Apps').

.PARAMETER ServiceConnectionName
    Service connection name for pipeline validation.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER PipelineYmlPath
    Path to the pipeline YAML file.

.PARAMETER ManifestPath
    Path to the workspace manifest for build readiness.

.PARAMETER ComponentsJson
    JSON string of components for pipeline validation.

.PARAMETER SkipBuild
    Skip local build checks in build readiness.

.PARAMETER SkipTests
    Skip local test checks in build readiness.

.PARAMETER SkipChecks
    Comma-separated check IDs to skip in pipeline validation.

.PARAMETER UpdateState
    Write deploy state after successful completion.

.PARAMETER StateJson
    JSON string of state data to write (requires -UpdateState).

.EXAMPLE
    ./.github/scripts/Invoke-Stage2PostRunner.ps1 `
        -AppType '.NET' -TargetAzureService 'App Service' `
        -ServiceConnectionName 'sc-vibe-user-ARM' `
        -UpdateState -StateJson '{"LastCompletedStage":2}'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppType,
    [Parameter(Mandatory)][string]$TargetAzureService,
    [Parameter(Mandatory)][string]$ServiceConnectionName,
    [string]$WorkspacePath = $PWD.Path,
    [string]$PipelineYmlPath,
    [string]$ManifestPath,
    [string]$ComponentsJson,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [string]$SkipChecks,
    [switch]$UpdateState,
    [string]$StateJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

try {
    $WorkspacePath = (Resolve-Path -Path $WorkspacePath -ErrorAction Stop).Path
} catch {
    Write-Error "Workspace path not found: '$WorkspacePath'. Verify the directory exists."
    $global:LASTEXITCODE = 1
    exit 1
}

# Load shared helpers for Write-DeployState and config resolution
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath
if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath }

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 2 Post-Runner: Pipeline Validation + Build Readiness"
Write-Output "================================================================"
Write-Output ""

# ── Step 1: Pipeline YAML Validation ────────────────────────
Write-Output "  [1/2] Validating pipeline YAML..."
$paScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-pipeline-validation', 'scripts', 'Invoke-PipelineAuthorValidation.ps1'
if (-not (Test-Path $paScript)) {
    Write-Error "Pipeline validation script not found: $paScript"
    $global:LASTEXITCODE = 1
    exit 1
}

$paArgs = @{
    PipelineYmlPath       = $PipelineYmlPath
    AppType               = $AppType
    TargetAzureService    = $TargetAzureService
    ServiceConnectionName = $ServiceConnectionName
    WorkspacePath         = $WorkspacePath
}
if ($ComponentsJson) { $paArgs['ComponentsJson'] = $ComponentsJson }
if ($SkipChecks)     { $paArgs['SkipChecks'] = $SkipChecks }

$global:LASTEXITCODE = 0
try {
    & $paScript @paArgs
} catch {
    Write-Output "  ❌ Pipeline validation threw an error: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
$paExit = $LASTEXITCODE

if ($paExit -ne 0) {
    Write-Output ""
    Write-Output "  ❌ Pipeline validation failed (exit code $paExit)"
    Write-Output "  Build readiness skipped."
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Output ""
Write-Output "  ✅ Pipeline validation passed"
Write-Output ""

# ── Step 1.5: SC Existence Warning (non-blocking) ──────────
# Parse pipeline YAML for SC references and warn if any don't exist in ADO
$pipelineFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
if (Test-Path $pipelineFullPath) {
    Write-Output "  [SC Check] Verifying service connection(s) exist in ADO..."
    $_yamlContent = Get-Content $pipelineFullPath -Raw
    $_scNames = @(Get-PipelineServiceConnections -YamlContent $_yamlContent)
    if ($_scNames.Count -gt 0) {
        # Resolve ADO context for SC query
        $_ctx = Get-DeployContext -WorkspacePath $WorkspacePath
        $_adoOrg = $_ctx.AdoOrgUrl
        $_adoProj = $_ctx.AdoProject
        if ($_adoOrg -and $_adoProj) {
            $_missingSCs = @()
            foreach ($_sc in $_scNames) {
                $_check = Test-ServiceConnectionExists -ScName $_sc -AdoOrgUrl $_adoOrg -AdoProject $_adoProj
                if (-not $_check.Exists) {
                    $_missingSCs += $_sc
                }
            }
            if ($_missingSCs.Count -gt 0) {
                Write-Output ""
                Write-Output "  ⚠️  The following service connection(s) do not exist in Azure DevOps:"
                foreach ($_sc in $_missingSCs) {
                    Write-Output "       - $_sc"
                }
                Write-Output "     The pipeline will fail at runtime unless these are created before Stage 3."
                Write-Output "     Contact the CELA SPEAR team at CELAVibeShieldSupport@microsoft.com to provision them."
                Write-Output ""
            } else {
                Write-Output "  ✅ All $($_scNames.Count) service connection(s) verified in ADO"
                Write-Output ""
            }
        } else {
            Write-Output "  ⚠️  Could not determine ADO org/project — skipping SC existence check"
            Write-Output ""
        }
    } else {
        Write-Output "  ℹ️  No service connections found in pipeline YAML"
        Write-Output ""
    }
}

# ── Step 2: Build Readiness ─────────────────────────────────
Write-Output "  [2/2] Checking build & deploy readiness..."

# ── Auto-generate workspace manifest if missing ────────────
$resolvedManifest = if ($ManifestPath) { $ManifestPath } else { Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'workspace-manifest.json' }
if (-not (Test-Path $resolvedManifest)) {
    Write-Output "    ℹ️  Workspace manifest not found — running workspace analysis..."
    $waScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-workspace-analysis', 'scripts', 'Invoke-WorkspaceAnalysis.ps1'
    if (Test-Path $waScript) {
        $waArgs = @{ WorkspacePath = $WorkspacePath }
        if ($PipelineYmlPath) { $waArgs['PipelineYmlPath'] = $PipelineYmlPath }
        $global:LASTEXITCODE = 0
        try {
            & $waScript @waArgs
        } catch {
            Write-Output "    ❌ Workspace analysis threw an error: $($_.Exception.Message)"
            $global:LASTEXITCODE = 1
            exit 1
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Output "    ❌ Workspace analysis failed (exit code $LASTEXITCODE)"
            $global:LASTEXITCODE = 1
            exit 1
        }
        Write-Output "    ✅ Workspace manifest generated"
    } else {
        Write-Error "Workspace manifest not found at $resolvedManifest and analysis script not available at $waScript."
        $global:LASTEXITCODE = 1
        exit 1
    }
}

$brScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-build-readiness', 'scripts', 'Invoke-BuildReadiness.ps1'
if (-not (Test-Path $brScript)) {
    Write-Error "Build readiness script not found: $brScript"
    $global:LASTEXITCODE = 1
    exit 1
}

$brArgs = @{
    WorkspacePath   = $WorkspacePath
    PipelineYmlPath = $PipelineYmlPath
}
if ($ManifestPath) { $brArgs['ManifestPath'] = $ManifestPath }
if ($SkipBuild)    { $brArgs['SkipBuild'] = $true }
if ($SkipTests)    { $brArgs['SkipTests'] = $true }

$global:LASTEXITCODE = 0
try {
    & $brScript @brArgs
} catch {
    Write-Output "  ❌ Build readiness threw an error: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
$brExit = $LASTEXITCODE

if ($brExit -ne 0) {
    Write-Output ""
    Write-Output "  ❌ Build readiness failed (exit code $brExit)"
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Output ""
Write-Output "  ✅ Build readiness passed"

# ── State write ─────────────────────────────────────────────
if ($UpdateState -and $brExit -eq 0 -and $StateJson) {
    try {
        $stateData = $StateJson | ConvertFrom-Json -AsHashtable
        Write-DeployState -WorkspacePath $WorkspacePath -StateData $stateData
    } catch {
        Write-Warning "State update failed: $_"
    }
}

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 2 Post-Runner Complete"
Write-Output "================================================================"
Write-Output ""

exit 0