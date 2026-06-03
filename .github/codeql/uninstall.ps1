# CodeQL Vibe -- Uninstaller
# Removes hooks, profile entries, and CodeQL Vibe configuration.
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/uninstall.ps1"

$ErrorActionPreference = 'Continue'

Write-Host "Uninstalling CodeQL Vibe..." -ForegroundColor Cyan

# Auto-detect paths from this script's location (works from .github/codeql/ or .codeql/)
$codeqlDir = $PSScriptRoot
if (-not $codeqlDir) {
    # Fallback: $PSScriptRoot can be empty when invoked through git's MINGW bash layer
    $codeqlDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue)
    if (-not $codeqlDir) { $codeqlDir = (Get-Location).Path }
}
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if ($repoRoot) { $repoRoot = (Resolve-Path $repoRoot -ErrorAction SilentlyContinue).Path }
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
$codeqlRelPath = ($codeqlDir.Substring($repoRoot.Length).TrimStart([char]'\', [char]'/') -replace '\\', '/')
$hooksRelPath = "$codeqlRelPath/hooks"

# 1. Remove core.hooksPath
$hooksPath = git config --get core.hooksPath 2>$null
if ($hooksPath -eq $hooksRelPath) {
    git config --unset core.hooksPath
    Write-Host "[PASS] Removed core.hooksPath" -ForegroundColor Green
} elseif ($hooksPath) {
    Write-Host "[SKIP] core.hooksPath is '$hooksPath' (not CodeQL Vibe) -- leaving unchanged" -ForegroundColor Yellow
} else {
    Write-Host "[SKIP] core.hooksPath was not set" -ForegroundColor Yellow
}

# 2. Restore original pre-commit hook
if (Test-Path '.git/hooks/pre-commit.backup') {
    Copy-Item '.git/hooks/pre-commit.backup' '.git/hooks/pre-commit' -Force
    Write-Host "[PASS] Restored original pre-commit hook from backup" -ForegroundColor Green
}

# 3. Remove CodeQL Vibe block from PowerShell profile
$profilePath = $PROFILE
if (-not $profilePath) {
    $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell' 'Microsoft.PowerShell_profile.ps1'
}
if ($profilePath -and (Test-Path $profilePath)) {
    $content = Get-Content $profilePath -Raw
    if ($content -match '# --- CodeQL Vibe start ---') {
        $cleaned = $content -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\r?\n?', ''
        Set-Content $profilePath $cleaned.TrimEnd() -Encoding UTF8
        Write-Host "[PASS] Removed CodeQL Vibe block from PowerShell profile" -ForegroundColor Green
    } else {
        Write-Host "[SKIP] No CodeQL Vibe block in PowerShell profile" -ForegroundColor Yellow
    }
} elseif (Test-Path "$profilePath.pre-codeql") {
    Copy-Item "$profilePath.pre-codeql" $profilePath -Force
    Write-Host "[PASS] Restored PowerShell profile from .pre-codeql backup" -ForegroundColor Green
}

# 4. Remove CodeQL Vibe block from bash/zsh profiles (macOS/Linux)
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    foreach ($rc in @("$HOME/.bashrc", "$HOME/.zshrc")) {
        if (Test-Path $rc) {
            $content = Get-Content $rc -Raw
            if ($content -match '# --- CodeQL Vibe start ---') {
                $cleaned = $content -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\n?', ''
                Set-Content $rc $cleaned.TrimEnd()
                Write-Host "[PASS] Removed CodeQL Vibe block from $(Split-Path $rc -Leaf)" -ForegroundColor Green
            }
        } elseif (Test-Path "$rc.pre-codeql") {
            Copy-Item "$rc.pre-codeql" $rc -Force
            Write-Host "[PASS] Restored $(Split-Path $rc -Leaf) from .pre-codeql backup" -ForegroundColor Green
        }
    }
}

Write-Host "" -ForegroundColor Cyan
Write-Host "CodeQL Vibe has been uninstalled." -ForegroundColor Cyan
Write-Host "The $codeqlRelPath/ folder was left in place. Delete it manually if no longer needed:" -ForegroundColor Yellow
Write-Host "  Remove-Item -Recurse -Force $codeqlRelPath" -ForegroundColor White
Write-Host ""
Write-Host "To reinstall: powershell -ExecutionPolicy Bypass -NoProfile -File `"$codeqlRelPath/install.ps1`"" -ForegroundColor Cyan
