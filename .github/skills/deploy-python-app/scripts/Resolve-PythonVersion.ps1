#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Resolves the Python version for a workspace from project configuration files.

.DESCRIPTION
    Scans the workspace for Python version specifiers in priority order
    matching deploy-python-app skill's version selection algorithm:
      1. pyproject.toml requires-python
      2. pyproject.toml [tool.poetry] python
      3. runtime.txt
      4. .python-version
      5. setup.py python_requires
      6. Default (3.11)

    Returns the resolved version, source file, and any constraint found.

.PARAMETER WorkspacePath
    Path to the workspace root. Defaults to current directory.

.EXAMPLE
    $result = ./.github/skills/deploy-python-app/scripts/Resolve-PythonVersion.ps1 -WorkspacePath ./my-app
    # $result.Version    = '3.11'
    # $result.Source     = 'pyproject.toml (requires-python)'
    # $result.Constraint = '>=3.10,<3.13'
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = $PWD.Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load shared helpers for integrity verification ──────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

$defaultVersion = '3.11'

# Version compatibility table (supported by Azure)
$supportedVersions = @('3.8', '3.9', '3.10', '3.11', '3.12', '3.13')

function Select-BestVersion {
    <#
    .SYNOPSIS Picks the best supported version from a constraint string.
    .DESCRIPTION
        Given a constraint like '>=3.10,<3.13', returns the highest
        supported version that satisfies the constraint. Falls back to
        default if no match.
    #>
    param([string]$Constraint)

    if (-not $Constraint) { return $defaultVersion }

    # Try to extract a specific version like ==3.11 or ~=3.11
    if ($Constraint -match '(?:==|~=)\s*(\d+\.\d+)') {
        $ver = $Matches[1]
        if ($ver -in $supportedVersions) { return $ver }
    }

    # Extract min version from >=X.Y
    $minVer = $null
    if ($Constraint -match '>=\s*(\d+\.\d+)') {
        $minVer = $Matches[1]
    }

    # Extract max version from <X.Y
    $maxVer = $null
    if ($Constraint -match '<\s*(\d+\.\d+)') {
        $maxVer = $Matches[1]
    }

    # Filter supported versions by range and pick highest
    $candidates = $supportedVersions | Where-Object {
        $v = [version]$_
        $inRange = $true
        if ($minVer) {
            $inRange = $inRange -and ($v -ge [version]$minVer)
        }
        if ($maxVer) {
            $inRange = $inRange -and ($v -lt [version]$maxVer)
        }
        $inRange
    }

    if (@($candidates).Count -gt 0) {
        return ($candidates | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
    }

    return $defaultVersion
}

# ═══════════════════════════════════════════════════════════
# Priority 1: pyproject.toml requires-python
# ═══════════════════════════════════════════════════════════
$pyprojectPath = Join-Path -Path $WorkspacePath -ChildPath 'pyproject.toml'
if (Test-Path $pyprojectPath) {
    $content = Get-Content $pyprojectPath -Raw

    # requires-python = ">=3.10,<3.13"
    if ($content -match 'requires-python\s*=\s*[''"]([^''"]+)[''"]') {
        $constraint = $Matches[1]
        $version = Select-BestVersion -Constraint $constraint
        [pscustomobject]@{
            Version    = $version
            Source     = 'pyproject.toml (requires-python)'
            Constraint = $constraint
        }
        $global:LASTEXITCODE = 0
        exit 0
    }

    # Priority 2: [tool.poetry] python = "^3.10"
    if ($content -match '(?s)\[tool\.poetry\].*?python\s*=\s*[''"]([^''"]+)[''"]') {
        $constraint = $Matches[1]
        # Convert poetry's ^ notation: ^3.10 means >=3.10,<4.0
        $resolvedConstraint = $constraint
        if ($constraint -match '\^(\d+\.\d+)') {
            $resolvedConstraint = ">=$($Matches[1]),<4.0"
        }
        $version = Select-BestVersion -Constraint $resolvedConstraint
        [pscustomobject]@{
            Version    = $version
            Source     = 'pyproject.toml (tool.poetry python)'
            Constraint = $constraint
        }
        $global:LASTEXITCODE = 0
        exit 0
    }
}

# ═══════════════════════════════════════════════════════════
# Priority 3: runtime.txt
# ═══════════════════════════════════════════════════════════
$runtimeTxtPath = Join-Path -Path $WorkspacePath -ChildPath 'runtime.txt'
if (Test-Path $runtimeTxtPath) {
    $runtimeContent = (Get-Content $runtimeTxtPath -Raw).Trim()
    # Format: python-3.11.4 or python-3.11
    if ($runtimeContent -match 'python-(\d+\.\d+)') {
        $version = $Matches[1]
        if ($version -in $supportedVersions) {
            [pscustomobject]@{
                Version    = $version
                Source     = 'runtime.txt'
                Constraint = $runtimeContent
            }
            $global:LASTEXITCODE = 0
            exit 0
        }
    }
}

# ═══════════════════════════════════════════════════════════
# Priority 4: .python-version
# ═══════════════════════════════════════════════════════════
$pythonVersionPath = Join-Path -Path $WorkspacePath -ChildPath '.python-version'
if (Test-Path $pythonVersionPath) {
    $pvContent = (Get-Content $pythonVersionPath -Raw).Trim()
    if ($pvContent -match '(\d+\.\d+)') {
        $version = $Matches[1]
        if ($version -in $supportedVersions) {
            [pscustomobject]@{
                Version    = $version
                Source     = '.python-version'
                Constraint = $pvContent
            }
            $global:LASTEXITCODE = 0
            exit 0
        }
    }
}

# ═══════════════════════════════════════════════════════════
# Priority 5: setup.py python_requires
# ═══════════════════════════════════════════════════════════
$setupPyPath = Join-Path -Path $WorkspacePath -ChildPath 'setup.py'
if (Test-Path $setupPyPath) {
    $setupContent = Get-Content $setupPyPath -Raw
    if ($setupContent -match 'python_requires\s*=\s*[''"]([^''"]+)[''"]') {
        $constraint = $Matches[1]
        $version = Select-BestVersion -Constraint $constraint
        [pscustomobject]@{
            Version    = $version
            Source     = 'setup.py (python_requires)'
            Constraint = $constraint
        }
        $global:LASTEXITCODE = 0
        exit 0
    }
}

# ═══════════════════════════════════════════════════════════
# Priority 6: Default
# ═══════════════════════════════════════════════════════════
[pscustomobject]@{
    Version    = $defaultVersion
    Source     = 'default'
    Constraint = "No version specifier found — using default $defaultVersion"
}
exit 0
