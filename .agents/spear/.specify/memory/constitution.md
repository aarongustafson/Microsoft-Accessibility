## Governing Document

Before making **any** code change, read and follow principles below.

<!-- BEGIN:automated-agents -->
## Automated Agents

Creation, updates, or validation to Bicep files or PowerShell scripts must use the agents defined in the `.specify/memory/constitution.md` under the **Automated Agents** section. Refer to that section for how to invoke each agent.

These agents are runtime-agnostic spec files. Any AI assistant (Copilot, Claude, Cursor, etc.) that can load and follow the spec can act as the agent — ownership is by role, not by tool. A Claude subagent prompted with the full agent spec **is** the vibeshield agent for that run; a VS Code Copilot session with the agent selected from the dropdown **is** the vibeshield agent for that run. The rule "other agents must not run validation scripts directly" is about role isolation (e.g., `speckit.implement` must not bypass the validator), not about which runtime executes it.

### Delegation Principles — Router, Not Architect

When a main/orchestrating agent delegates work to a vibeshield agent, it acts as a **router**, not an architect. The specialist agent owns domain expertise, MCP server consultation, and user clarification workflows. The delegating agent:

- **MUST** pass through the user's intent unchanged — either their original ad-hoc request or the spec/plan/task artifacts the user and specialist co-developed in earlier phases (common in Spec Kit flows). Either is authoritative; do not interpret, embellish, or override.
- **MUST** include the full, unabridged agent spec file contents — do not summarize or truncate.
- **MUST** add *navigational* context the specialist needs (file paths, what changed, prior conversation state, which artifact to act on). The specialist is stateless; this is not embellishment.
- **MUST NOT** inject design decisions (SKUs, regions, naming, topology) the user did not state and no prior artifact captures. If a detail is under-specified, leave it under-specified — the specialist will consult MCP servers and ask the user.
- **MUST NOT** act as a filter that colors the request. If the user said "I need a Key Vault," delegate "the user needs a Key Vault" — don't add "with Standard SKU in eastus2 using RBAC authorization" unless the user or a co-developed artifact said that.

This prevents a "telephone game" where the orchestrator's assumptions override the specialist's domain knowledge and established consultation workflows.

<!-- BEGIN:vibeshield-powershell -->
### vibeshield-powershell

**Agent file**: `.github/agents/vibeshield-powershell.agent.md`

This agent owns the full PowerShell lifecycle — creating constitution-compliant scripts from the start and validating them against project standards. It **must** be invoked:

- **When creating** a new `.ps1` file — route creation through this agent to ensure constitutional compliance from the start.
- **When significantly modifying** an existing `.ps1` file — use this agent to apply changes with defensive patterns.
- **After any `.ps1` edit** — the agent validates against constitutional standards.
- **During code review** — if any `.ps1` files are changed, invoke the agent to confirm compliance.
- **Before commit or at checkpoints** — delegate a full Tier 2 validation sweep of **all** `.ps1`/`.psm1` files in the repo (not just files changed in this session). When you are not acting as this agent, do not invoke its validation scripts yourself — delegate by spawning/invoking the agent. When you *are* the agent (loaded and following its spec), running the scripts is expected.

Other agents (e.g., `speckit.implement`) should delegate PowerShell script creation, modification, **and validation** to `@vibeshield-powershell` rather than generating PowerShell or running validation scripts directly.

See the agent file for implementation details, defensive patterns, and the validation workflow. Path-specific instructions (`.github/instructions/powershell.instructions.md`) auto-apply when editing `.ps1`/`.psm1` files.

**Invocation:**
- VS Code GitHub Copilot: select `vibeshield-powershell` from the agents dropdown in the Chat view. The agent spec is prepended to your prompt automatically.
- GitHub Copilot CLI: delegate via the `task` tool (`general-purpose` agent, model: `claude-opus-4.6`). Include the full, unabridged agent spec file contents and the user's original request passed through without interpretation. The sub-agent is stateless — include all necessary context (file paths, repo state, what changed). Follow the **Delegation Principles** above.
- Claude Code: spawn a subagent whose prompt is the contents of `.github/agents/vibeshield-powershell.agent.md`
- Any other runtime: load the agent spec and follow it end-to-end
<!-- END:vibeshield-powershell -->
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

