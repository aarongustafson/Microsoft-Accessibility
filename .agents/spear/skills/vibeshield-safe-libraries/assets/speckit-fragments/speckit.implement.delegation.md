<!-- BEGIN:vibeshield-safe-libraries-delegation -->
## Feed Configuration -- Delegate to `@vibeshield-safe-libraries`

For any task involving feed configuration files (`nuget.config`, `.npmrc`, `pip.ini`, `pip.conf`), delegate to `@vibeshield-safe-libraries` with the task description and context.

Do not edit feed configuration files yourself. The agent ensures CFS compliance, installs credential managers, and validates feed URLs.

Mark the task done after the agent completes.
<!-- END:vibeshield-safe-libraries-delegation -->
