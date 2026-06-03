# VibeShield Installer Architecture

This document describes the shared patterns, conventions, and structural differences across all VibeShield skill installer scripts under `skills/`.

## Overview

Each skill ships a self-contained installer surface:

| Skill | Source Strategy | Auth | Helper Count |
|-------|----------------|------|-------------|
| vibeshield-bicep | Local assets | None | 9 scripts |
| vibeshield-powershell | Local assets | None | 7 scripts |
| vibeshield-safe-libraries | Local assets | None | 5+ scripts (includes `helpers/`) |
| vibeshield-codeql | Sparse-clone from Azure Repos | OAuth (az CLI) | 0 |
| vibeshield-deploy | Sparse-clone from Azure Repos | OAuth (az CLI) | 0 |
| vibeshield-ev2 | Sparse-clone from GitHub | GitHub CLI | 0 |

Skills fall into two architectural families:

- **Local-asset skills** (bicep, powershell, safe-libraries) — copy files from a bundled `assets/` directory; never touch the network during install.
- **Remote-clone skills** (codeql, deploy, ev2) — sparse-clone from an external repository with authenticated Git; minimal local scripts.

---

## Shared Infrastructure

### Vibeshield.CapabilityContract.psm1

**Identical in all six skills.** Exports a single function, `Set-VibeShieldCapabilityResult`, that writes a structured JSON result file consumed by the installer framework.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `Status` | Yes | `ok`, `partial`, or `fail` |
| `Message` | No | Human-readable summary (truncated to 512 chars) |
| `Details` | No | Free-form hashtable forwarded to telemetry |
| `SubSteps` | No | Array of substep objects (`name`, `status`, `message`) |

**Required environment variables** (set by the installer framework before invoking the script):

| Variable | Purpose |
|----------|---------|
| `VIBESHIELD_RESULT_PATH` | Destination file path for the JSON result |
| `VIBESHIELD_HANDSHAKE_VERSION` | Schema version (currently `1`) |
| `VIBESHIELD_CAPABILITY_NAME` | Capability name in `<source>/<capability>` form |

Output is UTF-8 without BOM. Parent directories are created if needed.

### Install-VibeShield.ps1

**Present in every skill.** This is the main entry point. Common boilerplate:

