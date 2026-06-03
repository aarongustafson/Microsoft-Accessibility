---
name: vibeshield-deploy
description: 'Install VibeShield-Deploy agents, skills, prompts, and templates into a project. Sparse-clones the .github/ folder from the VibeShield-Deploy repository and wires routing into agent.md, CLAUDE.md, and copilot-instructions.md. Use when: installing deployment agents, setting up VibeShield-Deploy, adding deployment skills to a project, configuring deployment pipelines, onboarding a project with deploy templates.'
---

# VibeShield-Deploy Installation

## When to Use

- When installing VibeShield-Deploy agents and skills into a new or existing project
- When onboarding a project with deployment templates, prompts, and agent definitions
- When updating a project to the latest VibeShield-Deploy assets from the source repository

## Installation

**Script:** [`scripts/Install-VibeShield.ps1`](./scripts/Install-VibeShield.ps1) — **install entry point** for the vibeshield-deploy skill.

Sparse-clones only the `.github/` folder from the VibeShield-Deploy repository and copies agents, skills, prompts, hooks, instructions, and templates into the target project workspace. Then wires routing snippets into `agent.md`, `CLAUDE.md`, and `copilot-instructions.md` using idempotent marker blocks.

**Installed assets:**

| Asset | Path | Behavior |
|-------|------|----------|
| Agents | `.github/agents/` | Recursive copy, overwrite |
| Prompts | `.github/prompts/` | Recursive copy, overwrite |
| Skills | `.github/skills/` | Recursive copy, overwrite |
| Hooks | `.github/hooks/` | Recursive copy, overwrite |
| Instructions | `.github/instructions/` | Recursive copy, overwrite |
| Templates | `.github/templates/` | Recursive copy, overwrite |
| Agent routing snippet | `agent.md` (marker section) | Upsert (idempotent) |
| Claude routing snippet | `CLAUDE.md` (marker section) | Upsert (idempotent) |
| Copilot instructions snippet | `.github/copilot-instructions.md` (marker section) | Upsert (idempotent) |

**Usage:**

```powershell
# Install from the default branch:
powershell -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1

# Specify a source branch:
powershell -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1 -Branch "main"

# Install into a specific project workspace:
powershell -ExecutionPolicy Bypass -NoProfile -File scripts/Install-VibeShield.ps1 -Branch main -TargetPath "C:\projects\MyApp"
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Branch` | string | `main` | Source branch to pull agent files from |
| `-TargetPath` | string | Current directory | Project workspace root to install into |

Exit codes: `0` = installation completed successfully, non-zero = failure (clone, copy, or path error).

## Available Scripts

- **`scripts/Install-VibeShield.ps1`** — Install entry point (see [Installation](#installation) above). Sparse-clones `.github/` from the source repo, copies asset subdirectories, and wires routing snippets into project root files.

## Installation Workflow

The installer performs 5 sequential steps:

### Step 1: Sparse Clone

Initializes a temporary git repository and configures sparse checkout to fetch only the `.github/` directory. This keeps the clone minimal and avoids pulling application code.

### Step 2: Fetch Branch

Fetches a single branch at depth 1 from the VibeShield-Deploy repository. Validates the branch exists on the remote before proceeding.

### Step 3: Copy Assets

Copies the `.github/` folder contents into the target workspace. Uses wildcard copy to merge into an existing `.github/` directory without nesting.

Only these subdirectories are copied: `agents`, `prompts`, `skills`, `hooks`, `instructions`, `templates`.

### Step 4: Wire Routing Snippets

Updates three routing files with marker-delimited sections from `.github/snippets/`:

| Snippet source | Target file | Marker format |
|----------------|-------------|---------------|
| `.github/snippets/agent.md` | `agent.md` | `<!-- vibeshield-deploy-start/end -->` |
| `.github/snippets/CLAUDE.md` | `CLAUDE.md` | `# vibeshield-deploy-start/end` |
| `.github/snippets/copilot-instructions.md` | `.github/copilot-instructions.md` | `<!-- vibeshield-deploy-start/end -->` |

Snippet insertion is **idempotent** — existing marker blocks are replaced in-place; missing files are created; files without markers get the snippet appended.

### Step 5: Cleanup

Removes the temporary sparse-clone directory. On failure, cleanup runs in the `catch` block to avoid leaving orphaned temp directories.

## Project Layout

After successful installation, the project contains:

```
{project-root}/
├── .github/
│   ├── agents/          # Agent definitions
│   ├── prompts/         # Prompt templates
│   ├── skills/          # Skill definitions and scripts
│   ├── hooks/           # PostToolUse hooks
│   ├── instructions/    # Path-specific instructions
│   └── templates/       # Deployment templates
├── agent.md             # Agent routing (vibeshield-deploy section)
└── CLAUDE.md            # Claude CLI routing (vibeshield-deploy section)
```

## Prerequisites

- **Git** — Required for sparse checkout
- **Network access** — Fetches from Azure DevOps source repository
- **Write access** — Must be able to write to the target workspace directory
