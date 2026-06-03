#!/usr/bin/env pwsh
#Requires -Version 7.0
Set-StrictMode -Version Latest
<#
.SYNOPSIS
    Testable functions for the Deploy Monitor stage.

.DESCRIPTION
    Dot-source this file to load pipeline monitoring, health-check, and
    version-verification functions. All external commands (az, git,
    Invoke-WebRequest) are routed through wrapper functions so Pester can
    mock them.
#>

# ════════════════════════════════════════════════════════════
# CLI Wrappers — loaded from shared helpers (mock these in Pester tests)
# ════════════════════════════════════════════════════════════
# Idempotency guard: skip re-dot-source if SharedHelpers is already loaded.
# This preserves Pester mocks that the test's BeforeAll sets up.
# In production, functions aren't pre-loaded so the dot-source runs normally.
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (-not (Get-Command Invoke-GitCommand -ErrorAction SilentlyContinue) -or
    -not (Get-Command Get-DeployConfig -ErrorAction SilentlyContinue)) {
    if (Test-Path $sharedHelpersPath) {
        . $sharedHelpersPath
    } else {
    # Inline fallback if shared helpers not found (e.g. standalone testing)
    function Invoke-GitCommand {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        # Strip -TimeoutSeconds from args (not used in fallback)
        $cleanArgs = @(); for ($i=0; $i -lt $Arguments.Count; $i++) { if ($Arguments[$i] -eq '-TimeoutSeconds' -and $i+1 -lt $Arguments.Count) { $i++ } else { $cleanArgs += $Arguments[$i] } }
        $raw = & git @cleanArgs 2>&1 | Out-String
        $ec  = $LASTEXITCODE
        [pscustomobject]@{ Output = $raw.Trim(); ExitCode = $ec }
    }
    function Invoke-AzCommand {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        $cleanArgs = @(); for ($i=0; $i -lt $Arguments.Count; $i++) { if ($Arguments[$i] -eq '-TimeoutSeconds' -and $i+1 -lt $Arguments.Count) { $i++ } else { $cleanArgs += $Arguments[$i] } }
        $raw = & az @cleanArgs 2>&1 | Out-String
        $ec  = $LASTEXITCODE
        [pscustomobject]@{ Output = $raw.Trim(); ExitCode = $ec }
    }
}
}  # end idempotency guard

function Invoke-HealthRequest {
    <#
    .SYNOPSIS Sends an HTTP request and returns status code + body.
    .DESCRIPTION Wrapper around Invoke-WebRequest for mockability.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSec = 30)
    try {
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        [pscustomobject]@{
            StatusCode = [int]$resp.StatusCode
            Content    = $resp.Content
            Error      = $null
            ErrorType  = $null
        }
    } catch {
        $code = 0
        $errorType = 'unknown'
        $response = $null
        try { $response = $_.Exception.Response } catch { <# Intentionally suppressed — best-effort extraction of HTTP response details #> $null = $_ }
        if ($response) {
            $code = [int]$response.StatusCode
            $errorType = 'http'
        } elseif ($_.Exception.Message -match 'timed out|timeout|TaskCanceledException') {
            $errorType = 'timeout'
        } elseif ($_.Exception.Message -match 'Connection refused|actively refused') {
            $errorType = 'connection'
        } elseif ($_.Exception.Message -match 'could not be resolved|NameResolutionFailure|DNS') {
            $errorType = 'dns'
        }
        [pscustomobject]@{
            StatusCode = $code
            Content    = $null
            Error      = $_.Exception.Message
            ErrorType  = $errorType
        }
    }
}

# ════════════════════════════════════════════════════════════
# MO-01 / MO-02 / MO-03 — Pipeline run status
# ════════════════════════════════════════════════════════════

function Get-PipelineRunDetail {
    <#
    .SYNOPSIS Queries a pipeline run and returns its current state and stage info.
    .DESCRIPTION
        Returns a hashtable with Status (PASS/FAIL/WARN), pipeline run state,
        result, source version, and the full parsed run object.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    $result = Invoke-AzCommand 'pipelines' 'runs' 'show' `
        '--id' $RunId '--org' $AdoOrgUrl '--project' $AdoProject '-o' 'json' `
        -TimeoutSeconds 60

    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return @{
            Status        = 'FAIL'
            Message       = "Failed to query pipeline run ${RunId}: $($result.Output)"
            RunState      = 'unknown'
            RunResult     = 'unknown'
            SourceVersion = ''
            RunObject     = $null
        }
    }

    try {
        $run = $result.Output | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse pipeline run JSON for run ${RunId}: $($_.Exception.Message)"
        return @{
            Status        = 'FAIL'
            Message       = "Failed to parse pipeline run response for run ${RunId}"
            RunState      = 'unknown'
            RunResult     = 'unknown'
            SourceVersion = ''
            RunObject     = $null
        }
    }

    $state  = if ($run.status) { $run.status } else { 'unknown' }
    $runRes = if ($run.result) { $run.result } else { '' }
    $srcVer = if ($run.sourceVersion) { $run.sourceVersion } else { '' }

    if ($state -eq 'completed') {
        if ($runRes -eq 'succeeded') {
            return @{
                Status        = 'PASS'
                Message       = "Pipeline run ${RunId} completed successfully"
                RunState      = $state
                RunResult     = $runRes
                SourceVersion = $srcVer
                RunObject     = $run
            }
        } else {
            return @{
                Status        = 'FAIL'
                Message       = "Pipeline run ${RunId} completed with result: $runRes"
                RunState      = $state
                RunResult     = $runRes
                SourceVersion = $srcVer
                RunObject     = $run
            }
        }
    }

    if ($state -in @('canceling', 'canceled')) {
        return @{
            Status        = 'WARN'
            Message       = "Pipeline run ${RunId} was canceled"
            RunState      = $state
            RunResult     = $runRes
            IsRetryable   = $true
            SourceVersion = $srcVer
            RunObject     = $run
        }
    }

    # In-progress states (inProgress, notStarted, queued)
    return @{
        Status        = 'WARN'
        Message       = "Pipeline run ${RunId} is $state"
        RunState      = $state
        RunResult     = $runRes
        SourceVersion = $srcVer
        RunObject     = $run
    }
}

