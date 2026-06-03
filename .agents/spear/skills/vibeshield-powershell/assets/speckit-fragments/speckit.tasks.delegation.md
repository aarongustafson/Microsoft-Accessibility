<!-- BEGIN:vibeshield-powershell-delegation -->
## PowerShell Task Generation Rules

When the plan involves **PowerShell scripts**, two additional rules apply to task generation.

### 1. Annotate PowerShell Tasks for Delegation

Any task that creates or modifies a `.ps1` or `.psm1` file must include `(delegate to @vibeshield-powershell)` in its description. This tells `@speckit.implement` to hand off the task rather than generating PowerShell code directly.

Example:
- `- [ ] T008 [US2] Create deployment script in scripts/Deploy.ps1 (delegate to @vibeshield-powershell)`

### 2. Add PowerShell Validation Checkpoint Tasks

After groups of PowerShell tasks, insert validation checkpoints:
- After each script is complete: `- [ ] T0XX Run @vibeshield-powershell validation`
- In the Final Phase: `- [ ] T0XX Run @vibeshield-powershell pre-commit validation sweep on all .ps1/.psm1 files`

These are delegation tasks — `@speckit.implement` should invoke the agent, not run scripts directly.
<!-- END:vibeshield-powershell-delegation -->
