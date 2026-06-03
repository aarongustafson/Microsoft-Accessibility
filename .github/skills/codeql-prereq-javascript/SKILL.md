---
name: codeql-prereq-javascript
description: "Ensure prerequisites for JavaScript/TypeScript CodeQL scanning. Detects package managers, restores dependencies, and validates the environment. Use when JavaScript or TypeScript scan fails, when npm/yarn/pnpm install is needed, or when setting up JS/TS scanning for the first time."
argument-hint: "Describe the issue: npm install failed, TypeScript resolution errors, missing node_modules, or JS/TS scan question"
user-invocable: true
disable-model-invocation: false
---

# JavaScript/TypeScript Prerequisites Skill

Ensure all prerequisites for CodeQL JavaScript/TypeScript scanning are met before the scan runs.

## Language Classification

**Interpreted** -- CodeQL's JavaScript extractor parses source files directly without compiling. No build tool or runtime is strictly required for the scan to succeed. However, dependency restoration significantly improves analysis quality for TypeScript and module-heavy projects.

## CodeQL Language ID

`javascript` -- covers both JavaScript (`.js`, `.jsx`, `.mjs`, `.cjs`) and TypeScript (`.ts`, `.tsx`).

## Prerequisites

### Required

None. CodeQL's JavaScript extractor works directly on source files without a runtime.

### Recommended

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| Node.js | Run `npm install` / `yarn install` to populate `node_modules` | `Get-Command node` | https://nodejs.org |
| npm / yarn / pnpm | Restore dependencies for TypeScript type resolution | `Get-Command npm`, `Get-Command yarn`, `Get-Command pnpm` | Bundled with Node.js |

### Why Dependency Restoration Helps

- **TypeScript projects**: Without `node_modules`, the TypeScript compiler (and CodeQL's extractor) cannot resolve imported types from external packages. This reduces the precision of taint tracking and type-based queries.
- **Module aliases**: Projects using path aliases (e.g., `@app/...`) configured in `tsconfig.json` need resolved dependencies for accurate analysis.
- **Monorepos**: Workspace-based monorepos (npm workspaces, yarn workspaces) need a top-level install to link internal packages.

## Dependency Restoration Flow

The scan script performs dependency restoration in step 7c:

```powershell
'javascript' {
    $pkgJson = Test-Path 'package.json'
    if ($pkgJson) {
        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            Write-Host "Restoring JavaScript dependencies (pnpm)..." -ForegroundColor Cyan
            & pnpm install --frozen-lockfile 2>$null
            if ($LASTEXITCODE -ne 0) { & pnpm install 2>$null }
        } elseif ((Test-Path 'yarn.lock') -and (Get-Command yarn -ErrorAction SilentlyContinue)) {
            Write-Host "Restoring JavaScript dependencies (yarn)..." -ForegroundColor Cyan
            & yarn install --frozen-lockfile 2>$null
            if ($LASTEXITCODE -ne 0) { & yarn install 2>$null }
        } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Host "Restoring JavaScript dependencies (npm)..." -ForegroundColor Cyan
            & npm ci 2>$null
            if ($LASTEXITCODE -ne 0) { & npm install 2>$null }
        }
    }
}
```

Detection priority: pnpm > yarn (if yarn.lock exists) > npm. Each tries the lockfile-based install first (`--frozen-lockfile`, `npm ci`), then falls back to a regular install.

## Pre-Build Validation

JavaScript/TypeScript is an interpreted language -- no build validation is performed. The scan script emits a pass-through status:

```powershell
'javascript' {
    Write-Host "[PASS] JavaScript/TypeScript -- interpreted language, no build required" -ForegroundColor Green
}
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| TypeScript types not resolved | `node_modules` missing | Run `npm install` or `yarn install` before committing |
| `npm ci` fails | No `package-lock.json` | Falls back to `npm install` automatically |
| Large `node_modules` slows scan | Many dependencies | Normal -- CodeQL only scans source files, not `node_modules` |
| `.tsx` files not detected | Extension not in `$extMap` | `.tsx` IS mapped to `javascript` -- check file extensions |

## Interaction with Other Skills

- **codeql-build-prereqs**: Covers JavaScript at a high level. This skill provides the detailed per-language flow.
- **codeql-sdk-install**: Can install Node.js if needed, but Node.js is not required for CodeQL's JavaScript extractor.
- **codeql-scan-perf**: JavaScript scans are typically fast since no compilation is needed.
