#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    VibeShield-Deploy pipeline monitor — polls a running Azure DevOps pipeline,
    performs health checks, verifies deployed version, retries on failure.

.DESCRIPTION
    Monitors an Azure DevOps pipeline run end-to-end: polls build and deploy
    stages until completion, performs an HTTP health check on the deployed app,
    verifies the deployed commit matches the local HEAD, and classifies any
    failures. On failure it will re-trigger the pipeline (up to 3 total
    attempts) with automatic diagnosis between retries. If all retries are
    exhausted an escalation summary is produced.

    Results are written to a SARIF file for machine-readable consumption.
    Exit code 0 = all checks passed. Exit code 1 = one or more checks failed.

.PARAMETER RunId
    Pipeline run ID to monitor. If omitted, auto-detected from the latest run
    of the named pipeline.

.PARAMETER PipelineName
    Azure DevOps pipeline name. Defaults to 'VibeShield-Deploy-<RepoName>'.

.PARAMETER BranchName
    Branch associated with the pipeline run. Used for re-triggers.
    Defaults to the current git branch.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL (e.g. https://dev.azure.com/myorg).

.PARAMETER AdoProject
    Azure DevOps project name.

.PARAMETER RepoName
    Repository name. If omitted, detected from the workspace folder.

.PARAMETER AppUrl
    URL of the deployed application for health checks.
    If omitted, the health check is skipped with a WARN.

.PARAMETER TargetService
    Azure service type for log retrieval: AppService, ContainerApps, Functions,
    StaticWebApps. If provided, app logs can be retrieved on failure.

.PARAMETER AppName
    Name of the Azure resource (app/function/container app) for log retrieval.

.PARAMETER ResourceGroup
    Resource group of the Azure resource for log retrieval.

.PARAMETER PollIntervalSec
    Seconds between status polls. Defaults to 30.

.PARAMETER TimeoutMinutes
    Maximum minutes to wait for each pipeline run. Defaults to 60.

.PARAMETER MaxRetries
    Maximum number of retry attempts on failure. Defaults to 3.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER SarifPath
    Output path for the SARIF results file.
    Defaults to .vibeshield/results/deploy-monitor-results.sarif in the workspace.

.PARAMETER SkipHealthCheck
    Skip the HTTP health check after a successful pipeline run.

.PARAMETER SkipVersionCheck
    Skip the source version verification against local HEAD.

.EXAMPLE
    ./.github/skills/deploy-monitor/scripts/Invoke-DeployMonitor.ps1 `
        -RunId 12345 `
        -PipelineName 'VibeShield-Deploy-MyApp' `
        -BranchName 'feature/deploy' `
        -AdoOrgUrl https://dev.azure.com/oneCELA `
        -AdoProject CELA_Demos_and_POCs `
        -AppUrl 'https://myapp.azurewebsites.net'

.EXAMPLE
    # Auto-detect everything from git context, skip health check
    ./.github/skills/deploy-monitor/scripts/Invoke-DeployMonitor.ps1 `
        -AdoOrgUrl https://dev.azure.com/oneCELA `
        -AdoProject CELA_Demos_and_POCs `
        -SkipHealthCheck
#>
[CmdletBinding()]
param(
    [string]$RunId,
    [string]$PipelineName,
    [string]$BranchName,
    [string]$AdoOrgUrl,
    [string]$AdoProject,
    [string]$RepoName,
    [string]$AppUrl,
    [string]$TargetService,
    [string]$AppName,
    [string]$ResourceGroup,
    [ValidateSet('','ARM','EV2')][string]$InfraDeploy = '',
    [int]$PollIntervalSec,
    [int]$ReportIntervalSec,
    [int]$TimeoutMinutes,
    [int]$TotalTimeoutMinutes,
    [int]$MaxRetries,
    [string]$WorkspacePath = $PWD.Path,
    [string]$SarifPath,
    [switch]$SkipHealthCheck,
    [switch]$SkipVersionCheck,
    [switch]$UpdateState,
    [string]$StateJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load testable functions ─────────────────────────────────
. (Join-Path -Path $PSScriptRoot -ChildPath 'DeployMonitor.Functions.ps1')
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

# ── Input parameter validation ──────────────────────────────
if ($BranchName) {
    $pf = Test-ParameterFormat -BranchName $BranchName
    if (-not $pf.Valid) {
        Write-Warning "Parameter validation: $($pf.Issues -join '; ')"
    }
}

# ── Read monitor defaults from deploy-config.json ───────────
try {
    $_cfg = Get-DeployConfig
} catch {
    Write-Warning "Could not load deploy-config.json: $($_.Exception.Message). Using built-in defaults."
    $_cfg = [pscustomobject]@{ monitor = [pscustomobject]@{ pollIntervalSec = 30; reportIntervalSec = 60; timeoutMinutes = 60; totalTimeoutMinutes = 90; maxRetries = 3 } }
}
if (-not $PollIntervalSec)     { $PollIntervalSec     = $_cfg.monitor.pollIntervalSec }
if (-not $ReportIntervalSec)   { $ReportIntervalSec   = $_cfg.monitor.reportIntervalSec }
if (-not $TimeoutMinutes)      { $TimeoutMinutes       = $_cfg.monitor.timeoutMinutes }
if (-not $TotalTimeoutMinutes) { $TotalTimeoutMinutes  = $_cfg.monitor.totalTimeoutMinutes }
if (-not $MaxRetries)          { $MaxRetries            = $_cfg.monitor.maxRetries }

# ── InfraDeploy-aware timeout scaling (Gap C) ──────────────
# EV2 rollouts are slower than ARM deployments — scale timeout accordingly
if ($InfraDeploy -eq 'EV2' -and $TimeoutMinutes -le 60) {
    $TimeoutMinutes = 90
    Write-Output "  InfraDeploy=EV2 — timeout scaled to ${TimeoutMinutes} min (EV2 rollouts take longer)"
}

# ── InfraDeploy auto-detection from pipeline YAML ──────────
if (-not $InfraDeploy) {
    $stateFilePath = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield' 'deploy-state.json'
    if (Test-Path $stateFilePath) {
        try {
            $stateData = Get-Content $stateFilePath -Raw | ConvertFrom-Json
            if ($stateData.PSObject.Properties['PipelineYamlPath']) {
                $ymlFull = Join-Path -Path $WorkspacePath -ChildPath $stateData.PipelineYamlPath
                if (Test-Path $ymlFull) {
                    $ymlContent = Get-Content $ymlFull -Raw
                    if ($ymlContent -match 'Ev2RARollout@2|Ev2Rollout|ob_ev2|ServiceGroupRoot') {
                        $InfraDeploy = 'EV2'
                        Write-Output "  Auto-detected InfraDeploy=EV2 from pipeline YAML"
                    } else {
                        $InfraDeploy = 'ARM'
                    }
                }
            }
        } catch { $null = $_ }
    }
}

# ── Auto-detect defaults ───────────────────────────────────
try {
    $WorkspacePath = (Resolve-Path -Path $WorkspacePath -ErrorAction Stop).Path
} catch {
    Write-Error "Workspace path not found: '$WorkspacePath'. Verify the directory exists."
    $global:LASTEXITCODE = 1
    exit 1
}

# ── Resolve parameters via Get-DeployContext ────────────────
$overrides = @{}
if ($AppName)       { $overrides['AppName']       = $AppName }
if ($ResourceGroup) { $overrides['ResourceGroup'] = $ResourceGroup }
if ($AdoOrgUrl)     { $overrides['AdoOrgUrl']     = $AdoOrgUrl }
if ($AdoProject)    { $overrides['AdoProject']    = $AdoProject }
if ($RepoName)      { $overrides['RepoName']      = $RepoName }

try {
    $deployCtx = Get-DeployContext -WorkspacePath $WorkspacePath -Overrides $overrides
} catch {
    Write-Error "Failed to resolve deployment context: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}

$AppName       = $deployCtx.AppName
$ResourceGroup = $deployCtx.ResourceGroup
$AdoOrgUrl     = $deployCtx.AdoOrgUrl
$AdoProject    = $deployCtx.AdoProject
$RepoName      = $deployCtx.RepoName

# ── Resolve Subscription ID for portal links ────────────────
$script:SubscriptionId = ''
try {
    $infraConfigPath = Resolve-ConfigPath -WorkspacePath $WorkspacePath
    if (Test-Path $infraConfigPath) {
        $configContent = Get-Content $infraConfigPath -Raw
        if ($configContent -match '\$SubscriptionId\s*=\s*[''"]([^''"]+)[''"]') {
            $script:SubscriptionId = $Matches[1]
        }
    }
    if (-not $script:SubscriptionId -and $_cfg.tenants) {
        # Fallback: use corp tenant default subscription
        $corpTenant = $_cfg.tenants.corp
        if ($corpTenant -and $corpTenant.subscriptions -and $corpTenant.subscriptions.default) {
            $script:SubscriptionId = $corpTenant.subscriptions.default
        }
    }
} catch { $null = $_ }

if (-not $PipelineName) {
    $PipelineName = "VibeShield-Deploy-$RepoName"
}
if (-not $BranchName) {
    $brResult = Invoke-GitCommand 'rev-parse', '--abbrev-ref', 'HEAD'
    $BranchName = if ($brResult.ExitCode -eq 0 -and $brResult.Output) { $brResult.Output.Trim() } else { 'main' }
}

# ── Capture original branch for retries (immutable once resolved) ──
$script:OriginalBranchName = $BranchName

# ── Auto-detect RunId from latest pipeline run if not provided ──
if (-not $RunId) {
    # Resolve pipeline name to numeric ID first (--pipeline-ids requires numeric ID)
    $pipelineDefId = $null
    $pipelineListResult = Invoke-AzCommand 'pipelines', 'list', `
        '--name', $PipelineName, '--org', $AdoOrgUrl, '--project', $AdoProject, `
        '--query', '[0].id', '-o', 'tsv'
    if ($pipelineListResult.ExitCode -eq 0 -and $pipelineListResult.Output -match '^\d+$') {
        $pipelineDefId = $pipelineListResult.Output.Trim()
    }

    if (-not $pipelineDefId) {
        Write-Error "Could not resolve pipeline '$PipelineName' to a definition ID. Please provide -RunId."
        $global:LASTEXITCODE = 1
        exit 1
    }

    $listResult = Invoke-AzCommand 'pipelines', 'runs', 'list', `
        '--pipeline-ids', $pipelineDefId, '--branch', "refs/heads/$BranchName", `
        '--top', '1', '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json'
    if ($listResult.ExitCode -eq 0 -and $listResult.Output) {
        try {
            $runs = @($listResult.Output | ConvertFrom-Json)
            if ($runs -and $runs.Count -gt 0) {
                $RunId = "$($runs[0].id)"
            }
        } catch { <# Intentionally suppressed — best-effort JSON parsing for run auto-detection #> $null = $_ }
    }
    if (-not $RunId) {
        Write-Error "Could not auto-detect pipeline run ID. Please provide -RunId."
        $global:LASTEXITCODE = 1
        exit 1
    }
    Write-Output "Auto-detected pipeline run ID: $RunId"
}

# ── Stale-run guard: if the resolved RunId is already completed, look for a newer in-progress run ──
$staleCheckResult = Invoke-AzCommand 'pipelines' 'runs' 'show' `
    '--id' $RunId '--org' $AdoOrgUrl '--project' $AdoProject '-o' 'json' `
    -TimeoutSeconds 60
if ($staleCheckResult.ExitCode -eq 0 -and $staleCheckResult.Output) {
    try {
        $staleRun = $staleCheckResult.Output | ConvertFrom-Json
        $staleState = ($staleRun.status ?? '').ToLower()
        if ($staleState -eq 'completed') {
            Write-Output "  ⚠️  Run $RunId is already completed (result: $($staleRun.result)). Checking for a newer in-progress run..."
            # Resolve pipeline definition ID if not already known
            if (-not $pipelineDefId) {
                $pipelineListResult2 = Invoke-AzCommand 'pipelines', 'list', `
                    '--name', $PipelineName, '--org', $AdoOrgUrl, '--project', $AdoProject, `
                    '--query', '[0].id', '-o', 'tsv'
                if ($pipelineListResult2.ExitCode -eq 0 -and $pipelineListResult2.Output -match '^\d+$') {
                    $pipelineDefId = $pipelineListResult2.Output.Trim()
                }
            }
            if ($pipelineDefId) {
                $recentResult = Invoke-AzCommand 'pipelines', 'runs', 'list', `
                    '--pipeline-ids', $pipelineDefId, '--branch', "refs/heads/$BranchName", `
                    '--top', '5', '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json'
                if ($recentResult.ExitCode -eq 0 -and $recentResult.Output) {
                    try {
                        $recentRuns = @($recentResult.Output | ConvertFrom-Json)
                        $activeRun = $recentRuns | Where-Object { ($_.status ?? '').ToLower() -notin @('completed', 'canceled', 'canceling') } | Select-Object -First 1
                        if ($activeRun) {
                            Write-Output "  ✅ Found active run: $($activeRun.id) (status: $($activeRun.status)) — switching to monitor this run instead."
                            $RunId = "$($activeRun.id)"
                        } else {
                            Write-Output "  ℹ️  No active runs found. Will report on the latest completed run $RunId."
                        }
                    } catch { <# Intentionally suppressed — best-effort active run detection #> $null = $_ }
                }
            }
        }
    } catch { <# Intentionally suppressed — best-effort stale-run status check #> $null = $_ }
}

# ── Results collector ───────────────────────────────────────
$script:Results  = [System.Collections.ArrayList]::new()
$script:ExitCode = 0

$script:CheckNames = @{
    'MO-01'  = 'Build Stage'
    'MO-01b' = 'Provision Stage'
    'MO-02'  = 'Deploy Stage'
    'MO-03'  = 'Pipeline Result'
    'MO-04'  = 'Health Check'
    'MO-05'  = 'Version Match'
    'MO-R1'  = 'Retry Attempt 1'
    'MO-R2'  = 'Retry Attempt 2'
    'MO-R3'  = 'Retry Attempt 3'
    'MO-06'  = 'Deployed Resources'
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','WARN','SKIP')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Fix
    )
    $name = if ($script:CheckNames.ContainsKey($Id)) { $script:CheckNames[$Id] } else { "Check $Id" }
    $null = $script:Results.Add([pscustomobject]@{ Id = $Id; Name = $name; Status = $Status; Message = $Message; Fix = $Fix })
    if ($Status -eq 'FAIL') { $script:ExitCode = 1 }

    $icon  = switch ($Status) { 'PASS' { '✅' } 'FAIL' { '❌' } 'WARN' { '⚠️' } 'SKIP' { '⏭️' } }
    $line  = "  $icon ${Id}: $name"
    if ($Status -ne 'PASS') { $line += " — $Message" }
    Write-Output $line

    # ── Structured log ──────────────────────────────────────
    $logLevel = switch ($Status) { 'PASS' {'info'} 'FAIL' {'error'} 'WARN' {'warn'} 'SKIP' {'info'} default {'info'} }
    if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
        Write-VsdLog -Message "$Id $name — $Message" -Category 'monitor' -Level $logLevel `
            -Agent 'vibeshield-deploy-monitor' -Skill 'deploy-monitor' `
            -Script 'Invoke-DeployMonitor.ps1' -CheckId $Id -Stage 4 `
            -WorkspacePath $WorkspacePath `
            -Extra @{ status = $Status; fix = if ($Fix) { $Fix } else { '' } }
    }
}

# ── Banner ──────────────────────────────────────────────────
Push-Location $WorkspacePath

try {

Write-Output ""
Write-Output "================================================================"
Write-Output "  VibeShield-Deploy Monitor & Verify"
Write-Output "================================================================"
Write-Output ""
Write-Output "  Pipeline        : $PipelineName"
Write-Output "  Run ID          : $RunId"
Write-Output "  Branch          : $BranchName"
Write-Output "  ADO Org         : $AdoOrgUrl"
Write-Output "  ADO Project     : $AdoProject"
Write-Output "  App URL         : $(if ($AppUrl) { $AppUrl } else { '(not provided — health check will be skipped)' })"
Write-Output "  Target Service  : $(if ($TargetService) { $TargetService } else { '(not provided)' })"
Write-Output "  Max Retries     : $MaxRetries"
Write-Output "  Poll Interval   : ${PollIntervalSec}s"
Write-Output "  Report Interval : ${ReportIntervalSec}s"
Write-Output "  Timeout         : ${TimeoutMinutes}m (per run), ${TotalTimeoutMinutes}m (global)"

# ── Global deadline — prevents infinite retry loops ─────────
$script:GlobalDeadline = (Get-Date).AddMinutes($TotalTimeoutMinutes)

$script:PipelineRunUrl = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$RunId"
Write-Output "  Run Logs        : $script:PipelineRunUrl"
Write-Output ""

# ════════════════════════════════════════════════════════════
# SECTION 1 — Monitor Pipeline Run
# ════════════════════════════════════════════════════════════
$currentRunId = $RunId
Write-Output "  Monitoring pipeline run ${RunId}..."
Write-Output "  Running checks:"

$detail = Wait-PipelineCompletion -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject `
    -PollIntervalSec $PollIntervalSec -ReportIntervalSec $ReportIntervalSec -TimeoutMinutes $TimeoutMinutes

# ── Stage-Level Progress Report ─────────────────────────────
Write-Output ""
Write-Output ""
Write-Output "  Pipeline Stage Breakdown:"
$stageDetails = @(Get-PipelineStageDetails -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject)
if ($stageDetails.Count -gt 0) {
    $stageProgress = Format-StageProgress -StageDetails $stageDetails
    Write-Output $stageProgress
} else {
    Write-Output "    (stage details not available)"
}
Write-Output ""
Write-Output "  Running checks:"

# ── Task log cache — avoid redundant API calls for the same log ──
$script:TaskLogCache = @{}
if ($detail.RunState -eq 'completed' -and $detail.RunResult -eq 'succeeded') {
    Add-Result -Id 'MO-01' -Status PASS -Message 'Build stage completed successfully'
} elseif ($detail.RunState -eq 'completed') {
    # Classify failure to determine which stage failed
    $classification = Get-FailureClassification -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
    if ($classification.Stage -and $classification.Stage -ne 'Deploy' -and $classification.Stage -ne 'Provision' -and $classification.Stage -ne 'Unknown') {
        Add-Result -Id 'MO-01' -Status FAIL -Message "Build stage failed: $($classification.ErrorMessage)" `
            -Fix 'Review build logs for compilation or dependency errors.'
        # Retrieve failed task logs for diagnosis
        if ($stageDetails.Count -gt 0) {
            foreach ($stage in $stageDetails) {
                foreach ($job in $stage.Jobs) {
                    foreach ($task in $job.Tasks) {
                        if ($task.Result -eq 'failed' -and $task.LogId) {
                            # Use cached log if available
                            if ($script:TaskLogCache.ContainsKey($task.LogId)) {
                                $taskLog = $script:TaskLogCache[$task.LogId]
                            } else {
                                $taskLog = Get-PipelineTaskLog -RunId $RunId -LogId $task.LogId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
                                $script:TaskLogCache[$task.LogId] = $taskLog
                            }
                            if ($taskLog.Status -eq 'PASS' -and $taskLog.Content) {
                                Write-Output ""
                                Write-Output "  Failed task log ($($task.Name)):"
                                # Show last 20 lines to keep output manageable
                                $logLines = $taskLog.Content -split "`n" | Select-Object -Last 20
                                # Sanitize logs for secrets before display
                                if (Get-Command Remove-SensitiveContent -ErrorAction SilentlyContinue) {
                                    $logLines = $logLines | ForEach-Object { Remove-SensitiveContent -Text $_ }
                                }
                                foreach ($line in $logLines) { Write-Output "    $line" }
                            } elseif ($taskLog.Status -ne 'PASS') {
                                Write-Output "  ⚠️ Could not retrieve failed task log ($($task.Name)): $($taskLog.ErrorMessage)" | Out-Host
                            }
                        }
                    }
                }
            }
        }
    } else {
        Add-Result -Id 'MO-01' -Status PASS -Message 'Build stage passed (failure in later stage)'
    }
} elseif ($detail.RunState -eq 'timeout') {
    Add-Result -Id 'MO-01' -Status WARN -Message 'Pipeline timed out before completion'
} else {
    Add-Result -Id 'MO-01' -Status WARN -Message "Pipeline state: $($detail.RunState)"
}

