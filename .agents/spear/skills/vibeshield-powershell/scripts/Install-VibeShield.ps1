<#
.SYNOPSIS
    Installs vibeshield-powershell skill assets into the target project.

.DESCRIPTION
    Copies path-specific instruction files, creates .github\copilot-instructions.md
    from a template if it doesn't exist, and injects the copilot-instructions
    entry for the vibeshield-powershell skill via Install-VibeShieldFragment.ps1.
    Also injects the Automated Agents section into AGENTS.md and CLAUDE.md via
    Install-VibeShieldFragment.ps1.
    Existing files are never overwritten -- the script skips anything that already
    exists, except for the agent definition file which is always overwritten to
    ensure the latest version is deployed. Marker-based sections in
    copilot-instructions.md, AGENTS.md, and CLAUDE.md are updated idempotently.

    Why: Without these assets, agents editing .ps1 files won't automatically receive
    the project's PowerShell engineering standards. Path-specific instructions ensure
    the correct agent standards are applied even when @vibeshield-powershell is not
    explicitly invoked. The copilot-instructions entry makes the routing visible in
    the repo-wide instructions file.

    Installed assets:
      .github\instructions\powershell.instructions.md -- Path-specific instructions that
          auto-apply when any agent edits files matching **/*.ps1 or **/*.psm1.
          See: https://code.visualstudio.com/docs/copilot/copilot-customization#_instruction-files
      .github\copilot-instructions.md -- Created from copilot-instructions-template.md
          if the file does not already exist, then the vibeshield-powershell marker section
          is injected/updated via Install-VibeShieldFragment.ps1. This is the repo-wide
          instructions file loaded into every Copilot interaction.
          See: https://code.visualstudio.com/docs/copilot/copilot-customization#_repo-wide-custom-instructions
      AGENTS.md -- Marker section injected/updated. The Automated Agents entry
          for vibeshield-powershell, managed via Install-VibeShieldFragment.ps1.
      CLAUDE.md -- Marker section injected/updated. Same content as AGENTS.md,
          for Claude Code agent context.
      .github\agents\vibeshield-powershell.agent.md -- Agent definition file that registers
          the vibeshield-powershell agent in the project. Always overwritten to ensure
          the latest version from the skill is deployed.
      .github\hooks\validate-powershell.json -- PostToolUse hook that triggers
          PSScriptAnalyzer validation after every file edit. Always overwritten
          to ensure the latest version from the skill is deployed.
    Delegated to Install-SkillRuntime.ps1:
      .github\skills\vibeshield-powershell\SKILL.md -- Skill documentation.
          Always overwritten to ensure the latest version from the skill is deployed.
      .github\skills\vibeshield-powershell\scripts\Invoke-PSScriptAnalyzer.ps1 --
          Tier 1 single-file PSScriptAnalyzer analysis. Always overwritten.
      .github\skills\vibeshield-powershell\scripts\Invoke-PSScriptAnalyzerHook.ps1 --
          PostToolUse hook wrapper. Always overwritten.
      .github\skills\vibeshield-powershell\scripts\Test-PowerShellScripts.ps1 --
          Tier 2 checkpoint scan (all files). Always overwritten.
      .vscode\settings.json -- VS Code per-script auto-approve entries for
          vibeshield-powershell terminal commands. Additive merge (preserves
          existing settings).

    Delegated to Install-VsCodeExtensions.ps1:
      .vscode\extensions.json -- Adds extension recommendation for
          ms-vscode.PowerShell. Best-effort install via code CLI if available.

    Delegated to Install-SpecKitIntegration.ps1:
      .github\agents\speckit.*.agent.md -- Patches spec-kit agent files with
          agents: frontmatter and body delegation instructions so spec-kit
          agents delegate PowerShell work to @vibeshield-powershell. Idempotent
          and safe to re-run after 'specify init --force'.

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script walks up from
    $PSScriptRoot to find the .git directory, falling back to the current working directory.

.PARAMETER Branch
    Source branch passed from the installer. Default: "main". Accepted for
    interface compatibility with the VibeShield installer but not used by this
    skill (assets are copied from the local skill directory).

.EXAMPLE
    pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Install-VibeShield.ps1

.NOTES
    Exit Codes:
      0 - Installation completed successfully (items created and/or skipped)
