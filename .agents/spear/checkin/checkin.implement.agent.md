---
description: Execute the checkin implementation plan by processing and executing all tasks defined in checkin.tasks.md
handoffs: 
  - label: Verify Checkin
    agent: checkin.verify
    prompt: Verify the checkin implementation against the original requirements and ensure all tasks are completed. Review checkin.plan.md and checkin.tasks.md for context.
---

Once complete, **immediately** proceed to execute the `checkin.verify` agent without waiting for user confirmation. Make sure to re-read definition of the agent before executing.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. Parse `checkin.tasks.md` structure and extract:
   - **Task phases**: Phase 1 (Secret Detection), Phase 2 (Repository Creation), Phase 3 (Local Git Initialization), Phase 4 (Stage and Commit), Phase 5 (Remote Configuration and Push), Phase 6 (Post-Checkin Validation)
   - **Task dependencies**: Sequential vs parallel execution rules
   - **Task details**: ID, description, commands, parallel markers [P]
   - **Execution flow**: Order and dependency requirements

2. Read the **Key Project Information** table from `checkin.plan.md` to extract all necessary values:
   - ADO Organization URL
   - ADO Project name
   - Repository Name
   - Repository Description
   - Default Branch name
   - Local Project Path
   - Is Git Initialized flag
   - Git User Configured flag
   - Git User Name (if Git User Configured is False)
   - Git User Email (if Git User Configured is False)
   - Repo Exists flag
   - Repo Clone URL (if repo already exists)

3. Execute implementation following the task plan:
   - **Phase-by-phase execution**: Complete each phase before moving to the next
   - **Respect dependencies**: Run sequential tasks in order, parallel tasks [P] can run together
   - **Validation checkpoints**: Verify each phase completion before proceeding

