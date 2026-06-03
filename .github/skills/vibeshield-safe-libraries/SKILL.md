---
name: vibeshield-safe-libraries
description: 'Configure NuGet, Python (pip), and npm to consume packages exclusively from a CFS-backed Azure Artifacts feed. Installs feed configs, credential managers, and a Python virtualenv. Use when: setting up a new project for CFS compliance, onboarding a repo to Central Feed Services, configuring secure package consumption, installing Azure Artifacts credential providers. By default, all new VibeShield projects should use the https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs feed.'
---

# Safe Libraries — Central Feed Services (CFS)

## When to Use

- **When setting up a new project** — run the installer to point NuGet, pip, and npm at the CFS-backed Azure Artifacts feed.
- **When onboarding a repo to CFS** — the installer creates the required config files and credential managers.
- **When a developer joins the team** — ensures their local environment is configured to use the scanned feed.
- **After cloning a project that already has configs** — run the installer to set up credential managers that aren't stored in source control.

## What is CFS?

[Central Feed Services (CFS)](https://aka.ms/cfs) is an integrated feature of Azure Artifacts that protects against supply-chain threats from public package sources — typo-squatting, dependency confusion, compromised maintainer accounts, and more. Every package consumed through a CFS-enabled feed is scanned for malware, vulnerabilities, and other security policies before ingestion. Existing packages are also subject to continuous scanning.

**CFS is the Microsoft Engineering Systems Standard for secure package consumption.** All production repositories must onboard.

## Installation

**Script:** [`scripts/Install-VibeShield.ps1`](./scripts/Install-VibeShield.ps1) — **install entry point** for the vibeshield-safe-libraries skill.

The top-level VibeShield installer calls this script to configure CFS feed access. It can also be run directly for standalone adoption.

**What it does:**

| Ecosystem | Config File | Credential Manager | Placement |
|-----------|------------|-------------------|-----------|
| NuGet (.NET) | `nuget.config` | `artifacts-credprovider` | Project root |
| Python (pip) | `pip.ini` / `pip.conf` | `keyring` + `artifacts-keyring` | `.venv/` virtualenv |
| npm (Node.js) | `.npmrc` | `vsts-npm-auth` | Project root |

**Behavior:**
- **Idempotent with CFS detection:** If a config file already exists and matches the CFS asset, the installer skips it. If it exists with different content, the installer validates whether the existing config points to a known internal CFS-backed ADO organization. Valid internal configs are **skipped** (preserving the team's working feed). Partially valid configs (e.g., NuGet missing `<clear />`, pip with `extra-index-url`) are **fixed in place**. Invalid configs (public feeds, unknown orgs, malformed files) are **backed up** (`.bak`) then **replaced** with the CFS version.
- **Tool detection:** If `dotnet`, `python`/`python3`, or `npm` is not installed, that ecosystem is skipped with a warning (not a failure). For npm, the installer also probes `~/.agency/nodejs/node-vX.Y.Z-<platform>/` for an Agency-managed Node.js installation before skipping. If npm is found there (as `npm.cmd` on Windows or `npm` on Linux/macOS), it is added to PATH and npm configuration proceeds.
- **Virtualenv:** Auto-creates a `.venv` directory if one doesn't exist. Requires the selected Python (`python3` or `python`) to have both `ensurepip` and `venv` modules available; if either is missing the installer fails closed with platform-specific remediation guidance (e.g., `sudo apt install -y python3-venv` on Debian/Ubuntu). Managed venvs are tracked via a `.venv/.vibeshield-managed` sentinel file; structurally damaged managed venvs are automatically removed and recreated, while damaged unmanaged venvs are preserved with a manual-remediation message.
- **Keyring before config:** The pip installer installs `keyring` + `artifacts-keyring` from public PyPI before copying the CFS pip config into the venv. This avoids a circular dependency where pip would need the auth packages to access the feed that hosts those same packages.
- **Gitignore:** Creates or updates `.gitignore` to exclude `.venv/`.
- **Connectivity check:** Advisory warning if the feed is unreachable (does not fail).

**Usage:**

```powershell
# Called by the top-level VibeShield installer, or run directly:
pwsh -NoProfile -File skills/vibeshield-safe-libraries/scripts/Install-VibeShield.ps1

# With explicit project path:
pwsh -NoProfile -File skills/vibeshield-safe-libraries/scripts/Install-VibeShield.ps1 -ProjectPath C:\myproject
```

Exit codes: `0` = success, `1` = error (config already exists, assets not found, or critical failure).

## Available Scripts

- **`scripts/Install-VibeShield.ps1`** -- Install entry point (see [Installation](#installation) above). Configures all three ecosystems, installs credential managers, creates virtualenv, and installs governance assets (instructions, agent definition, AGENTS.md/CLAUDE.md fragments, spec-kit integration).
- **`scripts/Install-VibeShieldFragment.ps1`** -- Generic marker-based fragment injector for idempotent content injection into Markdown files.
- **`scripts/Install-SkillRuntime.ps1`** -- Copies SKILL.md and runtime scripts to `.github/skills/vibeshield-safe-libraries/` in the target project.
- **`scripts/Install-SpecKitIntegration.ps1`** -- Injects delegation fragments into spec-kit agent files so they delegate feed config work to `@vibeshield-safe-libraries`.
- **`scripts/Install-AutoApproveSettings.ps1`** -- Adds per-script VS Code auto-approve entries for terminal commands.
- **`scripts/Resolve-RepoRoot.ps1`** -- Shared utility that resolves the repository root by walking up to find `.git`.

## Agent Invocation

This skill is promoted to an **automated agent** in the project governance. The installer injects a `<!-- BEGIN:vibeshield-safe-libraries -->` section into AGENTS.md, CLAUDE.md, and `.github/copilot-instructions.md` so that all agents know to delegate feed configuration to `@vibeshield-safe-libraries`.

**Agent definition:** `.github/agents/vibeshield-safe-libraries.agent.md` (installed by `Install-VibeShield.ps1`)

**Triggers for invocation:**
- When onboarding a new project or repo
- When adding a new package ecosystem (NuGet, npm, pip)
- When modifying feed configuration files (`nuget.config`, `.npmrc`, `pip.ini`/`pip.conf`)
- After any feed config edit -- validate CFS compliance
- Before commit -- verify all feed configs point to CFS, not public registries

**Governance assets installed:**

| Asset | Target Path | Behavior |
|-------|-------------|----------|
| Path-specific instructions | `.github/instructions/safe-libraries.instructions.md` | Skip if exists |
| Copilot instructions entry | `.github/copilot-instructions.md` | Idempotent marker injection |
| AGENTS.md / CLAUDE.md entry | Root-level files | Idempotent marker injection |
| Agent definition | `.github/agents/vibeshield-safe-libraries.agent.md` | Always overwrite |
| Skill runtime | `.github/skills/vibeshield-safe-libraries/` | Always overwrite |
| Spec-kit integration | `.github/agents/speckit.*.agent.md` | Idempotent |

## Feed Details

All three ecosystems point at the same Azure DevOps project-scoped feed with CFS enabled:

| Protocol | Feed URL |
|----------|----------|
| NuGet v3 | `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/nuget/v3/index.json` |
| PyPI (pip) | `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/pypi/simple/` |
| npm | `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/npm/registry/` |

**Feed portal:** <https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_artifacts>

VibeShield contributors are contributors on this feed. When they add packages to their project, those packages flow into the feed and benefit from CFS scanning.

## Procedure

### First-Time Setup

1. Run the installer:
   ```powershell
   pwsh -NoProfile -File skills/vibeshield-safe-libraries/scripts/Install-VibeShield.ps1 -ProjectPath <path>
   ```
2. The installer will configure all detected ecosystems, install credential managers, and create a Python virtualenv.
3. Review the output for any warnings (missing tools, unreachable feed).

### npm Per-Session Authentication

After the initial install, you must run this command **once per terminal session** before using npm with the ADO feed:

```bash
npx vsts-npm-auth -config .npmrc
```

This refreshes your Azure DevOps authentication token for npm. The NuGet and pip credential managers handle authentication automatically.

### Verifying Configuration

```powershell
# NuGet — verify feed is reachable:
dotnet restore --configfile nuget.config

# pip — activate venv and verify:
.venv/Scripts/Activate.ps1   # Windows
# source .venv/bin/activate  # Linux/Mac
pip install --dry-run <some-package>

# npm — verify after auth:
npx vsts-npm-auth -config .npmrc
npm install --dry-run <some-package>
```

## Gotchas

- **Existing valid CFS configs are preserved.** If a config file already points to a known internal CFS-backed ADO feed (from any org in the known-org list), the installer skips it -- even if the content differs from the default asset. Partially valid configs are fixed in place (e.g., adding `<clear />` to NuGet, removing `extra-index-url` from pip). Invalid configs (public feeds, unknown orgs) are backed up to `.bak` then replaced.
- **npm auth is per-session.** Unlike NuGet and pip, npm requires running `npx vsts-npm-auth -config .npmrc` once per terminal session.
- **Linux `artifacts-keyring` prerequisites.** On Linux, the `artifacts-keyring` package may require additional system packages. See the ADO feed's "Connect to feed" dialog for details.
- **`pip.ini` vs `pip.conf`.** Windows uses `pip.ini`; Linux and macOS use `pip.conf`. The installer handles this automatically.
- **`.venv/` should not be committed.** The installer adds `.venv/` to `.gitignore`. If your project uses a different virtualenv directory name, update `.gitignore` accordingly.
- **Credential providers are user-scoped.** `artifacts-credprovider` (NuGet) and `artifacts-keyring` (pip) are installed to the user profile, not the project. `vsts-npm-auth` is installed globally via npm.
- **Python `venv` and `ensurepip` are prerequisites.** On some Linux distributions, `python3` ships without the `venv` and `ensurepip` modules. If the installer detects this, it will prompt you to run `sudo apt install -y python3-venv`. On Windows, reinstalling Python with default options resolves this.

## References

- [AGENTS.md](../../AGENTS.md) — Project constitution and governance
- [references/safe-libraries-cfs.md](./references/safe-libraries-cfs.md) — Detailed design, implementation notes, and CFS reference links
- [references/cfs-detection-overview.md](./references/cfs-detection-overview.md) — CFS detection overview (shared concepts, org list, backup policy)
- [references/cfs-detection-nuget.md](./references/cfs-detection-nuget.md) — NuGet CFS detection (XML validation, `<clear />` fix-in-place, test matrix)
- [references/cfs-detection-npm.md](./references/cfs-detection-npm.md) — npm CFS detection (`.npmrc` parsing, scoped-registry checks, test matrix)
- [references/cfs-detection-pip.md](./references/cfs-detection-pip.md) — pip CFS detection (INI parsing, `extra-index-url`/`find-links` safety, test matrix)
