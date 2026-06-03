#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 3 runner — chains pipeline validation and pipeline push in one terminal call.

.DESCRIPTION
    Chains Invoke-PipelineAuthorValidation.ps1 and Invoke-PipelinePush.ps1
    into a single terminal invocation, reducing VS Code confirmation dialogs.
    Part of the terminal-dialog reduction initiative.

    The runner:
      1. Runs PA-01 through PA-33 validation checks
      2. If all checks pass, proceeds with the pipeline push
      3. Returns combined output for the agent to parse

    Exit code 0 = both scripts succeeded. Exit code 1 = one or more failed.

.PARAMETER AppType
    Detected application type (e.g. .NET, Node.js backend, Python).

.PARAMETER TargetAzureService
    Target Azure service (e.g. AppService, ContainerApps, Functions).

.PARAMETER ServiceConnectionName
    Expected service connection name.

.PARAMETER Email
    Microsoft email address for push operations.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL.

.PARAMETER AdoProject
    Azure DevOps project name.

.PARAMETER RepoName
    Azure DevOps repository name.

.PARAMETER CommitMessage
    Commit message for git push.

.PARAMETER BranchName
    Branch to push to.

.PARAMETER PipelineName
    Name for the ADO pipeline.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER PipelineYmlPath
    Path to the pipeline YAML file.

.PARAMETER ComponentsJson
    Optional JSON array of secondary components for multi-component validation.

.PARAMETER SkipPush
    Skip the actual git push (dry-run mode).

.PARAMETER SkipPipelineRegistration
    Skip pipeline creation/registration.

.PARAMETER UpdateState
    When set, folds the state write into the push script call.

.PARAMETER StateJson
    JSON string for state update. Used with -UpdateState.

.EXAMPLE
    ./.github/scripts/Invoke-Stage3Runner.ps1 -AppType 'Node.js backend' `
        -TargetAzureService 'AppService' -ServiceConnectionName 'sc-vibe-user-ARM' `
        -Email user@microsoft.com -AdoOrgUrl https://dev.azure.com/org -AdoProject MyProject
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppType,
    [Parameter(Mandatory)][string]$TargetAzureService,
    [Parameter(Mandatory)][string]$ServiceConnectionName,
    [string]$Email,
    [string]$AdoOrgUrl,
    [string]$AdoProject,
    [string]$RepoName,
    [string]$CommitMessage,
    [string]$BranchName,
    [string]$PipelineName,
    [string]$WorkspacePath = $PWD.Path,
    [string]$PipelineYmlPath,
    [string]$ComponentsJson,
    [switch]$SkipPush,
    [switch]$SkipPipelineRegistration,
    [switch]$UpdateState,
    [string]$StateJson,
    [string]$SarifPath,
    [string]$SkipChecks,
    [ValidateSet('','author-new','run-existing','resume')][string]$DeploymentIntent = '',
    [ValidateSet('','ARM','EV2')][string]$InfraDeploy = ''
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
if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath }

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 3 Runner: Pipeline Validation + Code Push"
Write-Output "================================================================"
Write-Output ""

# ── Step 1: Pipeline Validation (PA-01 through PA-33) ──────
Write-Output "  [1/2] Validating pipeline YAML..."
$paScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-pipeline-validation', 'scripts', 'Invoke-PipelineAuthorValidation.ps1'
if (-not (Test-Path $paScript)) {
    Write-Error "Pipeline validation script not found: $paScript"
    $global:LASTEXITCODE = 1
    exit 1
}

$paArgs = @{
    AppType               = $AppType
    TargetAzureService    = $TargetAzureService
    ServiceConnectionName = $ServiceConnectionName
    WorkspacePath         = $WorkspacePath
    PipelineYmlPath       = $PipelineYmlPath
}
if ($ComponentsJson) { $paArgs['ComponentsJson'] = $ComponentsJson }
if ($SkipChecks)     { $paArgs['SkipChecks'] = $SkipChecks }

$global:LASTEXITCODE = 0
$Error.Clear()
try {
    & $paScript @paArgs -ErrorAction Stop 2>&1
} catch {
    Write-Output "  ❌ Pipeline validation threw an error: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
if ($Error.Count -gt 0) {
    Write-Output "  ❌ Pipeline validation encountered errors: $($Error[0].Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
$paExit = $LASTEXITCODE

if ($paExit -ne 0) {
    Write-Output ""
    Write-Output "  ❌ Pipeline validation failed (exit code $paExit)"
    Write-Output "  Code push skipped — fix the pipeline issues first."
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Output "  ✅ Pipeline validation passed"
Write-Output ""

# ── Step 2: Pipeline Push ──────────────────────────────────
Write-Output "  [2/2] Pushing code and registering pipeline..."
$ppScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-pipeline-push', 'scripts', 'Invoke-PipelinePush.ps1'
if (-not (Test-Path $ppScript)) {
    Write-Error "Pipeline push script not found: $ppScript"
    $global:LASTEXITCODE = 1
    exit 1
}

$ppArgs = @{
    AppType       = $AppType
    WorkspacePath = $WorkspacePath
}
if ($Email)                    { $ppArgs['Email'] = $Email }
if ($AdoOrgUrl)                { $ppArgs['AdoOrgUrl'] = $AdoOrgUrl }
if ($AdoProject)               { $ppArgs['AdoProject'] = $AdoProject }
if ($RepoName)                 { $ppArgs['RepoName'] = $RepoName }
if ($CommitMessage)            { $ppArgs['CommitMessage'] = $CommitMessage }
if ($BranchName)               { $ppArgs['BranchName'] = $BranchName }
if ($PipelineName)             { $ppArgs['PipelineName'] = $PipelineName }
if ($PipelineYmlPath)          { $ppArgs['PipelineYmlPath'] = $PipelineYmlPath }
if ($SkipPush)                 { $ppArgs['SkipPush'] = $true }
if ($SkipPipelineRegistration) { $ppArgs['SkipPipelineRegistration'] = $true }
if ($UpdateState)              { $ppArgs['UpdateState'] = $true }
if ($StateJson)                { $ppArgs['StateJson'] = $StateJson }
if ($SarifPath)                { $ppArgs['SarifPath'] = $SarifPath }
if ($DeploymentIntent)         { $ppArgs['DeploymentIntent'] = $DeploymentIntent }
if ($InfraDeploy)              { $ppArgs['InfraDeploy'] = $InfraDeploy }

$global:LASTEXITCODE = 0
$Error.Clear()
try {
    & $ppScript @ppArgs -ErrorAction Stop 2>&1
} catch {
    Write-Output "  ❌ Pipeline push threw an error: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
if ($Error.Count -gt 0) {
    Write-Output "  ❌ Pipeline push encountered errors: $($Error[0].Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}
$ppExit = $LASTEXITCODE

if ($ppExit -ne 0) {
    Write-Output ""
    Write-Output "  ❌ Pipeline push failed (exit code $ppExit)"
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Output "  ✅ Pipeline push complete"

Write-Output ""
Write-Output "================================================================"
Write-Output "  Stage 3 Runner Complete"
Write-Output "================================================================"
Write-Output ""

exit 0