---
name: codeql-hook-integrity
description: "Validate and repair the non-bypassable pre-commit hook chain: core.hooksPath, pre-commit script, git-secure bypass prevention wrappers, shell profile aliases, and flag-stripping logic. Use when hooks stop firing, bypass prevention fails, --no-verify is not blocked, git wrapper is broken, or after git/shell/IDE changes."
argument-hint: "Describe the hook issue: hook not running, bypass not blocked, profile missing alias, or what changed"
user-invocable: true
disable-model-invocation: false
---

# Hook Integrity Skill

Validate and repair the full hook chain that enforces non-bypassable CodeQL scanning on every commit. This is the most critical security property of the agent -- if any link breaks, enforcement is silently disabled.

## When to Use

- Pre-commit hook is **not firing** on commit
- User reports `--no-verify` is **not being blocked**
- User changed their **shell** or **terminal** configuration
- User updated **Git** and hooks stopped working
- IDE (VS Code, etc.) **reset** git hooks path
- User asks to **verify** or **test** hook integrity
- User asks about the **bypass prevention** mechanism
- After any system change that could affect git config, PATH, or shell profile

## Hook Chain Architecture

The enforcement chain has four layers. ALL must be intact for bypass prevention to work:

```
Layer 1: core.hooksPath
  git config core.hooksPath --> .github/codeql/hooks
  
Layer 2: Pre-commit hook
  .github/codeql/hooks/pre-commit --> invokes scan.ps1
  
Layer 3: Git wrapper (bypass prevention)
  .github/codeql/git-secure.ps1 / git-secure.sh
  Strips --no-verify and -n from git commit commands
  
Layer 4: Shell profile (PATH + alias)
  $PROFILE / ~/.bashrc / ~/.zshrc
  Ensures "git" resolves to the wrapper before system git
```

If Layer 3 or 4 is broken, a user can bypass the hook with `git commit --no-verify`. If Layer 1 or 2 is broken, no scan runs at all.

## Integrity Check Procedure

### Layer 1: core.hooksPath

```powershell
$hooksPath = git config --get core.hooksPath 2>$null
if ($hooksPath -eq '.github/codeql/hooks') {
    Write-Host "[PASS] core.hooksPath is set to .github/codeql/hooks" -ForegroundColor Green
} elseif ($hooksPath) {
    Write-Host "[FAIL] core.hooksPath is '$hooksPath' -- expected '.github/codeql/hooks'" -ForegroundColor Red
} else {
    Write-Host "[FAIL] core.hooksPath is not set -- hooks will use .git/hooks/ (not managed)" -ForegroundColor Red
}
```

**Repair:** `git config core.hooksPath .github/codeql/hooks`

**Common breakage:** Some IDEs and git GUIs reset `core.hooksPath` when configuring their own hooks. Check `.git/config` directly if the git config command reports unexpected values.

### Layer 2: Pre-commit Hook

```powershell
# File exists?
$hookPath = '.github/codeql/hooks/pre-commit'
if (-not (Test-Path $hookPath)) {
    Write-Host "[FAIL] Pre-commit hook missing: $hookPath" -ForegroundColor Red
} else {
    # Content correct? Must invoke scan.ps1
    $content = Get-Content $hookPath -Raw
    if ($content -match 'scan\.ps1') {
        Write-Host "[PASS] Pre-commit hook exists and references scan.ps1" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Pre-commit hook exists but does not invoke scan.ps1" -ForegroundColor Red
    }
}
```

**Expected content:**
```bash
#!/bin/sh
# CodeQL pre-commit hook - non-bypassable security scan
# Auto-detect scan.ps1 location relative to this hook (works from .github/codeql/ or .codeql/)
HOOK_DIR="$(dirname "$0")"
SCAN_SCRIPT="$HOOK_DIR/../scan.ps1"
# Use pwsh (PowerShell Core) on macOS/Linux; fall back to powershell (Windows)
if command -v pwsh >/dev/null 2>&1; then
  pwsh -ExecutionPolicy Bypass -NoProfile -File "$SCAN_SCRIPT"
else
  powershell -ExecutionPolicy Bypass -NoProfile -File "$SCAN_SCRIPT"
fi
exit $?
```

The hook tries `pwsh` first (PowerShell Core on macOS/Linux), falls back to `powershell` (Windows).

**Repair:** Re-run the installer: `pwsh -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"`

### Layer 3: Git Wrapper (Bypass Prevention)

Two wrappers must exist -- one for PowerShell, one for bash/zsh:

```powershell
# PowerShell wrapper
if (Test-Path '.github/codeql/git-secure.ps1') {
    Write-Host "[PASS] PowerShell git wrapper exists" -ForegroundColor Green
} else {
    Write-Host "[FAIL] PowerShell git wrapper missing: .github/codeql/git-secure.ps1" -ForegroundColor Red
}

# Bash/zsh wrapper
if (Test-Path '.github/codeql/git-secure.sh') {
    Write-Host "[PASS] Bash/zsh git wrapper exists" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Bash/zsh git wrapper missing: .github/codeql/git-secure.sh" -ForegroundColor Red
}
```

**Repair:** Re-run the installer to regenerate wrappers.

### Layer 4: Shell Profile (PATH + Alias)

The shell profile must add `.github/codeql/` to the front of PATH so `git` resolves to the wrapper.