function Wait-PipelineCompletion {
    <#
    .SYNOPSIS Polls a pipeline run until it reaches a terminal state.
    .DESCRIPTION
        Polls every $PollIntervalSec seconds up to $TimeoutMinutes.
        Every $ReportIntervalSec seconds (default 60) a detailed progress
        report is printed showing elapsed time and per-stage status via
        Get-PipelineStageDetails / Format-StageProgress, then monitoring
        resumes automatically.
        Returns the final Get-PipelineRunDetail result.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject,
        [int]$PollIntervalSec    = 0,
        [int]$TimeoutMinutes     = 0,
        [int]$ReportIntervalSec  = 0
    )

    # Resolve defaults from config at call time (not file-load time) to avoid
    # breaking all functions in this file if deploy-config.json is missing.
    if (-not $PSBoundParameters.ContainsKey('PollIntervalSec') -or $PollIntervalSec -le 0) {
        $PollIntervalSec = try { (Get-DeployConfig).monitor.pollIntervalSec } catch { 30 }
    }
    if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes') -or $TimeoutMinutes -le 0) {
        $TimeoutMinutes = try { (Get-DeployConfig).monitor.timeoutMinutes } catch { 60 }
    }
    if (-not $PSBoundParameters.ContainsKey('ReportIntervalSec') -or $ReportIntervalSec -le 0) {
        $ReportIntervalSec = try { (Get-DeployConfig).monitor.reportIntervalSec } catch { 60 }
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $terminalStates = @('completed', 'canceled', 'canceling')
    $startTime      = Get-Date
    $lastReportTime = Get-Date

    while ((Get-Date) -lt $deadline) {
        # Resilient poll: az CLI can fail transiently (pipe errors, timeouts).
        # On failure, retry on the next cycle instead of crashing.
        try {
            $detail = Get-PipelineRunDetail -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
        } catch {
            Write-Output "  Warning: Failed to query pipeline status: $($_.Exception.Message) — retrying in ${PollIntervalSec}s..." | Out-Host
            Start-Sleep -Seconds $PollIntervalSec
            continue
        }
        if (-not $detail -or ($detail -isnot [hashtable] -and $detail -isnot [pscustomobject])) {
            Write-Output "  Warning: Unexpected response from pipeline query — retrying in ${PollIntervalSec}s..." | Out-Host
            Start-Sleep -Seconds $PollIntervalSec
            continue
        }

        $detailRunState = if ($detail -is [hashtable]) { $detail['RunState'] } elseif ($detail.PSObject.Properties['RunState']) { $detail.RunState } else { $null }
        $detailStatus   = if ($detail -is [hashtable]) { $detail['Status'] }   elseif ($detail.PSObject.Properties['Status'])   { $detail.Status }   else { $null }

        if ($detailRunState -in $terminalStates -or $detailStatus -eq 'FAIL') {
            return $detail
        }

        # Periodic progress report every ReportIntervalSec
        $sinceLast = ((Get-Date) - $lastReportTime).TotalSeconds
        if ($sinceLast -ge $ReportIntervalSec) {
            $elapsed    = ((Get-Date) - $startTime).TotalSeconds
            $elapsedMin = [math]::Floor($elapsed / 60)
            $elapsedSec = [math]::Round($elapsed % 60)
            Write-Output "" | Out-Host
            Write-Output "  ── Progress Report (${elapsedMin}m ${elapsedSec}s elapsed) ──" | Out-Host
            Write-Output "  Pipeline run ${RunId} is $detailRunState" | Out-Host

            $stageDetails = @(Get-PipelineStageDetails -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject)
            if ($stageDetails.Count -gt 0) {
                $stageProgress = Format-StageProgress -StageDetails $stageDetails
                Write-Output $stageProgress | Out-Host

                # Structured progress marker for orchestrator-driven polling (Gap A/B)
                $stageMap = @{}
                foreach ($s in $stageDetails) {
                    $stageMap[$s['Name']] = @{ status = $s['State']; duration = $s['DurationSec'] }
                }
                $progressJson = @{
                    runId     = $RunId
                    state     = $detailRunState
                    elapsed   = "${elapsedMin}m ${elapsedSec}s"
                    stages    = $stageMap
                } | ConvertTo-Json -Compress
                Write-Output "##[monitor-progress]$progressJson" | Out-Host
            } else {
                Write-Output "    (stage details not yet available)" | Out-Host
            }

            Write-Output "  Continuing to monitor..." | Out-Host
            Write-Output "" | Out-Host
            $lastReportTime = Get-Date
        }

        Write-Output "  Pipeline run ${RunId} is $detailRunState — polling again in ${PollIntervalSec}s..." | Out-Host
        Start-Sleep -Seconds $PollIntervalSec
    }

    return @{
        Status        = 'FAIL'
        Message       = "Pipeline run ${RunId} did not complete within ${TimeoutMinutes} minutes"
        RunState      = 'timeout'
        RunResult     = 'timeout'
        SourceVersion = ''
        RunObject     = $null
    }
}

# ════════════════════════════════════════════════════════════
# MO-04 — Health Check
# ════════════════════════════════════════════════════════════

