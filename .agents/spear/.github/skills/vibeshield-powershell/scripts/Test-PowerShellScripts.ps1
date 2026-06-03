<#
.SYNOPSIS
    Runs PSScriptAnalyzer against all PowerShell scripts in the repository.

.DESCRIPTION
    Checkpoint quality gate that discovers all .ps1 and .psm1 files
    recursively from the repo root (excluding output/ and .specify/
    directories) and validates each one in-process using the shared
    Invoke-SingleFileAnalysis function from PSScriptAnalyzerHelper.ps1.

    PSScriptAnalyzer is loaded once via Initialize-PSScriptAnalyzer and
    reused for every file -- no per-file subprocess spawning.

    This script is the Tier 2 (checkpoint) counterpart to the Tier 1
    (hook) single-file validation. Use it at significant milestones
    and before commit.

    Always writes aggregated SARIF results to ./output/psscriptanalyzer-results.sarif
    for structured consumption by agents and CI tools.

    The script resolves the repository root automatically by walking up
    from its own location to find the .git directory. This allows it to
    run correctly from any location (skill directory, hook, CI, or manual).

.PARAMETER RepoRoot
    Optional. Explicit path to the repository root. If omitted, the script
    walks up from $PSScriptRoot to find the .git directory, falling back
    to the current working directory.

.EXAMPLE
    # From repo root (auto-resolves)
    pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Test-PowerShellScripts.ps1

.EXAMPLE
    # With explicit repo root
    pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Test-PowerShellScripts.ps1 -RepoRoot C:\repos\ComplianceAutomation

.NOTES
    Exit Codes:
      0 - All scripts pass (zero violations)
      1 - One or more violations detected
#>

param(
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

# Initialize PSScriptAnalyzer once for all files
$psaVersion = Initialize-PSScriptAnalyzer

Write-Host 'Scanning PowerShell scripts...'

# Discover all .ps1 and .psm1 files, excluding output/ and .specify/
$scripts = @(
    Get-ChildItem -Path $repoRoot -Include '*.ps1', '*.psm1' -Recurse -File |
        Where-Object {
            $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
            -not (Test-ExcludedPath -RelativePath $rel)
        }
)

if ($scripts.Count -eq 0) {
    Write-Host 'No PowerShell scripts found to analyze.'
    exit 0
}

Write-Host "Found $($scripts.Count) scripts to analyze."
Write-Host ''

$failedCount = 0
$skippedCount = 0
$allSarifResults = [System.Collections.ArrayList]::new()

foreach ($script in $scripts) {
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $script.FullName)
    Write-Host "Checking: $relativePath"

    # Per-file error isolation (FR-013)
    try {
        $fileResults = @(Invoke-SingleFileAnalysis -FilePath $script.FullName -RepoRoot $repoRoot)
    }
    catch {
        Write-Warning "Skipped $relativePath -- $($_.Exception.Message)"
        $skippedCount++
        continue
    }

    $fileViolationCount = $fileResults.Count
    if ($fileViolationCount -gt 0) {
        $failedCount++
        foreach ($r in $fileResults) {
            [void]$allSarifResults.Add($r)
            $line = $r.locations[0].physicalLocation.region.startLine
            Write-Host "  VIOLATION: Line $($line): $($r.ruleId) - $($r.message.text)" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host "Results: $relativePath -- $fileViolationCount violation(s) found." -ForegroundColor Red
    }
    else {
        Write-Host '  [OK] No issues' -ForegroundColor Green
        Write-Host ''
        Write-Host "Results: $relativePath passed." -ForegroundColor Green
    }
}

# Always write aggregated SARIF to output directory
$outputDir = Join-Path $repoRoot 'output'
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$aggregatedSarif = New-SarifEnvelope -Results @($allSarifResults) -ToolVersion $psaVersion

$sarifPath = Join-Path $outputDir 'psscriptanalyzer-results.sarif'
$aggregatedSarif | ConvertTo-Json -Depth 10 | Out-File -FilePath $sarifPath -Encoding utf8 -Force

$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed.TotalSeconds.ToString('F2')

Write-Host ''
if ($failedCount -eq 0) {
    Write-Host "Results: $($scripts.Count) scripts scanned, 0 violation(s) found. All scripts pass. SARIF written to ./output/. Completed in ${elapsed}s" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "Results: $($scripts.Count) scripts scanned, $failedCount script(s) failed. SARIF written to ./output/. Completed in ${elapsed}s" -ForegroundColor Red
    exit 1
}
