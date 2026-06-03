---
name: codeql-legacy-migration
description: "Detect and migrate legacy .codeql/ installations to the current .github/codeql/ path. Use when pre-flight detects .codeql/ at the project root, when the user reports split or stale configuration, when hooks reference .codeql/hooks, or when the user asks to migrate or upgrade the folder layout."
argument-hint: "Describe the issue: old .codeql/ folder present, hooks pointing to wrong path, stale config, or migration request"
user-invocable: true
disable-model-invocation: false
---

# Legacy Migration Skill

Detect installations that use the old `.codeql/` folder at the project root and migrate them to the current `.github/codeql/` layout. This is a one-time migration for early adopters who installed before the path change.

## When to Use

- Pre-flight check detects `.codeql/` folder at the project root
- `core.hooksPath` is set to `.codeql/hooks` (legacy path)
- Shell profile contains references to `.codeql/git-secure.ps1` or `.codeql/scan.ps1`
- User reports "hooks not firing" and `.codeql/` exists alongside `.github/codeql/`
- User explicitly asks to migrate or upgrade the folder layout
- Agent detects split config (some files in `.codeql/`, some in `.github/codeql/`)

## Detection Logic

Run this detection as part of the Phase 0 pre-flight check. Add it after the existing setup detection (step 7):

```powershell
# 7b. Legacy path detection (.codeql/ at project root)
$preflight.legacySetup = $false
$preflight.legacyHooksPath = $false
if (Test-Path '.codeql/scan.ps1') {
    $preflight.legacySetup = $true
    Write-Host "[WARN] Legacy .codeql/ folder detected at project root" -ForegroundColor Yellow
}
$currentHooksPath = git config --get core.hooksPath 2>$null
if ($currentHooksPath -eq '.codeql/hooks') {
    $preflight.legacyHooksPath = $true
    Write-Host "[WARN] core.hooksPath points to legacy .codeql/hooks" -ForegroundColor Yellow
}
```

## Migration Workflow

When `legacySetup` is true, the agent MUST offer migration before proceeding with any other operation. The workflow is:

### Step 1: Inventory Legacy Files

```powershell
Write-Host "Inventorying legacy .codeql/ installation..." -ForegroundColor Cyan

$legacyFiles = @()
$legacyRoot = '.codeql'

if (Test-Path $legacyRoot) {
    $legacyFiles = Get-ChildItem -Path $legacyRoot -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object FullName, Name, Length
    Write-Host "[INFO] Found $($legacyFiles.Count) file(s) in .codeql/" -ForegroundColor Cyan
    foreach ($f in $legacyFiles) {
        Write-Host "  $($f.FullName)" -ForegroundColor White
    }
}

# Check for legacy shell profile entries
$profilePath = $PROFILE
if (-not $profilePath) {
    $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell' 'Microsoft.PowerShell_profile.ps1'
}
$hasLegacyProfile = $false
if ($profilePath -and (Test-Path $profilePath)) {
    $profileContent = Get-Content $profilePath -Raw
    if ($profileContent -match '\.codeql[/\\](git-secure|scan)\.ps1') {
        $hasLegacyProfile = $true
        Write-Host "[WARN] Shell profile references legacy .codeql/ paths" -ForegroundColor Yellow
    }
}
```

### Step 2: Present Migration Summary

Show the user what will happen before proceeding:

```
Legacy CodeQL installation detected at .codeql/ (old layout).
The current layout uses .github/codeql/ instead.

Migration will:
1. Remove the legacy pre-commit hook configuration (core.hooksPath .codeql/hooks)
2. Remove the legacy CodeQL Vibe block from your shell profile
3. Delete the .codeql/ folder (script files only -- not databases or SARIF results)
4. Run a fresh install using the current .github/codeql/ layout

Files NOT affected:
- .codeql-db/ (scan databases -- stays at project root)
- .codeql-results*.sarif (scan results -- stays at project root)
- Your source code (never modified by migration)

Shall I proceed with the migration?
```

### Step 3: Uninstall Legacy Setup

After user confirmation, clean up the old installation:

