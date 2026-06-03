<#
.SYNOPSIS
    Installs vibeshield-powershell skill runtime files into the target project.

.DESCRIPTION
    Copies SKILL.md and runtime scripts from the skill source into
    .github\skills\vibeshield-powershell\ at the target project. All files
    are always overwritten to ensure the latest version is deployed.

    After copying files, delegates to Install-AutoApproveSettings.ps1 to
    register per-script VS Code auto-approve entries.

    Called by Install-VibeShield.ps1 as a helper. Can also be run directly
    to update skill runtime files without reinstalling other assets.

    Installed files:
      .github\skills\vibeshield-powershell\SKILL.md
      .github\skills\vibeshield-powershell\scripts\Resolve-RepoRoot.ps1
      .github\skills\vibeshield-powershell\scripts\Invoke-PSScriptAnalyzer.ps1
      .github\skills\vibeshield-powershell\scripts\Invoke-PSScriptAnalyzerHook.ps1
      .github\skills\vibeshield-powershell\scripts\PSScriptAnalyzerHelper.ps1
      .github\skills\vibeshield-powershell\scripts\Test-PowerShellScripts.ps1

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
$skillMdSource = Join-Path $skillSourceRoot 'SKILL.md'

if (-not (Test-Path $skillMdSource)) {
    Write-Host '  ERROR: SKILL.md not found in skill root' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve target paths
# ---------------------------------------------------------------------------
$skillTargetDir = Join-Path -Path (Join-Path -Path (Join-Path -Path $ProjectPath -ChildPath '.github') -ChildPath 'skills') -ChildPath 'vibeshield-powershell'
$scriptsTargetDir = Join-Path $skillTargetDir 'scripts'

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
    -DisplayPath '.github\skills\vibeshield-powershell\SKILL.md'

# ---------------------------------------------------------------------------
# 2. Copy runtime scripts (explicit list - excludes install scripts)
# ---------------------------------------------------------------------------
$runtimeScripts = @(
    'Resolve-RepoRoot.ps1',
    'Invoke-PSScriptAnalyzer.ps1',
    'Invoke-PSScriptAnalyzerHook.ps1',
    'PSScriptAnalyzerHelper.ps1',
    'Test-PowerShellScripts.ps1'
)

foreach ($scriptName in $runtimeScripts) {
    $scriptSource = Join-Path $scriptsSourceDir $scriptName
    if (Test-Path $scriptSource) {
        Copy-SkillFile -Source $scriptSource `
            -Target (Join-Path $scriptsTargetDir $scriptName) `
            -DisplayPath ".github\skills\vibeshield-powershell\scripts\$scriptName"
    } else {
        Write-Host "  WARNING: $scriptName not found in skill scripts" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 3. Install VS Code auto-approve settings
# ---------------------------------------------------------------------------
$autoApproveScript = Join-Path $PSScriptRoot 'Install-AutoApproveSettings.ps1'
if (Test-Path $autoApproveScript) {
    & $autoApproveScript -ProjectPath $ProjectPath
} else {
    Write-Host '  WARNING: Install-AutoApproveSettings.ps1 not found in skill scripts' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "  Skill runtime: $createdCount created, $overwrittenCount overwritten." -ForegroundColor Cyan
exit 0
