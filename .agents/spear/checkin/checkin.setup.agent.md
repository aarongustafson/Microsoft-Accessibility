---
description: This agent will set up your code for check-in to Azure DevOps. Just provide the name you'd like for your repository — the agent will figure out the rest. It will then create the initial plan file and hand off to the planning agent.

handoffs: 
  - label: Build Checkin Plan
    agent: checkin.plan
    prompt: Populate the checkin infrastructure plan with the provided details.
---

Once complete, **immediately** proceed to execute the `checkin.plan` agent without waiting for user confirmation. Make sure to re-read definition of the agent before executing.

## User Input

```text
$arguments
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

The text the user typed after `/checkin.setup` is a set of key-value pairs that provide details about the repository to be created and the local project to be committed. Assume you always have it available in this conversation even if `$ARGUMENTS` appears literally below. Do not ask the user to repeat it unless they provided an empty command.

1. **Verify Git is Installed**:
    - Run `git --version` to check if Git is available on the system.
    - If the command succeeds, record the version and proceed to step 2.
    - If the command fails (not found / not recognized), attempt to install Git automatically:
      - **Windows (PowerShell)**: Run `winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements`. If `winget` is not available, try `choco install git -y`.
      - **macOS (zsh/bash)**: Run `brew install git`. If `brew` is not available, run `xcode-select --install`.
      - **Linux (bash)**: Run `sudo apt-get update && sudo apt-get install -y git`. For RHEL/Fedora-based systems, run `sudo dnf install -y git`.
    - After installation, run `git --version` again to confirm Git is now available. If it still fails, stop the agent and inform the user: *"Git could not be installed automatically. Please install Git manually (https://git-scm.com/downloads) and re-run the checkin."*

2. **Verify Azure CLI is Installed**:
    - Run `az --version` to check if the Azure CLI is available on the system.
    - If the command succeeds, record the version and proceed to step 3.
    - If the command fails (not found / not recognized), attempt to install the Azure CLI automatically:
      - **Windows (PowerShell)**: Run `winget install --id Microsoft.AzureCLI -e --source winget --accept-package-agreements --accept-source-agreements`. If `winget` is not available, try `choco install azure-cli -y`.
      - **macOS (zsh/bash)**: Run `brew install azure-cli`. If `brew` is not available, run `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash` (for Homebrew-less setups on macOS, direct the user to https://learn.microsoft.com/cli/azure/install-azure-cli-macos).
      - **Linux (bash)**: Run `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`. For RHEL/Fedora-based systems, run `sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc && sudo dnf install -y azure-cli`.
    - After installation, run `az --version` again to confirm the Azure CLI is now available. If it still fails, stop the agent and inform the user: *"Azure CLI could not be installed automatically. Please install Azure CLI manually (https://learn.microsoft.com/cli/azure/install-azure-cli) and re-run the checkin."*

3. **Install Azure DevOps CLI and Authenticate**:
    - Run `az extension add --name azure-devops --upgrade --yes` to force-install (or upgrade) the Azure DevOps CLI extension. This MUST happen before any `az devops` or `az repos` commands are invoked, because those commands will hang if the extension is not already installed.
    - **Check the `core.login_experience_v2` config value** by running `az config get core.login_experience_v2 --only-show-errors -o tsv` and record the result:
      - If the value is `off` (or the key is not set), set `LOGIN_EXP_V2_WAS_ON` = `False` and and run `az config set core.login_experience_v2=off` to disable it before authenticating.
      - If the value is `on`, set `LOGIN_EXP_V2_WAS_ON` = `True` and run `az config set core.login_experience_v2=off` to disable it before authenticating.
    - Run `az login --allow-no-subscriptions --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47 --output none` to ensure the user is authenticated. This is required every time — do NOT skip this step or rely on cached credentials from `az account show`. The user must complete the interactive login flow **without specifying a subscription** before proceeding.
    - If `az login --allow-no-subscriptions --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47 --output none` fails or the user cancels the login, **restore the original config value first** (if `LOGIN_EXP_V2_WAS_ON` is `True`, run `az config set core.login_experience_v2=on`), then stop the agent and inform the user that authentication is required to continue.
    - After successful authentication, if `LOGIN_EXP_V2_WAS_ON` is `True`, run `az config set core.login_experience_v2=on` to restore the original value.

4. **Verify Azure DevOps Organization and Project Access**:
    - Run `az devops project show --project "CELA_Demos_and_POCs" --org https://dev.azure.com/oneCELA --query id -o tsv` to verify the user has access to the target organization and project.
    - If access fails, inform the user they need appropriate permissions to the oneCELA organization and the "CELA_Demos_and_POCs" project, then stop the agent.
    - **Do NOT check repository creation permissions in advance.** Permission will be verified implicitly when attempting to create the repository in Phase 2 during implementation. If creation fails due to insufficient permissions, the implementing agent will exit and notify the user.

