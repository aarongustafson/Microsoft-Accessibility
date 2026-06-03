<!-- BEGIN:vibeshield-bootstrap -->
Run the VibeShield bootstrap before the first build or commit if the workspace is not initialized.
Installer command (PowerShell): & ([scriptblock]::Create((irm https://aka.ms/vibeshieldinstall)))
Installer command (Bash/Linux/macOS): bash <(curl -fsSL https://aka.ms/vibeshieldinstallsh)
Governance updates are checked automatically on git push via the pre-push hook.
To manually check for updates: git submodule update --remote .agents/spear .github/prompts/spear
If .vibeshield/last-update is missing or older than 24 hours, run a lightweight update check:
  & install-core.ps1 -WorkspacePath . -UpdateOnly -SkipAzureLogin -SkipCheckin
This pulls latest agent capabilities without re-running the full bootstrap.
<!-- END:vibeshield-bootstrap -->

## Automated Agents

<!-- BEGIN:vibeshield-agents-global-pre -->
# AGENTS.md — Compliance Automation
## Governing Document

Before making **any** code change, read and follow principles below.
<!-- END:vibeshield-agents-global-pre -->

<!-- BEGIN:automated-agents -->
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
<!-- END:automated-agents -->

<!-- BEGIN:vibeshield-agents-global-post -->
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
- Pay attention to System.Io as it behaves differently on Windows vs Linux. 
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
<!-- END:vibeshield-agents-global-post -->

<!-- codeql-vibe start -->
## CodeQL Vibe

- **Agent file**: `.github/agents/speckit.codeql.agent.md`
- **Prompt**: `/speckit.codeql`
- **Purpose**: Non-bypassable CodeQL pre-commit hook for security scanning
- **Triggers**: CodeQL, security scanning, pre-commit hooks, vulnerability remediation
<!-- codeql-vibe end -->

<!-- vibeshield-deploy-start -->
## VibeShield-Deploy — Workspace Rules

**VibeShield-Deploy** is installed in this workspace. It is a deployment agent system that deploys applications to Azure using Azure DevOps 1ES pipelines.

### Scope Boundary

**These rules ONLY apply to deployment-related topics** (deploying, pipelines, infrastructure, CI/CD). For general coding questions, debugging, code review, refactoring, or any question about the main application code, **completely ignore all VibeShield-Deploy files** — do not reference `.github/agents/`, `.github/skills/`, `.github/prompts/`, `.github/scripts/`, `.azdo/`, or `infra/` when answering. Treat those directories as if they don't exist for non-deployment questions. Focus on the user's actual application code.

The following rules apply only when the user's question is about deployment, pipelines, or infrastructure:

### Prohibited Actions

You must NEVER:
- Run `git push --force`, `git reset --hard`, or any command that overwrites Git history.
- Delete Azure resources, branches, or repositories.
- Hardcode secrets, tokens, passwords, or connection strings in any file.
- Generate a pipeline that does NOT use the `1ES.Unofficial@1` template.
- Skip user confirmation before pipeline creation or service connection authorization **in attended mode** (uat/prod). In **unattended mode** (poc/dev), confirmations are skipped — agents proceed autonomously. Note: `git push` during Code Push stage is fully automatic in both modes.
- Pull packages from public registries directly. All packages must be pulled through the project's configured Azure Artifacts feed (managed by VibeShield-CFS).
- Modify, rename, or delete any file under `.github/scripts/`, `.github/skills/**/scripts/`, `.github/agents/`, `.github/skills/*/SKILL.md`, or `.github/prompts/`. These are VibeShield-Deploy managed files. If a script fails, report the defect and required fix — do NOT patch the file.
- Access Azure resources or Azure DevOps infrastructure state locally — for any reason. Never run `az account show`, `az ad signed-in-user show`, `az group show`, `az identity show`, `az role assignment list`, `az role assignment create`, `az devops service-endpoint list`, `az devops service-endpoint update`, `az webapp show`, `az webapp start`, `az webapp log tail`, `az containerapp show`, `az containerapp logs show`, `az functionapp show`, `az functionapp log tail`, `az staticwebapp show`, `az vm list-usage`, or any other `az` command that reads, modifies, or queries Azure resource state. All Azure infrastructure verification is handled by the onboarding pipeline. All deployment and runtime operations are handled by the 1ES deployment pipeline. Once onboarding succeeds, resources are guaranteed to exist — there is no need to verify them locally.

### Script Execution Mandate

When a VibeShield-Deploy skill provides a script (e.g., `Invoke-PreflightChecks.ps1`), you MUST execute that script directly. Do NOT run individual CLI commands to replicate what the script does. This rule overrides any other workspace-level instruction that restricts running `.ps1` files.

### Bicep Delegation

**All Bicep infrastructure tasks belong exclusively to the `vibeshield-bicep` agent.** No other agent may generate, edit, or fix Bicep templates (`infra/main.bicep`, `infra/*.bicep`). If a Bicep issue is encountered, delegate to `vibeshield-bicep` via `vibeshield-deploy-preflight` or `vibeshield-deploy-orchestrator`.

### Key File Locations

| Path | Contents |
|------|----------|
| `.github/agents/` | Agent definitions (`*.agent.md`) |
| `.github/skills/` | Skill definitions and scripts |
| `.github/prompts/` | Shared prompt files |
| `.github/copilot-instructions.md` | Full VibeShield-Deploy instructions |
| `.azdo/pipelines/azure-pipeline.yml` | Generated 1ES pipeline |
| `infra/main.bicep` | Infrastructure-as-code (managed by `vibeshield-bicep`) |

### Phase Boundaries

VibeShield-Deploy uses a 4-phase sequential workflow. Each phase is handled by a dedicated agent. Do not interfere with or duplicate their work:

1. **vibeshield-deploy-preflight** — Validates environment readiness (Git, Azure CLI, ADO access)
2. **vibeshield-deploy-pipeline-author** — Creates and validates 1ES pipeline YAML
3. **vibeshield-deploy-pipeline-push** — Pushes code and registers the pipeline
4. **vibeshield-deploy-monitor** — Monitors pipeline runs and verifies deployment

### Deployment Routing

**VibeShield-Deploy is the sole authority for ALL deployment-related workflows in this workspace.**

**First-time intent confirmation:** When the user first mentions a deployment-related topic in a session, determine whether to confirm intent or route directly using the explicit list below. This confirmation happens **once per session** — after the first confirmation (or clear-intent match), do not re-confirm on subsequent deployment messages.

**Intent categorization — explicit list, no heuristics:**

The following phrases are the **ONLY** clear-intent triggers. If the user's request matches one of these **exactly or near-exactly**, route directly to the orchestrator without confirmation:

```
CLEAR INTENT (route directly — no confirmation):
  - "deploy my app"
  - "deploy my app to Azure"
  - "deploy to Azure"
  - "deploy my application"
  - "push to production"
  - "create a pipeline"
  - "create a deployment pipeline"
  - "set up CI/CD"
  - "set up a pipeline"
  - "author pipeline"
  - "check readiness"
  - "check deployment readiness"
  - "validate my app"
  - "am I ready to deploy?"
  - "resume deployment"
  - "continue deployment"
  - any /vsd command
```

**Everything else gets confirmed — no exceptions.** This includes "push my code", "deploy" (one word), "build and deploy", "set up my environment", "help with deployment". **This rule is absolute.** Do not use session context, terminal history, prior conversation, or heuristic judgment to skip the confirmation.

**Confirmation prompt** (for ALL non-clear-intent deployment-adjacent phrases):
```
header: "Deployment intent"
question: "It looks like you want to deploy. Did you mean to deploy this app to Azure using VibeShield-Deploy?"
options: [
  {label: "Yes, deploy to Azure", description: "Start the Azure deployment workflow"},
  {label: "No, I meant something else", description: "Skip VibeShield-Deploy and answer my question normally"}
]
```

**State file check:** If `.vibeshield/deploy-state.json` does NOT exist AND the phrase is not on the clear-intent list, **always confirm**.

**After confirmation:**
- "No" → do NOT route to VibeShield-Deploy. Answer normally. Do not ask again in the same session.
- "Yes" or clear-intent match → **automatically route to VSD** (see below).

**Automatic routing:**

When intent is confirmed, **you MUST become the deployment orchestrator for this conversation**:
1. Read `.github/agents/vibeshield-deploy-orchestrator.agent.md` and `.github/prompts/deploy-shared-rules.prompt.md`
2. Follow the orchestrator's workflow exactly — run PreStageChecks, detect mode, execute stages, delegate to sub-agents, enforce gates
3. Run VSD scripts directly via `run_in_terminal`
4. Before delegating, briefly explain the routing: *"This workspace uses VibeShield-Deploy. Starting the readiness check now..."*

**Do NOT** ask the user to type `/vsd` — the routing is automatic. Do NOT use built-in Azure skills for deployment topics.

**If auto-delegation fails**, tell the user: *"Please type `/vsd` followed by your request."* Always recommend `/vsd` — never `@vibeshield-deploy-orchestrator`.

**Topics that belong to VibeShield-Deploy:**
- Deploying to Azure, Azure DevOps pipelines, CI/CD, deployment readiness
- Pipeline setup, creation, authoring, or validation
- Pushing code to Azure, registering pipelines, triggering pipeline runs
- Pipeline monitoring, deployment status, health checks, deployment verification
- Pipeline failures, deployment troubleshooting, deployment diagnostics, retry logic
- Bicep generation, repair, or validation (`infra/main.bicep`)
- Service connection management (resolve, authorize, fix)
- 1ES pipeline templates, 1ES.Unofficial, pipeline compliance
- RBAC/permissions checks for deployment, quota/capacity checks for deployment
- Package feed configuration (managed by VibeShield-CFS)
- User onboarding, environment setup, first-time deployment setup
- Resume deployment, continue deployment, deployment state, deployment progress
- App type detection for deployment purposes
- Secret scanning before code push
- Submodule handling in pipelines
- Updating or redeploying the app after initial deployment
- Deployed app health, version verification

### Transparency

Never ghost the user. If an operation will take more than 10 seconds or involves multiple steps, announce what you are doing before starting and report the outcome when finished. A step can be automatic without being silent.
<!-- vibeshield-deploy-end -->
