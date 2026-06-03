---
name: vibeshield-codeql
description: 'Install and configure CodeQL security scanning with pre-commit hooks. Sets up agent files, CodeQL configuration, and git hook infrastructure for automated vulnerability detection. Use when: setting up CodeQL, configuring security scanning, installing pre-commit hooks, enabling vulnerability remediation, running CodeQL scans on .ps1/.sh files, enforcing security gates before commit.'
---

# CodeQL Security Scanning

## Installation

**Script:** [`scripts/Install-VibeShield.ps1`](./scripts/Install-VibeShield.ps1) — **install entry point** for the vibeshield-codeql skill.

The top-level VibeShield installer calls this script to set up the skill in a target project. It can also be run directly to adopt this skill standalone.

Installs CodeQL Vibe agent files into the project via git sparse checkout from the source repository. Supports two execution paths: a fast path when all template files are present, and a CLI-assisted path that uses Claude or Copilot CLI to generate missing files.

**Installed assets:**

| Asset | Path | Behavior |
|-------|------|----------|
| Agent definition | `.github/agents/speckit.codeql.agent.md` | Via sparse checkout |
| Agent files | `.github/` (full structure) | Via sparse checkout |
| CLI routing | `CLAUDE.md` (CodeQL routing section) | Upsert (idempotent) |
| CodeQL scan script | `.github/codeql/scan.ps1` | From templates or CLI-generated |
| CodeQL installer | `.github/codeql/install.ps1` | From templates or CLI-generated |
| CodeQL uninstaller | `.github/codeql/uninstall.ps1` | From templates or CLI-generated |
| Git secure (Windows) | `.github/codeql/git-secure.ps1` | From templates or CLI-generated |
| Git secure (Unix) | `.github/codeql/git-secure.sh` | From templates or CLI-generated |
| Pre-commit hook | `.github/codeql/hooks/pre-commit` | From templates or CLI-generated |
| CodeQL config | `.github/codeql/codeql-config.yml` | From templates or CLI-generated |

**Usage:**

```powershell
# Run directly (defaults to main branch):
powershell -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1

# Specify a source branch:
powershell -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1 -Branch "release/2.0"

# Install agent files only, skip CLI-driven setup:
powershell -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1 -SkipSetup
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Branch` | string | `main` | Source branch to pull agent files from |
| `-SkipSetup` | switch | `$false` | Skip the CLI-driven setup step after copying agent files |
| `-Force` | switch | `$false` | Skip the interactive confirmation prompt before executing network-fetched scripts |

Exit codes: `0` = installation completed successfully, `1` = failure (clone, init, or verification failed).

## Available Scripts

- **`scripts/Install-VibeShield.ps1`** — Install entry point (see [Installation](#installation) above). Installs agent files via sparse checkout, configures CLAUDE.md routing, copies template files, and invokes CLI-assisted setup.

## Setup Execution Paths

The installer uses two execution paths depending on whether pre-built template files are available.

### Fast Path (All Templates Present)

When all 7 required files exist in `.github/codeql/` (copied from `.github/templates/codeql`), the installer runs `.github/codeql/install.ps1` directly — no AI agent or CLI involvement needed.

- **Speed**: ~30-60 seconds
- **Requirements**: All template files present in the source repo
- **Trigger**: Automatic when all files are detected

### CLI-Assisted Path (Files Missing)

When some `.github/codeql/` files are missing, the installer delegates to Claude CLI or Copilot CLI to generate them.

- **Speed**: ~3-5 minutes (LLM token generation)
- **Detection priority**: Inside Claude session → Inside Copilot session → Claude CLI available → Copilot CLI available
- **Fallback**: If neither CLI is found, prints manual instructions and exits cleanly

## Pre-Commit Hook

The CodeQL setup installs a git pre-commit hook that runs CodeQL security scanning before every commit. This ensures vulnerabilities are caught before code enters the repository.

### Hook files:
- `.codeql/hooks/pre-commit` — Git pre-commit hook script
- `.codeql/git-secure.ps1` — Windows hook helper
- `.codeql/git-secure.sh` — Unix hook helper

### Scanning:
- `.codeql/scan.ps1` — CodeQL scan script
- `.codeql/codeql-config.yml` — CodeQL query suite and configuration

## Project Layout

After successful installation, the project contains:

```
{project-root}/
├── .github/
│   └── agents/
│       └── speckit.codeql.agent.md   # Agent definition
├── .codeql/
│   ├── scan.ps1                      # CodeQL scan script
│   ├── install.ps1                   # CodeQL installer
│   ├── uninstall.ps1                 # CodeQL uninstaller
│   ├── git-secure.ps1               # Git hook helper (Windows)
│   ├── git-secure.sh                # Git hook helper (Unix)
│   ├── codeql-config.yml            # CodeQL configuration
│   └── hooks/
│       └── pre-commit               # Git pre-commit hook
└── CLAUDE.md                         # CLI routing (CodeQL section)
```

## Prerequisites

- **Git 2.9+** — Required for `core.hooksPath` support (verified at install time)
- **Network access** — Sparse checkout pulls from Azure DevOps source repository
- **Claude CLI or Copilot CLI** — Required only for CLI-assisted path when template files are missing

## CLI Routing

The installer creates or updates `CLAUDE.md` with routing rules that direct CodeQL-related requests to the agent definition at `.github/agents/speckit.codeql.agent.md`. Key rules enforced:

- Do NOT run pre-existing `.ps1` scripts — the agent creates these files fresh
- Do NOT use `powershell -Command` with inline code — always write to a `.ps1` file first
- Follow the agent spec step by step without skipping steps

## Gotchas

- The installer cleans up stale `.codeql/` directories from previous failed attempts before setup
- Git is initialized automatically if the target folder is not already a repository
- Template files from `.github/templates/codeql` are copied to `.codeql/` before CLI invocation to avoid redundant LLM generation
- The `-SkipSetup` flag installs agent files but does not run the CodeQL setup — useful when you want to trigger setup manually via VS Code
