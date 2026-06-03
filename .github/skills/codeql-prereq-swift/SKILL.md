---
name: codeql-prereq-swift
description: "Ensure prerequisites for Swift CodeQL scanning. Detects macOS platform, validates Xcode installation, resolves Swift Package Manager and CocoaPods dependencies, and validates builds. Use when Swift scan fails, when Xcode is missing, when Swift build errors occur, or when setting up Swift scanning."
argument-hint: "Describe the issue: Xcode not found, not on macOS, swift build failed, CocoaPods error, or Swift scan question"
user-invocable: true
disable-model-invocation: false
---

# Swift Prerequisites Skill

Ensure all prerequisites for CodeQL Swift scanning are met before the scan runs.

## Language Classification

**Compiled** -- CodeQL's Swift extractor intercepts Swift compiler calls during the build. macOS with Xcode and a successful build are required.

## CodeQL Language ID

`swift` -- covers `.swift` files.

## Prerequisites

### Required

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| macOS | Swift scanning requires macOS | `$IsMacOS` or `$PSVersionTable.OS -match 'Darwin'` | N/A (platform requirement) |
| Xcode | Provides `xcodebuild` and the Swift compiler | `Get-Command xcodebuild` | macOS App Store |

### Recommended

| Tool | Purpose | Detection |
|---|---|---|
| Swift Package Manager | Resolve SPM dependencies | `Test-Path Package.swift` |
| CocoaPods | Resolve pod dependencies | `Get-Command pod` + `Test-Path Podfile` |

## Platform Constraint

**Swift CodeQL scanning is only supported on macOS.** The scan script checks the platform and skips Swift on Windows and Linux with a clear message:

```powershell
if (-not $IsMacOS -and -not ($PSVersionTable.OS -match 'Darwin')) {
    Write-Host "[FAIL] Swift scanning requires macOS -- skipping on this platform" -ForegroundColor Red
    $preBuildFailed += $lang
}
```

## Dependency Restoration Flow

```powershell
'swift' {
    if ((Get-Command swift -ErrorAction SilentlyContinue) -and (Test-Path 'Package.swift')) {
        Write-Host "Resolving Swift packages..." -ForegroundColor Cyan
        & swift package resolve 2>$null
    }
    if ((Get-Command pod -ErrorAction SilentlyContinue) -and (Test-Path 'Podfile')) {
        Write-Host "Installing CocoaPods..." -ForegroundColor Cyan
        & pod install 2>$null
    }
}
```

Checks for both SPM (`Package.swift`) and CocoaPods (`Podfile`). Projects may use one or both.

## Pre-Build Validation Flow

1. **Platform check**: If not macOS, emit `[FAIL]` and skip Swift. This is a blocking failure -- Swift scanning cannot work on other platforms.
2. **Xcode detection**: Check `xcodebuild` on PATH. If missing, emit `[FAIL]` and skip Swift.
3. **Both present**: Emit `[PASS] Swift -- Xcode and compiler detected`.

```powershell
'swift' {
    if (-not $IsMacOS -and -not ($PSVersionTable.OS -match 'Darwin')) {
        Write-Host "[FAIL] Swift scanning requires macOS -- skipping on this platform" -ForegroundColor Red
        $preBuildFailed += $lang
    } elseif (-not (Get-Command xcodebuild -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] Xcode not found -- Swift scanning requires xcodebuild" -ForegroundColor Red
        Write-Host "  Install Xcode from the Mac App Store" -ForegroundColor Yellow
        $preBuildFailed += $lang
    } else {
        Write-Host "[PASS] Swift -- Xcode and compiler detected" -ForegroundColor Green
    }
}
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| Not on macOS | Windows or Linux | Swift scanning is macOS-only |
| `xcodebuild` not found | Xcode not installed | Install Xcode from the Mac App Store |
| `xcode-select` error | No active developer directory | Run `sudo xcode-select --switch /Applications/Xcode.app` |
| SPM resolution fails | Network or version conflicts | Run `swift package resolve` manually and fix `Package.swift` |
| CocoaPods install fails | Version conflicts or missing specs | Run `pod repo update` then `pod install` |
| Build scheme not found | Xcode project misconfigured | Specify scheme: `xcodebuild -scheme <Name>` |

## Interaction with Other Skills

- **codeql-build-prereqs**: Covers Swift at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Does not install Xcode (requires App Store). Points user to the correct download.
- **codeql-scan-perf**: Swift scans depend on Xcode build performance.
