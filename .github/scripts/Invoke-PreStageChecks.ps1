#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Consolidated pre-stage startup script — CLI prereqs, state read, validate, and preflight skip decision.

.DESCRIPTION
    Combines all pre-stage checks into a single terminal invocation to reduce
    the number of "Run pwsh command?" dialogs from 3-4 down to 1.

    Performs these steps in order:
    1. Dot-sources SharedHelpers.ps1
    2. Runs Test-CliPrerequisites (az, git installed and configured)
    3. Reads deploy-state.json via Invoke-StateFileManager.ps1 -Action Read
    4. If state found, validates via Invoke-StateFileManager.ps1 -Action Validate
    5. Runs Get-PreflightSkipDecision based on read result
    6. If validation shows invalid state, deletes via Invoke-StateFileManager.ps1 -Action Delete

    Outputs a single JSON object with all results for the agent to parse.

.PARAMETER WorkspacePath
    Path to the workspace root. Defaults to current directory.

.EXAMPLE
    ./.github/scripts/Invoke-PreStageChecks.ps1 -WorkspacePath .
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = $PWD.Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Resolve paths ───────────────────────────────────────────
$scriptRoot = $PSScriptRoot
$sharedHelpersPath = Join-Path -Path $scriptRoot -ChildPath 'SharedHelpers.ps1'
$stateManagerPath = Join-Path -Path $scriptRoot -ChildPath '..' -AdditionalChildPath 'skills', 'deploy-state-management', 'scripts', 'Invoke-StateFileManager.ps1'
$stateManagerPath = [System.IO.Path]::GetFullPath($stateManagerPath)

# ── Step 1: Load SharedHelpers ──────────────────────────────
if (-not (Test-Path $sharedHelpersPath)) {
    Write-Error "SharedHelpers.ps1 not found at $sharedHelpersPath"
    $global:LASTEXITCODE = 1
    exit 1
}
. $sharedHelpersPath
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath
# ── Step 2: CLI Prerequisites ──────────────────────────────
Write-Host '=== Pre-Stage: CLI Prerequisites ===' -ForegroundColor Cyan
$cliCheck = Test-CliPrerequisites

if (-not $cliCheck.Valid) {
    # CLI prereqs failed — output result and stop
    $result = [pscustomobject]@{
        CliCheck          = $cliCheck
        ReadResult        = $null
        Validation        = $null
        SkipDecision      = $null
        Action            = 'cli-failed'
        Message           = 'CLI prerequisites not met — fix issues before proceeding'
    }
    Write-Host ''
    Write-Host '=== Pre-Stage Result ===' -ForegroundColor Cyan
    $result | ConvertTo-Json -Depth 5
    $global:LASTEXITCODE = 1
    exit 1
}
Write-Host '  CLI prerequisites: OK' -ForegroundColor Green

# ── Step 3: Read State File ─────────────────────────────────
Write-Host ''
Write-Host '=== Pre-Stage: State File Read ===' -ForegroundColor Cyan
$global:LASTEXITCODE = 0
$readResult = & $stateManagerPath -Action Read -WorkspacePath $WorkspacePath

if ($readResult.Found) {
    Write-Host "  State found: $($readResult.Message)" -ForegroundColor Yellow
} else {
    Write-Host "  $($readResult.Message)" -ForegroundColor Green
}

# ── Step 4: Validate (if state found) ──────────────────────
$validation = $null
if ($readResult.Found) {
    Write-Host ''
    Write-Host '=== Pre-Stage: State Validation ===' -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    $validation = & $stateManagerPath -Action Validate -WorkspacePath $WorkspacePath

    if ($validation.Valid) {
        Write-Host '  State is valid' -ForegroundColor Green
    } else {
        Write-Host "  Validation issues: $($validation.Issues -join '; ')" -ForegroundColor Yellow
        Write-Host "  Recommendation: $($validation.Recommendation)" -ForegroundColor Yellow
    }
}

# ── Step 5: Preflight Skip Decision ────────────────────────
Write-Host ''
Write-Host '=== Pre-Stage: Preflight Skip Decision ===' -ForegroundColor Cyan
$skipDecision = Get-PreflightSkipDecision -ReadResult $readResult

Write-Host "  Skip preflight: $($skipDecision.Skip) — $($skipDecision.Reason)" -ForegroundColor $(if ($skipDecision.Skip) { 'Yellow' } else { 'Green' })

# ── Step 6: Auto-delete invalid state ──────────────────────
$action = 'proceed'
if ($readResult.Found -and $validation -and -not $validation.Valid) {
    $criticalPatterns = 'Missing required|no longer exists|App type changed'
    $hasCritical = $validation.Issues | Where-Object { $_ -match $criticalPatterns }
    if ($hasCritical) {
        Write-Host ''
        Write-Host '  Deleting invalid state file...' -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        $null = & $stateManagerPath -Action Delete -WorkspacePath $WorkspacePath
        $action = 'deleted-state'
    } elseif ($validation.Stale) {
        $action = 'stale'
    }
}

if (-not $readResult.Found) {
    $action = 'fresh'
}

