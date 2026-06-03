---
description: Updates the checkin plan with user-specified details for Azure DevOps repository creation and local code commit.
handoffs: 
  - label: Generate Checkin Tasks
    agent: checkin.tasks
    prompt: Generate the checkin.tasks.md file based on the updated plan.
---

Once complete, **immediately** proceed to execute the `checkin.tasks` agent without waiting for user confirmation. Make sure to re-read definition of the agent before executing.

## User Input

```text
$arguments
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. Review the `checkin.plan.md` file. There are key placeholders that must be replaced:

   **Required Placeholders:**

      - REPO_NAME
      - REPO_DESCRIPTION
      - LOCAL_PROJECT_PATH
      - IS_GIT_INITIALIZED
      - GIT_USER_CONFIGURED
      - GIT_USER_NAME
      - GIT_USER_EMAIL
      - REPO_EXISTS
      - REPO_CLONE_URL

   **Fixed Values (do not change):**

      - DEFAULT_BRANCH is always `main`

No other placeholders exist in the plan and no other values should be changed.

2. Take the Repository Name field and replace any instance of `REPO_NAME` in the plan with the provided value. The repo name should be used as-is for the ADO repository name. When used in URLs, it should be URL-encoded if it contains spaces.

3. Take the Local Project Path field and replace any instance of `LOCAL_PROJECT_PATH` in the plan with the provided value. This should be the absolute path to the local project directory.

4. Take the Is Git Initialized field and replace any instance of `IS_GIT_INITIALIZED` in the plan with the detected value (True or False). This determines whether `git init` is needed during implementation.

5. Take the Git User Configured field and replace any instance of `GIT_USER_CONFIGURED` in the plan with the detected value (True or False). This determines whether git identity needs to be configured before committing.

6. Take the Git User Name field and replace any instance of `GIT_USER_NAME` in the plan with the detected value. If `GIT_USER_CONFIGURED` is `True`, this may be set to the existing global value or left empty. If `GIT_USER_CONFIGURED` is `False`, this should contain the name resolved from the Azure CLI session.

7. Take the Git User Email field and replace any instance of `GIT_USER_EMAIL` in the plan with the detected value. If `GIT_USER_CONFIGURED` is `True`, this may be set to the existing global value or left empty. If `GIT_USER_CONFIGURED` is `False`, this should contain the email resolved from the Azure CLI session.

8. Take the Repository Description field and replace any instance of `REPO_DESCRIPTION` in the plan with the provided value. This field is only required when `REPO_EXISTS` is `False` (i.e., a new repository is being created). If `REPO_EXISTS` is `True` and no description was provided, replace `REPO_DESCRIPTION` with an empty string.

6. Take the Repo Exists field and replace any instance of `REPO_EXISTS` in the plan with the detected value (True or False). This determines whether the repository needs to be created or already exists in Azure DevOps.

7. Take the Repo Clone URL field and replace any instance of `REPO_CLONE_URL` in the plan with the detected value. If `REPO_EXISTS` is False, this will be empty and will be populated during Phase 2 execution.

8. The Default Branch is always `main`. It is already set in the plan and should not be changed.

9. DO NOT change any other part of the plan beyond placeholder replacement.

10. **Augment the plan** with the following detailed phases (append after the Status section):

    ```markdown
    ## Phase 1: Secret Detection
    - **CRITICAL SECURITY GATE**: Scan all files in LOCAL_PROJECT_PATH for hardcoded secrets before any repository is created or code is staged
    - Detect the following secret types: API keys, passwords, connection strings, SAS tokens, Azure Storage account keys, personal access tokens (PATs), private keys, certificates, OAuth client secrets, bearer tokens, and any string matching common secret patterns
    - Use pattern-based scanning with regular expressions to search for secrets across all text files in the project directory
    - If ANY secrets are detected, **IMMEDIATELY STOP** the entire agent workflow, report every finding with the file path and line number, and do NOT proceed to any subsequent phase
    - Only proceed to Phase 2 if the scan completes with zero findings

    ## Phase 2: Repository Setup
    - **If REPO_EXISTS is False**: Attempt to create a new Git repository named `REPO_NAME` in the "CELA_Demos_and_POCs" project under the oneCELA organization using the Azure DevOps CLI. Capture the repository clone URL (HTTPS) for use in subsequent steps. Set the repository description if provided. **If repository creation fails for any reason (including insufficient permissions), IMMEDIATELY STOP the entire agent workflow and display the following message to the user:**

      > **Repository creation failed.** Your account does not have permission to create repositories in the "CELA_Demos_and_POCs" project. Please request the **"CELA - Contributor"** role in the **"CELA Demos and POCs"** entitlement in **CoreIdentity**, then re-run the checkin.

    - **If REPO_EXISTS is True**: Skip repository creation. Use the existing clone URL (REPO_CLONE_URL). Verify the repository is accessible via `az repos show`.

    ## Phase 3: Local Git Initialization
    - If IS_GIT_INITIALIZED is False, initialize a new git repository in LOCAL_PROJECT_PATH
    - If IS_GIT_INITIALIZED is True, skip git init but verify the existing repo state
    - **If GIT_USER_CONFIGURED is False**, configure git identity before any commit by running:
      - `git config --global user.name "GIT_USER_NAME"`
      - `git config --global user.email "GIT_USER_EMAIL"`
    - Ensure a .gitignore file exists (create a sensible default if missing)
    - Ensure an `es-metadata.yml` file exists in the project root. If missing, create it using the format from `es-metadata-template.yml` (located at `.agents/spear/checkin/es-metadata-template.yml`), replacing `{SERVICE_ID}` with the default value `9d3392ae-6f2a-4a31-b834-b3189ec0609e`
    - Ensure the current branch is named `main`

    ## Phase 4: Stage and Commit
    - Stage all files in the local project directory
    - **If REPO_EXISTS is False**: Create a commit with the message "Initial commit - vibe-coded project checkin"
    - **If REPO_EXISTS is True**: Create a commit with a descriptive message summarizing the changes (e.g., "Add local project files")
    - If there are no changes to commit, note this and continue

    ## Phase 5: Remote Configuration and Push
    - Add the Azure DevOps repository as the remote origin (or update it if one already exists)
    - **If REPO_EXISTS is True and the remote has existing commits**: Pull remote changes first using `git pull --rebase origin main` to integrate any existing remote history before pushing. If there are merge conflicts, **STOP** and inform the user to resolve them manually before re-running the checkin.
    - Push the `main` branch to the remote origin
    - Verify the push was successful

    ## Phase 6: Post-Checkin Validation
    - Verify the repository is visible and accessible in Azure DevOps
    - Verify the pushed branch and commit appear in the remote repository
    - Update checkin.plan.md status checkboxes to mark completion
    ```

9. Verify that all required placeholders have been replaced. If any remain, ask the user for the missing values.

10. Once all replacements and augmentations are made, hand off to the `checkin.tasks` agent to build the `checkin.tasks.md` file.
