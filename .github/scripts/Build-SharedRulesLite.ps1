<#
.SYNOPSIS
    Generates deploy-shared-rules-lite.prompt.md from the full shared-rules
    by stripping the "Environment-Aware Deployment Modes" section.

.DESCRIPTION
    Pipeline-push and monitor agents do not need the env section (~104 lines).
    This script produces a lighter variant that saves ~400 tokens per agent turn.

    The lite file is GENERATED — edits must go to the full
    deploy-shared-rules.prompt.md, then this script re-run.

.PARAMETER Root
    Repository root directory. Defaults to two levels up from this script.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path (Split-Path -Path $PSScriptRoot -Parent) -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$monolithPath = Join-Path -Path $Root -ChildPath '.github' 'prompts' 'deploy-shared-rules.prompt.md'
$litePath     = Join-Path -Path $Root -ChildPath '.github' 'prompts' 'deploy-shared-rules-lite.prompt.md'

if (-not (Test-Path $monolithPath)) {
    Write-Error "Monolith not found: $monolithPath"
    $global:LASTEXITCODE = 1
    exit 1
}

$lines = Get-Content $monolithPath

# --- Locate YAML frontmatter end ---
$fmEnd = 0
if ($lines[0] -eq '---') {
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') {
            $fmEnd = $i + 1
            break
        }
    }
}

# --- Locate ## Environment-Aware Deployment Modes ---
$envStart = $null
$envEnd   = $null
for ($i = $fmEnd; $i -lt $lines.Count; $i++) {
    if ($null -eq $envStart -and $lines[$i] -match '^## Environment-Aware Deployment Modes') {
        $envStart = $i
    }
    elseif ($null -ne $envStart -and $null -eq $envEnd -and $i -gt $envStart -and $lines[$i] -match '^## ') {
        $envEnd = $i
        break
    }
}

if ($null -eq $envStart) {
    Write-Error "Could not find '## Environment-Aware Deployment Modes' heading in $monolithPath"
    $global:LASTEXITCODE = 1
    exit 1
}
if ($null -eq $envEnd) {
    Write-Error "Could not find the section following Environment-Aware in $monolithPath"
    $global:LASTEXITCODE = 1
    exit 1
}

# --- Build lite content ---
$liteHeader = @(
    '---'
    '# GENERATED FILE — do not edit directly.'
    '# Source: deploy-shared-rules.prompt.md (Environment-Aware section excluded).'
    '# Regenerate: pwsh .github/scripts/Build-SharedRulesLite.ps1'
    '---'
)

$bodyBefore = $lines[$fmEnd..($envStart - 1)]
$bodyAfter  = $lines[$envEnd..($lines.Count - 1)]

$liteContent = $liteHeader + $bodyBefore + $bodyAfter

Set-Content -Path $litePath -Value ($liteContent -join "`n") -NoNewline -Encoding UTF8

$envLines = $envEnd - $envStart
Write-Host "Generated: $litePath"
Write-Host "  Total lines : $($liteContent.Count)"
Write-Host "  Stripped     : $envLines lines (Environment-Aware Deployment Modes)"
Write-Host "  Source       : $monolithPath ($($lines.Count) lines)"