**PowerShell (`$PROFILE`):**
```powershell
if ($PROFILE -and (Test-Path $PROFILE)) {
    $profileContent = Get-Content $PROFILE -Raw
    if ($profileContent -match 'git-secure') {
        Write-Host "[PASS] PowerShell profile references git-secure wrapper" -ForegroundColor Green
    } else {
        Write-Host "[WARN] PowerShell profile does not reference git-secure wrapper" -ForegroundColor Yellow
    }
    if ($profileContent -match 'codeql-scan') {
        Write-Host "[PASS] PowerShell profile has codeql-scan alias" -ForegroundColor Green
    } else {
        Write-Host "[WARN] PowerShell profile missing codeql-scan alias" -ForegroundColor Yellow
    }
} else {
    Write-Host "[WARN] PowerShell profile not found or not set" -ForegroundColor Yellow
}
```

**Bash/zsh (`~/.bashrc` or `~/.zshrc`):**
```bash
grep -q 'git-secure' ~/.bashrc 2>/dev/null && echo "[PASS] bashrc references git-secure" || echo "[WARN] bashrc missing git-secure"
grep -q 'git-secure' ~/.zshrc 2>/dev/null && echo "[PASS] zshrc references git-secure" || echo "[WARN] zshrc missing git-secure"
```

**Profile null guard:** `$PROFILE` is `$null` inside `Start-Job` and some embedded hosts (CI, VS Code tasks). The installer captures `$profilePath` before `Start-Job` and uses `$using:profilePath` inside the job. If `$PROFILE` is genuinely null (no PowerShell profile exists), the installer creates a fallback path at `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`.

## Flag-Stripping Logic

The git wrappers block `--no-verify` and `-n` (its short form) from `git commit` commands. This is the core bypass prevention mechanism.

### What Gets Stripped

| Input | After Stripping | Notes |
|---|---|---|
| `git commit --no-verify -m "msg"` | `git commit -m "msg"` | Exact `--no-verify` match |
| `git commit -n -m "msg"` | `git commit -m "msg"` | Exact `-n` match |
| `git commit -an -m "msg"` | `git commit -a -m "msg"` | Combined flag: remove `n`, keep `a` |
| `git commit -nm -m "msg"` | `git commit -m -m "msg"` | Combined flag: remove `n`, keep `m` |
| `git commit -anm -m "msg"` | `git commit -am -m "msg"` | Combined flag: remove `n`, keep `a` and `m` |
| `git push --no-verify` | `git push --no-verify` | Not a commit command -- passed through unchanged |

### PowerShell Implementation Pattern

```
1. Find real git.exe (first in PATH that is not this wrapper)
2. For "git commit" commands, scan arguments:
   - Match "--no-verify" exactly --> drop
   - Match "-n" exactly --> drop
   - Match /-[a-zA-Z]*n[a-zA-Z]*/ --> remove "n" from cluster, keep rest
     - If only "n" remains after removal ("-n" --> "-") --> drop entirely
3. Print [WARN] message if any flag was stripped
4. Forward cleaned args to real git
5. Pass through exit code
```

### Bash Implementation Pattern

Uses bash parameter expansion `${arg//n/}` for removing `n` from combined flags -- no external process spawns (no `sed`, `tr`, or `echo | pipe`). The `command -v git` builtin finds the real git without spawning a process.

### Testing Bypass Prevention

To verify the wrapper is active:

```powershell
# This should print the [WARN] message and still run the commit with the hook
git commit --no-verify -m "test bypass prevention"
# Expected output: [WARN] --no-verify is disabled. CodeQL security scan cannot be bypassed.
# The commit should then trigger the CodeQL scan normally
```

## Common Breakage Scenarios

| Scenario | Symptom | Affected Layer | Fix |
|---|---|---|---|
| Git updated/reinstalled | Hook not running | Layer 1 | `git config core.hooksPath .github/codeql/hooks` |
| IDE reset hooks | Hook not running | Layer 1 | Re-set `core.hooksPath` |
| User deleted .github/codeql/ | Everything broken | Layers 2-4 | Re-run installer |
| New shell installed | `--no-verify` not blocked | Layer 4 | Add git-secure to new shell's profile |
| Profile cleared/reset | `--no-verify` not blocked | Layer 4 | Re-run installer (re-adds profile entries) |
| PATH changed | System git used instead of wrapper | Layer 4 | Ensure `.github/codeql/` is at front of PATH |
| Windows Terminal changed | Alias not loaded | Layer 4 | Open new terminal; verify `$PROFILE` is loaded |
| Corporate proxy/GPO | Hook execution blocked | Layer 2 | Check PowerShell execution policy; use `-ExecutionPolicy Bypass` |

## Full Integrity Report

Run all four layer checks in sequence. Report overall status:

- **All [PASS]**: Hook chain is intact. Bypass prevention active.
- **Any Layer 1-2 [FAIL]**: Scans are NOT running on commit. Critical -- fix immediately.
- **Any Layer 3-4 [FAIL/WARN]**: Scans run but `--no-verify` bypass is possible. High priority fix.

## Cross-References

- **Agent spec Step 5c** -- Pre-commit hook creation (source of truth)
- **Agent spec Step 5d** -- Git wrapper creation with flag-stripping logic
- **Agent spec Step 5e/6** -- Install.ps1 parallel setup (hooks + profile)
- **codeql-troubleshoot** -- General "hook not running" diagnosis
- **Agent spec behavioral boundaries** -- WILL NOT disable/weaken hook, WILL NOT allow --no-verify bypass
