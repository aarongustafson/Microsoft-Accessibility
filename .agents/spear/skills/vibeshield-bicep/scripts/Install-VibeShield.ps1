<#
.SYNOPSIS
    Installs vibeshield-bicep skill assets into the target project and scaffolds
    the Bicep project layout.

.DESCRIPTION
    Entry point for the vibeshield-bicep skill. Copies path-specific instruction
    files, creates .github\copilot-instructions.md from a template if it doesn't
    exist, injects the copilot-instructions entry for the vibeshield-bicep skill
    via Install-VibeShieldFragment.ps1, injects the Automated Agents section into
    AGENTS.md and CLAUDE.md via Install-VibeShieldFragment.ps1, and then delegates
    to Initialize-BicepProject.ps1 to scaffold the standard Bicep project layout
    (infra directory, main.bicep, modules, PSRule configs).

    Existing files are never overwritten -- the script skips anything that already
    exists, except for the agent definition file which is always overwritten to
    ensure the latest version is deployed. Marker-based sections in
    copilot-instructions.md are updated idempotently.

    Why: Without these assets, agents editing .bicep files won't automatically
    receive the project's Bicep engineering standards. Path-specific instructions
    ensure the correct agent standards are applied even when @vibeshield-bicep is
    not explicitly invoked. The copilot-instructions entry makes the routing
    visible in the repo-wide instructions file.

    Installed assets:
      .github\instructions\bicep.instructions.md -- Path-specific instructions that
          auto-apply when any agent edits files matching **/*.bicep.
          See: https://code.visualstudio.com/docs/copilot/copilot-customization#_instruction-files
      .github\copilot-instructions.md -- Created from copilot-instructions-template.md
          if the file does not already exist, then the vibeshield-bicep marker section
          is injected/updated via Install-VibeShieldFragment.ps1. This is the repo-wide
          instructions file loaded into every Copilot interaction.
          See: https://code.visualstudio.com/docs/copilot/copilot-customization#_repo-wide-custom-instructions
      AGENTS.md -- Marker section injected/updated. The Automated Agents entry
          for vibeshield-bicep, managed via Install-VibeShieldFragment.ps1.
      CLAUDE.md -- Marker section injected/updated. Same content as AGENTS.md,
          for Claude Code agent context.
      .github\agents\vibeshield-bicep.agent.md -- Agent definition file that registers
          the vibeshield-bicep agent in the project. Always overwritten to ensure the
          latest version from the skill is deployed.
      .github\hooks\validate-bicep.json -- PostToolUse hook that triggers Bicep
          linting after every file edit. Always overwritten to ensure the latest
          version from the skill is deployed.
    Delegated to Install-SkillRuntime.ps1:
      .github\skills\vibeshield-bicep\SKILL.md -- Skill documentation.
          Always overwritten to ensure the latest version from the skill is deployed.
      .github\skills\vibeshield-bicep\scripts\Invoke-BicepLint.ps1 --
          Tier 1 single-file Bicep lint. Always overwritten.
      .github\skills\vibeshield-bicep\scripts\Invoke-BicepLintHook.ps1 --
          PostToolUse hook wrapper. Always overwritten.
      .github\skills\vibeshield-bicep\scripts\Invoke-BicepValidation.ps1 --
          Tier 2 checkpoint validation (lint + PSRule). Always overwritten.
      .github\skills\vibeshield-bicep\scripts\Initialize-BicepProject.ps1 --
          Bicep project scaffolding. Always overwritten.
      .github\skills\vibeshield-bicep\references\*.md -- Reference documentation
          loaded on demand by agents. Always overwritten.
      .vscode\settings.json -- VS Code per-script auto-approve entries for
          vibeshield-bicep terminal commands. Additive merge (preserves
          existing settings).

    Delegated to Install-VsCodeExtensions.ps1:
      .vscode\extensions.json -- Adds extension recommendations for
          ms-azuretools.vscode-bicep and ms-azuretools.vscode-azure-mcp-server.
          Best-effort install via code CLI if available.

    Delegated to Install-McpConfig.ps1:
      .mcp.json -- Copilot CLI MCP server configuration at the repo root.
          Creates from asset template if missing, or additively merges server
          entries if the file exists but lacks the required Bicep/Azure MCP
          servers. Preserves existing MCP server configurations.

    Delegated to Install-SpecKitIntegration.ps1:
      .github\agents\speckit.*.agent.md -- Patches spec-kit agent files with
          agents: frontmatter and body delegation instructions so spec-kit
          agents delegate infrastructure work to @vibeshield-bicep. Idempotent
          and safe to re-run after 'specify init --force'.
      .specify\extensions.yml -- Installs lifecycle hooks that invoke
          @vibeshield-bicep at spec-kit boundaries (before_plan, after_implement,
          etc.). Survives 'specify init --force' as a durable safety net.

    Delegated to Initialize-BicepProject.ps1:
      infra\                    -- Infrastructure root
      infra\main.bicep          -- Main deployment entry point
      infra\modules\            -- Reusable Bicep modules
      infra\PSRule.dev.yaml     -- PSRule config for dev environment
      infra\PSRule.prod.yaml    -- PSRule config for prod environment
      output\                   -- Build artifacts (gitignored)

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script walks up from
    $PSScriptRoot to find the .git directory, falling back to the current working
    directory.

.PARAMETER Branch
    Source branch passed from the installer. Default: "main". Accepted for
    interface compatibility with the VibeShield installer but not used by this
    skill (assets are copied from the local skill directory).

.EXAMPLE
    # Install vibeshield-bicep at the repo root
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1

.EXAMPLE
    # Install at a specific path
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1 -ProjectPath C:\myproject

.NOTES
    Throws on failure and writes a VibeShield capability handshake when the
    installer supplies the required handshake environment variables.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Vibeshield.CapabilityContract.psm1') -Force

function Invoke-VibeShieldBicepScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$ProjectPath
    )

    # PIN $LASTEXITCODE before invoke; child .ps1 'exit N' returns control
    # without throwing under $ErrorActionPreference='Stop', so we must check
    # the exit code explicitly. Without this, a child failure silently bubbles
    # to the success-path helper write -- false 'status=ok' (contract bug).
    $global:LASTEXITCODE = 0
    & $ScriptPath -ProjectPath $ProjectPath
    $childExit = $LASTEXITCODE
    if ($null -ne $childExit -and $childExit -ne 0) {
        throw ('SUBSCRIPT_FAILED: child script exited with code ' + $childExit)
    }
}

function Invoke-VibeShieldBicepFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [string]$SectionMarker
    )

    $global:LASTEXITCODE = 0
    & $ScriptPath -SourcePath $SourcePath -TargetPath $TargetPath -SectionMarker $SectionMarker
    $childExit = $LASTEXITCODE
    if ($null -ne $childExit -and $childExit -ne 0) {
        throw ('SUBSCRIPT_FAILED: fragment script exited with code ' + $childExit)
    }
}

function Invoke-InstallVibeShieldBicep {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        [string]$Branch = 'main'
    )

    $resultWritten = $false

    try {
        $null = $Branch

        # -------------------------------------------------------------------
        # Resolve project root: use parameter or shared resolver
        # -------------------------------------------------------------------
        . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
        if ($ProjectPath) {
            $projectRoot = $ProjectPath
        } else {
            $projectRoot = Resolve-RepoRoot
            if (-not $projectRoot) { $projectRoot = (Get-Location).Path }
        }

        $projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

        Write-Host "Installing vibeshield-bicep assets at: $projectRoot" -ForegroundColor Cyan

        # -------------------------------------------------------------------
        # Tracking counters
        # -------------------------------------------------------------------
        $createdCount = 0
        $skippedCount = 0
        $overwrittenCount = 0

        # -------------------------------------------------------------------
        # Resolve assets directory
        # -------------------------------------------------------------------
        $assetsDir = Join-Path (Join-Path $PSScriptRoot '..') 'assets'
        if (-not (Test-Path $assetsDir)) {
            $message = 'ASSETS_MISSING: vibeshield-bicep assets'
            Set-VibeShieldCapabilityResult -Status fail -Message $message -Details @{
                code = 'ASSETS_MISSING'
                component = 'assets'
            }
            $resultWritten = $true
            throw $message
        }
        $assetsDir = [System.IO.Path]::GetFullPath($assetsDir)

        # -------------------------------------------------------------------
        # 1. Install path-specific instructions file
        # -------------------------------------------------------------------
        $instructionsDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'instructions'
        $instructionSource = Join-Path $assetsDir 'bicep.instructions.md'
        $instructionTarget = Join-Path $instructionsDir 'bicep.instructions.md'

        if (Test-Path $instructionSource) {
            if (-not (Test-Path $instructionsDir)) {
                New-Item -ItemType Directory -Path $instructionsDir -Force | Out-Null
            }
            if (-not (Test-Path $instructionTarget)) {
                Copy-Item -Path $instructionSource -Destination $instructionTarget
                Write-Host '  CREATED: .github\instructions\bicep.instructions.md' -ForegroundColor Green
                $createdCount++
            } else {
                Write-Host '  SKIPPED: .github\instructions\bicep.instructions.md (already exists)' -ForegroundColor Cyan
                $skippedCount++
            }
        } else {
            Write-Host '  WARNING: bicep.instructions.md not found in skill assets' -ForegroundColor Yellow
        }

        # -------------------------------------------------------------------
        # Resolve fragment injection script (used by sections 2 and 3)
        # -------------------------------------------------------------------
        $fragmentScript = Join-Path $PSScriptRoot 'Install-VibeShieldFragment.ps1'
        if (-not (Test-Path $fragmentScript)) {
            $message = 'SCRIPT_MISSING: Install-VibeShieldFragment.ps1'
            Set-VibeShieldCapabilityResult -Status fail -Message $message -Details @{
                code = 'SCRIPT_MISSING'
                script = 'Install-VibeShieldFragment.ps1'
            }
            $resultWritten = $true
            throw $message
        }

        # -------------------------------------------------------------------
        # 2. Inject copilot-instructions entry (idempotent, marker-based)
        #    Creates .github\copilot-instructions.md from template if it doesn't exist,
        #    then delegates marker injection to Install-VibeShieldFragment.ps1.
        # -------------------------------------------------------------------
        $githubDir = Join-Path -Path $projectRoot -ChildPath '.github'
        $copilotInstructionsPath = Join-Path -Path $githubDir -ChildPath 'copilot-instructions.md'
        $entrySource = Join-Path $assetsDir 'copilot-instructions-entry.md'
        $templateSource = Join-Path $assetsDir 'copilot-instructions-template.md'

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

        if ((Test-Path $entrySource) -and (Test-Path $copilotInstructionsPath)) {
            $result = Invoke-VibeShieldBicepFragment -ScriptPath $fragmentScript -SourcePath $entrySource -TargetPath $copilotInstructionsPath -SectionMarker 'path-specific-instructions'
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

        # -------------------------------------------------------------------
        # 3. Inject AGENTS.md and CLAUDE.md entries (idempotent, marker-based)
        # -------------------------------------------------------------------
        $agentsMdEntry = Join-Path $assetsDir 'AGENTS-md-fragment.md'

        if (Test-Path $agentsMdEntry) {
            foreach ($targetFile in @('AGENTS.md', 'CLAUDE.md')) {
                $targetPath = Join-Path $projectRoot $targetFile
                if (Test-Path $targetPath) {
                    $result = Invoke-VibeShieldBicepFragment -ScriptPath $fragmentScript -SourcePath $agentsMdEntry -TargetPath $targetPath -SectionMarker 'automated-agents'
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

        # -------------------------------------------------------------------
        # 4. Install agent definition file (always overwrite)
        # -------------------------------------------------------------------
        $agentsDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'agents'
        $agentSource = Join-Path $assetsDir 'vibeshield-bicep.agent.md'
        $agentTarget = Join-Path $agentsDir 'vibeshield-bicep.agent.md'

        if (Test-Path $agentSource) {
            if (-not (Test-Path $agentsDir)) {
                New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            }
            if (Test-Path $agentTarget) {
                Copy-Item -Path $agentSource -Destination $agentTarget -Force
                Write-Host '  OVERWRITTEN: .github\agents\vibeshield-bicep.agent.md' -ForegroundColor Green
                $overwrittenCount++
            } else {
                Copy-Item -Path $agentSource -Destination $agentTarget
                Write-Host '  CREATED: .github\agents\vibeshield-bicep.agent.md' -ForegroundColor Green
                $createdCount++
            }
        } else {
            Write-Host '  WARNING: vibeshield-bicep.agent.md not found in skill assets' -ForegroundColor Yellow
        }

        # -------------------------------------------------------------------
        # 5. Install hook file (always overwrite)
        # -------------------------------------------------------------------
        $hooksDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'hooks'
        $hookSource = Join-Path (Join-Path $assetsDir 'hooks') 'validate-bicep.json'
        $hookTarget = Join-Path $hooksDir 'validate-bicep.json'

        if (Test-Path $hookSource) {
            if (-not (Test-Path $hooksDir)) {
                New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
            }
            if (Test-Path $hookTarget) {
                Copy-Item -Path $hookSource -Destination $hookTarget -Force
                Write-Host '  OVERWRITTEN: .github\hooks\validate-bicep.json' -ForegroundColor Green
                $overwrittenCount++
            } else {
                Copy-Item -Path $hookSource -Destination $hookTarget
                Write-Host '  CREATED: .github\hooks\validate-bicep.json' -ForegroundColor Green
                $createdCount++
            }
        } else {
            Write-Host '  WARNING: validate-bicep.json not found in skill assets' -ForegroundColor Yellow
        }

        # -------------------------------------------------------------------
        # 6. Install skill runtime files (delegate to Install-SkillRuntime.ps1)
        # -------------------------------------------------------------------
        $skillRuntimeScript = Join-Path $PSScriptRoot 'Install-SkillRuntime.ps1'
        if (Test-Path $skillRuntimeScript) {
            Invoke-VibeShieldBicepScript -ScriptPath $skillRuntimeScript -ProjectPath $projectRoot
        } else {
            $message = 'SCRIPT_MISSING: Install-SkillRuntime.ps1'
            Set-VibeShieldCapabilityResult -Status fail -Message $message -Details @{
                code = 'SCRIPT_MISSING'
                script = 'Install-SkillRuntime.ps1'
            }
            $resultWritten = $true
            throw $message
        }

        # -------------------------------------------------------------------
        # 7. Install VS Code extension recommendations
        # -------------------------------------------------------------------
        $extensionsScript = Join-Path $PSScriptRoot 'Install-VsCodeExtensions.ps1'
        if (Test-Path $extensionsScript) {
            Invoke-VibeShieldBicepScript -ScriptPath $extensionsScript -ProjectPath $projectRoot
        } else {
            Write-Host '  SKIPPED: Install-VsCodeExtensions.ps1 not found' -ForegroundColor Cyan
        }

        # -------------------------------------------------------------------
        # 8. Install Copilot CLI MCP server configuration
        # -------------------------------------------------------------------
        $mcpConfigScript = Join-Path $PSScriptRoot 'Install-McpConfig.ps1'
        if (Test-Path $mcpConfigScript) {
            Invoke-VibeShieldBicepScript -ScriptPath $mcpConfigScript -ProjectPath $projectRoot
        } else {
            Write-Host '  SKIPPED: Install-McpConfig.ps1 not found' -ForegroundColor Cyan
        }

        # -------------------------------------------------------------------
        # 9. Integrate with spec-kit agents (delegate to Install-SpecKitIntegration.ps1)
        # -------------------------------------------------------------------
        $specKitIntegrationScript = Join-Path $PSScriptRoot 'Install-SpecKitIntegration.ps1'
        if (Test-Path $specKitIntegrationScript) {
            Write-Host '' -ForegroundColor Cyan
            Invoke-VibeShieldBicepScript -ScriptPath $specKitIntegrationScript -ProjectPath $projectRoot
        } else {
            Write-Host '  SKIPPED: Install-SpecKitIntegration.ps1 not found (spec-kit integration unavailable)' -ForegroundColor Cyan
        }

        # -------------------------------------------------------------------
        # 10. Scaffold Bicep project layout (delegate to Initialize-BicepProject.ps1)
        # -------------------------------------------------------------------
        $initScript = Join-Path $PSScriptRoot 'Initialize-BicepProject.ps1'
        if (Test-Path $initScript) {
            Write-Host '' -ForegroundColor Cyan
            Invoke-VibeShieldBicepScript -ScriptPath $initScript -ProjectPath $projectRoot
        } else {
            $message = 'SCRIPT_MISSING: Initialize-BicepProject.ps1'
            Set-VibeShieldCapabilityResult -Status fail -Message $message -Details @{
                code = 'SCRIPT_MISSING'
                script = 'Initialize-BicepProject.ps1'
            }
            $resultWritten = $true
            throw $message
        }

        # -------------------------------------------------------------------
        # Summary
        # -------------------------------------------------------------------
        Write-Host ''
        Write-Host "vibeshield-bicep install complete: $createdCount created, $overwrittenCount overwritten, $skippedCount skipped." -ForegroundColor Green
        Set-VibeShieldCapabilityResult -Status ok -Message 'vibeshield-bicep install complete' -Details @{
            created = $createdCount
            overwritten = $overwrittenCount
            skipped = $skippedCount
        }
        $resultWritten = $true
        return
    } catch {
        if (-not $resultWritten) {
            Set-VibeShieldCapabilityResult -Status fail -Message 'UNHANDLED_EXCEPTION: vibeshield-bicep install failed' -Details @{
                code = 'UNHANDLED_EXCEPTION'
                exceptionType = $_.Exception.GetType().Name
            }
        }
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-InstallVibeShieldBicep @PSBoundParameters }
