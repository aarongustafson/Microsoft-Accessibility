# Installation

## Entry Point

`Install-VibeShield.ps1` — installs all Copilot customization assets and scaffolds the Bicep project layout. Idempotent: skips files that exist, always overwrites agent definition and hook to deploy the latest version.

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-VibeShield.ps1
```

## What Gets Installed

- **Copilot assets**: agent definition, path-specific instructions, PostToolUse hook, skill docs + scripts, copilot-instructions entry
- **Project scaffolding** (delegated to `Initialize-BicepProject.ps1`): `infra/` directory, `main.bicep`, `modules/`, PSRule configs, `output/`
- **VS Code settings**: auto-approve pattern for VibeShield terminal commands

See the "Installation" section in [SKILL.md](../SKILL.md) for the full installed-assets table with skip/overwrite behavior per file.

## Scaffolding Only

To scaffold the Bicep project layout without reinstalling Copilot assets:

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Initialize-BicepProject.ps1 -ProjectPath C:\myproject
```

## Prerequisites

- **Azure CLI** with Bicep — `az bicep version` must succeed
- **PSRule.Rules.Azure** module — installed via `Install-Module PSRule.Rules.Azure`
- **PowerShell 7+** — scripts use `pwsh`

## SpecKit Integration

If the project uses SpecKit, `Install-SpecKitIntegration.ps1` patches SpecKit agent files to add Bicep delegation instructions and installs `.specify/extensions.yml` hooks. This runs automatically during full installation if SpecKit agents are detected.

## Idempotency Details

| Category | Behavior |
|----------|----------|
| Path-specific instructions | Skip if exists |
| Agent definition, hook, skill scripts | Always overwrite (ensures latest) |
| Copilot-instructions entry, AGENTS.md fragment | Upsert via marker delimiters |
| Infra scaffolding (main.bicep, modules/, PSRule configs) | Skip if exists |
| VS Code auto-approve | Additive merge into existing settings |