4. Phase-specific execution guidance:

   **Phase 1 - Secret Detection** (**CRITICAL SECURITY GATE**):
   - Recursively scan ALL files in `LOCAL_PROJECT_PATH` for hardcoded secrets before any repository is created, code is staged, or committed
   - Use the appropriate tool for the current shell to perform recursive regex searches across all files, excluding binary files and the `.git` directory. For example: `Select-String` in PowerShell, `grep -rn` in bash/zsh, or any equivalent. Detect the following patterns:
     - **Connection strings**: `connectionstring\s*=`, `Server=.*Password=`, `AccountKey=`
     - **Azure Storage keys / SAS tokens**: `sv=20`, `sig=`, `SharedAccessSignature=`, `DefaultEndpointsProtocol=`
     - **API keys / tokens**: `api[_-]?key\s*[=:]`, `apikey\s*[=:]`, `token\s*[=:]`, `bearer\s+[A-Za-z0-9\-._~+/]+=*`
     - **Passwords**: `password\s*[=:]`, `passwd\s*[=:]`, `pwd\s*[=:]`
     - **Secrets**: `secret\s*[=:]`, `client[_-]?secret\s*[=:]`
     - **Private keys**: `-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----`
     - **Personal access tokens**: strings matching PAT-like patterns (e.g., base64 strings of 52+ characters preceded by a key-like label)
     - **Other indicators**: `PRIVATE KEY`, `.pfx`, `.pem` file contents inlined as strings
   - Exclude `.git/` directory, binary files, image files, and the `.gitignore` file itself from scanning
   - **If ANY matches are found**:
     1. Report EVERY finding with the **file path**, **line number**, and a **preview of the matching line** (mask the actual secret value in the preview)
     2. **IMMEDIATELY STOP** the entire agent workflow — do NOT proceed to Phase 2 or any subsequent phase
     3. Inform the user they must remove or externalize all secrets (e.g., use environment variables, Azure Key Vault, or a `.env` file listed in `.gitignore`) before re-running the checkin
   - **Only proceed to Phase 2 if the scan completes with ZERO findings**

   **Phase 2 - Repository Setup**:
   - **If `Repo Exists` is `False`**:
     - Use `az repos create --name "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"` to create the repository
     - **If the creation command fails for any reason (including insufficient permissions), IMMEDIATELY STOP the entire agent workflow.** Do NOT proceed to any subsequent phase. Display the following message to the user:

       > **Repository creation failed.** Your account does not have permission to create repositories in the "CELA Demos and POCs" project. Please request the **"CELA - Contributor"** role in the **"CELA Demos and POCs"** entitlement in **CoreIdentity**, then re-run the checkin.

     - If creation succeeds, parse the JSON output to extract the `remoteUrl` (HTTPS clone URL)
     - Store the clone URL for use in Phase 5
   - **If `Repo Exists` is `True`**:
     - Skip repository creation entirely
     - Use the `Repo Clone URL` value from `checkin.plan.md`
     - Verify the repository is still accessible by running `az repos show --repository "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"`
     - If verification fails, inform the user the repository may have been deleted or renamed and stop the agent

   **Phase 3 - Local Git Initialization**:
   - Change directory to the `LOCAL_PROJECT_PATH` before executing git commands
   - If `Is Git Initialized` is `False`: run `git init` to initialize the repository
   - If `Is Git Initialized` is `True`: run `git status` to verify the repo state
   - **If `Git User Configured` is `False`**: configure git identity by running:
     - `git config --global user.name "<GIT_USER_NAME>"` (using the value from `checkin.plan.md`)
     - `git config --global user.email "<GIT_USER_EMAIL>"` (using the value from `checkin.plan.md`)
     - This MUST happen before any `git commit` command. Without `user.name` and `user.email`, git will refuse to create commits (common in clean dev containers or CI environments).
   - Check for `.gitignore` - if missing, create a sensible default based on the project type (detect by looking at file extensions: .py → Python, .js/.ts → Node, .cs/.csproj → .NET, etc.)
   - Check for `es-metadata.yml` in the project root (`LOCAL_PROJECT_PATH`). If the file does not exist, create it with the following content (replacing `{SERVICE_ID}` with the default value `9d3392ae-6f2a-4a31-b834-b3189ec0609e`):
     ```yaml
     schemaVersion: 1.0.0
     providers:
     - provider: InventoryAsCode
       version: 1.0.0
       metadata:
         isProduction: false
         accountableOwners:
           service: 9d3392ae-6f2a-4a31-b834-b3189ec0609e
         routing:
           defaultAreaPath:
             org: oneCELA
             path: CELA_Demos_and_POCs
     
     ```
     This file is **mandatory** for every new repository. The template format is defined in `.agents/spear/checkin/es-metadata-template.yml`.
   - Ensure the current branch is named correctly: run `git branch -M <DEFAULT_BRANCH>` to rename if needed

   **Phase 4 - Stage and Commit**:
   - Run `git add .` to stage all files
   - Run `git status` to verify files are staged (report count of staged files)
   - **If `Repo Exists` is `False`**: Run `git commit -m "Initial commit - vibe-coded project checkin"` to create the commit
   - **If `Repo Exists` is `True`**: Run `git commit -m "Add local project files"` to create the commit
   - If there are no changes to commit (already committed), note this and continue

   **Phase 5 - Remote Configuration and Push**:
   - Check if a remote named `origin` already exists with `git remote -v`
   - If origin exists but points to a different URL, update it with `git remote set-url origin <CLONE_URL>`
   - If origin does not exist, add it with `git remote add origin <CLONE_URL>`
   - **If `Repo Exists` is `True`**: Before pushing, pull and rebase from remote to integrate existing history:
     1. Run `git pull --rebase origin <DEFAULT_BRANCH>`
     2. If the pull succeeds, continue to push
     3. If the pull fails due to **merge conflicts**, **IMMEDIATELY STOP** the workflow, report the conflicted files, and inform the user they must resolve the conflicts manually, then re-run the checkin
     4. If the pull fails because the remote branch does not exist yet (empty repo), this is safe to ignore — proceed to push
   - Push the branch with `git push -u origin <DEFAULT_BRANCH>`
   - If push fails with a non-fast-forward error, inform the user that the remote has diverged and suggest running `git pull --rebase` manually
   - If push authentication fails, inform the user to configure Git Credential Manager or set up a Personal Access Token (PAT) for Azure DevOps, then retry

   **Phase 6 - Post-Checkin Validation**:
   - Run `az repos show --repository "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"` to verify the repository exists
   - Run `az repos ref list --repository "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"` to verify the branch exists in the remote
   - Update the `checkin.plan.md` status checkboxes to mark both items as complete: `[x]`

5. Progress tracking and error handling:
   - Report progress after each completed task
   - Halt execution if any non-parallel task fails
   - For parallel tasks [P], continue with successful tasks, report failed ones
   - Provide clear error messages with context for debugging
   - Suggest next steps if implementation cannot proceed
   - **IMPORTANT**: For completed tasks, make sure to mark the task off as `[x]` in `checkin.tasks.md`

6. Completion summary:
   - Report the Azure DevOps repository URL
   - Report the number of files committed
   - Report the branch name pushed
   - Confirm the repository is accessible in the "CELA_Demos_and_POCs" project
   - Provide the web URL for the user to view the repository in their browser: `https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/<REPO_NAME>`

Note: This command assumes a complete task breakdown exists in `checkin.tasks.md` and `checkin.plan.md` contains the project information.