```powershell
[CmdletBinding()]
param(
    [string]$ProjectPath    # Optional for local-asset skills; required for some remote-clone skills
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

Every `Install-VibeShield.ps1`:
1. Imports `Vibeshield.CapabilityContract.psm1` via `Import-Module`.
2. Resolves the target project root (from `-ProjectPath`, `Resolve-RepoRoot`, or cwd).
3. Orchestrates sub-installers or performs its own work.
4. Calls `Set-VibeShieldCapabilityResult` with final status.
5. Wraps the main body in `try/catch`; the catch block reports `fail` and re-throws.

### Capability Contract Implementation by Skill

Five of six skills implement the contract. The table below compares how each skill uses it.

| Aspect | bicep | powershell | deploy | ev2 | safe-libraries | codeql |
|--------|-------|------------|--------|-----|----------------|--------|
| **Imports module** | Yes | Yes | Yes | Yes | Yes | Yes |
| **Double-write guard** | `$resultWritten` | `$capabilityResultWritten` | No (mutually exclusive paths) | No (mutually exclusive paths) | `$capabilityResultWritten` | No (mutually exclusive paths) |
| **Inline fail calls** | 4 | 2 | 0 | 0 | 3 | 0 |
| **Catch-block fail** | `UNHANDLED_EXCEPTION` | `INSTALL_FAILED` + `$phase` | Classified via `Get-DeployFailureInfo` | Classified via `Convert-VibeShieldEv2ErrorToMessage` | `UNCAUGHT_EXCEPTION` + `$phase` | Classified via `Convert-VibeShieldCodeQLErrorToMessage` |
| **Success details** | `created`, `overwritten`, `skipped` | `created`, `overwritten`, `skipped` | `copiedFileCount`, `protectedFileCount`, `manifestGenerated` | `branch`, `copiedCount`, `platform` | `installedCount` | `branch`, `target` |
| **Uses `partial` status** | No | No | No | No | No | No |
| **Phase tracking** | No (uses error codes) | Yes | Yes | Yes | Yes | Yes |
| **Error classification** | Inline codes (`ASSETS_MISSING`, `SCRIPT_MISSING`) | Inline codes (`ASSET_MISSING`, `PREREQ_MISSING`) | Dedicated function with category taxonomy | Dedicated function mapping error prefixes | Inline codes (`ASSETS_MISSING`, `LOAD_HELPERS_FAILED`, `LIBRARY_INSTALL_FAILED`) | Dedicated function mapping error text |

#### Error Handling Patterns

**Inline error codes** (bicep, powershell, safe-libraries): Each failure point calls `Set-VibeShieldCapabilityResult -Status fail` with a specific code string (`ASSETS_MISSING`, `SCRIPT_MISSING`, etc.) before throwing. A boolean guard (`$resultWritten` / `$capabilityResultWritten`) prevents the catch block from writing a second result.

**Error classifier functions** (deploy, ev2): The catch block passes the raw `ErrorRecord` to a dedicated function that maps exception messages to a fixed taxonomy of safe error codes and categories. This keeps the main flow clean and centralizes error classification.

- **deploy** uses `Get-DeployFailureInfo` which returns a hashtable with `Message` and `Details` (including a `category` field: `input`, `prerequisite`, `auth`, `source-fetch`, `source-checkout`, `source-layout`).
- **ev2** uses `Convert-VibeShieldEv2ErrorToMessage` which maps error prefixes (e.g., `TARGET_PATH_MISSING:`, `PREREQ_GIT_MISSING:`) to human-readable messages.
- **codeql** uses `Convert-VibeShieldCodeQLErrorToMessage` which maps error text patterns (e.g., `git clone failed`, `Commit SHA mismatch`) to contract-safe codes (e.g., `GIT_CLONE_FAILED:`, `COMMIT_SHA_MISMATCH:`).

#### PII Safety

All skills avoid leaking PII (user paths, tokens) into the capability result:
- **bicep** reports only `exceptionType` (the .NET type name) in the catch block.
- **deploy** and **ev2** report `phase` and `category` only.
- **codeql** reports `phase` and a classified error code (no raw exception text forwarded).
- **safe-libraries** has an explicit PII-safety comment in its helper-load catch, noting that PowerShell dot-source errors include absolute paths which must not be forwarded to telemetry.
- **powershell** reports `phase` only.

#### Notable Gaps

- **No skill uses `partial` status**, even though the contract supports it. safe-libraries would be the natural candidate (some ecosystems can succeed while others fail), but it reports `fail` if any library installer fails.

---

## Common Helper Scripts (Local-Asset Skills)

### Resolve-RepoRoot.ps1

Present in bicep, powershell, and safe-libraries. Walks up from the current directory to find a `.git` root. Falls back to cwd if no repository is found. Results are normalized with `[System.IO.Path]::GetFullPath()`.

### Install-SkillRuntime.ps1

Copies `SKILL.md` and runtime scripts into `.github/skills/<skillname>/` in the target project.

- Uses a `Copy-SkillFile` helper that tracks file disposition (created vs. overwritten).
- Reports `$createdCount` and `$overwrittenCount` in the capability result.
- Exits `1` if `SKILL.md` is not found in the source directory.

### Install-VibeShieldFragment.ps1

Performs idempotent, marker-based injection into Markdown files (e.g., `AGENTS.md`, `copilot-instructions.md`).

**Marker format:**
```markdown
<!-- BEGIN:markerName -->
...injected content...
<!-- END:markerName -->
```

**Injection logic:**

1. Target already has `BEGIN:markerName` → replace the entire block (**update**).
2. Target has `END:sectionMarker` → insert before the closing section marker (**first injection**).
3. Target file does not exist → create it with section and fragment (**create**).
4. Target exists but has no insertion point → append at end.

Returns a single word to stdout (`CREATED`, `UPDATED`, or `SKIPPED`) for the caller to capture.

### Install-AutoApproveSettings.ps1

Present in bicep and powershell. Adds regex auto-approve entries to `.vscode/settings.json` so that hook and validation scripts can run without interactive confirmation.

Uses raw string manipulation rather than JSON cmdlets to avoid escaping issues with regex keys.

### Install-VsCodeExtensions.ps1

Present in bicep and powershell. Adds extension recommendations to `.vscode/extensions.json` and attempts best-effort installation via `code --install-extension` (failures produce warnings, never terminating errors).

### Install-SpecKitIntegration.ps1

Present in bicep and powershell. Patches spec-kit agent files in two layers:

1. **Agent file patching** — injects `agents:` entries into YAML frontmatter and appends delegation marker blocks to the body.
2. **Extensions.yml hooks** (bicep only) — installs `.specify/extensions.yml` with lifecycle hooks.

### Install-McpConfig.ps1

**Bicep only.** Manages `.mcp.json` for Copilot CLI MCP servers. Creates from an asset template if missing, or additively merges if the file exists. Installs required .NET global tools (`Azure.Bicep.McpServer`, `azure.mcp`).

---

## Safe-Libraries-Specific Helpers

The safe-libraries skill has a `helpers/` subdirectory with feed-specific installers:

| Script | Purpose |
|--------|---------|
| `Install-NuGetFeedConfig.ps1` | Validates/replaces `nuget.config` for CFS feed compliance; installs Azure Artifacts Credential Provider |
| `Install-PipFeedConfig.ps1` | Validates `pip.ini` for single `index-url`, no `extra-index-url`; creates `.venv/` and installs `artifacts-keyring` |
| `Install-NpmFeedConfig.ps1` | Validates `.npmrc` for single `registry=` line matching internal ADO feed; installs `vsts-npm-auth` |
| `Test-FeedConnectivity.ps1` | Advisory connectivity check (warnings only, never fails the install) |
| `Install-OrgList.ps1` | Supplies `Get-ValidCfsOrganization` function used by feed validators |

---

## Remote-Clone Skills

### Authentication Patterns

Remote-clone skills authenticate against two different Git hosts, each requiring a different token type:

| Skill | Source Host | Auth Provider | Token Format |
|-------|------------|---------------|-------------|
| codeql | Azure DevOps | `az account get-access-token` (Entra OAuth) | Bearer |
| deploy | Azure DevOps | `az account get-access-token` (Entra OAuth) | Bearer |
| ev2 | GitHub | `gh auth token` (GitHub CLI) | Basic (`x-access-token:<token>`, base64-encoded) |

The token format is dictated by the hosting platform — Azure DevOps expects a Bearer header, GitHub's Git HTTP protocol uses Basic auth.

All three skills auto-trigger interactive login if the user is not authenticated (`az login` for ADO, `gh auth login --web` for GitHub). ev2 can also fall back to unauthenticated cloning if GitHub CLI is unavailable (the source repo is public).

### Token Injection

How the token is passed to Git varies — and this is a design choice with security implications:

How the token is passed to Git varies across the three skills:

**codeql** and **ev2** use **per-command `-c` flag injection**, passing `-c http.extraheader=Authorization: ...` as arguments to each individual git invocation. This is the preferred pattern for three reasons:

1. **No credential leakage to child processes.** Process-wide env vars are inherited by every child process. Per-command flags exist only for the duration of the single git call.
2. **No cleanup liability.** Per-command flags require no cleanup — no `finally` block needed for credential removal.
3. **No race conditions.** Concurrent installer instances sharing a process cannot collide. Per-command flags are isolated by construction.

**deploy** uses a **hybrid approach**: `Invoke-GitCommand` defines a `-AdoToken` parameter with per-command `-c` flag support, but the main function **does not use it**. Instead, auth is injected via process-wide `GIT_CONFIG_*` env vars (`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`, `GIT_CONFIG_VALUE_0`) set after token acquisition. These are cleaned up in `Clear-DeployEnvironment` in the `finally` block alongside `GIT_TERMINAL_PROMPT` and `GCM_INTERACTIVE`. This creates a cleanup liability and credential leakage window that the per-command pattern avoids.

**codeql's `Invoke-GitCommand`** passes both credential helper disablement (`-c credential.helper=`) and auth per-command via `-AdoToken`. **ev2's `Invoke-Git`** does the same for auth. Both codeql and ev2 temporarily set `GIT_TERMINAL_PROMPT` and `GCM_INTERACTIVE` at process scope with save/restore in a `try/finally` for prompt suppression, which is slightly less isolated than a pure per-command approach.

### Workflow

Remote-clone installers are structurally simple: authenticate → sparse-clone (or full clone with `--depth=1`) → report capability result. They have no sub-installer cascade.

---

## Shared Coding Conventions

| Convention | Detail |
|------------|--------|
| Strict mode | `Set-StrictMode -Version Latest` in every script |
| Error preference | `$ErrorActionPreference = 'Stop'` |
| No `Write-Output` | All user-facing messages use `Write-Host`; only structured tokens go to stdout |
| Substep tracking | Accumulate a `$subSteps` array; pass to `Set-VibeShieldCapabilityResult -SubSteps` |
| File counters | Track `$createdCount`, `$overwrittenCount`, `$skippedCount` for reporting |
| Idempotent writes | Fragment injection checks for existing markers; instructions files are skipped if present |
| Absolute paths | Normalized via `[System.IO.Path]::GetFullPath()` |
| UTF-8 without BOM | Capability contract and fragment scripts write UTF-8 explicitly |

---

## External Dependencies (Remote-Clone Skills)

The three remote-clone skills depend on external tools, runtimes, and .NET APIs. This section catalogues everything required to run them.

### Required Tools

| Tool | codeql | deploy | ev2 | Purpose |
|------|--------|--------|-----|---------|
| **git** | 2.25+ ✅ | 2.25+ ✅ | 2.25+ ✅ | Sparse clone from source repo |
| **az** (Azure CLI) | Required | Required | — | Entra OAuth token for Azure DevOps repos |
| **gh** (GitHub CLI) | — | — | Optional | GitHub auth; falls back to unauthenticated clone |
| **unzip** | Linux/WSL/macOS | — | — | Extract CodeQL bundle archive |
| **ev2** (Ev2 client) | — | — | Required | ExpressV2 deployment operations |
| **pwsh** | 7.0 (`#Requires` + runtime check) ✅ | 7.0 (`#Requires` + runtime check) ✅ | 7.0 (`#Requires` + runtime check) ✅ | Script execution runtime |

