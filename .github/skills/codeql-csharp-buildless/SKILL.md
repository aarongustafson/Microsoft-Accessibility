---
name: codeql-csharp-buildless
description: "Enable CodeQL C# scanning for repositories with loose .cs files but no .sln or .csproj project file. Auto-generates a temporary .csproj, builds, scans, and cleans up. Use when C# scan fails because no project file exists, when the repo has standalone .cs files, scripts, or code snippets without a project structure, or when the user asks how to scan C# without a project file."
argument-hint: "Describe the issue: no .csproj or .sln, loose .cs files, C# scan skipped, or buildless scanning question"
user-invocable: true
disable-model-invocation: false
---

# C# Buildless Scanning Skill

Enable CodeQL C# scanning for repositories that contain `.cs` files but no `.sln` or `.csproj` project file. The scan script auto-generates a temporary project file, uses it for the build, and removes it after the scan.

## When to Use

- C# scan is skipped with `[FAIL] No .sln or .csproj found`
- Repository contains standalone `.cs` files (scripts, utilities, code samples, prototypes)
- User asks "can I scan C# without a project file?"
- User has loose `.cs` files in a non-.NET project (e.g., Unity scripts without a `.csproj`, or mixed-language repos)
- Pre-build validation fails because CodeQL's autobuild cannot find a build method for C#

## Background

CodeQL's C# extractor works by intercepting `csc.exe` (Roslyn compiler) calls during a `dotnet build`. Without a project file, there is nothing to build and the extractor captures nothing. The scan script solves this by generating a minimal temporary `.csproj` that includes all `.cs` files via `EnableDefaultCompileItems`, builds against it, and removes it after the scan completes.

## How It Works

The buildless scanning logic is implemented in the scan script's step 7c (pre-build validation) inside the `csharp` switch case. The flow is:

### Detection

When C# is in `$activeLanguages` and no `.sln` (root only) or `.csproj` (searched to depth 3) is found, the script checks for `.cs` files:

```powershell
$csFiles = Get-ChildItem -Path . -Filter '*.cs' -Recurse -Depth 5 -ErrorAction SilentlyContinue
```

If `.cs` files exist, the script proceeds to generate a temporary project.

### Temporary Project Generation

The generated `.csproj` is minimal and designed for maximum compatibility:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <OutputType>Library</OutputType>
    <EnableDefaultCompileItems>true</EnableDefaultCompileItems>
    <NoWarn>CS8021;CS0246;CS8019;CS0168;CS0219</NoWarn>
  </PropertyGroup>
</Project>
```

Key design decisions:
- **`OutputType=Library`** -- avoids requiring a `Main` method entry point
- **`EnableDefaultCompileItems=true`** -- automatically includes all `.cs` files in the directory tree (MSBuild default globbing)
- **`NoWarn` suppressions** -- silences common warnings that occur when scanning loose files without full dependency context:
  - `CS8021`: No value for RuntimeMetadataVersion (standalone files without runtime ref)
  - `CS0246`: Type or namespace not found (missing using/reference)
  - `CS8019`: Unnecessary using directive
  - `CS0168`: Variable declared but never used
  - `CS0219`: Variable assigned but never used
- **TargetFramework** -- auto-detected from the highest installed .NET SDK (`dotnet --list-sdks`), falls back to `net8.0`

### File Placement

The temporary project file is created at the repository root as `.codeql-temp-scan.csproj`. This location ensures:
- MSBuild's default globbing picks up all `.cs` files in the tree
- The file is clearly identified as temporary (dot-prefix, descriptive name)
- It is listed in `.gitignore` so it cannot be accidentally committed

### Cleanup

The temporary `.csproj` is tracked via the `$tempCsproj` variable and removed in the `finally` block (step 15) alongside other temporary files like `global.json`. Cleanup runs regardless of scan pass or fail.

## Limitations

- **Missing references**: Loose `.cs` files that reference external NuGet packages will produce build warnings (suppressed by `NoWarn`) but some code paths may not be analyzed if the compiler cannot resolve types. CodeQL still extracts what it can from the successful portions of the build.
- **Namespace conflicts**: If `.cs` files in different subdirectories define the same type, the build may fail. This is a project structure issue, not a scanning limitation.
- **Deep nesting**: The script searches to depth 5 for `.cs` files. Files deeper than this are not detected (but `EnableDefaultCompileItems` will still include them in the build if the `.csproj` is at the root).
- **Build failures**: If the generated project cannot build at all (e.g., all files have unresolvable dependencies), C# is removed from `$activeLanguages` and scanning continues for other languages.

## Interaction with Other Skills

- **codeql-csharp-sdk-compat**: If the temporary project triggers an SDK compatibility issue (exit code 32), the existing SDK pinning logic in step 7c applies normally -- it checks `$tempGlobalJson` and handles the `.NET SDK too new` case.
- **codeql-build-prereqs**: The `dotnet` CLI must be available. If it is not found, the build tool detection (step 7c) warns before the buildless logic runs.
- **codeql-troubleshoot**: If the temporary project build fails, the standard pre-build failure path runs and C# is skipped with guidance.

## Agent Behavior

- The temporary `.csproj` generation is **automatic** -- no user intervention needed.
- The `[AUTO]` prefix in the output clearly indicates this was an auto-generated action.
- If the user has a proper `.sln` or `.csproj` anywhere in the tree (depth 3), the standard build path is used instead -- buildless scanning is a fallback only.
- The skill does NOT create a permanent project file. If the user wants a real project structure, guide them to `dotnet new classlib` or `dotnet new console`.
