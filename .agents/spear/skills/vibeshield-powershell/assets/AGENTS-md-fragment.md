<!-- BEGIN:vibeshield-powershell -->
### vibeshield-powershell

**Agent file**: `.github/agents/vibeshield-powershell.agent.md`

This agent owns the full PowerShell lifecycle — creating constitution-compliant scripts from the start and validating them against project standards. It **must** be invoked:

- **When creating** a new `.ps1` file — route creation through this agent to ensure constitutional compliance from the start.
- **When significantly modifying** an existing `.ps1` file — use this agent to apply changes with defensive patterns.
- **After any `.ps1` edit** — the agent validates against constitutional standards.
- **During code review** — if any `.ps1` files are changed, invoke the agent to confirm compliance.
- **Before commit or at checkpoints** — delegate a full Tier 2 validation sweep of **all** `.ps1`/`.psm1` files in the repo (not just files changed in this session). When you are not acting as this agent, do not invoke its validation scripts yourself — delegate by spawning/invoking the agent. When you *are* the agent (loaded and following its spec), running the scripts is expected.

Other agents (e.g., `speckit.implement`) should delegate PowerShell script creation, modification, **and validation** to `vibeshield-powershell` rather than generating PowerShell or running validation scripts directly.

See the agent file for implementation details, defensive patterns, and the validation workflow. Path-specific instructions (`.github/instructions/powershell.instructions.md`) auto-apply when editing `.ps1`/`.psm1` files.

**Invocation:**
- VS Code GitHub Copilot: select `vibeshield-powershell` from the agents dropdown in the Chat view. The agent spec is prepended to your prompt automatically.
- GitHub Copilot CLI: delegate via the `task` tool (`general-purpose` agent, model: `claude-opus-4.6`). Include the full, unabridged agent spec file contents and the user's original request passed through without interpretation. The sub-agent is stateless — include all necessary context (file paths, repo state, what changed). Follow the **Delegation Principles** in the Automated Agents section.
- Claude Code: spawn a subagent whose prompt is the contents of `.github/agents/vibeshield-powershell.agent.md`
- Any other runtime: load the agent spec and follow it end-to-end
<!-- END:vibeshield-powershell -->
