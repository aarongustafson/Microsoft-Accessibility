<!-- BEGIN:vibeshield-bicep-delegation -->
## Infrastructure Planning — Delegate to `@vibeshield-bicep`

When the feature involves **Azure infrastructure**, the `@vibeshield-bicep` agent is your primary research and design partner. It has access to MCP servers with current knowledge of Azure best practices, the Well-Architected Framework, and Azure Verified Modules that you do not have. **Use it.**

### Phase 0 (Research) — Ask `@vibeshield-bicep` First

Do not research Azure infrastructure patterns yourself. Delegate to `@vibeshield-bicep` with the resource types from the spec:

- "What are the current best practices and validated modules for these Azure resource types: [list from spec]?"
- "What Well-Architected Framework guidance applies to this architecture?"
- "What security constraints apply to these resources under SFI?"

The agent consults MCP servers that have authoritative, up-to-date guidance — including Azure Verified Modules (pre-built, WAF-aligned Bicep modules) that can dramatically simplify the implementation. Record its findings in `research.md`.

### Phase 1 (Design & Contracts) — Co-Design with `@vibeshield-bicep`

For infrastructure design decisions, delegate to `@vibeshield-bicep`:

- "Design the module structure for this architecture. Which validated modules exist and which need custom Bicep?"
- "Define the parameter interfaces and contracts for these infrastructure modules."

The agent will produce module designs that are compliant from the start — baking in security and WAF alignment rather than retrofitting after validation failures. Use its output for `data-model.md` and `/contracts/`.
<!-- END:vibeshield-bicep-delegation -->
