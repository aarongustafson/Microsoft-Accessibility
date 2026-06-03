---
description: Verify the checkin implementation against the original requirements and ensure all tasks are completed.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

You are a read-only agent. Your task is to verify that the checkin has been implemented according to the original requirements and that all tasks have been completed.

Never make any changes to the codebase or Azure DevOps. Provide all feedback and findings in the chat window only.

## Verification Steps

1. **Review plan and tasks files**:
    - Read `checkin.plan.md` and `checkin.tasks.md` to understand the original requirements and tasks
    - Verify that all status checkboxes in `checkin.plan.md` are marked as complete `[x]`
    - Verify that all task checkboxes in `checkin.tasks.md` are marked as complete `[x]`

2. **Verify Azure DevOps Repository**:
    - Run `az repos show --repository "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"` to confirm the repository exists
    - Verify the repository name matches what was specified in the plan
    - Verify the repository is in the correct organization (oneCELA) and project (CELA_Demos_and_POCs)
    - Check the repository description if one was specified

3. **Verify Remote Branch and Commits**:
    - Run `az repos ref list --repository "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs"` to verify the default branch exists
    - Confirm the branch name matches the `DEFAULT_BRANCH` value from the plan
    - Verify at least one commit exists on the branch

4. **Verify Local Git State**:
    - Navigate to the `LOCAL_PROJECT_PATH` specified in the plan
    - Run `git status` to confirm the working directory is clean (no uncommitted changes)
    - Run `git remote -v` to confirm the origin points to the correct Azure DevOps repository URL
    - Run `git log --oneline -1` to verify the latest commit exists
    - **If `Repo Exists` is `False` in the plan**: Verify the latest commit message matches "Initial commit - vibe-coded project checkin"
    - **If `Repo Exists` is `True` in the plan**: Verify the latest commit message is descriptive (e.g., "Add local project files") and that the local branch is up-to-date with the remote (no diverged history)

5. **Cross-Reference Verification**:
    - Compare the number of files in the local directory with what was committed
    - Verify the `.gitignore` file exists and is appropriate for the project type
    - Verify that `es-metadata.yml` exists in the project root, matches the format defined in `.agents/spear/checkin/es-metadata-template.yml`, and contains a valid `service ID` under `accountableOwners` (default: `8d70dff6-2b97-4ddd-8195-3510b0012f8d`)
    - Confirm no sensitive files (secrets, credentials, .env files) were accidentally committed

6. **Verify Secret Detection Was Performed**:
    - Check `checkin.tasks.md` to confirm the Phase 1 (Secret Detection) task is marked as complete `[x]`
    - Re-run a spot-check scan of the committed files for common secret patterns (connection strings, API keys, passwords, SAS tokens, private keys) using a recursive regex search appropriate for the current shell (e.g., `Select-String` in PowerShell, `grep -rn` in bash/zsh)
    - If any potential secrets are found in the committed code, report them as **CRITICAL findings** with file path and line number
    - Confirm that no `.env`, `.secret`, `.key`, or `.pfx` files were committed (check `git ls-files`)

7. **Provide Verification Report**:
    - Provide a clear, concise report of your findings
    - Highlight any discrepancies or incomplete tasks
    - If everything is correct, confirm that the checkin meets all requirements
    - Include the Azure DevOps repository web URL for the user: `https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/<REPO_NAME>`
    - If there are issues, list the plan phase and task it corresponds to and how to fix it, but never fix it yourself
