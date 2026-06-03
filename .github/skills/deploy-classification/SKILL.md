# deploy-classification

Determine projectType (prototype or businessUse) for a project based on screening answers or prompt signals.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **4-question screening** | Determines project type via PII handling, scope, AI impact, and enterprise integration questions |
| **Prompt signal detection** | Infers project type from user prompt keywords (e.g., "prototype", "production", "POC") |
| **Tenant routing** | Maps `prototype` → TME tenant and `businessUse` → Corp tenant for pipeline configuration |
| **Framework selection input** | Feeds the classification result into `Get-PipelineFramework` for 1ES vs OneBranch routing |

## When to Use

- First-time POC or DEV deployment when `project-config.json` has no `projectType`
- When the orchestrator needs to classify a project before framework resolution

## How It Works

1. If the target environment is Test/UAT/Prod → returns `businessUse` immediately (no screening needed).
2. For POC/DEV, runs the screening sequence: 4 yes/no questions about PII, usage scope, AI/decision impact, and enterprise integrations.
3. Short-circuits on first "yes" → `businessUse`. All "no" → `prototype`. "Not sure" → `businessUse`.
4. Optionally accepts prompt text for signal inference before screening.

## Script

`scripts/Invoke-Classification.ps1` — takes screening answers (or prompt text) and returns `{ ProjectType, Reasoning, ScreeningPath }`.

## Rules

- Never ask "BusinessUse or Prototype?" directly — use directed screening questions.
- Never expose framework jargon (1ES, OneBranch) to the user.
- Default to `businessUse` when uncertain.
- See [classification-strategy.md](../../../docs/classification-strategy.md) for full criteria and examples.
