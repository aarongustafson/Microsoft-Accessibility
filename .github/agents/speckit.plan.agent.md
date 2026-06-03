---
description: Execute the implementation planning workflow using the plan template to generate design artifacts.
handoffs: 
  - label: Create Tasks
    agent: speckit.tasks
    prompt: Break the plan into tasks
    send: true
  - label: Create Checklist
    agent: speckit.checklist
    prompt: Create a checklist for the following domain...
agents: ['vibeshield-bicep', 'vibeshield-powershell', 'vibeshield-safe-libraries']
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before planning)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_plan` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- For each executable hook, output the following based on its `optional` flag:
  - **Optional hook** (`optional: true`):
    ```
    ## Extension Hooks

    **Optional Pre-Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```
  - **Mandatory hook** (`optional: false`):
    ```
    ## Extension Hooks

    **Automatic Pre-Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}

    Wait for the result of the hook command before proceeding to the Outline.
    ```
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Outline

1. **Setup**: Run `.specify/scripts/powershell/setup-plan.ps1 -Json` from repo root and parse JSON for FEATURE_SPEC, IMPL_PLAN, SPECS_DIR, BRANCH. For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

2. **Load context**: Read FEATURE_SPEC and `.specify/memory/constitution.md`. Load IMPL_PLAN template (already copied).

3. **Execute plan workflow**: Follow the structure in IMPL_PLAN template to:
   - Fill Technical Context (mark unknowns as "NEEDS CLARIFICATION")
   - Fill Constitution Check section from constitution
   - Evaluate gates (ERROR if violations unjustified)
   - Phase 0: Generate research.md (resolve all NEEDS CLARIFICATION)
   - Phase 1: Generate data-model.md, contracts/, quickstart.md
   - Phase 1: Update agent context by running the agent script
   - Re-evaluate Constitution Check post-design

4. **Stop and report**: Command ends after Phase 2 planning. Report branch, IMPL_PLAN path, and generated artifacts.

5. **Check for extension hooks**: After reporting, check if `.specify/extensions.yml` exists in the project root.
   - If it exists, read it and look for entries under the `hooks.after_plan` key
   - If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
   - Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
   - For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
     - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
     - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
   - For each executable hook, output the following based on its `optional` flag:
     - **Optional hook** (`optional: true`):
       ```
       ## Extension Hooks

       **Optional Hook**: {extension}
       Command: `/{command}`
       Description: {description}

       Prompt: {prompt}
       To execute: `/{command}`
       ```
     - **Mandatory hook** (`optional: false`):
       ```
       ## Extension Hooks

       **Automatic Hook**: {extension}
       Executing: `/{command}`
       EXECUTE_COMMAND: {command}
       ```
   - If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Phases

### Phase 0: Outline & Research

1. **Extract unknowns from Technical Context** above:
   - For each NEEDS CLARIFICATION → research task
   - For each dependency → best practices task
   - For each integration → patterns task

2. **Generate and dispatch research agents**:

   ```text
   For each unknown in Technical Context:
     Task: "Research {unknown} for {feature context}"
   For each technology choice:
     Task: "Find best practices for {tech} in {domain}"
   ```

3. **Consolidate findings** in `research.md` using format:
   - Decision: [what was chosen]
   - Rationale: [why chosen]
   - Alternatives considered: [what else evaluated]

**Output**: research.md with all NEEDS CLARIFICATION resolved

### Phase 1: Design & Contracts

**Prerequisites:** `research.md` complete

1. **Extract entities from feature spec** → `data-model.md`:
   - Entity name, fields, relationships
   - Validation rules from requirements
   - State transitions if applicable

2. **Define interface contracts** (if project has external interfaces) → `/contracts/`:
   - Identify what interfaces the project exposes to users or other systems
   - Document the contract format appropriate for the project type
   - Examples: public APIs for libraries, command schemas for CLI tools, endpoints for web services, grammars for parsers, UI contracts for applications
   - Skip if project is purely internal (build scripts, one-off tools, etc.)

3. **Agent context update**:
   - Run `.specify/scripts/powershell/update-agent-context.ps1 -AgentType copilot`
   - These scripts detect which AI agent is in use
   - Update the appropriate agent-specific context file
   - Add only new technology from current plan
   - Preserve manual additions between markers

**Output**: data-model.md, /contracts/*, quickstart.md, agent-specific file

## Key rules

- Use absolute paths
- ERROR on gate failures or unresolved clarifications
<!-- BEGIN:vibeshield-bicep-delegation -->
## Infrastructure Planning — Delegate to `@vibeshield-bicep`

When the feature involves **Azure infrastructure**, the `@vibeshield-bicep` agent is your primary research and design partner. It has access to MCP servers with current knowledge of Azure best practices, the Well-Architected Framework, and Azure Verified Modules that you do not have. **Use it.**

### Phase 0 (Research) — Ask `@vibeshield-bicep` First

Do not research Azure infrastructure patterns yourself. Delegate to `@vibeshield-bicep` with the resource types from the spec:

- "What are the current best practices and validated modules for these Azure resource types: [list from spec]?"
- "What Well-Architected Framework guidance applies to this architecture?"
- "What security constraints apply to these resources under SFI?"

The agent consults MCP servers that have authoritative, up-to-date guidance — including Azure Verified Modules (pre-built, WAF-aligned Bicep modules) that can dramatically simplify the implementation. Record its findings in `research.md`.

### Phase 1 (Design & Contracts) — Co-Design with `@vibeshield-bicep`

For infrastructure design decisions, delegate to `@vibeshield-bicep`:

- "Design the module structure for this architecture. Which validated modules exist and which need custom Bicep?"
- "Define the parameter interfaces and contracts for these infrastructure modules."

The agent will produce module designs that are compliant from the start — baking in security and WAF alignment rather than retrofitting after validation failures. Use its output for `data-model.md` and `/contracts/`.
<!-- END:vibeshield-bicep-delegation -->
<!-- BEGIN:vibeshield-powershell-delegation -->
## PowerShell Planning — Delegate to `@vibeshield-powershell`

When the plan includes **PowerShell scripts** (deployment, configuration, testing, automation), delegate script design to `@vibeshield-powershell`:

- "What defensive coding patterns should these scripts follow?"
- "What parameter validation and error handling standards apply?"

The agent ensures scripts are designed for strict mode, null safety, pipeline correctness, and PSScriptAnalyzer compliance from the start — rather than retrofitting after validation failures. Record its guidance in `research.md` alongside other design decisions.
<!-- END:vibeshield-powershell-delegation -->
<!-- BEGIN:vibeshield-safe-libraries-delegation -->
## Package Feed Configuration -- Delegate to `@vibeshield-safe-libraries`

When the plan involves **package dependencies** (NuGet, npm, or pip packages), consult `@vibeshield-safe-libraries` to ensure the project's feed configuration is CFS-compliant:

- "Are the package feed configs set up for this project?"
- "Does the project need feed configuration for a new ecosystem?"
- "What credential managers need to be installed?"

Record any feed setup tasks in the plan as prerequisites for package-dependent work.
<!-- END:vibeshield-safe-libraries-delegation -->

