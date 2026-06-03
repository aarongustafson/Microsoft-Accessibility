---
name: codeql-csharp-sdk-compat
description: "Diagnose and automatically resolve .NET SDK compatibility issues with CodeQL's C# extractor. Use when C# scan fails with exit code 32, SDK version mismatch, NETSDK1045 errors, global.json pinning, missing SQL client, deprecated NuGet packages like System.Data.SqlClient, when CodeQL cannot process C# compiler output, or when the user wants the issue fixed automatically."
argument-hint: "Describe the C# build or scan issue: exit code 32, SDK too new, NETSDK1045, missing SQL client, deprecated package, global.json questions, fix automatically"
user-invocable: true
disable-model-invocation: false
---

# C# SDK Compatibility Skill

Diagnose and automatically resolve .NET SDK version conflicts that prevent CodeQL from scanning C# code.

## When to Use

- C# scan fails with **exit code 32** ("detected code but could not process any of it")
- User reports **NETSDK1045** errors during scan
- User asks about **global.json** pinning for CodeQL
- User sees "CodeQL detected code written in C# but could not process any of it"
- User asks why C# scan fails when `dotnet build` succeeds
- CodeQL autobuild shows "Build succeeded" but scan still fails
- C# build fails with **missing SQL client** or `CS1069` (type forwarded to missing assembly)
- User references **deprecated packages** like `System.Data.SqlClient`
- User asks which **NuGet package** to use for SQL Server connectivity
- User asks to **fix** the compatibility issue automatically

## Background

CodeQL's C# extractor works by intercepting `csc.exe` (the Roslyn compiler) calls during the build. When the .NET SDK is newer than CodeQL supports, the extractor cannot hook the compiler — the build succeeds but CodeQL captures nothing. This manifests as exit code 32.

## Default Behavior

When this skill is invoked for a real workspace failure, the agent should default to **repairing the issue**, not stopping at explanation.

Use this order:
1. Confirm the failure is an SDK/extractor mismatch.
2. Choose the least invasive repair that preserves the project's target framework.
3. Execute the repair automatically when the user asked to fix the issue.
4. Re-run the relevant build or scan once to verify the repair.

Do not stop at diagnosis unless the environment prevents repair.

## Automatic Repair Workflow

### Repair Path A: Temporary SDK Pin

If the installed SDK is newer than CodeQL supports and the project still targets an older framework, rely on the scan script's temporary `global.json` pinning behavior. This is already the preferred automatic fix because it is reversible and does not permanently modify the repo.

### Repair Path B: Refresh CodeQL CLI Through CodeQL Vibe

If the project targets the same framework as the installed SDK major version, pinning to an older SDK would break the build. In that case, the default fix is to refresh CodeQL CLI through CodeQL Vibe setup.

Preferred repair flow:
1. Re-run CodeQL Vibe setup in VS Code:
    - Copilot: `/speckit.codeql` and choose `Full Setup`
    - Claude: `Set up CodeQL`
    - If the user specifically wants the CLI refreshed without rerunning everything, invoke the `codeql-cli-upgrade` skill.
2. If `.github/codeql/install.ps1` already exists in the workspace and the user asked for an automatic fix, run that installer directly.
3. If the same session still resolves the older CodeQL after reinstall, restart VS Code, open a fresh terminal, run `codeql version`, and only then retry the scan.
4. Re-run the relevant scan once.

Do not treat "CodeQL already installed" as success. The repair path exists to refresh a stale CLI.

### Repair Path C: Install a Compatible Side-by-Side SDK

If the project targets an older framework but no compatible SDK is installed, install one side-by-side and retry the scan.

Preferred Windows command:

```powershell
winget install Microsoft.DotNet.SDK.9
```

### Repair Path D: Missing Package Fixes

If the root cause is actually a build failure such as missing `System.Data.SqlClient`, fix the project dependency first, then re-run the build and scan once.

## Diagnostic Procedure

### 1. Confirm the Symptom

Check for these three conditions:
1. `dotnet build` succeeds (0 errors)
2. CodeQL autobuild exits 0 ("Build succeeded")
3. `codeql database create` exits with code **32**

If all three are true, the issue is an SDK/extractor version mismatch.