- **git version:** All three scripts now consistently check for git 2.25+ (required for `sparse-checkout`). Previously codeql checked 2.9+ with a wrong reason (`core.hooksPath`) and deploy had no check at all — both fixed.
- **unzip** is required by codeql on non-Windows platforms (Linux, WSL, macOS) to extract the CodeQL bundle. On Windows, `Expand-Archive` is used instead.
- **ev2 degrades gracefully** when `gh` is absent — the source repo is public GitHub, so unauthenticated cloning works (subject to rate limits).
- **codeql and deploy fail hard** if `az` is missing or the user cannot authenticate.
- **PowerShell version:** All three scripts now consistently declare `#Requires -Version 7.0` and include a runtime check with a user-friendly error message. Previously codeql had neither directive, and deploy had `#Requires` but no runtime check — both fixed to match ev2's reference pattern.

### Dependency Detection and Validation

The three installers use structurally different approaches to detect and validate external tools:

| Aspect | codeql | deploy | ev2 |
|--------|--------|--------|-----|
| **Detection scope** | Script scope (runs at dot-source time) | Dedicated `Test-DeployPrerequisite` function | Decomposed into four single-purpose functions |
| **Binary check** | `Get-Command git/az` at script scope — executes before any function call | `Get-Command git/az` inside `Test-DeployPrerequisite` | `Resolve-GitExecutable`, `Test-GitHubCliAvailable` |
| **Version check** | `& $script:GitBin --version` + `$PSVersionTable.PSVersion` inline in `Invoke-InstallVibeShieldCodeQL` | `& $script:GitBin --version` + `$PSVersionTable.PSVersion` inside `Test-DeployPrerequisite` | `Invoke-GitVersion` + `Get-PowerShellRuntimeVersion` |
| **Mockability** | **Partial** — binary existence checks are not mockable (script scope); version checks inside the function are mockable | **Full** — mock `Test-DeployPrerequisite` to simulate any prereq scenario | **Full** — each function is independently mockable with parameter injection |

