<#
.SYNOPSIS
    Integrates vibeshield-powershell delegation into spec-kit agent files.

.DESCRIPTION
    Patches spec-kit agent markdown files (.github/agents/speckit.*.agent.md)
    to enable delegation to @vibeshield-powershell. Two injection types per agent:
      a) YAML frontmatter 'agents:' key - enables the agent to invoke
         vibeshield-powershell (merge-safe, only for agents that generate code)
      b) Marker-delimited body instructions - tells the agent when and how
         to delegate (idempotent, append-to-end fallback)

    This script is idempotent and safe to re-run after 'specify init --force'
    overwrites the spec-kit agent files.

    Configured agents and their integration:
      speckit.plan       - agents: frontmatter + body delegation
      speckit.implement  - agents: frontmatter + body delegation
      speckit.tasks      - agents: frontmatter + body delegation

    Marker name: vibeshield-powershell-delegation
    This script only adds 'vibeshield-powershell' to frontmatter agents: lists.
    The vibeshield-bicep skill has its own Install-SpecKitIntegration.ps1
    that independently adds 'vibeshield-bicep'. Both are merge-safe.

.PARAMETER ProjectPath
    Required. Path to the project root where .github/agents/ lives.

.EXAMPLE
    pwsh -NoProfile -File Install-SpecKitIntegration.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes:
      0 - Completed (items created, updated, and/or skipped)
      1 - Hard error (missing assets directory)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)

Write-Host 'Integrating vibeshield-powershell into spec-kit agents...' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Tracking counters
# ---------------------------------------------------------------------------
$createdCount = 0
$updatedCount = 0
$skippedCount = 0

# ---------------------------------------------------------------------------
# Resolve fragment assets directory
# ---------------------------------------------------------------------------
$fragmentsDir = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'assets' 'speckit-fragments')
if (-not (Test-Path $fragmentsDir)) {
    Write-Host "  ERROR: Speckit fragments directory not found at $fragmentsDir" -ForegroundColor Red
    exit 1
}
$fragmentsDir = [System.IO.Path]::GetFullPath($fragmentsDir)

# ---------------------------------------------------------------------------
# Agent integration configuration
# ---------------------------------------------------------------------------
# Each entry defines: AgentFile, AgentsToAdd, FragmentFile
$agentConfigs = @(
    @{
        AgentFile    = 'speckit.plan.agent.md'
        AgentsToAdd  = @('vibeshield-powershell')
        FragmentFile = 'speckit.plan.delegation.md'
    },
    @{
        AgentFile    = 'speckit.implement.agent.md'
        AgentsToAdd  = @('vibeshield-powershell')
        FragmentFile = 'speckit.implement.delegation.md'
    },
    @{
        AgentFile    = 'speckit.tasks.agent.md'
        AgentsToAdd  = @('vibeshield-powershell')
        FragmentFile = 'speckit.tasks.delegation.md'
    }
)

# ---------------------------------------------------------------------------
# Patch agent files
# ---------------------------------------------------------------------------
$agentsDir = Join-Path -Path (Join-Path -Path $ProjectPath -ChildPath '.github') -ChildPath 'agents'

foreach ($config in $agentConfigs) {
    $agentPath = Join-Path $agentsDir $config.AgentFile
    $fragmentPath = Join-Path $fragmentsDir $config.FragmentFile

    # Check agent file exists (speckit may not be installed)
    if (-not (Test-Path $agentPath)) {
        Write-Host "  SKIPPED: $($config.AgentFile) (not found)" -ForegroundColor Cyan
        $skippedCount++
        continue
    }

    # Check fragment file exists
    if (-not (Test-Path $fragmentPath)) {
        Write-Host "  WARNING: Fragment $($config.FragmentFile) not found in assets" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    $fileContent = Get-Content -Path $agentPath -Raw
    $fileModified = $false
    $agentFileName = $config.AgentFile

    # -----------------------------------------------------------------
    # Frontmatter agents: injection
    # -----------------------------------------------------------------
    if ($fileContent -match '(?s)^---\r?\n(.*?)\r?\n---') {
        $frontmatter = $Matches[1]
        $originalFrontmatter = $frontmatter

        if ($frontmatter -match "agents:\s*\[([^\]]*)\]") {
            # agents: key exists - parse and merge
            $existingAgentsRaw = $Matches[1]
            $existingAgents = @($existingAgentsRaw -split ',' |
                ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $agentsToMerge = @($config.AgentsToAdd | Where-Object { $_ -notin $existingAgents })

            if ($agentsToMerge.Count -gt 0) {
                $mergedAgents = @($existingAgents) + @($agentsToMerge)
                $agentsList = ($mergedAgents | ForEach-Object { "'$_'" }) -join ', '
                $newAgentsLine = "agents: [$agentsList]"
                $frontmatter = $frontmatter -replace "agents:\s*\[[^\]]*\]", $newAgentsLine
                $fileModified = $true
            }
        } else {
            # agents: key doesn't exist - insert before closing ---
            $agentsList = ($config.AgentsToAdd | ForEach-Object { "'$_'" }) -join ', '
            $frontmatter = $frontmatter + "`nagents: [$agentsList]"
            $fileModified = $true
        }

        if ($fileModified) {
            $fileContent = $fileContent -replace ('(?s)^---\r?\n' + [regex]::Escape($originalFrontmatter) + '\r?\n---'), "---`n$frontmatter`n---"
        }
    }

    # -----------------------------------------------------------------
    # Body delegation injection (marker-based)
    # -----------------------------------------------------------------
    $fragmentContent = Get-Content -Path $fragmentPath -Raw
    $markerName = 'vibeshield-powershell-delegation'

    if ($fileContent -match "<!--\s*BEGIN:$markerName\s*-->") {
        # Replace existing marker block (idempotent update)
        $pattern = "(?s)<!--\s*BEGIN:$markerName\s*-->.*?<!--\s*END:$markerName\s*-->\r?\n?"
        $fileContent = $fileContent -replace $pattern, $fragmentContent
        if (-not $fileModified) {
            $existingRaw = Get-Content -Path $agentPath -Raw
            if ($existingRaw -ne $fileContent) {
                $fileModified = $true
            }
        } else {
            $fileModified = $true
        }
    } else {
        # Append to end of file (first injection)
        $separator = "`n`n"
        if ($fileContent -match '\r?\n$') {
            $separator = "`n"
        }
        $fileContent = $fileContent.TrimEnd() + $separator + $fragmentContent + "`n"
        $fileModified = $true
    }

    # -----------------------------------------------------------------
    # Write back if modified
    # -----------------------------------------------------------------
    if ($fileModified) {
        $existingRaw = Get-Content -Path $agentPath -Raw
        if ($existingRaw -eq $fileContent) {
            Write-Host "  SKIPPED: $agentFileName (already up to date)" -ForegroundColor Cyan
            $skippedCount++
        } else {
            Set-Content -Path $agentPath -Value $fileContent -NoNewline -Encoding utf8
            $existingHadMarker = $existingRaw -match "<!--\s*BEGIN:$markerName\s*-->"
            if ($existingHadMarker) {
                Write-Host "  UPDATED: $agentFileName (delegation refreshed)" -ForegroundColor Green
                $updatedCount++
            } else {
                Write-Host "  CREATED: $agentFileName (delegation injected)" -ForegroundColor Green
                $createdCount++
            }
        }
    } else {
        Write-Host "  SKIPPED: $agentFileName (already up to date)" -ForegroundColor Cyan
        $skippedCount++
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Spec-kit integration complete: $createdCount created, $updatedCount updated, $skippedCount skipped." -ForegroundColor Green
exit 0
