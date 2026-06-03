---
name: vibeshield-ev2
description: 'Install VibeShield-EV2 agent, prompts, and resources into a project. Sparse-clones the .github/ folder from the ev2-demo-agent GitHub repository and copies agents, prompts, and resources into the target workspace. Wires routing into copilot-instructions.md with idempotent marker blocks. Use when: installing EV2 agents, setting up VibeShield-EV2, adding EV2 deployment skills, onboarding a project with EV2 templates.'
---

# VibeShield-EV2 Installation

## When to Use

- When installing VibeShield-EV2 agents and resources into a new or existing project
- When onboarding a project with EV2 deployment agent definitions, prompts, and resources
- When updating a project to the latest VibeShield-EV2 assets from the source repository

## Installation

**Script:** [`scripts/Install-VibeShield.ps1`](./scripts/Install-VibeShield.ps1) — **install entry point** for the vibeshield-ev2 skill.

Sparse-clones only the `.github/` folder from the ev2-demo-agent GitHub repository and copies agents, prompts, and resources into the target project workspace. Then wires a routing snippet into `.github/copilot-instructions.md` using an idempotent marker block.

**Installed assets:**

| Asset | Path | Behavior |
|-------|------|----------|
| Agents | `.github/agents/` | Recursive copy, overwrite |
| Prompts | `.github/prompts/` | Recursive copy, overwrite |
| Resources | `.github/resources/` | Recursive copy, overwrite |
| Copilot instructions snippet | `.github/copilot-instructions.md` (marker section) | Upsert (idempotent) |

**Usage:**

```powershell
# Install from the default branch:
pwsh -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1

# Specify a source branch:
pwsh -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1 -Branch "main"

# Install into a specific project workspace:
pwsh -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1 -Branch main -ProjectPath "C:\projects\MyApp"
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Branch` | string | `main` | Source branch to pull agent files from |
| `-ProjectPath` | string | Current directory | Project workspace root to install into |

Exit codes: `0` = installation completed successfully, non-zero = failure (clone, copy, or path error).

## Installation Workflow

The installer performs 5 sequential steps:

### Step 1: Validate Prerequisites

Checks that `git` (2.25+) and PowerShell 7+ are available. Validates the target project path exists.

### Step 2: Sparse Clone

Clones the ev2-demo-agent repository with `--depth 1 --filter=blob:none --sparse` and sets sparse-checkout to `.github` only. Uses a temporary directory that is cleaned up on completion.

### Step 3: Copy Assets

Copies `.github/agents`, `.github/prompts`, and `.github/resources` into the target workspace. Uses recursive copy with overwrite for re-installation support.

### Step 4: Wire Copilot Instructions

Extracts the vibeshield-ev2 section from the cloned `.github/copilot-instructions.md` (delimited by `<!-- vibeshield-ev2 start -->` / `<!-- vibeshield-ev2 end -->` markers) and upserts it into the target workspace's `.github/copilot-instructions.md`. If no markers are found in the source, the entire file content is used as the snippet.

Snippet insertion is **idempotent** — existing marker blocks are replaced in-place; missing files are created; files without markers get the snippet appended.

### Step 5: Cleanup

Removes the temporary sparse-clone directory. On failure, cleanup runs in the `finally` block to avoid leaving orphaned temp directories.
