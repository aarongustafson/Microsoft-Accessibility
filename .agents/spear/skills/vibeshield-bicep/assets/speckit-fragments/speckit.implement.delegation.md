<!-- BEGIN:vibeshield-bicep-delegation -->
## Bicep Implementation — Delegate to `@vibeshield-bicep`

You do not have access to the MCP servers and validation tools needed to produce correct Bicep code. The `@vibeshield-bicep` agent does.

For any task involving a `.bicep` file (create, modify, or validate), delegate the task to `@vibeshield-bicep` with:
- The task description and target file path
- Relevant context from the plan (architecture decisions, contracts, resource types)

Do not write Bicep yourself. Mark the task done in tasks.md after the agent completes.

Bicep validation tasks (PSRule, lint) must also be delegated to `@vibeshield-bicep` — do not run validation scripts directly.
<!-- END:vibeshield-bicep-delegation -->
