<#
.SYNOPSIS
    Installs CFS-backed Azure Artifacts feed configuration for NuGet, pip, and npm.

.DESCRIPTION
    Configures a target project to consume packages exclusively from the
    CFS-backed Azure DevOps Artifacts feed. For each ecosystem (NuGet, Python/pip,
    npm), the script copies the appropriate config file from the skill assets and
    installs the corresponding credential manager.

    After ecosystem configuration, installs governance assets (path-specific
    instructions, copilot-instructions entry, AGENTS.md/CLAUDE.md fragments,
    agent definition, skill runtime, and spec-kit integration) so that other
    agents know to delegate feed configuration to @vibeshield-safe-libraries.

    Central Feed Services (CFS) scans every package for malware, vulnerabilities,
    typo-squatting, and other supply-chain threats before ingestion. See
    https://aka.ms/cfs for details.

    Behavior:
      - Fail if config exists:  If nuget.config, .npmrc, or the pip config already
            exists at the target location, the script stops with an error.
      - Tool detection:  If dotnet, python/python3, or npm is not installed, that
            ecosystem is skipped with a warning (not a failure).
      - Virtualenv:  Auto-creates a .venv directory for Python if one does not
            exist, using python3 (preferred) or python as a fallback.
      - Gitignore:  Creates or updates .gitignore to exclude .venv/.
      - Connectivity:  Advisory check -- warns if the feed is unreachable but does
            not fail.

    Installed config files:
      nuget.config        -- Project root. Points NuGet at the CFS-backed feed
                             with <clear /> to remove public upstream sources.
      pip.ini / pip.conf   -- Inside .venv/. Configures pip index-url to the
                             CFS-backed feed. File name is OS-dependent.
      .npmrc              -- Project root. Sets registry to the CFS-backed feed
                             with always-auth=true.

    Credential managers installed:
      artifacts-credprovider  -- NuGet (.NET). Installed via the official
                                 Microsoft bootstrap script.
      keyring + artifacts-keyring -- pip (Python). Installed into the .venv
                                    virtualenv.
      vsts-npm-auth           -- npm (Node.js). Installed globally.

    Governance assets installed:
      .github\instructions\safe-libraries.instructions.md -- Path-specific
          instructions that auto-apply when editing feed config files.
      .github\copilot-instructions.md -- Marker section injected/updated for
          feed config file routing.
      AGENTS.md / CLAUDE.md -- Marker section injected/updated with the
          vibeshield-safe-libraries automated agent entry.
      .github\agents\vibeshield-safe-libraries.agent.md -- Agent definition.
          Always overwritten to ensure the latest version is deployed.

    Delegated to Install-SkillRuntime.ps1:
      .github\skills\vibeshield-safe-libraries\SKILL.md -- Skill documentation.
      .github\skills\vibeshield-safe-libraries\scripts\* -- Runtime scripts.

    Delegated to Install-SpecKitIntegration.ps1:
      .github\agents\speckit.*.agent.md -- Patches spec-kit agent files with
          agents: frontmatter and body delegation instructions so spec-kit
          agents delegate feed config work to @vibeshield-safe-libraries.

    Helper scripts in scripts/helpers/:
      Install-NuGetFeedConfig.ps1  -- NuGet config and credential provider
      Install-PipFeedConfig.ps1    -- Python venv, pip config, and keyring
      Install-NpmFeedConfig.ps1    -- npm config and vsts-npm-auth
      Update-ProjectGitignore.ps1  -- .gitignore management
      Test-FeedConnectivity.ps1    -- Advisory feed reachability check

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script walks up from
    $PSScriptRoot to find the .git directory, falling back to the current
    working directory.

.EXAMPLE
    pwsh -NoProfile -File skills/vibeshield-safe-libraries/scripts/Install-VibeShield.ps1

.EXAMPLE
    pwsh -NoProfile -File skills/vibeshield-safe-libraries/scripts/Install-VibeShield.ps1 -ProjectPath C:\myproject

.NOTES
    Returns on success and throws on failure. Capability status is reported via
    the VibeShield capability contract handshake file.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath,
    # vibeshield-safe-libraries does not consume Branch (assets are local to
    # the skill), but the installer always invokes capability scripts as
    # & $script -ProjectPath <p> -Branch <b>. Without a script-level Branch
    # parameter, the value silently lands in $args -- see council Finding #1.
    # The parameter is accepted as a no-op for uniform contract surface.
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $PSScriptRoot/Vibeshield.CapabilityContract.psm1 -Force

