---
name: codeql-prereq-cpp
description: "Ensure prerequisites for C/C++ CodeQL scanning. Detects compilers (gcc, clang, cl), validates build systems, and supports buildless scanning for loose .c/.cpp files. Use when C++ scan fails, when no compiler is found, when Makefile or CMake is missing, or when setting up C/C++ scanning."
argument-hint: "Describe the issue: no compiler, no Makefile, CMake error, loose .c files, autobuild failed, or C/C++ scan question"
user-invocable: true
disable-model-invocation: false
---

# C/C++ Prerequisites Skill

Ensure all prerequisites for CodeQL C/C++ scanning are met before the scan runs.

## Language Classification

**Compiled** -- CodeQL's C/C++ extractor intercepts compiler calls (`cl.exe`, `gcc`, `clang`) during the build. A compiler and either a build system or the buildless fallback are required.

## CodeQL Language ID

`cpp` -- covers C (`.c`, `.h`) and C++ (`.cpp`, `.hpp`, `.cc`, `.cxx`).

## Prerequisites

### Required

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| C/C++ compiler | Compile source files | `Get-Command gcc`, `Get-Command clang`, or `Get-Command cl` | Platform-specific |

### Required (one of)

| Item | Purpose | Detection |
|---|---|---|
| Makefile / GNUmakefile | GNU Make build system | `Test-Path Makefile` |
| CMakeLists.txt | CMake build system | `Test-Path CMakeLists.txt` |
| build.ninja | Ninja build system | `Test-Path build.ninja` |
| `.vcxproj` files | MSBuild / Visual Studio | `Get-ChildItem -Filter '*.vcxproj' -Depth 3` |
| Loose `.c`/`.cpp` files | Buildless fallback auto-generates temp build | `Get-ChildItem -Recurse -Depth 5` filtering by extension |

## Compiler Detection

The scan script checks for compilers in priority order:

```powershell
$hasCppCompiler = (Get-Command gcc -ErrorAction SilentlyContinue) -or
                  (Get-Command clang -ErrorAction SilentlyContinue) -or
                  (Get-Command cl -ErrorAction SilentlyContinue)
```

For buildless scanning, the compiler is selected in order: `gcc` > `clang` > `cl`.

### Platform-Specific Compilers

| Platform | Primary | Install |
|---|---|---|
| Windows | `cl` (MSVC) or `gcc` (MinGW/MSYS2) | Visual Studio Build Tools or MSYS2 |
| macOS | `clang` (Xcode CLT) or `gcc` (Homebrew) | `xcode-select --install` or `brew install gcc` |
| Linux | `gcc` or `clang` | `apt install build-essential` or `dnf groupinstall "Development Tools"` |

## Pre-Build Validation Flow

### Standard Path (with build system)

1. **Compiler detection**: Check for `gcc`, `clang`, or `cl` on PATH.
2. **Build system detection**: Check for Makefile, CMakeLists.txt, build.ninja, or `.vcxproj`.
3. **Both found**: Emit `[PASS] C/C++ build system and compiler detected`.
4. **Build system but no compiler**: Emit `[FAIL]` and skip C/C++.

### Buildless Path (no build system)

When no build system exists but source files and a compiler are found:

1. Detect all `.c`, `.cpp`, `.cc`, `.cxx` files (depth 5).
2. Select compiler: `gcc` > `clang` > `cl`.
3. Generate `.codeql-temp-build.ps1` that compiles each file individually with `-c` (compile-only).
4. Set `$tempCppBuild` to the temp script path.
5. Pass via `--command` to `codeql database create`.
6. Cleanup in `finally` block removes the temp file.

See **codeql-cpp-buildless** skill for full details on the buildless scanning flow.

## Auto-Install

When no C/C++ compiler is found during pre-build validation, scan.ps1 automatically attempts to locate or install one:

### Step 1: Find Existing Compilers Not on PATH

1. Check common MSYS2/MinGW paths (`C:\msys64\ucrt64\bin`, `C:\msys64\mingw64\bin`) for `gcc.exe`.
2. Use `vswhere.exe` to locate Visual Studio Build Tools `cl.exe` (Hostx64/x64).
3. If found, add the directory to the current session PATH and emit `[PASS]`.

### Step 2: Auto-Install via winget (Windows)

If no existing compiler is found and `winget` is available:

1. Install MSYS2: `winget install --id MSYS2.MSYS2 --silent`.
2. Install gcc via pacman: `pacman -S --noconfirm mingw-w64-ucrt-x86_64-gcc`.
3. Add `C:\msys64\ucrt64\bin` to PATH.

### Fallback

If auto-install fails or no compiler can be located, the existing `[FAIL]` messages guide the user:

```
[FAIL] No C/C++ compiler found (cl, gcc, clang) -- skipping C/C++ scan
  Install a compiler and retry.
```

Note: C/C++ compiler installation is more complex than other languages. Unlike .NET SDK, JDK, and Go, a fully automated install may require additional manual steps.

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| No compiler found | gcc/clang/cl not on PATH | Install a C/C++ compiler for your platform |
| Autobuild exit code 2 | No build system found | Buildless fallback generates temp build script |
| MSVC `cl` not found | VS Developer shell not active | Run from Developer Command Prompt or `vcvarsall.bat` |
| Header files not found | Missing include paths | Buildless mode uses `-c` and suppresses errors |
| Linker errors | Missing `main()` or libraries | Buildless mode uses `-c` (compile-only, no linking) |

## Interaction with Other Skills

- **codeql-cpp-buildless**: Handles the buildless scanning path for repos with loose C/C++ files.
- **codeql-build-prereqs**: Covers C/C++ at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Can install Visual Studio Build Tools, MinGW, or Xcode CLT.
