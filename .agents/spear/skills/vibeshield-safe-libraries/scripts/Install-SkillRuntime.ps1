<#
.SYNOPSIS
    Installs vibeshield-safe-libraries skill runtime files into the target project.

.DESCRIPTION
    Copies SKILL.md and runtime scripts from the skill source into
    .github\skills\vibeshield-safe-libraries\ at the target project. All files
    are always overwritten to ensure the latest version is deployed.

    Called by Install-VibeShield.ps1 as a helper. Can also be run directly
    to update skill runtime files without reinstalling other assets.

    Installed files:
      .github\skills\vibeshield-safe-libraries\SKILL.md
      .github\skills\vibeshield-safe-libraries\scripts\Install-VibeShield.ps1
      .github\skills\vibeshield-safe-libraries\scripts\Resolve-RepoRoot.ps1
      .github\skills\vibeshield-safe-libraries\scripts\Install-VibeShieldFragment.ps1
      .github\skills\vibeshield-safe-libraries\scripts\helpers\Install-NuGetFeedConfig.ps1
      .github\skills\vibeshield-safe-libraries\scripts\helpers\Install-PipFeedConfig.ps1
      .github\skills\vibeshield-safe-libraries\scripts\helpers\Install-NpmFeedConfig.ps1
      .github\skills\vibeshield-safe-libraries\scripts\helpers\Update-ProjectGitignore.ps1
      .github\skills\vibeshield-safe-libraries\scripts\helpers\Test-FeedConnectivity.ps1

    This script outputs created/overwritten counts to the host stream via
    Write-Host. It does not emit result words to stdout (unlike single-file
    helpers) because it processes multiple files.

.PARAMETER ProjectPath
    Required. Path to the project root where files will be installed.

.EXAMPLE
    & Install-SkillRuntime.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes:
      0 - Installation completed successfully
      1 - Skill source directory not found
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve source paths
# ---------------------------------------------------------------------------
$skillSourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptsSourceDir = $PSScriptRoot
$helpersSourceDir = Join-Path $PSScriptRoot 'helpers'
$skillMdSource = Join-Path $skillSourceRoot 'SKILL.md'

if (-not (Test-Path $skillMdSource)) {
    Write-Host '  ERROR: SKILL.md not found in skill root' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve target paths
# ---------------------------------------------------------------------------
$skillTargetDir = Join-Path -Path (Join-Path -Path (Join-Path -Path $ProjectPath -ChildPath '.github') -ChildPath 'skills') -ChildPath 'vibeshield-safe-libraries'
$scriptsTargetDir = Join-Path $skillTargetDir 'scripts'
$helpersTargetDir = Join-Path $scriptsTargetDir 'helpers'

# ---------------------------------------------------------------------------
# Tracking counters
# ---------------------------------------------------------------------------
$createdCount = 0
$overwrittenCount = 0

# ---------------------------------------------------------------------------
# Helper: copy a single file with create/overwrite tracking
# ---------------------------------------------------------------------------
function Copy-SkillFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$DisplayPath
    )

    $targetDir = [System.IO.Path]::GetDirectoryName($Target)
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (Test-Path $Target) {
        Copy-Item -Path $Source -Destination $Target -Force
        Write-Host "  OVERWRITTEN: $DisplayPath" -ForegroundColor Green
        $script:overwrittenCount++
    } else {
        Copy-Item -Path $Source -Destination $Target
        Write-Host "  CREATED: $DisplayPath" -ForegroundColor Green
        $script:createdCount++
    }
}

# ---------------------------------------------------------------------------
# 1. Copy SKILL.md
# ---------------------------------------------------------------------------
Copy-SkillFile -Source $skillMdSource `
    -Target (Join-Path $skillTargetDir 'SKILL.md') `
    -DisplayPath '.github\skills\vibeshield-safe-libraries\SKILL.md'

# ---------------------------------------------------------------------------
# 2. Copy top-level runtime scripts (explicit list - excludes install-only scripts)
# ---------------------------------------------------------------------------
$topLevelScripts = @(
    'Install-VibeShield.ps1',
    'Resolve-RepoRoot.ps1',
    'Install-VibeShieldFragment.ps1'
)

foreach ($scriptName in $topLevelScripts) {
    $scriptSource = Join-Path $scriptsSourceDir $scriptName
    if (Test-Path $scriptSource) {
        Copy-SkillFile -Source $scriptSource `
            -Target (Join-Path $scriptsTargetDir $scriptName) `
            -DisplayPath ".github\skills\vibeshield-safe-libraries\scripts\$scriptName"
    } else {
        Write-Host "  WARNING: $scriptName not found in skill scripts" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 3. Copy helper scripts
# ---------------------------------------------------------------------------
$helperScripts = @(
    'Install-NuGetFeedConfig.ps1',
    'Install-PipFeedConfig.ps1',
    'Install-NpmFeedConfig.ps1',
    'Update-ProjectGitignore.ps1',
    'Test-FeedConnectivity.ps1'
)

foreach ($scriptName in $helperScripts) {
    $scriptSource = Join-Path $helpersSourceDir $scriptName
    if (Test-Path $scriptSource) {
        Copy-SkillFile -Source $scriptSource `
            -Target (Join-Path $helpersTargetDir $scriptName) `
            -DisplayPath ".github\skills\vibeshield-safe-libraries\scripts\helpers\$scriptName"
    } else {
        Write-Host "  WARNING: $scriptName not found in skill helpers" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "  Skill runtime: $createdCount created, $overwrittenCount overwritten." -ForegroundColor Cyan
exit 0