**Error codes** are consistent across all three for the same failure modes:

| Failure | codeql | deploy | ev2 |
|---------|--------|--------|-----|
| Binary missing | `PREREQ_MISSING:` (via classifier) | `PREREQ_MISSING: git\|az` (direct throw) | `PREREQ_GIT_MISSING:` (direct throw) |
| Git version < 2.25 | `PREREQ_GIT_VERSION_TOO_OLD:` | `PREREQ_GIT_VERSION_TOO_OLD:` | `PREREQ_GIT_VERSION_TOO_OLD:` |
| PowerShell < 7.0 | `PREREQ_POWERSHELL_VERSION_TOO_OLD:` | `PREREQ_POWERSHELL_VERSION_TOO_OLD:` | `PREREQ_POWERSHELL_VERSION_TOO_OLD:` |

**Classifier gap (deploy):** `Get-DeployFailureInfo` only matches `^PREREQ_MISSING: (git|az)$`. The two version error codes (`PREREQ_GIT_VERSION_TOO_OLD`, `PREREQ_POWERSHELL_VERSION_TOO_OLD`) fall through to `UNEXPECTED_FAILURE`. The codeql and ev2 classifiers handle all three codes correctly.

**Graceful degradation (ev2 only):** When `gh` is absent, ev2 falls back to unauthenticated cloning (the source repo is public). When a browser opener is unavailable, it prints the device-code URL to the terminal. No other skill degrades — codeql and deploy fail hard if `az` is missing or authentication fails.