# ── Step 7: Greeting Tier Classification ───────────────────
Write-Host ''
Write-Host '=== Pre-Stage: Greeting Tier ===' -ForegroundColor Cyan

$greetingTier = 'FIRST-EVER'
$greetingContext = @{ LastCompletedStage = 0; StageName = 'none' }

if ($readResult.Found -and $readResult.State) {
    $state = $readResult.State
    $hasFirst = $state.PSObject.Properties['FirstInteractionUtc'] -and $state.FirstInteractionUtc
    $hasLast  = $state.PSObject.Properties['LastGreetingUtc'] -and $state.LastGreetingUtc

    if ($hasFirst) {
        if ($hasLast) {
            $hoursSince = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.LastGreetingUtc)).TotalHours
            if ($hoursSince -lt 24) {
                $greetingTier = 'SAME-DAY'
            } else {
                $greetingTier = 'DAILY-RETURN'
            }
        } else {
            $greetingTier = 'DAILY-RETURN'
        }

        # Build context from state
        $lastStage = 0
        $stageName = 'none'
        if ($state.PSObject.Properties['LastCompletedStage']) {
            $lastStage = [int]$state.LastCompletedStage
            $stageName = switch ($lastStage) {
                1 { 'Readiness Check' }
                2 { 'Pipeline Setup' }
                3 { 'Code Push' }
                4 { 'Monitor & Verify' }
                default { 'none' }
            }
        }
        $greetingContext = @{
            LastCompletedStage = $lastStage
            StageName          = $stageName
        }
        if ($state.PSObject.Properties['PipelineYamlPath'] -and $state.PipelineYamlPath) {
            $greetingContext['PipelineYamlPath'] = $state.PipelineYamlPath
        }
        if ($state.PSObject.Properties['BranchName'] -and $state.BranchName) {
            $greetingContext['BranchName'] = $state.BranchName
        }
    }
}

Write-Host "  Tier: $greetingTier" -ForegroundColor $(switch ($greetingTier) {
    'FIRST-EVER'   { 'Green' }
    'DAILY-RETURN'  { 'Yellow' }
    'SAME-DAY'      { 'Cyan' }
})

# ── Step 8: Project Config Check ───────────────────────────
Write-Host ''
Write-Host '=== Pre-Stage: Project Config ===' -ForegroundColor Cyan

$projectConfig = Get-ProjectConfig -WorkspacePath $WorkspacePath
$hasProjectConfig = $null -ne $projectConfig
$projectType = $null

if ($hasProjectConfig) {
    $projectType = if ($projectConfig.PSObject.Properties['projectType']) { $projectConfig.projectType } else { $null }
    if ($projectType) {
        Write-Host "  Project config found: projectType=$projectType" -ForegroundColor Green
    } else {
        Write-Host "  Project config exists but projectType is not set" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No project-config.json found — orchestrator must create one" -ForegroundColor Yellow
}

# ── Step 9: Pipeline Discovery ──────────────────────────────
Write-Host ''
Write-Host '=== Pre-Stage: Pipeline Discovery ===' -ForegroundColor Cyan

$existingPipelines = @()
if (Get-Command Get-ExistingPipelines -ErrorAction SilentlyContinue) {
    $existingPipelines = @(Get-ExistingPipelines -WorkspacePath $WorkspacePath)
    if ($existingPipelines.Count -gt 0) {
        Write-Host "  Found $($existingPipelines.Count) existing pipeline(s):" -ForegroundColor Green
        foreach ($ep in $existingPipelines) {
            $epStatus = if ($ep.LastRunStatus) { $ep.LastRunStatus } else { 'Unknown' }
            Write-Host "    - $($ep.Name) (ID: $($ep.Id), Status: $epStatus)" -ForegroundColor Green
        }
    } else {
        Write-Host "  No existing pipelines found — new pipeline will be authored" -ForegroundColor Yellow
    }
}

# ── Final Output ────────────────────────────────────────────
$result = [pscustomobject]@{
    CliCheck          = $cliCheck
    ReadResult        = $readResult
    Validation        = $validation
    SkipDecision      = $skipDecision
    GreetingTier      = $greetingTier
    GreetingContext   = $greetingContext
    ProjectConfig     = [pscustomobject]@{
        Found         = $hasProjectConfig
        ProjectType   = $projectType
        NeedsCreation = (-not $hasProjectConfig)
    }
    ExistingPipelines = $existingPipelines
    Action            = $action
    Message           = switch ($action) {
        'fresh'         { 'No state file — fresh deployment, start at Stage 1' }
        'deleted-state' { 'State file was invalid — deleted, starting fresh at Stage 1' }
        'stale'         { "State file is stale — $($validation.Recommendation)" }
        'proceed'       { "Resuming from Stage $($readResult.NextStage) ($($readResult.StageName) completed)" }
        default         { 'Ready to proceed' }
    }
}

Write-Host ''
Write-Host '=== Pre-Stage Result ===' -ForegroundColor Cyan
$result | ConvertTo-Json -Depth 5
exit 0