5. Parse the user input into key-value pairs. The required values are:
    - `REPO_NAME` - Name of the repository to be created in Azure DevOps (e.g., MyVibeCodedApp)
    - `LOCAL_PROJECT_PATH` - Absolute path to the local project directory to be committed (e.g., `C:\Projects\MyApp` on Windows or `/home/user/projects/MyApp` on macOS/Linux). **If the user did not provide this value, default it to the project root directory.** Determine the project root as follows:
      - **In an IDE** (VS Code, etc.): use the workspace root folder (the top-level folder open in the editor).
      - **In a CLI** (terminal-only context): use the current working directory.
      - In either case, do NOT use the folder where this agent file resides (e.g., `.agents/spear/checkin/`).

    The following value is optional and only required when the repository does not yet exist (determined in step 5a):
    - `REPO_DESCRIPTION` - A short description for the repository (e.g., "Vibe-coded contract review tool"). If the user provides it upfront, record it for later use. **If not provided, it will be auto-generated from the project files later (see step 5b).**

    The following value is fixed and must NOT be changed or requested from the user:
    - `DEFAULT_BRANCH` - Always set to `main`

    1. If the user did not provide a `REPO_NAME`, ask for it in plain, friendly language. For example: *"What would you like to name your repository?"* Do NOT use technical jargon or reference variable names — the user may be non-technical. Do NOT ask for `LOCAL_PROJECT_PATH` (default to current working directory) or `REPO_DESCRIPTION` at this stage.

5a. **Check for Existing Repository in Azure DevOps**:
    - Run `az repos show --repository "<REPO_NAME>" --org https://dev.azure.com/oneCELA --project "CELA_Demos_and_POCs" -o json` to check if the repository already exists
    - If the command succeeds (returns JSON with repository details):
      - Set `REPO_EXISTS` = `True`
      - Extract the `remoteUrl` from the JSON output and record it as `REPO_CLONE_URL`
    - If the command fails (repository not found):
      - Set `REPO_EXISTS` = `False`
      - Set `REPO_CLONE_URL` to empty

5b. **Conditionally Generate Repository Description**:
    - If `REPO_EXISTS` is `False` and the user has not already provided a `REPO_DESCRIPTION`, **automatically generate one** by reviewing the project files in `LOCAL_PROJECT_PATH`:
        1. Look for common descriptive files such as `README.md`, `package.json`, `*.csproj`, `*.sln`, `pyproject.toml`, `Cargo.toml`, or similar manifest/config files.
        2. Read a small sample of these files to understand the project's purpose, technology stack, and key functionality.
        3. Compose a concise one-sentence description (no longer than 150 characters) summarizing what the project does.
        4. Set `REPO_DESCRIPTION` to this generated description.
    - If `REPO_EXISTS` is `True`, a `REPO_DESCRIPTION` is not needed. If the user provided one, it can be recorded but is not required.

6. **Validate Local Project Path**:
    - Verify the `LOCAL_PROJECT_PATH` exists and is a directory (e.g., `Test-Path` on PowerShell, `test -d` on bash/zsh)
    - Verify the directory is not empty (e.g., `Get-ChildItem` on PowerShell, `ls` on bash/zsh)
    - If the path does not exist or is empty, inform the user and stop the agent

7. **Check for Existing Git Repository**:
    - Check if the `LOCAL_PROJECT_PATH` already contains a `.git` directory
    - Record whether the project is already a git repo (`IS_GIT_INITIALIZED` = True/False) for use in later steps

8. **Check Git User Identity Configuration**:
    - Run `git config --global user.name` and `git config --global user.email` to check if the git user identity is already configured
    - If **both** return non-empty values, set `GIT_USER_CONFIGURED` = `True`
    - If **either** is missing or empty, set `GIT_USER_CONFIGURED` = `False`
    - When `GIT_USER_CONFIGURED` is `False`, capture the signed-in user's display name and email from the Azure CLI session by running `az ad signed-in-user show --query "{name: displayName, email: mail}" -o json`. Record these values as `GIT_USER_NAME` and `GIT_USER_EMAIL` so the implementing agent can configure git identity before committing. If the `az ad` command fails (e.g., in environments without Microsoft Graph access), fall back to `az account show --query user.name -o tsv` for the email and leave the name as the portion before the `@` sign.

9. Create the `checkin.plan.md` file at the root of the current working directory with the following initial content:

    ```markdown
    # Checkin Plan

    ## Key Project Information

    | Field | Value |
    |---|---|
    | ADO Organization | https://dev.azure.com/oneCELA |
    | ADO Project | CELA_Demos_and_POCs |
    | Repository Name | REPO_NAME |
    | Repository Description | REPO_DESCRIPTION |
    | Default Branch | main |
    | Local Project Path | LOCAL_PROJECT_PATH |
    | Is Git Initialized | IS_GIT_INITIALIZED |
    | Git User Configured | GIT_USER_CONFIGURED |
    | Git User Name | GIT_USER_NAME |
    | Git User Email | GIT_USER_EMAIL |
    | Repo Exists | REPO_EXISTS |
    | Repo Clone URL | REPO_CLONE_URL |

    ## Status
    - [ ] Repository available in Azure DevOps
    - [ ] Local project committed and pushed
    ```

10. Update the `checkin.plan.md` file by replacing the placeholder values with the actual user-provided values.

11. Once the `checkin.plan.md` file is created and updated, hand off to the `checkin.plan` agent to continue with detailed planning.

````