Other agents (e.g., `speckit.implement`) should delegate Bicep template creation, modification, **and validation** to `@vibeshield-bicep` rather than generating Bicep or running validation scripts directly.

See the agent file for implementation details, SFI/WAF design patterns, MCP server consultation, and the validation workflow. Path-specific instructions (`.github/instructions/bicep.instructions.md`) auto-apply when editing `.bicep` files.

**Invocation:** Use Claude Opus 4.6 (or later) with 1M-token context — the agent spec, MCP server consultations, and infrastructure files routinely exceed standard context windows.
- VS Code GitHub Copilot: select `vibeshield-bicep` from the agents dropdown in the Chat view. The agent spec is prepended to your prompt automatically.
- GitHub Copilot CLI: delegate via the `task` tool (`general-purpose` agent, model: `claude-opus-4.6-1m`). Include the full user's intent — either their original request (for ad-hoc tasks) or the spec/plan artifacts that were co-developed with vibeshield-bicep in earlier phases. Do not layer your own interpretation on top of either. The sub-agent is stateless — include all necessary context (file paths, repo state, what changed). Follow the **Delegation Principles** above.
- Claude Code: spawn a subagent whose prompt is the contents of `.github/agents/vibeshield-bicep.agent.md`
- Any other runtime: load the agent spec and follow it end-to-end
<!-- END:vibeshield-bicep -->
<!-- END:automated-agents -->


## Core Principles

### I. Secure Infrastructure
This project contains specialized Github Copilot Agents to build secure infrastucture. Defer to them to create, test, and validate code. Even for small changes.

### II. Quality Gates (NON-NEGOTIABLE)
All code must pass automated validation before commit.
- **PowerShell**: All `.ps1`/`.psm1` scripts must pass quality gates before commit. The `@vibeshield-powershell` agent owns validation; the `vibeshield-powershell` skill (`.github/skills/vibeshield-powershell/SKILL.md`) defines the two-tier validation procedure (hook + checkpoint). Scripts with complex logic should include Pester unit tests for critical paths.
- **Bicep**: All `.bicep` templates must pass two-tier validation (lint + PSRule) before commit. The `@vibeshield-bicep` agent owns validation; the `vibeshield-bicep` skill (`.github/skills/vibeshield-bicep/SKILL.md`) defines the validation procedure (lint-on-edit hook + checkpoint with PSRule).
- **Role GUIDs**: All Azure role definition GUIDs added to Bicep or scripts must be validated via `az role definition list`.

### III. Security — Secure Future Initiative (SFI) Compliance (NON-NEGOTIABLE)
Microsoft SFI principles are mandatory:
- **Network isolation**: All deployed resources must enforce network-level isolation (private endpoints, NSGs, service firewalls, NSPs). No resources exposed to the public internet without explicit justification.
- **No local identities**: Resources must not use local accounts, SQL auth, storage keys, or any form of shared secret for authentication. No CosmosDB keys, no Entra App passwords, etc. All service-to-service and user-to-service auth must use **Managed Identity** or **Entra ID (Azure AD)**.
- **No passwords**: Credentials must never appear in code, parameters, or configuration. Use Azure Key Vault references or Managed Identity grants exclusively.
- **No vulnerable components or deprecated libraries**: Code should not use packages that are known to be vulnerable or that are no longer supported.
- **All YAML build pipelines should extend the 1es standard pipeline templates at a minimum**: The standard templates ensure base supply chain security. 
- **Always JIT**: No persistent personal access to production resources (including data plane); use JIT/JEA patterns. Protect the administrator.
- **Least privilege (RBAC)**: Remove over‑privileged role assignments (Owner/Contributor/UAA/RBAC Admin); prefer scoped roles and just‑enough permissions
- **Standard identity middleware**: Adopt and keep current on MISE for token validation on Microsoft-owned web APIs; avoid bespoke JWT validation. Use EasyAuth and WEBSITE_AAD_ENABLE_MISE = true. 