# ── MO-01b: Provision Stage (Bicep Infrastructure or EV2 Rollout) ─────
if ($detail.RunState -eq 'completed' -and $detail.RunResult -eq 'succeeded') {
    Add-Result -Id 'MO-01b' -Status PASS -Message 'Provision stage completed successfully'
} elseif ($detail.RunState -eq 'completed') {
    if (-not (Get-Variable 'classification' -Scope Local -ErrorAction SilentlyContinue)) {
        $classification = Get-FailureClassification -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
    }
    if ($classification.Classification -in @('EV2', 'EV2-Auth')) {
        Add-Result -Id 'MO-01b' -Status FAIL `
            -Message "Provision stage failed (EV2 rollout): $($classification.ErrorMessage)" `
            -Fix 'Check EV2 rollout logs. Re-generate ServiceGroupRoot artifacts via ev2-demo-agent (/ev2) if validation errors. For EV2-Auth: verify Ev2Endpoint SC exists.'
    } elseif ($classification.Stage -eq 'Provision' -or $classification.Classification -eq 'Bicep/Infrastructure') {
        Add-Result -Id 'MO-01b' -Status FAIL `
            -Message "Provision stage failed: $($classification.ErrorMessage)" `
            -Fix 'Review Bicep template and infrastructure configuration. Ensure resource group exists and service connection has Owner role.'
    } else {
        Add-Result -Id 'MO-01b' -Status PASS -Message 'Provision stage passed (failure in later stage)'
    }
} else {
    Add-Result -Id 'MO-01b' -Status SKIP -Message "Pipeline did not complete — state: $($detail.RunState)"
}

