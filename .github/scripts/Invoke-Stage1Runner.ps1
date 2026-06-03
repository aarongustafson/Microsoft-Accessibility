#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 1 runner — runs preflight environment checks.

.DESCRIPTION
    Runs Invoke-PreflightChecks.ps1 in a single terminal invocation.

    Build verification has been removed — it is now handled entirely by
    Stage 2 Build Readiness (deploy-build-readiness, BR-00 through BR-07).

    The runner:
      1. Runs preflight environment checks (PF-09 through PF-12)
      2. Returns output for the agent to parse

    Exit code 0 = all checks passed. Exit code 1 = one or more failed.

.PARAMETER Email
    Microsoft email address for naming convention derivation.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL.

.PARAMETER AdoProject
    Azure DevOps project name.

.PARAMETER ProjectResourceGroup
    Resource group for the application deployment.

.PARAMETER AppName
    Azure hosting resource name.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER Environment
    Target environment (dev, poc, etc.).

.PARAMETER SkipBuild
    Skip the build check in preflight.

.PARAMETER SkipSecretScan
    Skip the basic secret scan in preflight.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.EXAMPLE
    ./.github/scripts/Invoke-Stage1Runner.ps1 -Email user@microsoft.com `
        -AdoOrgUrl https://dev.azure.com/org -AdoProject MyProject
#>
[CmdletBinding()]
param(
    [string]$Email,
    [string]$AdoOrgUrl,
    [string]$AdoProject,
    [string]$ProjectResourceGroup,
    [string]$AppName,
    [string]$SubscriptionId,
    [string]$Environment,
    [switch]$SkipBuild,
    [switch]$SkipSecretScan,
    [string]$WorkspacePath = $PWD.Path,
    [string]$SarifPath
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

# Load SharedHelpers for config resolution
$_shPath = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'scripts', 'SharedHelpers.ps1'
if (Test-Path $_shPath) { . $_shPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 1 Runner: Preflight Checks"
Write-Output "================================================================"
Write-Output ""

# ── Preflight Checks ───────────────────────────────
Write-Output "  Running preflight checks..."
$pfScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-preflight-checks', 'scripts', 'Invoke-PreflightChecks.ps1'
if (-not (Test-Path $pfScript)) {
    Write-Error "Preflight checks script not found: $pfScript"
    $global:LASTEXITCODE = 1
    exit 1
}

$pfArgs = @{
    WorkspacePath = $WorkspacePath
}
if ($Email)                { $pfArgs['Email'] = $Email }
if ($AdoOrgUrl)            { $pfArgs['AdoOrgUrl'] = $AdoOrgUrl }
if ($AdoProject)           { $pfArgs['AdoProject'] = $AdoProject }
if ($ProjectResourceGroup) { $pfArgs['ProjectResourceGroup'] = $ProjectResourceGroup }
if ($AppName)              { $pfArgs['AppName'] = $AppName }
if ($SubscriptionId)       { $pfArgs['SubscriptionId'] = $SubscriptionId }
if ($Environment)          { $pfArgs['Environment'] = $Environment }
if ($SkipBuild)            { $pfArgs['SkipBuild'] = $true }
if ($SkipSecretScan)       { $pfArgs['SkipSecretScan'] = $true }
if ($SarifPath)            { $pfArgs['SarifPath'] = $SarifPath }

$global:LASTEXITCODE = 0
$Error.Clear()
try {
    & $pfScript @pfArgs -ErrorAction Stop 2>&1
} catch {
    Write-Output "  ❌ Preflight checks threw an error: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
if ($Error.Count -gt 0) {
    Write-Output "  ❌ Preflight checks encountered errors: $($Error[0].Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
$pfExit = $LASTEXITCODE

if ($pfExit -ne 0) {
    Write-Output ""
    Write-Output "  ❌ Preflight checks failed (exit code $pfExit)"
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Output "  ✅ Preflight checks passed"

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 1 Runner Complete"
Write-Output "================================================================"
Write-Output ""

$global:LASTEXITCODE = 0
exit 0