# ---------------------------------------------------------------------------
# Dot-source helper functions at script scope so test mocks can intercept by
# command name. Wrapped in try/catch so a missing helper file still writes a
# handshake (per the v0.6 contract: the installer must never see a silent
# script termination -- spec sec. 4 row #2 (handshake-missing) would
# otherwise be the only signal, which is fail-closed in PR3 only).
# ---------------------------------------------------------------------------
try {
    $helpersDir = Join-Path $PSScriptRoot 'helpers'
    . (Join-Path $helpersDir 'Install-NuGetFeedConfig.ps1')
    . (Join-Path $helpersDir 'Install-PipFeedConfig.ps1')
    . (Join-Path $helpersDir 'Install-NpmFeedConfig.ps1')
    . (Join-Path $helpersDir 'Update-ProjectGitignore.ps1')
    . (Join-Path $helpersDir 'Test-FeedConnectivity.ps1')
}
catch {
    if ($env:VIBESHIELD_RESULT_PATH -and $env:VIBESHIELD_HANDSHAKE_VERSION -and $env:VIBESHIELD_CAPABILITY_NAME) {
        # PII-safe: do not include the raw $_.Exception.Message because
        # PowerShell dot-source/parse errors include absolute paths
        # (e.g., 'C:\Users\<name>\...'). Spec sec. 6.1 forbids this in
        # the message field, which is forwarded verbatim to telemetry.
        # Categorize via details only, with leaf filename or exception
        # type-name (both PII-safe) for forensics.
        $exType = ''
        try { $exType = [string]$_.Exception.GetType().Name }
        catch { Write-Verbose ('  GetType() failed: ' + $_.Exception.Message) }
        Set-VibeShieldCapabilityResult -Status fail `
            -Message 'LOAD_HELPERS_FAILED: safe-libraries helper load failed' `
            -Details @{
                phase     = 'load-helpers'
                code      = 'LOAD_HELPERS_FAILED'
                exception = $exType
            }
    }
    throw
}

