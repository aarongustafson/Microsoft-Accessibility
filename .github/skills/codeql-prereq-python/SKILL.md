---
name: codeql-prereq-python
description: "Ensure prerequisites for Python CodeQL scanning. Detects Python runtime, restores pip dependencies, and validates the environment. Use when Python scan fails, when pip install is needed, or when setting up Python scanning for the first time."
argument-hint: "Describe the issue: pip install failed, missing modules, virtual environment, or Python scan question"
user-invocable: true
disable-model-invocation: false
---

# Python Prerequisites Skill

Ensure all prerequisites for CodeQL Python scanning are met before the scan runs.

## Language Classification

**Interpreted** -- CodeQL's Python extractor parses source files directly without compiling or executing. No Python runtime is strictly required for the scan to succeed. However, dependency restoration can improve analysis quality for projects with complex import graphs.

## CodeQL Language ID

`python` -- covers `.py` and `.pyw` files.

## Prerequisites

### Required

None. CodeQL's Python extractor works directly on source files without a runtime.

### Recommended

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| Python 3 | Run `pip install` to resolve dependencies | `Get-Command python3` or `Get-Command python` | https://python.org |
| pip | Install packages from requirements files | `Get-Command pip3` or `Get-Command pip` | Bundled with Python 3.4+ |

### Why Dependency Restoration Helps

- **Import resolution**: Without installed packages, CodeQL cannot trace data flow through third-party libraries. This reduces the precision of taint tracking for vulnerabilities like SQL injection via ORM calls.
- **Type stubs**: Some packages include type stubs (`.pyi` files) that help CodeQL understand API contracts.
- **Dynamic imports**: Projects using `importlib` or plugin patterns benefit from having the full dependency tree available.

## Dependency Restoration Flow

The scan script performs dependency restoration in step 7c:

```powershell
'python' {
    $pipCmd = if (Get-Command pip3 -ErrorAction SilentlyContinue) { 'pip3' }
              elseif (Get-Command pip -ErrorAction SilentlyContinue) { 'pip' }
              else { $null }
    if ($pipCmd) {
        if (Test-Path 'requirements.txt') {
            Write-Host "Restoring Python dependencies (requirements.txt)..." -ForegroundColor Cyan
            & $pipCmd install -r requirements.txt --quiet 2>$null
        } elseif (Test-Path 'setup.py') {
            Write-Host "Restoring Python dependencies (setup.py)..." -ForegroundColor Cyan
            & $pipCmd install -e . --quiet 2>$null
        } elseif (Test-Path 'pyproject.toml') {
            Write-Host "Restoring Python dependencies (pyproject.toml)..." -ForegroundColor Cyan
            & $pipCmd install -e . --quiet 2>$null
        }
    }
}
```

Detection priority: `pip3` > `pip`. Checks for `requirements.txt` first, then `setup.py`, then `pyproject.toml`.

## Pre-Build Validation

Python is an interpreted language -- no build validation is performed. The scan script emits a pass-through status:

```powershell
'python' {
    Write-Host "[PASS] Python -- interpreted language, no build required" -ForegroundColor Green
}
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| Missing module warnings | Dependencies not installed | Run `pip install -r requirements.txt` before committing |
| Virtual environment not active | pip installs to wrong location | Activate venv first, or CodeQL still extracts source directly |
| Python 2 code detected | CodeQL supports Python 2 and 3 | No action needed -- extractor handles both |
| `pyproject.toml` not detected | Newer packaging format | Scan script checks `pyproject.toml` as a fallback |

## Interaction with Other Skills

- **codeql-build-prereqs**: Covers Python at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Can install Python if needed, but Python is not required for CodeQL's Python extractor.
- **codeql-scan-perf**: Python scans are typically fast since no compilation is needed.
