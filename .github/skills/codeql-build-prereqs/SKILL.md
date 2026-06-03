---
name: codeql-build-prereqs
description: "Detect build tools, restore dependencies, and validate builds for all CodeQL-supported languages. Use when a scan fails due to missing build tools, dependency restoration errors, compilation failures, unresolved packages, or when setting up a new language for CodeQL scanning."
argument-hint: "Describe the build issue: missing tool, restore failure, compilation error, or which language needs help"
user-invocable: true
disable-model-invocation: false
---

# Build Prerequisites Skill

Detect, restore, and validate build environments for all CodeQL-supported compiled languages. Interpreted languages (JavaScript, Python, Ruby) do not need build prerequisites -- CodeQL extracts directly from source.

## When to Use

- Scan fails with **database creation error** for a compiled language
- User sees **missing build tool** warnings during setup or scan
- User asks "why did my C#/Java/Go/C++/Swift scan fail?"
- User asks how to **set up build tools** for CodeQL
- **Dependency restoration** fails (NuGet, Maven, Gradle, Go modules, Swift packages, CocoaPods)
- **Pre-build validation** fails (project does not compile)
- User asks about **build requirements** for a specific language

## Language Reference

### Compiled Languages (Build Required)

CodeQL's extractors for compiled languages intercept compiler calls during the build. If the build fails or the build tool is missing, database creation fails.

| Language | CodeQL ID | Build Tool | Restore Command | Validation Command | Install URL |
|---|---|---|---|---|---|
| C# | `csharp` | `dotnet` | `dotnet restore` | `dotnet build --no-restore --verbosity quiet` | https://dot.net/download |
| Java/Kotlin | `java` | `javac` (JDK) | Maven: `mvn dependency:resolve -q`; Gradle: `./gradlew dependencies --quiet` | Maven: `mvn compile -q`; Gradle: `./gradlew compileJava --quiet` | https://adoptium.net |
| Go | `go` | `go` | `go mod download` (requires `go.mod`) | `go build ./...` | https://go.dev/dl |
| C/C++ | `cpp` | `cl`, `gcc`, or `clang` | Varies (CMake, vcpkg, Conan) | Varies (no universal command) | Platform-specific |
| Swift | `swift` | `xcodebuild` | `swift package resolve` or `pod install` | `swift build` or `xcodebuild` | macOS App Store (Xcode) |

### Interpreted Languages (No Build Required)

| Language | CodeQL ID | Notes |
|---|---|---|
| JavaScript/TypeScript | `javascript` | Extracted directly from source. No build, restore, or validation needed. |
| Python | `python` | Extracted directly from source. No build, restore, or validation needed. |
| Ruby | `ruby` | Extracted directly from source. No build, restore, or validation needed. |

## Build Tool Detection

Before dependency restoration, check that the required build tool exists on PATH. Missing tools produce `[FAIL]` messages during pre-build validation (Step 7c) and the language is removed from the scan. If an SDK is missing, the `codeql-sdk-install` skill (Prompt 36) can install it automatically with user consent.

### Detection Commands

```powershell
# C# -- .NET SDK
Get-Command dotnet -ErrorAction SilentlyContinue

# Java -- JDK (javac is the reliable indicator, not java)
Get-Command javac -ErrorAction SilentlyContinue

# Go -- Go toolchain
Get-Command go -ErrorAction SilentlyContinue

# C++ -- any one of: MSVC (cl), GCC (gcc), or Clang (clang)
(Get-Command cl -ErrorAction SilentlyContinue) -or
(Get-Command gcc -ErrorAction SilentlyContinue) -or
(Get-Command clang -ErrorAction SilentlyContinue)

# Swift -- Xcode (macOS only)
Get-Command xcodebuild -ErrorAction SilentlyContinue
```

### Platform Constraints

| Language | Windows | macOS | Linux |
|---|---|---|---|
| C# | .NET SDK | .NET SDK | .NET SDK |
| Java | JDK | JDK | JDK |
| Go | Go toolchain | Go toolchain | Go toolchain |
| C++ | Visual Studio / Build Tools | Xcode CLT or gcc/clang | gcc or clang |
| Swift | Not supported | Xcode required | Not supported by CodeQL |

## Dependency Restoration

Dependency restoration is **best-effort** -- failures are silenced (`2>$null`) because CodeQL's autobuild attempts its own restore/build sequence. The explicit pre-restore ensures packages are available on machines where the project has never been built (fresh clone).

### C# (.NET)

1. Look for `.sln` at repo root first (covers multi-project solutions).
2. Fall back to individual `.csproj` files (search to depth 3).
3. Run `dotnet restore <target> --verbosity quiet`.

**Common failure:** Missing NuGet package references cause CS1069 errors during build validation. See the **codeql-csharp-sdk-compat** skill for deprecated package mapping and SDK version conflicts.

### Java

