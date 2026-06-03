#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Emit a SARIF report for the Bicep Generator stage.
.DESCRIPTION
    Thin wrapper around Write-SarifReport.ps1 that handles .bak rename,
    sets the correct tool name and output path, and cleans up on success.
    Called by the vibeshield-bicep agent after collecting check results.
.PARAMETER ResultsJson
    JSON string — array of result objects (id, name, status, message, fix).
.PARAMETER WorkspacePath
    Workspace root. Defaults to current directory.
.PARAMETER PropertiesJson
    Optional extra metadata as JSON string (e.g. mode=repair).
.EXAMPLE
    ./Invoke-BicepSarif.ps1 -ResultsJson '[{"id":"BIC-01","name":"Template Generated","status":"PASS","message":"infra/main.bicep created","fix":""}]'
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

$sarifPath  = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'bicep-results.sarif'
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
    ToolName    = 'Bicep Generator'
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
