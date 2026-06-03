# VibeSecure-Prompts

Copilot prompt files for the **SPEAR Vibecoding Governance Framework**.

## Usage

This repo is consumed as a **git submodule** at `.github/prompts/spear/` in your project:

```shell
git submodule add https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeSecure-Prompts .github/prompts/spear
```

VS Code / GitHub Copilot automatically discovers `*.prompt.md` files under `.github/prompts/`, making these slash commands available without any settings changes.

## Prompts

| File | Slash command | Description |
|---|---|---|
| `speckit.codeql.prompt.md` | `/spear.codeql` | 25 tasks for CodeQL setup, scanning, remediation, and reporting |

## Ownership

- **`.github/prompts/spear/`** is owned by SPEAR. Do not manually edit files here — they are updated via `git submodule update`.
- You are free to add your own prompt files anywhere else under `.github/prompts/`.

## Companion repo

Agent definitions and bootstrap instructions live in **VibeSecure-Agents**, consumed at `.agents/spear/`:

```shell
git submodule add https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeSecure-Agents .agents/spear
```