### Optional Tools (ev2 only)

ev2 opens a browser for GitHub device-flow login. It probes for platform-specific openers:

| Tool | Platform | Fallback |
|------|----------|----------|
| `Start-Process` | Windows | — |
| `open` | macOS | — |
| `xdg-open` | Linux desktop | Warning: "Navigate to URL manually" |
| `wslview` | WSL | `cmd.exe /c start` |

No other skill opens a browser or invokes platform-specific helpers.

### PowerShell Module Dependencies

All three import `Vibeshield.CapabilityContract.psm1` from `$PSScriptRoot`. No external PowerShell Gallery modules are required.

### .NET Framework APIs

All three scripts run on .NET (via PowerShell 7) and use framework APIs directly:

| API | codeql | deploy | ev2 | Purpose |
|-----|--------|--------|-----|---------|
| `System.Environment.OSVersion.Platform` | Yes | — | — | Windows detection |
| `System.Runtime.InteropServices.RuntimeInformation` | Yes | — | Yes | macOS / WSL detection |
| `System.IO.Path` (GetRelativePath, GetTempPath) | Yes | Yes | Yes | Path normalization, temp dirs |
| `System.Guid.NewGuid()` | — | Yes | Yes | Unique temp directory names |
| `System.Security.Cryptography.SHA256` | — | Yes | — | Integrity manifest super-hash |
| `System.Text.Encoding` | — | Yes | Yes | Base64 token encoding, UTF-8 file writes |
| `System.Text.RegularExpressions.Regex` | — | — | Yes | Marker block pattern matching |
| `System.Convert.ToBase64String` | — | — | Yes | GitHub Basic auth header encoding |
| `Get-FileHash` (SHA256) | Yes | — | — | Per-file integrity manifest |

