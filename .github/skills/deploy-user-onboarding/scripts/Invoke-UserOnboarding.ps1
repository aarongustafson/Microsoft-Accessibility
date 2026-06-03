#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies that all service connections referenced in the pipeline YAML exist in Azure DevOps.

.DESCRIPTION
    Parses the pipeline YAML for service connection references (azureSubscription,
    ConnectedServiceName, variable references) and checks each one exists in the
    ADO project via az devops service-endpoint list.

    Does NOT provision any resources. Does NOT trigger any pipeline.
    Infrastructure provisioning is handled out-of-band by the CELA SPEAR team.

    Exit code 0 = all SCs exist.
    Exit code 1 = one or more SCs missing or error.

.PARAMETER PipelineYmlPath
    Relative path to the pipeline YAML file (from WorkspacePath).

.PARAMETER WorkspacePath
    Root of the workspace. Defaults to current directory.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL. Auto-detected from git remote if omitted.

.PARAMETER AdoProject
    Azure DevOps project name. Auto-detected from git remote if omitted.

.EXAMPLE
    ./.github/skills/deploy-user-onboarding/scripts/Invoke-UserOnboarding.ps1 `
        -PipelineYmlPath '.azdo/pipelines/azure-pipeline.yml'
#>
[CmdletBinding()]
param(
    [string]$PipelineYmlPath,
    [string]$WorkspacePath = $PWD.Path,
    [string]$AdoOrgUrl,
    [string]$AdoProject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load SharedHelpers ──────────────────────────────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..', 'scripts', 'SharedHelpers.ps1'
$sharedHelpersPath = [System.IO.Path]::GetFullPath($sharedHelpersPath)
if (-not (Test-Path $sharedHelpersPath)) {
    Write-Error "SharedHelpers.ps1 not found at $sharedHelpersPath"
    $global:LASTEXITCODE = 1
    exit 1
}
# Idempotency guard: skip re-dot-source if SharedHelpers is already loaded.
# This preserves Pester mocks that the test's BeforeAll sets up.
if (-not (Get-Command Get-PipelineServiceConnections -ErrorAction SilentlyContinue) -or
    -not (Get-Command Test-ServiceConnectionExists -ErrorAction SilentlyContinue) -or
    -not (Get-Command Test-AllPipelineSCsExist -ErrorAction SilentlyContinue)) {
    . $sharedHelpersPath
}
if ($WorkspacePath) { Assert-ScriptIntegrity -WorkspacePath $WorkspacePath }
# ── Resolve parameters ──────────────────────────────────────
if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath -WorkspacePath $WorkspacePath }
$pipelineFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
if (-not (Test-Path $pipelineFullPath)) {
    Write-Error "Pipeline YAML not found: $pipelineFullPath"
    $global:LASTEXITCODE = 1
    exit 1
}

if (-not $AdoOrgUrl -or -not $AdoProject) {
    $ctx = Get-DeployContext -WorkspacePath $WorkspacePath
    if (-not $AdoOrgUrl)  { $AdoOrgUrl  = $ctx.AdoOrgUrl }
    if (-not $AdoProject) { $AdoProject = $ctx.AdoProject }
}

if (-not $AdoOrgUrl -or -not $AdoProject) {
    Write-Error "Could not determine ADO org/project. Pass -AdoOrgUrl and -AdoProject explicitly."
    $global:LASTEXITCODE = 1
    exit 1
}

# ── Extract SC names from pipeline YAML ─────────────────────
Write-Output ""
Write-Output "================================================================"
Write-Output "  Service Connection Verification"
Write-Output "================================================================"
Write-Output ""
Write-Output "  Pipeline: $PipelineYmlPath"
Write-Output "  ADO Org:  $AdoOrgUrl"
Write-Output "  Project:  $AdoProject"
Write-Output ""

$yamlContent = Get-Content $pipelineFullPath -Raw
$scResult = Test-AllPipelineSCsExist -YamlContent $yamlContent -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject

if ($scResult.TotalSCs -eq 0) {
    Write-Output "  No service connections found in pipeline YAML."
    Write-Output ""
    $global:LASTEXITCODE = 0
    exit 0
}

Write-Output "  Found $($scResult.TotalSCs) service connection(s) to verify:"
Write-Output ""

# ── Display results ─────────────────────────────────────────
foreach ($sc in $scResult.FoundSCs) {
    Write-Output "    [PASS] $($sc.Name) (ID: $($sc.EndpointId))"
}
foreach ($sc in $scResult.MissingSCs) {
    Write-Output "    [FAIL] $sc — not found"
}

Write-Output ""

# ── Output result ───────────────────────────────────────────
if ($scResult.AllExist) {
    Write-Output "  All $($scResult.TotalSCs) service connection(s) verified."
    [pscustomobject]@{
        AllExist   = $true
        MissingSCs = @()
        TotalSCs   = $scResult.TotalSCs
    }
    $global:LASTEXITCODE = 0
    exit 0
} else {
    Write-Output "  $($scResult.MissingSCs.Count) service connection(s) missing."
    Write-Output ""
    Write-Output "  Contact the CELA SPEAR team to provision them:"
    Write-Output "    Email: CELAVibeShieldSupport@microsoft.com"
    Write-Output "    Office Hour: https://microsoft.sharepoint.com/teams/CELAEngineeringFundamentals/SitePages/Contact-Us.aspx"
    Write-Output ""
    [pscustomobject]@{
        AllExist   = $false
        MissingSCs = $scResult.MissingSCs
        TotalSCs   = $scResult.TotalSCs
    }
    $global:LASTEXITCODE = 1
    exit 1
}