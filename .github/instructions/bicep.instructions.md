---
applyTo: "**/*.bicep"
---

# Bicep Standards

When editing Bicep files in this repository, follow these requirements:

1. **Policy**: Read and comply with the constitution (`.specify/memory/constitution.md`) — specifically the Quality Gates, SFI Compliance, and Well-Architected Framework sections.
2. **Implementation standards**: The `@vibeshield-bicep` agent (`.github/agents/vibeshield-bicep.agent.md`) is the canonical source for Bicep design patterns, including SFI principles, WAF alignment, modular design, and MCP server consultation.
3. **Validation**: The `vibeshield-bicep` skill (`.agents/spear/skills/vibeshield-bicep/SKILL.md`) defines the two-tier validation workflow (lint-on-edit + checkpoint with PSRule). Follow its procedures for compliance.
4. **Delegation**: For new templates, modifications, **and validation**, delegate to `@vibeshield-bicep` rather than generating Bicep or running validation scripts directly.
