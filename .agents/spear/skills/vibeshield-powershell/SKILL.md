---
name: vibeshield-powershell
description: 'Validate PowerShell scripts against PSScriptAnalyzer rules and constitution quality gates. Two-tier model: Tier 1 (hook) validates modified files on every edit; Tier 2 (checkpoint) scans all scripts at milestones. Use when: validating PowerShell, checking script quality, running PSScriptAnalyzer, enforcing coding standards on .ps1 files, checking for PSAvoidUsingWriteHost exclusions, verifying Strict Mode compliance.'
---

# PowerShell Validation

## Installation

**Script:** [`scripts/Install-VibeShield.ps1`](./scripts/Install-VibeShield.ps1) — **install entry point** for the vibeshield-powershell skill.

The top-level VibeShield installer calls this script to set up the skill in a target project. It can also be run directly to adopt this skill standalone.

Installs Copilot customization assets into the project. Idempotent — skips files that already exist, and always overwrites the agent definition and hook to ensure the latest version is deployed.

**Installed assets:**

| Asset | Path | Behavior |
|-------|------|----------|
| Path-specific instructions | `.github/instructions/powershell.instructions.md` | Skip if exists |
| Copilot instructions entry | `.github/copilot-instructions.md` (marker section) | Upsert (idempotent) |
| Agent definition | `.github/agents/vibeshield-powershell.agent.md` | Always overwrite |
| PostToolUse hook | `.github/hooks/validate-powershell.json` | Always overwrite |
| Skill documentation | `.github/skills/vibeshield-powershell/SKILL.md` | Always overwrite |
| Validation scripts | `.github/skills/vibeshield-powershell/scripts/` (3 runtime scripts) | Always overwrite |
| VS Code auto-approve | `.vscode/settings.json` (auto-approve pattern) | Additive merge |

**Usage:**

```powershell
# Called by the top-level VibeShield installer, or run directly:
pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Install-VibeShield.ps1

# With explicit project path:
pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Install-VibeShield.ps1 -ProjectPath C:\myproject
```

Exit codes: `0` = installation completed successfully (items created and/or skipped).

## Available Scripts

