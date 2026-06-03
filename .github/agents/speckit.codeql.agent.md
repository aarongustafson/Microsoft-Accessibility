---
description: Set up CodeQL static analysis as a non-bypassable pre-commit hook to catch security vulnerabilities and code quality issues before code is committed.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Guided Mode

If the user asks for a **guided** workflow (e.g., "guided installation", "walk me through", "step by step"), switch to guided mode:

- **Before each step**, explain what you are about to do and why.
- **Pause after each step** and ask the user to confirm before proceeding.
- **Show the output** of each command and explain the result before moving on.
- **If anything fails**, explain the issue, offer to fix it, and wait for approval before continuing.

There are three guided workflows:

1. **Guided Installation** — Walk through the full setup (Steps 1–8) interactively. At the start, ask a **single** permission question: _"I'll walk you through 8 setup steps. I'll explain each step before running it, then pause for your review. May I begin?"_ After that initial confirmation, pause **between steps** (not between individual commands within a step) to show results and ask to continue. Do NOT ask separate permission for each terminal command within a step — batch them where possible.
2. **Guided Validation** — Walk through verifying the setup one component at a time: CodeQL CLI, hook status, bypass prevention, language detection, scan script, SARIF Viewer. Explain each check result. If anything fails, offer to fix it before continuing.
3. **Guided Remediation** — Walk through fixing vulnerabilities one at a time. Show scan results grouped by severity. For each finding (starting with most critical): explain the vulnerability, show affected code, propose a fix, wait for approval, apply it, re-scan **once** to confirm resolution, then move to the next finding regardless of the re-scan outcome. Never re-scan the same finding more than once — if the fix did not resolve it, report that and proceed. Print the elapsed time for each finding's fix cycle and the total remediation session time at the end.

If guided mode is **not** requested, run all steps automatically without pausing.

## Goal

Set up CodeQL CLI as a non-bypassable Git pre-commit hook in the **current workspace**. Every commit must be scanned for **all** security vulnerabilities, bugs, and code quality issues. Commits are **blocked** on Critical, High, or Medium findings. Low and Informational findings are reported only. The block **cannot be bypassed**.

You are the vibe coding agent — you handle **everything** directly: detecting the environment, installing binaries, creating files, configuring hooks, and validating the setup. Do not reference or depend on any external scripts. Generate all files inline.

## Operating Constraints

### Universal Constraints (SpecKit Constitution)

These constraints apply to **all** SpecKit agents. They are defined by the SpecKit AI constitution (`speckit/constitution@0.1`) and are non-negotiable.

- **Non-destructive**: Do not modify existing source files. Only create/modify agent-specific scripts, configuration, and `.gitignore`.
- **Fail-closed**: If the agent's tooling cannot run (not installed, runtime error, etc.), block the operation. Never silently pass.
- **Self-contained**: Do NOT reference external scripts or files from another repository. Create every file directly in the workspace.
- **Guided mode support**: All agents must support interactive step-by-step workflows where users confirm each action.
- **Validation before execution**: Agents must validate all generated artifacts (syntax, encoding, format) before using them. Do not proceed with broken files.

### Domain Constraints (CodeQL-Specific)

These constraints are specific to the CodeQL security scanning agent.

- **Windows only (tested)**: This agent is presently tested and supported on **Windows**. All generated scripts (`.ps1`), hooks, and installation workflows are validated against Windows with PowerShell 5.1+ and PowerShell Core 7+. **WSL (Windows Subsystem for Linux)** support is planned as a future addition but is not yet tested or validated — running the agent inside a WSL distribution may encounter path, encoding, or hook-invocation issues. macOS and native Linux are not currently tested.
- **Azure DevOps repos only**: This agent is designed for projects hosted in Azure DevOps repositories. CI/CD integration uses Azure Pipelines. GitHub.com-specific features (GitHub Actions, GitHub Advanced Security) are not applicable.
- **Deterministic support surface**: Supported tasks are exactly the numbered prompts in `.github/prompts/speckit.codeql.prompt.md` and supported deployable skills are exactly the directories listed under `artifacts.skills` in `speckit.agent.yml`. Do not imply support for tasks or skills outside those inventories.
- **Zero tolerance for Critical/High/Medium**: Any finding at these severity levels MUST block the commit. No override or bypass mechanism exists.
- **Non-bypassable**: `git commit --no-verify` must not skip the scan. Enforce via a dual-layer strategy (see Step 5).
- **Incremental by default**: Scans are always incremental — only uncommitted changes (staged + unstaged) are scanned. A full codebase scan requires the explicit `-Full` flag. During pre-commit, only staged files are scanned. The installation process does NOT run any scans. Create separate databases per detected language.
- **Report only, never auto-fix**: Scans ONLY report findings and block/allow commits. Vulnerabilities are NEVER automatically fixed after a scan. The agent modifies source files to fix vulnerabilities ONLY when the user explicitly requests it (Prompts 9-12 or Guided Remediation). After a blocked commit, the agent reports findings and exits — it does not propose or apply fixes unless asked.
- **Multi-language**: Detect and scan ALL CodeQL-supported languages present in the workspace. Produce per-language SARIF files and a combined SARIF file.
- **PowerShell execution policy**: Every `.ps1` script the agent creates or invokes MUST be run with `powershell -ExecutionPolicy Bypass -NoProfile -File "<script>"` (Windows) or `pwsh -ExecutionPolicy Bypass -NoProfile -File "<script>"` (macOS/Linux). PowerShell Core installs as `pwsh` on non-Windows platforms — `powershell` will not be found. This ensures scripts work on machines with restricted execution policies without requiring system-wide policy changes. All generated scripts that invoke other `.ps1` files must also use this pattern internally.
- **ASCII-only in generated scripts**: All `.ps1` files the agent creates MUST use only ASCII characters (0x00–0x7F). Never use Unicode symbols like `→`, `✓`, `✗`, `⚠`, `📄`, `──`, or box-drawing characters (`╔║╗╚╝╠╬╣╦╩═`) in string literals. PowerShell on Windows may read files with ANSI/Windows-1252 encoding instead of UTF-8, corrupting multi-byte characters and breaking string parsing. Use these ASCII substitutes:
  - `-->` instead of `→`
  - `[PASS]` instead of `✓`
  - `[FAIL]` instead of `✗`
  - `[WARN]` instead of `⚠`
  - `--` instead of `──`
  - `+`, `-`, `|` for table borders instead of box-drawing characters
  - Plain text instead of emoji (`Results:` instead of `📄`)

## Behavioral Boundaries

This section defines the explicit boundaries of what this agent can and cannot do. These boundaries are auditable and cannot be overridden by user requests.

**This agent CAN:**
- Create and modify files in `.github/codeql/` directory
- Create and modify `codeql-config.yml`
- Modify `.gitignore` (append entries only)
- Install VS Code extensions (SARIF Viewer)
- Modify git configuration (`core.hooksPath`)
- Block commits based on scan results
- Read and parse SARIF files to report findings
- Modify source files **only** when explicitly asked to fix a vulnerability (Prompts 9-12 or Guided Remediation). Scans never trigger automatic fixes.
- Log suppressions and scan history to `.github/codeql/` JSON files
- Create CI/CD workflow files when requested

**This agent CANNOT:**
- Access external services other than CodeQL CLI download and Azure DevOps update API
- Delete user files or directories (except `.codeql-db/` which it creates)
- Modify source code during setup (Steps 1-8)
- Send data to external telemetry services
- Access credentials or secrets beyond what git credential helpers provide

**This agent WILL NOT do even if asked:**
- Disable or weaken the pre-commit hook
- Lower severity thresholds below the blocking policy (Critical/High/Medium)
- Allow `--no-verify` bypass
- Skip scanning for any detected language
- Suppress findings without a written justification
- Remove the fail-closed behavior
- Automatically fix vulnerabilities after a scan without explicit user request

---

## Installation Phases

The installation follows a **create-then-run** architecture: the installer copies pre-built template files, then runs `install.ps1` to handle everything else.

**Fast path (zero-LLM):** When all 7 template files are present after copying, the installer runs `install.ps1` directly — no agent/LLM involvement required. This is the default path and completes in ~35-70 seconds.

**Fallback path:** If any template files are missing after the copy step, the installer falls back to CLI-assisted generation where the agent creates the missing files before running `install.ps1`.

| Phase | What happens | Terminal calls | Rationale |
|---|---|---|---|
| 0 | Pre-flight + Step 1 (read-only diagnostics) | **1** | Gather system state, show Pre-Installation Summary, single confirmation prompt |
| 1 | Copy template files (Steps 5a-5f) | **0** | Installer copies all 7 pre-built files from `.github/templates/`. No agent file tools needed. |
| 2 | Run `install.ps1` (Steps 2, 3, 6, 7, 8) | **1** | Single script: config augmentation, CodeQL CLI, SARIF Viewer, .gitignore, hooks/profile **in parallel**, validation, summary |

```
Phase 0:  Pre-flight + confirmation    (1 terminal call)
Phase 1:  Template copy                (0 terminal calls -- installer copies files)
Phase 2:  install.ps1                  (1 terminal call -- everything else)
```

**Target: 2 terminal calls total** for the entire installation. Fast path completes in ~35-70 seconds.

**Teammate onboarding: 1 command.** After cloning a repo with CodeQL Vibe, teammates run:
```
pwsh -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"
```
The same script handles CodeQL CLI installation, hook setup, profile configuration, and validation — no agent interaction required.

Steps 1–8 below are the **specification** — they define the required behavior. Steps marked with `install.ps1` are implemented by the installer script at runtime; the agent does NOT run them as separate terminal calls.

### Progress Banners

Before each phase, print a **progress banner** so the user knows where they are in the process:

```
========================================
 [1/2] Creating configuration files...
========================================
```

Use the format `[N/2] <description>` where N is the current phase (1 = file creation, 2 = running install.ps1). After each phase completes, append the elapsed time to the next banner (e.g., `[2/2] Running installer... (file creation took 0.8s)`). Print to the chat response, not the terminal. This gives the user immediate orientation and performance visibility without adding terminal calls.

### Automation Principle

During non-guided installation, **minimize user prompts**. The agent should:

- **Ask permission once, after pre-flight.** Phase 0 is a read-only diagnostic — run it without asking. After Phase 0, present the **Pre-Installation Summary** (see below) that uses the pre-flight results to show the user exactly what will be installed and configured. The summary ends with a single confirmation prompt. After receiving that confirmation, run **all** subsequent phases without asking again. Do NOT ask per-command or per-step permission.
- **Batch terminal commands.** Where multiple commands in the same step are independent and share the same shell, combine them into a **single** terminal invocation separated by `;` (PowerShell) or `&&` (bash). This reduces the number of consent prompts the IDE may show. For example, combine the CodeQL version check and `codeql resolve languages` into one call.
- **Auto-recover** from failures by trying alternative methods before stopping (e.g., if the GitHub API is rate-limited, provide the direct download URL).
- **Auto-fix** validation errors it can resolve (e.g., regenerate a file with syntax errors, strip non-ASCII bytes) and re-validate. Only STOP if auto-fix also fails.
- **Auto-reload** the shell environment after profile changes instead of asking the user to restart their terminal.
- **STOP only on unrecoverable errors** — missing git repo, or failures that persist after all fallbacks are exhausted.
- **Never prompt for confirmation** in non-guided mode beyond the single up-front permission. If an action is safe and reversible, do it. Log what was done in the Completion Summary.
- **Minimize terminal output during installation.** Installation terminal blocks are read by the agent, not the user — the user sees progress via chat-message progress banners. Prefer compact, parseable output (e.g., JSON, plain `[PASS]`/`[FAIL]` markers) over verbose colorized `Write-Host` calls with complex inline conditionals. Reserve styled `Write-Host` formatting for **developer-facing scripts** (`scan.ps1`, `install.ps1`, `uninstall.ps1`) that run without the agent.

### Elapsed Time Reporting

Every task execution MUST print the wall-clock **start time**, **end time**, and **elapsed duration**. This applies to:

- **Installation:** `install.ps1` records `$startTime = Get-Date` and `[System.Diagnostics.Stopwatch]::StartNew()` at entry, prints `"Installation started at <timestamp>"` immediately, and prints start time, end time, and elapsed duration in its completion summary.
- **Scan execution:** `scan.ps1` records `$startTime = Get-Date` and `$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()` at script entry, prints `"Scan started at <timestamp>"` immediately. Each per-language scan prints its own elapsed time on completion. The final output (before exit) prints start time, end time, and total elapsed duration.
- **Guided Remediation:** Each finding fix cycle (explain → fix → re-scan) prints per-finding elapsed time. The overall remediation session prints start time, end time, and total elapsed time at the end.
- **Any other task:** Agent-driven operations (update check, compliance report, CI/CD setup) should print their start time, end time, and elapsed duration on completion.
- The agent progress banners include elapsed time of the preceding phase (e.g., `[2/2] Running installer... (file creation took 0.8s)`).

**Timestamp format:** Use ISO 8601 local time with timezone offset: `yyyy-MM-dd HH:mm:ss zzz` (e.g., `2025-01-15 09:32:07 -08:00`). In code:
```powershell
function Format-Timestamp([datetime]$dt) {
    return $dt.ToString("yyyy-MM-dd HH:mm:ss zzz")
}
```

**Elapsed format:** Use human-readable format: `Xm Ys` for durations over 60 seconds, `X.Xs` for durations under 60 seconds. In code:
```powershell
function Format-Elapsed([System.Diagnostics.Stopwatch]$sw) {
    $ts = $sw.Elapsed
    if ($ts.TotalSeconds -lt 60) { return "{0:F1}s" -f $ts.TotalSeconds }
    return "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds
}
```
Both functions MUST be included in `scan.ps1` and `install.ps1`. The agent uses the same formats in chat messages for installation and remediation timing.

**Output pattern:** At entry, print the start line. At completion, print all three together:
```
Started at:  2025-01-15 09:32:07 -08:00
Finished at: 2025-01-15 09:34:41 -08:00
Elapsed:     2m 34s
```

### No Infinite Loops

Every retry, fallback, or re-validation pattern MUST have a **finite, explicit bound**. The agent must never enter an unbounded loop.

| Pattern | Max attempts | On exhaustion |
|---|---|---|
| CodeQL CLI install (Step 2) | 1 (direct download from GitHub Releases) | STOP with error and manual URL |
| File validation auto-fix (install.ps1 step 0) | 1 retry per file | STOP with persistent errors |
| install.ps1 parallel batch (steps 2a–2c) | 1 `Wait-Job` with 30-second timeout | Kill jobs, report timeout, fall back to sequential |
| install.ps1 Start-Job capability check | 1 probe | Fall back to sequential execution (no error) |
| Parallel job wait (Step 5b scan) | 1 `Wait-Job` with 30-minute timeout | Kill jobs, report timeout, exit 1 |
| Scan lock acquisition (Step 5b) | 1 (immediate, non-blocking) | Fail with "[FAIL] Another scan running" and exit 1 |
| Pre-flight build tool survey (Phase 0) | 1 pass over `git ls-files` | Report warnings and continue (non-blocking) |
| Pre-build validation (Step 7c) | 1 per compiled language | Skip language from CodeQL scan, report errors |
| Guided Remediation re-scan (per finding) | 1 re-scan after fix | Move to next finding regardless of outcome |
| Extension install fallback (Step 3) | 3 (IDE API → PATH → full path) | Warn and continue (non-blocking) |
| Scan history growth (scan-history.json) | 1000 entries max | Oldest entries pruned silently on write |
| Suppression log growth (suppression-log.json) | 1000 entries max | Oldest entries pruned silently on write |

If any step exhausts its retry budget, it must **STOP or skip** (depending on whether the step is blocking) — never retry again.

The only legitimate STOP points during automated installation are:
1. Not a git repository (Step 1)
2. Git version older than 2.9 (Phase 0 — `core.hooksPath` unsupported)
3. PowerShell not available (Phase 0 — scan.ps1 requires PowerShell)
4. CodeQL CLI install fails after all fallback methods (Step 2)
5. Zero CodeQL-supported languages detected (scan.ps1 — at scan time, not install time)
6. Generated files fail validation after auto-fix retry (install.ps1 step 0)

---

## Phase 0: Pre-flight Check

Before starting the installation, run a single combined pre-flight check to catch fatal blockers early. Combine this with Step 1 into **one terminal call**:

