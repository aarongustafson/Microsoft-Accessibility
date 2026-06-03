<#
.SYNOPSIS
    Adds per-script VS Code auto-approve entries for vibeshield-powershell.

.DESCRIPTION
    Ensures .vscode/settings.json contains individual auto-approve entries for
    each vibeshield-powershell runtime script in the chat.tools.terminal.autoApprove
    section. Each script gets its own regex key with an exact filename match
    (instead of a single wildcard pattern).

    Uses raw string operations instead of ConvertFrom-Json/ConvertTo-Json because
    PowerShell's JSON cmdlets cannot round-trip regex property keys -- backslash
    escaping levels drift on every read/write cycle, creating duplicates.

    The script is idempotent: entries that already exist are skipped. If a stale
    generic wildcard entry for this skill exists (from a prior version), it is
    removed before adding the per-script entries.

    Scripts registered for auto-approve:
      - Invoke-PSScriptAnalyzer.ps1       (Tier 1 single-file analysis)
      - Invoke-PSScriptAnalyzerHook.ps1   (PostToolUse hook wrapper)
      - Test-PowerShellScripts.ps1        (Tier 2 checkpoint scan)

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script walks up from
    $PSScriptRoot to find the .git directory, falling back to cwd.

.EXAMPLE
    & Install-AutoApproveSettings.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes: 0 always. Outputs summary to host stream.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$skillName = 'vibeshield-powershell'

# Scripts that need auto-approve entries (invoked directly via terminal).
# Resolve-RepoRoot.ps1 is excluded -- it is dot-sourced, never invoked directly.
# Hook scripts read from stdin and accept NO CLI parameters.
$hookScripts = @(
    'Invoke-PSScriptAnalyzerHook.ps1'
)

# Param scripts accept named parameters (e.g., -FilePath, -RepoRoot).
$paramScripts = @(
    'Invoke-PSScriptAnalyzer.ps1',
    'Test-PowerShellScripts.ps1'
)

$approvedScripts = $hookScripts + $paramScripts

# Stale generic pattern to detect and remove (from prior install versions).
# This matched any .ps1 via \S+ wildcard -- now replaced by per-script entries.
$staleGenericMarker = "vibeshield-powershell[\\/\\\\]scripts[\\/\\\\]\\S+\\.ps1"

# Old open-ended suffix that allowed arbitrary trailing content (security risk).
# Entries containing this suffix are replaced by tightened per-category patterns.
$staleOpenEndedMarker = '(\\s.*)?'

# ---------------------------------------------------------------------------
# Resolve project root
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
if ($ProjectPath) {
    $projectRoot = $ProjectPath
} else {
    $projectRoot = Resolve-RepoRoot
    if (-not $projectRoot) { $projectRoot = (Get-Location).Path }
}
$projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

$vscodeDir = Join-Path $projectRoot '.vscode'
$settingsPath = Join-Path $vscodeDir 'settings.json'

# ---------------------------------------------------------------------------
# Read existing file or start fresh
# ---------------------------------------------------------------------------
if (Test-Path $settingsPath) {
    $lines = @(Get-Content -Path $settingsPath -Encoding UTF8)
} else {
    $lines = @('{', '}')
}

$rawText = $lines -join "`n"