- **`scripts/Install-VibeShield.ps1`** — Install entry point (see [Installation](#installation) above). Installs Copilot customization assets into the target project.
- **`scripts/Invoke-PSScriptAnalyzer.ps1`** — Tier 1 single-file PSScriptAnalyzer analysis. Runs full static analysis against one `.ps1`/`.psm1` file.
- **`scripts/Invoke-PSScriptAnalyzerHook.ps1`** — PostToolUse hook wrapper. Extracts the edited file path from hook input and delegates to `Invoke-PSScriptAnalyzer.ps1`.
- **`scripts/Test-PowerShellScripts.ps1`** — Tier 2 checkpoint scan. Discovers all `.ps1`/`.psm1` files in the repo and runs PSScriptAnalyzer against each.

All scripts share the same exit code contract: `0` = pass, `1` = violations found.

## Two-Tier Validation Architecture

PowerShell validation uses two tiers: tier 1 is a hook that runs on every edit against the modified file, providing fast feedback. Tier 2 is for checkpoints that scans all scripts at significant milestones, providing comprehensive validation before commits or PRs.

### Tier 1 — Hook (Single-File Analysis)

**Script:** [Invoke-PSScriptAnalyzer.ps1](./scripts/Invoke-PSScriptAnalyzer.ps1)

- **Scope**: Modified file only
- **Speed**: ~1-2 seconds
- **Trigger**: PostToolUse hook — automatic on every `.ps1`/`.psm1` edit
- **Exit codes**: 0 = pass, 1 = violations, 2 = invalid args (file not found, wrong extension)

Runs full `Invoke-ScriptAnalyzer` static analysis (best practices, code quality, security patterns) against a single file. The PostToolUse hook wrapper ([Invoke-PSScriptAnalyzerHook.ps1](./scripts/Invoke-PSScriptAnalyzerHook.ps1)) extracts the edited file path from hook input and calls this script automatically.

Manual usage:
```powershell
pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Invoke-PSScriptAnalyzer.ps1 -FilePath SFI/NS2-1/Add-VirtualTag.ps1
```

### Tier 2 — Checkpoint (All-Files Scan)

**Script:** [Test-PowerShellScripts.ps1](./scripts/Test-PowerShellScripts.ps1)

- **Scope**: All `.ps1`/`.psm1` files in the repo (excluding `output/` and `.specify/`)
- **Speed**: ~3-5 seconds
- **Trigger**: Manual invocation at significant milestones
- **Exit codes**: 0 = all pass, 1 = violations found

Discovers all PowerShell scripts recursively, runs `Invoke-ScriptAnalyzer` against each, and reports per-file results with line numbers, rule names, and messages.

Manual usage:
```powershell
# From repo root (auto-resolves)
pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Test-PowerShellScripts.ps1

# With explicit repo root
pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/Test-PowerShellScripts.ps1 -RepoRoot /path/to/repo
```

### When to Use Each Tier

| Situation | Tier |
|-----------|------|
| After editing a single `.ps1` file | Tier 1 (automatic via hook) |
| After completing a new script | Tier 2 (checkpoint) |
| After making multiple related changes | Tier 2 (checkpoint) |
| After fixing violations flagged by Tier 1 | Tier 2 (checkpoint) |
| Before declaring work complete | Tier 2 (checkpoint) |
| Before committing PowerShell changes | Tier 2 (checkpoint) |
| During code review of PowerShell scripts | Tier 2 (checkpoint) |

## PSScriptAnalyzer Rules

- Both tiers exclude only `PSAvoidUsingWriteHost` (per constitution — console color output with `-ForegroundColor`/`-BackgroundColor` is allowed)
- All other PSScriptAnalyzer rules are enforced
- Auto-installs PSScriptAnalyzer if missing

## Automation

The PostToolUse hook (`.github/hooks/validate-powershell.json`) runs Tier 1 automatically after every `.ps1`/`.psm1` file edit in Copilot agent sessions. The hook surfaces pass/fail results as SARIF JSON in the system message. On pass, the output reminds the agent to run Tier 2 at checkpoints.

## SARIF Output

All validation scripts emit SARIF v2.1.0 structured output:

- **Tier 1** (hook): `Invoke-PSScriptAnalyzer.ps1 -OutputSarif` emits minimal SARIF to stdout. The hook passes this automatically.
- **Tier 2** (checkpoint): `Test-PowerShellScripts.ps1` always writes aggregated SARIF to `./output/psscriptanalyzer-results.sarif`.

Agents should read SARIF for structured results. Do not pipe, filter, or post-process console output.

## Terminal Command Contract

All terminal commands for this skill **must** use the following format:

```
pwsh -NoProfile -File .github/skills/vibeshield-powershell/scripts/<Script>.ps1 [parameters]
```

### Allowed commands and parameters

| Script | Parameters |
|--------|-----------|
| `Invoke-PSScriptAnalyzer.ps1` | `-FilePath <path>` (required), `-RepoRoot <path>` |
| `Test-PowerShellScripts.ps1` | `-RepoRoot <path>` |

### Forbidden patterns

- `pwsh -NoProfile -Command` with any inline code
- Piping output: `| Out-String`, `| Select-Object`, `| Select-String`, `| Tee-Object`, `| Out-File`
- Wrapping: `Set-Location '...'; pwsh ...`, `& { Set-StrictMode ... }`, `& { ... 2>&1 | ... }`
- Stderr redirection: `2>&1 | Out-String`, `2>&1`
- Direct cmdlet calls: `Invoke-ScriptAnalyzer`, `Invoke-Pester`, `Get-Module ... -ListAvailable`

All output formatting, filtering, and file-writing is handled by script parameters. Tier 1 always emits SARIF to stdout. Checkpoint scripts always write SARIF to `./output/`. Do not pipe or wrap.

### Diagnostic escape hatch

If you need to run a diagnostic command that is not covered by these scripts (e.g., checking environment state, debugging a module installation issue), explain what you are investigating and why the standard scripts cannot answer it. The user will see an approval prompt -- provide enough context so the approval is informed, not reflexive.

## VS Code Auto-Approve

The installer ([`Install-AutoApproveSettings.ps1`](./scripts/Install-AutoApproveSettings.ps1)) automatically adds the auto-approve pattern to `.vscode/settings.json`. Additive and idempotent — existing settings and other auto-approve keys are preserved.

## Constitution Reference

See `.specify/memory/constitution.md` sections:
- **Quality Gates** — PSScriptAnalyzer is a non-negotiable quality gate
- **Defensive PowerShell** — Strict Mode, null handling, pipeline safety, string literals
