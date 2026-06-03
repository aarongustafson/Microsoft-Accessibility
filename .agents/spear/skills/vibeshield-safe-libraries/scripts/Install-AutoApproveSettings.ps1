<#
.SYNOPSIS
    Adds per-script VS Code auto-approve entries for vibeshield-safe-libraries.

.DESCRIPTION
    Ensures .vscode/settings.json contains individual auto-approve entries for
    each vibeshield-safe-libraries runtime script in the chat.tools.terminal.autoApprove
    section. Each script gets its own regex key with an exact filename match.

    Uses raw string operations instead of ConvertFrom-Json/ConvertTo-Json because
    PowerShell's JSON cmdlets cannot round-trip regex property keys -- backslash
    escaping levels drift on every read/write cycle, creating duplicates.

    The script is idempotent: entries that already exist are skipped.

    Scripts registered for auto-approve:
      - Install-VibeShield.ps1  (CFS feed configuration installer)

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
$skillName = 'vibeshield-safe-libraries'

# Scripts that accept named parameters.
$paramScripts = @(
    'Install-VibeShield.ps1'
)

$approvedScripts = $paramScripts

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
        [string]$ScriptName
    )
    # Escape the dot in the filename for regex
    $escapedName = $ScriptName -replace '\.', '\\.'
    $suffix = '( -[A-Za-z]+( [\\w./\\\\:][\\w.\\-/\\\\:]*)?)*'
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

foreach ($script in $approvedScripts) {
    $escapedName = $script -replace '\.', '\\.'
    $keyFragment = "$skillName[\\/\\\\]scripts[\\/\\\\]$escapedName"
    if ($rawText.Contains($keyFragment)) {
        $skippedCount++
    } else {
        $entryBlock = @(Get-EntryBlock -ScriptName $script)
        $entriesToAdd.Add($entryBlock)
    }
}

if ($entriesToAdd.Count -eq 0) {
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
            $lastLine = $sectionLines[$sectionLines.Count - 1]
            if (-not $lastLine.TrimEnd().EndsWith(',')) {
                $sectionLines[$sectionLines.Count - 1] = $lastLine.TrimEnd() + ','
            }
        }
    }
    $sectionLines.Add('  }')

    $insertLines = [System.Collections.Generic.List[string]]::new()
    foreach ($sl in $sectionLines) { $insertLines.Add($sl) }

    $newLines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lastBrace; $i++) { $newLines.Add($lines[$i]) }
    foreach ($sl in $insertLines) { $newLines.Add($sl) }
    for ($i = $lastBrace; $i -lt $lines.Count; $i++) { $newLines.Add($lines[$i]) }
    $lines = $newLines.ToArray()
} else {
    # autoApprove section exists -- find its closing brace and insert before it
    $braceDepth = 0
    $sectionEnd = -1
    for ($i = $markerIndex; $i -lt $lines.Count; $i++) {
        foreach ($ch in $lines[$i].ToCharArray()) {
            if ($ch -eq '{') { $braceDepth++ }
            if ($ch -eq '}') {
                $braceDepth--
                if ($braceDepth -eq 0) {
                    $sectionEnd = $i
                    break
                }
            }
        }
        if ($sectionEnd -ge 0) { break }
    }

    if ($sectionEnd -lt 0) { $sectionEnd = $lines.Count - 1 }

    # Add comma to previous entry if needed
    if ($sectionEnd -gt $markerIndex + 1) {
        $prev = $lines[$sectionEnd - 1].TrimEnd()
        if ($prev -ne '' -and -not $prev.EndsWith(',') -and -not $prev.EndsWith('{')) {
            $lines[$sectionEnd - 1] = $prev + ','
        }
    }

    $insertLines = [System.Collections.Generic.List[string]]::new()
    for ($e = 0; $e -lt $entriesToAdd.Count; $e++) {
        foreach ($el in $entriesToAdd[$e]) {
            $insertLines.Add($el)
        }
        if ($e -lt $entriesToAdd.Count - 1) {
            $lastLine = $insertLines[$insertLines.Count - 1]
            if (-not $lastLine.TrimEnd().EndsWith(',')) {
                $insertLines[$insertLines.Count - 1] = $lastLine.TrimEnd() + ','
            }
        }
    }

    $newLines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $sectionEnd; $i++) { $newLines.Add($lines[$i]) }
    foreach ($sl in $insertLines) { $newLines.Add($sl) }
    for ($i = $sectionEnd; $i -lt $lines.Count; $i++) { $newLines.Add($lines[$i]) }
    $lines = $newLines.ToArray()
}

# ---------------------------------------------------------------------------
# Write settings file
# ---------------------------------------------------------------------------
if (-not (Test-Path $vscodeDir)) {
    New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
}

$lines | Set-Content -Path $settingsPath -Encoding UTF8
Write-Host "  CREATED: .vscode\settings.json auto-approve ($skillName) $($entriesToAdd.Count) entries added" -ForegroundColor Green