### Environment Variables Consumed

Variables read from the environment (not set by the script for its own use):

| Variable | codeql | deploy | ev2 | Purpose |
|----------|--------|--------|-----|---------|
| `HOME` | Yes | — | — | macOS cache path (`~/Library/Application Support/CodeQL`) |
| `XDG_DATA_HOME` | Yes | — | — | Linux cache path (fallback: `~/.local/share`) |
| `LocalApplicationData` | Yes | — | — | Windows cache path (via `SpecialFolder`) |

deploy and ev2 use only `[System.IO.Path]::GetTempPath()` for working directories and do not read cache-related environment variables.

### Dependency Matrix Summary

| Aspect | codeql | deploy | ev2 |
|--------|--------|--------|-----|
| Required external binaries | 3 (git, az, unzip*) | 2 (git, az) | 2 (git, ev2) |
| Optional external binaries | 0 | 0 | 4 (gh, open/xdg-open/wslview/cmd.exe) |
| PowerShell minimum | 7.0 (`#Requires` + runtime check) | 7.0 | 7.0 |
| Needs network auth | Always | Always | Optional (public repo) |
| Local caching | 1-hour TTL | None (temp dir) | None (temp dir) |
| .NET API surface | Small | Medium (SHA256, Guid) | Medium (Regex, Base64, Guid) |

---

## Strategy: Further Alignment of vibeshield-codeql

### Completed

The following items have been addressed:

1. **Merge conflicts resolved** — removed all `<<<<<<< HEAD` / `=======` / `>>>>>>>` markers; adopted the newer parameter set (`$Branch`, `$ProjectPath`, `$SkipSetup`, `$Force`, `$CommitSHA`, `$SourceRepo`).
2. **Capability contract integrated** — `Import-Module` added; `Set-VibeShieldCapabilityResult` called with `ok` on success and `fail` on exception.
3. **Per-command auth injection** — replaced process-wide `GIT_CONFIG_*` env vars with `Invoke-GitCommand -AdoToken` using `-c http.extraheader=AUTHORIZATION: bearer ...` per-command (matching deploy/ev2 pattern).
4. **Clean `finally` block** — only `Pop-Location` remains; no env var cleanup needed since auth is per-command.
5. **Phase tracking** — `$phase` variable set at each step, reported in `Set-VibeShieldCapabilityResult` on failure.
6. **`#Requires -Version 7.0`** — added shebang, `#Requires` directive, and runtime version check (matching ev2 pattern).
7. **Git version check** — fixed from 2.9+/`core.hooksPath` to 2.25+/`sparse-checkout` (matching ev2 pattern).
8. **Error classifier function** — `Convert-VibeShieldCodeQLErrorToMessage` maps throw messages to contract-safe error codes (ev2 pattern).
9. **Named function wrapper** — main logic wrapped in `Invoke-InstallVibeShieldCodeQL` with invocation guard for Pester testability (deploy/ev2 pattern).

### Remaining Improvements

These are alignment improvements that can be addressed in future iterations:

| Item | Description | Priority |
|------|-------------|----------|
| **Replace `Set-MarkerBlock`** | Migrate to the shared `Install-VibeShieldFragment.ps1` pattern (requires creating fragment asset files with `<!-- BEGIN:vibeshield-codeql -->` / `<!-- END:vibeshield-codeql -->` markers, then replacing the inline `Set-MarkerBlock` function and its `<!-- codeql-vibe start/end -->` format) | Low |
