<!-- BEGIN:vibeshield-bicep -->
### vibeshield-bicep

**Agent file**: `.github/agents/vibeshield-bicep.agent.md`

This agent owns Azure infrastructure design and the full Bicep lifecycle — creating constitution-compliant templates from the start and validating them against project standards. It consults MCP servers for current best practices and applies SFI security principles and WAF alignment during design. It **must** be invoked:
- **When designing or extending Azure infrastructure** — user asks to build or host an application, website, API, database, cloud service, Azure resource, or other software system (anything that needs to run on a server rather than only on their own computer). Excludes desktop, mobile, or browser-only apps with no backend.
- **When creating** a new `.bicep` file — route creation through this agent to ensure SFI and WAF compliance from the start.
- **When significantly modifying** an existing `.bicep` file — use this agent to apply changes with best practices.
- **After any `.bicep` edit** — the agent validates against constitutional standards.
- **During code review** — if any `.bicep` files are changed, invoke the agent to confirm compliance.
- **Before commit or at checkpoints** — delegate a full Tier 2 validation sweep of **all** `.bicep` files in the repo (not just files changed in this session). When you are not acting as this agent, do not invoke its validation scripts yourself — delegate by spawning/invoking the agent. When you *are* the agent (loaded and following its spec), running the scripts is expected.

Other agents (e.g., `speckit.implement`) should delegate Bicep template creation, modification, **and validation** to `vibeshield-bicep` rather than generating Bicep or running validation scripts directly.

See the agent file for implementation details, SFI/WAF design patterns, MCP server consultation, and the validation workflow. Path-specific instructions (`.github/instructions/bicep.instructions.md`) auto-apply when editing `.bicep` files.

**Invocation:** Use Claude Opus 4.6 (or later) with 1M-token context — the agent spec, MCP server consultations, and infrastructure files routinely exceed standard context windows.
- VS Code GitHub Copilot: select `vibeshield-bicep` from the agents dropdown in the Chat view. The agent spec is prepended to your prompt automatically.
- GitHub Copilot CLI: delegate via the `task` tool (`general-purpose` agent, model: `claude-opus-4.6-1m` or later). Include the full user's intent — either their original request (for ad-hoc tasks) or the spec/plan artifacts that were co-developed with vibeshield-bicep in earlier phases. Do not layer your own interpretation on top of either. The sub-agent is stateless — include all necessary context (file paths, repo state, what changed). Follow the **Delegation Principles** in the Automated Agents section.
- Claude Code: spawn a subagent whose prompt is the contents of `.github/agents/vibeshield-bicep.agent.md`
- Any other runtime: load the agent spec and follow it end-to-end
<!-- END:vibeshield-bicep -->
