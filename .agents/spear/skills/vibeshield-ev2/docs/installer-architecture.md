# VibeShield-EV2 Installer — Architecture & Design

## Overview

`Install-VibeShield.ps1` installs Copilot agent assets for ExpressV2 (EV2) into a target project workspace. It sparse-clones a private GitHub repository, copies agent/prompt/resource files into `.github/`, wires routing into `copilot-instructions.md`, and configures the EV2 MCP Server in `.vscode/mcp.json`.

**Source:** [`scripts/Install-VibeShield.ps1`](../scripts/Install-VibeShield.ps1)

---

## Execution Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Invoke-InstallVibeShieldEv2               │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ Platform      │    │ Validate     │    │ Authenticate  │  │
│  │ Detection     │───>│ Target Path  │───>│ & Clone       │  │
│  │ (WSL/Win/     │    │              │    │               │  │
│  │  Mac/Linux)   │    └──────────────┘    └───────┬───────┘  │
│  └──────────────┘                                 │          │
│                                                   ▼          │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ Cleanup      │    │ Wire         │    │ Copy Asset    │  │
│  │ & Summary    │<───│ Instructions │<───│ Directories   │  │
│  │              │    │ & MCP Config │    │               │  │
│  └──────────────┘    └──────────────┘    └───────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Step-by-Step

| Step | Phase ID | What Happens | Failure Behavior |
|------|----------|--------------|------------------|
| **1** | `prerequisites` | Validate git ≥ 2.25, PowerShell ≥ 7, GitHub CLI (gh) | Hard fail with classified error code |
| **2** | `clone-source` | Authenticate via gh, sparse-clone repo, handle SAML SSO | Retry with OAuth device flow on SAML 403 |
| **3** | `copy-assets` | Copy `.github/{agents,prompts,resources}` to target | Warns on missing source dirs, continues |
| **4** | `configure-copilot` | Upsert marker block in `copilot-instructions.md` | Warns if source file missing, continues |
| **5** | `configure-mcp` | Merge EV2 server entry into `.vscode/mcp.json` | Backs up corrupt JSON, recreates |
| **6** | `cleanup` | Remove temp clone directory | Runs in `finally` block (always) |

---

## Architecture Decisions

### Git Isolation

The installer clones a private repo into a temp directory alongside the user's project. To prevent side effects on the user's own git configuration:

- **No process-wide env vars.** The script does not set `GIT_TERMINAL_PROMPT`, `GCM_INTERACTIVE`, or `GIT_CONFIG_*` at process scope. These would leak into any subsequent git commands the user runs.
- **Per-command `-c` flags.** `Invoke-Git` injects isolation via `git -c credential.helper= -c core.askPass=` on every invocation. These override the user's git config for that command only.
- **Auth header injection.** When a token is available, it's passed as `git -c http.extraHeader=Authorization: Basic <base64>` — again per-command, no persistent credential storage.
- **Env var save/restore.** `GIT_TERMINAL_PROMPT` and `GCM_INTERACTIVE` are temporarily set during `Invoke-Git` and restored in a `finally` block.

```
Invoke-Git -GitArgs @('clone', ...) -AuthToken $token
  │
  ├─ Builds: git -c credential.helper= -c core.askPass= -c http.extraHeader=... clone ...
  ├─ Sets:   GIT_TERMINAL_PROMPT=0, GCM_INTERACTIVE=never
  ├─ Runs:   & $GitBin @cmd
  └─ Finally: restores env vars to previous values
```

### Idempotent Marker Blocks

`copilot-instructions.md` is shared — other VibeShield skills may also write to it. The installer uses HTML comment markers to own exactly its section:

```markdown
<!-- vibeshield-ev2 start -->
(EV2-specific routing instructions)
<!-- vibeshield-ev2 end -->
```

`Set-MarkerBlock` handles three cases:
- **Markers exist** → regex replace in-place (upgrade)
- **File exists, no markers** → append block at end
- **File missing** → create with block as sole content

This makes re-installation safe — running the installer again overwrites the EV2 section without touching other content.

### MCP Configuration Merge

`.vscode/mcp.json` may already contain other MCP server entries. The installer:
1. Reads existing JSON (if any)
2. Parses with `ConvertFrom-Json -AsHashtable`
3. Upserts the `"Ev2 MCP Server"` key under `servers`
4. Writes back with `ConvertTo-Json -Depth 10`

If the existing file is corrupt JSON, it's backed up to `.bak` and recreated.

---

## Authentication Architecture

The installer must clone from `https://github.com/gim-home/ev2-demo-agent.git`, a private repository in an org that enforces SAML SSO. Authentication is **mandatory** — the script never attempts unauthenticated cloning.

### Authentication Flow

