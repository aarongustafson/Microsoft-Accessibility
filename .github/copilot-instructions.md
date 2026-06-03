<!-- BEGIN:vibeshield-bootstrap -->
# Copilot Instructions
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
<!-- BEGIN:path-specific-instructions -->
<!-- BEGIN:vibeshield-bicep -->
- **Bicep** (`**/*.bicep`): Routes through `@vibeshield-bicep` standards via `.github/instructions/bicep.instructions.md`
<!-- END:vibeshield-bicep -->
<!-- BEGIN:vibeshield-powershell -->
- **PowerShell** (`**/*.ps1,**/*.psm1`): Routes through `@vibeshield-powershell` standards via `.github/instructions/powershell.instructions.md`
<!-- END:vibeshield-powershell -->
<!-- BEGIN:vibeshield-safe-libraries -->
- **Package Feed Configs** (`**/nuget.config,**/.npmrc,**/pip.ini,**/pip.conf`): Routes through `@vibeshield-safe-libraries` CFS compliance via `.github/instructions/safe-libraries.instructions.md`
<!-- END:vibeshield-safe-libraries -->
<!-- END:path-specific-instructions -->

<!-- codeql-vibe start -->
## CodeQL

For CodeQL setup, scanning, hooks, and vulnerability remediation, read and follow
`.github/agents/speckit.codeql.agent.md`. Use `/speckit.codeql` prompts for task routing.
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

### Script Execution Mandate

When a VibeShield-Deploy skill provides a script (e.g., `Invoke-PreflightChecks.ps1`, `Invoke-PipelinePush.ps1`, `Invoke-PipelineAuthorValidation.ps1`, `Invoke-ServiceConnectionResolve.ps1`, `Invoke-StateFileManager.ps1`), you MUST execute that script directly. Do NOT run individual CLI commands to replicate what the script does. This rule overrides any other workspace-level instruction that restricts running `.ps1` files.

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

**Everything else gets confirmed — no exceptions.** This includes:
- "push my code" (could be `git push`)
- "deploy" (one word, no context)
- "build and deploy" (could be local build)
- "set up my environment" (could be dev tools)
- "help with deployment" (could be informational)
- "push to Azure" (could be storage upload)
- Any phrase not on the clear-intent list above

**This rule is absolute.** Do not use session context, terminal history, prior conversation, or heuristic judgment to skip the confirmation. If the phrase is NOT on the clear-intent list, confirm intent — regardless of what the user was doing before.

**Confirmation prompt** (shown for ALL non-clear-intent deployment-adjacent phrases):
```
header: "Deployment intent"
question: "It looks like you want to deploy. Did you mean to deploy this app to Azure using VibeShield-Deploy?"
options: [
  {label: "Yes, deploy to Azure", description: "Start the Azure deployment workflow"},
  {label: "No, I meant something else", description: "Skip VibeShield-Deploy and answer my question normally"}
]
```

**State file check — additional guard:**
If `.vibeshield/deploy-state.json` does NOT exist AND the user's phrase is not on the clear-intent list, **always confirm** — even if prior conversation discussed deployment. No state file = no prior deployment = extra reason to confirm.

**After confirmation:**
- "No" → do NOT route to VibeShield-Deploy. Answer using general knowledge, ignoring all VibeShield files. Do not ask again in the same session.
- "Yes" or clear-intent match → **automatically route to the VSD orchestrator** (see below). Do NOT show the orchestrator's mode selection question — at most one question per first interaction.

**Automatic routing — how to hand off:**

When the user's intent is confirmed (or matches the clear-intent list), **you MUST become the deployment orchestrator for the remainder of this conversation**. Do this by:

1. **Read the orchestrator agent file**: `.github/agents/vibeshield-deploy-orchestrator.agent.md` — this contains the full workflow, stage definitions, and delegation rules.
2. **Read the shared rules**: `.github/prompts/deploy-shared-rules.prompt.md` — this contains persona, safety rules, script index, and UX standards.
3. **Follow the orchestrator's workflow exactly** — run PreStageChecks, detect mode, execute stages sequentially, delegate to sub-agents, enforce gates.
4. **Run scripts directly** — use `run_in_terminal` to execute VSD scripts as the orchestrator instructs. Always call scripts via `& ./.github/scripts/ScriptName.ps1 @args` (not dot-source + function call). For workspace analysis, use `Invoke-Stage2PreRunner.ps1` (not `Invoke-WorkspaceAnalysis.ps1` directly).
5. **Delegate to sub-agents** using `runSubagent` when the orchestrator workflow says to delegate (e.g., to `vibeshield-deploy-preflight` for Stage 1).

**You ARE the orchestrator once routing is confirmed.** Do not tell the user to type `/vsd` — that defeats the purpose of automatic routing. Do not narrate the handoff as a separate step — just start doing the work.

**Before delegating, briefly explain the routing** so the user understands why, then begin Stage 1:
> *"This workspace uses VibeShield-Deploy for deployments. Starting the readiness check now..."*

**Do NOT:**
- Ask the user to switch agents or type `/vsd` — the routing is automatic
- Use built-in Azure skills (`azure-prepare`, `azure-deploy`, `azure-validate`, etc.) — VibeShield-Deploy owns all deployment workflows
- Run VibeShield scripts without reading the orchestrator instructions first — the workflow has specific ordering, gates, and delegation rules

**If auto-delegation fails** (e.g., tool access issues, agent file not found), tell the user: *"Please type `/vsd` followed by your request."* Always recommend `/vsd` — never `@vibeshield-deploy-orchestrator`.

**Topics that belong to VibeShield-Deploy:**
- Deploying to Azure, Azure DevOps pipelines, CI/CD, deployment readiness
- Pipeline setup, creation, authoring, or validation
- Pushing code to Azure, registering pipelines, triggering pipeline runs
- Pipeline monitoring, deployment status, health checks, deployment verification
- Pipeline failures, deployment troubleshooting, deployment diagnostics, retry logic
- Service connection management (resolve, authorize, fix)
- 1ES pipeline templates, 1ES.Unofficial, pipeline compliance
- RBAC/permissions checks for deployment, quota/capacity checks for deployment
- Package feed configuration (managed by VibeShield-CFS)
- User onboarding, environment setup, first-time deployment setup
- Resume deployment, continue deployment, deployment state, deployment progress
- App type detection for deployment purposes
- Submodule handling in pipelines
- Updating or redeploying the app after initial deployment
- Deployed app health, version verification

### Transparency

Never ghost the user. If an operation will take more than 10 seconds or involves multiple steps, announce what you are doing before starting and report the outcome when finished. A step can be automatic without being silent.
<!-- vibeshield-deploy-end -->