1. **Maven** (if `pom.xml` exists): `mvn dependency:resolve -q`
2. **Gradle** (if `build.gradle` or `build.gradle.kts` exists):
   - Prefer wrapper: `./gradlew.bat` (Windows) or `./gradlew` (Unix)
   - Fall back to system `gradle` if no wrapper present
   - Command: `<gradle> dependencies --quiet`

**Common failure:** JAVA_HOME not set or pointing to JRE instead of JDK. Fix: set `JAVA_HOME` to the JDK installation directory.

### Go

1. Requires `go.mod` in the repo root.
2. Run `go mod download`.

**Common failure:** Private modules require `GONOSUMCHECK` and `GOPRIVATE` environment variables. The user must configure Go authentication for private registries before CodeQL can resolve dependencies.

### Swift

1. **Swift Package Manager** (if `Package.swift` exists): `swift package resolve`
2. **CocoaPods** (if `Podfile` exists): `pod install`
3. Both can be present -- run both if detected.

**Common failure:** Swift scanning requires macOS. On other platforms, skip Swift with a clear warning.

### C/C++

No universal restore command. Build systems vary widely:
- **CMake:** `cmake -B build && cmake --build build`
- **MSBuild:** `msbuild /t:Restore`
- **vcpkg:** `vcpkg install` (if vcpkg.json manifest)
- **Conan:** `conan install .`

CodeQL's autobuild tries multiple strategies for C/C++. If autobuild fails, the user must provide a build command.

## Pre-Build Validation

After dependency restoration, run a trial build for compiled languages. This catches build errors in seconds instead of waiting 1+ minutes for CodeQL's multi-strategy autobuild to exhaust all fallbacks.

### Validation Flow

```
For each language in $activeLanguages:
  1. Check build tool exists --> [FAIL] if missing, skip language
  2. Run restore command    --> best-effort, continue on failure
  3. Run validation build   --> [FAIL] removes language from scan
  4. Report [PASS] or [FAIL] with actionable guidance
```

Languages that fail pre-build validation are removed from `$activeLanguages` so CodeQL does not waste time attempting database creation for them.

### C# Validation Details

The C# validation path has the most complex logic due to SDK compatibility and deprecated package handling:

1. Find `.sln` or `.csproj` -- if neither found, skip C# with guidance.
2. Run `dotnet build <target> --no-restore --verbosity quiet`.
3. On failure, parse build output for:
   - **CS1069 errors** (missing type forwarded assemblies): Extract assembly names, map deprecated packages to replacements using `$deprecatedMap`, suggest `dotnet add package <replacement>`.
   - **NETSDK1045** (SDK version mismatch): Delegate to SDK compatibility auto-resolution.
   - **Other errors**: Print generic "fix build errors" guidance.
4. On success, check SDK version for CodeQL extractor compatibility (see codeql-csharp-sdk-compat skill).

### Java Validation Details

1. Detect build system: Maven (`pom.xml`) or Gradle (`build.gradle`/`build.gradle.kts`).
2. Run compile phase only (not full test): `mvn compile -q` or `<gradle> compileJava --quiet`.
3. On failure, suggest fixing build errors before retrying.

### Go Validation Details

1. Requires both `go` command AND `go.mod` file.
2. Run `go build ./...` to compile all packages.
3. On failure, suggest fixing build errors before retrying.

## Troubleshooting Common Build Failures

| Symptom | Language | Likely Cause | Fix |
|---|---|---|---|
| "dotnet: command not found" | C# | .NET SDK not installed | Install from https://dot.net/download or use `codeql-sdk-install` skill |
| CS1069 errors | C# | Missing NuGet package references | `dotnet add package <PackageName>` (check deprecated map) |
| NETSDK1045 | C# | SDK version mismatch with TargetFramework | See codeql-csharp-sdk-compat skill |
| Exit code 32 | C# | SDK too new for CodeQL extractor | See codeql-csharp-sdk-compat skill |
| "javac: command not found" | Java | JDK not installed (only JRE present) | Install JDK from https://adoptium.net or use `codeql-sdk-install` skill |
| "package does not exist" | Java | Dependencies not resolved | Run `mvn dependency:resolve` or `gradle dependencies` |
| "go: command not found" | Go | Go toolchain not installed | Install from https://go.dev/dl or use `codeql-sdk-install` skill |
| "go.mod: no such file" | Go | No Go module defined | Run `go mod init <module>` |
| "xcodebuild: not found" | Swift | Xcode not installed, or not macOS | Install Xcode; Swift requires macOS |
| "no compiler found" | C++ | No C/C++ compiler on PATH | Install Visual Studio Build Tools, gcc, or clang |
| Autobuild timeout | Any compiled | Build takes > 10 minutes | Pre-build manually, or provide explicit build command |

## Cross-References

- **codeql-csharp-sdk-compat** -- For .NET SDK version conflicts, exit code 32, NETSDK1045, and deprecated package mapping
- **codeql-troubleshoot** -- For general scan failures, hook issues, and encoding problems
- **Agent spec Step 7c** -- Pre-build dependency restoration and validation (source of truth)
- **Agent spec Phase 0** -- Pre-flight build tool survey
