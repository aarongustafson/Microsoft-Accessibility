<!-- BEGIN:vibeshield-safe-libraries-delegation -->
## Feed Configuration Task Generation Rules

When the plan involves **package dependencies** or **feed configuration**, two additional rules apply to task generation.

### 1. Annotate Feed Configuration Tasks for Delegation
Any task that creates or modifies a feed configuration file (`nuget.config`, `.npmrc`, `pip.ini`, `pip.conf`) must include `(delegate to @vibeshield-safe-libraries)` in its description.

Example: `- [ ] T003 [P] [US1] Configure CFS-backed NuGet feed (delegate to @vibeshield-safe-libraries)`

### 2. Add Feed Validation Checkpoint Tasks
After feed configuration tasks, insert a validation checkpoint:
- `- [ ] T0XX Run @vibeshield-safe-libraries feed validation to verify CFS compliance`
<!-- END:vibeshield-safe-libraries-delegation -->
