<!-- BEGIN:vibeshield-powershell-delegation -->
## PowerShell Implementation — Delegate to `@vibeshield-powershell`

For any task involving a `.ps1` or `.psm1` file (create or significantly modify), delegate to `@vibeshield-powershell` with the task description and context from the plan.

Do not write PowerShell yourself. The agent applies defensive coding patterns and validates against PSScriptAnalyzer. Mark the task done in tasks.md after the agent completes.

PowerShell validation tasks (PSScriptAnalyzer) must also be delegated — do not run validation scripts directly.
<!-- END:vibeshield-powershell-delegation -->
