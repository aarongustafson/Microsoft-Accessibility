---
applyTo: "**/nuget.config,**/.npmrc,**/pip.ini,**/pip.conf"
---

# Package Feed Configuration Standards

When editing package feed configuration files in this repository, follow these requirements:

1. **CFS Compliance**: All package feeds must point to the CFS-backed Azure Artifacts feed. Do not add public registries (nuget.org, pypi.org, npmjs.com) as package sources. CFS scans every package for malware, vulnerabilities, typo-squatting, and dependency confusion before ingestion.
2. **Feed URL**: The approved feed is `https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs`. Protocol-specific paths vary by ecosystem (see the `@vibeshield-safe-libraries` agent at `.github/agents/vibeshield-safe-libraries.agent.md` for standards).
3. **No public fallbacks**: `nuget.config` must include `<clear />` before the CFS source to remove default public sources. `.npmrc` must set `always-auth=true`. `pip.ini`/`pip.conf` must use `index-url` (not `extra-index-url`) to prevent public PyPI fallback.
4. **Validation**: The `vibeshield-safe-libraries` skill (`.github/skills/vibeshield-safe-libraries/SKILL.md`) defines the installation and validation workflow for feed configuration.
5. **Delegation**: For feed config creation, modification, or validation, delegate to `@vibeshield-safe-libraries` rather than editing these files directly.
