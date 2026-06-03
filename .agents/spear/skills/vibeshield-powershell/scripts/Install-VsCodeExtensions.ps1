<#
.SYNOPSIS
    Recommends and optionally installs the VS Code PowerShell extension.

.DESCRIPTION
    Ensures the VS Code PowerShell extension (ms-vscode.PowerShell) is listed
    in the project's .vscode/extensions.json recommendations file and attempts
    a best-effort install via the 'code' CLI.

    Step 1 - Updates .vscode/extensions.json with the extension recommendation.
    Creates the file and directory if they do not exist.

    Step 2 - If the 'code' CLI is available, attempts to install the extension.
    Failures in this step are warnings only and never terminate the script.

    The ms-vscode.PowerShell extension provides rich PowerShell language support,
    IntelliSense, and debugging - required by the vibeshield-powershell agent for
    effective script authoring and validation workflows.

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script resolves the
    repository root via Resolve-RepoRoot, falling back to the current directory.

.EXAMPLE
    & Install-VsCodeExtensions.ps1

.EXAMPLE
    & Install-VsCodeExtensions.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes:
      0 - Always. This script must never crash the parent install process.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
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
    # Extension list
    # -------------------------------------------------------------------
    $extensionIds = @(
        'ms-vscode.PowerShell'
    )

    # ===================================================================
    # Step 1: Ensure .vscode/extensions.json has recommendations
    # ===================================================================
    $vscodeDir = Join-Path $projectRoot '.vscode'
    $extensionsPath = Join-Path $vscodeDir 'extensions.json'

    if (-not (Test-Path $vscodeDir)) {
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
    }

    if (-not (Test-Path $extensionsPath)) {
        $extensionsObj = [pscustomobject]@{ recommendations = @() }
        Write-Host '  CREATED: .vscode\extensions.json' -ForegroundColor Green
    } else {
        $raw = Get-Content -Path $extensionsPath -Raw -Encoding UTF8
        $extensionsObj = $raw | ConvertFrom-Json
    }

    # Ensure recommendations property exists.
    # Use indexer instead of .Properties.Name to avoid StrictMode PropertyNotFoundException
    # when the parsed object has zero properties (e.g., extensions.json is '{}').
    if ($null -eq $extensionsObj.PSObject.Properties['recommendations']) {
        $extensionsObj | Add-Member -MemberType NoteProperty -Name 'recommendations' -Value @()
    }

    $recommendations = @($extensionsObj.recommendations)
    $addedCount = 0
    $skippedCount = 0

    foreach ($extId in $extensionIds) {
        $alreadyPresent = $false
        foreach ($rec in $recommendations) {
            if ($rec -and $rec.ToString().Equals($extId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyPresent = $true
                break
            }
        }

        if ($alreadyPresent) {
            Write-Host "  SKIPPED: $extId (already recommended)" -ForegroundColor Cyan
            $skippedCount++
        } else {
            $recommendations += $extId
            Write-Host "  ADDED: $extId recommendation" -ForegroundColor Green
            $addedCount++
        }
    }

    if ($addedCount -gt 0) {
        $extensionsObj.recommendations = $recommendations
        $json = $extensionsObj | ConvertTo-Json -Depth 10
        Set-Content -Path $extensionsPath -Value $json -Encoding UTF8
    }

    Write-Host "  Recommendations: $addedCount added, $skippedCount skipped." -ForegroundColor Cyan

    # ===================================================================
    # Step 2: Best-effort install via code CLI
    # ===================================================================
    $codeCli = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeCli) {
        Write-Host '  WARNING: code CLI not found - skipping extension installation. Ensure VS Code ''code'' CLI is on PATH, or install extensions manually from the VS Code Extensions panel.' -ForegroundColor Cyan
        exit 0
    }

    $installedExtensions = @()
    try {
        $installedExtensions = @(code --list-extensions)
    } catch {
        Write-Host "  WARNING: Failed to list installed extensions - $($_.Exception.Message). Skipping installation." -ForegroundColor Yellow
        exit 0
    }

    $installedCount = 0
    $alreadyInstalledCount = 0
    $failedCount = 0

    foreach ($extId in $extensionIds) {
        $isInstalled = $false
        foreach ($installed in $installedExtensions) {
            if ($installed -and $installed.ToString().Equals($extId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isInstalled = $true
                break
            }
        }

        if ($isInstalled) {
            Write-Host "  SKIPPED: $extId (already installed)" -ForegroundColor Cyan
            $alreadyInstalledCount++
        } else {
            try {
                $installOutput = code --install-extension $extId --force 2>&1
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
    Write-Host "  WARNING: Install-VsCodeExtensions encountered an error - $($_.Exception.Message)" -ForegroundColor Yellow
}

exit 0