```
                    ┌─────────────────────┐
                    │ gh installed?       │
                    └─────────┬───────────┘
                         yes  │  no
                    ┌─────────┘  └──────────────┐
                    ▼                            ▼
            ┌───────────────┐          ┌──────────────────┐
            │ gh auth token │          │ Install-GitHubCli │
            │ (fast path)   │          │ (~/.local/bin)    │
            └───────┬───────┘          └────────┬─────────┘
               has  │  no token            ok   │  failed
              token │                           │
                    ▼                           ▼
            ┌───────────────┐          ┌──────────────────┐
            │ Use existing  │          │ GITHUB_AUTH_FAILED│
            │ token         │          │ (hard fail)       │
            └───────┬───────┘          └──────────────────┘
                    │
                    ▼
            ┌───────────────┐
            │ Clone repo    │
            └───────┬───────┘
               ok   │  SAML SSO 403
                    │
                    ▼
            ┌───────────────────────────────┐
            │ OAuth Device Flow             │
            │ (direct GitHub API, no gh)    │
            │                               │
            │ 1. POST /login/device/code    │
            │ 2. Copy code to clipboard     │
            │ 3. Open browser               │
            │ 4. Poll /login/oauth/access_token │
            │ 5. Feed token to gh auth login│
            │ 6. Retry clone                │
            └───────────────────────────────┘
```

### Token Acquisition: `Get-GitHubToken`

This function handles initial authentication via `gh`:

1. **Fast path:** `gh auth token` returns an existing token → use it immediately (zero interaction)
2. **No token:** Launch `gh auth login --git-protocol https --web` which triggers the standard browser-based device flow via gh
3. **Post-login:** Re-read token with `gh auth token`

### SAML SSO Re-authorization

If the initial clone fails with a `SAML SSO` error in git output:

