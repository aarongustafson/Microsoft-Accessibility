#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Manages the deploy-state.json state file for deployment resume support.

.DESCRIPTION
    Provides Read, Write, Validate, and Delete operations on the
    .vibeshield/deploy-state.json state file. Implements the resume protocol
    from deploy-resume-protocol.prompt.md including staleness detection.

    Never stores secrets, tokens, or passwords in the state file.

.PARAMETER Action
    The operation to perform: Read, Write, Validate, Delete.

.PARAMETER WorkspacePath
    Path to the workspace root. Defaults to current directory.

.PARAMETER State
    Hashtable of state values to write. Required for Write action (unless -StateJson is used).
    Expected keys: LastCompletedStage,
    PipelineYamlPath, BranchName,
    PipelineName, RunId, PipelineId, LoopBackCount, LastLoopBackError.
    NOTE: AdoOrgUrl and AdoProject belong in project-config.json (git-tracked).
    NOTE: AppName, ResourceGroup, Email, ServiceConnection, AppType,
    and TargetAzureService belong in infra/config.ps1 (git-tracked)
    and must NOT be stored here.

.PARAMETER StateJson
    JSON string alternative to -State. Parsed into a hashtable internally.
    Use when calling from a terminal where passing hashtables is inconvenient.

.EXAMPLE
    # Read state
    ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Read

    # Write state after Stage 1
    $state = @{ LastCompletedStage = 1; AppType = 'Node.js'; ... }
    ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Write -State $state

    # Validate existing state
    ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Validate

    # Delete state (on completion or restart)
    ./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 -Action Delete
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Read','Write','Validate','Delete')][string]$Action,
    [string]$WorkspacePath = $PWD.Path,
    [hashtable]$State,
    [string]$StateJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Accept -StateJson as alternative to -State ──────────────
if (-not $State -and $StateJson) {
    try {
        $parsed = $StateJson | ConvertFrom-Json -ErrorAction Stop
        $State = @{}
        foreach ($prop in $parsed.PSObject.Properties) {
            $State[$prop.Name] = $prop.Value
        }
    } catch {
        Write-Error "Failed to parse -StateJson: $($_.Exception.Message)"
        $global:LASTEXITCODE = 1
        exit 1
    }
}

# ── Load shared helpers ─────────────────────────────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

# ── State file path (from config with fallback) ─────────────
$stateFilePath = Get-StateFilePath -WorkspacePath $WorkspacePath
$requiredFields = @('LastCompletedStage', 'Timestamp')

$stageNames = @{
    0 = 'None'
    1 = 'Readiness Check'
    2 = 'Pipeline Setup'
    3 = 'Code Push'
    4 = 'Monitor & Verify'
}

# ════════════════════════════════════════════════════════════
# READ
# ════════════════════════════════════════════════════════════