# ── MO-02: Deploy Stage ────────────────────────────────────
if ($detail.RunState -eq 'completed' -and $detail.RunResult -eq 'succeeded') {
    Add-Result -Id 'MO-02' -Status PASS -Message 'Deploy stage completed successfully'
} elseif ($detail.RunState -eq 'completed') {
    if (-not (Get-Variable 'classification' -Scope Local -ErrorAction SilentlyContinue)) {
        $classification = Get-FailureClassification -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
    }
    if ($classification.Stage -eq 'Deploy' -or $classification.Classification -eq 'Deployment') {
        Add-Result -Id 'MO-02' -Status FAIL `
            -Message "Deploy stage failed ($($classification.Classification)): $($classification.ErrorMessage)" `
            -Fix 'Review deployment logs and infrastructure configuration.'
        # Retrieve failed task logs for diagnosis
        if (@($stageDetails).Count -gt 0) {
            foreach ($stage in $stageDetails) {
                foreach ($job in $stage.Jobs) {
                    foreach ($task in $job.Tasks) {
                        if ($task.Result -eq 'failed' -and $task.LogId) {
                            # Use cached log if available
                            if ($script:TaskLogCache.ContainsKey($task.LogId)) {
                                $taskLog = $script:TaskLogCache[$task.LogId]
                            } else {
                                $taskLog = Get-PipelineTaskLog -RunId $RunId -LogId $task.LogId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
                                $script:TaskLogCache[$task.LogId] = $taskLog
                            }
                            if ($taskLog.Status -eq 'PASS' -and $taskLog.Content) {
                                Write-Output ""
                                Write-Output "  Failed task log ($($task.Name)):"
                                $logLines = $taskLog.Content -split "`n" | Select-Object -Last 20
                                if (Get-Command Remove-SensitiveContent -ErrorAction SilentlyContinue) {
                                    $logLines = $logLines | ForEach-Object { Remove-SensitiveContent -Text $_ }
                                }
                                foreach ($line in $logLines) { Write-Output "    $line" }
                            } elseif ($taskLog.Status -ne 'PASS') {
                                Write-Output "  ⚠️ Could not retrieve failed task log ($($task.Name)): $($taskLog.ErrorMessage)" | Out-Host
                            }
                        }
                    }
                }
            }
        }
    } else {
        Add-Result -Id 'MO-02' -Status SKIP -Message 'Deploy stage not reached — build failed'
    }
} else {
    Add-Result -Id 'MO-02' -Status SKIP -Message "Pipeline did not complete — state: $($detail.RunState)"
}