1. **User prompt:** Ask permission to proceed with SSO login (Y/n)
2. **OAuth Device Flow:** Bypass `gh auth refresh` (which has interactive prompts that break in WSL) by calling GitHub's OAuth API directly:
   - `POST https://github.com/login/device/code` with `client_id=178c6fc778ccc68e1d6a` (GitHub CLI's public OAuth client ID), scope `repo read:org`
   - Display the `user_code` and copy it to clipboard
   - Open `https://github.com/login/device` in the browser
   - Poll `POST https://github.com/login/oauth/access_token` every `interval` seconds until authorized or expired
3. **Token persistence:** Feed the access token to `gh auth login --with-token` so subsequent gh commands work
4. **Retry:** Clean up the failed clone directory, re-clone with the new token

### Why OAuth Device Flow Instead of `gh auth refresh`

`gh auth refresh -h github.com` has two interactive prompts (`Authenticate Git with your GitHub credentials? [Y/n]` and `Press Enter to open github.com in your browser...`) that don't work well in WSL and can't be automated. The custom device flow:
- Reduces user interaction to **one step** (paste code in browser)
- Copies the code to clipboard automatically
- Opens the browser automatically
- Polls silently in the background

---

## Platform Support

### Detection

```powershell
$script:RunOnWindows = $IsWindows
$script:RunOnMacOS   = $IsMacOS
$script:RunOnWSL     = (-not $IsWindows) -and
    (Test-Path '/proc/version') -and
    ((Get-Content '/proc/version' -Raw) -match '(?i)microsoft|wsl')
```

WSL is detected separately from Linux because it requires Windows-side tools for clipboard and browser access.

### Platform-Specific Behaviors

| Feature | Windows | WSL | macOS | Linux |
|---------|---------|-----|-------|-------|
| **Clipboard** | `Set-Clipboard` | `clip.exe` via `System.Diagnostics.Process` | `/usr/bin/pbcopy` via `System.Diagnostics.Process` | `xclip` or `xsel` via `System.Diagnostics.Process` |
| **Open browser** | `Start-Process` | `wslview` → `cmd.exe /c start` | `open` | `xdg-open` |
| **Install gh** | Not supported (manual) | `~/.local/bin` via tarball | `~/.local/bin` via tarball | `~/.local/bin` via tarball |

All clipboard operations use `System.Diagnostics.Process` with `RedirectStandardInput` for reliability across platforms (avoids PowerShell pipeline encoding issues).

---

## Dependency: GitHub CLI Auto-Install

`Install-GitHubCli` downloads gh from GitHub Releases when it's not already installed:

1. Detect OS (`linux`/`macOS`) and architecture (`amd64`/`arm64`)
2. Query `https://api.github.com/repos/cli/cli/releases/latest` for the current version
3. Download tarball → extract to `~/.local/bin/gh` → `chmod +x`
4. Add `~/.local/bin` to `$env:PATH` for the current session

**Not supported on Windows** — returns `$false`, which triggers a hard `GITHUB_AUTH_FAILED` error. Windows users must install gh manually.

---

## Error Handling

### Classified Error Codes

All errors are thrown as prefixed strings (e.g., `GITHUB_AUTH_FAILED: ...`). `Convert-VibeShieldEv2ErrorToMessage` maps them to user-facing messages:

| Error Code | Meaning |
|-----------|---------|
| `TARGET_PATH_MISSING` | `-ProjectPath` does not exist |
| `PREREQ_GIT_MISSING` | `git` not found in PATH |
| `PREREQ_GIT_VERSION_TOO_OLD` | git < 2.25 (no sparse-checkout) |
| `PREREQ_POWERSHELL_VERSION_TOO_OLD` | PowerShell < 7 |
| `GIT_CLONE_FAILED` | Clone command returned non-zero |
| `GIT_SPARSE_CHECKOUT_FAILED` | `sparse-checkout set` failed |
| `SOURCE_GITHUB_MISSING` | `.github/` not in cloned content |
| `GITHUB_AUTH_FAILED` | Authentication failed or gh unavailable |
| `GITHUB_AUTH_DECLINED` | User chose not to authenticate |

### Phase Tracking

The `$phase` variable tracks the current operation for error reporting:

```
initialize → validate-target → prerequisites → clone-source → copy-assets
→ configure-copilot → configure-mcp → cleanup
```

On failure, the phase is included in the capability contract result for diagnostics.

### Cleanup Guarantee

The `finally` block ensures the temp directory is removed regardless of success or failure:

```powershell
finally {
    if (-not [string]::IsNullOrEmpty($TempDir) -and (Test-Path $TempDir)) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```

---

## Capability Contract Integration

The installer integrates with the VibeShield orchestrator via `Vibeshield.CapabilityContract.psm1`. This module exports `Set-VibeShieldCapabilityResult` which writes a JSON handshake file.

### Contract Protocol

The orchestrator sets three environment variables before invoking the installer:
- `VIBESHIELD_RESULT_PATH` — where to write the result JSON
- `VIBESHIELD_HANDSHAKE_VERSION` — schema version (currently `1`)
- `VIBESHIELD_CAPABILITY_NAME` — capability identifier (e.g., `vibeshield/ev2`)

### Result Statuses

| Status | When |
|--------|------|
| `ok` | Installation completed successfully |
| `partial` | User declined authentication (graceful skip) |
| `fail` | Any classified error |

### Standalone Mode

When run outside the orchestrator (env vars not set), `Set-VibeShieldCapabilityResult` throws. The installer catches this in a nested `try/catch` and falls back to `Write-Warning` — the user still sees the error, but no handshake file is written.

---

## File Layout

```
skills/vibeshield-ev2/
├── SKILL.md                              # Skill metadata and usage docs
├── docs/
│   └── installer-architecture.md         # This document
└── scripts/
    ├── Install-VibeShield.ps1            # Installer entry point
    └── Vibeshield.CapabilityContract.psm1 # Orchestrator handshake module
```

### What Gets Installed

```
<target-project>/
├── .github/
│   ├── agents/          ← copied from source repo
│   ├── prompts/         ← copied from source repo
│   ├── resources/       ← copied from source repo
│   └── copilot-instructions.md  ← marker block upserted
└── .vscode/
    └── mcp.json         ← EV2 MCP Server entry merged
```

---

## Function Reference

| Function | Purpose | Called By |
|----------|---------|-----------|
| `Invoke-InstallVibeShieldEv2` | Main installer orchestrator (6-step pipeline) | Script entry point |
| `Get-GitHubToken` | Acquires GitHub token via gh CLI, triggers login if needed | Step 2 |
| `Invoke-Git` | Isolated git wrapper with per-command auth and config injection | Steps 2 |
| `Set-MarkerBlock` | Idempotent marker-delimited content upsert in text files | Step 4 |
| `Install-GitHubCli` | Downloads and installs gh CLI to `~/.local/bin` | Step 1 |
| `Resolve-GitExecutable` | Finds git binary in PATH | Step 1 |
| `Invoke-GitVersion` | Returns `git --version` output | Step 1 |
| `Get-PowerShellRuntimeVersion` | Returns `$PSVersionTable.PSVersion` | Step 1 |
| `Test-GitHubCliAvailable` | Checks if gh is in PATH | Step 1 |
| `Convert-VibeShieldEv2ErrorToMessage` | Maps error code prefixes to user messages | Error handler |
| `Write-Step` / `Write-Pass` / `Write-Fail` / `Write-Warn` | Colored console output helpers | Throughout |

---

## Design Constraints

1. **Set-StrictMode -Version Latest** — all property access must use `PSObject.Properties['name']?.Value` to avoid null reference errors
2. **No secrets in env vars or logs** — tokens are passed as function parameters, never stored in process-wide state
3. **Idempotent** — safe to run multiple times; files are overwritten, marker blocks are replaced in-place
4. **Cross-platform** — single script runs on Windows, macOS, Linux, and WSL with platform-specific adaptations
5. **Zero leftover state** — temp directories cleaned up in `finally`, env vars restored, no git config side effects
