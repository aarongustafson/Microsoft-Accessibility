---
name: codeql-prereq-java
description: "Ensure prerequisites for Java/Kotlin CodeQL scanning. Detects JDK, validates Maven/Gradle builds, restores dependencies, and checks JAVA_HOME. Use when Java scan fails, when JDK is missing, when Maven or Gradle build errors occur, or when setting up Java scanning."
argument-hint: "Describe the issue: JDK not found, Maven build failed, Gradle error, JAVA_HOME not set, or Java scan question"
user-invocable: true
disable-model-invocation: false
---

# Java/Kotlin Prerequisites Skill

Ensure all prerequisites for CodeQL Java/Kotlin scanning are met before the scan runs.

## Language Classification

**Compiled** -- CodeQL's Java extractor intercepts `javac` calls during the build. A JDK and a successful build are required for database creation.

## CodeQL Language ID

`java` -- covers Java (`.java`) and Kotlin (`.kt`, `.kts`).

## Prerequisites

### Required

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| JDK (javac) | Compile Java/Kotlin source | `Get-Command javac` | https://adoptium.net |

### Required (one of)

| Tool | Purpose | Detection |
|---|---|---|
| Maven (mvn) | Build Maven projects | `Get-Command mvn` + `Test-Path pom.xml` |
| Gradle | Build Gradle projects | `Test-Path build.gradle` or `Test-Path build.gradle.kts` |

### Recommended

| Tool | Purpose |
|---|---|
| JAVA_HOME | Set to JDK (not JRE) installation directory. Many build tools require this. |

## Dependency Restoration Flow

The scan script performs dependency restoration in step 7c:

```powershell
'java' {
    if (Test-Path 'pom.xml') {
        Write-Host "Resolving Maven dependencies..." -ForegroundColor Cyan
        & mvn dependency:resolve -q 2>$null
    } elseif ((Test-Path 'build.gradle') -or (Test-Path 'build.gradle.kts')) {
        $gradleCmd = if (Test-Path './gradlew.bat') { '.\gradlew.bat' }
                     elseif (Test-Path './gradlew') { './gradlew' }
                     else { 'gradle' }
        Write-Host "Resolving Gradle dependencies..." -ForegroundColor Cyan
        & $gradleCmd dependencies --quiet 2>$null
    }
}
```

Gradle wrapper (`gradlew.bat` / `gradlew`) is preferred over system Gradle.

## Pre-Build Validation Flow

```powershell
'java' {
    if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] JDK not found -- skipping Java CodeQL scan" -ForegroundColor Red
        $preBuildFailed += $lang
    } else {
        # Validate build if build system exists
        if (Test-Path 'pom.xml') {
            & mvn compile -q 2>$null
            # Check $LASTEXITCODE...
        } elseif (build.gradle exists) {
            & $gradleCmd compileJava --quiet 2>$null
            # Check $LASTEXITCODE...
        }
    }
}
```

### Validation Steps

1. **JDK detection**: Check `javac` on PATH. If missing, emit `[FAIL]` and skip Java.
2. **Build system detection**: Check for `pom.xml` (Maven) or `build.gradle`/`build.gradle.kts` (Gradle).
3. **Build validation**: Run `mvn compile -q` or `gradle compileJava --quiet`. If build fails, emit `[FAIL]` and skip Java.
4. **Build success**: Emit `[PASS] Java build validation OK`.

## Auto-Install

When the JDK is not found during pre-build validation, scan.ps1 automatically attempts installation:

1. If `winget` is available (Windows): runs `winget install --id EclipseAdoptium.Temurin.21.JDK --silent`.
2. Refreshes PATH from the system registry to detect the newly installed JDK.
3. Verifies the installation with `javac -version`.

If auto-install succeeds (`[PASS]`), the scan continues with full Java validation. If it fails, the scan emits `[FAIL]` with the manual install URL and skips Java.

### Install Method (Windows)

```powershell
winget install --id EclipseAdoptium.Temurin.21.JDK --accept-source-agreements --accept-package-agreements --silent
$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
```

### Fallback

If auto-install fails (no winget, restricted permissions, or network issues), the user sees:

```
[FAIL] JDK not found -- skipping Java CodeQL scan
  Install a JDK: https://adoptium.net
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| `javac` not found | JDK not installed or not on PATH | Install JDK: `winget install EclipseAdoptium.Temurin.21.JDK` |
| `JAVA_HOME` not set | Environment variable missing | Set to JDK installation directory (not JRE) |
| `JAVA_HOME` points to JRE | Common misconfiguration | Update to point to JDK directory containing `bin/javac` |
| Maven build fails | Missing dependencies or plugins | Run `mvn dependency:resolve` manually, check `pom.xml` |
| Gradle wrapper not executable | Permissions on `gradlew` | Run `chmod +x gradlew` (Unix) or use system Gradle |
| Multi-module build fails | Sub-module dependency order | Ensure parent POM is built first: `mvn install -pl parent` |
| Kotlin files not detected | Wrong extension mapping | `.kt` and `.kts` are mapped to `java` in `$extMap` |

## Interaction with Other Skills

- **codeql-build-prereqs**: Covers Java at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Can install JDK 21 via winget or direct download. Always asks for consent first.
- **codeql-scan-perf**: Java builds can be slow for large projects. Consider `--threads=0` for parallel extraction.
