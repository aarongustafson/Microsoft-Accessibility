<#
.SYNOPSIS
    Lints a single Bicep file using az bicep lint.

.DESCRIPTION
    Fast lint script for use by PostToolUse hooks on every .bicep edit.
    Runs 'az bicep lint' for syntax and lint validation only -- no PSRule.
    Always emits results as SARIF v2.1.0 JSON to stdout via
    --diagnostics-format sarif for structured consumption by hooks,
    agents, and CI tools.
    For full PSRule + WAF validation, use Invoke-BicepValidation.ps1 at
    checkpoints and before commit.

.PARAMETER FilePath
    Required. Path to the .bicep file to lint. Accepts absolute paths
    or paths relative to the current working directory.

.PARAMETER RepoRoot
    Optional. Explicit path to the repository root. If omitted, the script
    walks up from $PSScriptRoot to find the .git directory, falling back
    to the current working directory.

.EXAMPLE
    # Lint a file (SARIF output to stdout)
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepLint.ps1 -FilePath infra/main.bicep

.EXAMPLE
    # Lint with explicit repo root
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepLint.ps1 -FilePath infra/main.bicep -RepoRoot C:\repos\ComplianceAutomation

.NOTES
    Exit Codes:
      0 - File passes lint
      1 - Lint errors detected
      2 - Invalid arguments (file not found, not .bicep, excluded path)

    Output:
      Always emits SARIF v2.1.0 JSON to stdout via az bicep lint --diagnostics-format sarif.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

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

# Validate file exists and is a .bicep file
if (-not (Test-Path $FilePath)) {
    Write-Host "ERROR: File not found: $FilePath" -ForegroundColor Red
    exit 2
}

if ([System.IO.Path]::GetExtension($FilePath) -ne '.bicep') {
    Write-Host "ERROR: Not a .bicep file: $FilePath" -ForegroundColor Red
    exit 2
}

# Reject files under output/ or .specify/ directories
$relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $FilePath)
if ($relativePath -match '(^|[\\/])(output|\.specify)[\\/]') {
    Write-Host "SKIP: File is under an excluded directory (output/ or .specify/): $relativePath" -ForegroundColor Yellow
    Write-Host "Elapsed: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Cyan
    exit 0
}

# Verify Azure CLI is available
$azCmd = Get-Command 'az' -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Host 'ERROR: Azure CLI is not installed.' -ForegroundColor Red
    Write-Host 'Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli' -ForegroundColor Yellow
    exit 1
}

Write-Host "Linting: $relativePath"

# Lint via az bicep lint with native SARIF output
try {
    $sarifOutput = az bicep lint --file $FilePath --diagnostics-format sarif 2>&1
    $lintExitCode = $LASTEXITCODE

    # Emit SARIF to stdout
    $sarifOutput | ForEach-Object { Write-Output $_ }

    Write-Host "Elapsed: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Cyan
    if ($lintExitCode -ne 0) { exit 1 } else { exit 0 }
}
catch {
    Write-Host "  LINT: $relativePath -- ERROR" -ForegroundColor Red
    Write-Host "    $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host "Results: $relativePath lint failed." -ForegroundColor Red
    Write-Host "Elapsed: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Cyan
    exit 1
}