if ($Action -eq 'Read') {
    # Clean up orphaned .tmp files from interrupted writes
    $tmpFile = "$stateFilePath.tmp"
    if (Test-Path $tmpFile) {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Verbose "  Cleaned orphaned temp file: $tmpFile"
    }

    if (-not (Test-Path $stateFilePath)) {
        [pscustomobject]@{
            Found             = $false
            State             = $null
            LastCompletedStage = 0
            StageName         = 'None'
            NextStage         = 1
            Message           = 'No state file found — fresh deployment'
        }
        $global:LASTEXITCODE = 0
        exit 0
    }

    try {
        $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "State file is corrupt — cannot parse JSON"
        [pscustomobject]@{
            Found             = $false
            State             = $null
            LastCompletedStage = 0
            StageName         = 'None'
            NextStage         = 1
            Message           = 'State file is corrupt — starting fresh'
        }
        $global:LASTEXITCODE = 0
        exit 0
    }

    # ── HMAC verification (tamper detection) ────────────────
    if ($stateObj.PSObject.Properties['_hmac'] -and $stateObj._hmac) {
        $storedHmac = $stateObj._hmac
        # Reconstruct state without _hmac for verification
        $verifyState = @{}
        foreach ($prop in $stateObj.PSObject.Properties) {
            if ($prop.Name -ne '_hmac') { $verifyState[$prop.Name] = $prop.Value }
        }
        $verifyJson = $verifyState | ConvertTo-Json -Depth 5
        $hmacKey = [System.Text.Encoding]::UTF8.GetBytes("vsd-state-$WorkspacePath")
        $hmac = [System.Security.Cryptography.HMACSHA256]::new($hmacKey)
        $computedHmac = ($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($verifyJson)) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        $hmac.Dispose()
        if ($computedHmac -ne $storedHmac) {
            Write-Warning "State file HMAC mismatch — file may have been tampered with. Starting fresh."
            [pscustomobject]@{
                Found             = $false
                State             = $null
                LastCompletedStage = 0
                StageName         = 'None'
                NextStage         = 1
                Message           = 'State file HMAC mismatch — tamper detected, starting fresh'
            }
            $global:LASTEXITCODE = 0
            exit 0
        }
    }

    # ── Schema validation ───────────────────────────────────
    # Validate required fields exist and have expected types
    if (-not $stateObj.PSObject.Properties['LastCompletedStage']) {
        Write-Warning "State file missing required field: LastCompletedStage — starting fresh"
        [pscustomobject]@{ Found = $false; State = $null; LastCompletedStage = 0; StageName = 'None'; NextStage = 1; Message = 'State file invalid (missing LastCompletedStage) — starting fresh' }
        $global:LASTEXITCODE = 0
        exit 0
    }
    $stageVal = $stateObj.LastCompletedStage
    if ($stageVal -notin @(0,1,2,3,4)) {
        Write-Warning "State file has invalid LastCompletedStage value: $stageVal — starting fresh"
        [pscustomobject]@{ Found = $false; State = $null; LastCompletedStage = 0; StageName = 'None'; NextStage = 1; Message = "State file invalid (LastCompletedStage=$stageVal) — starting fresh" }
        $global:LASTEXITCODE = 0
        exit 0
    }
    # Validate SubStep if present
    $validSubSteps = @('yaml-generated', 'pushed', 'registered', 'triggered', 'polling', 'failed', $null)
    if ($stateObj.PSObject.Properties['SubStep'] -and $stateObj.SubStep -and $stateObj.SubStep -notin $validSubSteps) {
        Write-Warning "State file has unknown SubStep '$($stateObj.SubStep)' — ignoring SubStep, running full stage"
        $stateObj.SubStep = $null
    }

    $lastStage = if ($stateObj.PSObject.Properties['LastCompletedStage']) { [int]$stateObj.LastCompletedStage } else { 0 }
    $nextStage = [Math]::Min($lastStage + 1, 4)
    $stageName = if ($stageNames.ContainsKey($lastStage)) { $stageNames[$lastStage] } else { "Stage $lastStage" }
    $subStep = if ($stateObj.PSObject.Properties['SubStep']) { $stateObj.SubStep } else { $null }

    $message = "Resuming from Stage $nextStage (last completed: Stage $lastStage - $stageName)"
    if ($subStep) { $message += " [sub-step: $subStep]" }

    [pscustomobject]@{
        Found             = $true
        State             = $stateObj
        LastCompletedStage = $lastStage
        SubStep           = $subStep
        StageName         = $stageName
        NextStage         = $nextStage
        Message           = $message
    }
    $global:LASTEXITCODE = 0
    exit 0
}

# ════════════════════════════════════════════════════════════
# WRITE
# ════════════════════════════════════════════════════════════

