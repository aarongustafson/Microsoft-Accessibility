<#
.SYNOPSIS
    Integrates vibeshield-bicep delegation into spec-kit agent files and
    installs extensions.yml hooks as a durable safety net.

.DESCRIPTION
    Two-layer integration of vibeshield-bicep into the spec-kit agent lifecycle:

    Layer 1 - Agent file patching (Primary):
      Patches spec-kit agent markdown files (.github/agents/speckit.*.agent.md)
      to enable delegation to @vibeshield-bicep and @vibeshield-powershell.
      Two injection types per agent:
        a) YAML frontmatter 'agents:' key - enables the agent to invoke
           vibeshield sub-agents (merge-safe, only for agents that generate code)
        b) Marker-delimited body instructions - tells the agent when and how
           to delegate (idempotent, append-to-end fallback)

    Layer 2 - Extensions.yml safety net (Durable):
      Installs .specify/extensions.yml with vibeshield-bicep hooks at spec-kit
      lifecycle boundaries (before_plan, after_implement, etc.). This file
      survives 'specify init --force' because the specify CLI does not manage
      extensions.yml. Even if agent file patches are wiped, the hooks still fire.

    This script is idempotent and safe to re-run after 'specify init --force'
    overwrites the spec-kit agent files.

    Configured agents and their integration:
      speckit.plan       - agents: frontmatter + body delegation
      speckit.implement  - agents: frontmatter + body delegation
      speckit.tasks      - agents: frontmatter + body delegation
      speckit.specify    - body delegation only (no code generation)
      speckit.clarify    - body delegation only (no code generation)

    Marker name: vibeshield-bicep-delegation
    This script only adds 'vibeshield-bicep' to frontmatter agents: lists.
    The vibeshield-powershell skill has its own Install-SpecKitIntegration.ps1
    that independently adds 'vibeshield-powershell'. Both are merge-safe.

.PARAMETER ProjectPath
    Required. Path to the project root where .github/agents/ and .specify/
    directories live.

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

Write-Host 'Integrating vibeshield-bicep into spec-kit agents...' -ForegroundColor Cyan

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
# Each entry defines: AgentFile, AgentsToAdd (empty = body-only), FragmentFile
$agentConfigs = @(
    @{
        AgentFile   = 'speckit.plan.agent.md'
        AgentsToAdd = @('vibeshield-bicep')
        FragmentFile = 'speckit.plan.delegation.md'
    },
    @{
        AgentFile   = 'speckit.implement.agent.md'
        AgentsToAdd = @('vibeshield-bicep')
        FragmentFile = 'speckit.implement.delegation.md'
    },
    @{
        AgentFile   = 'speckit.tasks.agent.md'
        AgentsToAdd = @('vibeshield-bicep')
        FragmentFile = 'speckit.tasks.delegation.md'
    },
    @{
        AgentFile   = 'speckit.specify.agent.md'
        AgentsToAdd = @()
        FragmentFile = 'speckit.specify.delegation.md'
    },
    @{
        AgentFile   = 'speckit.clarify.agent.md'
        AgentsToAdd = @()
        FragmentFile = 'speckit.clarify.delegation.md'
    }
)

