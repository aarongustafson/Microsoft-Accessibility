---
description: Create the checkin.tasks.md file which will be used to implement the repository creation and code checkin.
handoffs: 
  - label: Implement Checkin
    agent: checkin.implement
    prompt: Start implementing the checkin tasks based on the checkin.tasks.md file. Follow each task in order and do not skip any steps. Do not deviate from the tasks outlined in checkin.tasks.md even if it optimizes the process or is more efficient. Always update each task as complete before moving to the next one.
---

Once complete, **immediately** proceed to execute the `checkin.implement` agent without waiting for user confirmation. Make sure to re-read definition of the agent before executing.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. Review the `checkin.plan.md` to create the task list for the repository creation and code checkin. The `checkin.plan.md` is in an implementation order (Phase 1 through Phase 6), so that phase ordering should be used to create the `checkin.tasks.md` file.

2. Create tasks for each phase in the `checkin.plan.md` file. Each task should be clear and concise, with a specific goal in mind.

3. Ensure that each task is actionable and can be completed independently.

4. Reference the Key Project Information table from `checkin.plan.md` for all variable values (org URL, project name, repo name, local path, branch name, etc.).

5. **Important**: When generating tasks for Phase 3 (Local Git Initialization), conditionally include `git init` based on the `Is Git Initialized` value from the plan:
    - If `Is Git Initialized` is `False`, include a task for `git init`
    - If `Is Git Initialized` is `True`, include a task to verify the existing git repo state instead

6. **Important**: When generating tasks for Phase 3, conditionally include git identity configuration based on the `Git User Configured` value from the plan:
    - If `Git User Configured` is `False`, include a task to run `git config --global user.name "<Git User Name>"` and `git config --global user.email "<Git User Email>"` using the values from the plan. This task MUST come before any commit task.
    - If `Git User Configured` is `True`, skip this task (identity is already set)

7. **Important**: When generating tasks for Phase 2 (Repository Setup), conditionally include repository creation based on the `Repo Exists` value from the plan:
    - If `Repo Exists` is `False`, include tasks to create the repository and capture the clone URL
    - If `Repo Exists` is `True`, skip repository creation and include a task to verify the existing repository is accessible (using `az repos show`) and use the `Repo Clone URL` from the plan

8. **Important**: When generating tasks for Phase 4 (Stage and Commit), use an appropriate commit message based on the `Repo Exists` value from the plan:
    - If `Repo Exists` is `False`, use `"Initial commit - vibe-coded project checkin"`
    - If `Repo Exists` is `True`, use a descriptive message such as `"Add local project files"`

9. **Important**: When generating tasks for Phase 5 (Remote Configuration and Push), conditionally include a pull/rebase step based on the `Repo Exists` value from the plan:
    - If `Repo Exists` is `True`, include a task to run `git pull --rebase origin main` before pushing to integrate any existing remote history. If merge conflicts occur, the task should **STOP** the workflow and inform the user to resolve conflicts manually.
    - If `Repo Exists` is `False`, skip the pull/rebase task (the remote repo is empty)

Context for task generation: $ARGUMENTS

The `checkin.tasks.md` should be immediately executable - each task must be specific enough that an LLM can complete it without additional context.

## Task Generation Rules

**CRITICAL**: Tasks MUST be organized by phase to enable sequential implementation.

### Checklist Format (REQUIRED)

Every task MUST strictly follow this format:

```text
- [ ] [TaskID] [P?] [Phase] Description
```

**Format Components**:

1. **Checkbox**: ALWAYS start with `- [ ]` (markdown checkbox)
2. **Task ID**: Sequential number (T001, T002, T003...) in execution order
3. **[P] marker**: Include ONLY if task is parallelizable (different commands, no dependencies on incomplete tasks)
4. **[Phase] label**: REQUIRED - matches checkin.plan.md phases
   - Format: [P1], [P2], [P3], [P4], [P5], [P6]
5. **Description**: Clear action with exact command or file path where applicable

**Expected Task Breakdown**:

