---
name: codeql-prereq-go
description: "Ensure prerequisites for Go CodeQL scanning. Detects Go toolchain, restores modules, validates builds, and checks go.mod. Use when Go scan fails, when Go is missing, when module download fails, or when setting up Go scanning."
argument-hint: "Describe the issue: go not found, module download failed, build error, no go.mod, or Go scan question"
user-invocable: true
disable-model-invocation: false
---

# Go Prerequisites Skill

Ensure all prerequisites for CodeQL Go scanning are met before the scan runs.

## Language Classification

**Compiled** -- CodeQL's Go extractor intercepts the Go compiler during `go build`. The Go toolchain and successful module resolution are required.

## CodeQL Language ID

`go` -- covers `.go` files.

## Prerequisites

### Required

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| Go toolchain | Compile Go source and resolve modules | `Get-Command go` | https://go.dev/dl |

### Recommended

| Item | Purpose | Detection |
|---|---|---|
| `go.mod` | Module dependency management | `Test-Path go.mod` |
| `go.sum` | Dependency checksums | `Test-Path go.sum` |

## Dependency Restoration Flow

```powershell
'go' {
    if ((Get-Command go -ErrorAction SilentlyContinue) -and (Test-Path 'go.mod')) {
        Write-Host "Downloading Go modules..." -ForegroundColor Cyan
        & go mod download 2>$null
    }
}
```

Only runs if both the Go toolchain and `go.mod` are present. Standalone `.go` files without `go.mod` are handled by CodeQL's autobuild.

## Pre-Build Validation Flow

1. **Toolchain detection**: Check `go` on PATH. If missing, emit `[FAIL]` and skip Go.
2. **Module check**: If `go.mod` exists, run `go build ./...` for validation.
3. **Build fails**: Emit `[FAIL]` and skip Go with guidance.
4. **Build success**: Emit `[PASS] Go build validation OK`.
5. **No go.mod**: Skip validation -- CodeQL's autobuild handles standalone Go files.

```powershell
'go' {
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] Go toolchain not found -- skipping Go CodeQL scan" -ForegroundColor Red
        $preBuildFailed += $lang
    } elseif (Test-Path 'go.mod') {
        & go build ./... 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[FAIL] Go project does not build -- skipping Go CodeQL scan" -ForegroundColor Red
            $preBuildFailed += $lang
        } else {
            Write-Host "[PASS] Go build validation OK" -ForegroundColor Green
        }
    }
}
```

## Auto-Install

When the Go toolchain is not found during pre-build validation, scan.ps1 automatically attempts installation:

1. If `winget` is available (Windows): runs `winget install --id GoLang.Go --silent`.
2. Refreshes PATH from the system registry to detect the newly installed Go toolchain.
3. Verifies the installation with `go version`.

If auto-install succeeds (`[PASS]`), the scan continues with full Go validation. If it fails, the scan emits `[FAIL]` with the manual install URL and skips Go.

### Install Method (Windows)

```powershell
winget install --id GoLang.Go --accept-source-agreements --accept-package-agreements --silent
$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
```

### Fallback

If auto-install fails (no winget, restricted permissions, or network issues), the user sees:

```
[FAIL] Go toolchain not found -- skipping Go CodeQL scan
  Install Go: https://go.dev/dl
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| `go` not found | Go toolchain not installed | Install from https://go.dev/dl or `winget install GoLang.Go` |
| `go mod download` fails | Network issues or private modules | Configure `GOPROXY` or `GONOSUMCHECK` for private repos |
| `go build` fails | Missing dependencies or syntax errors | Run `go mod tidy` then `go build ./...` manually |
| No `go.mod` | Standalone Go files or GOPATH mode | CodeQL autobuild handles this; consider running `go mod init` |
| CGO dependencies | C libraries required for CGO | Install C compiler and required headers |

## Interaction with Other Skills

- **codeql-build-prereqs**: Covers Go at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Can install Go toolchain via winget or direct download.
- **codeql-scan-perf**: Go scans are typically fast. Module download time depends on dependency count.
