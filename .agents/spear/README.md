# VibeSecure-Agents

### 🚀 Get Started in One Step

> **Copy the [`AGENTS.md`](AGENTS.md) file into the root directory of your project.**
>
> That's it. The next time you open **VS Code Copilot Chat**, **Copilot CLI**, or **Claude**,
> it will read this file and **automagically** set up your project as a properly governed
> OneCELA project — including repo registration, security scanning, and compliance tooling.
>
> No manual configuration. No extra commands. Just drop the file and start coding.

---

## What happens behind the scenes

When your AI assistant reads `AGENTS.md`, it will automatically:

1. ✅ Authenticate you against Azure DevOps
2. ✅ Install the SPEAR agent and prompt submodules
3. ✅ Register your project with OneCELA governance
4. ✅ Set up CodeQL security scanning
5. ✅ Create the necessary configuration wrappers

All of this happens conversationally — you just confirm a few details (repo name, description) and the agents handle the rest.

---

## Contents

| Path | Purpose |
|---|---|
| `checkin/` | Project registration agents (setup → plan → tasks → implement → verify) |
| `AGENTS.md` | Bootstrap constitution — **the file you copy to your project root** |

---

<details>
<summary><h2>🔧 Developer Reference — Git Submodule Details</h2></summary>

> *This section is for informational purposes only.* You do **not** need to run these
> commands manually — the bootstrap in `AGENTS.md` handles submodule installation automatically.

### How it works

This repo is consumed as a **git submodule** at `.agents/spear/` in your project. A companion
repo provides Copilot slash-command prompt files at `.github/prompts/spear/`.

```shell
# Agents submodule (this repo)
git submodule add https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeSecure-Agents .agents/spear

# Prompts submodule (companion repo)
git submodule add https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeSecure-Prompts .github/prompts/spear
```

### Updating submodules

```shell
git submodule sync --recursive
git submodule update --init --recursive
```

### Ownership boundaries

- **`.agents/spear/`** and **`.github/prompts/spear/`** are owned by SPEAR. Do not manually edit files here.
- You are free to add your own agents under `.agents/` and prompts under `.github/prompts/` — just keep them outside the `spear/` directories.

### Companion repo

| Repo | Submodule path | Purpose |
|---|---|---|
| **VibeSecure-Agents** (this repo) | `.agents/spear/` | Agent definitions, bootstrap constitution, docs |
| [**VibeSecure-Prompts**](https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeSecure-Prompts) | `.github/prompts/spear/` | Copilot slash-command prompt files |

</details>