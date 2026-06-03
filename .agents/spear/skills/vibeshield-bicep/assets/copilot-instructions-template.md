# Copilot Instructions — Projects.

## Governing Document

**Read and follow [AGENTS.md](../AGENTS.md) before generating, modifying, or validating any code.** That file is the canonical source of truth for all engineering standards, security requirements, quality gates, and agent delegation rules in this project.

The auto-generated `.github/agents/copilot-instructions.md` provides supplementary technology and project structure context. The constitution governs policy; that file provides tooling context. Both apply.

## Path-Specific Instructions

Path-specific instruction files in `.github/instructions/` auto-apply when editing files matching their `applyTo` glob patterns. These ensure the correct agent standards are applied even when an agent is not explicitly invoked.

<!-- BEGIN:path-specific-instructions -->
<!-- END:path-specific-instructions -->

## Automated Agents

Project-wide automated agents and their invocation requirements are defined in [AGENTS.md](../AGENTS.md). Refer to that file for when and how to invoke each agent.
