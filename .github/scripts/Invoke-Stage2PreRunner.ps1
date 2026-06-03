#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 2 pre-runner — resolves service connection and analyzes workspace in one terminal call.

.DESCRIPTION
    Chains Invoke-ServiceConnectionResolve.ps1 and Invoke-WorkspaceAnalysis.ps1
    into a single terminal invocation, reducing VS Code confirmation dialogs.
    Part of the terminal-dialog reduction initiative (Phase 3).

    The runner:
      1. Runs SC resolve (with optional -Authorize)
      2. If SC resolve succeeds, runs workspace analysis
      3. Returns combined JSON output for the agent to parse

    Exit code 0 = both scripts succeeded. Exit code 1 = one or more failed.

.PARAMETER Email
    Microsoft email address for SC derivation.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL.

.PARAMETER AdoProject
    Azure DevOps project name.

.PARAMETER Authorize
    Whether to authorize the SC for the pipeline.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER PipelineYmlPath
    Path to the pipeline YAML for workspace analysis.

.PARAMETER OutputPath
    Output path for the workspace manifest.

.EXAMPLE
    ./.github/scripts/Invoke-Stage2PreRunner.ps1 -Email user@microsoft.com `
        -AdoOrgUrl https://dev.azure.com/org -AdoProject MyProject -Authorize
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AdoOrgUrl', Justification='Interface contract parameter')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AdoProject', Justification='Interface contract parameter')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Authorize', Justification='Interface contract parameter')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$AdoOrgUrl,
    [Parameter(Mandatory)][string]$AdoProject,
    [switch]$Authorize,
    [string]$WorkspacePath = $PWD.Path,
    [string]$SourcePath,
    [string]$PipelineYmlPath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

try {
    $WorkspacePath = (Resolve-Path $WorkspacePath -ErrorAction Stop).Path
} catch {
    Write-Error "Workspace path not found: '$WorkspacePath'. Verify the directory exists."
    $global:LASTEXITCODE = 1
    exit 1
}

# Load SharedHelpers for config resolution
$_shPath = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'scripts', 'SharedHelpers.ps1'
if (Test-Path $_shPath) { . $_shPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath
if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath }

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 2 Pre-Runner: SC Resolve + Workspace Analysis"
Write-Output "================================================================"
Write-Output ""

# ── Step 1: Derive Service Connection Name ──────────────────
# Stage 2 only needs the SC NAME to embed in pipeline YAML.
# Verification and authorization happen in Stage 3 (after onboarding).
Write-Output "  [1/2] Deriving service connection name..."

$ScName = $null
# Priority 1: Read from deploy-state.json (onboarding pipeline output)
$_statePath = Get-StateFilePath -WorkspacePath $WorkspacePath
if (Test-Path $_statePath) {
    try {
        $_state = Get-Content $_statePath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($_state.PSObject.Properties['ServiceConnectionName'] -and $_state.ServiceConnectionName) {
            $ScName = $_state.ServiceConnectionName
        }
    } catch { $null = $_ }
}
# Priority 2: Read from pipeline YAML (existing pipeline — check both 1ES and OneBranch dirs)
if (-not $ScName) {
    $_ymlPaths = @(
        (Join-Path -Path $WorkspacePath -ChildPath '.azdo/pipelines/azure-pipeline.yml'),
        (Join-Path -Path $WorkspacePath -ChildPath '.azdo/pipelines/azure-pipelines.yml')
    )
    # Also scan OneBranch directory
    $_obDir = Join-Path -Path $WorkspacePath -ChildPath '.azure-pipelines'
    if (Test-Path $_obDir) {
        $_ymlPaths += @(Get-ChildItem -Path $_obDir -Filter '*.yml' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    foreach ($_yp in $_ymlPaths) {
        if (Test-Path $_yp) {
            $_ymlContent = Get-Content $_yp -Raw -ErrorAction SilentlyContinue
            if ($_ymlContent -match '(?m)^\s+serviceConnection:\s*([^$\n]+)$') {
                $_scCandidate = $Matches[1].Trim().Trim("'""")
                if ($_scCandidate -match '^sc-vibe-') { $ScName = $_scCandidate }
            }
            break
        }
    }
}
# Priority 3: Read from infra/config.ps1 (explicit SC for uat/prod)
if (-not $ScName) {
    $configPath = if (Get-Command Resolve-ConfigPath -ErrorAction SilentlyContinue) {
        Resolve-ConfigPath -WorkspacePath $WorkspacePath
    } else {
        Join-Path -Path $WorkspacePath -ChildPath 'infra/config.ps1'
    }
    if (Test-Path $configPath) {
        $Config = $null
        try { . $configPath } catch { $null = $_ }
        if ($Config -and $Config.ServiceConnection) {
            $ScName = $Config.ServiceConnection
        }
    }
}
# Priority 4: Derive from email (fallback for poc/dev)
if (-not $ScName) {
    $Username = ($Email -split '@')[0]
    $ScName   = Get-ServiceConnectionName -Username $Username
}

Write-Output "  ✅ Service connection name: $ScName"
Write-Output "     (Verification and authorization deferred to Stage 3)"
Write-Output ""

# ── Step 2: Workspace Analysis ──────────────────────────────
Write-Output "  [2/2] Running workspace analysis..."
$waScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-workspace-analysis', 'scripts', 'Invoke-WorkspaceAnalysis.ps1'
if (-not (Test-Path $waScript)) {
    Write-Error "Workspace analysis script not found: $waScript"
    $global:LASTEXITCODE = 1
    exit 1
}

$waArgs = @{
    WorkspacePath   = $WorkspacePath
    PipelineYmlPath = $PipelineYmlPath
}
if ($SourcePath)  { $waArgs['SourcePath'] = $SourcePath }
if ($OutputPath) { $waArgs['OutputPath'] = $OutputPath }

$global:LASTEXITCODE = 0
$Error.Clear()
try {
    & $waScript @waArgs -ErrorAction Stop 2>&1
} catch {
    Write-Output "  ❌ Workspace analysis threw an error: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
if ($Error.Count -gt 0) {
    Write-Output "  ❌ Workspace analysis encountered errors: $($Error[0].Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
$waExit = $LASTEXITCODE

if ($waExit -ne 0) {
    Write-Output ""
    Write-Output "  ❌ Workspace analysis failed (exit code $waExit)"
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Output "  ✅ Workspace analysis complete"

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 2 Pre-Runner Complete"
Write-Output "================================================================"
Write-Output ""

exit 0