### IV. Well-Architected Framework (WAF)
All infrastructure and scripts must align with the Azure Well-Architected Framework pillars: Reliability, Security, Cost Optimization, Operational Excellence, and Performance Efficiency. Azure Verified Modules start us off with WAF during implementation. PSRule for Azure enforces this during validation. Always validate and iterate.
## Engineering Standards

### Defensive PowerShell
Implementation-level standards for PowerShell defensive coding are defined canonically in the `vibeshield-powershell` agent file (`.github/agents/vibeshield-powershell.agent.md`) and include null handling, pipeline safety (`@()` wrapping), string literal guidance, parameter validation, `SupportsShouldProcess`, and error-handling patterns.

Do not duplicate detailed defensive PowerShell implementation rules in this constitution; maintain them in the `vibeshield-powershell` agent so script-generation and validation behavior stays consistent.

### Bicep Templates
Implementation-level standards for Bicep infrastructure templates are defined canonically in the `vibeshield-bicep` agent file (`.github/agents/vibeshield-bicep.agent.md`) and include SFI security principles, WAF alignment, modular design, AVM-first patterns, and MCP server consultation. Delegate to the vibeshield-bicep for implementation and validation.
Do not duplicate detailed Bicep implementation rules in this constitution; maintain them in the `vibeshield-bicep` agent so template-generation and validation behavior stays consistent. 

### C# Standards

#### Use Test Driven Development (TDD)
- Design all interfaces for testability and mocking so the code is testable.
- Use the red, green, refactor principle.
- Design tests as Arrange, Act, Assert.
- Use the NSubstitute test framework with Roslyn analyzers https://github.com/nsubstitute/NSubstitute/blob/main/README.md 
- Test quality is as important as code quality.
- If a unit test fails, determine why. Do not remove a test as an expedient.
- Unit tests should mock the filesystem and environment in addition to external systems.
- Unit tests are different than integration tests. They should be kept separately.

#### Use newer language and .NET Core framework options when possible
- Use DateTimeOffset whenever possible. DateTimeOffset handles time zone information clearly than the obsolete DateTime.
- Always prefer Path.Join to Path.Combine.
- Use String.IsNullOrWhiteSpace as it is more inclusive than IsNullOrEmpty. 

#### Platform Issues
- Pay attention to System.IO as it behaves differently on Windows vs Linux. 
- Use platform independent commands such as Path.GetTempFileName rather than assuming directories
- Use Environment class instead of assuming environment issues

### Build Output
- All build artifacts (PSRule reports, compiled ARM templates, etc.) are written to `./output/` by default.
- The `./output/` directory is excluded from source control via `.gitignore`.
- **Never** commit generated files to the repository.
- **Never** check in binaries.

### Versioning
* We use [Nerdbank.GitVersioning](https://github.com/dotnet/Nerdbank.GitVersioning) for semantic versioning
- Version format: `{major}.{minor}.{patch}` where patch is automatically calculated from git commit height.
- Bump the minor version at the start of each new plan, spec, or feature.
- See `version.json` in the repo root for configuration.

### Changelog
- Maintain a changelog following the [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format in `CHANGELOG.md` in the repo root.
- Each entry must describe:
  - **Goal**: What was the objective of the change
  - **Why**: Why was this change needed
  - **What**: Brief summary of what was changed

## Governance

This constitution supersedes ad-hoc practices. All code changes — whether via PR or direct commit — must comply with these principles. Amendments to this constitution require documentation and team review.

- Every PR/commit must pass quality gates. **Delegate validation to the owning engineer agents** (`@vibeshield-powershell`, `@vibeshield-bicep`). When you are not acting as the owning agent, do not invoke its validation scripts yourself; when you *are* the agent (following its spec), running the scripts is expected.
- At checkpoints and before commit, every engineer agent must validate **all** code in their domain, not just files changed in the current session.
- Security principles (SFI: network isolation, managed identity, no passwords) are non-negotiable and cannot be waived.
- Complexity must be justified.
- All automated agents listed in the **Automated Agents** section above must be invoked per their documented triggers.

**Version**: 0.35 | **Ratified**: 2026-02-16 | **Last Amended**: 2026-04-18