### 2. Check SDK Version

```powershell
dotnet --version        # Current SDK version
dotnet --list-sdks      # All installed SDKs
```

If the SDK major version is >= 10, it is likely too new for the current CodeQL CLI release.

### 3. Check Target Frameworks

Scan all `.csproj` files for `<TargetFramework>`:

```powershell
Get-ChildItem -Recurse -Filter '*.csproj' | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -match '<TargetFramework[s]?>[^<]*net(\d+)\.\d[^<]*</TargetFramework[s]?>') {
        [PSCustomObject]@{ File = $_.Name; TFM = "net$($Matches[1]).0" }
    }
}
```

This determines which resolution path to follow.

### 4. Choose Resolution

**Decision matrix:**

| SDK Major | TFM Major | Can Auto-Pin? | Resolution |
|---|---|---|---|
| >= 10 | < SDK Major (e.g. net8.0, net9.0) | Yes | Temporary `global.json` pin to 8.x/9.x SDK |
| >= 10 | >= SDK Major (e.g. net10.0) | No | Refresh CodeQL CLI through CodeQL Vibe setup or retarget project |
| < 10 | Any | N/A | Not an SDK compat issue — different root cause |

### Resolution A: Auto-Pin (TFM < SDK Major)

The project targets an older framework (net8.0/net9.0) but the installed SDK is too new. Create a temporary `global.json`:

```powershell
# Find the best compatible SDK
$installed = & dotnet --list-sdks 2>$null
$compatSdk = $installed |
    Where-Object { $_ -match '^(8|9)\.\d+\.\d+' } |
    ForEach-Object { ($_ -split '\s')[0] } |
    Sort-Object { [version]$_ } -Descending |
    Select-Object -First 1

if ($compatSdk) {
    $compatMajor = ($compatSdk -split '\.')[0]
    $pinVersion = "$compatMajor.0.100"
    @{ sdk = @{ version = $pinVersion; rollForward = 'latestFeature' } } |
        ConvertTo-Json | Set-Content 'global.json' -Encoding UTF8
}
```

The scan script does this automatically (`$tempGlobalJson` flag) and cleans up in its `finally` block.

### Resolution B: Refresh CodeQL CLI (TFM >= SDK Major)

When the project targets the same framework as the SDK (e.g. net10.0 on SDK 10), pinning to an older SDK would cause NETSDK1045:

> NETSDK1045: The current .NET SDK does not support targeting .NET 10.0.