#>


[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Vibeshield.CapabilityContract.psm1')

function Invoke-InstallVibeShieldPowerShell {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,

        [string]$Branch = 'main',

        [Parameter(DontShow = $true)]
        [scriptblock]$ScriptInvoker = {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ScriptPath,

                [Parameter(Mandatory = $true)]
                [hashtable]$Arguments
            )

            # Child .ps1 'exit N' returns control without throwing under
            # $ErrorActionPreference='Stop'. Pin LASTEXITCODE before invoke
            # and throw on non-zero so the parent's catch writes status=fail.
            $global:LASTEXITCODE = 0
            & $ScriptPath @Arguments
            $childExit = $LASTEXITCODE
            if ($null -ne $childExit -and $childExit -ne 0) {
                throw ('SUBSCRIPT_FAILED: child script exited with code ' + $childExit)
            }
        }
    )

    $null = $Branch
    $phase = 'initialization'
    $capabilityResultWritten = $false

    try {
        $phase = 'resolve-project-root'

        # ---------------------------------------------------------------------------
        # Resolve project root: use parameter or shared resolver
        # ---------------------------------------------------------------------------
        . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
        if ($ProjectPath) {
            $projectRoot = $ProjectPath
        } else {
            $projectRoot = Resolve-RepoRoot
            if (-not $projectRoot) { $projectRoot = (Get-Location).Path }
        }

        $projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

        Write-Host "Installing vibeshield-powershell assets at: $projectRoot" -ForegroundColor Cyan

        $phase = 'tracking'

        # ---------------------------------------------------------------------------
        # Tracking counters
        # ---------------------------------------------------------------------------
        $createdCount = 0
        $skippedCount = 0
        $overwrittenCount = 0

        # ---------------------------------------------------------------------------
        # Resolve assets directory
        # ---------------------------------------------------------------------------
        $phase = 'assets'
        $assetsDir = Join-Path (Join-Path $PSScriptRoot '..') 'assets'
        if (-not (Test-Path $assetsDir)) {
            Write-Host '  ERROR: Assets directory not found' -ForegroundColor Red
            Set-VibeShieldCapabilityResult -Status fail -Message 'ASSET_MISSING: vibeshield-powershell assets directory' -Details @{ phase = $phase }
            $capabilityResultWritten = $true
            throw 'ASSET_MISSING: vibeshield-powershell assets directory'
        }
        $assetsDir = [System.IO.Path]::GetFullPath($assetsDir)

        $phase = 'instructions'

        # ---------------------------------------------------------------------------
        # 1. Install path-specific instructions file
        # ---------------------------------------------------------------------------
        $instructionsDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'instructions'
        $instructionSource = Join-Path $assetsDir 'powershell.instructions.md'
        $instructionTarget = Join-Path $instructionsDir 'powershell.instructions.md'

        if (Test-Path $instructionSource) {
            if (-not (Test-Path $instructionsDir)) {
                New-Item -ItemType Directory -Path $instructionsDir -Force | Out-Null
            }
            if (-not (Test-Path $instructionTarget)) {
                Copy-Item -Path $instructionSource -Destination $instructionTarget
                Write-Host '  CREATED: .github\instructions\powershell.instructions.md' -ForegroundColor Green
                $createdCount++
            } else {
                Write-Host '  SKIPPED: .github\instructions\powershell.instructions.md (already exists)' -ForegroundColor Cyan
                $skippedCount++
            }
        } else {
            Write-Host '  WARNING: powershell.instructions.md not found in skill assets' -ForegroundColor Yellow
        }

        $phase = 'fragment-script'

        # ---------------------------------------------------------------------------
        # Resolve fragment injection script (used by sections 2 and 3)
        # ---------------------------------------------------------------------------
        $fragmentScript = Join-Path $PSScriptRoot 'Install-VibeShieldFragment.ps1'
        if (-not (Test-Path $fragmentScript)) {
            $fragmentScript = [System.IO.Path]::GetFullPath($fragmentScript)
        }

        $phase = 'copilot-instructions'

        # ---------------------------------------------------------------------------
        # 2. Inject copilot-instructions entry (idempotent, marker-based)
        #    Creates .github\copilot-instructions.md from template if it doesn't exist,
        #    then delegates marker injection to Install-VibeShieldFragment.ps1.
        # ---------------------------------------------------------------------------
        $githubDir = Join-Path -Path $projectRoot -ChildPath '.github'
        $copilotInstructionsPath = Join-Path -Path $githubDir -ChildPath 'copilot-instructions.md'
        $entrySource = Join-Path $assetsDir 'copilot-instructions-entry.md'
        $templateSource = Join-Path $assetsDir 'copilot-instructions-template.md'

        # Create from template if missing
        if (-not (Test-Path $copilotInstructionsPath)) {
            if (Test-Path $templateSource) {
                if (-not (Test-Path $githubDir)) {
                    New-Item -ItemType Directory -Path $githubDir -Force | Out-Null
                }
                Copy-Item -Path $templateSource -Destination $copilotInstructionsPath
                Write-Host '  CREATED: .github\copilot-instructions.md (from template)' -ForegroundColor Green
                $createdCount++
            } else {
                Write-Host '  WARNING: copilot-instructions-template.md not found in skill assets' -ForegroundColor Yellow
            }
        }

        # Inject entry via Install-VibeShieldFragment.ps1
        if ((Test-Path $entrySource) -and (Test-Path $copilotInstructionsPath)) {
            $result = & $ScriptInvoker -ScriptPath $fragmentScript -Arguments @{ SourcePath = $entrySource; TargetPath = $copilotInstructionsPath; SectionMarker = 'path-specific-instructions' }
            if ($result -eq 'CREATED' -or $result -eq 'UPDATED') {
                $createdCount++
            } elseif ($result -eq 'SKIPPED') {
                $skippedCount++
            }
        } elseif (-not (Test-Path $entrySource)) {
            Write-Host '  WARNING: copilot-instructions-entry.md not found in skill assets' -ForegroundColor Yellow
        } else {
            Write-Host '  SKIPPED: .github\copilot-instructions.md could not be created (no injection)' -ForegroundColor Cyan
            $skippedCount++
        }

        $phase = 'automated-agents'

        # ---------------------------------------------------------------------------
        # 3. Inject AGENTS.md and CLAUDE.md entries (idempotent, marker-based)
        # ---------------------------------------------------------------------------
        $agentsMdEntry = Join-Path $assetsDir 'AGENTS-md-fragment.md'

        if (Test-Path $agentsMdEntry) {
            foreach ($targetFile in @('AGENTS.md', 'CLAUDE.md')) {
                $targetPath = Join-Path $projectRoot $targetFile
                if (Test-Path $targetPath) {
                    $result = & $ScriptInvoker -ScriptPath $fragmentScript -Arguments @{ SourcePath = $agentsMdEntry; TargetPath = $targetPath; SectionMarker = 'automated-agents' }
                    if ($result -eq 'CREATED' -or $result -eq 'UPDATED') {
                        $createdCount++
                    } elseif ($result -eq 'SKIPPED') {
                        $skippedCount++
                    }
                } else {
                    Write-Host "  SKIPPED: $targetFile not found (no injection)" -ForegroundColor Cyan
                    $skippedCount++
                }
            }
        } else {
            Write-Host '  WARNING: AGENTS-md-fragment.md not found in skill assets' -ForegroundColor Yellow
        }

        $phase = 'agent-definition'

        # ---------------------------------------------------------------------------
        # 4. Install agent definition file (always overwrite)
        # ---------------------------------------------------------------------------
        $agentsDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'agents'
        $agentSource = Join-Path $assetsDir 'vibeshield-powershell.agent.md'
        $agentTarget = Join-Path $agentsDir 'vibeshield-powershell.agent.md'

        if (Test-Path $agentSource) {
            if (-not (Test-Path $agentsDir)) {
                New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            }
            if (Test-Path $agentTarget) {
                Copy-Item -Path $agentSource -Destination $agentTarget -Force
                Write-Host '  OVERWRITTEN: .github\agents\vibeshield-powershell.agent.md' -ForegroundColor Green
                $overwrittenCount++
            } else {
                Copy-Item -Path $agentSource -Destination $agentTarget
                Write-Host '  CREATED: .github\agents\vibeshield-powershell.agent.md' -ForegroundColor Green
                $createdCount++
            }
        } else {
            Write-Host '  WARNING: vibeshield-powershell.agent.md not found in skill assets' -ForegroundColor Yellow
        }

        $phase = 'hook'

        # ---------------------------------------------------------------------------
        # 5. Install hook file (always overwrite)
        # ---------------------------------------------------------------------------
        $hooksDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'hooks'
        $hookSource = Join-Path (Join-Path $assetsDir 'hooks') 'validate-powershell.json'
        $hookTarget = Join-Path $hooksDir 'validate-powershell.json'

        if (Test-Path $hookSource) {
            if (-not (Test-Path $hooksDir)) {
                New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
            }
            if (Test-Path $hookTarget) {
                Copy-Item -Path $hookSource -Destination $hookTarget -Force
                Write-Host '  OVERWRITTEN: .github\hooks\validate-powershell.json' -ForegroundColor Green
                $overwrittenCount++
            } else {
                Copy-Item -Path $hookSource -Destination $hookTarget
                Write-Host '  CREATED: .github\hooks\validate-powershell.json' -ForegroundColor Green
                $createdCount++
            }
        } else {
            Write-Host '  WARNING: validate-powershell.json not found in skill assets' -ForegroundColor Yellow
        }

        # ---------------------------------------------------------------------------
        # 6. Install skill runtime files (delegate to Install-SkillRuntime.ps1)
        # ---------------------------------------------------------------------------
        $phase = 'skill-runtime'
        $skillRuntimeScript = Join-Path $PSScriptRoot 'Install-SkillRuntime.ps1'
        if (Test-Path $skillRuntimeScript) {
            $null = & $ScriptInvoker -ScriptPath $skillRuntimeScript -Arguments @{ ProjectPath = $projectRoot }
        } else {
            Write-Host '  ERROR: Install-SkillRuntime.ps1 not found' -ForegroundColor Red
            Set-VibeShieldCapabilityResult -Status fail -Message 'PREREQ_MISSING: Install-SkillRuntime.ps1' -Details @{ phase = $phase }
            $capabilityResultWritten = $true
            throw 'PREREQ_MISSING: Install-SkillRuntime.ps1'
        }

        $phase = 'vscode-extensions'

        # ---------------------------------------------------------------------------
        # 7. Install VS Code extension recommendations
        # ---------------------------------------------------------------------------
        $extensionsScript = Join-Path $PSScriptRoot 'Install-VsCodeExtensions.ps1'
        if (Test-Path $extensionsScript) {
            $null = & $ScriptInvoker -ScriptPath $extensionsScript -Arguments @{ ProjectPath = $projectRoot }
        } else {
            Write-Host '  SKIPPED: Install-VsCodeExtensions.ps1 not found' -ForegroundColor Cyan
        }

        $phase = 'speckit-integration'

        # ---------------------------------------------------------------------------
        # 8. Integrate with spec-kit agents (delegate to Install-SpecKitIntegration.ps1)
        # ---------------------------------------------------------------------------

        $specKitIntegrationScript = Join-Path $PSScriptRoot 'Install-SpecKitIntegration.ps1'
        if (Test-Path $specKitIntegrationScript) {
            Write-Host '' -ForegroundColor Cyan
            $null = & $ScriptInvoker -ScriptPath $specKitIntegrationScript -Arguments @{ ProjectPath = $projectRoot }
        } else {
            Write-Host '  SKIPPED: Install-SpecKitIntegration.ps1 not found (spec-kit integration unavailable)' -ForegroundColor Cyan
        }

        $phase = 'summary'

        # ---------------------------------------------------------------------------
        # Summary
        # ---------------------------------------------------------------------------
        Write-Host ''
        Write-Host "vibeshield-powershell install complete: $createdCount created, $overwrittenCount overwritten, $skippedCount skipped." -ForegroundColor Green
        Set-VibeShieldCapabilityResult -Status ok -Message 'vibeshield-powershell install complete' -Details @{ created = $createdCount; overwritten = $overwrittenCount; skipped = $skippedCount }
        $capabilityResultWritten = $true
        return
    }
    catch {
        if (-not $capabilityResultWritten) {
            Set-VibeShieldCapabilityResult -Status fail -Message 'INSTALL_FAILED: vibeshield-powershell' -Details @{ phase = $phase }
        }
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallVibeShieldPowerShell @PSBoundParameters
}