# ---------------------------------------------------------------------------
# Part A: Patch agent files
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
    # A1: Frontmatter agents: injection (if agents configured)
    # -----------------------------------------------------------------
    if ($config.AgentsToAdd.Count -gt 0) {
        # Extract frontmatter (between first --- and second ---)
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
    }

    # -----------------------------------------------------------------
    # A2: Body delegation injection (marker-based)
    # -----------------------------------------------------------------
    $fragmentContent = Get-Content -Path $fragmentPath -Raw
    $markerName = 'vibeshield-bicep-delegation'

    # Migration: remove old shared 'vibeshield-delegation' marker if present
    $oldMarkerName = 'vibeshield-delegation'
    if ($fileContent -match "<!--\s*BEGIN:$oldMarkerName\s*-->") {
        $oldPattern = "(?s)<!--\s*BEGIN:$oldMarkerName\s*-->.*?<!--\s*END:$oldMarkerName\s*-->\r?\n?"
        $fileContent = $fileContent -replace $oldPattern, ''
        $fileModified = $true
    }

    if ($fileContent -match "<!--\s*BEGIN:$markerName\s*-->") {
        # Replace existing marker block (idempotent update)
        $pattern = "(?s)<!--\s*BEGIN:$markerName\s*-->.*?<!--\s*END:$markerName\s*-->\r?\n?"
        $fileContent = $fileContent -replace $pattern, $fragmentContent
        if (-not $fileModified) {
            # Check if content actually changed
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
            # Determine if this is a first injection or update
            $existingHadMarker = $existingRaw -match "<!--\s*BEGIN:$markerName\s*-->" -or
                                 $existingRaw -match "<!--\s*BEGIN:$oldMarkerName\s*-->"
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
# Part B: Install/merge extensions.yml
# ---------------------------------------------------------------------------
$specifyDir = Join-Path -Path $ProjectPath -ChildPath '.specify'
$extensionsTarget = Join-Path $specifyDir 'extensions.yml'
$extensionsSource = Join-Path $fragmentsDir 'extensions.yml'

if (-not (Test-Path $specifyDir)) {
    Write-Host '  SKIPPED: .specify/ directory not found (spec-kit not initialized)' -ForegroundColor Cyan
    $skippedCount++
} elseif (-not (Test-Path $extensionsSource)) {
    Write-Host '  WARNING: extensions.yml template not found in assets' -ForegroundColor Yellow
    $skippedCount++
} elseif (-not (Test-Path $extensionsTarget)) {
    # First install - copy template
    Copy-Item -Path $extensionsSource -Destination $extensionsTarget
    Write-Host '  CREATED: .specify/extensions.yml (vibeshield-bicep hooks installed)' -ForegroundColor Green
    $createdCount++
} else {
    # Extensions.yml already exists - check if vibeshield-bicep hooks are present
    $existingContent = Get-Content -Path $extensionsTarget -Raw
    if ($existingContent -match 'extension:\s*vibeshield-bicep') {
        Write-Host '  SKIPPED: .specify/extensions.yml (vibeshield-bicep hooks already present)' -ForegroundColor Cyan
        $skippedCount++
    } else {
        # Merge: append vibeshield-bicep hook entries
        # Read the source template and extract only the hook entries (skip comments header)
        $sourceContent = Get-Content -Path $extensionsSource -Raw
        # Find the hooks: line and everything after it
        if ($sourceContent -match '(?s)(hooks:\r?\n.+)$') {
            $hookContent = $Matches[1]
            # If existing file already has hooks: key, append entries under each hook key
            if ($existingContent -match 'hooks:') {
                # Append the vibeshield entries as a comment-separated block at the end
                $mergedContent = $existingContent.TrimEnd() + "`n`n# --- vibeshield-bicep hooks (auto-injected) ---`n"
                # Extract individual hook sections from source (skip the hooks: key itself)
                $hookEntries = $hookContent -replace '^hooks:\r?\n', ''
                $mergedContent += $hookEntries
                Set-Content -Path $extensionsTarget -Value $mergedContent -NoNewline -Encoding utf8
            } else {
                # No hooks: key - append the full hooks block
                $mergedContent = $existingContent.TrimEnd() + "`n`n" + $hookContent
                Set-Content -Path $extensionsTarget -Value $mergedContent -NoNewline -Encoding utf8
            }
            Write-Host '  UPDATED: .specify/extensions.yml (vibeshield-bicep hooks merged)' -ForegroundColor Green
            $updatedCount++
        } else {
            Write-Host '  WARNING: Could not parse hooks from extensions.yml template' -ForegroundColor Yellow
            $skippedCount++
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Spec-kit integration complete: $createdCount created, $updatedCount updated, $skippedCount skipped." -ForegroundColor Green
exit 0