Options:
1. **Preferred:** re-run CodeQL Vibe setup so the installer refreshes CodeQL CLI automatically
2. **Manual fallback:** update CodeQL CLI directly from [github/codeql-cli-binaries/releases](https://github.com/github/codeql-cli-binaries/releases)
3. **Alternative:** install a compatible SDK alongside — `winget install Microsoft.DotNet.SDK.9` — and retarget the project to net9.0 if possible

When the user asked to fix the issue, choose option 1 by default.

### Resolution C: Manual global.json

For permanent control (not recommended for general use):

```json
{
  "sdk": {
    "version": "8.0.100",
    "rollForward": "latestFeature"
  }
}
```

This uses the latest 8.0.x patch installed. The project can still target any framework version — `global.json` only controls which SDK the CLI uses for build commands.

## How the Scan Script Handles This

The scan script (`.github/codeql/scan.ps1`) implements auto-resolution in step 7c:

1. Detects SDK major version >= 10
2. Checks that no `global.json` already exists
3. Scans all `.csproj` for the highest `<TargetFramework>` major
4. If TFM < SDK major: creates temporary `global.json` with `rollForward: latestFeature`
5. Sets `$tempGlobalJson = $true` for cleanup tracking
6. The `finally` block removes the temporary file after scan completes

If the TFM >= SDK major, the auto-pin is skipped and the repair path should refresh CodeQL CLI through CodeQL Vibe setup.

## Missing SQL Client and Deprecated Packages

C# builds commonly fail during CodeQL pre-build validation because a SQL client package is missing from the project. The scan's CS1069 handler detects this and suggests the correct `dotnet add package` command.

**Important:** When recommending packages, always prefer the actively maintained replacement over any deprecated predecessor.

### Deprecated-to-Recommended Package Map

| Deprecated Package | Recommended Replacement | Why |
|---|---|---|
| `System.Data.SqlClient` | `Microsoft.Data.SqlClient` | `System.Data.SqlClient` is in maintenance mode — no new features, only critical security fixes. `Microsoft.Data.SqlClient` is the actively developed driver with support for Always Encrypted, Azure AD auth, and current TDS protocol features. |
| `Microsoft.Azure.Storage.*` | `Azure.Storage.*` | Old `WindowsAzure.Storage` and `Microsoft.Azure.Storage.*` packages replaced by `Azure.Storage.Blobs`, `Azure.Storage.Queues`, etc. |
| `Microsoft.Azure.ServiceBus` | `Azure.Messaging.ServiceBus` | Old SDK replaced by unified Azure SDK (`Azure.*` namespace). |
| `Microsoft.Azure.EventHubs` | `Azure.Messaging.EventHubs` | Old SDK replaced by unified Azure SDK. |
| `Microsoft.Azure.KeyVault` | `Azure.Security.KeyVault.*` | Old SDK replaced by `Azure.Security.KeyVault.Secrets`, `.Keys`, `.Certificates`. |
| `Microsoft.AspNetCore.Mvc.NewtonsoftJson` (as sole JSON) | `System.Text.Json` (built-in) | `System.Text.Json` is the default in modern .NET. Newtonsoft is still supported but adds a dependency when not needed. |

### How the Scan Handles This

The scan's CS1069 handler extracts the missing assembly name from the build error. Before printing the `dotnet add package` suggestion, it checks the deprecated-to-recommended map:

```powershell
$deprecatedMap = @{
    'System.Data.SqlClient'         = 'Microsoft.Data.SqlClient'
    'Microsoft.Azure.Storage.Blob'  = 'Azure.Storage.Blobs'
    'Microsoft.Azure.Storage.Queue' = 'Azure.Storage.Queues'
    'Microsoft.Azure.ServiceBus'    = 'Azure.Messaging.ServiceBus'
    'Microsoft.Azure.EventHubs'     = 'Azure.Messaging.EventHubs'
    'Microsoft.Azure.KeyVault'      = 'Azure.Security.KeyVault.Secrets'
}
foreach ($pkg in $missingPkgs) {
    if ($deprecatedMap.ContainsKey($pkg)) {
        $rec = $deprecatedMap[$pkg]
        Write-Host "  dotnet add package $rec" -ForegroundColor Yellow
        Write-Host "    (replaces deprecated $pkg)" -ForegroundColor DarkYellow
    } else {
        Write-Host "  dotnet add package $pkg" -ForegroundColor Yellow
    }
}
```

This ensures developers are guided to the current, actively maintained package instead of adding a deprecated dependency.

### Missing SQL Client — Diagnosis

When a C# project uses `SqlConnection`, `SqlCommand`, or other types from `System.Data.SqlClient` without a package reference, the build fails with:

```
error CS1069: The type name 'SqlConnection' could not be found ... forwarded to assembly 'System.Data.SqlClient'
```

The correct fix is:

```powershell
dotnet add package Microsoft.Data.SqlClient
```

Then update `using` statements:

```csharp
// Before (deprecated)
using System.Data.SqlClient;

// After (recommended)
using Microsoft.Data.SqlClient;
```

Both packages provide the same core types (`SqlConnection`, `SqlCommand`, etc.) so the code logic remains identical — only the `using` directive and package reference change.

## Constraints

- Auto-pin only creates a **temporary** `global.json` — it is removed after the scan
- The scan never modifies the user's existing `global.json`
- If no compatible SDK (8.x/9.x) is installed, the scan warns and continues without pinning
- When the user asked to fix the issue, prefer executing the repair instead of only describing it
- Do not retarget the project's `TargetFramework` automatically unless the user explicitly asked for that code change
- After applying a repair, re-run the relevant build or scan once to verify the result
- The deprecated-to-recommended map covers common packages — extend it as new deprecations are announced
- See [Troubleshooting](../../../docs/troubleshooting.md) and [Dependencies Guide](../../../docs/dependencies-guide.md) for related documentation