# ---------------------------------------------------------------------------
# Build the entry blocks for each script
# ---------------------------------------------------------------------------
function Get-EntryBlock {
    param(
        [string]$ScriptName,
        [switch]$IsHook
    )
    # Escape the dot in the filename for regex
    $escapedName = $ScriptName -replace '\.', '\\.'
    # Hook scripts take no CLI arguments -- regex ends at the filename.
    # Param scripts accept named parameters with safe values only.
    # The param suffix blocks shell metacharacters (; | & $ ` < > ( ) { } ! quotes).
    if ($IsHook) {
        $suffix = ''
    } else {
        $suffix = '( -[A-Za-z]+( [\\w./\\\\:][\\w.\\-/\\\\:]*)?)*'
    }
    @(
        "    `"/^pwsh -NoProfile -File [\\.\\\\]?\\.?github[\\/\\\\]skills[\\/\\\\]$skillName[\\/\\\\]scripts[\\/\\\\]$escapedName$suffix$/`": {"
        '      "approve": true,'
        '      "matchCommandLine": true'
        '    }'
    )
}

# ---------------------------------------------------------------------------
# Determine which entries already exist and which are needed
# ---------------------------------------------------------------------------
$entriesToAdd = [System.Collections.Generic.List[string[]]]::new()
$skippedCount = 0

# Detect stale open-ended entries (old suffix that allowed arbitrary trailing content)
$hasStaleOpenEndedEntry = $false
foreach ($line in $lines) {
    if ($line.Contains($skillName) -and $line.Contains($staleOpenEndedMarker)) {
        $hasStaleOpenEndedEntry = $true
        break
    }
}

foreach ($script in $approvedScripts) {
    $escapedName = $script -replace '\.', '\\.'
    $keyFragment = "$skillName[\\/\\\\]scripts[\\/\\\\]$escapedName"
    $isHook = $script -in $hookScripts
    if ($rawText.Contains($keyFragment)) {
        if ($hasStaleOpenEndedEntry) {
            # Entry exists but uses old open-ended suffix -- replace with tightened pattern
            $entryBlock = @(Get-EntryBlock -ScriptName $script -IsHook:$isHook)
            $entriesToAdd.Add($entryBlock)
        } else {
            $skippedCount++
        }
    } else {
        $entryBlock = @(Get-EntryBlock -ScriptName $script -IsHook:$isHook)
        $entriesToAdd.Add($entryBlock)
    }
}

# ---------------------------------------------------------------------------
# Check for stale generic entry to remove
# ---------------------------------------------------------------------------
$hasStaleEntry = $rawText.Contains($staleGenericMarker)

if ($entriesToAdd.Count -eq 0 -and -not $hasStaleEntry -and -not $hasStaleOpenEndedEntry) {
    Write-Host "  SKIPPED: .vscode\settings.json auto-approve ($skillName) all entries present" -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------------------
# Locate the autoApprove section
# ---------------------------------------------------------------------------
$autoApproveMarker = '"chat.tools.terminal.autoApprove"'
$markerIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Contains($autoApproveMarker)) {
        $markerIndex = $i
        break
    }
}

if ($markerIndex -lt 0) {
    # No autoApprove section -- create one before the last closing brace
    $lastBrace = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim().StartsWith('}')) {
            $lastBrace = $i
            break
        }
    }
    if ($lastBrace -lt 0) { $lastBrace = $lines.Count }
    if ($lastBrace -gt 0) {
        $prev = $lines[$lastBrace - 1].TrimEnd()
        if ($prev -ne '' -and -not $prev.EndsWith(',') -and -not $prev.EndsWith('{')) {
            $lines[$lastBrace - 1] = $prev + ','
        }
    }

    # Build section with all entries
    $sectionLines = [System.Collections.Generic.List[string]]::new()
    $sectionLines.Add('  "chat.tools.terminal.autoApprove": {')
    for ($e = 0; $e -lt $entriesToAdd.Count; $e++) {
        foreach ($el in $entriesToAdd[$e]) {
            $sectionLines.Add($el)
        }
        if ($e -lt $entriesToAdd.Count - 1) {
            # Add comma after closing brace of each entry except last
            $lastIdx = $sectionLines.Count - 1
            $sectionLines[$lastIdx] = $sectionLines[$lastIdx] + ','
        }
    }
    $sectionLines.Add('  }')

    $before = if ($lastBrace -gt 0) { $lines[0..($lastBrace - 1)] } else { @() }
    $after = $lines[$lastBrace..($lines.Count - 1)]
    $lines = @($before) + @($sectionLines) + @($after)
} else {
    # Find closing brace of the autoApprove object
    $depth = 0
    $closingIndex = -1
    for ($i = $markerIndex; $i -lt $lines.Count; $i++) {
        foreach ($ch in $lines[$i].ToCharArray()) {
            if ($ch -eq '{') { $depth++ }
            if ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $closingIndex = $i
                    break
                }
            }
        }
        if ($closingIndex -ge 0) { break }
    }

    # Build output: copy lines outside the section as-is, filter stale entries inside
    $output = [System.Collections.Generic.List[string]]::new()

    # Lines before and including the marker line
    for ($i = 0; $i -le $markerIndex; $i++) {
        $output.Add($lines[$i])
    }

    # Lines inside the section -- remove stale entries if present
    $i = $markerIndex + 1
    while ($i -lt $closingIndex) {
        $shouldRemove = $false
        if ($hasStaleEntry -and $lines[$i].Contains($staleGenericMarker)) {
            $shouldRemove = $true
        }
        if ($hasStaleOpenEndedEntry -and $lines[$i].Contains($skillName) -and $lines[$i].Contains($staleOpenEndedMarker)) {
            $shouldRemove = $true
        }
        if ($shouldRemove) {
            # Skip this entry -- detect multi-line vs single-line
            if ($lines[$i].TrimEnd().TrimEnd(',').EndsWith('{')) {
                $entryDepth = 0
                while ($i -lt $closingIndex) {
                    foreach ($ch in $lines[$i].ToCharArray()) {
                        if ($ch -eq '{') { $entryDepth++ }
                        if ($ch -eq '}') { $entryDepth-- }
                    }
                    $i++
                    if ($entryDepth -eq 0) { break }
                }
            } else {
                $i++
            }
            continue
        }
        $output.Add($lines[$i])
        $i++
    }

    # Add new entries (ensure trailing commas between entries)
    if ($entriesToAdd.Count -gt 0) {
        # Ensure comma on the last existing line before new entries
        if ($output.Count -gt 0) {
            $lastIdx = $output.Count - 1
            $lastLine = $output[$lastIdx].TrimEnd()
            if ($lastLine -ne '' -and -not $lastLine.EndsWith(',') -and -not $lastLine.EndsWith('{')) {
                $output[$lastIdx] = $lastLine + ','
            }
        }

        for ($e = 0; $e -lt $entriesToAdd.Count; $e++) {
            foreach ($el in $entriesToAdd[$e]) {
                $output.Add($el)
            }
            if ($e -lt $entriesToAdd.Count - 1) {
                $lastIdx = $output.Count - 1
                $output[$lastIdx] = $output[$lastIdx] + ','
            }
        }
    }

    # Fix trailing commas: ensure no comma on the last entry before closing brace
    if ($output.Count -gt 0) {
        $lastIdx = $output.Count - 1
        $lastLine = $output[$lastIdx].TrimEnd()
        if ($lastLine.EndsWith(',')) {
            $output[$lastIdx] = $lastLine.TrimEnd(',')
        }
    }

    # Add closing brace and everything after the section
    for ($i = $closingIndex; $i -lt $lines.Count; $i++) {
        $output.Add($lines[$i])
    }
    $lines = @($output)
}

# ---------------------------------------------------------------------------
# Write back
# ---------------------------------------------------------------------------
if (-not (Test-Path $vscodeDir)) {
    New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
}

$outputText = $lines -join "`n"
Set-Content -Path $settingsPath -Value $outputText -Encoding UTF8 -NoNewline

$addedCount = $entriesToAdd.Count
$staleNote = ''
if ($hasStaleEntry) { $staleNote += ', stale generic entry removed' }
if ($hasStaleOpenEndedEntry) { $staleNote += ', open-ended suffixes tightened' }
Write-Host "  AUTO-APPROVE ($skillName): $addedCount added, $skippedCount skipped$staleNote" -ForegroundColor Green
exit 0
