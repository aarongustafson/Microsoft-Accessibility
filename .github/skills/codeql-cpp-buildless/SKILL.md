---
name: codeql-cpp-buildless
description: "Enable CodeQL C/C++ scanning for repositories with loose .c/.cpp files but no build system (Makefile, CMakeLists.txt, .vcxproj). Auto-generates a temporary build command using the detected compiler. Use when C++ scan fails because CodeQL autobuild cannot find a build method, when the repo has standalone C/C++ files without a project structure, or when the user asks how to scan C/C++ without a build system."
argument-hint: "Describe the issue: no Makefile or CMakeLists.txt, loose .c/.cpp files, C++ scan skipped, or buildless scanning question"
user-invocable: true
disable-model-invocation: false
---

# C/C++ Buildless Scanning Skill

Enable CodeQL C/C++ scanning for repositories that contain `.c`, `.cpp`, `.cc`, or `.cxx` files but no build system (Makefile, CMakeLists.txt, build.ninja, .vcxproj, .sln). The scan script detects a compiler on PATH, generates a temporary build script, passes it to CodeQL via `--command`, and removes it after the scan.

## When to Use

- C++ scan fails with `[FAIL] database create for cpp exited with 2`
- CodeQL autobuild says "C/C++ requires a successful build for CodeQL analysis"
- Repository contains standalone `.c` or `.cpp` files (snippets, utilities, prototypes)
- User asks "can I scan C/C++ without a Makefile?"
- Pre-build validation fails because CodeQL autobuild cannot find a build method for C/C++

## Background

CodeQL's C/C++ extractor works by intercepting compiler calls (`cl.exe`, `gcc`, `clang`) during a build. Without a build system, CodeQL's `autobuild` cannot determine how to compile the files and exits with code 2. The scan script solves this by detecting a compiler on PATH, generating a temporary build script that compiles all C/C++ source files with `-c` (compile-only), and passing it via `--command` to `codeql database create`.

## How It Works

The buildless scanning logic is implemented in the scan script's step 7c (pre-build validation) inside a new `cpp` switch case. The flow is:

### Detection

When `cpp` is in `$activeLanguages` and no build system is found at the project root or in subdirectories (depth 3), the script checks for C/C++ source files:

```powershell
$cppFiles = Get-ChildItem -Path . -Recurse -Depth 5 -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.c', '.cpp', '.cc', '.cxx') }
```

If source files exist and a compiler is available, the script proceeds to generate a temporary build script.

### Build System Detection

The following files and patterns indicate an existing build system -- if any are found, the standard autobuild path is used instead:

- `Makefile` or `GNUmakefile` (root)
- `CMakeLists.txt` (root)
- `build.ninja` (root)
- `*.vcxproj` (depth 3)
- `*.sln` with C++ projects (depth 0)

### Compiler Detection

The script checks for compilers in this order:

1. `gcc` -- most broadly available, works on Windows (MinGW/MSYS2), macOS, Linux
2. `clang` -- available on macOS (Xcode CLT), Linux, Windows (LLVM)
3. `cl` -- MSVC on Windows (requires Visual Studio or Build Tools)

### Temporary Build Script

The generated build script compiles all detected C/C++ files with `-c` (compile-only, no linking):

```powershell
# For gcc/clang:
$files = @('file1.c', 'file2.cpp', ...)
foreach ($f in $files) {
    & gcc -c $f 2>&1 | Out-Null
}

# For cl (MSVC):
$files = @('file1.c', 'file2.cpp', ...)
foreach ($f in $files) {
    & cl /c $f 2>&1 | Out-Null
}
```

Key design decisions:
- **`-c` (compile-only)** -- avoids linker errors from missing `main()` or unresolved symbols
- **Errors suppressed** -- CodeQL extracts from whatever the compiler processes, even if some files have unresolvable includes
- **All files compiled individually** -- ensures CodeQL sees each file's compiler invocation

### File Placement

The temporary build script is created at the repository root as `.codeql-temp-build.ps1`. This location ensures:
- It runs from the repository root context
- The file is clearly identified as temporary (dot-prefix, descriptive name)
- It is listed in `.gitignore` so it cannot be accidentally committed

### Integration with Database Create

The scan script passes the build command via `--command` to `codeql database create`:

```powershell
& codeql database create ".codeql-db/$language" --overwrite --language=$language --source-root=. --command="pwsh -NoProfile -File .codeql-temp-build.ps1" ...
```

For multi-language scans (e.g., C# + C++), a compound build script is generated that runs all needed builds. CodeQL traces all compiler invocations across all languages in a single `--command` execution.

### Cleanup

The temporary build script is tracked via the `$tempCppBuild` variable and removed in the `finally` block (step 15) alongside other temporary files. Cleanup runs regardless of scan pass or fail.

## Limitations

- **Missing headers**: Loose `.c` files that `#include` headers not in the tree will produce compiler warnings/errors. CodeQL still extracts what was successfully parsed.
- **Complex build configurations**: Files that require specific preprocessor defines (`-DFOO=1`), include paths (`-I/path`), or link against libraries cannot be fully analyzed with the simple compile-only approach.
- **MSVC environment**: `cl.exe` requires the Visual Studio environment (`vcvarsall.bat`). If the user has `cl` on PATH but not the full VS environment, compilation may fail. Prefer `gcc` or `clang` when available.
- **Build failures**: If the generated build script fails for all files, C++ is removed from `$activeLanguages` and scanning continues for other languages.

## Interaction with Other Skills

- **codeql-build-prereqs**: The compiler must be available on PATH. If no compiler is found, the build tool detection warns and C++ is added to `$preBuildFailed`.
- **codeql-sdk-install**: Can install GCC or Clang if no compiler is detected and the user consents.
- **codeql-csharp-buildless**: Works alongside C# buildless scanning. In multi-language repos with both loose `.cs` and `.c` files, both temporary build artifacts are generated and composed into a single `--command`.
- **codeql-troubleshoot**: If the temporary build fails, the standard pre-build failure path runs and C++ is skipped with guidance.

## Agent Behavior

- The temporary build script generation is **automatic** -- no user intervention needed.
- The `[AUTO]` prefix in the output clearly indicates this was an auto-generated action.
- If a build system exists anywhere in the tree, the standard autobuild path is used instead -- buildless scanning is a fallback only.
- The skill does NOT create a permanent build system. If the user wants a real build, guide them to `cmake`, `make`, or their preferred build tool.
