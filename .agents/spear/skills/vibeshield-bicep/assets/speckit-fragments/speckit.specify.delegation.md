<!-- BEGIN:vibeshield-bicep-delegation -->
## Infrastructure Feasibility Consultation

When the feature description involves **Azure infrastructure** (deploying, managing, or configuring Azure resources), consult `@vibeshield-bicep` during specification — not for implementation details, but for two specific purposes:

### 1. Feasibility Validation

Before finalizing the spec, delegate a feasibility check to `@vibeshield-bicep`:
- "Given this feature description, are the Azure resources referenced real and appropriate for the stated goals?"
- "Are there constraints or limitations with these resource types that should appear as assumptions or edge cases in the spec?"
- "Does anything in this spec conflict with SFI security principles that would make it infeasible as written?"

The agent has access to current Azure resource metadata and best practices via MCP servers. Use its response to refine requirements and identify risks — but do **not** add implementation details (specific SKUs, Bicep patterns, module names) to the spec.

### 2. Terminology Consistency

Azure resource names, capabilities, and service boundaries change. Before finalizing:
- Delegate to `@vibeshield-bicep`: "Verify that the Azure resource names and capabilities referenced in this spec use current terminology."
- If the agent identifies outdated or incorrect terms (e.g., "Azure AD" → "Microsoft Entra ID", deprecated resource types), update the spec to use canonical names.

This keeps the spec accurate for downstream planning without leaking implementation into the requirements.
<!-- END:vibeshield-bicep-delegation -->