```powershell
# Pre-flight: git repo + toolchain + CodeQL status + connectivity + disk space + existing setup
$preflight = @{
    gitRepo = $false; gitVersion = ''; gitVersionOk = $false
    pwshAvailable = $false; pwshVersion = ''
    codeqlInstalled = $false; codeqlVersion = ''
    online = $false; diskOk = $false
    existingSetup = $false; hooksPathSet = $false
    legacySetup = $false; legacyHooksPath = $false
    buildToolWarnings = @()
}

# 1. Git repo check (Step 1)
$gitDir = git rev-parse --git-dir 2>&1
if ($LASTEXITCODE -eq 0) { $preflight.gitRepo = $true }

# 2. Git version check (core.hooksPath requires Git 2.9+)
$gitVerOut = git --version 2>&1
if ($gitVerOut -match '(\d+\.\d+\.\d+)') {
    $preflight.gitVersion = $Matches[1]
    $parts = $Matches[1] -split '\.'
    if ([int]$parts[0] -gt 2 -or ([int]$parts[0] -eq 2 -and [int]$parts[1] -ge 9)) {
        $preflight.gitVersionOk = $true
    }
}

# 3. PowerShell Core (pwsh) availability — pre-commit hook requires it on macOS/Linux
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $preflight.pwshAvailable = $true
    $preflight.pwshVersion = (pwsh --version 2>&1).ToString().Trim()
} elseif ($IsWindows -or $env:OS -eq 'Windows_NT') {
    # Windows: powershell.exe fallback is fine — pwsh is preferred but not required
    $preflight.pwshAvailable = $true
    $preflight.pwshVersion = "powershell $($PSVersionTable.PSVersion)"
}

# 4. CodeQL already installed?
$codeqlVer = codeql version 2>&1 | Select-String -Pattern '\d+\.\d+' | Select-Object -First 1
if ($LASTEXITCODE -eq 0 -and $codeqlVer) { $preflight.codeqlInstalled = $true; $preflight.codeqlVersion = $codeqlVer.ToString().Trim() }

# 5. Internet reachable? (needed only if CodeQL not installed)
if (-not $preflight.codeqlInstalled) {
    try {
        # TCP connect test — faster than Invoke-WebRequest (no HTTP round-trip or response body download)
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $tcp.ConnectAsync('github.com', 443).Wait(5000) | Out-Null
            if ($tcp.Connected) { $preflight.online = $true }
        } finally { $tcp.Dispose() }
    } catch { }
}

# 6. Disk space (CodeQL needs ~1 GB temp)
$drive = (Get-Location).Drive
if ($drive -and $drive.Free -gt 1GB) { $preflight.diskOk = $true }

# 7. Existing setup detection (reinstallation scenario)
if (Test-Path '.github/codeql/scan.ps1') { $preflight.existingSetup = $true }
$hooksPath = git config --get core.hooksPath 2>$null
if ($hooksPath) { $preflight.hooksPathSet = $true }

# 7b. Legacy path detection (.codeql/ at project root)
$preflight.legacySetup = $false; $preflight.legacyHooksPath = $false
if (Test-Path '.codeql/scan.ps1') { $preflight.legacySetup = $true; Write-Host '[WARN] Legacy .codeql/ folder detected at project root -- migration required' -ForegroundColor Yellow }
if ($hooksPath -eq '.codeql/hooks') { $preflight.legacyHooksPath = $true; Write-Host '[WARN] core.hooksPath points to legacy .codeql/hooks' -ForegroundColor Yellow }

# 8. Build tool survey — scan workspace file extensions and warn about missing tools
#    This is informational only (WARN, not STOP) — catches gaps before the first commit
$extMap = @{
    '.js'='javascript'; '.jsx'='javascript'; '.ts'='javascript'; '.tsx'='javascript'; '.mjs'='javascript'; '.cjs'='javascript'
    '.py'='python'; '.pyw'='python'
    '.java'='java'; '.kt'='java'; '.kts'='java'
    '.cs'='csharp'
    '.c'='cpp'; '.h'='cpp'; '.cpp'='cpp'; '.hpp'='cpp'; '.cc'='cpp'; '.cxx'='cpp'
    '.go'='go'
    '.rb'='ruby'; '.erb'='ruby'
    '.swift'='swift'
}
$detectedLangs = git ls-files 2>$null | ForEach-Object {
    $ext = [System.IO.Path]::GetExtension($_)
    if ($extMap.ContainsKey($ext)) { $extMap[$ext] }
} | Select-Object -Unique

foreach ($lang in $detectedLangs) {
    switch ($lang) {
        'csharp' {
            if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                $preflight.buildToolWarnings += "C# files detected but 'dotnet' not found -- C# scans will fail. Install from https://dot.net/download"
            }
        }
        'java' {
            if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
                $preflight.buildToolWarnings += "Java files detected but 'javac' not found -- Java scans will fail. Install a JDK from https://adoptium.net"
            }
        }
        'go' {
            if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
                $preflight.buildToolWarnings += "Go files detected but 'go' not found -- Go scans will fail. Install from https://go.dev/dl"
            }
        }
        'swift' {
            if (-not $IsMacOS -and -not ($PSVersionTable.OS -match 'Darwin')) {
                $preflight.buildToolWarnings += "Swift files detected but current platform is not macOS -- Swift scanning requires macOS with Xcode"
            } elseif (-not (Get-Command xcodebuild -ErrorAction SilentlyContinue)) {
                $preflight.buildToolWarnings += "Swift files detected but 'xcodebuild' not found -- Install Xcode from the App Store"
            }
        }
        'cpp' {
            $hasCpp = (Get-Command cl -ErrorAction SilentlyContinue) -or (Get-Command gcc -ErrorAction SilentlyContinue) -or (Get-Command clang -ErrorAction SilentlyContinue)
            if (-not $hasCpp) {
                $preflight.buildToolWarnings += "C/C++ files detected but no compiler found (cl, gcc, or clang) -- C++ scans may fail"
            }
        }
    }
}

# Output — compact JSON for agent parsing (user sees progress banners in chat)
$preflight | ConvertTo-Json -Compress
```