if ($Action -eq 'Write') {
    if (-not $State) {
        Write-Error '-State parameter is required for Write action'
        $global:LASTEXITCODE = 1
        exit 1
    }

    # Ensure timestamp is always set
    if (-not $State.ContainsKey('Timestamp')) {
        $State['Timestamp'] = (Get-Date -Format 'o')
    }

    # ── Write-time schema validation (#16) ──────────────────
    if ($State.ContainsKey('LastCompletedStage')) {
        $stageVal = $State['LastCompletedStage']
        if ($stageVal -notin @(0, 1, 2, 3, 4)) {
            Write-Warning "Write rejected: LastCompletedStage '$stageVal' is not in [0-4]. Clamping to 0."
            $State['LastCompletedStage'] = 0
        }
    }
    if ($State.ContainsKey('SubStep') -and $State['SubStep']) {
        $validSubSteps = @('yaml-generated', 'pushed', 'registered', 'triggered', 'polling', 'failed')
        if ($State['SubStep'] -notin $validSubSteps) {
            Write-Warning "Write: unknown SubStep '$($State['SubStep'])'. Clearing to null."
            $State['SubStep'] = $null
        }
    }
    if ($State.ContainsKey('LoopBackCount') -and $State['LoopBackCount'] -lt 0) {
        $State['LoopBackCount'] = 0
    }

    # Ensure schema version is always set (for resume compatibility across updates)
    $State['SchemaVersion'] = 2

    # Ensure .vibeshield directory exists
    $vibeshieldDir = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield'
    if (-not (Test-Path $vibeshieldDir)) {
        New-Item -Path $vibeshieldDir -ItemType Directory -Force | Out-Null
    }

    # Ensure LoopBackCount defaults to 0 if not set
    if (-not $State.ContainsKey('LoopBackCount')) {
        $State['LoopBackCount'] = 0
    }

    # Ensure WorkspacePathHash is set for resume validation
    if (-not $State.ContainsKey('WorkspacePathHash')) {
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($WorkspacePath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $State['WorkspacePathHash'] = ($sha.ComputeHash($hashBytes) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        $sha.Dispose()
    }

    # NOTE: Preferences are no longer stored in the state file.
    # The preference profile is persisted in .vibeshield/project-config.json
    # under the 'preferenceProfile' key. See config-architecture.md §7.
    # Legacy: if existing state has a 'Preferences' field, it is NOT carried forward.
    # Remove any stale Preferences from the state being written.
    if ($State.ContainsKey('Preferences')) {
        $State.Remove('Preferences')
    }

    # Atomic write with exclusive file lock to prevent concurrent corruption
    $tmpPath = "$stateFilePath.tmp"

    # Compute HMAC for tamper detection (key derived from workspace path)
    $hmacKey = [System.Text.Encoding]::UTF8.GetBytes("vsd-state-$WorkspacePath")
    $State.Remove('_hmac')  # remove stale HMAC before computing
    $stateForHmac = $State | ConvertTo-Json -Depth 5
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($hmacKey)
    $State['_hmac'] = ($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stateForHmac)) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
    $hmac.Dispose()

    $jsonContent = $State | ConvertTo-Json -Depth 5
    try {
        # Write to temp file with exclusive lock
        $fs = [System.IO.FileStream]::new(
            $tmpPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
        $writer.Write($jsonContent)
        $writer.Flush()
        $writer.Close()
        $fs.Close()
    } catch {
        # Clean up on failure
        if ($writer) { try { $writer.Dispose() } catch { <# ignore dispose failure #> $null = $_ } }
        if ($fs) { try { $fs.Dispose() } catch { <# ignore dispose failure #> $null = $_ } }
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue }
        Write-Error "Failed to write state file: $_"
        $global:LASTEXITCODE = 1
        exit 1
    }
    Move-Item -Path $tmpPath -Destination $stateFilePath -Force

    # Ensure .gitignore excludes the state file
    # NOTE: This read-then-write is not locked, but the worst-case race is a
    # duplicate .gitignore entry which is harmless.
    $gitignorePath = Join-Path -Path $WorkspacePath -ChildPath '.gitignore'
    $stateRelPath  = Get-ConfigPath -Key 'stateFile' -Default '.vibeshield/deploy-state.json'
    try {
        if (Test-Path $gitignorePath) {
            $gitignoreContent = Get-Content $gitignorePath -Raw
            if ($gitignoreContent -notmatch [regex]::Escape($stateRelPath)) {
                Add-Content -Path $gitignorePath -Value "`n$stateRelPath" -Encoding utf8
                Write-Output "  Added $stateRelPath to .gitignore" | Out-Host
            }
        } else {
            Set-Content -Path $gitignorePath -Value $stateRelPath -Encoding UTF8
            Write-Output "  Created .gitignore with $stateRelPath" | Out-Host
        }
    } catch {
        Write-Warning "Failed to update .gitignore: $_"
    }

    $lastStage = if ($State.ContainsKey('LastCompletedStage')) { $State['LastCompletedStage'] } else { 0 }
    Write-Output "  State saved: LastCompletedStage=$lastStage at $($State['Timestamp'])" | Out-Host

    [pscustomobject]@{
        Written   = $true
        Path      = $stateFilePath
        Timestamp = $State['Timestamp']
    }
    $global:LASTEXITCODE = 0
    exit 0
}

# ════════════════════════════════════════════════════════════
# VALIDATE
# ════════════════════════════════════════════════════════════

if ($Action -eq 'Validate') {
    if (-not (Test-Path $stateFilePath)) {
        [pscustomobject]@{
            Valid    = $false
            Stale    = $false
            Issues   = @('State file not found')
            Recommendation = 'Start fresh at Stage 1'
        }
        $global:LASTEXITCODE = 0
        exit 0
    }

    try {
        $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
    } catch {
        [pscustomobject]@{
            Valid    = $false
            Stale    = $false
            Issues   = @('State file is corrupt — cannot parse JSON')
            Recommendation = 'Delete state file and start fresh'
        }
        $global:LASTEXITCODE = 0
        exit 0
    }

    $issues = @()

    # Check required fields
    $missingFields = $requiredFields | Where-Object {
        -not $stateObj.PSObject.Properties[$_] -or [string]::IsNullOrWhiteSpace($stateObj.$_)
    }
    if (@($missingFields).Count -gt 0) {
        $issues += "Missing required fields: $($missingFields -join ', ')"
    }

    # Schema version check (v2 = Phase 3 restructured stages)
    $schemaVer = if ($stateObj.PSObject.Properties['SchemaVersion']) { $stateObj.SchemaVersion } else { 1 }
    if ($schemaVer -lt 2) {
        $issues += "State file uses schema v$schemaVer (current: v2) — stage assignments may differ. Consider starting fresh."
    }

    # Workspace path hash mismatch — state was created in a different workspace
    if ($stateObj.PSObject.Properties['WorkspacePathHash'] -and $stateObj.WorkspacePathHash) {
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($WorkspacePath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $currentHash = ($sha.ComputeHash($hashBytes) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        $sha.Dispose()
        if ($currentHash -ne $stateObj.WorkspacePathHash) {
            $issues += "State file was created in a different workspace — workspace path hash mismatch. Starting fresh is recommended."
        }
    }

    # Staleness: older than configured threshold (default 8 hours)
    $isStale = $false
    $stalenessHours = 8
    try {
        $cfgObj = Get-DeployConfig
        if ($cfgObj.monitor.PSObject.Properties['stalenessHours']) {
            $stalenessHours = $cfgObj.monitor.stalenessHours
        }
    } catch { <# use default #> $null = $_ }
    if ($stateObj.PSObject.Properties['Timestamp']) {
        try {
            $stateTime = [datetime]$stateObj.Timestamp
            $age = (Get-Date) - $stateTime
            if ($age.TotalHours -gt $stalenessHours) {
                $isStale = $true
                $issues += "State file is $([math]::Round($age.TotalHours, 1)) hours old (threshold: $($stalenessHours)h)"
            }
        } catch {
            $issues += 'Timestamp field is not a valid datetime'
        }
    }

    # StageCheckResults staleness: discard per-stage results older than configured threshold
    if ($stateObj.PSObject.Properties['StageCheckResults'] -and $stateObj.StageCheckResults) {
        foreach ($stageProp in $stateObj.StageCheckResults.PSObject.Properties) {
            $stageData = $stageProp.Value
            if ($stageData.PSObject.Properties['Timestamp']) {
                try {
                    $checkAge = (Get-Date) - [datetime]$stageData.Timestamp
                    if ($checkAge.TotalHours -gt $stalenessHours) {
                        $issues += "Stage $($stageProp.Name) check results are $([math]::Round($checkAge.TotalHours, 1)) hours old — will be ignored on resume"
                    }
                } catch {
                    $issues += "Stage $($stageProp.Name) check results have invalid Timestamp"
                }
            }
        }
    }

    # App type changed (read from config.ps1, not state)
    if ($stateObj.PSObject.Properties['AppType']) {
        $currentAppType = if (Get-Command Get-AppType -ErrorAction SilentlyContinue) {
            $det = Get-AppType -Path $WorkspacePath -WorkspacePath $WorkspacePath
            if ($det) { $det.AppType } else { 'Unknown' }
        } else { 'Unknown' }
        if ($currentAppType -ne $stateObj.AppType -and $currentAppType -ne 'Unknown') {
            $issues += "App type changed: was '$($stateObj.AppType)', now '$currentAppType'"
        }
    }

    # Resource group still exists (read from config.ps1, not state)
    $configPath = Join-Path -Path $WorkspacePath -ChildPath 'infra/config.ps1'
    if (Test-Path $configPath) {
        $configSafety = if (Get-Command Test-ConfigFileSafe -ErrorAction SilentlyContinue) {
            Test-ConfigFileSafe -ConfigPath $configPath
        } else { [pscustomobject]@{ Safe = $true; Issues = @() } }
        if (-not $configSafety.Safe) {
            $issues += "Unsafe infra/config.ps1: $($configSafety.Issues -join '; ')"
        } else {
        try {
            $Config = $null
            . $configPath
            if ($Config -is [hashtable] -and $Config.ContainsKey('ResourceGroup') -and
                -not [string]::IsNullOrWhiteSpace($Config['ResourceGroup'])) {
                $rgCheck = Invoke-AzCommand 'group', 'exists', '--name', $Config['ResourceGroup']
                if ($rgCheck.ExitCode -eq 0 -and $rgCheck.Output -match 'false') {
                    $issues += "Resource group '$($Config['ResourceGroup'])' no longer exists"
                }
            }
        } catch {
            Write-Verbose "Could not check resource group from config.ps1: $_"
        }
        } # end else (config is safe)
    }

    # Branch mismatch (informational)
    if ($stateObj.PSObject.Properties['BranchName']) {
        $gitBranch = Invoke-GitCommand 'branch', '--show-current'
        if ($gitBranch.ExitCode -eq 0 -and $gitBranch.Output -and $gitBranch.Output -ne $stateObj.BranchName) {
            $issues += "Branch changed: was '$($stateObj.BranchName)', now '$($gitBranch.Output)' (informational)"
        }
    }

    # Pipeline run still exists (critical for Stage 4 resume)
    # AdoOrgUrl/AdoProject come from project-config.json, not state
    $projCfg = Get-ProjectConfig -WorkspacePath $WorkspacePath
    $pOrgUrl = if ($projCfg) { $projCfg.adoOrgUrl } else { $null }
    $pProject = if ($projCfg) { $projCfg.adoProject } else { $null }
    if ($stateObj.PSObject.Properties['RunId'] -and
        -not [string]::IsNullOrWhiteSpace($stateObj.RunId) -and
        $pOrgUrl -and $pProject) {
        $runCheck = Invoke-AzCommand 'pipelines', 'runs', 'show',
            '--id', $stateObj.RunId,
            '--org', $pOrgUrl,
            '--project', $pProject,
            '-o', 'json'
        if ($runCheck.ExitCode -ne 0) {
            $issues += "Pipeline run $($stateObj.RunId) no longer exists in Azure DevOps — will need to trigger a new run"
        }
    }

    $recommendation = if ($issues.Count -eq 0) {
        'State is valid — safe to resume'
    } elseif ($isStale -or $issues -match 'no longer exists|App type changed|Missing required') {
        'Recommend starting fresh at Stage 1'
    } else {
        'Review issues but resume may be safe'
    }

    [pscustomobject]@{
        Valid          = ($issues.Count -eq 0)
        Stale          = $isStale
        Issues         = $issues
        Recommendation = $recommendation
        State          = $stateObj
    }
    $global:LASTEXITCODE = 0
    exit 0
}

# ════════════════════════════════════════════════════════════
# DELETE
# ════════════════════════════════════════════════════════════

if ($Action -eq 'Delete') {
    $deleted = $false
    if (Test-Path $stateFilePath) {
        Remove-Item $stateFilePath -Force
        Write-Output "  State file deleted: $stateFilePath" | Out-Host
        $deleted = $true
    } else {
        Write-Output "  No state file to delete" | Out-Host
    }

    # Clean up SARIF results directory to avoid stale reports on restart
    $sarifDir = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield' 'results'
    $cleanedSarif = @()
    if (Test-Path $sarifDir) {
        $sarifFiles = Get-ChildItem -Path $sarifDir -Include '*.sarif','*.sarif.bak' -Recurse -ErrorAction SilentlyContinue
        foreach ($f in $sarifFiles) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            $cleanedSarif += $f.Name
        }
        if ($cleanedSarif.Count -gt 0) {
            Write-Output "  Cleaned $($cleanedSarif.Count) SARIF file(s) from $sarifDir" | Out-Host
        }
    }

    [pscustomobject]@{ Deleted = $deleted; Path = $stateFilePath; CleanedSarif = $cleanedSarif }
    $global:LASTEXITCODE = 0
    exit 0
}
