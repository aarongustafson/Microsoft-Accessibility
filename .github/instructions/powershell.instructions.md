---
applyTo: "**/*.ps1,**/*.psm1"
---

# PowerShell Standards

When editing PowerShell files in this repository, follow these requirements:

1. **Policy**: Read and comply with the constitution (`.specify/memory/constitution.md`) — specifically the Quality Gates and SFI Compliance sections.
2. **Implementation standards**: The `@vibeshield-powershell` agent (`.github/agents/vibeshield-powershell.agent.md`) is the canonical source for defensive PowerShell patterns, including Strict Mode, null handling, pipeline safety, parameter validation, and error handling.
3. **Validation**: The `vibeshield-powershell` skill (`.agents/spear/skills/vibeshield-powershell/SKILL.md`) defines the two-tier validation workflow (hook + checkpoint). Follow its procedures for PSScriptAnalyzer compliance.
4. **Delegation**: For new scripts, modifications, **and validation**, delegate to `@vibeshield-powershell` rather than generating PowerShell or running validation scripts directly.
