---
name: codeql-azuredevops-git-auth
description: "Configure Azure DevOps git authentication using Git Credential Manager and browser-based az login. Use when Azure DevOps git fetch or git ls-remote returns 401 or 403, when agent updates cannot download from the source repo, when git credentials are missing, when Credential Manager needs to be configured, or when the user wants Azure Repos auth without device code login."
argument-hint: "Describe the auth issue: Azure DevOps 401/403, git credentials missing, Credential Manager setup, az login without device code, or update download auth failure"
user-invocable: true
disable-model-invocation: false
---

# Azure DevOps Git Authentication Skill

Configure git authentication for Azure DevOps repositories using Git Credential Manager (GCM) and browser-based Azure CLI sign-in.

## When to Use

- `git ls-remote` against Azure DevOps returns **401** or **403**
- Agent update download from the source repository fails due to authentication
- Git Credential Manager is not configured for Azure DevOps
- The user wants Azure Repos authentication through **Credential Manager**
- The user wants to use `az login` but **must not** use device-code flow
- Git operations succeed in one shell but fail in another because credentials are missing or cached incorrectly

## Goal

Ensure that Azure DevOps git operations authenticate through Git Credential Manager with browser-based Microsoft Entra sign-in, not device-code login.

## Default Behavior

When invoked, the agent should default to **repairing the auth path**, not merely explaining it.

Use this order:
1. Verify Git Credential Manager is installed and configured as the git credential helper.
2. Verify Azure CLI is installed.
3. Sign in with `az login` using the browser-based flow only.
4. Re-test the Azure DevOps remote with `git ls-remote`.
5. If the remote still fails, surface the next precise blocker.

## Authentication Workflow

### 1. Verify Git Credential Helper

Check the current helper:

```powershell
git config --global credential.helper
```

Preferred values:
- `manager-core`
- `manager`

If the helper is missing or different, configure Git Credential Manager:

```powershell
git config --global credential.helper manager-core
git config --global credential.azreposCredentialType oauth
git config --global credential.https://dev.azure.com.useHttpPath true
```

If `manager-core` is unavailable on the machine, use `manager` only if that is the installed helper name.

### 2. Verify Azure CLI

```powershell
az version
```

If `az` is not available, stop and tell the user to install Azure CLI before continuing.

### 3. Sign In With Browser-Based Azure CLI Flow

Use:

```powershell
az login
```

If tenant selection matters:

```powershell
az login --tenant <tenant-id-or-domain>
```

**Do not use:**

```powershell
az login --use-device-code
```

The skill must never choose device-code login when the requirement is browser-based sign-in.

### 4. Re-Test Azure DevOps Git Access

After login, validate access against the actual Azure DevOps repository URL:

```powershell
git ls-remote <azure-devops-repo-url>
```

This is the canonical verification because it exercises the same auth path used by agent update downloads and git-based access.

### 5. If GCM Prompts Again

If Git Credential Manager opens an interactive sign-in prompt during `git ls-remote`, complete the browser-based Microsoft sign-in flow.

The skill should treat this as normal first-run behavior, not as a failure.

### 6. PAT Fallback

Only use a PAT fallback if:
- browser-based sign-in is blocked by policy, or
- Git Credential Manager is unavailable and cannot be installed in the environment.

If PAT fallback is required, use the minimum scope needed, typically `Code (Read)` for update/download scenarios.

PAT is a fallback, not the preferred path.

## Expected Outcome

After this skill runs successfully:

1. Git uses Git Credential Manager for Azure DevOps.
2. The user is signed in with browser-based `az login`.
3. `git ls-remote` against the Azure DevOps remote succeeds.
4. The workflow avoids device-code login.

## Constraints

- Prefer Git Credential Manager plus Microsoft Entra browser sign-in over PATs.
- Never choose `az login --use-device-code` when the user asked to avoid device code.
- Do not claim success until `git ls-remote` or the real Azure DevOps fetch path succeeds.
- If the environment blocks browser sign-in, say so explicitly instead of silently switching auth modes.

## Cross-References

- Use this skill when agent updates fail with Azure DevOps 401/403 errors.
- Combine with `codeql-cli-upgrade` or `codeql-csharp-sdk-compat` only after git authentication itself is working.