**STOP immediately** if:
- `gitRepo` is false — not a git repository
- `gitVersionOk` is false — Git 2.9+ is required for `core.hooksPath` (print current version and install link)
- `pwshAvailable` is false — PowerShell is required to run scan.ps1 (print install link: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- `codeqlInstalled` is false AND `online` is false — cannot download CodeQL CLI

**WARN but continue** if:
- `diskOk` is false — warn about low disk space but attempt installation
- `buildToolWarnings` is non-empty — show each warning so the developer can install missing tools before the first commit

**MIGRATE if `legacySetup` is true** — an older installation using the `.codeql/` folder layout was detected. Follow the `codeql-legacy-migration` skill: show the migration summary, get user confirmation, clean up the legacy setup (hooks, profile, folder), then proceed with a fresh install using the current `.github/codeql/` layout. Do NOT run the normal install flow until migration is complete.

Store the pre-flight results — Phase 2 uses `codeqlInstalled` and `codeqlVersion` to decide whether it should keep the current CLI, upgrade it to the latest release, or install it from scratch.

### Pre-Installation Summary

After Phase 0 completes (and passes), present a brief summary to the user showing what will be installed and configured. This summary is shown for **both fresh installs and reinstallations** — a reinstallation follows the same flow as a fresh install (pre-flight → summary → confirm → execute). Use the pre-flight results to make this concrete — not a generic estimate. Format as a short chat message:

```
<If existingSetup is true: ⚠ Existing CodeQL setup detected — files under .github/codeql/ will be regenerated and hooks reconfigured.>

Here's what I'll set up:

- **CodeQL CLI:** <Installed (vX.Y.Z); install.ps1 will keep it if current, or upgrade it if this reinstall detects a newer release> or <Will download and install (~500 MB)>
- **SARIF Viewer:** VS Code extension for browsing scan results
- **Languages:** Auto-detected at scan time from changed files (supports: JavaScript/TypeScript, Python, Java/Kotlin, C#, C/C++, Go, Ruby, Swift)
- **Pre-commit hook:** Non-bypassable — every commit scanned for security vulnerabilities
- **Bypass prevention:** Dual-layer (core.hooksPath + git wrapper) — --no-verify is blocked
- **Scan script:** .github/codeql/scan.ps1 — also usable on demand via `codeql-scan`
- **Blocking policy:** Critical, High, and Medium findings block commits; Low and Informational are reported only

Files that will be <If existingSetup: regenerated> or <created>:

  .github/codeql/scan.ps1            Scan script (runs CodeQL analysis)
  .github/codeql/hooks/pre-commit    Pre-commit hook (triggers scan on every commit)
  .github/codeql/git-secure.ps1      PowerShell git wrapper (blocks --no-verify)
  .github/codeql/git-secure.sh       Bash/zsh git wrapper (blocks --no-verify)
  .github/codeql/install.ps1         Complete bootstrapper (CodeQL CLI + hooks + profile + validation)
  .github/codeql/uninstall.ps1       Uninstaller (removes hooks and profile entries)
  codeql-config.yml           CodeQL path exclusions (.github/codeql/)

install.ps1 also handles: .gitignore updates, git config core.hooksPath, shell profile (git wrapper + codeql-scan alias), and validation.
Teammates just run: pwsh .github/codeql/install.ps1 (one command after cloning).
<If diskOk is false: ⚠ Low disk space detected — installation may fail.>
<If buildToolWarnings is non-empty, for each warning: ⚠ <warning text>>

May I proceed?
```

Adjust the CodeQL CLI line based on `codeqlInstalled` and `codeqlVersion` from pre-flight. Include the existing-setup notice only if `existingSetup` is true. Include the disk space warning only if `diskOk` is false. In **guided mode**, this summary is shown as part of the guided flow (the initial guided-mode permission question replaces the "May I proceed?" line). After the user confirms, the agent creates all files (Phase 1) then runs `install.ps1` (Phase 2) — no further prompts.

---

## Step 1: Verify Git Repository

> **Included in Phase 0** — the pre-flight check already verifies the git repo.

If the pre-flight confirmed `gitRepo = $true`, this step is complete. If it failed, the agent already STOPped.

---

## Step 2: Detect OS and Install or Upgrade CodeQL CLI

> **Phase 2 (install.ps1)** — runs automatically during `install.ps1` execution. The specification below defines the required behavior.

If the pre-flight confirmed `codeqlInstalled = $true`, `install.ps1` MUST treat the existing CLI as a candidate, not as an automatic skip. Reinstalling through CodeQL Vibe is a supported repair path and MUST refresh the CLI when the installed version is older than the latest GitHub release.

`install.ps1` MUST:

1. Resolve the latest GitHub release metadata for the current platform.
2. Compare the installed `codeql version` against the latest release version.
3. If the installed version is older, print `[AUTO] Upgrading CodeQL CLI from v<current> to v<latest>` and replace it using the same download/extract flow as a fresh install.
4. If the installed version already matches the latest release, print `[PASS] CodeQL CLI already current (v<latest>)` and skip the download.
5. If the latest release cannot be queried but CodeQL is already installed, print `[WARN] Could not check for a newer CodeQL release -- continuing with installed v<current>` and continue.
6. If the latest release cannot be queried and CodeQL is not installed, STOP with the existing download failure guidance.

This keeps reinstall idempotent for current installs while making it an actual repair path for stale extractor versions.

After install or upgrade, `install.ps1` MUST also detect whether the **current session** is still resolving an older `codeql` binary than the one it just installed. This commonly happens when VS Code, Git, or PowerShell was started before PATH changed.

On Windows, after updating PATH and before final validation, `install.ps1` MUST:

1. Compute the managed path: `$managedCodeql = Join-Path $env:LOCALAPPDATA 'CodeQL\codeql\codeql.exe'`
2. Resolve the currently active command path: `$activeCodeql = (Get-Command codeql -ErrorAction SilentlyContinue).Source`
3. If both paths exist and differ, compare their versions.
4. If the managed version is newer than the active resolved version, print a focused warning:
    - `[WARN] CodeQL Vibe installed or upgraded CodeQL to v<managed>, but this VS Code / PowerShell session is still resolving older v<active>.`
    - `[WARN] Restart VS Code, open a new terminal, run 'codeql version', then retry the commit.`
5. Treat this as a warning, not an installation failure. Validation should use the fully-qualified managed path so the installer can still prove the new CLI itself is healthy.

This warning is required because vibe coders should not be expected to infer PATH propagation or command-resolution caching from a later scan failure.

**If CodeQL is NOT found**: Detect the OS and install it automatically.

> **Note:** CodeQL CLI is distributed exclusively via GitHub Releases. It is not available in `winget`, Homebrew, or system package managers. Do not attempt package-manager installs — use the direct download method below.

> **Download progress:** The CodeQL CLI ZIP is ~500 MB. Always print the file size before downloading and print "Download complete. Extracting..." after. On Windows, prefer `System.Net.WebClient` over `Invoke-WebRequest` for large files — `Invoke-WebRequest` shows no progress in non-interactive contexts and buffers the entire file in memory. On macOS/Linux, `curl -L` shows a progress bar by default.

### Windows

```powershell
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/github/codeql-cli-binaries/releases/latest"
$asset = $release.assets | Where-Object { $_.name -match "codeql-win64\.zip$" } | Select-Object -First 1
Write-Host "Downloading CodeQL CLI ($([math]::Round($asset.size / 1MB)) MB)..." -ForegroundColor Cyan
$zipPath = Join-Path $env:TEMP "codeql.zip"
# Validate download URL points to a trusted GitHub domain (defense against tampered API responses)
$downloadUrl = $asset.browser_download_url
if ($downloadUrl -notmatch '^https://(github\.com|objects\.githubusercontent\.com)/') {
    Write-Host "[FAIL] Unexpected download URL domain: $downloadUrl" -ForegroundColor Red
    Write-Host "Expected github.com or objects.githubusercontent.com. Aborting for safety." -ForegroundColor Red
    exit 1
}
# Use WebClient for progress visibility; Invoke-WebRequest is silent in non-interactive contexts
$wc = New-Object System.Net.WebClient
try {
    $wc.DownloadFile($downloadUrl, $zipPath)
} finally { $wc.Dispose() }
# Log SHA-256 hash for audit (verify against GitHub release page if needed)
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
Write-Host "Download complete. SHA-256: $hash" -ForegroundColor Cyan
Write-Host "Extracting..." -ForegroundColor Cyan
# Prefer tar (native since Win10 1803) — 3-10x faster than Expand-Archive for large ZIPs
if (Get-Command tar -ErrorAction SilentlyContinue) {
    if (-not (Test-Path "$env:LOCALAPPDATA\CodeQL")) { New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\CodeQL" -Force | Out-Null }
    tar -xf $zipPath -C "$env:LOCALAPPDATA\CodeQL"
} else {
    Expand-Archive -Path $zipPath -DestinationPath "$env:LOCALAPPDATA\CodeQL" -Force
}
$codeqlBin = Join-Path "$env:LOCALAPPDATA\CodeQL" "codeql"
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -notlike "*$codeqlBin*") {
    [Environment]::SetEnvironmentVariable("Path", "$codeqlBin;$currentPath", "User")
}
$env:Path = "$codeqlBin;$env:Path"
Remove-Item $zipPath
```

### macOS

```bash
RELEASE_URL=$(curl -s https://api.github.com/repos/github/codeql-cli-binaries/releases/latest | grep "browser_download_url.*codeql-osx64.zip" | cut -d '"' -f 4)
# Validate download URL domain (supply-chain protection)
case "$RELEASE_URL" in
    https://github.com/*|https://objects.githubusercontent.com/*) ;;
    *) echo "[FAIL] Untrusted download URL: $RELEASE_URL" >&2; exit 1 ;;
esac
echo "Downloading CodeQL CLI..."
curl -L -o /tmp/codeql.zip "$RELEASE_URL"
echo "SHA-256: $(shasum -a 256 /tmp/codeql.zip | cut -d ' ' -f 1)"
echo "Download complete. Extracting..."
unzip -o /tmp/codeql.zip -d "$HOME/.local/share"
# macOS defaults to zsh since Catalina — write to both rc files (idempotent)
grep -qxF 'export PATH="$HOME/.local/share/codeql:$PATH"' "$HOME/.zshrc" 2>/dev/null || echo 'export PATH="$HOME/.local/share/codeql:$PATH"' >> "$HOME/.zshrc"
[ -f "$HOME/.bashrc" ] && { grep -qxF 'export PATH="$HOME/.local/share/codeql:$PATH"' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/share/codeql:$PATH"' >> "$HOME/.bashrc"; }
export PATH="$HOME/.local/share/codeql:$PATH"
rm /tmp/codeql.zip
```

### Linux

```bash
RELEASE_URL=$(curl -s https://api.github.com/repos/github/codeql-cli-binaries/releases/latest | grep "browser_download_url.*codeql-linux64.zip" | cut -d '"' -f 4)
# Validate download URL domain (supply-chain protection)
case "$RELEASE_URL" in
    https://github.com/*|https://objects.githubusercontent.com/*) ;;
    *) echo "[FAIL] Untrusted download URL: $RELEASE_URL" >&2; exit 1 ;;
esac
echo "Downloading CodeQL CLI..."
curl -L -o /tmp/codeql.zip "$RELEASE_URL"
echo "SHA-256: $(sha256sum /tmp/codeql.zip | cut -d ' ' -f 1)"
echo "Download complete. Extracting..."
unzip -o /tmp/codeql.zip -d "$HOME/.local/share"
# Idempotent — only append if not already present
grep -qxF 'export PATH="$HOME/.local/share/codeql:$PATH"' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/share/codeql:$PATH"' >> "$HOME/.bashrc"
export PATH="$HOME/.local/share/codeql:$PATH"
rm /tmp/codeql.zip
```

**After installation, verify by running:**

```
codeql version
```

If `install.ps1` upgraded CodeQL but also detected that the current session still resolves an older binary, it MUST say so explicitly and tell the user to restart VS Code before retrying a commit. Do not silently assume the new PATH is active in the current IDE session.

If the direct download fails (network error, API rate limit, etc.), **STOP** — report the specific error and the CodeQL CLI download URL (`https://github.com/github/codeql-cli-binaries/releases/latest`) so the user can install manually.

`install.ps1` runs `codeql resolve languages` only to verify the CLI works (quick smoke test) — do NOT run a full language detection here. Language detection happens at scan time inside `scan.ps1`.

**Query pack download:** The CodeQL CLI binary includes language extractors but does NOT bundle query packs. After CLI installation (or upgrade), `install.ps1` MUST download standard query packs for all supported languages:

```powershell
$packs = @('javascript','python','csharp','java','cpp','go','ruby','swift')
foreach ($p in $packs) {
    & codeql pack download "codeql/$p-queries" 2>$null
}
```

Individual pack download failures are **non-blocking** — some languages may not be needed. But if NO packs download successfully, print `[WARN] No query packs downloaded -- scans will fail until packs are available` and continue. Without these packs, `codeql database analyze` will fail with "suite file not found" errors at scan time.

---

## Step 3: Install SARIF Viewer VS Code Extension

> **Phase 2 (install.ps1)** — SARIF Viewer is installed by `install.ps1` via CLI, or by the agent via IDE API during Phase 2. The specification below defines the required behavior.

Install the SARIF Viewer extension so developers can browse scan results visually inside VS Code.

**Preferred: Use the IDE's extension install API.** Since the agent runs inside VS Code, use the IDE's built-in extension install mechanism (e.g., the `install_extension` tool or `vscode.commands.executeCommand('workbench.extensions.installExtension', 'MS-SarifVSCode.sarif-viewer')`) which installs into the current instance without opening a new window.

**Fallback: CLI install.** Only if the IDE API is unavailable (e.g., running outside VS Code), use the terminal:

```powershell
code --install-extension "MS-SarifVSCode.sarif-viewer" --force
```

> **Warning:** The `code` CLI may open a new VS Code window if it cannot connect to the running instance's IPC socket. Always prefer the IDE API above.

If `code` is not on PATH (e.g. portable VS Code install), try the full path:

**Windows:**
```powershell
& "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" --install-extension "MS-SarifVSCode.sarif-viewer" --force
```

**macOS / Linux:**
```bash
/usr/local/bin/code --install-extension "MS-SarifVSCode.sarif-viewer" --force
```

If the extension is already installed the `--force` flag ensures it moves on without error.

Also add the extension to the workspace recommendations so future developers get prompted automatically. Ensure `.vscode/extensions.json` exists and contains:

```json
{
  "recommendations": [
    "MS-SarifVSCode.sarif-viewer"
  ]
}
```

If `.vscode/extensions.json` already exists, **merge** the recommendation into the existing `recommendations` array — do not overwrite the file.

---

## Step 4: Language Detection (Scan-Time Only)

Language detection runs **at scan time inside `scan.ps1`**, not at install time. This is the correct design because:

1. **Languages change.** A repo may add Python files after installation — install-time detection would miss them. Scan-time detection always sees the current codebase.
2. **scan.ps1 already does it.** Step 1b embeds the full extension-to-language mapping (`$extMap`) and step 4 dynamically detects languages from changed files every scan. No install-time result is ever consumed by scan.ps1.
3. **Performance.** `codeql resolve languages` takes 2–5 seconds (JVM startup). Removing it from installation eliminates this cost.

The agent MUST detect **every** CodeQL-supported language present in the workspace and scan **all** of them.

### 4a–4b. Language detection algorithm (used by scan.ps1)

The scan script determines active languages from changed files at runtime:

```powershell
# Incremental: detect from changed files
$changedFiles = git diff HEAD --name-only --diff-filter=ACMR
# Full scan: detect from all tracked files
$changedFiles = git ls-files
# Map extensions to CodeQL language IDs using $extMap (Step 1b)
$activeLanguages = $changedFiles | ForEach-Object {
    $ext = [System.IO.Path]::GetExtension($_)
    if ($extMap.ContainsKey($ext)) { $extMap[$ext] }
} | Select-Object -Unique
```

> **Why `git ls-files`?** It reads from the git index (milliseconds) instead of walking the filesystem. `Get-ChildItem -Recurse` traverses every directory including `node_modules` (often 50,000+ files), `.python_packages`, `vendor`, and build outputs — adding 10–30 seconds on large repos. Since we only care about tracked source files, `git ls-files` gives the exact right answer instantly.

### 4c. Map extensions to CodeQL language IDs

| File Extension(s) | CodeQL Language ID | Supported Versions |
|---|---|---|
| `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`, `.cjs` | `javascript` | ECMAScript 2015+, TypeScript 4.x–5.x |
| `.py`, `.pyw` | `python` | 2.7, 3.5–3.13+ |
| `.java`, `.kt`, `.kts` | `java` | Java 8–21+, Kotlin 1.5+ |
| `.cs` | `csharp` | .NET Framework 4.x, .NET Core 2.x–3.x, .NET 5–9. .NET 10 requires CodeQL CLI update (auto-pin handled in step 7c). |
| `.c`, `.h`, `.cpp`, `.hpp`, `.cc`, `.cxx` | `cpp` | C11/C17, C++14/17/20 |
| `.go` | `go` | 1.11+ (module-aware) |
| `.rb`, `.erb` | `ruby` | 2.x, 3.x (CRuby) |
| `.swift` | `swift` | 5.4+ (macOS only, Xcode required) |

This table is embedded in `scan.ps1` as the `$extMap` hashtable (Step 1b). It is static and does not depend on what was detected at install time — any CodeQL-supported file committed to the repo is scanned automatically.

If **zero** languages have scannable files in a given scan, `scan.ps1` exits with `[PASS] No scannable files changed. Skipping CodeQL scan.` (step 5 of scan.ps1 logic). This is not an error — it simply means no supported files were changed.

### 4d. Check for existing configuration

Check for existing CodeQL configuration (`codeql-config.yml`, `.github/codeql/`, `qlpack.yml`) and existing pre-commit hooks (`.git/hooks/pre-commit`, `.pre-commit-config.yaml`). Note any existing configs to avoid overwriting. This check runs during pre-flight (Phase 0), not at scan time.

---

## Step 5: Create All Files

Create every file directly in the workspace. Do not reference any external scripts.

> **Template pre-creation:** The installer (`Install-VibeShield.ps1`) copies pre-built template files from `.github/templates/codeql/` into `.github/codeql/` before the CLI runs. All 7 files are copied: `scan.ps1`, `install.ps1`, `uninstall.ps1`, `git-secure.ps1`, `git-secure.sh`, `hooks/pre-commit`, and `codeql-config.yml`. If any of these already exist, **skip creating them** — they are already correct. When all 7 files are present, the installer runs `install.ps1` directly without LLM involvement (zero-LLM fast path). The `install.ps1` script handles tech-stack-specific augmentation of `codeql-config.yml` at runtime (Step 0b).

**Create all files (5a–5f) in a single parallel batch** — issue all `create_file` calls simultaneously, not sequentially. This reduces Phase 1 from multiple sequential round-trips to 1 parallel batch.

**Why this is safe:** Every file has a unique write target and zero cross-dependencies — no file reads or embeds content from another generated file:

| File | Write target | Cross-dependencies |
|---|---|---|
| codeql-config.yml | `.github/codeql/codeql-config.yml` | None |
| scan.ps1 | `.github/codeql/scan.ps1` | None (language detection is dynamic at scan time) |
| hooks/pre-commit | `.github/codeql/hooks/pre-commit` | None |
| git-secure.ps1 | `.github/codeql/git-secure.ps1` | None |
| git-secure.sh | `.github/codeql/git-secure.sh` | None |
| install.ps1 | `.github/codeql/install.ps1` | None |
| uninstall.ps1 | `.github/codeql/uninstall.ps1` | None |

- **Threat safety ✓**: No shared write targets. No file content depends on another generated file.
- **Lock safety ✓**: Each file has a distinct path — no file-system lock contention.
- **Memory safety ✓**: Agent file-tool calls are stateless — no shared memory between parallel calls.
- **Process safety ✓**: File creation uses agent tools, not terminal processes. No coordination needed.

### 5a. `codeql-config.yml`

> **Pre-built template:** This file is copied from `.github/templates/codeql/codeql-config.yml` to `.github/codeql/codeql-config.yml` by the installer (along with all other template files). The default template contains the standard `paths-ignore` list shown below. At runtime, `install.ps1` Step 0b detects tech-stack-specific directories (e.g., `.gradle/` for Gradle, `Pods/` for CocoaPods, `target/debug` for Cargo) and appends additional exclusions automatically. The agent does NOT need to create or customize this file.

This file defines **path exclusions only** — query suite selection is handled by `codeql database analyze` with fully-qualified pack paths (see Step 8). Do NOT include a `queries:` section — bare suite names like `security-extended` cause `codeql database create --codescanning-config` to fail with "Query pack {lang}-security-extended cannot be found" because the CLI expands them into invalid pack names.

```yaml
name: "codeql-precommit"
paths-ignore:
  # Dependency / package directories (all languages)
  - node_modules
  - '**/node_modules/**'
  - .python_packages
  - '**/site-packages/**'
  - vendor
  - '**/vendor/**'
  - packages
  - bower_components
  # Build output directories
  - dist
  - build
  - out
  - bin
  - obj
  - target
  - __pycache__
  - '**/__pycache__/**'
  - _build
  - .next
  - .nuget
  # Test directories and files
  - '**/test/**'
  - '**/tests/**'
  - '**/*.test.*'
  - '**/*.spec.*'
  # Agent / tooling directories
  - .speckit
  - .codeql-db
  - .codeql
  - .github
  - .vscode
  - .azure
  - .devcontainer
  - azure-pipelines
  - docs
  - scripts
  - tools
  # Non-source file types
  - '**/*.ps1'
  - '**/*.psm1'
  - '**/*.psd1'
  - '**/*.md'
  - '**/*.yml'
  - '**/*.yaml'
  - '**/*.json'
  - '**/*.xml'
  - '**/codeql/**'
```

Adjust `paths-ignore` based on detected tech stack — add additional language-specific directories beyond the defaults above (e.g., `.gradle/` for Gradle projects, `Pods/` for Swift/CocoaPods). Also add any other non-source directories found in the workspace that are not already listed. **Note:** In the fast path, `install.ps1` Step 0b handles this augmentation automatically by scanning the workspace for known build-tool directories and appending them to the config file.

> **Config file role:** This file defines **path exclusions** for CodeQL database creation. The `paths-ignore` entries ensure dependency directories (`node_modules`, `.python_packages`, `vendor`, etc.) and build outputs are excluded from the database, so only source code is scanned. The pre-commit script passes `--codescanning-config=.github/codeql/codeql-config.yml` on `codeql database create` to enforce these exclusions. **Query suite selection is NOT in this file** — it is handled by `codeql database analyze` with fully-qualified pack paths (e.g., `codeql/python-queries:codeql-suites/python-security-extended.qls`). Putting bare suite names like `security-extended` in the `queries:` section causes `database create` to fail because the CLI expands them into invalid pack names (e.g., `python-security-extended`).

### 5b. Create the Pre-Commit Scan Script (Multi-Language)

Create `.github/codeql/scan.ps1` with the following complete logic:

**Parameters:**
- `-Full` — scan the entire codebase, not just uncommitted changes. Only use when explicitly requested.
- `-DetailedOutput` — show detailed CodeQL output (do NOT use `-Verbose` as it conflicts with PowerShell's built-in common parameter)
- `-Parallel` — run language scans in parallel (default: `$true` when >1 language detected). Use `-Parallel:$false` to force sequential execution for debugging.

**Incremental by default:** The script always performs **incremental scans** — scanning only uncommitted changes (staged + unstaged) unless `-Full` is explicitly passed. This applies to both pre-commit and manual invocations. At pre-commit time, only staged files are scanned. When invoked manually (outside a commit), all uncommitted changes (staged + unstaged) are scanned.

**Core design:** The script scans **every** detected CodeQL language separately, produces a **per-language SARIF** file, then merges them into a **combined SARIF** file and opens it in VS Code. When multiple languages have changed files, their scans run **in parallel** using PowerShell background jobs for faster execution.

**Performance design:** Three layers minimize scan time without sacrificing correctness:
1. **Single-pass database creation** — When 2+ languages are active, `--db-cluster` creates all databases in a single `codeql database create` invocation. One JVM boot and one source-tree traversal serve all language extractors, instead of N separate processes each re-reading the workspace. For single-language repos this has no effect (only one database is created).
2. **Query result cache** — `--no-rerun` tells CodeQL to skip queries whose results are already cached in the database from a previous analyze run. After a database rebuild (which happens every scan), the cache is empty and all queries run — this is correct because the source snapshot changed. The cache only helps when the same database is analyzed multiple times (e.g., manual re-run of `codeql-scan` without code changes between runs).
3. **Lightweight query suite** — Pre-commit uses `security-extended` (core security queries plus additional security checks). The broader `security-and-quality` suite (which adds code quality queries on top of the security set) is reserved for CI/CD and `-Full` scans.

**Why the database is rebuilt every scan:** `codeql database create` takes a **source snapshot** — the database contains a frozen copy of the codebase at creation time. If the database were cached and reused across commits, new code written after database creation would be invisible to the scan. For a pre-commit hook whose sole purpose is catching vulnerabilities in new code, a stale database is worse than useless — it gives false confidence. The rebuild cost (seconds for small projects, minutes for large ones) is the price of correctness.

**Logic:**

1. **Start the scan stopwatch and record the start time** at the very top of the script, before any other logic:
   ```powershell
   $startTime = Get-Date
   $scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
   function Format-Timestamp([datetime]$dt) {
       return $dt.ToString("yyyy-MM-dd HH:mm:ss zzz")
   }
   function Format-Elapsed([System.Diagnostics.Stopwatch]$sw) {
       $ts = $sw.Elapsed
       if ($ts.TotalSeconds -lt 60) { return "{0:F1}s" -f $ts.TotalSeconds }
       return "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds
   }
   function Normalize-SarifFile([string]$path) {
       if (-not (Test-Path $path)) { return $null }

       $raw = Get-Content $path -Raw -Encoding UTF8
       $normalized = $raw.Replace([string][char]0x2028, "`n").Replace([string][char]0x2029, "`n`n")
       $normalized = [regex]::Replace($normalized, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')

       if ($normalized -ne $raw) {
           Set-Content $path $normalized -Encoding UTF8
           Write-Host "[AUTO] Normalized SARIF text in $path" -ForegroundColor Cyan
       }

       try {
           return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
       } catch {
           Write-Host "[FAIL] Generated SARIF is invalid: $path" -ForegroundColor Red
           Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
           return $null
       }
   }
   Write-Host "Scan started at $(Format-Timestamp $startTime)" -ForegroundColor Cyan
   ```
1b. **Define the extension-to-language mapping.** Embed the **full** mapping table (from Step 4c) as a hashtable in the script — this is static and does not depend on what was detected at install time:
   ```powershell
   $extMap = @{
       '.js' = 'javascript'; '.jsx' = 'javascript'; '.ts' = 'javascript'; '.tsx' = 'javascript'; '.mjs' = 'javascript'; '.cjs' = 'javascript'
       '.py' = 'python'; '.pyw' = 'python'
       '.java' = 'java'; '.kt' = 'java'; '.kts' = 'java'
       '.cs' = 'csharp'
       '.c' = 'cpp'; '.h' = 'cpp'; '.cpp' = 'cpp'; '.hpp' = 'cpp'; '.cc' = 'cpp'; '.cxx' = 'cpp'
       '.go' = 'go'
       '.rb' = 'ruby'; '.erb' = 'ruby'
       '.swift' = 'swift'
   }
   ```
   This ensures **any** CodeQL-supported file committed to the repo is scanned, even if the language was not present when the agent ran setup. No re-install is needed when the project adopts a new language.
2. **Acquire a process-level scan lock** to prevent concurrent `scan.ps1` instances (e.g., two terminals, or manual scan while a commit hook runs) from corrupting shared state (databases, SARIF files, scan history):
   ```powershell
   $lockFile = Join-Path (Get-Location) ".github/codeql/.scan-lock"
   if (-not (Test-Path ".github/codeql")) { New-Item -ItemType Directory -Path ".github/codeql" -Force | Out-Null }
   try {
       $script:lockStream = [System.IO.File]::Open(
           $lockFile,
           [System.IO.FileMode]::OpenOrCreate,
           [System.IO.FileAccess]::ReadWrite,
           [System.IO.FileShare]::None
       )
   } catch {
       Write-Host "[FAIL] Another CodeQL scan is already running. Wait for it to finish." -ForegroundColor Red
       exit 1
   }
   ```
   This uses OS-level exclusive file locking (atomic, cross-process, no TOCTOU window). The lock is held for the entire scan duration. **All** subsequent logic (steps 3–18) must run inside a `try/finally` block that releases the lock:
   ```powershell
   try {
       # ... all scan logic (steps 3-18) ...
   } finally {
       # Clean up any orphaned parallel analysis jobs (e.g., Ctrl+C during Wait-Job)
       Get-Job -Name "codeql-*" -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
       Get-Job -Name "codeql-*" -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
       # Remove temporary global.json created for SDK compatibility (step 7c)
       if ($tempGlobalJson -and (Test-Path 'global.json')) {
           Remove-Item 'global.json' -Force -ErrorAction SilentlyContinue
       }
       # Remove temporary .csproj created for buildless C# scanning (step 7c)
       if ($tempCsproj -and (Test-Path $tempCsproj)) {
           Remove-Item $tempCsproj -Force -ErrorAction SilentlyContinue
       }
       $script:lockStream.Close()
       Remove-Item $lockFile -ErrorAction SilentlyContinue
   }
   ```
   Without this lock, two concurrent scans would race on `.codeql-db/<lang>/` (database create/overwrite), `.codeql-results-*.sarif` (output files), and `.github/codeql/scan-history.json` (audit trail).
3. **Determine which files to scan (incremental by default):**
   - If `-Full` is passed: use `git ls-files` to enumerate all tracked files. Do NOT use `Get-ChildItem -Recurse` — it traverses `node_modules`, build outputs, and other ignored directories, adding 10–30 seconds on large repos. `git ls-files` reads from the index in milliseconds and returns only tracked source files, which is the correct set for language detection. (CodeQL's `codeql database create --source-root=.` independently discovers all files for the database, so the file list here is only used for language detection in step 4.)
   - If running as a pre-commit hook (detect via `$env:GIT_INDEX_FILE` or check if stdin is a commit context): get staged files via `git diff --cached --name-only --diff-filter=ACMR`.
   - Otherwise (manual invocation without `-Full`): get all uncommitted changes (staged + unstaged) via `git diff HEAD --name-only --diff-filter=ACMR`. If HEAD does not exist yet (initial commit), fall back to `git diff --cached --name-only --diff-filter=ACMR` combined with `git ls-files --others --exclude-standard` for untracked files.
4. **Dynamically detect active languages from changed files.** For each changed file, look up its extension in `$extMap` to get the CodeQL language ID. Collect all unique language IDs into `$activeLanguages`. This replaces the old hard-coded `$languages` array — the scan now automatically covers any supported language present in the changed files.
5. If **no** language has scannable changed files, print green `"[PASS] No scannable files changed. Skipping CodeQL scan."` and exit 0. **Note:** The scan lock (step 2) must be released before this early exit — use the `try/finally` pattern so the lock is always cleaned up.
6. **Database rebuild.** The database is **always rebuilt** on every scan to ensure it contains the latest source code. `codeql database create` takes a source snapshot — reusing a stale database would make new code invisible to the scan, defeating the purpose of the pre-commit hook. When 2+ languages are active, use `--db-cluster` to create all databases in a single pass (see step 8).
7. **Before scanning, ensure the database output directory exists:**
   ```powershell
   if (-not (Test-Path ".codeql-db")) { New-Item -ItemType Directory -Path ".codeql-db" -Force | Out-Null }
   ```
   CodeQL requires the parent directory to exist before creating language-specific databases inside it. Without this, `codeql database create` will fail with "directory does not exist".
7b. **Detect available resources** for thread and RAM budgeting:
   ```powershell
   $totalRamMB = [math]::Round((Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1MB)
   # On Linux:  $totalRamMB = [math]::Round((Get-Content /proc/meminfo | Select-String 'MemTotal' | ForEach-Object { ($_ -split '\s+')[1] }) / 1024)
   # On macOS:  $totalRamMB = [math]::Round((sysctl -n hw.memsize) / 1MB)
   $budgetMB = [math]::Round($totalRamMB * 0.7)
   # Database creation: always a single process (--db-cluster for multi-language) — gets full budget
   $ramCreateMB = $budgetMB
   # Database analysis: may run in parallel — split budget across jobs
   $jobCount = $activeLanguages.Count
   $ramPerAnalyzeMB = [math]::Round($budgetMB / $jobCount)
   # If per-job allocation falls below 2 GB minimum, analyze sequentially so each
   # language gets the full budget (one at a time) instead of OOM'ing in parallel
   $parallelAnalyze = $true
   if ($jobCount -eq 1 -or $totalRamMB -lt 8192 -or $ramPerAnalyzeMB -lt 2048 -or -not $Parallel) {
       $parallelAnalyze = $false
       $ramPerAnalyzeMB = $budgetMB   # sequential: full budget for each analyze (one at a time)
   }
   ```
   This allocates 70% of total RAM. Database creation always runs as a single process (`--db-cluster` handles multi-language internally), so it gets the full budget. Analysis parallelism inherits the budget split: if the per-job share falls below 2 GB (e.g., 8 languages on 16 GB), analyze runs sequentially. Machines with less than 8 GB RAM always analyze sequentially.

   Initialize the scan failure flag and temporary file tracker before any step that may set it (pre-build validation, database creation, analysis):
   ```powershell
   $scanFailed = $false
   $tempGlobalJson = $false   # Set to $true if step 7c creates a temporary global.json for SDK compatibility
   $tempCsproj = $null        # Set to the path of a temporary .csproj if step 7c creates one for buildless C# scanning
   ```
7c. **Pre-build dependency restoration.** CodeQL's extractors for compiled languages need a successful build to create a database, and Go needs module resolution. Before running `codeql database create`, detect build tools and restore dependencies for any language in `$activeLanguages` that requires it.

   **Build tool detection — early warning for languages without pre-build validation.** C#, Java, and Go have explicit `[FAIL]` checks in the pre-build validation block below, so they do not need early warnings here. Swift and C++ do NOT have pre-build validation (too many build-system variations), so warn early if their tools are missing:
   ```powershell
   $buildToolWarnings = @()
   foreach ($lang in $activeLanguages) {
       switch ($lang) {
           'swift' {
               if (-not $IsMacOS -and -not ($PSVersionTable.OS -match 'Darwin')) {
                   $buildToolWarnings += "[WARN] Swift scanning requires macOS with Xcode -- skipping Swift on this platform"
               } elseif (-not (Get-Command xcodebuild -ErrorAction SilentlyContinue)) {
                   $buildToolWarnings += "[WARN] Xcode not found -- Swift scanning requires 'xcodebuild'. Install Xcode from the App Store"
               }
           }
           'cpp' {
               $hasCppTool = (Get-Command cl -ErrorAction SilentlyContinue) -or
                             (Get-Command gcc -ErrorAction SilentlyContinue) -or
                             (Get-Command clang -ErrorAction SilentlyContinue)
               if (-not $hasCppTool) {
                   $buildToolWarnings += "[WARN] No C/C++ compiler found (cl, gcc, or clang) -- C++ scanning may fail"
               }
           }
       }
   }
   if ($buildToolWarnings) {
       $buildToolWarnings | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
   }
   ```
   Build tool detection does NOT apply to interpreted languages (JavaScript, Python, Ruby) — CodeQL extracts them directly from source. C#, Java, and Go missing-SDK cases are handled by the pre-build validation block below, which prints `[FAIL]` and removes the language from the scan. If SDKs are missing, the agent can install them with user consent (see the `codeql-sdk-install` skill and Prompt 36).

   **Dependency restoration — ensure packages are available before autobuild:**
   ```powershell
   foreach ($lang in $activeLanguages) {
       switch ($lang) {
           'csharp' {
               if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                   $sln = Get-ChildItem -Path . -Filter '*.sln' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
                   if ($sln) {
                       Write-Host "Restoring NuGet packages ($($sln.Name))..." -ForegroundColor Cyan
                       & dotnet restore $sln.FullName --verbosity quiet 2>$null
                   } else {
                       $projs = Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue
                       if ($projs) {
                           Write-Host "Restoring NuGet packages ($($projs.Count) project(s))..." -ForegroundColor Cyan
                           foreach ($p in $projs) { & dotnet restore $p.FullName --verbosity quiet 2>$null }
                       }
                       # No .sln or .csproj -- skip restore; step 7c pre-build will handle .csproj generation
                   }
               }
           }
           'java' {
               if (Test-Path 'pom.xml') {
                   Write-Host "Resolving Maven dependencies..." -ForegroundColor Cyan
                   & mvn dependency:resolve -q 2>$null
               } elseif ((Test-Path 'build.gradle') -or (Test-Path 'build.gradle.kts')) {
                   $gradleCmd = if (Test-Path './gradlew.bat') { '.\gradlew.bat' } elseif (Test-Path './gradlew') { './gradlew' } else { 'gradle' }
                   Write-Host "Resolving Gradle dependencies..." -ForegroundColor Cyan
                   & $gradleCmd dependencies --quiet 2>$null
               }
           }
           'go' {
               if ((Get-Command go -ErrorAction SilentlyContinue) -and (Test-Path 'go.mod')) {
                   Write-Host "Downloading Go modules..." -ForegroundColor Cyan
                   & go mod download 2>$null
               }
           }
           'swift' {
               if ((Get-Command swift -ErrorAction SilentlyContinue) -and (Test-Path 'Package.swift')) {
                   Write-Host "Resolving Swift packages..." -ForegroundColor Cyan
                   & swift package resolve 2>$null
               }
               if ((Get-Command pod -ErrorAction SilentlyContinue) -and (Test-Path 'Podfile')) {
                   Write-Host "Installing CocoaPods..." -ForegroundColor Cyan
                   & pod install 2>$null
               }
           }
           # cpp: no universal restore step — build systems vary widely (CMake, Make, MSBuild, vcpkg, Conan, etc.)
           # Interpreted languages (javascript, python, ruby): no restore needed — CodeQL extracts directly from source
       }
   }
   ```
   Dependency restoration is **best-effort** — failures are silenced (`2>$null`) because CodeQL's autobuild will attempt its own restore/build sequence. The explicit pre-restore ensures dependencies are available on machines where the project has never been built (e.g., fresh clone without `dotnet restore`, or Go modules not yet downloaded). It does NOT fix compilation errors from missing package references or broken source code — those must be fixed in the project before committing.

   **Pre-build validation — fail fast on compilation errors.** After dependency restoration, run a trial build for compiled languages to verify the project actually compiles. This catches build errors in seconds instead of waiting 1+ minutes for CodeQL's multi-strategy autobuild to exhaust all fallbacks. Languages that fail pre-build validation are removed from `$activeLanguages` so CodeQL does not waste time attempting database creation for them:
   ```powershell
   $preBuildFailed = @()
   foreach ($lang in @($activeLanguages)) {
       switch ($lang) {
           'csharp' {
               if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                   $sln = Get-ChildItem -Path . -Filter '*.sln' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
                   $buildTarget = if ($sln) { $sln.FullName } else {
                       $p = Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
                       if ($p) { $p.FullName } else { $null }
                   }
                   if (-not $buildTarget) {
                       # No .sln or .csproj found -- check for loose .cs files and auto-generate
                       # a temporary .csproj so CodeQL's C# extractor can intercept the build.
                       $csFiles = Get-ChildItem -Path . -Filter '*.cs' -Recurse -Depth 5 -ErrorAction SilentlyContinue
                       if ($csFiles -and $csFiles.Count -gt 0) {
                           Write-Host "[AUTO] No .sln or .csproj found -- generating temporary project for $($csFiles.Count) .cs file(s)" -ForegroundColor Cyan
                           # Detect the highest installed .NET SDK major version for TargetFramework
                           $sdkList = & dotnet --list-sdks 2>$null
                           $sdkMajors = $sdkList | ForEach-Object { if ($_ -match '^(\d+)\.') { [int]$Matches[1] } } | Sort-Object -Descending
                           $tfm = if ($sdkMajors) { "net$($sdkMajors[0]).0" } else { 'net8.0' }
                           $tempProjPath = Join-Path (Get-Location) '.codeql-temp-scan.csproj'
                           $projContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$tfm</TargetFramework>
    <OutputType>Library</OutputType>
    <EnableDefaultCompileItems>true</EnableDefaultCompileItems>
    <NoWarn>CS8021;CS0246;CS8019;CS0168;CS0219</NoWarn>
  </PropertyGroup>
</Project>
"@
                           Set-Content -Path $tempProjPath -Value $projContent -Encoding UTF8
                           $tempCsproj = $tempProjPath
                           # Restore packages for the temporary project
                           & dotnet restore $tempProjPath --verbosity quiet 2>$null
                           $buildTarget = $tempProjPath
                           Write-Host "  Temporary project: .codeql-temp-scan.csproj (targeting $tfm)" -ForegroundColor Cyan
                           Write-Host "  This file will be removed after the scan." -ForegroundColor Cyan
                       } else {
                           # No .cs files at all -- nothing for C# to scan
                           Write-Host "[FAIL] No .sln, .csproj, or .cs files found -- skipping C# CodeQL scan" -ForegroundColor Red
                           $preBuildFailed += $lang
                       }
                   } else {
                       Write-Host "Validating C# build..." -ForegroundColor Cyan
                       $buildOutput = & dotnet build $buildTarget --no-restore --verbosity quiet 2>&1 | Out-String
                       if ($LASTEXITCODE -ne 0) {
                           Write-Host "[FAIL] C# project does not build — skipping C# CodeQL scan" -ForegroundColor Red
                           # Parse CS1069 errors: extract forwarded assembly names for targeted guidance
                           $cs1069Matches = [regex]::Matches($buildOutput, "CS1069.*?forwarded to assembly '([^,]+)")
                           if ($cs1069Matches.Count -gt 0) {
                               $missingPkgs = $cs1069Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
                               # Map deprecated packages to their recommended replacements
                               $deprecatedMap = @{
                                   'System.Data.SqlClient'         = 'Microsoft.Data.SqlClient'
                                   'Microsoft.Azure.Storage.Blob'  = 'Azure.Storage.Blobs'
                                   'Microsoft.Azure.Storage.Queue' = 'Azure.Storage.Queues'
                                   'Microsoft.Azure.ServiceBus'    = 'Azure.Messaging.ServiceBus'
                                   'Microsoft.Azure.EventHubs'     = 'Azure.Messaging.EventHubs'
                                   'Microsoft.Azure.KeyVault'      = 'Azure.Security.KeyVault.Secrets'
                               }
                               Write-Host "" -ForegroundColor Yellow
                               Write-Host "Missing package reference(s) detected:" -ForegroundColor Yellow
                               foreach ($pkg in $missingPkgs) {
                                   if ($deprecatedMap.ContainsKey($pkg)) {
                                       $rec = $deprecatedMap[$pkg]
                                       Write-Host "  dotnet add package $rec" -ForegroundColor Yellow
                                       Write-Host "    (replaces deprecated $pkg)" -ForegroundColor DarkYellow
                                   } else {
                                       Write-Host "  dotnet add package $pkg" -ForegroundColor Yellow
                                   }
                               }
                               Write-Host "" -ForegroundColor Yellow
                               Write-Host "Run the command(s) above, then retry the commit." -ForegroundColor Yellow
                           } else {
                               Write-Host "" -ForegroundColor Yellow
                               Write-Host "C# requires a successful build for CodeQL analysis." -ForegroundColor Yellow
                               Write-Host "  1. Verify the project builds:  dotnet build" -ForegroundColor Yellow
                               Write-Host "  2. Fix any compilation errors, then retry the commit." -ForegroundColor Yellow
                           }
                           $preBuildFailed += $lang
                       } else {
                           Write-Host "[PASS] C# build validation OK" -ForegroundColor Green
                           # Auto-resolve .NET SDK compatibility for CodeQL's C# extractor.
                           # CodeQL's extractor intercepts csc.exe during the build. If the SDK is
                           # too new (e.g., .NET 10+), the extractor can't hook the compiler and
                           # database create exits 32 ("detected code but could not process any of it").
                           # Fix: temporarily pin to a compatible SDK via global.json for the scan —
                           # but ONLY if the project's TargetFramework can build with the older SDK.
                           # A project targeting net10.0 cannot build with SDK 9.x (NETSDK1045).
                           $sdkVer = (& dotnet --version 2>$null)
                           $sdkMajor = if ($sdkVer -match '^(\d+)\.') { [int]$Matches[1] } else { 0 }
                           $tempGlobalJson = $false
                           if ($sdkMajor -ge 10 -and -not (Test-Path 'global.json')) {
                               # Check the highest TargetFramework across all .csproj files.
                               # If ANY project targets net<N>.0 where N >= sdkMajor, pinning to
                               # an older SDK would cause NETSDK1045 ("does not support targeting .NET N").
                               $tfmMajor = 0
                               Get-ChildItem -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
                                   Select-Object -ExpandProperty FullName |
                                   ForEach-Object {
                                       $content = Get-Content $_ -Raw -ErrorAction SilentlyContinue
                                       if ($content -match '<TargetFramework[s]?>[^<]*net(\d+)\.\d[^<]*</TargetFramework[s]?>') {
                                           $m = [int]$Matches[1]
                                           if ($m -gt $tfmMajor) { $tfmMajor = $m }
                                       }
                                   }
                               if ($tfmMajor -ge $sdkMajor) {
                                   # Project targets the current SDK's framework (e.g., net10.0 on SDK 10).
                                   # Pinning to an older SDK would break the build. Skip auto-pin.
                                   Write-Host "[WARN] .NET SDK $sdkVer detected -- CodeQL may not support this version yet" -ForegroundColor Yellow
                                   Write-Host "  Project targets net$tfmMajor.0, which requires SDK $sdkMajor.x -- cannot pin to an older SDK." -ForegroundColor Yellow
                                   # Detect the "reinstalled, but current session still resolves old CodeQL" case.
                                   $activeCodeql = (Get-Command codeql -ErrorAction SilentlyContinue).Source
                                   $managedCodeql = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                                       Join-Path $env:LOCALAPPDATA 'CodeQL\codeql\codeql.exe'
                                   } else {
                                       $null
                                   }
                                   if ($managedCodeql -and $activeCodeql -and (Test-Path $managedCodeql) -and ($activeCodeql -ne $managedCodeql)) {
                                       $activeVerText = (& $activeCodeql version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).ToString().Trim()
                                       $managedVerText = (& $managedCodeql version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).ToString().Trim()
                                       $activeMatch = [regex]::Match($activeVerText, '(\d+\.\d+\.\d+)')
                                       $managedMatch = [regex]::Match($managedVerText, '(\d+\.\d+\.\d+)')
                                       if ($activeMatch.Success -and $managedMatch.Success) {
                                           $activeVer = [version]$activeMatch.Groups[1].Value
                                           $managedVer = [version]$managedMatch.Groups[1].Value
                                           if ($managedVer -and $managedVer -gt $activeVer) {
                                               Write-Host "[WARN] CodeQL Vibe already installed newer CodeQL at $managedCodeql, but this session is still using older CodeQL at $activeCodeql" -ForegroundColor Yellow
                                               Write-Host "  Restart VS Code, open a new terminal, run 'codeql version', then retry the commit." -ForegroundColor Yellow
                                           }
                                       }
                                   }
                                   Write-Host "  Re-run CodeQL Vibe setup in VS Code to refresh CodeQL CLI to the latest supported release:" -ForegroundColor Yellow
                                   Write-Host "    Copilot: /speckit.codeql --> Full Setup" -ForegroundColor Cyan
                                   Write-Host "    Claude:  Set up CodeQL" -ForegroundColor Cyan
                                   Write-Host "  If you need to update manually, use:" -ForegroundColor Yellow
                                   Write-Host "    https://github.com/github/codeql-cli-binaries/releases" -ForegroundColor Cyan
                                   Write-Host "  Or install a compatible SDK and retarget the project to net$($sdkMajor - 1).0 for scanning." -ForegroundColor Yellow
                               } else {
                                   # Project targets an older framework (e.g., net8.0/net9.0) but runs
                                   # on a newer SDK. Safe to pin to the older SDK for the scan.
                                   $installed = & dotnet --list-sdks 2>$null
                                   $compatSdk = $installed |
                                       Where-Object { $_ -match '^(8|9)\.\d+\.\d+' } |
                                       ForEach-Object { ($_ -split '\s')[0] } |
                                       Sort-Object { [version]$_ } -Descending |
                                       Select-Object -First 1
                                   if ($compatSdk) {
                                       $compatMajor = ($compatSdk -split '\.')[0]
                                       $pinVersion = "$compatMajor.0.100"
                                       Write-Host "[AUTO] .NET SDK $sdkVer is too new for CodeQL -- pinning to $compatSdk via temporary global.json" -ForegroundColor Cyan
                                       @{ sdk = @{ version = $pinVersion; rollForward = 'latestFeature' } } | ConvertTo-Json | Set-Content 'global.json' -Encoding UTF8
                                       $tempGlobalJson = $true
                                       # Verify the pin took effect
                                       $pinnedVer = (& dotnet --version 2>$null)
                                       Write-Host "  Pinned SDK: $pinnedVer (will be removed after scan)" -ForegroundColor Cyan
                                   } else {
                                       Write-Host "[WARN] .NET SDK $sdkVer detected -- CodeQL may not support this version yet" -ForegroundColor Yellow
                                       Write-Host "  No compatible SDK (8.x or 9.x) found. Install one from: https://dot.net/download" -ForegroundColor Yellow
                                       Write-Host "  Or re-run CodeQL Vibe setup in VS Code to refresh the CLI first:" -ForegroundColor Yellow
                                       Write-Host "    Copilot: /speckit.codeql --> Full Setup" -ForegroundColor Cyan
                                       Write-Host "    Claude:  Set up CodeQL" -ForegroundColor Cyan
                                       Write-Host "  Or add a global.json manually:" -ForegroundColor Yellow
                                       Write-Host '    { "sdk": { "version": "8.0.100", "rollForward": "latestFeature" } }' -ForegroundColor Cyan
                                   }
                               }
                           }
                       }
                   }
               } else {
                   # dotnet CLI not found — build tool detection already warned, but also skip pre-build
                   Write-Host "[FAIL] dotnet CLI not found — skipping C# CodeQL scan" -ForegroundColor Red
                   Write-Host "  Install the .NET SDK: https://dot.net/download" -ForegroundColor Yellow
                   $preBuildFailed += $lang
               }
           }
           'java' {
               if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
                   Write-Host "[FAIL] JDK not found -- skipping Java CodeQL scan" -ForegroundColor Red
                   Write-Host "  Install a JDK: https://adoptium.net" -ForegroundColor Yellow
                   $preBuildFailed += $lang
               } else {
                   $buildCmd = $null
                   if (Test-Path 'pom.xml') {
                       $buildCmd = 'mvn compile -q'
                   } elseif ((Test-Path 'build.gradle') -or (Test-Path 'build.gradle.kts')) {
                       $gc = if (Test-Path './gradlew.bat') { '.\gradlew.bat' } elseif (Test-Path './gradlew') { './gradlew' } else { 'gradle' }
                       $buildCmd = "$gc compileJava --quiet"
                   }
                   if ($buildCmd) {
                       Write-Host "Validating Java build..." -ForegroundColor Cyan
                       Invoke-Expression $buildCmd 2>$null
                       if ($LASTEXITCODE -ne 0) {
                           Write-Host "[FAIL] Java project does not build -- skipping Java CodeQL scan" -ForegroundColor Red
                           Write-Host "  Fix build errors and retry the commit." -ForegroundColor Yellow
                           $preBuildFailed += $lang
                       } else {
                           Write-Host "[PASS] Java build validation OK" -ForegroundColor Green
                       }
                   }
               }
           }
           'go' {
               if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
                   Write-Host "[FAIL] Go toolchain not found -- skipping Go CodeQL scan" -ForegroundColor Red
                   Write-Host "  Install Go: https://go.dev/dl" -ForegroundColor Yellow
                   $preBuildFailed += $lang
               } elseif (Test-Path 'go.mod') {
                   Write-Host "Validating Go build..." -ForegroundColor Cyan
                   & go build ./... 2>$null
                   if ($LASTEXITCODE -ne 0) {
                       Write-Host "[FAIL] Go project does not build -- skipping Go CodeQL scan" -ForegroundColor Red
                       Write-Host "  Fix build errors and retry the commit." -ForegroundColor Yellow
                       $preBuildFailed += $lang
                   } else {
                       Write-Host "[PASS] Go build validation OK" -ForegroundColor Green
                   }
               }
           }
           # cpp and swift: no universal pre-build command — too many build system variations.
           # These rely on CodeQL's autobuild + step 19 guidance on failure.
           # Interpreted languages (javascript, python, ruby): no build step needed.
       }
   }
   # Remove languages that failed pre-build validation
   if ($preBuildFailed) {
       $activeLanguages = $activeLanguages | Where-Object { $_ -notin $preBuildFailed }
       if ($activeLanguages.Count -eq 0) {
           Write-Host "" -ForegroundColor Red
           Write-Host "[FAIL] All detected languages failed pre-build validation." -ForegroundColor Red
           Write-Host "Fix the build errors above, then retry the commit." -ForegroundColor Red
           $scanFailed = $true
           # Fall through to steps 15-18 (cleanup/timing/verdict)
       }
   }
   ```
   Pre-build validation runs only for languages with a reliable, fast build command. C/C++ and Swift are excluded because their build systems are too varied for a generic check — they fall through to CodeQL's autobuild and rely on step 19 guidance if it fails. Interpreted languages (JavaScript, Python, Ruby) need no build step.

   The C# pre-build check specifically parses CS1069 ("type has been forwarded to assembly") errors to extract the exact NuGet package name and print a targeted `dotnet add package <PackageName>` command. Before printing, it checks a deprecated-to-recommended map — if the missing package is deprecated (e.g., `System.Data.SqlClient`), the guidance recommends the actively maintained replacement (`Microsoft.Data.SqlClient`) instead. This prevents developers from adding deprecated dependencies to resolve build errors.

   **Language-specific notes:**
   - **JavaScript/TypeScript, Python, Ruby:** No build or dependency restoration needed. CodeQL extracts directly from source files. (`node_modules` is excluded via `codeql-config.yml` — CodeQL does not need it for extraction.)
   - **C#:** `dotnet restore` fetches NuGet packages. If the `.csproj` is missing a `<PackageReference>`, the restore succeeds but the build fails — that's a project-level fix. If no `.sln` or `.csproj` exists but loose `.cs` files are present, the scan auto-generates a temporary `.codeql-temp-scan.csproj` targeting the highest installed SDK, builds against it, and removes it after the scan.
   - **Java/Kotlin:** Maven and Gradle restore. Prefers the project's Gradle wrapper (`gradlew`/`gradlew.bat`) over a global install for reproducibility.
   - **Go:** `go mod download` fetches module dependencies. CodeQL's Go extractor can also resolve modules itself, but pre-downloading avoids repeated network calls during extraction.
   - **C/C++:** No automated restore — build systems are too varied. The build tool detection warns if no compiler is found.
   - **Swift:** `swift package resolve` for Swift Package Manager projects, `pod install` for CocoaPods. Xcode workspace projects that use neither need no pre-restore (Xcode resolves internally). Swift scanning is macOS-only — the build tool check warns on other platforms.
8. **Run language scans — two phases: create databases, then analyze.**

   The scan is split into two phases for optimal performance:
   - **Phase 1 (create):** Build all databases. For 2+ languages, `--db-cluster` creates them in a single pass (one JVM, one source traversal). For 1 language, a regular `database create` call.
   - **Phase 2 (analyze):** Run queries against each database. For 2+ languages with enough RAM, analyze in parallel (`Start-Job`). Otherwise, analyze sequentially.

   **Phase 1 — Database creation:**

   Skip Phase 1 entirely if `$scanFailed` was already set by pre-build validation (all languages failed). Otherwise, recalculate resource budgeting if `$activeLanguages` changed (languages removed by pre-build validation).
   ```powershell
   if (-not $scanFailed) {
   $createSw = [System.Diagnostics.Stopwatch]::StartNew()
   $createExitCode = 0   # capture for step 19 targeted guidance
   if ($activeLanguages.Count -eq 1) {
       # Single language — regular create
       $language = $activeLanguages[0]
       & codeql database create ".codeql-db/$language" --overwrite --language=$language --source-root=. --codescanning-config=.github/codeql/codeql-config.yml --threads=0 --ram=$ramCreateMB
       $createExitCode = $LASTEXITCODE
       if ($createExitCode -ne 0) {
           Write-Host "[FAIL] database create for $language exited with $createExitCode" -ForegroundColor Red
           $scanFailed = $true
       }
   } else {
       # Multi-language — single-pass cluster creation (one JVM, one source traversal)
       $langList = $activeLanguages -join ','
       & codeql database create .codeql-db --db-cluster --overwrite --language=$langList --source-root=. --codescanning-config=.github/codeql/codeql-config.yml --threads=0 --ram=$ramCreateMB
       $createExitCode = $LASTEXITCODE
       if ($createExitCode -ne 0) {
           Write-Host "[FAIL] database create (cluster) exited with $createExitCode" -ForegroundColor Red
           $scanFailed = $true
       }
   }
   $createSw.Stop()
   if (-not $scanFailed) {
       Write-Host "[PASS] Database creation complete ($(Format-Elapsed $createSw))" -ForegroundColor Green
   }
   }  # end: if (-not $scanFailed) guard from pre-build validation
   ```

   > **Why `--db-cluster`?** Without it, each language spawns a separate `codeql database create` process. Each one boots its own JVM (2–5 seconds) and independently traverses the entire source tree. With `--db-cluster`, a single JVM boot serves all language extractors and the source tree is read once. For a 3-language workspace, this saves ~10 seconds of JVM startup alone, plus the I/O overhead of redundant directory walks.

   **Phase 2 — Query analysis:**

   **Sequential analysis** (1 active language, low RAM, or `-Parallel:$false`):
   ```powershell
   if (-not $scanFailed -and -not $parallelAnalyze) {
       foreach ($language in $activeLanguages) {
           $langSw = [System.Diagnostics.Stopwatch]::StartNew()
           $dbPath = ".codeql-db/$language"
           $sarifFile = ".codeql-results-$language.sarif"

           $suiteLevel = if ($Full) { 'security-and-quality' } else { 'security-extended' }
           $suite = "codeql/${language}-queries:codeql-suites/${language}-${suiteLevel}.qls"
           & codeql database analyze $dbPath --format=sarifv2.1.0 --output=$sarifFile --no-rerun --threads=0 --ram=$ramPerAnalyzeMB $suite
           if ($LASTEXITCODE -ne 0) {
               Write-Host "[FAIL] database analyze for $language exited with $LASTEXITCODE" -ForegroundColor Red
               $scanFailed = $true
               break
           }

           $langSw.Stop()
           Write-Host "[PASS] $language analyze complete ($(Format-Elapsed $langSw))" -ForegroundColor Green
       }
   }
   ```

   > **Important:** The sequential path must NOT call `exit 1` inside the loop — that would skip cleanup (step 15) and bypass the scan lock release. Instead, set a `$scanFailed` flag and `break` out of the loop. Cleanup and exit logic follow after the loop.

   **Query suite resolution:** The `codeql database analyze` command requires **fully-qualified pack paths**, not bare suite names. For pre-commit scans, use `codeql/$lang-queries:codeql-suites/$lang-security-extended.qls` (e.g., `codeql/python-queries:codeql-suites/python-security-extended.qls`). For `-Full` scans, use the broader `security-and-quality` suite. Bare names like `security-extended` will fail with "Query pack cannot be found".

   **`--no-rerun` caching:** This flag tells CodeQL to skip re-evaluating queries whose results are already cached in the database from a previous `database analyze` run. Because the database is rebuilt on every scan (new source snapshot), the cache starts empty and all queries run — this is the correct behavior. The flag only provides a speedup when the same database is analyzed multiple times without a rebuild in between (e.g., running `codeql-scan` manually twice without any code changes). It is harmless to always include.

   **Parallel analysis** (2+ active languages with sufficient RAM, default): Use `Start-Job` to launch each language analysis as a background job. Database creation is already complete — each job only runs `codeql database analyze` for its language. The main script waits for all jobs with `Wait-Job`, then collects results with `Receive-Job`.

   **Parallel analysis implementation:**
   ```powershell
   if (-not $scanFailed -and $parallelAnalyze) {
       $jobs = @()
       foreach ($language in $activeLanguages) {
           $sarifFile = ".codeql-results-$language.sarif"
           $dbPath = ".codeql-db/$language"
           $jobs += Start-Job -Name "codeql-$language" -ScriptBlock {
               param($lang, $db, $sarif, $workDir, $ramMB, $isFull)
               Set-Location $workDir
               $ErrorActionPreference = 'Continue'
               $jobSw = [System.Diagnostics.Stopwatch]::StartNew()

               $suiteLevel = if ($isFull) { 'security-and-quality' } else { 'security-extended' }
               $suite = "codeql/${lang}-queries:codeql-suites/${lang}-${suiteLevel}.qls"
               & codeql database analyze $db --format=sarifv2.1.0 --output=$sarif --no-rerun --threads=0 --ram=$ramMB $suite
               if ($LASTEXITCODE -ne 0) {
                   Write-Output "[FAIL] database analyze for $lang exited with $LASTEXITCODE"
                   exit 1
               }

               $jobSw.Stop()
               $ts = $jobSw.Elapsed
               $elapsed = if ($ts.TotalSeconds -lt 60) { "{0:F1}s" -f $ts.TotalSeconds } else { "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds }
               Write-Output "[PASS] $lang analyze complete ($elapsed)"
           } -ArgumentList $language, $dbPath, $sarifFile, (Get-Location).Path, $ramPerAnalyzeMB, $Full
       }

       # Wait for all jobs to finish (30-minute timeout to prevent hangs)
       $jobs | Wait-Job -Timeout 1800 | Out-Null

       # Separate timed-out jobs from completed ones BEFORE cleanup
       $timedOut = $jobs | Where-Object { $_.State -eq 'Running' }
       $completedJobs = $jobs | Where-Object { $_.State -ne 'Running' }

       if ($timedOut) {
           $timedOut | ForEach-Object {
               $lang = $_.Name -replace '^codeql-', ''
               Write-Host "[FAIL] CodeQL analyze for $lang timed out after 30 minutes" -ForegroundColor Red
               Stop-Job -Job $_ -ErrorAction SilentlyContinue
               Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue
           }
           $scanFailed = $true
       }

       # Always receive+cleanup completed jobs (even after partial timeout — don't leak jobs or lose output)
       foreach ($job in $completedJobs) {
           $output = Receive-Job -Job $job
           $output | ForEach-Object { Write-Host $_ }
           if ($job.State -eq 'Failed' -or ($output -match '\[FAIL\]')) {
               $lang = $job.Name -replace '^codeql-', ''
               Write-Host "[FAIL] CodeQL analyze failed for $lang" -ForegroundColor Red
               $scanFailed = $true
           }
           Remove-Job -Job $job
       }
   }
   # Do NOT exit here — fall through to cleanup, elapsed time, and scan history
   ```

   **Post-scan flow:** After the parallel or sequential path completes, the script follows two branches:
   - **If `$scanFailed` is false:** Run steps 9–14 (SARIF merge, parse, filter, display, open) → then steps 15–18 (cleanup, elapsed time, scan history, verdict).
   - **If `$scanFailed` is true:** **Skip** steps 9–14 entirely (no SARIF files to process) → go straight to steps 15–18 (cleanup, elapsed time, scan history logging with zero findings, then exit 1).

   Steps 15–18 MUST always run regardless of `$scanFailed` — they handle lock release (via `try/finally`), elapsed time reporting, and scan history logging. Guard the SARIF steps:
   ```powershell
   if (-not $scanFailed) {
       # Steps 9-14: merge SARIF, parse, filter, display, open
   }
   # Steps 15-18: cleanup, elapsed time, scan history, exit (always run)
   ```

   **Why parallel analysis is safe:** Database creation is already complete before analysis begins. Each language's `database analyze` reads from its own database directory (`.codeql-db/<language>`) and writes to its own SARIF file (`.codeql-results-<language>.sarif`), so there are no shared resources or write conflicts between jobs. CodeQL CLI itself is stateless across invocations. Cross-instance safety (two terminals running `scan.ps1` simultaneously) is guaranteed by the process-level file lock (step 2) which prevents concurrent scan instances entirely.

   **Performance note:** The two-phase architecture maximizes throughput: database creation uses `--db-cluster` to amortize JVM startup and source traversal across all languages (single pass), then analysis runs in parallel to overlap query evaluation. For single-language workspaces, both phases are a single sequential invocation. `--threads=0` uses all available CPU cores. For analysis, `--ram` is split evenly across parallel jobs (70% of system RAM / job count). If the per-job share falls below 2 GB, analysis falls back to sequential to stay within budget. Machines with less than 8 GB RAM always analyze sequentially.

   **Incremental note:** The incremental behavior works at the **language level**, not the file level. The file-level filtering (step 4) determines which languages have changed files — only those languages get scanned. However, `codeql database analyze` analyzes the full database for each active language, so the raw SARIF may include findings beyond the changed set. **Step 10 post-filters** the SARIF results to retain only findings in changed files (unless `-Full` is passed), so developers see only relevant findings and the scan feels incremental. The language-level optimization avoids scanning languages with no changes at all (e.g., if only Python files changed, JavaScript is skipped entirely).

   This produces per-language SARIF files, e.g.:
   - `.codeql-results-javascript.sarif`
   - `.codeql-results-python.sarif`
   - `.codeql-results-java.sarif`
9. **Normalize per-language SARIF and merge into combined SARIF.** After all language scans complete (all jobs finished successfully), normalize every per-language SARIF file **before** reading, copying, or opening it. This prevents unusual line terminators (`U+2028`, `U+2029`) and stray control characters from reaching the final artifact. The generated script MUST call `Normalize-SarifFile` on each `.codeql-results-<language>.sarif` file first. If any normalized file still cannot be parsed as JSON, mark the scan as failed, skip the open step, and continue to cleanup/history.

   After successful normalization of all per-language files, create `.codeql-results.sarif` by collecting every `runs[]` entry and writing a single SARIF v2.1.0 envelope:
   ```json
   {
     "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
     "version": "2.1.0",
     "runs": [ ...all runs from all per-language files... ]
   }
   ```
   Use the parsed objects returned from `Normalize-SarifFile` to extract `.runs`, merge into a single array, and write with `ConvertTo-Json -Depth 20`. Do NOT use `-Depth 100` — it causes exponential traversal time on large SARIF files. SARIF structure is at most ~15 levels deep; `-Depth 20` captures everything with significantly better performance.

   After writing or copying the combined SARIF, run `Normalize-SarifFile ".codeql-results.sarif"` as a final validation gate. Do not open the file in VS Code unless this validation succeeds.

   **Single-language fast path:** When only one language was scanned, skip the JSON parse/serialize entirely — just copy the per-language file to the combined path:
   ```powershell
   $sarifDocs = @{}
   foreach ($language in $activeLanguages) {
       $sarifPath = ".codeql-results-$language.sarif"
       $sarifDoc = Normalize-SarifFile $sarifPath
       if (-not $sarifDoc) {
           $scanFailed = $true
           break
       }
       $sarifDocs[$language] = $sarifDoc
   }

   if (-not $scanFailed -and $activeLanguages.Count -eq 1) {
       Copy-Item ".codeql-results-$($activeLanguages[0]).sarif" ".codeql-results.sarif" -Force
       if (-not (Normalize-SarifFile ".codeql-results.sarif")) {
           $scanFailed = $true
       }
   }
   ```
   This avoids an unnecessary full merge for single-language scans while still guaranteeing that both the per-language file and the combined file are normalized and parseable. Only perform the full merge when 2+ languages have results.

   **Multi-language merge path:**
   ```powershell
   if (-not $scanFailed -and $activeLanguages.Count -gt 1) {
       $allRuns = @()
       foreach ($language in $activeLanguages) {
           $allRuns += @($sarifDocs[$language].runs)
       }

       @{
           '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
           version = '2.1.0'
           runs = $allRuns
       } | ConvertTo-Json -Depth 20 | Set-Content '.codeql-results.sarif' -Encoding UTF8

       if (-not (Normalize-SarifFile '.codeql-results.sarif')) {
           $scanFailed = $true
       }
   }
   ```
10. **Parse and filter the combined SARIF.** First, if the scan is incremental (not `-Full`), post-filter results to retain only findings whose `physicalLocation.artifactLocation.uri` matches a file in the changed file list (from step 3). Build a `[System.Collections.Generic.HashSet[string]]` from the changed file list for O(1) lookups — do NOT use `$changedFiles -contains $file` which is O(n) per result and becomes slow when there are many findings or many changed files. Normalize backslashes to forward slashes so paths match SARIF URIs:
   ```powershell
   $changedFileSet = [System.Collections.Generic.HashSet[string]]::new(
       [StringComparer]::OrdinalIgnoreCase)
   foreach ($f in $changedFiles) {
       $changedFileSet.Add(($f -replace '\\', '/')) | Out-Null
   }
   ```
   **Critical:** wrap `-replace` expressions in parentheses when passing to `.Add()` or any .NET method — without them, PowerShell treats the comma as an argument separator, not as part of the `-replace` operator.

   This ensures developers see only findings relevant to their changes, not the entire codebase. For `-Full` scans, skip filtering and report all findings.

   For each remaining result across all runs:
   - Read `properties.security-severity` (float) and `level` from the SARIF.
   - Classify: `security-severity >= 9.0` = **Critical**, `>= 7.0` = **High**, `>= 4.0` = **Medium**, `< 4.0` = **Low**. If no `security-severity` property: `error` = **Medium**, `warning` = **Low**, `note`/`none` = **Informational**.
11. Print a per-language breakdown header, then a **combined** summary table grouped by severity:
   ```
   -- javascript: 2 findings --
   -- python: 1 finding --

   +----------+----------+-----------+------------------------+------+---------------------------+
   | Severity | Language | Rule ID   | File                   | Line | Message                   |
   +----------+----------+-----------+------------------------+------+---------------------------+
   | CRITICAL | js       | js/sql-in | src/db.js              | 42   | SQL injection from ...    |
   | HIGH     | python   | py/cmd-in | app/run.py             | 17   | Command injection ...     |
   | LOW      | js       | js/unused | src/utils.js           | 7    | Unused variable           |
   +----------+----------+-----------+------------------------+------+---------------------------+
   ```
12. Print severity breakdown: `Critical: N | High: N | Medium: N | Low: N | Info: N`
13. Print per-language SARIF file locations:
    ```
    Per-language results:
       .codeql-results-javascript.sarif
       .codeql-results-python.sarif
    Combined results: .codeql-results.sarif
    ```
14. **Open the combined SARIF in VS Code.** Run:
    ```powershell
    code .codeql-results.sarif
    ```
    This opens the file in the active VS Code window. The SARIF Viewer extension will automatically render it with inline annotations. If `code` is not available, skip this step silently (don't fail the scan over it).
15. **Cleanup:** Keep `.codeql-db/` (databases are rebuilt on every scan but the `--no-rerun` query cache inside them is reused if the developer runs a manual scan without code changes). **Keep** all `.sarif` files. To reclaim disk space, developers can delete `.codeql-db/` manually — it will be rebuilt on the next scan. **Remove the temporary `global.json`** if one was created for SDK compatibility in step 7c (the `try/finally` block handles this). **Remove the temporary `.codeql-temp-scan.csproj`** if one was created for buildless C# scanning in step 7c. Cleanup of temporary files (if any) MUST happen before the exit statement so it runs regardless of pass/fail.
16. **Print total scan elapsed time:**
    ```powershell
    $scanStopwatch.Stop()
    $endTime = Get-Date
    Write-Host ""
    Write-Host "Started at:  $(Format-Timestamp $startTime)" -ForegroundColor Cyan
    Write-Host "Finished at: $(Format-Timestamp $endTime)" -ForegroundColor Cyan
    Write-Host "Elapsed:     $(Format-Elapsed $scanStopwatch)" -ForegroundColor Cyan
    ```
    These lines print immediately before the pass/fail verdict so the user always sees the timing.
17. **Verdict:** Check `$scanFailed` first — if true, print red `"[FAIL] CodeQL scan failed (see errors above)"` and exit 1 (fail-closed, regardless of finding counts). Otherwise, if any Critical, High, or Medium findings: print red `"[FAIL] COMMIT BLOCKED"` with the blocking findings listed, exit 1.
18. **If only Low/Info or no findings** (and `$scanFailed` is false): print green `"[PASS] CodeQL scan passed"`, exit 0.
19. **Error handling**: If any CodeQL command fails for any language, the scan follows the `$scanFailed` path: steps 9–14 are skipped, then steps 15–18 run (cleanup, elapsed time, scan history with zero findings, verdict exit 1). A failure in one language scan blocks the commit even if other languages passed.

    For **database creation failures**, append actionable guidance after the `[FAIL]` line so developers can diagnose the issue outside of CodeQL:
    ```powershell
    $guidanceLangs = @('csharp', 'java', 'cpp', 'go', 'swift')
    if ($language -in $guidanceLangs) {
        Write-Host "" -ForegroundColor Yellow
        switch ($language) {
            'csharp' {
                # Check environment to provide targeted guidance (codeql output is not captured)
                $hasDotnet = Get-Command dotnet -ErrorAction SilentlyContinue
                $hasProject = (Get-ChildItem -Path . -Filter '*.sln' -Depth 0 -ErrorAction SilentlyContinue) -or
                              (Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue)
                if (-not $hasDotnet) {
                    Write-Host "The .NET SDK (dotnet CLI) was not found on PATH." -ForegroundColor Yellow
                    Write-Host "  Install it from: https://dot.net/download" -ForegroundColor Yellow
                } elseif (-not $hasProject) {
                    Write-Host "No .sln or .csproj found in the repo (searched depth 3)." -ForegroundColor Yellow
                    Write-Host "  If .cs files exist, the scan should have auto-generated a temporary .csproj." -ForegroundColor Yellow
                    Write-Host "  If this error persists, create a project file:  dotnet new classlib" -ForegroundColor Yellow
                    Write-Host "  Or if the project file is deeper, run the scan from that directory." -ForegroundColor Yellow
                } elseif ($createExitCode -eq 32) {
                    # Exit code 32 = "detected code but could not process any of it"
                    # The build succeeded (autobuild exit 0) but the C# extractor could not
                    # intercept compiler calls — usually a .NET SDK version newer than CodeQL supports.
                    # Two sub-cases:
                    #   a) Project targets net10.0+ on SDK 10+ → can't pin to older SDK (NETSDK1045)
                    #   b) Project targets net8.0/9.0 on SDK 10+ but no compatible SDK installed
                    $sdkVer = (& dotnet --version 2>$null)
                    Write-Host "The C# project builds successfully, but CodeQL could not process the compiler output." -ForegroundColor Yellow
                    Write-Host "  .NET SDK $sdkVer is newer than CodeQL's C# extractor supports." -ForegroundColor Yellow
                    Write-Host "" -ForegroundColor Yellow
                    if ($tempGlobalJson) {
                        Write-Host "  The scan pinned to an older SDK via temporary global.json, but the" -ForegroundColor Yellow
                        Write-Host "  extractor still failed. Update CodeQL CLI to a version that supports" -ForegroundColor Yellow
                        Write-Host "  .NET SDK $sdkVer :" -ForegroundColor Yellow
                    } else {
                        Write-Host "  The scan could not auto-pin to an older SDK (the project's target" -ForegroundColor Yellow
                        Write-Host "  framework requires SDK $sdkVer). Update CodeQL CLI to a version" -ForegroundColor Yellow
                        Write-Host "  that supports this SDK:" -ForegroundColor Yellow
                    }
                    Write-Host "    https://github.com/github/codeql-cli-binaries/releases" -ForegroundColor Cyan
                    Write-Host "" -ForegroundColor Yellow
                    Write-Host "  Or install a compatible .NET SDK alongside your current one:" -ForegroundColor Yellow
                    Write-Host "    winget install Microsoft.DotNet.SDK.9" -ForegroundColor Cyan
                    Write-Host "  and retarget the project to net9.0 if possible." -ForegroundColor Yellow
                } else {
                    Write-Host "C# requires a successful dotnet build for CodeQL analysis." -ForegroundColor Yellow
                    Write-Host "  1. Verify the project builds:  dotnet build" -ForegroundColor Yellow
                    Write-Host "  2. If packages are missing:    dotnet add package <PackageName>" -ForegroundColor Yellow
                    Write-Host "     (Check build output for CS1069 -- the assembly name is the package)" -ForegroundColor Yellow
                    Write-Host "  3. If the SDK is missing:      https://dot.net/download" -ForegroundColor Yellow
                }
            }
            'java' {
                Write-Host "Java requires a successful build for CodeQL analysis." -ForegroundColor Yellow
                Write-Host "  Maven:   mvn compile" -ForegroundColor Yellow
                Write-Host "  Gradle:  gradle build" -ForegroundColor Yellow
                Write-Host "  If the JDK is missing: https://adoptium.net" -ForegroundColor Yellow
            }
            'cpp' {
                Write-Host "C/C++ requires a successful build for CodeQL analysis." -ForegroundColor Yellow
                Write-Host "  Verify your build command works: make / cmake --build . / msbuild" -ForegroundColor Yellow
            }
            'go' {
                Write-Host "Go requires module resolution for CodeQL analysis." -ForegroundColor Yellow
                Write-Host "  1. Verify modules resolve:  go mod download" -ForegroundColor Yellow
                Write-Host "  2. Verify the code builds:  go build ./..." -ForegroundColor Yellow
                Write-Host "  3. If Go is missing:        https://go.dev/dl" -ForegroundColor Yellow
            }
            'swift' {
                Write-Host "Swift requires macOS with Xcode for CodeQL analysis." -ForegroundColor Yellow
                Write-Host "  1. Verify the project builds:  xcodebuild -scheme <Scheme>" -ForegroundColor Yellow
                Write-Host "  2. For SPM projects:           swift build" -ForegroundColor Yellow
                Write-Host "  3. If Xcode is missing:        Install from the App Store" -ForegroundColor Yellow
            }
        }
        Write-Host "Fix any build errors, then retry the commit." -ForegroundColor Yellow
    }
    ```
    This guidance prints inside the `$scanFailed` block before falling through to steps 15-18 (cleanup/timing/verdict). It does NOT replace the `[FAIL]` message -- it supplements it with next steps.

Use colorized output via `Write-Host` with `-ForegroundColor`.

**CRITICAL — PowerShell stderr handling:** CodeQL writes progress and diagnostic messages to stderr. PowerShell treats stderr output from native commands as `ErrorRecord` objects, causing spurious `NativeCommandError` exceptions even when the command succeeds. The generated `scan.ps1` MUST handle this by:

1. Setting `$ErrorActionPreference = 'Continue'` at the top of the script so stderr lines are displayed but do not terminate execution.
2. **Never** using `2>&1` redirection on `codeql` commands. Instead, let stderr flow naturally to the console and check `$LASTEXITCODE` after each `codeql` invocation to determine success or failure.
3. After each `codeql database create` and `codeql database analyze` call, check:
   ```powershell
   if ($LASTEXITCODE -ne 0) {
       Write-Host "[FAIL] CodeQL failed for $language (exit code $LASTEXITCODE)" -ForegroundColor Red
       $scanFailed = $true; break
   }
   ```
   **Do NOT use `exit 1` here** — that would bypass the `try/finally` block, leaking the scan lock and orphaning parallel jobs. Always set `$scanFailed = $true` and `break` out of the loop, then let the `finally` block handle cleanup.
4. Do NOT wrap `codeql` calls in `try/catch` — native executables do not throw PowerShell exceptions. Only `$LASTEXITCODE` is reliable.

### 5c. Create the Hooks Directory and Pre-Commit Hook

Create `.github/codeql/hooks/pre-commit` (a shell/PowerShell polyglot or OS-appropriate script) that:

```bash
#!/bin/sh
# CodeQL pre-commit hook - non-bypassable security scan
# Use pwsh (PowerShell Core) on macOS/Linux; fall back to powershell (Windows)
if command -v pwsh >/dev/null 2>&1; then
  pwsh -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/scan.ps1"
else
  powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/scan.ps1"
fi
exit $?
```

> **Note:** On macOS and Linux, PowerShell Core installs as `pwsh`, not `powershell`. The hook tries `pwsh` first and falls back to `powershell` for Windows compatibility.

On Windows, if PowerShell is the shell, the hook should work via Git's MINGW layer which runs shell scripts, OR create a parallel `.github/codeql/hooks/pre-commit.ps1` that Git for Windows can invoke. That `.ps1` hook must also invoke the scan script with `powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/scan.ps1"`.

### 5d. Create the Git Wrapper (Bypass Prevention)

Create **two** wrapper scripts — one for PowerShell, one for bash/zsh — so bypass prevention works on all platforms.

#### PowerShell wrapper: `.github/codeql/git-secure.ps1`

```powershell
# CodeQL bypass prevention wrapper for PowerShell
# Strips --no-verify and -n flags from git commit commands
param([Parameter(ValueFromRemainingArguments)]$gitArgs)

$ErrorActionPreference = 'Continue'

# Find the real git executable (not this wrapper)
$realGit = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
if (-not $realGit) { $realGit = 'git.exe' }

$cleaned = @()
$stripped = $false
$isCommit = $false

foreach ($arg in $gitArgs) {
    if ($arg -eq 'commit' -and -not $isCommit) {
        $isCommit = $true
        $cleaned += $arg
    }
    elseif ($isCommit -and $arg -eq '--no-verify') {
        $stripped = $true
    }
    elseif ($isCommit -and $arg -match '^-[a-zA-Z]*n[a-zA-Z]*$') {
        # Combined short flags containing -n (e.g., -an, -nm, -anm)
        $stripped = $true
        $remainder = $arg -replace 'n', ''
        if ($remainder -ne '-') {
            $cleaned += $remainder
        }
    }
    else {
        $cleaned += $arg
    }
}

if ($stripped) {
    Write-Host "[WARN] --no-verify is disabled. CodeQL security scan cannot be bypassed." -ForegroundColor Yellow
}

& $realGit @cleaned
exit $LASTEXITCODE
```

#### Bash/zsh wrapper: `.github/codeql/git-secure.sh`

Create `.github/codeql/git-secure.sh` for macOS/Linux users:

```bash
#!/usr/bin/env bash
# CodeQL bypass prevention wrapper for bash/zsh
# Strips --no-verify and -n flags from git commit commands

# command -v is a shell builtin (no process spawns); which -a | grep | head spawns 3 processes per invocation
REAL_GIT=$(command -v git)
if [ -z "$REAL_GIT" ]; then
  REAL_GIT=/usr/bin/git
fi

ARGS=()
STRIPPED=false
IS_COMMIT=false

for arg in "$@"; do
  if [ "$arg" = "commit" ] && [ "$IS_COMMIT" = false ]; then
    IS_COMMIT=true
    ARGS+=("$arg")
  elif [ "$IS_COMMIT" = true ] && [ "$arg" = "--no-verify" ]; then
    STRIPPED=true
  elif [ "$IS_COMMIT" = true ] && [[ "$arg" =~ ^-[a-zA-Z]*n[a-zA-Z]*$ ]]; then
    # Combined short flags containing -n (e.g., -an, -nm, -anm)
    # Use bash parameter expansion (no process spawns) instead of echo | sed
    CLEANED="${arg//n/}"
    STRIPPED=true
    if [ "$CLEANED" != "-" ]; then
      ARGS+=("$CLEANED")  # Keep remaining flags (e.g., -an -> -a)
    fi
  else
    ARGS+=("$arg")
  fi
done

if [ "$STRIPPED" = true ]; then
  echo "[WARN] --no-verify is disabled. CodeQL security scan cannot be bypassed."
fi

"$REAL_GIT" "${ARGS[@]}"
exit $?
```

Make it executable: `chmod +x .github/codeql/git-secure.sh`

### 5e. Create the Installer

Create `.github/codeql/install.ps1` — the **single-command bootstrapper** that handles the complete setup. This script is used both by the agent (Phase 2) and by teammates after cloning. Every step prints `[PASS]`/`[FAIL]` status. Any critical failure stops the script immediately (fail-closed).

**install.ps1 execution flow (parallelized):**

```
$startTime = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "Installation started at $($startTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))" -ForegroundColor Cyan

── Sequential gate ─────────────────────────────────────
0. File validation                — syntax, encoding, config checks (auto-fix once)
1. CodeQL CLI         (Step 2)   — detect/install (MUST complete first)

── Parallel batch (Start-Job) ──────────────────────────  ← no shared state
   2a. SARIF Viewer        (Step 3)  — code --install-extension (non-blocking)
   2b. .gitignore          (Step 8)  — append exclusions
   2c. Hooks + profile     (Step 6)  — core.hooksPath + git wrapper + alias
── Wait-Job ─────────────────────────────────────────────

── Sequential gate ─────────────────────────────────────
3. Validation         (Step 7)   — verify everything works
4. Summary                        — files, timing
```

**Why this is safe:** Steps 2a–2c touch **completely disjoint resources** — no two steps read or write the same file, git config key, or environment variable:

| Step | Reads | Writes |
|---|---|---|
| 2a. SARIF Viewer | `code` CLI PATH lookup | VS Code extension dir, `.vscode/extensions.json` |
| 2b. .gitignore | `.gitignore` | `.gitignore` |
| 2c. Hooks + profile | `.git/hooks/pre-commit` | `.git/config` (core.hooksPath), `$PROFILE` or `~/.bashrc`/`~/.zshrc` |

No two steps share a write target → no race conditions. Each job captures its own output; the main script collects results after `Wait-Job`.

**Parallel implementation pattern:**

```powershell
# After CodeQL CLI is confirmed on PATH:
$scriptRoot = $PSScriptRoot
# Capture $PROFILE before Start-Job ($PROFILE is $null inside jobs).
# $PROFILE can also be $null in embedded/CI hosts — compute a fallback.
$profilePath = $PROFILE
if (-not $profilePath) {
    $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell' 'Microsoft.PowerShell_profile.ps1'
}
$jobs = @()

$jobs += Start-Job -Name "codeql-sarif" -ScriptBlock {
    # 2a. SARIF Viewer (independent — talks to VS Code, not git)
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if ($codeCmd) {
        & code --install-extension "MS-SarifVSCode.sarif-viewer" --force 2>&1
    }
}

$jobs += Start-Job -Name "codeql-gitignore" -ScriptBlock {
    # 2b. .gitignore (only file that touches .gitignore)
    Set-Location $using:scriptRoot/..
    # ... append entries if not present
}

$jobs += Start-Job -Name "codeql-hooks" -ScriptBlock {
    # 2c. Hooks + profile (touches .git/config and shell profile — no overlap with above)
    Set-Location $using:scriptRoot/..
    $prof = $using:profilePath   # $PROFILE is $null inside Start-Job — use captured value
    # ... git core.hooksPath setup always runs (does not need $prof)
    # ... profile snippet: guard all profile operations with $prof null check:
    if ($prof) {
        # ... backup, profile snippet (use $prof instead of $PROFILE)
    } else {
        Write-Host "[WARN] Could not determine PowerShell profile path -- skipping profile setup" -ForegroundColor Yellow
        Write-Host "       Run install.ps1 from a regular PowerShell terminal to enable the codeql-scan alias" -ForegroundColor Yellow
    }
}

# Wait for all parallel jobs (30-second timeout — these are lightweight operations)
$completed = $jobs | Wait-Job -Timeout 30
# Handle timed-out jobs (still running after 30s)
$timedOut = $jobs | Where-Object { $_.State -eq 'Running' }
if ($timedOut) {
    $timedOut | Stop-Job
    Write-Host "[WARN] Parallel batch timed out -- falling back to sequential" -ForegroundColor Yellow
    # Re-run timed-out steps sequentially (omitted for brevity — same logic as fallback path)
}
$failed = $jobs | Where-Object { $_.State -eq 'Failed' }
if ($failed) {
    $failed | ForEach-Object { Write-Host "[FAIL] $($_.Name): $(Receive-Job $_ 2>&1)" -ForegroundColor Red }
}
# Clean up all jobs (timed-out jobs were stopped above but not yet removed)
$jobs | Remove-Job -Force -ErrorAction SilentlyContinue
```

**Fallback:** If `Start-Job` is unavailable (constrained language mode, minimal PowerShell hosts), fall back to sequential execution of steps 2a–2c. The script MUST detect this and proceed without error:

```powershell
$canParallelize = $true
try { $null = Start-Job -ScriptBlock { 1 }; Get-Job | Remove-Job -Force } catch { $canParallelize = $false }
```

**Performance impact:** On a typical machine, the parallel batch completes in ~2–4 seconds (dominated by `code --install-extension` discovery). Sequential execution takes ~5–10 seconds for the same steps. The CodeQL CLI download (step 1) is the true bottleneck at ~30–60 seconds on first install.

**Partial-failure state tracking:** install.ps1 tracks the completion status of each step so that if it fails mid-execution, the `finally` block can print a diagnostic summary showing what completed and what didn't. This prevents the developer from being left in a half-installed state with no guidance:

```powershell
$installState = [ordered]@{
    'File validation'   = 'not-started'
    'CodeQL CLI'        = 'not-started'
    'SARIF Viewer'      = 'not-started'
    '.gitignore'        = 'not-started'
    'Hooks + profile'   = 'not-started'
    'Validation'        = 'not-started'
}
try {
    # ... all installation logic (steps 0-3) ...
    # Mark each step as 'done' or 'failed' after it completes
} finally {
    $incomplete = $installState.GetEnumerator() | Where-Object { $_.Value -ne 'done' }
    if ($incomplete) {
        Write-Host "" -ForegroundColor Red
        Write-Host "[PARTIAL] Installation did not complete. Status:" -ForegroundColor Red
        foreach ($step in $installState.GetEnumerator()) {
            $color = switch ($step.Value) { 'done' { 'Green' } 'failed' { 'Red' } default { 'Yellow' } }
            $icon = switch ($step.Value) { 'done' { '[PASS]' } 'failed' { '[FAIL]' } default { '[SKIP]' } }
            Write-Host "  $icon $($step.Key)" -ForegroundColor $color
        }
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Re-run install.ps1 to retry. Completed steps will be detected and skipped." -ForegroundColor Yellow
    }
}
```

The state map is an `[ordered]` hashtable so the output matches the execution order. Each step sets its value to `'done'` on success or `'failed'` on error before the script terminates. The `finally` block runs even on `exit 1`, `Ctrl+C`, or unhandled exceptions — so the developer always sees where things stopped. On a clean run (all steps `'done'`), the partial-failure block is silent — only the normal completion summary prints.

#### 0. File validation (implements Step 5g)

The first thing install.ps1 does (after recording the start time) is validate all generated files. This catches agent-generated file errors before any installation work begins, and runs automatically for teammate onboarding too. install.ps1 cannot validate its own syntax (if it runs, it's syntactically valid), so it validates all OTHER generated files:

```powershell
# Validate all .ps1 files EXCEPT install.ps1 itself (which is already running)
$allPassed = $true
Get-ChildItem ".github/codeql/*.ps1" | Where-Object { $_.Name -ne 'install.ps1' } | ForEach-Object {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$null, [ref]$errors
    )
    if ($errors.Count -gt 0) {
        $allPassed = $false
        Write-Host "[FAIL] Syntax errors in $($_.Name):" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  Line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    } else {
        Write-Host "[PASS] $($_.Name) syntax OK" -ForegroundColor Green
    }
    # Encoding validation (in the same loop — no second file pass)
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $nonAsciiCount = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAsciiCount++ } }
    if ($nonAsciiCount -gt 0) {
        $allPassed = $false
        Write-Host "[FAIL] $($_.Name) contains $nonAsciiCount non-ASCII bytes" -ForegroundColor Red
    } else {
        Write-Host "[PASS] $($_.Name) encoding OK (ASCII)" -ForegroundColor Green
    }
}
```

Also validate (in the same block):
- **`codeql-config.yml`**: Text-based checks — confirm the file is not empty, starts with `name:`, and contains `paths-ignore:` (use `Select-String` or regex). Must NOT contain a `queries:` section — if one is found, remove it and warn.
- **`.github/codeql/hooks/pre-commit`**: Confirm it starts with `#!/bin/sh` and contains the `scan.ps1` invocation.

If **any** file fails validation, **auto-fix once** and re-validate:
- **Syntax errors**: The script cannot regenerate agent-generated files. Print `[FAIL]` with details and exit 1. When the agent runs install.ps1, it reads this output, fixes the file, and re-runs.
- **Non-ASCII bytes**: Re-encode the file as ASCII (replace non-ASCII with substitutes). Re-run the encoding check.
- **Empty or malformed config**: Print `[FAIL]` and exit 1.

If a file still fails after one auto-fix attempt, **STOP** (exit 1) and report the persistent errors. Do NOT proceed to step 1 with broken files.

#### 1. CodeQL CLI (implements Step 2)

Check if `codeql` is on PATH (`Get-Command codeql -ErrorAction SilentlyContinue`). If already installed, print `[PASS] CodeQL CLI vX.Y.Z` and skip to the parallel batch. Otherwise, detect OS and install using the same logic specified in Step 2 (URL validation, SHA-256 hash, platform-specific extraction). After installation, verify with `codeql version`. If the install fails after all fallback methods, print the download URL and exit 1.

**This step MUST complete before the parallel batch starts** — the hooks and profile configured in steps 2a–2c invoke CodeQL, so the CLI must be on PATH first.

#### 2a. SARIF Viewer (implements Step 3) — parallel

Install `MS-SarifVSCode.sarif-viewer` via `code --install-extension ... --force`. If `code` is not on PATH, try the platform-specific full path (see Step 3). If the extension install fails or `code` is unavailable, print `[INFO] SARIF Viewer skipped — install manually from VS Code marketplace` and continue (non-blocking). Also ensure `.vscode/extensions.json` contains the recommendation (merge into existing if present).

> **Note:** When the agent runs install.ps1 during Phase 2, the agent SHOULD also install the SARIF Viewer via the IDE's extension install API (preferred method) — the CLI fallback in install.ps1 covers teammate onboarding and headless environments.

#### 2b. .gitignore (implements Step 8) — parallel

Append the CodeQL exclusion entries (`.codeql-db/`, `.codeql-results.sarif`, etc.) to `.gitignore` if not already present. See Step 8 for the full list.

#### 2c. Hooks + profile (implements Step 6) — parallel

This is the hook and profile setup logic:

1. Back up existing `.git/hooks/pre-commit` to `.git/hooks/pre-commit.backup` if it exists.
2. Ensure `.github/codeql/hooks/pre-commit` exists and is executable (`chmod +x` on macOS/Linux). Since `core.hooksPath` will point to `.github/codeql/hooks/`, the file is already in its final location — no copy is needed.
3. Set `git config core.hooksPath .github/codeql/hooks` so hooks are in a controlled directory that can be committed to the repo.
4. Create a PowerShell profile snippet or shell alias that intercepts **only `git commit`** commands and delegates them to the appropriate git-secure wrapper. **Non-commit** git commands (`status`, `log`, `diff`, `push`, etc.) MUST go directly to the real `git` executable with zero overhead — do NOT call `rev-parse` or the wrapper script for them. For `commit` commands, the wrapper MUST resolve the repo root dynamically (via `git rev-parse --show-toplevel`) so it works from any subdirectory — do NOT use a hard-coded relative path like `.github/codeql/git-secure.ps1`. If the current directory is not inside a repo with `.github/codeql/`, the function must fall through to the real `git` executable.
   - **Windows (PowerShell):** Ensure the `$PROFILE` parent directory exists (it may not on fresh PowerShell installations). **Back up the profile** before any modification so the uninstaller has a safety net if marker-based removal fails.

     **IMPORTANT:** `$PROFILE` is `$null` inside `Start-Job` (jobs run with `-NoProfile`), and can also be `$null` in embedded or CI host environments. The parent script must capture `$profilePath` with a fallback before launching jobs, and the job must use `$prof = $using:profilePath`. All code below uses `$prof` (the captured value), not `$PROFILE` directly.

     **Null guard (parent scope, before Start-Job):**
     ```powershell
     $profilePath = $PROFILE
     if (-not $profilePath) {
         $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell' 'Microsoft.PowerShell_profile.ps1'
     }
     ```

     **Null guard (inside job):** All profile operations below MUST be wrapped in `if ($prof) { ... }`. If `$prof` is still null (e.g., `GetFolderPath` returned empty on a service account), skip profile setup with a warning:
     ```powershell
     $prof = $using:profilePath
     if (-not $prof) {
         Write-Host "[WARN] Could not determine PowerShell profile path -- skipping profile setup" -ForegroundColor Yellow
         Write-Host "       Run install.ps1 from a regular PowerShell terminal to enable the codeql-scan alias" -ForegroundColor Yellow
         return   # exit this job's script block; hooks still work via core.hooksPath
     }
     # $prof is confirmed non-null -- proceed with profile operations
     $profileDir = Split-Path $prof
     if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
     # Safety backup of entire profile (one-time, before first modification)
     if ((Test-Path $prof) -and -not (Test-Path "$prof.pre-codeql")) {
         Copy-Item $prof "$prof.pre-codeql"
     }
     # Idempotency: remove existing CodeQL Vibe block before re-writing (prevents duplicates on re-install)
     if (Test-Path $prof) {
         $content = Get-Content $prof -Raw
         if ($content -match '# --- CodeQL Vibe start ---') {
             $content = $content -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\r?\n?', ''
             Set-Content $prof $content -Encoding UTF8
         }
     }
     ```
     All profile insertions (git wrapper + codeql-scan alias) MUST be wrapped in boundary markers:
     ```powershell
     # --- CodeQL Vibe start ---
     function git {
         # Only intercept 'commit' -- all other commands go straight to git.exe (no rev-parse overhead)
         if ($args.Count -gt 0 -and $args[0] -eq 'commit') {
             $repoRoot = & git.exe rev-parse --show-toplevel 2>$null
             if ($repoRoot -and (Test-Path "$repoRoot/.github/codeql/git-secure.ps1")) {
                 & powershell -ExecutionPolicy Bypass -NoProfile -File "$repoRoot/.github/codeql/git-secure.ps1" @args
                 return
             }
         }
         & git.exe @args
     }
     # --- CodeQL Vibe end ---
     ```
   - **macOS/Linux (bash/zsh):** Add a function `git` to `~/.bashrc` and/or `~/.zshrc` wrapped in the same boundary markers. **Before writing, check if the markers already exist** — if they do, remove the existing block first (same idempotency pattern as Windows). **Back up each rc file** before first modification:
     ```bash
     # Safety backup of shell profiles (one-time, before first modification)
     for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
         [ -f "$rc" ] && [ ! -f "$rc.pre-codeql" ] && cp "$rc" "$rc.pre-codeql"
     done
     # Idempotency: remove existing CodeQL Vibe block before re-writing
     for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
         [ -f "$rc" ] && sed -i.bak '/# --- CodeQL Vibe start ---/,/# --- CodeQL Vibe end ---/d' "$rc" && rm -f "$rc.bak"
     done
     ```
     Then append the block:
     ```bash
     # --- CodeQL Vibe start ---
     git() {
         # Only intercept 'commit' -- all other commands go straight to git (no rev-parse overhead)
         if [ "$1" = "commit" ]; then
             local repo_root
             repo_root=$(command git rev-parse --show-toplevel 2>/dev/null)
             if [ -n "$repo_root" ] && [ -x "$repo_root/.github/codeql/git-secure.sh" ]; then
                 "$repo_root/.github/codeql/git-secure.sh" "$@"
                 return $?
             fi
         fi
         command git "$@"
     }
     # --- CodeQL Vibe end ---
     ```
   - Detect the OS via `$PSVersionTable.Platform` or `$IsWindows`/`$IsLinux`/`$IsMacOS` and install the appropriate wrapper.
   - **Auto-reload** the profile in the current session so the wrapper takes effect immediately:
     - **Windows (PowerShell):** Run `. $PROFILE` after writing the snippet. If `$PROFILE` doesn't exist yet (the installer just created it), this is a no-op — the function is already defined in the current session.
     - **macOS/Linux:** The installer runs under `pwsh`, which cannot source `~/.bashrc` or `~/.zshrc` into the user's calling shell. The bash/zsh wrapper function will take effect in **new** terminal windows automatically. The pre-commit hook (via `core.hooksPath`) works immediately regardless — bypass prevention is the only feature that requires the wrapper.
   - Do NOT ask the user to manually restart their terminal. On Windows the auto-reload handles the current session. On macOS/Linux, inform the user that the bypass-prevention wrapper will activate in new terminals, while the pre-commit hook is active immediately.
5. **Register convenience aliases** so developers don't need to type the full `powershell -ExecutionPolicy Bypass ...` command:
   - **Windows (PowerShell):** Add inside the same `# --- CodeQL Vibe start/end ---` markers block in `$PROFILE` (alongside the git wrapper):
     ```powershell
     function codeql-scan {
         $repoRoot = & git.exe rev-parse --show-toplevel 2>$null
         if ($repoRoot -and (Test-Path "$repoRoot/.github/codeql/scan.ps1")) {
             & powershell -ExecutionPolicy Bypass -NoProfile -File "$repoRoot/.github/codeql/scan.ps1" @args
         } else {
             Write-Host "[FAIL] Not in a CodeQL-enabled repository" -ForegroundColor Red
         }
     }
     ```
   - **macOS/Linux (bash/zsh):** Add inside the same `# --- CodeQL Vibe start/end ---` markers block in `~/.bashrc` and/or `~/.zshrc`:
     ```bash
     codeql-scan() {
         local repo_root
         repo_root=$(command git rev-parse --show-toplevel 2>/dev/null)
         if [ -n "$repo_root" ] && [ -f "$repo_root/.github/codeql/scan.ps1" ]; then
             pwsh -ExecutionPolicy Bypass -NoProfile -File "$repo_root/.github/codeql/scan.ps1" "$@"
         else
             echo "[FAIL] Not in a CodeQL-enabled repository"
         fi
     }
     ```
   These resolve the repo root dynamically (same pattern as the git wrapper), so they work from any subdirectory and only activate in CodeQL-enabled repos.

#### 3. Validation (implements Step 7)

Run the validation checks defined in Step 7 (core.hooksPath, pre-commit hook, CodeQL CLI on PATH, alias status). Print `[PASS]`/`[FAIL]` for each check.

#### 4. Completion summary

Stop the timer, record the end time, and print:
- Start time, end time, and elapsed duration in the standard output pattern:
  ```
  Started at:  2025-01-15 09:32:07 -08:00
  Finished at: 2025-01-15 09:34:41 -08:00
  Elapsed:     2m 34s
  ```
- OS detected
- CodeQL CLI version
- Supported languages (from the static mapping table in Step 4c — not detected at install time; actual detection happens at scan time)
- Files and folders (using the format from the Completion Summary section)
- Hook status, SARIF Viewer status
- Next steps (scan commands, teammate onboarding)
- **Language dependency checklist** — detect which languages are present in the repo and print a per-language checklist of prerequisites the developer must have installed for scans to succeed. This uses the same `$extMap` from Step 1b to detect languages from `git ls-files`:
  ```powershell
  $extMap = @{
      '.cs' = 'csharp'; '.js' = 'javascript'; '.ts' = 'javascript'; '.jsx' = 'javascript'; '.tsx' = 'javascript'
      '.py' = 'python'; '.java' = 'java'; '.kt' = 'java'; '.go' = 'go'; '.rb' = 'ruby'
      '.c' = 'cpp'; '.h' = 'cpp'; '.cpp' = 'cpp'; '.cc' = 'cpp'; '.swift' = 'swift'
  }
  $repoLangs = git ls-files 2>$null | ForEach-Object {
      $ext = [System.IO.Path]::GetExtension($_)
      if ($extMap.ContainsKey($ext)) { $extMap[$ext] }
  } | Select-Object -Unique

  # Collect only action items — things the user still needs to do
  $actions = @()
  foreach ($lang in $repoLangs) {
      switch ($lang) {
          'csharp' {
              if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                  $actions += "C# -- Install .NET SDK: https://dot.net/download"
              }
              # Always remind about NuGet packages for C# (common pitfall even when dotnet is installed)
              $actions += "C# -- Ensure all NuGet packages are in your .csproj (e.g., dotnet add package Microsoft.Data.SqlClient)"
              $actions += "C# -- Verify: dotnet build (must succeed before scans will pass)"
          }
          'java' {
              if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
                  $actions += "Java -- Install JDK 11+: https://adoptium.net"
              }
              $actions += "Java -- Verify: mvn compile (or gradle build) must succeed"
          }
          'go' {
              if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
                  $actions += "Go -- Install Go: https://go.dev/dl"
              }
              $actions += "Go -- Verify: go build ./... (must succeed before scans will pass)"
          }
          'cpp' {
              $hasCpp = (Get-Command cl -ErrorAction SilentlyContinue) -or
                        (Get-Command gcc -ErrorAction SilentlyContinue) -or
                        (Get-Command clang -ErrorAction SilentlyContinue)
              if (-not $hasCpp) {
                  $actions += "C/C++ -- Install a compiler: Visual Studio Build Tools (Windows) or gcc/clang (Linux/macOS)"
              }
              $actions += "C/C++ -- Verify: your build command (make / cmake --build . / msbuild) must succeed"
          }
          'swift' {
              if (-not (Get-Command xcodebuild -ErrorAction SilentlyContinue)) {
                  $actions += "Swift -- Install Xcode from the App Store (macOS only)"
              }
              $actions += "Swift -- Verify: swift build (SPM) or xcodebuild must succeed"
          }
          # javascript, python, ruby: interpreted — no action needed
      }
  }

  if ($actions.Count -gt 0) {
      Write-Host "" -ForegroundColor Yellow
      Write-Host "Before your first commit, please ensure:" -ForegroundColor Yellow
      foreach ($action in $actions) {
          Write-Host "  - $action" -ForegroundColor Yellow
      }
      Write-Host "" -ForegroundColor Cyan
  }
  ```
  This checklist prints only action items for compiled languages present in the repo. Interpreted languages (JavaScript/TypeScript, Python, Ruby) are silently skipped — they need no build tools. If there are no action items (e.g., repo only has Python files), nothing is printed.
- Documentation link (`https://aka.ms/CELA-CODEQL`)

### 5f. Create the Uninstaller

Create `.github/codeql/uninstall.ps1` that:

1. Runs `git config --unset core.hooksPath`.
2. Restores `.git/hooks/pre-commit.backup` if it exists.
3. Removes the CodeQL Vibe block (git wrapper + codeql-scan alias) from shell profiles by finding and deleting everything between `# --- CodeQL Vibe start ---` and `# --- CodeQL Vibe end ---` (inclusive):
   - **Windows:** Remove the marker-delimited block from the PowerShell `$PROFILE`. If marker removal fails (e.g., user edited inside the markers and the regex doesn't match), fall back to restoring `$PROFILE.pre-codeql` if it exists.
   - **macOS/Linux:** Remove the marker-delimited block from `~/.bashrc` and/or `~/.zshrc`. If marker removal fails, fall back to restoring the `.pre-codeql` backup for each rc file.
   The boundary markers ensure only agent-inserted content is removed — user-added profile content outside the markers is never touched. The `.pre-codeql` backups are a safety net for edge cases where marker-based removal cannot succeed.
4. Prints confirmation.

### 5g. File Validation (performed by install.ps1 step 0)

Validation of all generated files is performed by `install.ps1` at runtime (step 0 in the install.ps1 flow) — NOT as a separate agent terminal call. This eliminates an extra terminal call from Phase 1 and ensures teammate onboarding also gets auto-validation.

The agent does NOT run a separate validation terminal call after file creation. Phase 1 ends when all files are written. Validation runs automatically when install.ps1 starts in Phase 2.

See **5e, step 0** for the complete validation specification (syntax, encoding, config, and hook checks with auto-fix).

---

## Step 6: Install the Hook

> **Phase 2** — the agent runs `install.ps1` as a single terminal call. This is the only terminal command after file creation.

Run the installer (use `pwsh` instead of `powershell` on macOS/Linux):

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"
```

The installer handles **everything**: CodeQL CLI detection/installation, SARIF Viewer (CLI fallback), .gitignore updates, hook setup, profile configuration, validation, and prints the completion summary. The agent does NOT need to run any additional terminal commands after this.

---

## Step 7: Validate Installation

> **Phase 2 (install.ps1)** — validation runs as the final step of `install.ps1`. The specification below defines the required behavior.

Validate that the hook infrastructure is correctly installed. Do **NOT** run a scan during installation — scans happen only on-demand or at pre-commit time.

Combine all validation checks into **one terminal call**:

```powershell
# 1. core.hooksPath
$hooksPath = git config --get core.hooksPath 2>$null
if ($hooksPath -eq '.github/codeql/hooks') {
    Write-Host "[PASS] core.hooksPath = $hooksPath" -ForegroundColor Green
} else {
    Write-Host "[FAIL] core.hooksPath not set or incorrect: '$hooksPath'" -ForegroundColor Red
}

# 2. Pre-commit hook file
if (Test-Path ".github/codeql/hooks/pre-commit") {
    Write-Host "[PASS] Pre-commit hook installed" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Pre-commit hook not found" -ForegroundColor Red
}

# 3. CodeQL CLI accessible (already verified in Phase 0 — just confirm PATH is correct)
# Use Get-Command (instant PATH lookup) instead of codeql version (spawns the JVM, 2-5s)
$codeqlCmd = Get-Command codeql -ErrorAction SilentlyContinue
if ($codeqlCmd) {
    Write-Host "[PASS] CodeQL CLI in PATH ($($codeqlCmd.Source))" -ForegroundColor Green
} else {
    Write-Host "[FAIL] CodeQL CLI not found in PATH" -ForegroundColor Red
}

# 4. Convenience alias check
if (Get-Command codeql-scan -ErrorAction SilentlyContinue) {
    Write-Host "[PASS] codeql-scan alias active" -ForegroundColor Green
} else {
    Write-Host "[INFO] codeql-scan alias will activate in new terminals" -ForegroundColor Yellow
}

# 5. Query pack resolution (confirms CLI is functional, not just on PATH)
$qlpackOut = codeql resolve qlpacks 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[PASS] CodeQL query packs resolve successfully" -ForegroundColor Green
} else {
    Write-Host "[FAIL] CodeQL query packs failed to resolve -- CLI may be corrupted" -ForegroundColor Red
    Write-Host "  Try reinstalling: https://github.com/github/codeql-cli-binaries/releases/latest" -ForegroundColor Yellow
}
```

Report the installation status: hook path, CLI version, supported languages (from the static mapping table), bypass prevention status, and alias status. Do NOT run a scan.

---

## Step 8: Update .gitignore

> **Phase 2 (install.ps1)** — .gitignore is updated early in `install.ps1` execution. The specification below defines the required behavior.

Append these entries to `.gitignore` if not already present:

```
.codeql-db/
.codeql-results.sarif
.codeql-results-*.sarif
.codeql-temp-scan.csproj
.github/codeql/.scan-lock
.github/codeql/status.json
```

Do NOT ignore `.github/codeql/` itself — the hooks, scan script, and config must be committed so all developers get the enforcement.

---

## Update Agent Files

When the user asks to check for updates or update the agent files, use the source repository at:

```
https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/CodeQL-Vibe
```

### Check for Updates (Prompt 26)

> **Note:** If this repo is managed by the SpecKit bootstrapper, prefer using the bootstrapper for updates. Prompts 26-27 are for standalone use or manual checks within a single repo.

Compare the local agent and prompt files against the source repository using **version comparison**:

1. Read the local version from `speckit.agent.yml` (the `agent.version` field). This is the canonical version source — the agent frontmatter does not contain a `version:` field.
2. Fetch the latest versions from the remote (do NOT clone the full repo — use the Azure DevOps REST API or `git archive`):
   ```powershell
   $baseUrl = "https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_apis/git/repositories/CodeQL-Vibe/items"
   $agentUrl = "$baseUrl?path=/.github/agents/speckit.codeql.agent.md&api-version=7.0"
   $promptUrl = "$baseUrl?path=/.github/prompts/speckit.codeql.prompt.md&api-version=7.0"
   $manifestUrl = "$baseUrl?path=/speckit.agent.yml&api-version=7.0"
   $changelogUrl = "$baseUrl?path=/CHANGELOG.md&api-version=7.0"
   ```
3. Extract the `agent.version` field from the remote `speckit.agent.yml`. Compare against the local version using semantic versioning.
4. Report one of:
   - `[PASS] Agent files are up to date (v1.0.0)` — if versions match
   - `[WARN] Update available: v1.0.0 --> v1.1.0` — show version diff and relevant CHANGELOG excerpt
5. If updates are available, ask the user if they want to apply them.

### Update Agent Files (Prompt 27)

Pull and replace the local agent files from the source repository:

1. Download the latest versions of these files from the remote:
   - `.github/agents/speckit.codeql.agent.md`
   - `.github/prompts/speckit.codeql.prompt.md`
   - `speckit.agent.yml`
2. **Archive** the current local files with timestamps for multi-generation rollback:
   ```powershell
   $timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
   $backupDir = ".codeql-backup"
   if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
   Copy-Item ".github/agents/speckit.codeql.agent.md" "$backupDir/speckit.codeql.agent.md.$timestamp"
   Copy-Item ".github/prompts/speckit.codeql.prompt.md" "$backupDir/speckit.codeql.prompt.md.$timestamp"
   if (Test-Path "speckit.agent.yml") {
       Copy-Item "speckit.agent.yml" "$backupDir/speckit.agent.yml.$timestamp"
   }
   ```
3. Replace the local files with the downloaded versions.
4. If `CLAUDE.md` exists in the workspace and contains a CodeQL section, check whether the agent file path reference is still correct. Update if needed.
5. Print a summary:
   - Version change (e.g., `v1.0.0 --> v1.1.0`)
   - Files updated (with timestamped backup locations in `.codeql-backup/`)
   - Files unchanged (already current)
   - Any warnings (e.g., CLAUDE.md not found)
   - Relevant CHANGELOG excerpt for the new version
6. Recommend the user re-run `verify installation` to confirm the updated agent works correctly.

**Restoring a previous version:** List available backups with `Get-ChildItem .codeql-backup/ | Sort-Object Name` and copy the desired version back.

**Authentication:** The Azure DevOps API may require authentication. If the request fails with 401/403:
- Prefer the `codeql-azuredevops-git-auth` skill or equivalent workflow:
    - Verify `git config --global credential.helper` is `manager-core` (or `manager` where that is the installed name)
    - Configure `credential.azreposCredentialType oauth`
    - Run browser-based `az login` (never `az login --use-device-code`)
    - Re-test with `git ls-remote <source-repo-url>`
- If that path is blocked by environment or policy, instruct the user to provide a PAT (Personal Access Token) with `Code (Read)` scope, or clone the source repo manually.

**Offline fallback:** If the API is unreachable, instruct the user to manually copy the files from the source repository.

---

## Suppression Logging

When the user asks to suppress a false positive (Prompt 13), the agent MUST log the suppression in addition to adding the code comment.

### Logging Procedure

After adding the suppression comment to the source file:

1. Read or create `.github/codeql/suppression-log.json`. If it doesn't exist, initialize with `{"suppressions": []}`.
2. Append a new entry using the `@()` array pattern (see the PSObject gotcha note under Scan Audit Trail — the same issue applies here):
   ```powershell
   $log = Get-Content -Raw ".github/codeql/suppression-log.json" | ConvertFrom-Json
   $entry = [PSCustomObject]@{ date = ...; developer = ...; ruleId = ...; file = ...; line = ...; severity = ...; justification = ... }
   $log.suppressions = @($log.suppressions) + @($entry)
   # Cap at 1000 entries to prevent unbounded growth (keeps most recent)
   if ($log.suppressions.Count -gt 1000) { $log.suppressions = $log.suppressions[-1000..-1] }
   $tmpFile = ".github/codeql/suppression-log.json.tmp"
   $log | ConvertTo-Json -Depth 10 | Set-Content $tmpFile -Encoding UTF8
   Move-Item $tmpFile ".github/codeql/suppression-log.json" -Force   # atomic rename
   ```
   Entry schema:
   ```json
   {
     "date": "<ISO 8601 timestamp>",
     "developer": "<from git config user.name>",
     "ruleId": "<CodeQL rule ID>",
     "file": "<relative file path>",
     "line": <line number>,
     "severity": "<Critical|High|Medium|Low|Informational>",
     "justification": "<the justification text from the suppression comment>"
   }
   ```
3. Write the updated file back (already done in the code above — do NOT also write separately).
4. Remind the user that suppressions should follow the [suppression policy](../../docs/suppression-policy.md).

### Review Suppressions (Prompt 32)

When the user asks to review suppressions:

1. Read `.github/codeql/suppression-log.json`. If it doesn't exist, report "No suppressions logged."
2. For each entry, show: date, age (days since suppression), developer, rule ID, severity, file:line, and justification.
3. Sort by severity (Critical first), then by age (oldest first).
4. Flag any suppressions older than 90 days for review.
5. Suggest removing suppressions where the underlying code has changed or the CodeQL rule has been updated.

---

## Scan Audit Trail

Every time the scan script runs (pre-commit or manual), it MUST append structured metadata to `.github/codeql/scan-history.json` for compliance reporting.

### Scan History Entry

After each scan completes (pass or fail), read or create `.github/codeql/scan-history.json`. If it doesn't exist, initialize with `{"scans": []}`. Append a new entry to the `scans` array, then write the updated file back. (This is the same read-modify-write pattern used by Suppression Logging — do NOT literally append JSON text to the file, as that would produce invalid JSON.)

> **Critical — PowerShell `ConvertFrom-Json` array gotcha:** `ConvertFrom-Json` returns `PSObject` wrappers, and the `+=` operator does not work on PSObject arrays (`op_Addition` error). Do NOT write `$history.scans += $entry`. Instead, force the property to a native array before appending:
> ```powershell
> $history = Get-Content -Raw ".github/codeql/scan-history.json" | ConvertFrom-Json
> $history.scans = @($history.scans) + @($entry)
> # Cap at 1000 entries to prevent unbounded growth (keeps most recent)
> if ($history.scans.Count -gt 1000) { $history.scans = $history.scans[-1000..-1] }
> $tmpFile = ".github/codeql/scan-history.json.tmp"
> $history | ConvertTo-Json -Depth 10 | Set-Content $tmpFile -Encoding UTF8
> Move-Item $tmpFile ".github/codeql/scan-history.json" -Force   # atomic rename
> ```
> The same pattern applies to `suppression-log.json` (`$log.suppressions = @($log.suppressions) + @($entry)`).
>
> **Size cap:** Both `scan-history.json` and `suppression-log.json` are pruned to their most recent 1000 entries on every write. This prevents unbounded file growth (a scan every 5 minutes would hit the cap after ~3.5 days of continuous use). Older entries are discarded silently. For long-term compliance, export the history to an external system before it rotates out.

Entry schema:

```json
{
  "timestamp": "<ISO 8601>",
  "durationMs": 12345,
  "developer": "<from git config user.name>",
  "trigger": "<pre-commit|manual|ci>",
  "languages": ["javascript", "python"],
  "findings": {
    "critical": 0,
    "high": 1,
    "medium": 3,
    "low": 5,
    "informational": 2
  },
  "blocked": true,
  "agentVersion": "1.0.0"
}
```

The scan script generated in Step 5b should include this logging at the end, before the exit statement. Populate `durationMs` from `$scanStopwatch.ElapsedMilliseconds`. Read the version from `speckit.agent.yml` (`agent.version` field) or default to "unknown" if the file is not found or not parseable.

### Generate Compliance Report (Prompt 33)

When the user asks to generate a compliance report:

1. Read `.github/codeql/scan-history.json`. If it doesn't exist, report "No scan history found. Run a scan first."
2. Aggregate the data:
   - Total scans (all time, last 30 days, last 7 days)
   - Block rate (percentage of scans that blocked a commit)
   - Findings trend (total findings per severity over time)
   - Languages scanned
   - Most common rule IDs in blocked commits
3. Generate a markdown report and save to `docs/compliance-report.md`.
4. Open the report in VS Code.

---

## Agent Health Beacon

When the user asks for a status report (Prompt 19), the agent MUST produce both human-readable output AND a structured JSON file for fleet-level observability.

### Health Beacon Output

In addition to the existing human-readable status report, write `.github/codeql/status.json`:

```json
{
  "agent": "speckit.codeql",
  "version": "1.0.0",
  "status": "active",
  "lastScan": "<ISO 8601 timestamp of most recent scan from scan-history.json>",
  "findings": {
    "critical": 0,
    "high": 1,
    "medium": 3,
    "low": 5,
    "informational": 2
  },
  "languages": ["javascript", "python"],
  "hooksActive": true,
  "bypassPrevention": true,
  "codeqlVersion": "<from codeql version>",
  "platform": "<Windows|macOS|Linux>"
}
```

Read the `version` value from `speckit.agent.yml` (`agent.version` field) or default to `"unknown"` if the file is not found. This file enables the SpecKit bootstrapper and fleet tooling to aggregate status across repos.

---

## CI/CD Setup

When the user asks to set up CI/CD scanning (Prompt 30), the agent creates an Azure Pipelines definition for server-side enforcement. This agent targets projects hosted in **Azure DevOps repos** — GitHub Actions workflows are not applicable.

### Azure Pipelines Setup

1. Detect languages by scanning workspace files with `git ls-files` and mapping extensions via `$extMap` (Step 4c), then validate against `codeql resolve languages` to confirm CodeQL supports them.
2. Copy the template from `azure-pipelines/codeql-scan.yml` (shipped with this agent).
3. Replace the `AGENT_PLACEHOLDER` language variable with the detected languages (comma-separated).
4. Commit-ready: the pipeline file is ready to push.

### Verify CI/CD Integration (Prompt 31)

When the user asks to verify CI/CD integration:

1. Check for `azure-pipelines/codeql-scan.yml`.
2. Validate the language list matches the workspace languages (re-detect using the `$extMap` mapping from Step 4c).
3. Validate the query suite path uses the fully-qualified pack format (e.g., `codeql/$lang-queries:codeql-suites/$lang-security-extended.qls` for pre-commit, `$lang-security-and-quality.qls` for full scans).
4. Report status: `[PASS] CI/CD scanning configured` or `[WARN] No CI/CD pipeline found`.

---

## Completion Summary

`install.ps1` prints its own completion summary to the terminal (see 5e, step 4). The agent reads the install.ps1 output and relays this to the user in chat, supplementing with any information the agent has from Phase 0 (pre-flight).

Report to the user:
- **Timing** — start time, end time, and elapsed duration (same pattern printed by install.ps1)
- OS detected
- CodeQL CLI version (installed or already present)
- Supported CodeQL languages (from the static mapping table — actual detection happens dynamically at scan time)
- Files and folders created — list **every** path, using this exact format:
  ```
  Created:
    .github/codeql/                    (new folder)
    .github/codeql/hooks/              (new folder)
    .github/codeql/scan.ps1            Scan script
    .github/codeql/hooks/pre-commit    Pre-commit hook
    .github/codeql/git-secure.ps1      PowerShell git wrapper
    .github/codeql/git-secure.sh       Bash/zsh git wrapper
    .github/codeql/install.ps1         Complete bootstrapper
    .github/codeql/uninstall.ps1       Uninstaller
    .github/codeql/codeql-config.yml   CodeQL configuration
  Modified:
    .gitignore                  Added CodeQL temp-file exclusions
    git config core.hooksPath   Set to .github/codeql/hooks
    Shell profile ($PROFILE)    Added git wrapper + codeql-scan alias
  ```
  If any file already existed and was regenerated, note it as `(regenerated)` instead of listing under Created.
- Hook installation status (confirmed without running a scan)
- SARIF Viewer extension status (installed or skipped)
- **Language dependency checklist** — relay the action items from install.ps1's terminal output (see 5e, step 4). Only mention what the user still needs to do — omit anything already installed or resolved. Example chat format for a repo with C#, Python, and Go:

  ```
  Before your first commit, please ensure:
    - C# -- Ensure all NuGet packages are in your .csproj (e.g., dotnet add package System.Data.SqlClient)
    - C# -- Verify: dotnet build (must succeed before scans will pass)
    - Go -- Verify: go build ./... (must succeed before scans will pass)
  ```

  If there are no action items (e.g., repo only has interpreted languages like Python or JavaScript), skip this section entirely — don't print "everything is ready".

- Next steps:
  - Remind developers to run `pwsh -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"` after cloning (one command — handles everything)
  - To scan uncommitted changes on demand: **`codeql-scan`** (convenience alias) or `powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/scan.ps1"` (or `pwsh` on macOS/Linux)
  - To scan the entire codebase: **`codeql-scan -Full`** or `powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/scan.ps1" -Full` (or `pwsh` on macOS/Linux)
  - Pre-commit scans happen automatically on staged files when committing

Finally, recommend the user read the guides at **https://aka.ms/CELA-CODEQL** with this summary:

```
Learn more at https://aka.ms/CELA-CODEQL

Available guides:
  * Introduction        -- What CodeQL Vibe does, blocking policy, supported languages, and design decisions
  * Getting Started     -- Step-by-step setup: copying files, running the agent, and verifying installation
  * Troubleshooting     -- Common issues: CodeQL not found, slow scans, encoding errors, hook problems
  * How It Works        -- Scan flow, severity classification, enforcement architecture, and query suites
  * SARIF Guide         -- Understanding SARIF output, using the viewer, filtering results, and comparing scans
  * Remediation Guide   -- Fixing vulnerabilities with vibe coding prompts, manual patterns, and false positive handling
  * Dependencies Guide  -- Per-language build prerequisites, what the scan auto-resolves, and what you install
  * Prompts Guide       -- All available prompts with examples, tips, and when to use each one
```
