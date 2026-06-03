<#
.SYNOPSIS
    Injects a marker-delimited fragment into a target Markdown file.

.DESCRIPTION
    Generic marker-based fragment injector for idempotent content injection into
    Markdown files (AGENTS.md, CLAUDE.md, copilot-instructions.md, etc.).

    The fragment source file must contain exactly one BEGIN/END marker pair:
      <!-- BEGIN:markerName -->
      ...content...
      <!-- END:markerName -->

    The marker name is extracted automatically from the source content.

    Injection logic:
      1. If the target already contains a matching BEGIN marker, the entire
         marker block is replaced with the source content (idempotent update).
      2. If -SectionMarker is provided and the target contains
         <!-- END:sectionMarker -->, the source content is inserted just
         before that closing marker (first injection into the section).
      3. If the target file does not exist, it is created with the section
         markers and the fragment content.
      4. If the target file exists but has no insertion point, the section
         markers and fragment content are appended at the end of the file.

    This script outputs a single result word to stdout (CREATED, UPDATED,
    SKIPPED) that the caller can capture. Status messages go to the host
    stream via Write-Host and do not pollute stdout.

.PARAMETER SourcePath
    Required. Path to the fragment .md file containing BEGIN/END markers.

.PARAMETER TargetPath
    Required. Path to the target .md file to inject into.

.PARAMETER SectionMarker
    Optional. The name of a section marker (e.g., 'automated-agents') that
    wraps the target section with <!-- BEGIN:name --> / <!-- END:name -->.
    When the fragment's own markers don't exist yet in the target, the
    section is created automatically (at the end of the file, or in a new
    file) and the fragment is inserted inside it.

.EXAMPLE
    # Inject AGENTS-md-fragment.md into AGENTS.md
    $result = & .agents/spear/skills/vibeshield-bicep/scripts/Install-VibeShieldFragment.ps1 `
        -SourcePath '.agents/spear/skills/vibeshield-bicep/assets/AGENTS-md-fragment.md' `
        -TargetPath 'AGENTS.md' `
        -SectionMarker 'automated-agents'

.EXAMPLE
    # Inject into CLAUDE.md (creates the file if it does not exist)
    $result = & .agents/spear/skills/vibeshield-bicep/scripts/Install-VibeShieldFragment.ps1 `
        -SourcePath '.agents/spear/skills/vibeshield-bicep/assets/AGENTS-md-fragment.md' `
        -TargetPath 'CLAUDE.md' `
        -SectionMarker 'automated-agents'

.NOTES
    Exit Codes:
      0 - Always (caller interprets result via stdout word)
    Stdout:
      CREATED  - Fragment inserted for the first time (including file creation)
      UPDATED  - Existing marker block replaced
      SKIPPED  - Source file not found
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$TargetPath,

    [string]$SectionMarker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if (-not (Test-Path $SourcePath)) {
    Write-Host "  WARNING: Source fragment not found at $SourcePath" -ForegroundColor Yellow
    Write-Output 'SKIPPED'
    exit 0
}

# ---------------------------------------------------------------------------
# Read source fragment and extract marker name
# ---------------------------------------------------------------------------
$sourceContent = Get-Content -Path $SourcePath -Raw

if ($sourceContent -notmatch '<!--\s*BEGIN:(\S+)\s*-->') {
    Write-Host "  WARNING: No <!-- BEGIN:xxx --> marker found in $SourcePath" -ForegroundColor Yellow
    Write-Output 'SKIPPED'
    exit 0
}

$markerName = $Matches[1]
$targetFileName = Split-Path $TargetPath -Leaf

# Escape $ for use in -replace replacement strings so that characters like
# $1 or $& in source content are treated as literals, not regex backreferences.
$safeReplacement = $sourceContent.Replace('$', '$$')

# ---------------------------------------------------------------------------
# Helper: build a new section block with the fragment inside it
# ---------------------------------------------------------------------------
function Build-SectionBlock {
    $sectionBlock = "## Automated Agents`r`n"
    $sectionBlock += "<!-- BEGIN:$SectionMarker -->`r`n"
    $sectionBlock += $sourceContent
    if (-not $sourceContent.EndsWith("`n")) { $sectionBlock += "`r`n" }
    $sectionBlock += "<!-- END:$SectionMarker -->`r`n"
    return $sectionBlock
}

# ---------------------------------------------------------------------------
# Case 1: Target file does not exist - create it with section and fragment
# ---------------------------------------------------------------------------
if (-not (Test-Path $TargetPath)) {
    $targetDir = Split-Path $TargetPath -Parent
    if ($targetDir -and -not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if ($SectionMarker) {
        $newContent = Build-SectionBlock
    } else {
        $newContent = $sourceContent
    }
    Set-Content -Path $TargetPath -Value $newContent -NoNewline -Encoding utf8
    Write-Host "  CREATED: $targetFileName ($markerName section created in new file)" -ForegroundColor Green
    Write-Output 'CREATED'
    exit 0
}

# ---------------------------------------------------------------------------
# Case 2+: Target file exists - read and determine injection strategy
# ---------------------------------------------------------------------------
$existingContent = Get-Content -Path $TargetPath -Raw

if ($existingContent -match "<!--\s*BEGIN:$markerName\s*-->") {
    # Case 2a: Fragment marker already present - replace (idempotent update)
    $pattern = "(?s)<!--\s*BEGIN:$markerName\s*-->.*?<!--\s*END:$markerName\s*-->\r?\n?"
    $newContent = $existingContent -replace $pattern, $safeReplacement
    Set-Content -Path $TargetPath -Value $newContent -NoNewline -Encoding utf8
    Write-Host "  UPDATED: $targetFileName ($markerName section replaced)" -ForegroundColor Green
    Write-Output 'UPDATED'
} elseif ($SectionMarker -and ($existingContent -match "<!--\s*END:$SectionMarker\s*-->")) {
    # Case 2b: Section end marker present - inject fragment before it
    $endPattern = "(<!--\s*END:$SectionMarker\s*-->)"
    $newContent = $existingContent -replace $endPattern, "$safeReplacement`$1"
    Set-Content -Path $TargetPath -Value $newContent -NoNewline -Encoding utf8
    Write-Host "  CREATED: $targetFileName ($markerName section injected)" -ForegroundColor Green
    Write-Output 'CREATED'
} else {
    # Case 2c: No insertion point - append section block at end of file
    $trailing = if ($existingContent -and -not $existingContent.EndsWith("`n")) { "`r`n`r`n" } else { "`r`n" }
    if ($SectionMarker) {
        $newContent = $existingContent + $trailing + (Build-SectionBlock)
    } else {
        $newContent = $existingContent + $trailing + $sourceContent
    }
    Set-Content -Path $TargetPath -Value $newContent -NoNewline -Encoding utf8
    Write-Host "  CREATED: $targetFileName ($markerName section appended)" -ForegroundColor Green
    Write-Output 'CREATED'
}

exit 0

