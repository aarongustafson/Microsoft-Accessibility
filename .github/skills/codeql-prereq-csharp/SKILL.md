---
name: codeql-prereq-csharp
description: "Ensure prerequisites for C# CodeQL scanning. Detects .NET SDK, restores NuGet packages, validates builds, handles SDK compatibility, and supports buildless scanning for loose .cs files. Use when C# scan fails, when dotnet is missing, when NuGet restore fails, or when setting up C# scanning."
argument-hint: "Describe the issue: dotnet not found, NuGet restore failed, build error, no .csproj, SDK version mismatch, or C# scan question"
user-invocable: true
disable-model-invocation: false
---

# C# Prerequisites Skill

Ensure all prerequisites for CodeQL C# scanning are met before the scan runs.

## Language Classification

**Compiled** -- CodeQL's C# extractor intercepts Roslyn (`csc.exe`) compiler calls during `dotnet build`. A .NET SDK and a successful build are required for database creation.

## CodeQL Language ID

`csharp` -- covers `.cs` files.

## Prerequisites

### Required

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| .NET SDK (dotnet) | Build C# projects and invoke Roslyn | `Get-Command dotnet` | https://dot.net/download |

### Required (one of)

| Item | Purpose | Detection |
|---|---|---|
| `.sln` file | Solution file covering the project | `Get-ChildItem -Filter '*.sln' -Depth 0` |
| `.csproj` file | Individual project file | `Get-ChildItem -Filter '*.csproj' -Recurse -Depth 3` |
| Loose `.cs` files | Buildless fallback auto-generates a temp `.csproj` | `Get-ChildItem -Filter '*.cs' -Recurse -Depth 5` |

## Dependency Restoration Flow

```powershell
'csharp' {
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $sln = Get-ChildItem -Path . -Filter '*.sln' -Depth 0 | Select-Object -First 1
        if ($sln) {
            & dotnet restore $sln.FullName --verbosity quiet 2>$null
        } else {
            $projs = Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3
            foreach ($p in $projs) { & dotnet restore $p.FullName --verbosity quiet 2>$null }
        }
    }
}
```

Prefers `.sln` (covers multi-project solutions) over individual `.csproj` files.

## Pre-Build Validation Flow

### Standard Path (with project file)

1. **SDK detection**: Check `dotnet` on PATH. If missing, emit `[FAIL]` and skip C#.
2. **Project detection**: Find `.sln` or `.csproj`. If neither found, fall to buildless path.
3. **NuGet restore**: Run `dotnet restore` (best-effort).
4. **Build validation**: Run `dotnet build --no-restore --verbosity quiet`. If fails, check for CS1069 (missing packages) and provide guidance.
5. **SDK compatibility**: If SDK 10+ and no `global.json`, check if project targets a compatible framework. Auto-pin to older SDK if possible.
6. **Build success**: Emit `[PASS] C# build validation OK`.

### Buildless Path (no project file)

When no `.sln` or `.csproj` exists but `.cs` files are found:

1. Auto-detect target framework from installed .NET SDK.
2. Generate `.codeql-temp-scan.csproj` with `OutputType=Library` and `EnableDefaultCompileItems=true`.
3. Suppress common warnings: CS8021, CS0246, CS8019, CS0168, CS0219.
4. Set `$buildTarget` to the temp `.csproj`.
5. Emit `[AUTO] No .sln or .csproj found -- generating temporary project for C# scan`.
6. Cleanup in `finally` block removes the temp file.

See **codeql-csharp-buildless** skill for full details on the buildless scanning flow.

## SDK Compatibility

CodeQL's C# extractor may lag behind the latest .NET SDK. The scan script handles this:

- **SDK 10+ with older project target**: Auto-creates temporary `global.json` to pin to compatible SDK (8.x or 9.x).
- **SDK 10+ with matching project target**: Cannot pin -- warns user to update CodeQL CLI.
- **Stale session detection**: If a newer CodeQL CLI was installed but the current terminal uses an older one, warns to restart VS Code.

See **codeql-csharp-sdk-compat** skill for full details on SDK compatibility resolution.

## Auto-Install

When the .NET SDK is not found during pre-build validation, scan.ps1 automatically attempts installation:

1. Downloads the official `dotnet-install.ps1` script from Microsoft.
2. Installs .NET SDK 9.x to `%LOCALAPPDATA%\dotnet` on Windows or `~/.dotnet` on macOS/Linux (user-local, no admin required).
3. Adds the install directory to the current session PATH.
4. Verifies the installation with `dotnet --version`.

If auto-install succeeds (`[PASS]`), the scan continues with full C# validation including buildless fallback. If it fails (`[WARN]`), the scan emits `[FAIL]` with the manual install URL and skips C#.

### Install Method

```powershell
$installScript = Join-Path $env:TEMP 'dotnet-install.ps1'
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript -UseBasicParsing
$dotnetDir = Join-Path $env:LOCALAPPDATA 'dotnet'
& $installScript -Channel 9.0 -InstallDir $dotnetDir
```

### Fallback

If auto-install fails (network restrictions, proxy, or permissions), the user sees:

```
[FAIL] dotnet CLI not found -- skipping C# CodeQL scan
  Install the .NET SDK: https://dot.net/download
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| `dotnet` not found | .NET SDK not installed | Install from https://dot.net/download |
| CS1069 errors | Missing NuGet package references | Run `dotnet add package <PackageName>` |
| Exit code 32 | SDK version newer than CodeQL supports | Pin SDK via `global.json` or update CodeQL CLI |
| No `.sln` or `.csproj` | Loose `.cs` files | Buildless fallback auto-generates temp `.csproj` |
| `NETSDK1045` | SDK version pinned to unavailable version | Remove or update `global.json` |
| Deprecated packages | `System.Data.SqlClient` etc. | Replace with modern equivalents (see CS1069 guidance) |

## Interaction with Other Skills

- **codeql-csharp-buildless**: Handles the buildless scanning path for repos with loose `.cs` files.
- **codeql-csharp-sdk-compat**: Resolves .NET SDK version conflicts with CodeQL's C# extractor.
- **codeql-build-prereqs**: Covers C# at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Can install .NET SDK 9.x via `dotnet-install.ps1` or winget.
