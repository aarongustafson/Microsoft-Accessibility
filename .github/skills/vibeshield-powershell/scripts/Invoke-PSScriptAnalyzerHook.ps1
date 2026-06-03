<#
.SYNOPSIS
    PostToolUse hook wrapper - runs PSScriptAnalyzer validation after .ps1 file edits.

.DESCRIPTION
    Reads hook input from stdin, extracts individual .ps1/.psm1 file paths,
    and validates each one in-process using the shared functions from
    PSScriptAnalyzerHelper.ps1 (Invoke-SingleFileAnalysis). No child
    processes are spawned. This is fast single-file validation for
    immediate feedback -- the agent should run the full
    Test-PowerShellScripts.ps1 (all-files scan) at checkpoints and before
    declaring work complete.

    Communication contract (per VS Code hooks docs):
    - hookSpecificOutput.additionalContext: injected into agent/model conversation
    - decision + reason: on failure, blocks further processing and tells the model why
    - systemMessage: warning displayed to the user in chat
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read hook input from stdin
$rawInput = @($input) -join "`n"
if (-not $rawInput) { exit 0 }

# Only run after write operations, not reads
$writeTools = 'create_file|replace_string_in_file|multi_replace_string_in_file|edit_notebook_file|insert_edit|run_in_terminal'
if ($rawInput -notmatch $writeTools) { exit 0 }

# Quick check: was a .ps1 or .psm1 file involved in this tool use?
if ($rawInput -notmatch '\.(ps1|psm1)') { exit 0 }

# -- Working body wrapped in safety guard: hooks must not crash --
try {

# Dot-source shared helper library
$helperPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerHelper.ps1'
if (-not (Test-Path $helperPath)) {
    @{
        systemMessage = 'PSScriptAnalyzer helper not found -- validation skipped.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = 'PSScriptAnalyzerHelper.ps1 is missing. Validation could not run.'
        }
    } | ConvertTo-Json -Depth 3 -Compress
    exit 0
}
. $helperPath

# Resolve repo root using shared resolver
$resolverPath = Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1'
if (-not (Test-Path $resolverPath)) {
    @{
        systemMessage = 'Repo root resolver not found -- validation skipped.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = 'Resolve-RepoRoot.ps1 is missing. Validation could not run.'
        }
    } | ConvertTo-Json -Depth 3 -Compress
    exit 0
}
. $resolverPath
$repoRoot = Resolve-RepoRoot
if (-not $repoRoot) {
    @{
        systemMessage = 'Could not resolve repo root -- validation skipped.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = 'Resolve-RepoRoot returned null. Validation could not run.'
        }
    } | ConvertTo-Json -Depth 3 -Compress
    exit 0
}

# Initialize PSScriptAnalyzer once for all files
$psaVersion = Initialize-PSScriptAnalyzer

# Extract .ps1/.psm1 file paths from the hook input
$psPaths = @([regex]::Matches($rawInput, '[^\s"'']+\.ps(?:1|m1)') | ForEach-Object { $_.Value } | Sort-Object -Unique)

if ($psPaths.Count -eq 0) { exit 0 }

# Validate each extracted file in-process and aggregate SARIF results
$allResults = [System.Collections.Generic.List[hashtable]]::new()
$anyFailed = $false

foreach ($psPath in $psPaths) {
    # Resolve to absolute path if relative
    $absolutePath = if ([System.IO.Path]::IsPathRooted($psPath)) {
        $psPath
    } else {
        Join-Path $repoRoot $psPath
    }

    if (-not (Test-Path $absolutePath)) { continue }

    # Compute relative path for exclusion check
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $absolutePath)
    if (Test-ExcludedPath -RelativePath $relativePath) { continue }

    try {
        $fileResults = @(Invoke-SingleFileAnalysis -FilePath $absolutePath -RepoRoot $repoRoot)
        if ($fileResults.Count -gt 0) {
            $anyFailed = $true
            foreach ($r in $fileResults) { $allResults.Add($r) }
        }
    }
    catch {
        # Analysis failure on a single file should not crash the hook
        continue
    }
}

# Build combined SARIF output
$sarifDoc = New-SarifEnvelope -Results @($allResults) -ToolVersion $psaVersion
$sarifJson = $sarifDoc | ConvertTo-Json -Depth 10 -Compress

# Build PostToolUse-compliant JSON output
if (-not $anyFailed) {
    @{
        systemMessage = 'PSScriptAnalyzer validation PASSED - edited script(s) comply.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = "PSScriptAnalyzer validation PASSED (modified file only). Run Test-PowerShellScripts.ps1 for full checkpoint validation (all scripts) at milestones and before declaring work complete. $sarifJson"
        }
    } | ConvertTo-Json -Depth 3 -Compress
} else {
    @{
        decision = 'block'
        reason = 'PSScriptAnalyzer validation FAILED - fix all violations before proceeding.'
        systemMessage = 'PSScriptAnalyzer validation FAILED - violations detected in edited script(s).'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = "PSScriptAnalyzer validation FAILED. Fix these violations before continuing: $sarifJson"
        }
    } | ConvertTo-Json -Depth 3 -Compress
}

} catch {
    # Outer safety net: emit diagnostic JSON and exit cleanly (hooks must not crash)
    @{
        systemMessage = 'PSScriptAnalyzer validation encountered an unexpected error.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = "Validation was incomplete due to an unexpected error: $($_.Exception.Message)"
        }
    } | ConvertTo-Json -Depth 3 -Compress
    exit 0
}

exit 0
