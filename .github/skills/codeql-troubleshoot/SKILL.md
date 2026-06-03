---
name: codeql-troubleshoot
description: "Diagnose and fix CodeQL setup and scan failures. Use when CodeQL is not found, scan fails, hook not running, database creation fails, language not detected, PowerShell errors, encoding issues, lock file stuck, scan timeout, or any CodeQL problem."
argument-hint: "Describe the problem: error message, what failed, or what you expected to happen"
user-invocable: true
disable-model-invocation: false
---

# CodeQL Troubleshoot Skill

Diagnose and resolve common CodeQL setup, scan, and hook issues.

## When to Use

- User reports any **error** during CodeQL setup or scan
- User says scan is **failing**, **stuck**, or **slow**
- User says hook is **not running** on commit
- User says a **language is not detected**
- User sees **encoding** or **Unicode** errors in scripts
- User asks to **test** or **validate** the CodeQL setup
- User asks "why did my scan fail?"

## Diagnostic Flowchart

Start here and follow the branch that matches the symptom:

### "codeql: command not found"

1. Check if CodeQL is on PATH: `codeql version`
2. Check `.github/codeql/` directory exists with the CLI
3. Check PowerShell `$PROFILE` was updated with the PATH addition
4. **Fix:** Re-run the installer: `powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"`

### "Not a git repository"

1. The workspace must be a git repo: `git rev-parse --git-dir`
2. **Fix:** Run `git init` if the project isn't a git repo yet

### Hook Not Running on Commit

1. Check `core.hooksPath`: `git config --get core.hooksPath`
   - Expected: `.github/codeql/hooks`
2. Check the pre-commit hook exists: `Test-Path .github/codeql/hooks/pre-commit`
3. Check the PowerShell wrapper exists: `Test-Path .github/codeql/hooks/pre-commit.ps1`
4. **Fix:** Re-run the installer to recreate hooks

### Language Not Detected

1. Check what CodeQL supports: `codeql resolve languages`
2. Check the workspace has files with standard extensions
3. Check `codeql-config.yml` `paths-ignore` isn't excluding source directories
4. **Fix:** Ensure source files exist and aren't in ignored paths

### Database Creation Failed

**For compiled languages (C#, Java, C++, Go, Swift):**
1. Verify the build tool is installed and on PATH
2. Verify the project builds successfully outside CodeQL
3. Check for missing dependencies
4. If the SDK is missing, use the **codeql-sdk-install** skill (Prompt 36) to install it automatically

**Language-specific checks:**

| Language | Check | Fix |
|---|---|---|
| C# | `dotnet build` succeeds? | Install .NET SDK, restore packages |
| Java | `mvn compile` or `gradle build`? | Install JDK, check JAVA_HOME |
| C++ | `make` / `cmake` / `msbuild`? | Install build toolchain |
| Go | `go build ./...`? | Run `go mod download` |
| Swift | `xcodebuild` or `swift build`? | Install Xcode (macOS only) |

**For interpreted languages (JavaScript, Python, Ruby):** Database creation should not fail — CodeQL extracts source directly without building.

### Exit Code 32 (C# Specific)

See the **csharp-sdk-compat** skill for detailed diagnosis. Summary:
- Build succeeds but CodeQL extractor can't intercept compiler calls
- Usually caused by .NET SDK too new for CodeQL
- Auto-resolved by temporary `global.json` pinning when possible

### Scan Timeout

Parallel analysis jobs have a 30-minute timeout. If a language times out:
1. Check if the database is very large (many source files)
2. Try running that language sequentially: `-Parallel:$false`
3. Check available RAM — per-job share must be >= 2 GB

### Lock File Stuck

If you see "[FAIL] Another scan running":
1. Check for orphaned `.github/codeql/scan.lock` file
2. Verify no other scan process is running
3. **Fix:** Delete `.github/codeql/scan.lock` manually

### Encoding / Unicode Errors

If scripts show garbled characters (e.g. `a]` instead of arrows):
1. All `.ps1` files must be ASCII-only (bytes 0x00-0x7F)
2. **Fix:** Ask the agent to "Test my CodeQL setup" — validation detects and repairs encoding issues
3. Or re-run install.ps1 which validates all generated files

### PowerShell Execution Policy

If execution policy blocks scripts:
1. All scripts must be invoked with `-ExecutionPolicy Bypass -NoProfile`
2. Check the hook script uses this invocation pattern
3. **Fix:** Re-run: `powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"`

### PowerShell $PROFILE Null Error

If you see "Cannot bind argument to parameter 'Path' because it is null":
1. This happens in environments where `$PROFILE` is null (CI, constrained hosts)
2. The install script uses a fallback: `[Environment]::GetFolderPath('MyDocuments')`
3. **Fix:** Re-run the installer — v0.6+ handles this automatically

### SARIF File Missing or Empty

1. Check whether the scan completed (look for pass/fail verdict in terminal)
2. Check `.codeql-db/` directories exist (databases were created)
3. Run a manual scan with full output: `.github/codeql/scan.ps1 -Full`
4. **Fix:** If databases exist but SARIF doesn't, re-run: `.github/codeql/scan.ps1`

## Validation Checklist

When asked to "test setup" or "validate", check all of these:

1. **CodeQL CLI**: `codeql version` returns a version string
2. **Hook path**: `git config --get core.hooksPath` returns `.github/codeql/hooks`
3. **Pre-commit hook**: `.github/codeql/hooks/pre-commit` exists and is executable
4. **Scan script**: `.github/codeql/scan.ps1` exists and has valid PowerShell syntax
5. **Install script**: `.github/codeql/install.ps1` exists and has valid PowerShell syntax
6. **Config file**: `codeql-config.yml` exists and has valid YAML
7. **SARIF Viewer**: VS Code extension `MS-SarifVSCode.sarif-viewer` is installed
8. **Encoding**: All `.ps1` files contain only ASCII characters
9. **Languages**: `codeql resolve languages` shows expected languages

## Constraints

- See [Troubleshooting Guide](../../../docs/troubleshooting.md) for full documentation
- See [Getting Started](../../../docs/getting-started.md) for prerequisites
- The agent follows fail-closed: if tooling can't run, the commit is blocked
