<#
.SYNOPSIS
    Scaffolds a default Bicep project layout with standard directories and PSRule
    config files.

.DESCRIPTION
    Initializes a Bicep project by creating the standard directory structure,
    copying 9 template files from the skill assets (including resourcegroup.bicep
    and the subscription-scoped Create-ResourceGroup.ps1 in its own subfolder),
    generating a unique 11-char
    project name, and replacing the {{REPLACE-WITH-11-CHAR-PROJECT-NAME}}
    placeholder in all template files (including pre-existing ones that still
    contain the placeholder). Existing files and directories are never
    overwritten -- the script skips anything that already exists during copy.

    The project name is composed of the first 4 characters of the current user
    alias (lowercase, padded with 'x' if shorter than 4 chars) plus 7 random
    lowercase alphanumeric characters.

    Copilot customization assets (path-specific instructions and
    copilot-instructions.md injection) are handled separately by
    Install-VibeShield.ps1, which calls this script after installing those
    assets.

    Created structure:
      {ProjectPath}\infra\                        -- Infrastructure root
      {ProjectPath}\infra\main.bicep               -- Main deployment entry point
      {ProjectPath}\infra\parameters.dev.bicepparam -- Dev parameters
      {ProjectPath}\infra\parameters.prod.bicepparam -- Prod parameters
      {ProjectPath}\infra\Config.ps1               -- Configuration script
      {ProjectPath}\infra\subscription-configuration\Create-ResourceGroup.ps1 -- Resource group creation
      {ProjectPath}\infra\Deploy.ps1               -- Deployment script
      {ProjectPath}\infra\resourcegroup.bicep      -- Subscription-scoped RG template
      {ProjectPath}\infra\modules\                 -- Reusable Bicep modules (seeded with sample files from assets\infra\modules\)
      {ProjectPath}\infra\PSRule.dev.yaml          -- PSRule config for dev
      {ProjectPath}\infra\PSRule.prod.yaml         -- PSRule config for prod
      {ProjectPath}\output\                        -- Build artifacts (gitignored)

.PARAMETER ProjectPath
    Optional. Path to the project root where the infra directory will be created.
    If omitted, the script walks up from $PSScriptRoot to find the .git directory,
    falling back to the current working directory.

.EXAMPLE
    # Initialize a Bicep project at the repo root
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Initialize-BicepProject.ps1

.EXAMPLE
    # Initialize a Bicep project at a specific path
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Initialize-BicepProject.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes:
      0 - Initialization completed successfully (items created and/or skipped)
#>

[CmdletBinding()]
param(
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# Resolve to absolute path
$projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

Write-Host "Initializing Bicep project at: $projectRoot" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Resolve assets infra directory
# ---------------------------------------------------------------------------
$assetsInfraDir = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'assets' 'infra')
if (-not (Test-Path $assetsInfraDir)) {
    Write-Host '  WARNING: Assets infra directory not found -- skipping file copy.' -ForegroundColor Yellow
} else {
    $assetsInfraDir = [System.IO.Path]::GetFullPath($assetsInfraDir)
}

# ---------------------------------------------------------------------------
# Generate unique 11-char project name (4 alias chars + 7 random alphanumeric)
# ---------------------------------------------------------------------------
$alias = [System.Environment]::UserName.ToLower()
$aliasPrefix = $alias.Substring(0, [System.Math]::Min(4, $alias.Length)).PadRight(4, 'x')
$charPool = 'abcdefghijklmnopqrstuvwxyz0123456789'
$randomSuffix = -join (1..7 | ForEach-Object { $charPool[(Get-Random -Maximum $charPool.Length)] })
$projectName = $aliasPrefix + $randomSuffix
Write-Host "  Generated project name: $projectName" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Tracking counters
# ---------------------------------------------------------------------------
$createdCount = 0
$skippedCount = 0

# ---------------------------------------------------------------------------
# 1. Create \infra directory
# ---------------------------------------------------------------------------
$infraDir = Join-Path $projectRoot 'infra'
if (-not (Test-Path $infraDir)) {
    New-Item -ItemType Directory -Path $infraDir -Force | Out-Null
    Write-Host "  CREATED: infra\" -ForegroundColor Green
    $createdCount++
} else {
    Write-Host "  SKIPPED: infra\ (already exists)" -ForegroundColor Cyan
    $skippedCount++
}

# ---------------------------------------------------------------------------
# 2. Copy template files from assets\infra\
# ---------------------------------------------------------------------------
$templateFiles = @(
    'main.bicep',
    'resourcegroup.bicep',
    'parameters.dev.bicepparam',
    'parameters.prod.bicepparam',
    'Config.ps1',
    'Deploy.ps1',
    'PSRule.dev.yaml',
    'PSRule.prod.yaml'
)

# Files that live in a subdirectory under infra\ (relative path from assetsInfraDir / infraDir).
# subscription-configuration\ is enumerated dynamically so new scripts dropped into the
# assets folder (e.g. Register-NspServiceTagFeature.ps1) are picked up automatically.
$nestedTemplateFiles = @()
$subConfigAssetDir = Join-Path $assetsInfraDir 'subscription-configuration'
if (Test-Path $subConfigAssetDir) {
    $nestedTemplateFiles = @(
        Get-ChildItem -Path $subConfigAssetDir -File -ErrorAction Stop |
            ForEach-Object { Join-Path 'subscription-configuration' $_.Name }
    )
}