function Invoke-AppHealthCheck {
    <#
    .SYNOPSIS Checks if the deployed app responds with HTTP 200.
    .DESCRIPTION
        Sends an HTTP GET to the app URL. Retries with exponential backoff.
        If AppUrl is not provided but TargetService and AppName are, derives
        the health check URL from the service type.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppUrl,
        [string]$TargetService,
        [int]$MaxRetries   = 0,
        [int]$InitialWaitSec = 30,
        [int]$TimeoutSec   = 30
    )

    if (-not $PSBoundParameters.ContainsKey('MaxRetries') -or $MaxRetries -le 0) {
        $MaxRetries = try { (Get-DeployConfig).monitor.maxRetries } catch { 3 }
    }

    # Service-aware health check path derivation
    if ($TargetService -and $AppUrl -notmatch '/health|/api/health') {
        $healthPath = switch ($TargetService) {
            'Functions'     { '/api/health' }
            'StaticWebApps' { '/' }
            default         { '/' }
        }
        # Only append path if URL doesn't already have one (beyond /)
        $uri = [System.Uri]$AppUrl
        if ($uri.AbsolutePath -eq '/') {
            $AppUrl = $AppUrl.TrimEnd('/') + $healthPath
        }
    }

    $resp = Invoke-HealthRequest -Uri $AppUrl -TimeoutSec $TimeoutSec

    if ($resp.StatusCode -eq 200) {
        return @{
            Status     = 'PASS'
            Message    = "HTTP 200 at $AppUrl"
            StatusCode = 200
        }
    }

    # Retry with exponential backoff
    $waitSec = $InitialWaitSec
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Output "  Health check returned $($resp.StatusCode) — retrying in ${waitSec}s (attempt $i of $MaxRetries)..." | Out-Host
        Start-Sleep -Seconds $waitSec

        $resp = Invoke-HealthRequest -Uri $AppUrl -TimeoutSec $TimeoutSec

        if ($resp.StatusCode -eq 200) {
            return @{
                Status     = 'PASS'
                Message    = "HTTP 200 at $AppUrl (passed on retry $i)"
                StatusCode = 200
            }
        }

        $waitSec = [Math]::Min($waitSec * 2, 300)
    }

    $msg = if ($resp.Error) {
        "Health check failed at ${AppUrl}: $($resp.Error)"
    } else {
        "Health check failed at ${AppUrl}: HTTP $($resp.StatusCode)"
    }

    return @{
        Status     = 'FAIL'
        Message    = $msg
        StatusCode = $resp.StatusCode
        Fix        = 'Check application logs for startup errors.'
    }
}

# ════════════════════════════════════════════════════════════
# MO-05 — Version Verification
# ════════════════════════════════════════════════════════════

function Confirm-DeployedVersion {
    <#
    .SYNOPSIS Verifies the deployed source version matches or is an ancestor of local HEAD.
    .DESCRIPTION
        Uses git merge-base --is-ancestor to handle merge/rebase commits
        where the deployed SHA differs from the direct local HEAD.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceVersion
    )

    $headResult = Invoke-GitCommand 'rev-parse', 'HEAD'
    if ($headResult.ExitCode -ne 0) {
        return @{
            Status  = 'WARN'
            Message = "Could not determine local HEAD: $($headResult.Output)"
        }
    }

    $localHead = $headResult.Output.Trim()

    # Exact match (short prefix comparison)
    $minLen = [Math]::Min($localHead.Length, $SourceVersion.Length)
    if ($minLen -ge 7 -and $localHead.Substring(0, $minLen) -eq $SourceVersion.Substring(0, $minLen)) {
        return @{
            Status  = 'PASS'
            Message = "Deployed version matches local HEAD ($($localHead.Substring(0,7)))"
        }
    }

    # Ancestry check — handles merge/rebase commits
    $ancestryResult = Invoke-GitCommand 'merge-base', '--is-ancestor', $SourceVersion, 'HEAD'
    if ($ancestryResult.ExitCode -eq 0) {
        return @{
            Status  = 'PASS'
            Message = "Deployed version $($SourceVersion.Substring(0, [Math]::Min(7, $SourceVersion.Length))) is an ancestor of local HEAD ($($localHead.Substring(0,7)))"
        }
    }

    return @{
        Status  = 'WARN'
        Message = "Version mismatch — deployed: $($SourceVersion.Substring(0, [Math]::Min(7, $SourceVersion.Length))), local HEAD: $($localHead.Substring(0, [Math]::Min(7, $localHead.Length)))"
        Fix     = 'The pipeline may have run against an older commit. Push again to deploy the latest code.'
    }
}

# ════════════════════════════════════════════════════════════
# Failure Classification
# ════════════════════════════════════════════════════════════

