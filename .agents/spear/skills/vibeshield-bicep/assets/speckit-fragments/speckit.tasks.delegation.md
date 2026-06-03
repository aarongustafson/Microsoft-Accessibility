<!-- BEGIN:vibeshield-bicep-delegation -->
## Bicep Task Generation Rules

When the plan involves **Bicep templates**, two additional rules apply to task generation.

### 1. Annotate Bicep Tasks for Delegation

Any task that creates or modifies a `.bicep` file must include `(delegate to @vibeshield-bicep)` in its description. This tells `@speckit.implement` to hand off the task rather than generating Bicep code directly.

Example:
- `- [ ] T005 [P] [US1] Create networking module in infra/modules/networking.bicep (delegate to @vibeshield-bicep)`

### 2. Add Bicep Validation Checkpoint Tasks

After groups of Bicep tasks, insert validation checkpoints:
- After each module is complete: `- [ ] T0XX Run @vibeshield-bicep checkpoint validation`
- After all modules are wired into main.bicep: `- [ ] T0XX Run @vibeshield-bicep full validation`
- In the Final Phase: `- [ ] T0XX Run @vibeshield-bicep pre-commit validation sweep on all .bicep files`

These are delegation tasks — `@speckit.implement` should invoke the agent, not run scripts directly.
<!-- END:vibeshield-bicep-delegation -->
