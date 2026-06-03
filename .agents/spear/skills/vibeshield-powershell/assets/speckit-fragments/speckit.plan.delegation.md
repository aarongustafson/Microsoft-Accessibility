<!-- BEGIN:vibeshield-powershell-delegation -->
## PowerShell Planning — Delegate to `@vibeshield-powershell`

When the plan includes **PowerShell scripts** (deployment, configuration, testing, automation), delegate script design to `@vibeshield-powershell`:

- "What defensive coding patterns should these scripts follow?"
- "What parameter validation and error handling standards apply?"

The agent ensures scripts are designed for strict mode, null safety, pipeline correctness, and PSScriptAnalyzer compliance from the start — rather than retrofitting after validation failures. Record its guidance in `research.md` alongside other design decisions.
<!-- END:vibeshield-powershell-delegation -->