function Get-PipelineStageDetails {
    <#
    .SYNOPSIS Returns per-stage status from the pipeline timeline.
    .DESCRIPTION
        Queries the Azure DevOps timeline API and returns an array of
        stage records, each containing name, state, result, duration, and
        child jobs with their tasks. Enables granular stage-by-stage
        progress reporting during monitoring.
    .OUTPUTS Array of hashtables with keys: Name, Type, State, Result,
        StartTime, FinishTime, DurationSec, Jobs (array).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    $result = Invoke-AzCommand 'devops' 'invoke' `
        '--area' 'build' '--resource' 'timeline' `
        '--route-parameters' "buildId=$RunId" "project=$AdoProject" `
        '--org' $AdoOrgUrl '-o' 'json' `
        -TimeoutSeconds 60

    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return @()
    }

    try {
        $timeline = $result.Output | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse pipeline timeline JSON for run ${RunId}: $($_.Exception.Message)"
        return @()
    }

    if (-not $timeline.PSObject.Properties['records'] -or -not $timeline.records) { return @() }

    $records = $timeline.records

    # Build lookup by id
    $byId = @{}
    foreach ($rec in $records) {
        if ($rec.id) { $byId[$rec.id] = $rec }
    }

    # Extract stages
    $stages = @($records | Where-Object { $_.type -eq 'Stage' })
    $jobs   = @($records | Where-Object { $_.type -eq 'Job' })
    $tasks  = @($records | Where-Object { $_.type -eq 'Task' })

    $stageDetails = foreach ($stage in $stages) {
        $stageJobs = @($jobs | Where-Object { $_.parentId -eq $stage.id })
        $jobDetails = foreach ($job in $stageJobs) {
            $jobTasks = @($tasks | Where-Object { $_.parentId -eq $job.id })
            $taskDetails = foreach ($task in $jobTasks) {
                $tStart = if ($task.startTime) { $task.startTime } else { $null }
                $tEnd   = if ($task.finishTime) { $task.finishTime } else { $null }
                $tDur   = 0
                if ($tStart -and $tEnd) {
                    try { $tDur = [math]::Round(([datetime]$tEnd - [datetime]$tStart).TotalSeconds, 1) } catch { <# Intentionally suppressed — best-effort duration calculation from potentially invalid timestamps #> $null = $_ }
                }
                @{
                    Name       = if ($task.name) { $task.name } else { 'Unknown' }
                    State      = if ($task.state) { $task.state } else { 'pending' }
                    Result     = if ($task.result) { $task.result } else { '' }
                    DurationSec = $tDur
                    LogId      = if ($task.log -and $task.log.id) { $task.log.id } else { $null }
                    Issues     = if ($task.issues) { @($task.issues) } else { @() }
                }
            }
            @{
                Name  = if ($job.name) { $job.name } else { 'Unknown' }
                State = if ($job.state) { $job.state } else { 'pending' }
                Result = if ($job.result) { $job.result } else { '' }
                Tasks = @($taskDetails)
            }
        }

        $sStart = if ($stage.startTime) { $stage.startTime } else { $null }
        $sEnd   = if ($stage.finishTime) { $stage.finishTime } else { $null }
        $sDur   = 0
        if ($sStart -and $sEnd) {
            try { $sDur = [math]::Round(([datetime]$sEnd - [datetime]$sStart).TotalSeconds, 1) } catch { <# Intentionally suppressed — best-effort duration calculation from potentially invalid timestamps #> $null = $_ }
        }

        @{
            Name        = if ($stage.name) { $stage.name } else { 'Unknown' }
            State       = if ($stage.state) { $stage.state } else { 'pending' }
            Result      = if ($stage.result) { $stage.result } else { '' }
            StartTime   = $sStart
            FinishTime  = $sEnd
            DurationSec = $sDur
            Jobs        = @($jobDetails)
        }
    }

    return @($stageDetails)
}

function Get-PipelineTaskLog {
    <#
    .SYNOPSIS Retrieves the log content for a specific pipeline task.
    .DESCRIPTION
        Uses the Azure DevOps build logs API to fetch the text log output
        for a given log ID. Returns the log content as a string, or an
        error message if retrieval fails.
    .OUTPUTS Hashtable with keys: Status, Content, ErrorMessage.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$LogId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    $result = Invoke-AzCommand 'devops' 'invoke' `
        '--area' 'build' '--resource' 'logs' `
        '--route-parameters' "buildId=$RunId" "logId=$LogId" "project=$AdoProject" `
        '--org' $AdoOrgUrl '-o' 'json' `
        -TimeoutSeconds 60

    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return @{
            Status       = 'FAIL'
            Content      = ''
            ErrorMessage = "Failed to retrieve log $LogId for run ${RunId}: $($result.Output)"
        }
    }

    try {
        $logData = $result.Output | ConvertFrom-Json
        # The logs API returns an object with a 'value' array of log lines
        $content = if ($logData.value) {
            ($logData.value -join "`n")
        } elseif ($logData -is [string]) {
            $logData
        } else {
            $result.Output
        }
        return @{
            Status       = 'PASS'
            Content      = $content
            ErrorMessage = ''
        }
    } catch {
        # Raw text response — return as-is
        return @{
            Status       = 'PASS'
            Content      = $result.Output
            ErrorMessage = ''
        }
    }
}

function Format-StageProgress {
    <#
    .SYNOPSIS Formats stage details into a human-readable progress summary.
    .DESCRIPTION
        Takes the output from Get-PipelineStageDetails and produces a
        formatted string showing status icons for each stage.
    .OUTPUTS String with formatted stage progress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$StageDetails
    )

    $lines = @()
    foreach ($stage in $StageDetails) {
        $icon = switch ($stage.Result) {
            'succeeded'           { '[PASS]' }
            'succeededWithIssues' { '[WARN]' }
            'failed'              { '[FAIL]' }
            'canceled'            { '[SKIP]' }
            default {
                switch ($stage.State) {
                    'completed'  { '[DONE]' }
                    'inProgress' { '[....]' }
                    default      { '[----]' }
                }
            }
        }

        $durStr = ''
        if ($stage.DurationSec -gt 0) {
            $mins = [math]::Floor($stage.DurationSec / 60)
            $secs = [math]::Round($stage.DurationSec % 60)
            $durStr = if ($mins -gt 0) { " (${mins}m ${secs}s)" } else { " (${secs}s)" }
        }

        $lines += "    $icon $($stage.Name)$durStr"

        # Show failed tasks within the stage
        foreach ($job in $stage.Jobs) {
            foreach ($task in $job.Tasks) {
                if ($task.Result -eq 'failed') {
                    $issueMsg = if (@($task.Issues).Count -gt 0) {
                        ": " + ($task.Issues | ForEach-Object { $_.message } | Select-Object -First 1)
                    } else { '' }
                    $lines += "           X $($task.Name)$issueMsg"
                }
            }
        }
    }

    return ($lines -join "`n")
}

# ════════════════════════════════════════════════════════════
# Deployed Resources Discovery
# ════════════════════════════════════════════════════════════

function Get-DeployedResources {
    <#
    .SYNOPSIS Lists Azure resources in the target resource group.
    .DESCRIPTION
        Queries Azure Resource Manager for resources in the specified
        resource group. Returns a structured array of resource details
        for display in the deployment summary.
    .OUTPUTS Array of hashtables with keys: Name, Type, ShortType, Location, Kind, ProvisioningState.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup
    )

    $result = Invoke-AzCommand 'resource' 'list' `
        '--resource-group' $ResourceGroup '-o' 'json' `
        -TimeoutSeconds 60

    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return @()
    }

    try {
        $resources = @($result.Output | ConvertFrom-Json)
    } catch {
        Write-Warning "Failed to parse resource list JSON: $($_.Exception.Message)"
        return @()
    }

    $resources | ForEach-Object {
        @{
            Name              = if ($_.name) { $_.name } else { 'Unknown' }
            Type              = if ($_.type) { $_.type } else { 'Unknown' }
            ShortType         = if ($_.type) { ($_.type -split '/')[-1] } else { 'Unknown' }
            Location          = if ($_.location) { $_.location } else { '' }
            Kind              = if ($_.kind) { $_.kind } else { '' }
            ProvisioningState = if ($_.provisioningState) { $_.provisioningState } else { '' }
        }
    }
}

# ════════════════════════════════════════════════════════════
# Deployment Summary Formatter
# ════════════════════════════════════════════════════════════
# EV2 Rollout Monitoring (Gap D)
# ════════════════════════════════════════════════════════════

