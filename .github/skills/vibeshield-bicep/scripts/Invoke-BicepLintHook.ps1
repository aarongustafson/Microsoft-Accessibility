<#
.SYNOPSIS
    PostToolUse hook wrapper - runs Bicep lint after .bicep file edits.

.DESCRIPTION
    Reads hook input from stdin, extracts individual .bicep file paths,
    and lint-validates each one by calling az bicep lint directly
    (no subprocess spawning). This is fast lint-only validation
    for immediate feedback -- the agent should run the full
    Invoke-BicepValidation.ps1 (with PSRule) at checkpoints and before checkin.

    Communication contract (per VS Code hooks docs):
    - hookSpecificOutput.additionalContext: injected into agent/model conversation
    - decision + reason: on failure, blocks further processing and tells the model why
    - systemMessage: warning displayed to the user in chat
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Read hook input from stdin
$rawInput = @($input) -join "`n"
if (-not $rawInput) { exit 0 }

# Only run after write operations, not reads
$writeTools = 'create_file|replace_string_in_file|multi_replace_string_in_file|edit_notebook_file|insert_edit|run_in_terminal'
if ($rawInput -notmatch $writeTools) { exit 0 }

# Quick check: was a .bicep file involved in this tool use?
if ($rawInput -notmatch '\.bicep') { exit 0 }

# Resolve repo root using shared resolver
. (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
$repoRoot = Resolve-RepoRoot
if (-not $repoRoot) { exit 0 }

# Verify az CLI is available (required for direct az bicep lint calls)
if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) { exit 0 }

# Extract .bicep file paths from the hook input
$bicepPaths = @([regex]::Matches($rawInput, '[^\s"'']+\.bicep') | ForEach-Object { $_.Value } | Sort-Object -Unique)

if ($bicepPaths.Count -eq 0) { exit 0 }

# T022: Validate .bicep files in parallel for multi-file edits
$results = @($bicepPaths | ForEach-Object -Parallel {
    $bicepPath = $_
    $localRepoRoot = $using:repoRoot

    # Resolve to absolute path if relative
    $absolutePath = if ([System.IO.Path]::IsPathRooted($bicepPath)) {
        $bicepPath
    } else {
        Join-Path $localRepoRoot $bicepPath
    }

    if (-not (Test-Path $absolutePath)) { return }

    # Skip files in excluded directories (output/, .specify/)
    $normalizedPath = $absolutePath.Replace('\', '/')
    if ($normalizedPath -match '/(output|\.specify)/') { return }

    # Direct az bicep lint call
    $lintOutput = @(& az bicep lint --file $absolutePath --diagnostics-format sarif 2>&1)
    $lintExitCode = $LASTEXITCODE
    $sarifLines = @($lintOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $errorLines = @($lintOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })

    $capturedOutput = ($sarifLines -join "`n")
    if ($errorLines.Count -gt 0) {
        $capturedOutput += "`n" + ($errorLines -join "`n")
    }

    [PSCustomObject]@{
        Output = $capturedOutput
        Failed = ($lintExitCode -ne 0)
    }
} -ThrottleLimit 4)

# Aggregate results
$allOutput = [System.Text.StringBuilder]::new()
$anyFailed = $false
foreach ($result in $results) {
    if ($null -eq $result) { continue }
    if ($result.Output) { [void]$allOutput.AppendLine($result.Output) }
    if ($result.Failed) { $anyFailed = $true }
}
$combinedOutput = $allOutput.ToString()

# Build PostToolUse-compliant JSON output
if (-not $anyFailed) {
    @{
        systemMessage = 'Bicep lint PASSED - edited template(s) have valid syntax.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = "Bicep lint PASSED (lint only). PSRule was NOT run. Run Invoke-BicepValidation.ps1 for full validation (lint + PSRule) at checkpoints and before checkin. $combinedOutput"
        }
    } | ConvertTo-Json -Depth 3 -Compress
} else {
    @{
        decision = 'block'
        reason = 'Bicep lint FAILED - fix all syntax/lint errors before proceeding.'
        systemMessage = 'Bicep lint FAILED - syntax/lint errors detected.'
        hookSpecificOutput = @{
            hookEventName = 'PostToolUse'
            additionalContext = "Bicep lint FAILED. Fix these lint errors before continuing: $combinedOutput"
        }
    } | ConvertTo-Json -Depth 3 -Compress
}

Write-Host "Elapsed: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Cyan
exit 0