function Invoke-InstallVibeShieldSafeLibrary {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        # No-op: the installer always passes -Branch; accepted here so the
        # script-level invocation guard's @PSBoundParameters splat does not
        # bind to an unknown parameter. Asset source is the local skill,
        # not a branch on a remote repo. See council Finding #1 (PR2 r2).
        [string]$Branch = 'main'
    )

    $phase = 'initialization'
    $capabilityResultWritten = $false
    $null = $Branch  # accepted for uniform contract surface; not consumed

    try {
        # -------------------------------------------------------------------
        # Resolve project root: use parameter, walk up to .git dir, or fall back to cwd
        # A .git *file* (not directory) indicates a submodule -- keep walking.
        # -------------------------------------------------------------------
        $phase = 'project-root'
        if ($ProjectPath) {
            $projectRoot = $ProjectPath
        } else {
            $searchDir = $PSScriptRoot
            if (-not $searchDir) { $searchDir = (Get-Location).Path }
            $gitPath = $null
            while ($searchDir) {
                $candidate = Join-Path $searchDir '.git'
                if (Test-Path $candidate -PathType Container) {
                    $gitPath = $candidate
                    break
                }
                $parent = Split-Path $searchDir -Parent
                if ($parent -eq $searchDir) { break }
                $searchDir = $parent
            }
            if ($gitPath) {
                $projectRoot = $searchDir
            } else {
                $projectRoot = (Get-Location).Path
            }
        }

        $projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

        Write-Host "Installing vibeshield-safe-libraries (CFS feed configuration) at: $projectRoot" -ForegroundColor Cyan

        # -------------------------------------------------------------------
        # Resolve assets directory (one level up from scripts/, then into assets/)
        # -------------------------------------------------------------------
        $phase = 'assets'
        $assetsDirOverride = Get-Variable -Name 'VibeShieldSafeLibrariesAssetsDirOverride' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $assetsDirOverride -and -not [string]::IsNullOrWhiteSpace([string]$assetsDirOverride)) {
            $assetsDir = [string]$assetsDirOverride
        } else {
            $assetsDir = Join-Path (Join-Path $PSScriptRoot '..') 'assets'
        }
        if (-not (Test-Path $assetsDir)) {
            Write-Host "  ERROR: Assets directory not found at $assetsDir" -ForegroundColor Red
            $message = 'ASSETS_MISSING: vibeshield-safe-libraries assets directory not found'
            Set-VibeShieldCapabilityResult -Status fail -Message $message -Details @{ phase = $phase; missingAsset = 'safe-libraries assets' }
            $capabilityResultWritten = $true
            throw $message
        }
        $assetsDir = [System.IO.Path]::GetFullPath($assetsDir)

        # -------------------------------------------------------------------
        # Detect platform
        # -------------------------------------------------------------------
        $phase = 'platform-detection'
        $runningOnWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

        # -------------------------------------------------------------------
        # Run each ecosystem installer and aggregate results
        # -------------------------------------------------------------------
        $phase = 'library-installers'
        $libraryResults = @(
            [PSCustomObject]@{ Name = 'nuget'; Result = (Install-NuGetFeedConfig -ProjectRoot $projectRoot -AssetsDir $assetsDir -RunningOnWindows $runningOnWindows) },
            [PSCustomObject]@{ Name = 'pip';   Result = (Install-PipFeedConfig   -ProjectRoot $projectRoot -AssetsDir $assetsDir -RunningOnWindows $runningOnWindows) },
            [PSCustomObject]@{ Name = 'npm';   Result = (Install-NpmFeedConfig   -ProjectRoot $projectRoot -AssetsDir $assetsDir) }
        )

        $allResults = @(
            $libraryResults[0].Result,
            $libraryResults[1].Result,
            $libraryResults[2].Result,
            (Update-ProjectGitignore -ProjectRoot $projectRoot),
            (Test-FeedConnectivity   -ProjectRoot $projectRoot)
        )

        $createdCount = 0
        $skippedCount = 0
        $warnedCount  = 0
        $failedCount  = 0

        foreach ($r in @($allResults)) {
            if ($null -eq $r) {
                continue
            }
            $createdCount += $r.Created
            $skippedCount += $r.Skipped
            $warnedCount  += $r.Warned
            $failedCount  += $r.Failed
        }

        $failedLibraries = @(
            foreach ($libraryResult in @($libraryResults)) {
                if ($null -ne $libraryResult.Result -and $libraryResult.Result.Failed -gt 0) {
                    $libraryResult.Name
                }
            }
        )
        $successfulLibraries = @(
            foreach ($libraryResult in @($libraryResults)) {
                if ($null -ne $libraryResult.Result -and $libraryResult.Result.Failed -eq 0) {
                    $libraryResult.Name
                }
            }
        )

        # ===================================================================
        # GOVERNANCE ASSETS INSTALLATION
        # ===================================================================
        $phase = 'governance-assets'
        Write-Host '' -ForegroundColor Cyan
        Write-Host '=== Governance Assets ===' -ForegroundColor Cyan

        # -------------------------------------------------------------------
        # G1. Install path-specific instructions file
        # -------------------------------------------------------------------
        $instructionsDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'instructions'
        $instructionSource = Join-Path $assetsDir 'safe-libraries.instructions.md'
        $instructionTarget = Join-Path $instructionsDir 'safe-libraries.instructions.md'

        if (Test-Path $instructionSource) {
            if (-not (Test-Path $instructionsDir)) {
                New-Item -ItemType Directory -Path $instructionsDir -Force | Out-Null
            }
            if (-not (Test-Path $instructionTarget)) {
                Copy-Item -Path $instructionSource -Destination $instructionTarget
                Write-Host '  CREATED: .github\instructions\safe-libraries.instructions.md' -ForegroundColor Green
                $createdCount++
            } else {
                Write-Host '  SKIPPED: .github\instructions\safe-libraries.instructions.md (already exists)' -ForegroundColor Cyan
                $skippedCount++
            }
        } else {
            Write-Host '  WARNING: safe-libraries.instructions.md not found in skill assets' -ForegroundColor Yellow
        }

        # -------------------------------------------------------------------
        # Resolve fragment injection script (used by G2 and G3)
        # -------------------------------------------------------------------
        $fragmentScript = Join-Path $PSScriptRoot 'Install-VibeShieldFragment.ps1'
        if (-not (Test-Path $fragmentScript)) {
            $fragmentScript = [System.IO.Path]::GetFullPath($fragmentScript)
        }

        # -------------------------------------------------------------------
        # G2. Inject copilot-instructions entry (idempotent, marker-based)
        # -------------------------------------------------------------------
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
            $result = & $fragmentScript -SourcePath $entrySource -TargetPath $copilotInstructionsPath -SectionMarker 'path-specific-instructions'
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
        # G3. Inject AGENTS.md and CLAUDE.md entries (idempotent, marker-based)
        # -------------------------------------------------------------------
        $agentsMdEntry = Join-Path $assetsDir 'AGENTS-md-fragment.md'

        if (Test-Path $agentsMdEntry) {
            foreach ($targetFile in @('AGENTS.md', 'CLAUDE.md')) {
                $targetPath = Join-Path $projectRoot $targetFile
                if (Test-Path $targetPath) {
                    $result = & $fragmentScript -SourcePath $agentsMdEntry -TargetPath $targetPath -SectionMarker 'automated-agents'
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
        # G4. Install agent definition file (always overwrite)
        # -------------------------------------------------------------------
        $agentsDir = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath '.github') -ChildPath 'agents'
        $agentSource = Join-Path $assetsDir 'vibeshield-safe-libraries.agent.md'
        $agentTarget = Join-Path $agentsDir 'vibeshield-safe-libraries.agent.md'

        if (Test-Path $agentSource) {
            if (-not (Test-Path $agentsDir)) {
                New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            }
            if (Test-Path $agentTarget) {
                Copy-Item -Path $agentSource -Destination $agentTarget -Force
                Write-Host '  OVERWRITTEN: .github\agents\vibeshield-safe-libraries.agent.md' -ForegroundColor Green
            } else {
                Copy-Item -Path $agentSource -Destination $agentTarget
                Write-Host '  CREATED: .github\agents\vibeshield-safe-libraries.agent.md' -ForegroundColor Green
                $createdCount++
            }
        } else {
            Write-Host '  WARNING: vibeshield-safe-libraries.agent.md not found in skill assets' -ForegroundColor Yellow
        }

        # -------------------------------------------------------------------
        # G5. Install skill runtime files (delegate to Install-SkillRuntime.ps1)
        # -------------------------------------------------------------------
        $skillRuntimeScript = Join-Path $PSScriptRoot 'Install-SkillRuntime.ps1'
        if (Test-Path $skillRuntimeScript) {
            # Child .ps1 'exit N' returns control without throwing under
            # $ErrorActionPreference='Stop'. Check LASTEXITCODE explicitly so
            # a child failure routes through the catch and writes status=fail.
            $global:LASTEXITCODE = 0
            & $skillRuntimeScript -ProjectPath $projectRoot
            $childExit = $LASTEXITCODE
            if ($null -ne $childExit -and $childExit -ne 0) {
                throw ('SUBSCRIPT_FAILED: Install-SkillRuntime.ps1 exited with code ' + $childExit)
            }
        } else {
            Write-Host "  WARNING: Install-SkillRuntime.ps1 not found at $skillRuntimeScript" -ForegroundColor Yellow
        }

        # -------------------------------------------------------------------
        # G6. Spec-kit integration (delegate to Install-SpecKitIntegration.ps1)
        # -------------------------------------------------------------------
        $specKitScript = Join-Path $PSScriptRoot 'Install-SpecKitIntegration.ps1'
        if (Test-Path $specKitScript) {
            $global:LASTEXITCODE = 0
            & $specKitScript -ProjectPath $projectRoot
            $childExit = $LASTEXITCODE
            if ($null -ne $childExit -and $childExit -ne 0) {
                throw ('SUBSCRIPT_FAILED: Install-SpecKitIntegration.ps1 exited with code ' + $childExit)
            }
        } else {
            Write-Host '  SKIPPED: Install-SpecKitIntegration.ps1 not found (spec-kit integration skipped)' -ForegroundColor Cyan
        }

        # -------------------------------------------------------------------
        # Summary
        # -------------------------------------------------------------------
        $phase = 'summary'
        Write-Host ''
        if ($failedCount -gt 0) {
            Write-Host "vibeshield-safe-libraries install completed with errors: $createdCount created, $skippedCount skipped, $warnedCount warnings, $failedCount FAILED." -ForegroundColor Red
            $message = 'LIBRARY_INSTALL_FAILED: one or more safe library feed installers failed'
            Set-VibeShieldCapabilityResult -Status fail -Message $message -Details @{
                phase = $phase
                failedLibraries = @($failedLibraries)
                failedCount = $failedLibraries.Count
                totalCount = $libraryResults.Count
            }
            $capabilityResultWritten = $true
            throw $message
        }

        Write-Host "vibeshield-safe-libraries install complete: $createdCount created, $skippedCount skipped, $warnedCount warnings." -ForegroundColor Green
        Set-VibeShieldCapabilityResult -Status ok -Message 'vibeshield-safe-libraries install complete' -Details @{ installedCount = $successfulLibraries.Count }
        $capabilityResultWritten = $true
        return
    } catch {
        if (-not $capabilityResultWritten) {
            Set-VibeShieldCapabilityResult -Status fail -Message 'UNCAUGHT_EXCEPTION: vibeshield-safe-libraries install failed' -Details @{ phase = $phase }
        }
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallVibeShieldSafeLibrary @PSBoundParameters
}