function Get-Ev2RolloutIdFromLogs {
    <#
    .SYNOPSIS Extracts the EV2 rollout ID and URL from Ev2RARollout@2 task logs.
    .DESCRIPTION
        Parses the pipeline task logs for the Ev2RARollout task to find the
        rollout ID and dashboard URL. Returns $null if not found.
    .PARAMETER RunId    Pipeline run ID.
    .PARAMETER AdoOrgUrl  ADO organization URL.
    .PARAMETER AdoProject ADO project name.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    $stageDetails = @(Get-PipelineStageDetails -RunId $RunId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject)
    foreach ($stage in $stageDetails) {
        foreach ($job in $stage.Jobs) {
            foreach ($task in $job.Tasks) {
                if ($task.Name -match 'Ev2RARollout|Ev2Rollout') {
                    # Get the task log
                    if ($task.PSObject.Properties['LogId'] -and $task.LogId) {
                        $log = Get-PipelineTaskLog -RunId $RunId -LogId $task.LogId -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
                        if ($log) {
                            # Parse rollout ID: "Rollout Id: <guid>" or "RolloutId=<guid>"
                            $rolloutIdMatch = [regex]::Match($log, 'Rollout\s*Id[=:]\s*([a-fA-F0-9-]{36})')
                            # Parse rollout URL: "https://ev2portal.azure.net/..." or similar
                            $rolloutUrlMatch = [regex]::Match($log, '(https://[^\s]+ev2[^\s]*rollout[^\s]*)')

                            if ($rolloutIdMatch.Success) {
                                return @{
                                    RolloutId  = $rolloutIdMatch.Groups[1].Value
                                    RolloutUrl = if ($rolloutUrlMatch.Success) { $rolloutUrlMatch.Groups[1].Value } else { '' }
                                    TaskName   = $task.Name
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return $null
}

function Get-Ev2RolloutStatus {
    <#
    .SYNOPSIS Queries EV2 rollout status via EV2 MCP.
    .DESCRIPTION
        Calls the EV2 MCP (Management Control Plane) to get the current rollout
        state and per-region progress. Returns a structured status object.

        NOTE: This function requires EV2 MCP tool availability. When EV2 MCP
        is not available, it returns a SKIP status with guidance.
    .PARAMETER RolloutId  EV2 rollout ID (GUID).
    .PARAMETER RolloutUrl EV2 rollout dashboard URL (optional, for user reference).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RolloutId,
        [string]$RolloutUrl = ''
    )

    # TODO: Replace with actual EV2 MCP call when available
    # Expected MCP tool: mcp_ev2_get_rollout_status
    # Expected response: { state: 'InProgress|Succeeded|Failed|RolledBack', regions: [...], error: '...' }
    Write-Warning "EV2 MCP not yet integrated — cannot poll rollout status for $RolloutId"
    return @{
        Status     = 'SKIP'
        State      = 'Unknown'
        RolloutId  = $RolloutId
        RolloutUrl = $RolloutUrl
        Regions    = @()
        Message    = 'EV2 MCP integration pending — monitor the rollout manually at the EV2 dashboard'
        Error      = ''
    }
}

function Wait-Ev2RolloutCompletion {
    <#
    .SYNOPSIS Polls EV2 rollout status until terminal state.
    .DESCRIPTION
        After the ADO pipeline succeeds for an EV2 deployment, this function
        polls the EV2 rollout status via Get-Ev2RolloutStatus until it reaches
        Succeeded, Failed, or RolledBack. Emits ##[ev2-progress] markers for
        orchestrator-driven chat updates.
    .PARAMETER RolloutId    EV2 rollout ID.
    .PARAMETER RolloutUrl   EV2 dashboard URL.
    .PARAMETER PollIntervalSec  Seconds between polls. Default 60.
    .PARAMETER TimeoutMinutes   Max minutes to wait. Default 90.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RolloutId,
        [string]$RolloutUrl = '',
        [int]$PollIntervalSec = 60,
        [int]$TimeoutMinutes  = 90
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $startTime = Get-Date
    $terminalStates = @('Succeeded', 'Failed', 'RolledBack', 'Canceled')

    while ((Get-Date) -lt $deadline) {
        $result = Get-Ev2RolloutStatus -RolloutId $RolloutId -RolloutUrl $RolloutUrl

        # If MCP not available, return SKIP immediately
        if ($result.Status -eq 'SKIP') { return $result }

        # Emit structured progress marker
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $elapsedMin = [math]::Floor($elapsed / 60)
        $elapsedSec = [math]::Round($elapsed % 60)
        $progressJson = @{
            rolloutId = $RolloutId
            state     = $result.State
            elapsed   = "${elapsedMin}m ${elapsedSec}s"
            regions   = $result.Regions
        } | ConvertTo-Json -Compress
        Write-Output "##[ev2-progress]$progressJson" | Out-Host

        if ($result.State -in $terminalStates) {
            return $result
        }

        Write-Output "  EV2 rollout $RolloutId is $($result.State) — checking again in ${PollIntervalSec}s..." | Out-Host
        Start-Sleep -Seconds $PollIntervalSec
    }

    return @{
        Status     = 'FAIL'
        State      = 'Timeout'
        RolloutId  = $RolloutId
        RolloutUrl = $RolloutUrl
        Regions    = @()
        Message    = "EV2 rollout did not complete within $TimeoutMinutes minutes"
        Error      = 'Timeout'
    }
}

# ════════════════════════════════════════════════════════════

function Format-DeploymentSummary {
    <#
    .SYNOPSIS Produces a structured deployment summary with stage details, tasks, and resources.
    .DESCRIPTION
        Combines pipeline stage details (with per-task breakdown), deployed
        Azure resources, and post-deployment check results into a formatted
        summary string suitable for terminal and agent display.
    .OUTPUTS String with the formatted deployment summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$StageDetails,
        [array]$DeployedResources = @(),
        [array]$CheckResults = @(),
        [string]$PipelineName = '',
        [string]$RunId = '',
        [string]$BranchName = '',
        [string]$AppUrl = '',
        [string]$PipelineRunUrl = '',
        [int]$Attempt = 1,
        [string]$InfraDeployMethod = '',
        [string]$Ev2ServiceConnection = '',
        [string]$ServiceConnectionName = '',
        [string]$AdoOrgUrl = '',
        [string]$AdoProject = '',
        [string]$ResourceGroup = '',
        [string]$SubscriptionId = ''
    )

    $lines = [System.Collections.ArrayList]::new()
    $null = $lines.Add('')
    $null = $lines.Add('  ╔═══════════════════════════════════════════════════════════════╗')
    $null = $lines.Add('  ║                    DEPLOYMENT SUMMARY                         ║')
    $null = $lines.Add('  ╚═══════════════════════════════════════════════════════════════╝')
    $null = $lines.Add('')

    # ── Pipeline Info ──
    if ($PipelineName) { $null = $lines.Add("  Pipeline     : $PipelineName") }
    if ($RunId)        { $null = $lines.Add("  Run ID       : $RunId") }
    if ($BranchName)   { $null = $lines.Add("  Branch       : $BranchName") }
    if ($Attempt -gt 1) { $null = $lines.Add("  Attempt      : $Attempt") }

    # ── Deployment Method ──
    if ($InfraDeployMethod) {
        $null = $lines.Add("  Infra Method : $InfraDeployMethod")
    }
    if ($ServiceConnectionName) {
        $null = $lines.Add("  ARM SC       : $ServiceConnectionName")
    }
    if ($Ev2ServiceConnection) {
        $null = $lines.Add("  EV2 SC       : $Ev2ServiceConnection")
    }

    # ── Total Duration ──
    $totalDur = 0
    foreach ($stage in $StageDetails) {
        $totalDur += $stage.DurationSec
    }
    $totalMin = [math]::Floor($totalDur / 60)
    $totalSec = [math]::Round($totalDur % 60)
    $null = $lines.Add("  Total Duration: ${totalMin}m ${totalSec}s")
    $null = $lines.Add('')

    # ── Stage Overview with Task Breakdown ──
    $null = $lines.Add('  ── Stage Results ──────────────────────────────────────────')
    $null = $lines.Add('')

    foreach ($stage in $StageDetails) {
        $icon = switch ($stage.Result) {
            'succeeded'           { '[PASS]' }
            'succeededWithIssues' { '[WARN]' }
            'failed'              { '[FAIL]' }
            'canceled'            { '[SKIP]' }
            default {
                switch ($stage.State) {
                    'completed'  { '[DONE]' }
                    'inProgress' { '[....]' }
                    default      { '[----]' }
                }
            }
        }

        $durStr = ''
        if ($stage.DurationSec -gt 0) {
            $mins = [math]::Floor($stage.DurationSec / 60)
            $secs = [math]::Round($stage.DurationSec % 60)
            $durStr = if ($mins -gt 0) { " (${mins}m ${secs}s)" } else { " (${secs}s)" }
        }

        # Count tasks
        $totalTasks = 0
        $passedTasks = 0
        foreach ($job in $stage.Jobs) {
            foreach ($task in $job.Tasks) {
                $totalTasks++
                if ($task.Result -in @('succeeded', '')) { $passedTasks++ }
            }
        }
        $taskSummary = if ($totalTasks -gt 0) { " [$passedTasks/$totalTasks tasks]" } else { '' }

        $null = $lines.Add("    $icon $($stage.Name)$durStr$taskSummary")

        # Show all tasks within the stage
        foreach ($job in $stage.Jobs) {
            foreach ($task in $job.Tasks) {
                $taskIcon = switch ($task.Result) {
                    'succeeded' { '✓' }
                    'failed'    { '✗' }
                    'skipped'   { '○' }
                    default     { '·' }
                }
                $tDurStr = ''
                if ($task.DurationSec -gt 0) {
                    $tMins = [math]::Floor($task.DurationSec / 60)
                    $tSecs = [math]::Round($task.DurationSec % 60)
                    $tDurStr = if ($tMins -gt 0) { " ${tMins}m ${tSecs}s" } else { " ${tSecs}s" }
                }
                $issueStr = ''
                if ($task.Result -eq 'failed' -and @($task.Issues).Count -gt 0) {
                    $issueStr = ": " + ($task.Issues | ForEach-Object { $_.message } | Select-Object -First 1)
                }
                $null = $lines.Add("         $taskIcon $($task.Name)$tDurStr$issueStr")
            }
        }
        $null = $lines.Add('')
    }

    # ── Deployed Resources ──
    if ($DeployedResources.Count -gt 0) {
        $null = $lines.Add('  ── Deployed Resources ─────────────────────────────────────')
        $null = $lines.Add('')

        # Group by resource type for cleaner display
        $grouped = $DeployedResources | Group-Object -Property { $_['Type'] }
        foreach ($group in ($grouped | Sort-Object Name)) {
            $shortType = ($group.Name -split '/')[-1]
            foreach ($res in $group.Group) {
                $state = if ($res.ProvisioningState -eq 'Succeeded') { '✓' }
                         elseif ($res.ProvisioningState -eq 'Failed') { '✗' }
                         else { '·' }
                $kindStr = if ($res.Kind) { " ($($res.Kind))" } else { '' }
                $null = $lines.Add("    $state $($res.Name)  [$shortType]  $($res.Location)$kindStr")
            }
        }
        $null = $lines.Add('')
    }

    # ── Post-Deployment Checks ──
    if ($CheckResults.Count -gt 0) {
        $null = $lines.Add('  ── Post-Deployment Checks ────────────────────────────────')
        $null = $lines.Add('')
        foreach ($check in $CheckResults) {
            $chkIcon = switch ($check.Status) {
                'PASS' { '✅' }
                'FAIL' { '❌' }
                'WARN' { '⚠️' }
                'SKIP' { '⏭️' }
                default { '·' }
            }
            $null = $lines.Add("    $chkIcon $($check.Name): $($check.Message)")
        }
        $null = $lines.Add('')
    }

    # ── Links ──
    $null = $lines.Add('  ── Links ─────────────────────────────────────────────────')
    if ($AppUrl)         { $null = $lines.Add("    App URL      : $AppUrl") }
    if ($AppUrl -match 'https?://([^./]+)\.azurewebsites\.net') {
        $null = $lines.Add("    Kudu/SCM     : https://$($Matches[1]).scm.azurewebsites.net")
    }
    if ($PipelineRunUrl) { $null = $lines.Add("    Build Log    : $PipelineRunUrl") }
    if ($ResourceGroup -and $SubscriptionId) {
        $null = $lines.Add("    Resource Group: https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview")
    }
    if ($AdoOrgUrl -and $AdoProject) {
        $null = $lines.Add("    ADO Pipelines: $AdoOrgUrl/$AdoProject/_build")
        $null = $lines.Add("    Service Conns : $AdoOrgUrl/$AdoProject/_settings/adminservices")
    }
    $null = $lines.Add("    SARIF Report : .vibeshield/results/deploy-monitor-results.sarif")
    $null = $lines.Add('')

    return ($lines -join "`n")
}

function Get-FailureClassification {
    <#
    .SYNOPSIS Classifies a pipeline failure from the run timeline.
    .DESCRIPTION
        Retrieves the run timeline and inspects failed tasks to classify
        the failure type. Returns a hashtable with classification, stage,
        and error details.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    # Get timeline (stages/jobs/tasks)
    # Also add timeout on the classification timeline call
    $result = Invoke-AzCommand 'devops' 'invoke' `
        '--area' 'build' '--resource' 'timeline' `
        '--route-parameters' "buildId=$RunId" "project=$AdoProject" `
        '--org' $AdoOrgUrl '-o' 'json' `
        -TimeoutSeconds 60

    $failedTasks = @()
    $failStage   = 'Unknown'
    $errorMsg    = ''

    if ($result.ExitCode -eq 0 -and $result.Output) {
        try {
            $timeline = $result.Output | ConvertFrom-Json
            if ($timeline.records) {
                $failedTasks = @($timeline.records | Where-Object {
                    $_.result -eq 'failed' -and $_.type -eq 'Task'
                })
                $failedStages = @($timeline.records | Where-Object {
                    $_.result -eq 'failed' -and $_.type -eq 'Stage'
                })
                if ($failedStages.Count -gt 0) {
                    $failStage = $failedStages[0].name
                }
                if ($failedTasks.Count -gt 0) {
                    $errorMsg = if ($failedTasks[0].issues) {
                        ($failedTasks[0].issues | ForEach-Object { $_.message }) -join '; '
                    } else {
                        $failedTasks[0].name + ' failed'
                    }
                }

                # Detect SKIPPED stages when no failed tasks are found
                if (-not $errorMsg -and $failedStages.Count -eq 0) {
                    $skippedStages = @($timeline.records | Where-Object {
                        $_.type -eq 'Stage' -and $_.result -eq 'skipped'
                    })
                    if ($skippedStages.Count -gt 0) {
                        $skippedNames = ($skippedStages | ForEach-Object { $_.name }) -join ', '
                        $errorMsg = "Stage(s) skipped: $skippedNames — pipeline completed without executing all stages"
                        $failStage = $skippedStages[0].name
                    }
                }
            }
        } catch { <# Intentionally suppressed — best-effort error classification from pipeline stage/task details #> $null = $_ }
    }

    # If we still have no error message, produce a descriptive fallback
    if (-not $errorMsg) {
        $errorMsg = 'No failed tasks or error messages found in pipeline timeline — manual log investigation required'
    }

    # Classify based on error message patterns (ordered from most specific to least)
    $classification = 'Unknown'
    $lowerMsg = $errorMsg.ToLower()

    if ($lowerMsg -match 'credscan|policheck|component governance|compliance') {
        $classification = 'Compliance'
    } elseif ($lowerMsg -match 'ev2rarollout|ev2rollout|servicegrouproot|rolloutspec|servicemodel.*error|ob_release_environment|ob_release_servicetreeid|subscription.*not registered.*ev2|ev2.*subscription.*not.*registered') {
        if ($lowerMsg -match 'cn-ev2deploy.*not found|ev2endpoint.*not found|ev2.*service connection.*not found') {
            $classification = 'EV2-Auth'
        } elseif ($lowerMsg -match 'subscription.*not registered|not.*registered.*subscription') {
            $classification = 'EV2-Auth'
        } else {
            $classification = 'EV2'
        }
    } elseif ($lowerMsg -match 'service connection|aadsts|authorization|not authorized|waiting for authorization|resource authorization') {
        if ($lowerMsg -match 'waiting for authorization|resource authorization|not authorized to use|pipeline not authorized') {
            $classification = 'SC Authorization Pending'
        } elseif ($lowerMsg -match 'could not (find|resolve) service connection') {
            $classification = 'SC Authorization Pending'
        } else {
            $classification = 'Authentication'
        }
    } elseif ($lowerMsg -match 'resourcenotfound|deployment failed|provision|bicep|arm template|infrastructure') {
        if ($lowerMsg -match 'bicep|arm template|infrastructure') {
            $classification = 'Bicep/Infrastructure'
        } else {
            $classification = 'Deployment'
        }
    } elseif ($lowerMsg -match 'msbuild|npm err|modulenotfounderror|build failure|error ts|compilation|dotnet|maven|gradle|test fail') {
        $classification = 'Build'
    } elseif ($lowerMsg -match 'process\.exit|module_not_found|cannot find module|error:\s*missing|application error|503.*application.*error|503.*stopped') {
        $classification = 'StartupCrash'
    } else {
        $classification = 'Unknown'
    }

    # ── Upstream causation check ─────────────────────────────
    # If a Build failure occurred, check if Provision stage also failed —
    # the build failure may be a cascade from missing infrastructure.
    $upstreamCause = $null
    if ($classification -eq 'Build') {
        $provisionFailed = @($failedStages | Where-Object { $_.name -match 'Provision|Infrastructure' })
        if ($provisionFailed.Count -gt 0) {
            $upstreamCause = "Provision stage also failed — build failure may be caused by missing infrastructure (cascade)"
            $classification = 'Bicep/Infrastructure'  # Reclassify to upstream cause
        }
    }
    # If a Deployment failure occurred, check if Build stage failed —
    # deployment might have used stale artifacts.
    if ($classification -eq 'Deployment') {
        $buildFailed = @($failedStages | Where-Object { $_.name -match 'Build' })
        if ($buildFailed.Count -gt 0) {
            $upstreamCause = "Build stage also failed — deployment failure may be caused by build issues (cascade)"
        }
    }

    # Determine retryability
    $nonRetryable = @('StartupCrash', 'Build', 'Bicep/Infrastructure', 'PipelineYaml', 'Compliance')
    $isRetryable = $classification -notin $nonRetryable

    return @{
        Classification = $classification
        Stage          = $failStage
        ErrorMessage   = $errorMsg
        FailedTasks    = $failedTasks
        UpstreamCause  = $upstreamCause
        IsRetryable    = $isRetryable
    }
}

function Get-ArmErrorFixSuggestion {
    <#
    .SYNOPSIS Parses ARM deployment error messages and returns structured fix suggestions (IL-8).
    .PARAMETER ErrorMessage  The ARM error message string from pipeline logs.
    .OUTPUTS PSCustomObject with Code, Suggestion, AutoFixable, RawError.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ErrorMessage)

    $lowerMsg = $ErrorMessage.ToLower()

    # Known ARM error patterns → fix suggestions
    $patterns = @(
        @{
            Pattern     = 'skunotavailable|skucode.*invalid|sku.*not.*valid'
            Code        = 'SkuNotAvailable'
            Suggestion  = 'Change the SKU in Bicep parameters. Common: SWA linked backends require Standard SKU (not Free).'
            AutoFixable = $true
        },
        @{
            Pattern     = 'regiondoesnotallowprovisioning|location.*not.*available'
            Code        = 'RegionRestricted'
            Suggestion  = 'Change the location parameter. Do not rely on resourceGroup().location — set explicitly.'
            AutoFixable = $true
        },
        @{
            Pattern     = 'linkedauthorizationfailed|authorization.*failed|roleassignment.*denied'
            Code        = 'RBACMissing'
            Suggestion  = 'Add a roleAssignment ARM template for the managed identity on the target resource.'
            AutoFixable = $true
        },
        @{
            Pattern     = 'quotaexceeded|exceeds.*quota|subscription.*limit'
            Code        = 'QuotaExceeded'
            Suggestion  = 'Request a quota increase or choose a different SKU/region.'
            AutoFixable = $false
        },
        @{
            Pattern     = 'resourcenotfound|resource.*not.*found|does not exist'
            Code        = 'ResourceNotFound'
            Suggestion  = 'The dependent resource does not exist. Check deployment order — deploy dependencies before this resource.'
            AutoFixable = $true
        },
        @{
            Pattern     = 'conflictingserveroperation|conflicting.*operation|resource.*already.*exists'
            Code        = 'ResourceConflict'
            Suggestion  = 'Resource already exists. Use incremental deployment mode or check for name collisions.'
            AutoFixable = $false
        },
        @{
            Pattern     = 'invalidtemplate|template.*error|invalid.*parameter'
            Code        = 'TemplateError'
            Suggestion  = 'Fix the ARM/Bicep template syntax. Run az deployment group validate locally first.'
            AutoFixable = $true
        }
    )

    foreach ($p in $patterns) {
        if ($lowerMsg -match $p.Pattern) {
            return [PSCustomObject]@{
                Code        = $p.Code
                Suggestion  = $p.Suggestion
                AutoFixable = $p.AutoFixable
                RawError    = $ErrorMessage
            }
        }
    }

    return [PSCustomObject]@{
        Code        = 'Unknown'
        Suggestion  = 'Unrecognized ARM error. Check the deployment operation details in Azure Portal.'
        AutoFixable = $false
        RawError    = $ErrorMessage
    }
}

# ════════════════════════════════════════════════════════════
# Retry — Re-trigger pipeline
# ════════════════════════════════════════════════════════════

function Invoke-PipelineRetry {
    <#
    .SYNOPSIS Re-triggers a pipeline run from the specified branch.
    .OUTPUTS Hashtable with Status, Message, and new RunId.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PipelineName', Justification='Used inside Invoke-WithRetry scriptblock; PSScriptAnalyzer cannot detect cross-scope usage')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AdoOrgUrl', Justification='Used inside Invoke-WithRetry scriptblock; PSScriptAnalyzer cannot detect cross-scope usage')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AdoProject', Justification='Used inside Invoke-WithRetry scriptblock; PSScriptAnalyzer cannot detect cross-scope usage')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipelineName,
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    # Use retry wrapper for transient ADO failures (503, 429, timeout)
    $retryResult = $null
    try {
        $retryResult = Invoke-WithRetry -ScriptBlock {
            $r = Invoke-AzCommand 'pipelines' 'run' `
                '--name' $PipelineName '--branch' $BranchName `
                '--org' $AdoOrgUrl '--project' $AdoProject '-o' 'json' `
                -TimeoutSeconds 60
            if ($r.ExitCode -ne 0 -and $r.Output -match '503|429|timed out|throttl') { throw $r.Output }
            $r
        } -MaxRetries ((Get-DeployConfig).monitor.maxRetries)
    } catch {
        $retryResult = [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 1 }
    }

    if ($retryResult.ExitCode -eq 0 -and $retryResult.Output) {
        try {
            $run = $retryResult.Output | ConvertFrom-Json
            if ($run.id -and $run.state -in @('inProgress', 'notStarted', 'queued')) {
                return @{
                    Status  = 'PASS'
                    Message = "Re-triggered pipeline run $($run.id) from branch $BranchName (state: $($run.state))"
                    RunId   = "$($run.id)"
                }
            } elseif ($run.id) {
                Write-Warning "Pipeline run $($run.id) triggered but in unexpected state: $($run.state)"
                return @{
                    Status  = 'PASS'
                    Message = "Re-triggered pipeline run $($run.id) from branch $BranchName (state: $($run.state))"
                    RunId   = "$($run.id)"
                }
            }
        } catch {
            Write-Warning "Failed to parse pipeline retry JSON: $($_.Exception.Message)"
        }
    }

    return @{
        Status  = 'FAIL'
        Message = "Failed to re-trigger pipeline: $($retryResult.Output)"
        RunId   = ''
        Fix     = 'Check pipeline name and branch; verify az login status.'
    }
}
