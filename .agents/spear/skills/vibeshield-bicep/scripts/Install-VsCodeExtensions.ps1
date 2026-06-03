<#
.SYNOPSIS
    Recommends and optionally installs VS Code extensions for vibeshield-bicep.

.DESCRIPTION
    Ensures the two VS Code extensions required by the vibeshield-bicep agent's
    MCP servers are listed in the project's .vscode/extensions.json recommendations
    and, when the code CLI is available, attempts a best-effort installation.

    Managed extensions:
      - ms-azuretools.vscode-bicep          (Bicep language server / Bicep MCP server)
      - ms-azuretools.vscode-azure-mcp-server (Azure MCP Server tools)

    Step 1 - Recommendations: Creates or updates .vscode/extensions.json so
    both extension IDs appear in the "recommendations" array. Existing entries
    are preserved; only missing IDs are added.

    Step 2 - Installation: If the `code` CLI is on the PATH, the script
    checks already-installed extensions and installs any that are missing.
    Each install attempt is wrapped in its own try/catch so one failure does
    not block the other. Installation failures produce warnings but never
    terminating errors.

    This script always exits 0 so it cannot break a parent install pipeline.

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script dot-sources
    Resolve-RepoRoot.ps1 and walks up the directory tree to find the .git
    directory, falling back to the current working directory.

.EXAMPLE
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VsCodeExtensions.ps1

.EXAMPLE
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VsCodeExtensions.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes:
      0 - Always. Failures are reported as warnings, never terminating errors.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    # -------------------------------------------------------------------
    # Constants
    # -------------------------------------------------------------------
    $extensionIds = @(
        'ms-azuretools.vscode-bicep',
        'ms-azuretools.vscode-azure-mcp-server'
    )

    # -------------------------------------------------------------------
    # Resolve project root
    # -------------------------------------------------------------------
    . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
    if ($ProjectPath) {
        $projectRoot = $ProjectPath
    } else {
        $projectRoot = Resolve-RepoRoot
        if (-not $projectRoot) { $projectRoot = (Get-Location).Path }
    }
    $projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

    # -------------------------------------------------------------------
    # Step 1: Ensure .vscode/extensions.json has recommendations
    # -------------------------------------------------------------------
    $vscodeDir = Join-Path $projectRoot '.vscode'
    $extensionsPath = Join-Path $vscodeDir 'extensions.json'

    if (-not (Test-Path $vscodeDir)) {
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
    }

    if (-not (Test-Path $extensionsPath)) {
        $extJson = [pscustomobject]@{ recommendations = @() }
        Write-Host '  CREATED: .vscode\extensions.json' -ForegroundColor Green
    } else {
        $rawContent = Get-Content -Path $extensionsPath -Raw -Encoding UTF8
        $extJson = $rawContent | ConvertFrom-Json
    }

    # Ensure the recommendations property exists
    if (-not (Get-Member -InputObject $extJson -Name 'recommendations' -MemberType Properties)) {
        $extJson | Add-Member -NotePropertyName 'recommendations' -NotePropertyValue @()
    }

    $existingRecs = @($extJson.recommendations)
    $addedCount = 0
    $skippedRecCount = 0

    foreach ($extId in $extensionIds) {
        $alreadyPresent = $false
        foreach ($rec in $existingRecs) {
            if ($rec -and $rec.Equals($extId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyPresent = $true
                break
            }
        }
        if ($alreadyPresent) {
            Write-Host "  SKIPPED: $extId (already recommended)" -ForegroundColor Cyan
            $skippedRecCount++
        } else {
            $existingRecs += $extId
            Write-Host "  ADDED: $extId recommendation" -ForegroundColor Green
            $addedCount++
        }
    }

    if ($addedCount -gt 0) {
        $extJson.recommendations = $existingRecs
        $jsonText = $extJson | ConvertTo-Json -Depth 10
        Set-Content -Path $extensionsPath -Value $jsonText -Encoding UTF8
    }

    Write-Host "  Recommendations: $addedCount added, $skippedRecCount skipped." -ForegroundColor Cyan

    # -------------------------------------------------------------------
    # Step 2: Best-effort install via code CLI
    # -------------------------------------------------------------------
    $codeCli = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeCli) {
        Write-Host '  WARNING: code CLI not found - skipping extension installation. Ensure VS Code ''code'' CLI is on PATH, or install extensions manually from the VS Code Extensions panel.' -ForegroundColor Cyan
        exit 0
    }

    $installedExts = @()
    try {
        $installedExts = @(& code --list-extensions)
    } catch {
        Write-Host "  WARNING: Failed to list installed extensions - $($_.Exception.Message). Skipping installation." -ForegroundColor Yellow
        exit 0
    }

    $installedCount = 0
    $alreadyInstalledCount = 0
    $failedCount = 0

    foreach ($extId in $extensionIds) {
        $isInstalled = $false
        foreach ($inst in $installedExts) {
            if ($inst -and $inst.Equals($extId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isInstalled = $true
                break
            }
        }
        if ($isInstalled) {
            Write-Host "  SKIPPED: $extId (already installed)" -ForegroundColor Cyan
            $alreadyInstalledCount++
        } else {
            try {
                $installOutput = & code --install-extension $extId --force 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $stderrText = @($installOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
                    Write-Host "  WARNING: Failed to install $extId (exit code $LASTEXITCODE) - $stderrText" -ForegroundColor Yellow
                    $failedCount++
                } else {
                    Write-Host "  INSTALLED: $extId" -ForegroundColor Green
                    $installedCount++
                }
            } catch {
                Write-Host "  WARNING: Failed to install $extId - $($_.Exception.Message)" -ForegroundColor Yellow
                $failedCount++
            }
        }
    }

    Write-Host "  Extensions: $installedCount installed, $alreadyInstalledCount already installed, $failedCount failed." -ForegroundColor Cyan
} catch {
    Write-Host "  WARNING: Install-VsCodeExtensions encountered an error: $($_.Exception.Message)" -ForegroundColor Yellow
}

exit 0
