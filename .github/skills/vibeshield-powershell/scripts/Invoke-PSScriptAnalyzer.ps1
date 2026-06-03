<#
.SYNOPSIS
    Validates a single PowerShell file using PSScriptAnalyzer static analysis.

.DESCRIPTION
    Fast single-file validation script for use by PostToolUse hooks on every
    .ps1/.psm1 edit. Delegates analysis, SARIF construction, and module
    bootstrapping to shared functions in PSScriptAnalyzerHelper.ps1.
    Always emits results as SARIF v2.1.0 JSON to stdout for structured
    consumption by hooks, agents, and CI tools.
    For full repo-wide validation of all scripts, use
    Test-PowerShellScripts.ps1 at checkpoints and before commit.

.PARAMETER FilePath
    Required. Path to the .ps1 or .psm1 file to validate. Accepts absolute
    paths or paths relative to the current working directory.

.PARAMETER RepoRoot
    Optional. Explicit path to the repository root. If omitted, the script
    walks up from $PSScriptRoot to find the .git directory, falling back
    to the current working directory. Used for relative path display.

.EXAMPLE
    # Validate a file (SARIF output to stdout)
    pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Invoke-PSScriptAnalyzer.ps1 -FilePath SFI/NS2-1/Add-VirtualTag.ps1

.EXAMPLE
    # Validate with explicit repo root
    pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Invoke-PSScriptAnalyzer.ps1 -FilePath SFI/NS2-1/Add-VirtualTag.ps1 -RepoRoot C:\repos\ComplianceAutomation

.NOTES
    Exit Codes:
      0 - File passes validation (zero violations)
      1 - One or more violations detected
      2 - Invalid arguments (file not found, wrong extension)

    Output:
      Always emits SARIF v2.1.0 JSON to stdout.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stopwatch = [Diagnostics.Stopwatch]::StartNew()

# Dot-source shared helper library (safety guard)
$helperPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerHelper.ps1'
if (-not (Test-Path $helperPath)) {
    Write-Host "ERROR: Required file not found: $helperPath" -ForegroundColor Red
    exit 2
}
try { . $helperPath } catch {
    Write-Host "ERROR: Failed to load helper: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

# Resolve repository root: use parameter or shared resolver
. (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
if ($RepoRoot) {
    $repoRoot = $RepoRoot
} else {
    $repoRoot = Resolve-RepoRoot
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
}

# Resolve the file path to an absolute path
if (-not [System.IO.Path]::IsPathRooted($FilePath)) {
    $FilePath = Join-Path (Get-Location).Path $FilePath
}
$FilePath = [System.IO.Path]::GetFullPath($FilePath)

# Validate file exists
if (-not (Test-Path $FilePath)) {
    Write-Host "ERROR: File not found: $FilePath" -ForegroundColor Red
    exit 2
}

# Validate file extension
$extension = [System.IO.Path]::GetExtension($FilePath)
if ($extension -ne '.ps1' -and $extension -ne '.psm1') {
    Write-Host "ERROR: Not a PowerShell file (.ps1 or .psm1): $FilePath" -ForegroundColor Red
    exit 2
}

# Skip files under excluded directories
$relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $FilePath)
if (Test-ExcludedPath -RelativePath $relativePath) {
    Write-Host "SKIP: File is under an excluded directory: $relativePath" -ForegroundColor Yellow
    exit 0
}

# Bootstrap PSScriptAnalyzer module
$moduleVersion = Initialize-PSScriptAnalyzer

# Run analysis and build SARIF output
$sarifResults = @(Invoke-SingleFileAnalysis -FilePath $FilePath -RepoRoot $repoRoot)
$sarif = New-SarifEnvelope -Results $sarifResults -ToolVersion $moduleVersion

$stopwatch.Stop()

$sarif | ConvertTo-Json -Depth 10 -Compress
Write-Verbose "Completed in $($stopwatch.Elapsed.TotalSeconds.ToString('F2'))s"
if ($sarifResults.Count -gt 0) { exit 1 } else { exit 0 }
