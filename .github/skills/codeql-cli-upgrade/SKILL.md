---
name: codeql-cli-upgrade
description: "Ensure the latest CodeQL CLI is installed and automatically upgrade older versions. Use when the user asks to upgrade CodeQL, ensure latest CodeQL is installed, refresh a stale CodeQL CLI, fix an older CodeQL version, update CodeQL after extractor incompatibility, or verify that the active session is using the newest CodeQL binary."
argument-hint: "Describe the CodeQL CLI issue: upgrade CodeQL, ensure latest installed, stale CodeQL version, old extractor, or PATH/session using old codeql"
user-invocable: true
disable-model-invocation: false
---

# CodeQL CLI Upgrade Skill

Ensure that the newest available CodeQL CLI is installed and that the current workspace is actually using it.

## When to Use

- User asks to **upgrade CodeQL**
- User asks to **ensure the latest CodeQL is installed**
- User reports CodeQL is **too old**
- User reports extractor compatibility issues after a reinstall
- User asks to **refresh** or **reinstall** CodeQL CLI
- User reports the installer succeeded but the scan still uses an older CodeQL version
- User wants to verify which `codeql` binary is active on PATH

## Default Behavior

When invoked, the agent should default to **performing** the upgrade workflow, not merely explaining it.

Use this order:
1. Detect the currently active `codeql` binary and version.
2. Query the latest CodeQL CLI release for the current platform.
3. If the installed version is older, upgrade it automatically.
4. Verify the newly installed CodeQL version directly.
5. Verify whether the current session is still resolving an older `codeql` binary.
6. If the session is stale, tell the user exactly what to do next.

## Upgrade Workflow

### 1. Detect Active CodeQL

```powershell
Get-Command codeql -ErrorAction SilentlyContinue | Format-List Source,Path
codeql version
```

If `codeql` is not found, proceed directly to installation.

### 2. Resolve Latest Release

Use GitHub Releases for `github/codeql-cli-binaries`.

Windows pattern:

```powershell
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/github/codeql-cli-binaries/releases/latest"
$asset = $release.assets | Where-Object { $_.name -match "codeql-win64\.zip$" } | Select-Object -First 1
```

Extract the semantic version from `tag_name` and compare it to the installed version.

### 3. Upgrade If Older

If the installed version is older than the latest release:

```powershell
Write-Host "[AUTO] Upgrading CodeQL CLI from v<current> to v<latest>" -ForegroundColor Cyan
```

Then download, extract, and update the user PATH to the managed install location:

```powershell
$codeqlBin = Join-Path $env:LOCALAPPDATA "CodeQL\codeql"
```

Use the same ZIP download and extraction flow as the installer. Prefer `System.Net.WebClient` for large downloads on Windows.

If the installed version already matches the latest release, print:

```powershell
Write-Host "[PASS] CodeQL CLI already current (v<latest>)" -ForegroundColor Green
```

### 4. Verify Managed Install

Always verify the managed install directly, even if the current session PATH may be stale:

```powershell
& "$env:LOCALAPPDATA\CodeQL\codeql\codeql.exe" version
```

### 5. Detect Stale Session Resolution

This is critical on Windows. The user PATH may be updated correctly while the already-open VS Code / Git / PowerShell session still resolves an older `codeql.exe`.

Check:

```powershell
$managedCodeql = Join-Path $env:LOCALAPPDATA 'CodeQL\codeql\codeql.exe'
$activeCodeql = (Get-Command codeql -ErrorAction SilentlyContinue).Source
```

If both exist and differ, compare versions. If the managed version is newer than the active one, print:

```powershell
Write-Host "[WARN] CodeQL Vibe installed or upgraded CodeQL to v<managed>, but this VS Code / PowerShell session is still resolving older v<active>." -ForegroundColor Yellow
Write-Host "[WARN] Restart VS Code, open a new terminal, run 'codeql version', then retry the commit." -ForegroundColor Yellow
```

Do not present this as an upgrade failure. The upgrade succeeded; the session is stale.

## Expected Outcome

After this skill runs successfully:

1. The latest CodeQL CLI release for the platform is installed.
2. The managed CodeQL location is known.
3. The user is told whether a restart is required before scans or hooks will use the new binary.

## Constraints

- Prefer automatic upgrade over manual instructions when the user asked to fix the issue.
- Do not leave the user to infer PATH or session-caching behavior.
- Always verify both the managed install and the currently active session resolution.
- If GitHub release metadata cannot be queried and CodeQL is already installed, warn clearly and stop short of claiming success.
- If GitHub release metadata cannot be queried and CodeQL is not installed, stop with a clear error and the manual download URL.
- Use GitHub Releases only; do not switch to `winget`, Homebrew, or other package managers for CodeQL CLI.

## Cross-References

- See `codeql-csharp-sdk-compat` when the upgrade need was triggered by a .NET SDK / extractor mismatch.
- See `codeql-hook-integrity` if the hook is still not firing after the correct CodeQL version is installed.