# ── MO-03: Pipeline Result ─────────────────────────────────
if ($detail.Status -eq 'PASS') {
    Add-Result -Id 'MO-03' -Status PASS -Message $detail.Message
} elseif ($detail.Status -eq 'WARN') {
    Add-Result -Id 'MO-03' -Status WARN -Message $detail.Message
} else {
    Add-Result -Id 'MO-03' -Status FAIL -Message $detail.Message `
        -Fix 'Review pipeline logs for error details.'
}

# ════════════════════════════════════════════════════════════
# SECTION 2 — Post-Deployment Verification (on success)
# ════════════════════════════════════════════════════════════
$pipelineSucceeded = ($detail.RunState -eq 'completed' -and $detail.RunResult -eq 'succeeded')

# ── MO-03b: EV2 Rollout Monitoring (Gap D) ─────────────────
# For EV2 deployments, the ADO pipeline hands off to the EV2 server.
# The pipeline succeeding only means the rollout was submitted — not completed.
# We must poll the EV2 rollout until it reaches a terminal state.
$ev2RolloutResult = $null
if ($pipelineSucceeded -and $InfraDeploy -eq 'EV2') {
    Write-Output "  EV2 deployment detected — checking rollout status..." | Out-Host
    $ev2Info = Get-Ev2RolloutIdFromLogs -RunId $currentRunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
    if ($ev2Info) {
        Write-Output "  EV2 Rollout ID: $($ev2Info.RolloutId)" | Out-Host
        $ev2RolloutResult = Wait-Ev2RolloutCompletion `
            -RolloutId $ev2Info.RolloutId `
            -RolloutUrl $ev2Info.RolloutUrl `
            -PollIntervalSec $PollIntervalSec `
            -TimeoutMinutes $TimeoutMinutes

        if ($ev2RolloutResult.State -eq 'Succeeded') {
            Add-Result -Id 'MO-03b' -Status PASS -Message "EV2 rollout completed successfully (ID: $($ev2Info.RolloutId))"
        } elseif ($ev2RolloutResult.Status -eq 'SKIP') {
            Add-Result -Id 'MO-03b' -Status WARN -Message "EV2 MCP not available — cannot verify rollout. $($ev2RolloutResult.Message)"
        } else {
            Add-Result -Id 'MO-03b' -Status FAIL `
                -Message "EV2 rollout failed: $($ev2RolloutResult.Error)" `
                -Fix 'Check the EV2 rollout dashboard for details. Delegate to ev2-demo-agent (/ev2) if ServiceGroupRoot artifacts need regeneration.'
            $pipelineSucceeded = $false  # Block health checks
        }
    } else {
        Add-Result -Id 'MO-03b' -Status WARN -Message 'Could not extract EV2 rollout ID from pipeline logs — rollout status unknown'
    }
}

# ── MO-04: Health Check ────────────────────────────────────
if (-not $pipelineSucceeded) {
    Add-Result -Id 'MO-04' -Status SKIP -Message 'Skipped — pipeline did not succeed'
} elseif ($SkipHealthCheck -or -not $AppUrl) {
    $skipMsg = if (-not $AppUrl) { 'No AppUrl provided' } else { 'SkipHealthCheck flag set' }
    Add-Result -Id 'MO-04' -Status SKIP -Message "Skipped — $skipMsg"
} else {
    # Service-aware initial wait for cold-start differences
    $healthWaitSec = switch ($TargetService) {
        'ContainerApps' { 60 }
        'Functions'     { 15 }
        'StaticWebApps' { 10 }
        default         { 30 }  # AppService and unknown
    }
    $hc = Invoke-AppHealthCheck -AppUrl $AppUrl -InitialWaitSec $healthWaitSec
    Add-Result -Id 'MO-04' -Status $hc.Status -Message $hc.Message -Fix $(if ($hc.ContainsKey('Fix')) { $hc.Fix } else { '' })
}

# ── MO-05: Version Match ───────────────────────────────────
if (-not $pipelineSucceeded) {
    Add-Result -Id 'MO-05' -Status SKIP -Message 'Skipped — pipeline did not succeed'
} elseif ($SkipVersionCheck) {
    Add-Result -Id 'MO-05' -Status SKIP -Message 'Skipped — SkipVersionCheck flag set'
} elseif (-not $detail.SourceVersion) {
    Add-Result -Id 'MO-05' -Status WARN -Message 'Source version not available from pipeline run'
} else {
    $vc = Confirm-DeployedVersion -SourceVersion $detail.SourceVersion
    Add-Result -Id 'MO-05' -Status $vc.Status -Message $vc.Message -Fix $(if ($vc.ContainsKey('Fix')) { $vc.Fix } else { '' })
}

# ════════════════════════════════════════════════════════════
# SECTION 2b — Deployment Summary (on success)
# ════════════════════════════════════════════════════════════
if ($pipelineSucceeded) {
    # ── MO-06: Deployed Resources Discovery ─────────────────
    $deployedResources = @()
    if ($ResourceGroup) {
        $deployedResources = @(Get-DeployedResources -ResourceGroup $ResourceGroup)
        if ($deployedResources.Count -gt 0) {
            Add-Result -Id 'MO-06' -Status PASS -Message "Discovered $($deployedResources.Count) resource(s) in resource group '$ResourceGroup'"
        } else {
            Add-Result -Id 'MO-06' -Status WARN -Message "No resources found in resource group '$ResourceGroup' (may require elevated permissions)"
        }
    } else {
        Add-Result -Id 'MO-06' -Status SKIP -Message 'Skipped — no ResourceGroup provided'
    }

    # ── Print Deployment Summary ────────────────────────────
    $postDeployChecks = @($script:Results | Where-Object { $_.Id -in @('MO-04', 'MO-05', 'MO-06') })

    # Detect infra deploy method and SC names from stage task list
    $_infraMethod = 'ARM'
    $_ev2Sc = ''
    $_armSc = ''
    foreach ($_s in $stageDetails) {
        foreach ($_j in $_s.Jobs) {
            foreach ($_t in $_j.Tasks) {
                if ($_t.Name -match 'Ev2RARollout') { $_infraMethod = 'EV2' }
                if ($_t.Name -match 'Ev2RARollout' -and $_t.PSObject.Properties['Inputs']) {
                    $_csnVal = $_t.Inputs | Where-Object { $_.Key -eq 'ConnectedServiceName' } | Select-Object -First 1
                    if ($_csnVal) { $_ev2Sc = $_csnVal.Value }
                }
                if ($_t.Name -match 'AzureCLI' -and $_t.PSObject.Properties['Inputs']) {
                    $_azSubVal = $_t.Inputs | Where-Object { $_.Key -eq 'azureSubscription' } | Select-Object -First 1
                    if ($_azSubVal) { $_armSc = $_azSubVal.Value }
                }
            }
        }
    }

    $summaryText = Format-DeploymentSummary `
        -StageDetails $stageDetails `
        -DeployedResources $deployedResources `
        -CheckResults $postDeployChecks `
        -PipelineName $PipelineName `
        -RunId $currentRunId `
        -BranchName $BranchName `
        -AppUrl $AppUrl `
        -PipelineRunUrl $script:PipelineRunUrl `
        -Attempt 1 `
        -InfraDeployMethod $_infraMethod `
        -Ev2ServiceConnection $_ev2Sc `
        -ServiceConnectionName $_armSc `
        -AdoOrgUrl $AdoOrgUrl `
        -AdoProject $AdoProject `
        -ResourceGroup $ResourceGroup `
        -SubscriptionId $script:SubscriptionId
    Write-Output $summaryText
}

# ════════════════════════════════════════════════════════════
# SECTION 3 — Retry Logic (category-aware, up to MaxRetries per category)
# ════════════════════════════════════════════════════════════
$attempt      = 1
$currentRunId = $RunId

# ── Retry reasoning history — tracks what was tried and what happened ──
$script:RetryHistory = [System.Collections.ArrayList]::new()

# ── Per-category retry tracking ─────────────────────────────
# Distinct failures (e.g., 5 different bugs each fixed on first try) should
# NOT hit the flat MaxRetries cap. Only same-category failures count.
# Total attempt cap prevents runaway loops regardless of category.
$script:CategoryRetryCount = @{}  # { 'BuildCode' = 2, 'SCAuth' = 1, ... }
$totalAttemptCap = $MaxRetries * 2  # absolute cap: 2x MaxRetries across all categories

while (-not $pipelineSucceeded -and $attempt -le $totalAttemptCap) {
    # ── Global deadline guard ────────────────────────────────
    if ((Get-Date) -ge $script:GlobalDeadline) {
        Add-Result -Id "MO-R$attempt" -Status FAIL `
            -Message "Global timeout exceeded (${TotalTimeoutMinutes}m). Aborting retries." `
            -Fix 'Increase -TotalTimeoutMinutes or investigate why the pipeline is running so long.'
        break
    }

    $retryId = "MO-R$attempt"
    Write-Output ""

    # Classify the failure BEFORE deciding what to do (always re-fetch)
    $classification = Get-FailureClassification -RunId $currentRunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
    $category = $classification.Classification

    # ── Per-category retry cap ───────────────────────────────
    # Only count retries for the SAME failure category against MaxRetries.
    # Distinct categories each get their own counter.
    if (-not $script:CategoryRetryCount.ContainsKey($category)) {
        $script:CategoryRetryCount[$category] = 0
    }
    $script:CategoryRetryCount[$category]++
    $categoryCount = $script:CategoryRetryCount[$category]
    Write-Output "  Retry attempt $attempt (category '$category': $categoryCount of ${MaxRetries})..."

    if ($categoryCount -gt $MaxRetries) {
        Write-Output "  ⚠️ Category '$category' has exceeded ${MaxRetries} retries. Escalating." | Out-Host
        Add-Result -Id $retryId -Status FAIL `
            -Message "Category '$category' exceeded retry limit ($categoryCount > $MaxRetries)" `
            -Fix "This failure category has been retried ${MaxRetries} times without resolution. Review logs manually or escalate."
        $null = $script:RetryHistory.Add(@{
            Attempt        = $attempt
            Classification = $category
            ErrorMessage   = $classification.ErrorMessage
            FixApplied     = '(none — category retry limit exceeded)'
            Result         = 'escalated — category cap'
        })
        break
    }

    # ── Fix-didn't-work detection ────────────────────────────
    # If the previous retry had the same classification AND error, the fix
    # didn't address the root cause — escalate instead of repeating.
    if ($script:RetryHistory.Count -gt 0) {
        $lastAttempt = $script:RetryHistory[-1]
        if ($lastAttempt.Classification -eq $classification.Classification -and
            $lastAttempt.ErrorMessage -eq $classification.ErrorMessage) {
            Write-Output "  ⚠️ Same error recurred after applying fix '$($lastAttempt.FixApplied)'" | Out-Host
            Write-Output "  → Previous fix did not address the root cause. Escalating." | Out-Host
            Add-Result -Id $retryId -Status FAIL `
                -Message "Same error recurred after fix: $($classification.Classification) — '$($classification.ErrorMessage)'" `
                -Fix "The fix '$($lastAttempt.FixApplied)' did not resolve this issue. The root cause may be different. Review logs manually."
            $null = $script:RetryHistory.Add(@{
                Attempt        = $attempt
                Classification = $classification.Classification
                ErrorMessage   = $classification.ErrorMessage
                FixApplied     = '(none — same error recurred)'
                Result         = 'escalated — fix ineffective'
            })
            break
        }
    }

    # Non-retryable: Bicep/Infrastructure or Compliance — escalate immediately
    if ($classification.Classification -in @('Bicep/Infrastructure', 'Compliance')) {
        Add-Result -Id $retryId -Status FAIL `
            -Message "Non-retryable failure ($($classification.Classification)): $($classification.ErrorMessage)" `
            -Fix "This failure type requires manual intervention. Escalating."
        $null = $script:RetryHistory.Add(@{
            Attempt        = $attempt
            Classification = $classification.Classification
            ErrorMessage   = $classification.ErrorMessage
            FixApplied     = '(none — non-retryable)'
            Result         = 'escalated'
        })
        break
    }

    # Determine the fix being applied (for reasoning history)
    $diagnosis = Get-FailureDiagnosis -ErrorMessage $classification.ErrorMessage
    $fixDescription = if ($diagnosis.Fix) { $diagnosis.Fix } else { 're-trigger pipeline' }

    # ── Show transient/persistent classification to user ─────
    if ($diagnosis.Transient) {
        Write-Output "  ℹ️ This is a transient error ($($diagnosis.Category)) — retrying should help." | Out-Host
    } else {
        Write-Output "  ℹ️ This is likely a persistent error ($($diagnosis.Category)) — retrying to confirm, but the fix is: $($diagnosis.Fix)" | Out-Host
    }
    # Show ranked alternatives if available
    if ($diagnosis.Alternatives -and $diagnosis.Alternatives.Count -gt 0) {
        $altText = $diagnosis.Alternatives | ForEach-Object {
            if ($_ -is [hashtable] -and $_.Hypothesis) { "[$($_.Likelihood)] $($_.Hypothesis)" }
            elseif ($_ -is [string]) { $_ }
        }
        if ($altText) {
            Write-Output "  💡 If the primary fix doesn't work, consider: $($altText -join ' | ')" | Out-Host
        }
    }

    # Re-trigger
    $retry = Invoke-PipelineRetry -PipelineName $PipelineName -BranchName $BranchName `
        -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject

    if ($retry.Status -ne 'PASS' -or -not $retry.RunId) {
        Add-Result -Id $retryId -Status FAIL -Message "Retry trigger failed: $($retry.Message)" `
            -Fix $(if ($retry.ContainsKey('Fix')) { $retry.Fix } else { '' })
        break
    }

    $currentRunId = $retry.RunId
    Write-Output "  New run ID: $currentRunId — polling..."

    # Wait for the retried run
    $retryDetail = Wait-PipelineCompletion -RunId $currentRunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject `
        -PollIntervalSec $PollIntervalSec -ReportIntervalSec $ReportIntervalSec -TimeoutMinutes $TimeoutMinutes

    # Show stage breakdown for retried run
    $retryStages = @(Get-PipelineStageDetails -RunId $currentRunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject)
    if ($retryStages.Count -gt 0) {
        Write-Output ""
        Write-Output "  Retry $attempt Stage Breakdown:"
        Write-Output (Format-StageProgress -StageDetails $retryStages)
    }

    if ($retryDetail.RunState -eq 'completed' -and $retryDetail.RunResult -eq 'succeeded') {
        Add-Result -Id $retryId -Status PASS -Message "Retry $attempt succeeded (run $currentRunId)"
        $pipelineSucceeded = $true
        $detail = $retryDetail
        $null = $script:RetryHistory.Add(@{
            Attempt        = $attempt
            Classification = $classification.Classification
            ErrorMessage   = $classification.ErrorMessage
            FixApplied     = $fixDescription
            Result         = 'succeeded'
        })

        # Re-run post-deployment checks for the successful retry
        if (-not $SkipHealthCheck -and $AppUrl) {
            $healthWaitSec = switch ($TargetService) {
                'ContainerApps' { 60 }
                'Functions'     { 15 }
                'StaticWebApps' { 10 }
                default         { 30 }
            }
            $hc = Invoke-AppHealthCheck -AppUrl $AppUrl -InitialWaitSec $healthWaitSec
            # Update MO-04 result — remove the old SKIP and add the real result
            $script:Results = [System.Collections.ArrayList]@($script:Results | Where-Object { $_.Id -ne 'MO-04' })
            Add-Result -Id 'MO-04' -Status $hc.Status -Message $hc.Message -Fix $(if ($hc.ContainsKey('Fix')) { $hc.Fix } else { '' })
        }
        if (-not $SkipVersionCheck -and $retryDetail.SourceVersion) {
            $vc = Confirm-DeployedVersion -SourceVersion $retryDetail.SourceVersion
            $script:Results = [System.Collections.ArrayList]@($script:Results | Where-Object { $_.Id -ne 'MO-05' })
            Add-Result -Id 'MO-05' -Status $vc.Status -Message $vc.Message -Fix $(if ($vc.ContainsKey('Fix')) { $vc.Fix } else { '' })
        }

        # ── Deployment summary for successful retry ──────────
        $retryDeployedResources = @()
        if ($ResourceGroup) {
            $retryDeployedResources = @(Get-DeployedResources -ResourceGroup $ResourceGroup)
            $script:Results = [System.Collections.ArrayList]@($script:Results | Where-Object { $_.Id -ne 'MO-06' })
            if ($retryDeployedResources.Count -gt 0) {
                Add-Result -Id 'MO-06' -Status PASS -Message "Discovered $($retryDeployedResources.Count) resource(s) in resource group '$ResourceGroup'"
            } else {
                Add-Result -Id 'MO-06' -Status WARN -Message "No resources found in resource group '$ResourceGroup'"
            }
        }
        $retryPostChecks = @($script:Results | Where-Object { $_.Id -in @('MO-04', 'MO-05', 'MO-06') })
        $retrySummaryText = Format-DeploymentSummary `
            -StageDetails $retryStages `
            -DeployedResources $retryDeployedResources `
            -CheckResults $retryPostChecks `
            -PipelineName $PipelineName `
            -RunId $currentRunId `
            -BranchName $BranchName `
            -AppUrl $AppUrl `
            -PipelineRunUrl "$AdoOrgUrl/$AdoProject/_build/results?buildId=$currentRunId" `
            -Attempt $attempt `
            -InfraDeployMethod $_infraMethod `
            -Ev2ServiceConnection $_ev2Sc `
            -ServiceConnectionName $_armSc `
            -AdoOrgUrl $AdoOrgUrl `
            -AdoProject $AdoProject `
            -ResourceGroup $ResourceGroup `
            -SubscriptionId $script:SubscriptionId
        Write-Output $retrySummaryText
    } else {
        Add-Result -Id $retryId -Status FAIL `
            -Message "Retry $attempt failed (run $currentRunId): $($retryDetail.Message)" `
            -Fix 'Review pipeline logs for the retried run.'
        $null = $script:RetryHistory.Add(@{
            Attempt        = $attempt
            Classification = $classification.Classification
            ErrorMessage   = $classification.ErrorMessage
            FixApplied     = $fixDescription
            Result         = "failed — $($retryDetail.Message)"
        })
    }

    $attempt++
}

# ── State file: write final monitoring state ────────────────
$stateManagerPath = Join-Path -Path $WorkspacePath -ChildPath '.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1'
if (Test-Path $stateManagerPath) {
    $finalState = @{
        LastCompletedStage = if ($pipelineSucceeded) { 4 } else { 3 }
        SubStep            = if ($pipelineSucceeded) { $null } else { 'failed' }
        PipelineRunId      = $currentRunId
        BranchName         = $script:OriginalBranchName
        PipelineName       = $PipelineName
        RetryCount         = [Math]::Max(0, $attempt - 1)
        CategoryRetryCount = $script:CategoryRetryCount
        FailureHistory     = @($script:RetryHistory | ForEach-Object {
            [ordered]@{
                Attempt        = $_.Attempt
                Classification = $_.Classification
                ErrorMessage   = $_.ErrorMessage
                FixApplied     = $_.FixApplied
                Result         = $_.Result
            }
        })
        Timestamp          = (Get-Date -Format 'o')
    }
    $global:LASTEXITCODE = 0
    & $stateManagerPath -Action Write -WorkspacePath $WorkspacePath -State $finalState
}

# ── Escalation summary if all retries exhausted ─────────────
if (-not $pipelineSucceeded -and $attempt -gt $MaxRetries) {
    Write-Output ""
    Write-Output "  ╔═══════════════════════════════════════════════════════════╗"
    Write-Output "  ║  ESCALATION: All $MaxRetries retry attempts exhausted                ║"
    Write-Output "  ╚═══════════════════════════════════════════════════════════╝"
    Write-Output ""
    Write-Output "  Pipeline        : $PipelineName"
    Write-Output "  Last Run ID     : $currentRunId"
    Write-Output "  Branch          : $BranchName"
    Write-Output "  Run Logs        : $AdoOrgUrl/$AdoProject/_build/results?buildId=$currentRunId"
    if ((Get-Variable 'classification' -Scope Local -ErrorAction SilentlyContinue)) {
        Write-Output "  Failure Type    : $($classification.Classification)"
        Write-Output "  Failed Stage    : $($classification.Stage)"
        Write-Output "  Error           : $($classification.ErrorMessage)"
    }

    # ── Reasoning history — what was tried and what happened ──
    if ($script:RetryHistory.Count -gt 0) {
        Write-Output ""
        Write-Output "  Retry Reasoning History:"
        foreach ($rh in $script:RetryHistory) {
            Write-Output "    Attempt $($rh.Attempt): [$($rh.Classification)] $($rh.ErrorMessage)"
            Write-Output "      Fix applied: $($rh.FixApplied)"
            Write-Output "      Result: $($rh.Result)"
        }
    }
    Write-Output ""
    Write-Output "  Recommended next steps:"
    Write-Output "    1. Review pipeline logs in Azure DevOps"
    Write-Output "    2. Check infrastructure configuration"
    Write-Output "    3. Verify service connection and RBAC"
    Write-Output "    4. Contact your DevOps administrator"
}

Write-Output ""

# ════════════════════════════════════════════════════════════
# SARIF Output
# ════════════════════════════════════════════════════════════
if (-not $SarifPath) {
    $SarifPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'deploy-monitor-results.sarif'
}
Initialize-SarifCleanStart -SarifPath $SarifPath

$sarifHelperPath = Join-Path -Path $WorkspacePath -ChildPath '.github/scripts/Write-SarifReport.ps1'
if (Test-Path $sarifHelperPath) {
    $resultsJsonArr = $script:Results | ForEach-Object {
        [ordered]@{
            id      = $_.Id
            name    = $_.Name
            status  = $_.Status
            message = $_.Message
            fix     = $_.Fix
        }
    }
    $resultsJson = $resultsJsonArr | ConvertTo-Json -Depth 5

    $propsObj = [ordered]@{
        pipelineName      = $PipelineName
        pipelineRunId     = $currentRunId
        branch            = $BranchName
        appUrl            = $AppUrl
        pipelineRunUrl    = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$currentRunId"
        attempts          = $attempt
        resourceGroup     = $ResourceGroup
        deployedResources = if ((Get-Variable 'deployedResources' -Scope Local -ErrorAction SilentlyContinue) -or
                               (Get-Variable 'retryDeployedResources' -Scope Local -ErrorAction SilentlyContinue)) {
            $resList = if ((Get-Variable 'retryDeployedResources' -Scope Local -ErrorAction SilentlyContinue) -and $retryDeployedResources.Count -gt 0) {
                $retryDeployedResources
            } elseif ((Get-Variable 'deployedResources' -Scope Local -ErrorAction SilentlyContinue)) {
                $deployedResources
            } else { @() }
            @($resList | ForEach-Object {
                [ordered]@{ name = $_.Name; type = $_.Type; location = $_.Location; kind = $_.Kind; state = $_.ProvisioningState }
            })
        } else { @() }
    }
    $propsJson = $propsObj | ConvertTo-Json -Depth 3 -Compress

    $global:LASTEXITCODE = 0
    & $sarifHelperPath `
        -ToolName 'Monitor & Verify' `
        -ResultsJson $resultsJson `
        -OutputPath $SarifPath `
        -PropertiesJson $propsJson
} else {
    # Fallback inline SARIF
    $sarifRules   = [System.Collections.ArrayList]::new()
    $sarifResults = [System.Collections.ArrayList]::new()

    foreach ($r in $script:Results) {
        $level = switch ($r.Status) {
            'FAIL' { 'error' }
            'WARN' { 'warning' }
            'PASS' { 'note' }
            'SKIP' { 'none' }
        }
        $ruleId = "vibeshield/$($r.Id)"
        if (-not ($sarifRules | Where-Object { $_.id -eq $ruleId })) {
            $null = $sarifRules.Add([ordered]@{
                id               = $ruleId
                name             = $r.Name
                shortDescription = [ordered]@{ text = $r.Name }
            })
        }
        $msgText = $r.Message
        if ($r.Fix) { $msgText += "`nFix: $($r.Fix)" }
        $null = $sarifResults.Add([ordered]@{
            ruleId     = $ruleId
            level      = $level
            message    = [ordered]@{ text = $msgText }
            properties = [ordered]@{
                status    = $r.Status
                checkId   = $r.Id
                checkName = $r.Name
            }
        })
    }

    $sarifDoc = [ordered]@{
        '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            [ordered]@{
                tool = [ordered]@{
                    driver = [ordered]@{
                        name           = 'VibeShield-Deploy Monitor & Verify'
                        version        = '1.0.0'
                        informationUri = $_cfg.ado.sourceRepoUrl
                        rules          = @($sarifRules)
                    }
                }
                results    = @($sarifResults)
                invocations = @(
                    [ordered]@{
                        executionSuccessful = ($script:ExitCode -eq 0)
                        properties          = [ordered]@{
                            pipelineName  = $PipelineName
                            pipelineRunId = $currentRunId
                            branch        = $BranchName
                            appUrl        = $AppUrl
                            pipelineRunUrl = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$currentRunId"
                            attempts      = $attempt
                        }
                    }
                )
                properties  = [ordered]@{
                    pipelineName  = $PipelineName
                    pipelineRunId = $currentRunId
                    branch        = $BranchName
                    appUrl        = $AppUrl
                    pipelineRunUrl = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$currentRunId"
                    attempts      = $attempt
                }
            }
        )
    }

    $sarifDir = Split-Path -Path $SarifPath -Parent
    if (-not (Test-Path $sarifDir)) { New-Item -ItemType Directory -Path $sarifDir -Force | Out-Null }
    $sarifDoc | ConvertTo-Json -Depth 15 | Set-Content -Path $SarifPath -Encoding utf8

    # Terminal summary
    Write-Output ""
    Write-Output "  SARIF report written to: $SarifPath"
    Write-Output ""
    $total   = $script:Results.Count
    $passed  = @($script:Results | Where-Object Status -eq 'PASS').Count
    $failed  = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $warned  = @($script:Results | Where-Object Status -eq 'WARN').Count
    $skipped = @($script:Results | Where-Object Status -eq 'SKIP').Count
    Write-Output "  Total: $total | Passed: $passed | Failed: $failed | Warnings: $warned | Skipped: $skipped"
}

} finally {
    Pop-Location
}

# ── State write (Phase 2: fold state writes into scripts) ───
if ($UpdateState -and $script:ExitCode -eq 0 -and $StateJson) {
    try {
        $stateData = $StateJson | ConvertFrom-Json -AsHashtable
        Write-DeployState -WorkspacePath $WorkspacePath -StateData $stateData
    } catch {
        Write-Warning "State update failed: $_"
    }
}

exit $script:ExitCode
