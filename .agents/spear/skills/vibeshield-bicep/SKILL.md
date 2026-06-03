---
name: vibeshield-bicep
description: 'Set up and validate Bicep projects. Setup: scaffolds infra directory with main.bicep entry point, modules folder, and PSRule configs. Validation: lints Bicep via az bicep lint and runs PSRule for Azure with file expansion against main.bicep. Use when: scaffolding a new Bicep project, validating Bicep, checking infrastructure code quality, running PSRule, enforcing WAF compliance on .bicep files, verifying SFI security compliance, linting Bicep templates, compiling Bicep to ARM JSON.'
---

# Bicep Setup & Validation

## Prerequisites

This skill's agent relies on two VS Code extensions for MCP server consultation during design:

- **`ms-azuretools.vscode-bicep`** -- Bicep language server, lint, and Bicep MCP tools (`get_bicep_best_practices`, `list_avm_metadata`)
- **`ms-azuretools.vscode-azure-mcp-server`** -- Azure MCP Server tools (`get_bestpractices`, resource schema queries)

The install script (`Install-VsCodeExtensions.ps1`) recommends these in `.vscode/extensions.json` and attempts installation automatically. If MCP calls fail during agent use, verify these extensions are installed and enabled in VS Code.

For **Copilot CLI** users (terminal-based agent), a project-level `.mcp.json` file at the repo root is required. The install script (`Install-McpConfig.ps1`) creates or updates this file and installs both MCP servers as .NET global tools (`Azure.Bicep.McpServer` and `azure.mcp`). If MCP tools are unavailable in Copilot CLI, verify `.mcp.json` exists at the project root and that both tools are installed (`dotnet tool list -g`).

## When to Use

### Setup (scaffolding a new project)
- When starting a new Bicep infrastructure project
- When the `infra/` directory does not exist yet
- When PSRule config files need to be initialized for dev/prod environments

### Validation
- After creating or modifying any `.bicep` file (lint-only via hook, automatic)
- At checkpoint triggers during a session (full lint + PSRule, manual):
  - After completing each Bicep module (local or AVM registry)
  - After wiring up module references in `main.bicep`
  - After fixing PSRule violations (confirm fixes, catch regressions)
  - When switching infrastructure layers (e.g., networking → compute)
  - After any significant refactor (monolith → modules, custom → AVM)
- **Always** before declaring work complete or committing Bicep infrastructure changes
- During code review of Bicep templates
- When asked to validate infrastructure code quality
- When compiling Bicep to ARM JSON (use `-GenerateARM` flag)

## Installation

**Script:** [`scripts/Install-VibeShield.ps1`](./scripts/Install-VibeShield.ps1) — **install entry point** for the vibeshield-bicep skill.

Called by the top-level VibeShield installer, or run directly for standalone adoption.

Installs Copilot customization assets into the project, then delegates to `Initialize-BicepProject.ps1` to scaffold the standard Bicep project layout. Idempotent — skips files that already exist, and always overwrites the agent definition and hook to ensure the latest version is deployed.

**Installed assets:**

| Asset | Path | Behavior |
|-------|------|----------|
| Path-specific instructions | `.github/instructions/bicep.instructions.md` | Skip if exists |
| Copilot instructions entry | `.github/copilot-instructions.md` (marker section) | Upsert (idempotent) |
| Agent definition | `.github/agents/vibeshield-bicep.agent.md` | Always overwrite |
| PostToolUse hook | `.github/hooks/validate-bicep.json` | Always overwrite |
| Skill documentation | `.github/skills/vibeshield-bicep/SKILL.md` | Always overwrite |
| Validation scripts | `.github/skills/vibeshield-bicep/scripts/` (4 runtime scripts) | Always overwrite |
| VS Code auto-approve | `.vscode/settings.json` (auto-approve pattern) | Additive merge |
| MCP config | `.mcp.json` (project root) | Create or additive merge |

**Delegated to `Initialize-BicepProject.ps1`:** `infra/`, `infra/main.bicep`, `infra/modules/`, `PSRule.dev.yaml`, `PSRule.prod.yaml`, `output/`

**Delegated to `Install-McpConfig.ps1`:** `.mcp.json` — Copilot CLI MCP server configuration at the repo root. Creates from asset template if missing, or adds server entries for Bicep/Azure MCP if the file exists but lacks them.

**Usage:**

```powershell
# Called by the top-level VibeShield installer, or run directly:
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1

# With explicit project path:
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1 -ProjectPath C:\myproject
```

Exit codes: `0` = installation completed successfully (items created and/or skipped).