Phase 1 - Secret Detection (**CRITICAL SECURITY GATE**):
- Recursively scan all text files in LOCAL_PROJECT_PATH for hardcoded secrets using regex pattern matching
- Detect: API keys, passwords, connection strings, SAS tokens, Azure Storage account keys, personal access tokens (PATs), private keys (e.g., `-----BEGIN RSA PRIVATE KEY-----`), OAuth client secrets, bearer tokens, and strings matching common secret patterns (e.g., `password\s*=`, `secret\s*=`, `connectionstring\s*=`, `key\s*=`, high-entropy base64 strings)
- If ANY secrets are found, report each finding with file path and line number, then **IMMEDIATELY STOP** the entire workflow — do NOT proceed to Phase 2 or any subsequent phase
- Only proceed if the scan completes with zero findings

Phase 2 - Repository Setup:
- **If Repo Exists is False**: Attempt to create the Git repository in Azure DevOps using `az repos create`, capture and record the clone URL, set repository description if provided. **If repository creation fails for any reason (including insufficient permissions), IMMEDIATELY STOP the entire agent workflow** and display this message to the user: *"Repository creation failed. Your account does not have permission to create repositories in the 'CELA Demos and POCs' project. Please request the 'CELA - Contributor' role in the 'CELA Demos and POCs' entitlement in CoreIdentity, then re-run the checkin."*
- **If Repo Exists is True**: Skip creation, verify the existing repository is accessible via `az repos show`, use the clone URL from the plan

Phase 3 - Local Git Initialization:
- Initialize git repo (if needed) or verify existing repo
- **If Git User Configured is False**: Configure git identity using `git config --global user.name` and `git config --global user.email` with the values from the plan. This MUST happen before any commit — without it, `git commit` will fail in clean dev containers or CI environments.
- Check for and create .gitignore if missing
- Check for `es-metadata.yml` in the project root. If missing, create it using the format from `es-metadata-template.yml` (located at `.agents/spear/checkin/es-metadata-template.yml`), replacing `{SERVICE_ID}` with the default value `8d70dff6-2b97-4ddd-8195-3510b0012f8d`. This file is **mandatory** for every new repository.
- Ensure branch is named correctly (rename if needed)

Phase 4 - Stage and Commit:
- Stage all files with `git add .`
- **If Repo Exists is False**: Create the commit with message `"Initial commit - vibe-coded project checkin"`
- **If Repo Exists is True**: Create the commit with a descriptive message such as `"Add local project files"`

Phase 5 - Remote Configuration and Push:
- Add or update the remote origin URL
- **If Repo Exists is True**: Pull and rebase from remote first using `git pull --rebase origin main` to integrate existing history — STOP if merge conflicts occur
- Push the branch to the remote
- Handle authentication if prompted (inform user to use Git Credential Manager or PAT)

Phase 6 - Post-Checkin Validation:
- Verify remote repository exists via `az repos show`
- Verify the branch and latest commit via `az repos ref list`
- Update checkin.plan.md status

**Examples**:

- ✅ CORRECT: `- [ ] T001 [P1] Scan all files in LOCAL_PROJECT_PATH for hardcoded secrets (API keys, passwords, connection strings, SAS tokens, private keys, PATs, bearer tokens) using regex pattern matching — STOP workflow if any are found`
- ✅ CORRECT: `- [ ] T002 [P2] Create Git repository "MyApp" in CELA_Demos_and_POCs project using: az repos create --name "MyApp" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs" — if creation fails, IMMEDIATELY STOP and instruct user to request "CELA - Contributor" role in "CELA Demos and POCs" entitlement in CoreIdentity` (when Repo Exists is False)
- ✅ CORRECT: `- [ ] T002 [P2] Verify existing repository "MyApp" is accessible using: az repos show --repository "MyApp" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"` (when Repo Exists is True)
- ✅ CORRECT: `- [ ] T005 [P3] Initialize git repository in LOCAL_PROJECT_PATH using: git init`
- ✅ CORRECT: `- [ ] T006 [P3] Configure git user identity using: git config --global user.name "<NAME>" && git config --global user.email "<EMAIL>"` (when Git User Configured is False)
- ✅ CORRECT: `- [ ] T007 [P] [P3] Check for .gitignore in LOCAL_PROJECT_PATH and create a default one if missing`
- ✅ CORRECT: `- [ ] T008 [P4] Stage all files using: git add .`
- ❌ WRONG: `- [ ] Create repository` (missing ID and Phase label)
- ❌ WRONG: `T001 [P1] Create repo` (missing checkbox)
- ❌ WRONG: `- [ ] [P1] Create repository` (missing Task ID)

Run checkin.implement.agent.md
