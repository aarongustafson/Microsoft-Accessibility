<!-- BEGIN:vibeshield-safe-libraries -->
### vibeshield-safe-libraries

**Agent file**: `.github/agents/vibeshield-safe-libraries.agent.md`

This agent owns CFS-backed package feed configuration for all ecosystems (NuGet, npm, pip) -- ensuring packages are consumed exclusively through scanned Azure Artifacts feeds, not directly from public registries. CFS is one layer of supply-chain protection; additional component governance checks are enforced separately. It **must** be invoked:

- **When onboarding a new project or repo** -- run the installer to configure all detected package ecosystems for CFS compliance.
- **When adding a new package ecosystem** (NuGet, npm, or pip) to a project that was not previously using it -- ensure the new ecosystem's feed config points to CFS.
- **When modifying feed configuration files** (`nuget.config`, `.npmrc`, `pip.ini`/`pip.conf`) -- validate that changes maintain CFS compliance and do not revert to public registries.
- **After any feed config edit** -- verify the config still points to the CFS-backed feed and has not been corrupted or overwritten by tooling.
- **Before commit or at checkpoints** -- verify all feed configs in the repo point to CFS, not public registries. When you are not acting as this agent, do not modify feed configs yourself — delegate by spawning/invoking the agent. When you *are* the agent (loaded and following its spec), modifying and validating feed configs is expected.

Other agents (e.g., `speckit.implement`) should delegate feed configuration creation, modification, **and validation** to `vibeshield-safe-libraries` rather than editing feed config files directly.

See the agent file for feed configuration standards, validation workflow, and the skill file (`.github/skills/vibeshield-safe-libraries/SKILL.md`) for installation details, feed URLs, and credential manager setup. Path-specific instructions (`.github/instructions/safe-libraries.instructions.md`) auto-apply when editing feed config files.

**Invocation:**
- VS Code GitHub Copilot: select `vibeshield-safe-libraries` from the agents dropdown in the Chat view. The agent spec is prepended to your prompt automatically.
- GitHub Copilot CLI: delegate via the `task` tool (`general-purpose` agent, model: `claude-opus-4.6`). Include the full, unabridged agent spec file contents and the user's original request passed through without interpretation. The sub-agent is stateless — include all necessary context (file paths, repo state, what changed). Follow the **Delegation Principles** in the Automated Agents section.
- Claude Code: spawn a subagent whose prompt is the contents of `.github/agents/vibeshield-safe-libraries.agent.md`
- Any other runtime: load the agent spec and follow it end-to-end
<!-- END:vibeshield-safe-libraries -->