if (Test-Path $assetsInfraDir) {
    foreach ($templateFile in $templateFiles) {
        $sourcePath = Join-Path $assetsInfraDir $templateFile
        $targetPath = Join-Path $infraDir $templateFile

        if (-not (Test-Path $sourcePath)) {
            Write-Host "  WARNING: Source file not found: $templateFile" -ForegroundColor Yellow
            continue
        }

        if (-not (Test-Path $targetPath)) {
            Copy-Item -Path $sourcePath -Destination $targetPath
            Write-Host "  CREATED: infra\$templateFile" -ForegroundColor Green
            $createdCount++
        } else {
            Write-Host "  SKIPPED: infra\$templateFile (already exists)" -ForegroundColor Cyan
            $skippedCount++
        }
    }

    foreach ($nestedFile in $nestedTemplateFiles) {
        $sourcePath = Join-Path $assetsInfraDir $nestedFile
        $targetPath = Join-Path $infraDir $nestedFile
        $targetDir = Split-Path $targetPath -Parent

        if (-not (Test-Path $sourcePath)) {
            Write-Host "  WARNING: Source file not found: $nestedFile" -ForegroundColor Yellow
            continue
        }

        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            $relDir = (Split-Path $nestedFile -Parent)
            Write-Host "  CREATED: infra\$relDir\" -ForegroundColor Green
            $createdCount++
        }

        if (-not (Test-Path $targetPath)) {
            Copy-Item -Path $sourcePath -Destination $targetPath
            Write-Host "  CREATED: infra\$nestedFile" -ForegroundColor Green
            $createdCount++
        } else {
            Write-Host "  SKIPPED: infra\$nestedFile (already exists)" -ForegroundColor Cyan
            $skippedCount++
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Create \infra\modules directory and copy any sample/template modules
#    from assets\infra\modules\. Files are enumerated dynamically so new
#    samples (e.g. nsp-keyvault.bicep.sample) are picked up automatically.
# ---------------------------------------------------------------------------
$modulesDir = Join-Path $infraDir 'modules'
if (-not (Test-Path $modulesDir)) {
    New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
    Write-Host "  CREATED: infra\modules\" -ForegroundColor Green
    $createdCount++
} else {
    Write-Host "  SKIPPED: infra\modules\ (already exists)" -ForegroundColor Cyan
    $skippedCount++
}

$modulesAssetDir = Join-Path $assetsInfraDir 'modules'
if (Test-Path $modulesAssetDir) {
    $moduleAssetFiles = @(Get-ChildItem -Path $modulesAssetDir -File -ErrorAction Stop)
    foreach ($moduleFile in $moduleAssetFiles) {
        $targetPath = Join-Path $modulesDir $moduleFile.Name
        if (-not (Test-Path $targetPath)) {
            Copy-Item -Path $moduleFile.FullName -Destination $targetPath
            Write-Host "  CREATED: infra\modules\$($moduleFile.Name)" -ForegroundColor Green
            $createdCount++
        } else {
            Write-Host "  SKIPPED: infra\modules\$($moduleFile.Name) (already exists)" -ForegroundColor Cyan
            $skippedCount++
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Create \output directory (build artifacts, gitignored)
# ---------------------------------------------------------------------------
$outputDir = Join-Path $projectRoot 'output'
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Write-Host "  CREATED: output\" -ForegroundColor Green
    $createdCount++
} else {
    Write-Host "  SKIPPED: output\ (already exists)" -ForegroundColor Cyan
    $skippedCount++
}

# ---------------------------------------------------------------------------
# 5. Ensure output/ is in .gitignore
# ---------------------------------------------------------------------------
$gitignorePath = Join-Path $projectRoot '.gitignore'
if (Test-Path $gitignorePath) {
    $gitignoreContent = Get-Content -Path $gitignorePath -Raw
    if ($gitignoreContent -notmatch '(?m)^output/?\r?$') {
        Add-Content -Path $gitignorePath -Value "`noutput/"
        Write-Host '  UPDATED: .gitignore (added output/)' -ForegroundColor Green
        $createdCount++
    } else {
        Write-Host '  SKIPPED: .gitignore (output/ already listed)' -ForegroundColor Cyan
        $skippedCount++
    }
} else {
    Set-Content -Path $gitignorePath -Value 'output/' -Encoding utf8
    Write-Host '  CREATED: .gitignore (with output/)' -ForegroundColor Green
    $createdCount++
}

# ---------------------------------------------------------------------------
# 6. Replace placeholder in all template files (covers fresh installs and
#    re-runs where files exist but still contain the placeholder)
# ---------------------------------------------------------------------------
$placeholder = '{{REPLACE-WITH-11-CHAR-PROJECT-NAME}}'
$placeholderTargets = @(
    $templateFiles | ForEach-Object { Join-Path $infraDir $_ }
    $nestedTemplateFiles | ForEach-Object { Join-Path $infraDir $_ }
)
foreach ($targetPath in $placeholderTargets) {
    if (-not (Test-Path $targetPath)) { continue }
    $content = Get-Content -Path $targetPath -Raw
    if ($content -and $content.Contains($placeholder)) {
        $content = $content -replace [regex]::Escape($placeholder), $projectName
        Set-Content -Path $targetPath -Value $content -NoNewline -Encoding utf8
        Write-Host "  UPDATED: $(Split-Path $targetPath -Leaf) (replaced project name placeholder)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Bicep project initialization complete: $createdCount created, $skippedCount skipped." -ForegroundColor Green
exit 0