```powershell
Write-Host "Removing legacy CodeQL setup..." -ForegroundColor Cyan

# 3a. Unset core.hooksPath if it points to the legacy path
$hooksPath = git config --get core.hooksPath 2>$null
if ($hooksPath -eq '.codeql/hooks') {
    git config --unset core.hooksPath
    Write-Host "[PASS] Removed legacy core.hooksPath (.codeql/hooks)" -ForegroundColor Green
} elseif ($hooksPath -eq '.github/codeql/hooks') {
    Write-Host "[SKIP] core.hooksPath already points to .github/codeql/hooks" -ForegroundColor Yellow
} elseif ($hooksPath) {
    Write-Host "[SKIP] core.hooksPath is '$hooksPath' (not CodeQL Vibe) -- leaving unchanged" -ForegroundColor Yellow
} else {
    Write-Host "[SKIP] core.hooksPath was not set" -ForegroundColor Yellow
}

# 3b. Restore original pre-commit hook if backed up
if (Test-Path '.git/hooks/pre-commit.backup') {
    Copy-Item '.git/hooks/pre-commit.backup' '.git/hooks/pre-commit' -Force
    Write-Host "[PASS] Restored original pre-commit hook from backup" -ForegroundColor Green
}

# 3c. Remove legacy CodeQL Vibe block from PowerShell profile
$profilePath = $PROFILE
if (-not $profilePath) {
    $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell' 'Microsoft.PowerShell_profile.ps1'
}
if ($profilePath -and (Test-Path $profilePath)) {
    $content = Get-Content $profilePath -Raw
    if ($content -match '# --- CodeQL Vibe start ---') {
        $cleaned = $content -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\r?\n?', ''
        Set-Content $profilePath $cleaned.TrimEnd() -Encoding UTF8
        Write-Host "[PASS] Removed legacy CodeQL Vibe block from PowerShell profile" -ForegroundColor Green
    }
}

# 3d. Remove legacy CodeQL Vibe block from bash/zsh profiles (macOS/Linux)
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    foreach ($rc in @("$HOME/.bashrc", "$HOME/.zshrc")) {
        if (Test-Path $rc) {
            $rcContent = Get-Content $rc -Raw
            if ($rcContent -match '# --- CodeQL Vibe start ---') {
                $cleaned = $rcContent -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\n?', ''
                Set-Content $rc $cleaned.TrimEnd()
                Write-Host "[PASS] Removed legacy CodeQL Vibe block from $(Split-Path $rc -Leaf)" -ForegroundColor Green
            }
        }
    }
}

# 3e. Delete the legacy .codeql/ folder
if (Test-Path '.codeql') {
    Remove-Item -Recurse -Force '.codeql' -ErrorAction SilentlyContinue
    if (-not (Test-Path '.codeql')) {
        Write-Host "[PASS] Deleted legacy .codeql/ folder" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Could not fully delete .codeql/ -- remove it manually" -ForegroundColor Yellow
    }
}

# 3f. Clean up legacy .gitignore entries
if (Test-Path '.gitignore') {
    $gitignore = Get-Content '.gitignore' -Raw
    # Remove old entries that referenced .codeql/ (not .codeql-db/ or .codeql-results)
    $legacyEntries = @('.codeql/.scan-lock', '.codeql/status.json')
    $changed = $false
    foreach ($entry in $legacyEntries) {
        if ($gitignore -match [regex]::Escape($entry)) {
            $gitignore = $gitignore -replace [regex]::Escape($entry) + '\r?\n?', ''
            $changed = $true
        }
    }
    if ($changed) {
        Set-Content '.gitignore' $gitignore.TrimEnd() -Encoding UTF8
        Write-Host "[PASS] Removed legacy .codeql/ entries from .gitignore" -ForegroundColor Green
    }
}

Write-Host "" -ForegroundColor Cyan
Write-Host "Legacy cleanup complete." -ForegroundColor Green
```

### Step 4: Fresh Install

After the legacy cleanup, proceed with the standard setup flow:

```
The legacy .codeql/ installation has been removed.
Now running a fresh install with the current .github/codeql/ layout...
```

Then invoke the normal "Full Setup" workflow (Prompt 1). This runs the standard Phase 0 through Phase 4 installation, which creates all files under `.github/codeql/`, sets `core.hooksPath` to `.github/codeql/hooks`, configures shell profiles with the new paths, and runs validation.

## Edge Cases

### Both Folders Exist

If both `.codeql/` and `.github/codeql/` exist, the migration still applies. The legacy `.codeql/` folder is removed and the `.github/codeql/` setup is refreshed via reinstall.

### Legacy Hooks Path but No .codeql/ Folder

If `core.hooksPath` points to `.codeql/hooks` but the `.codeql/` folder is gone (partially cleaned up), unset `core.hooksPath` and proceed with a fresh install. The shell profile cleanup still runs to catch stale aliases.

### Custom Files in .codeql/

The migration deletes everything under `.codeql/`. If users added custom files there (unlikely in early stage), they will be lost. The migration summary warns that `.codeql/` will be deleted. User confirmation is required before proceeding.

### .codeql in .gitignore paths-ignore

The `codeql-config.yml` may contain `- .codeql` in `paths-ignore`. This entry is harmless (the folder no longer exists) and `.github` in the same list already covers `.github/codeql/`. No cleanup needed.

## Agent Behavior

- **Auto-detect**: When the agent detects `legacySetup = true` during pre-flight, it MUST inform the user and offer migration before proceeding with any other task.
- **No silent migration**: The agent MUST show the migration summary and get user confirmation before deleting anything.
- **One-shot**: After migration, the standard install flow runs. No second confirmation is needed for the install (migration confirmation covers both steps).
- **Idempotent**: If `.codeql/` does not exist, the skill is a no-op. The agent proceeds with normal setup.
