# Safe Libraries via Central Feed Services (CFS)

VibeShield projects use the Azure DevOps artifact feed at
[oneCELA / CELA_Demos_and_POCs](https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_artifacts)
with [Central Feed Services (CFS)](https://aka.ms/cfs) enabled. (Note CFS link is eng.ms page which blocks copilot) CFS automatically scans every
package for known vulnerabilities, so any library consumed through this feed
has been checked before it reaches a developer's machine.

---

## Part 1 — Installer Implementation

### What the installer must ship

The VibeSecure-Agents repo contains default config files that the VibeShield
installer copies into the user's project root during `Install-VibeShield`:

| File | Language ecosystem | Purpose |
|---|---|---|
| `nuget.config` | .NET / NuGet | Points `<packageSources>` at the CFS-backed ADO feed and clears upstream defaults. |
| `pip.ini` | Python / pip | Sets `index-url` to the CFS-backed ADO feed for pip installs. |
| `.npmrc` | Node.js / npm | Sets `registry` to the CFS-backed ADO feed with `always-auth=true`. |

### Feed details

- **Feed URL (NuGet v3):** `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/nuget/v3/index.json`
- **Feed URL (pip/PyPI):** `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/pypi/simple/`
- **Feed URL (npm):** `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/npm/registry/`
- **CFS scanning:** enabled on this feed — all packages are scanned for vulnerable components automatically.
- **Permissions:** VibeShield contributors are contributors on this feed. When they add packages to their project, those packages flow into the feed.

### Installer steps

1. **Detect tools** — check for `dotnet`, `python3`/`python`, and `npm`. If a tool is not found, skip that ecosystem with a warning (do not fail the install). For npm, also probes `~/.agency/nodejs/node-vX.Y.Z-<platform>/` for Agency-managed Node.js.
2. **Install `nuget.config`** into the target project root. The file uses `<clear />` to remove default public sources and adds only the CFS-backed feed. If a `nuget.config` already exists, the installer validates it against known internal CFS-backed ADO organizations: **skip** if valid, **fix in place** if missing `<clear />`, or **backup then replace** if invalid (public feed, unknown org, malformed XML). See [cfs-detection-nuget.md](cfs-detection-nuget.md).
3. **Create Python virtualenv** — if `.venv/` does not exist, create it via `python3 -m venv .venv` (falling back to `python -m venv .venv`). Install `keyring` + `artifacts-keyring` from public PyPI before copying the CFS pip config (avoids circular dependency). Copy `pip.ini` (Windows) or `pip.conf` (Linux/Mac) into the `.venv/` directory. If pip config already exists, validate against known internal orgs: **skip** if valid, **fix** if `extra-index-url` or unsafe `find-links` present, or **backup then replace** if invalid. See [cfs-detection-pip.md](cfs-detection-pip.md).
4. **Install `.npmrc`** into the target project root with `registry` and `always-auth=true`. If `.npmrc` already exists, validate against known internal orgs: **skip** if valid (including scoped registries to internal feeds), or **backup then replace** if invalid (public registry, scoped registry to public feed, unknown org). Install `vsts-npm-auth` globally via npm. See [cfs-detection-npm.md](cfs-detection-npm.md).
5. **Install credential managers:**
   - **NuGet:** Install `artifacts-credprovider` via the official Microsoft bootstrap script (`https://aka.ms/install-artifacts-credprovider.ps1` on Windows, `.sh` on Linux/Mac).
   - **pip:** Install `keyring` + `artifacts-keyring` into the `.venv` (requires pip 19.2+).
   - **npm:** Install `vsts-npm-auth` globally. Users must run `npx vsts-npm-auth -config .npmrc` once per terminal session before npm operations.
   - **Linux note:** `artifacts-keyring` has additional prerequisites on Linux — see the ADO "Connect to feed" dialog for details.
6. **Update `.gitignore`** — create if missing, append `.venv/` if not already present.
7. **Advisory connectivity check** — warn if the ADO feed is unreachable (network/VPN issue). Config files are still installed.

### Notes for the installer

- The `nuget.config` must be saved as **ASCII** encoding (no BOM). The current repo copy is already ASCII.
- The `pip.ini` should be UTF-8 without BOM.
- The `.npmrc` should be UTF-8 without BOM.
- **Existing configs are validated, not blindly replaced.** If a config file already exists, the installer checks whether it points to a known internal CFS-backed ADO feed (validated against `Install-OrgList.ps1`). Valid configs are preserved; partially valid configs are fixed in place; invalid configs are backed up (`.bak`) then replaced. See the per-ecosystem CFS detection references for decision trees and edge cases.

---

## Part 2 — What This Means for You (VibeShield Users)

### Why this matters

When you build software, your project pulls in open-source libraries — things
like JSON parsers, HTTP clients, and testing frameworks. Some of those
libraries have known security problems. VibeShield makes sure you're only
getting libraries that have been checked for those problems.

### How it works

When you install VibeShield into your project, it sets up your project to
download libraries from a **private, scanned feed** instead of directly from
the public internet. Every library in this feed is automatically checked for
known vulnerabilities before you can use it.

You don't need to do anything special — just add packages the way you
normally would (`dotnet add package`, `pip install`, etc.). The feed handles
the security scanning in the background.

### What gets installed

VibeShield adds three small configuration files to your project:

- **`nuget.config`** — tells .NET where to get packages (the scanned feed).
- **`pip.ini`** — tells Python where to get packages (the same scanned feed). This lives inside a Python virtualenv (`.venv/`) that the installer creates automatically.
- **`.npmrc`** — tells npm/Node.js where to get packages (the same scanned feed).

It also installs **credential helpers** so you can log in to the feed
automatically using your existing Microsoft account:

- For .NET projects: the Azure Artifacts Credential Provider.
- For Python projects: the `keyring` and `artifacts-keyring` packages (authenticates via your browser).
- For npm projects: the `vsts-npm-auth` tool. **Note:** You need to run `npx vsts-npm-auth -config .npmrc` once each time you open a new terminal before using npm.

No tokens or passwords to manage.

### What you need to know

- **Your packages are scanned.** If a library has a known vulnerability, the
  feed flags it so you're aware before it ships.
- **You're a contributor.** When you add a new package to your project, it
  gets added to the shared feed automatically, which means the whole team
  benefits from the same scanned package set.
- **Nothing changes about how you code.** You still use `dotnet add package`,
  `pip install`, or `npm install` exactly as before. The only difference is
  where the packages come from — a safer source.
- **If a tool isn't installed, it's skipped.** If you don't have .NET, Python,
  or Node.js on your machine, the installer simply skips that part and tells
  you. You can re-run later after installing the missing tool.