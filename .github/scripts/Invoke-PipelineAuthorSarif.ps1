#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Emit a SARIF report for the Pipeline Author stage.
.DESCRIPTION
    Thin wrapper around Write-SarifReport.ps1 that handles .bak rename,
    sets the correct tool name and output path, and cleans up on success.
    Called by the vibeshield-deploy-pipeline-author agent after collecting check results.
.PARAMETER ResultsJson
    JSON string — array of result objects (id, name, status, message, fix).
.PARAMETER WorkspacePath
    Workspace root. Defaults to current directory.
.PARAMETER PropertiesJson
    Optional extra metadata as JSON string.
.EXAMPLE
    ./Invoke-PipelineAuthorSarif.ps1 -ResultsJson '[{"id":"PA-01","name":"Service Connection","status":"PASS","message":"Found sc-vibe-user-ARM","fix":""}]'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsJson,
    [string]$WorkspacePath = $PWD.Path,
    [string]$PropertiesJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load shared helpers for Initialize-SarifCleanStart
$sharedHelpersPath = Join-Path -Path $WorkspacePath -ChildPath '.github/scripts/SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) {
    . $sharedHelpersPath
    try { Assert-ScriptIntegrity -WorkspacePath $WorkspacePath } catch {
        Write-Warning "Script integrity check failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "SharedHelpers.ps1 not found at $sharedHelpersPath — skipping integrity check."
}

$sarifPath  = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'pipeline-author-results.sarif'
$helperPath = Join-Path -Path $WorkspacePath -ChildPath '.github/scripts/Write-SarifReport.ps1'

if (-not (Test-Path $helperPath)) {
    Write-Error "SARIF writer not found at $helperPath. Run Install-VibeShield.ps1 to restore."
    $global:LASTEXITCODE = 1
    exit 1
}

# Step 0: Clean previous SARIF
Initialize-SarifCleanStart -SarifPath $sarifPath

# Emit SARIF
$sarifArgs = @{
    ToolName    = 'Pipeline Setup'
    ResultsJson = $ResultsJson
    OutputPath  = $sarifPath
}
if ($PropertiesJson) { $sarifArgs['PropertiesJson'] = $PropertiesJson }

$global:LASTEXITCODE = 0
try {
    & $helperPath @sarifArgs
} catch {
    Write-Error "SARIF emission failed: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}

if (Test-Path $sarifPath) {
    Write-Output "SARIF report written to $sarifPath"
} else {
    Write-Warning "SARIF emission failed"
}