See [Procedure → Skill installation](#skill-installation-first-time) below for scaffolding-only options.

## Available Scripts

- **`scripts/Install-VibeShield.ps1`** — Install entry point (see [Installation](#installation) above). Installs Copilot customization assets and delegates to `Initialize-BicepProject.ps1` for project scaffolding.
- **`scripts/Initialize-BicepProject.ps1`** — Scaffolds the default Bicep project layout: creates `infra/`, `infra/main.bicep`, `infra/modules/`, copies `PSRule.dev.yaml` / `PSRule.prod.yaml` from skill assets, creates `output/` directory, and ensures `.gitignore` covers it. Idempotent — skips anything that already exists. Does not install Copilot assets (that's handled by `Install-VibeShield.ps1`).
- **`scripts/Install-McpConfig.ps1`** — Installs Copilot CLI MCP server configuration. Creates `.mcp.json` at the repo root from the skill asset template if missing, or additively merges server entries if the file exists but lacks the required Bicep/Azure MCP servers. Preserves existing MCP server configurations. Always exits 0.
- **`scripts/Invoke-BicepLint.ps1`** -- Lints a single `.bicep` file via `az bicep lint`. Fast, lightweight -- used by the PostToolUse hook for instant syntax feedback on every edit. Always emits SARIF to stdout.
- **`scripts/Invoke-BicepValidation.ps1`** -- Checkpoint validation: lints `infra/main.bicep` via `az bicep lint` (which validates all module dependencies) and runs PSRule with file expansion for WAF compliance. Always writes SARIF to `./output/`. Supports `-Environment dev|prod` to select PSRule config.

All validation scripts share the same exit code contract: `0` = pass, `1` = violations found.

## Project Layout

The setup script creates this standard structure:

```
{project-root}/
├── infra/
│   ├── main.bicep          # Main deployment entry point
│   ├── modules/            # Reusable Bicep modules
│   ├── PSRule.dev.yaml     # PSRule config for dev environment
│   └── PSRule.prod.yaml    # PSRule config for prod environment
└── output/                 # Build artifacts (gitignored)
```

PSRule configs use file expansion (`AZURE_BICEP_FILE_EXPANSION: true`) and target only `main.bicep` via `pathIgnore`. Modules are analyzed through expansion — not individually.

## Procedure

### Skill installation (first time)

Installs Copilot customization assets and scaffolds the Bicep project layout:

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1
```

With a specific project path:

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1 -ProjectPath C:\myproject
```

To scaffold only the Bicep project layout (without reinstalling Copilot assets):

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Initialize-BicepProject.ps1 -ProjectPath C:\myproject
```

### Lint on edit (fast — used by hooks)

The PostToolUse hook automatically runs this after every `.bicep` edit. You can also run it manually for quick syntax checks:

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepLint.ps1 -FilePath infra/main.bicep
```

This runs only `az bicep lint` (syntax + lint). PSRule is skipped for speed.

### Checkpoint validation (lint + PSRule — before commit)

Use this at checkpoints during a session and always before committing:

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -Environment dev
```

To compile to ARM JSON (output written to `./output/`):

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -GenerateARM
```

### Validation loop

1. Run the appropriate script (single-file or full)
2. Review the output — every lint error and PSRule violation must be fixed
3. Re-run until exit code is `0`

## PSRule Expansion Model

PSRule is configured to analyze only `main.bicep` via `pathIgnore` and expand all module references via `AZURE_BICEP_FILE_EXPANSION: true`. This means:

- **Modules are not analyzed individually** — they are analyzed through expansion from `main.bicep`
- **AVM registry modules** (`br:mcr.microsoft.com/bicep/avm/...`) are expanded and analyzed identically to local modules.
- **One PSRule invocation** covers the entire deployment graph
- **Environment-specific configs** (`PSRule.dev.yaml`, `PSRule.prod.yaml`) control which rules are enforced and which are relaxed per environment

## Gotchas

- PSRule.Rules.Azure module first-load is slow (~10s). Subsequent runs are faster.
- `az bicep lint` requires Azure CLI to be installed. The scripts check and error early if missing.
- Files under `output/` and `.specify/` are excluded from validation.
- The single-file script returns exit code `2` for invalid arguments (file not found, wrong extension, excluded path).
- If no PSRule config is found in `infra/`, PSRule runs with defaults. Run `Initialize-BicepProject.ps1` to copy config files.

## Two-Tier Validation Model

This skill provides two tiers of validation. Both are required — tier 1 does not replace tier 2.

### Tier 1: Lint-on-edit (automatic, fast)

A PostToolUse hook (`.github/hooks/validate-bicep.json`) can be installed from the skill to automatically **lint** the edited file (syntax only, no PSRule) after every `.bicep` edit in Copilot agent sessions. This catches syntax errors and lint warnings within seconds without the overhead of PSRule module loading. Results are returned as SARIF JSON.

### Tier 2: Checkpoint validation (manual, comprehensive)

The agent invokes `Invoke-BicepValidation.ps1` at checkpoint triggers (see "When to Use"). This runs lint + PSRule with file expansion, catching WAF alignment violations, SFI configuration gaps, and inter-module composition issues that lint alone cannot detect.

**Tier 1 is your spellchecker. Tier 2 is your code review. Both are required.**

The agent should run `Invoke-BicepValidation.ps1` (lint + PSRule) at every checkpoint trigger listed above and always before declaring work complete or committing.

### What checkpoint validation catches (that lint misses)

PSRule with file expansion detects issues that are invisible to `az bicep lint`:

- **WAF alignment**: missing availability zones, no diagnostic settings, storage accounts without HTTPS-only, missing redundancy configurations
- **SFI compliance**: public network access enabled, missing managed identity configuration, deprecated API versions, resources without network isolation
- **Module composition**: parameter mismatches or missing required configurations that only surface when modules are expanded from `main.bicep`

These issues are invisible to lint alone.

## SARIF Output

All validation scripts emit SARIF v2.1.0 structured output:

- **Tier 1** (hook): `Invoke-BicepLint.ps1` always emits native SARIF via `az bicep lint --diagnostics-format sarif`.
- **Tier 2** (checkpoint): `Invoke-BicepValidation.ps1` always writes SARIF to `./output/`:
  - `./output/bicep-lint-results.sarif` -- lint results from `az bicep lint`
  - `./output/psrule-results.sarif` -- PSRule WAF/SFI analysis results

Agents should read SARIF files for structured results. Do not pipe, filter, or post-process console output.

## Terminal Command Contract

All terminal commands for this skill **must** use the following format:

```
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/<Script>.ps1 [parameters]
```

### Allowed commands and parameters

| Script | Parameters |
|--------|-----------|
| `Invoke-BicepLint.ps1` | `-FilePath <path>` (required), `-RepoRoot <path>` |
| `Invoke-BicepValidation.ps1` | `-RepoRoot <path>`, `-Environment dev\|prod`, `-GenerateARM` |
| `Initialize-BicepProject.ps1` | `-ProjectPath <path>` |

### Forbidden patterns

- `pwsh -NoProfile -Command` with any inline code
- Piping output: `| Out-String`, `| Select-Object`, `| Select-String`, `| Tee-Object`, `| Out-File`
- Wrapping: `Set-Location '...'; pwsh ...`, `& { Set-StrictMode ... }`, `& { ... 2>&1 | ... }`
- Stderr redirection: `2>&1 | Out-String`, `2>&1`
- Direct tool calls: `az bicep build` (use the wrapper scripts), `az bicep lint` (use `Invoke-BicepLint.ps1`)

All output formatting, filtering, and file-writing is handled by script parameters. Tier 1 always emits SARIF to stdout. Checkpoint scripts always write SARIF to `./output/`. Do not pipe or wrap.

### Diagnostic escape hatch

If you need to run a diagnostic command that is not covered by these scripts (e.g., checking Azure CLI version, verifying Bicep installation), explain what you are investigating and why the standard scripts cannot answer it. The user will see an approval prompt -- provide enough context so the approval is informed, not reflexive.

## VS Code Auto-Approve

The installer ([`Install-AutoApproveSettings.ps1`](./scripts/Install-AutoApproveSettings.ps1)) automatically adds the auto-approve pattern to `.vscode/settings.json`. Additive and idempotent — existing settings and other auto-approve keys are preserved.

## References

Deeper documentation is available in the `references/` folder — loaded on demand when needed, not preloaded:

- [`references/installation.md`](references/installation.md) — Installation workflow, prerequisites, idempotency details
- [`references/validation.md`](references/validation.md) — Two-tier validation deep-dive (Tier 1 lint vs Tier 2 PSRule)
- [`references/infra-folder.md`](references/infra-folder.md) — Scaffolded `infra/` folder layout and purpose of each file
- [`references/naming-conventions.md`](references/naming-conventions.md) — Resource naming system, functions, and MCP consultation guidance
- [`references/psrule-sync.md`](references/psrule-sync.md) — PSRule static placeholder synchronization with Config.ps1
- [`references/vscode-extensions.md`](references/vscode-extensions.md) — VS Code extension recommendations strategy and troubleshooting

## Constitution Reference

See `.specify/memory/constitution.md` sections:
- **Quality Gates** — Bicep lint + PSRule is a non-negotiable quality gate
- **Bicep Templates** — Modularity, readability, maintainability standards
- **Security — SFI Compliance** — Network isolation, managed identity, no secrets
- **Well-Architected Framework** — PSRule enforces WAF pillar alignment
