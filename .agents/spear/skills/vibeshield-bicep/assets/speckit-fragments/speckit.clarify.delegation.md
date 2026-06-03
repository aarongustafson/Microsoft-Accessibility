<!-- BEGIN:vibeshield-bicep-delegation -->
## Infrastructure Clarification Guidance

When the specification involves **Azure infrastructure**, consult `@vibeshield-bicep` before generating your clarification questions — not to get implementation answers, but to ask better questions.

### Why Consult

The vibeshield-bicep agent understands Azure resource capabilities, constraints, and relationships via MCP servers. It can identify ambiguities you might miss:
- Resources that sound similar but have different capabilities (e.g., App Service vs Container Apps)
- Implicit dependencies between resources that the spec doesn't acknowledge
- Security or compliance assumptions that need to be made explicit
- Whether stated requirements are realistic for the resource types mentioned

### How to Consult

Before finalizing your prioritized question queue (step 3), delegate to `@vibeshield-bicep`:
- "Review this spec's Azure resource references. What infrastructure ambiguities or unstated assumptions would create the most rework risk during planning?"

Use the agent's response to inform your question prioritization. Infrastructure ambiguities that affect security posture or resource selection are **high impact** and should rank above cosmetic or preference questions.

Do **not** ask the user implementation-level questions based on the agent's response (e.g., "Which SKU?", "How many availability zones?"). Those belong in planning. Focus on requirement-level gaps: "Should this be accessible from the internet or internal only?" rather than "Should we use a private endpoint?"
<!-- END:vibeshield-bicep-delegation -->
