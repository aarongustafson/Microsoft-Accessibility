---
agent: vsd
description: "Prompt template for SC existence verification and user guidance when service connections are missing. Used in Stage 2 (warning) and Stage 3 (blocking). Replaces the former auto-trigger of the onboarding pipeline."
---

# Service Connection Verification Prompt

When pipeline YAML references service connections that don't exist in Azure DevOps, use these templates to guide the user.

## Trigger Conditions

This prompt is used when `Test-ServiceConnectionExists` returns `Exists: false` for any SC referenced in the pipeline YAML:

| SC Type | Naming Pattern | Example |
|---------|---------------|---------|
| ARM SC | `sc-vibe-{username}-ARM` or user-provided | `sc-vibe-user.name-ARM` |
| EV2 SC | `cn-ev2deploy-{service}-{env}` or user-provided | `cn-ev2deploy-myservice-dev` |

## Stage 2 Warning Template (non-blocking)

After pipeline authoring, if any SC is missing, emit this **warning** — do NOT block:

> ⚠️ **Service connection not found**
>
> The following service connection(s) referenced in your pipeline do not exist yet in Azure DevOps:
> - `<sc-name-1>`
> - `<sc-name-2>`
>
> The pipeline will fail at runtime unless these are created before Stage 3 (Code Push).
>
> Please contact the **CELA SPEAR team** to provision them:
> - Email: [CELAVibeShieldSupport@microsoft.com](mailto:CELAVibeShieldSupport@microsoft.com)
> - Office Hour: [Contact Us](https://microsoft.sharepoint.com/teams/CELAEngineeringFundamentals/SitePages/Contact-Us.aspx)

## Stage 3 Blocking Template

Before pipeline push, if any SC is missing, **block deployment**:

> ⛔ **Deployment blocked — service connection(s) not found**
>
> The following service connection(s) are required by your pipeline but do not exist in Azure DevOps:
> - `<sc-name-1>` (used by `<stage/task>`)
> - `<sc-name-2>` (used by `<stage/task>`)
>
> Please contact the **CELA SPEAR team** to provision these service connections:
> - Email: [CELAVibeShieldSupport@microsoft.com](mailto:CELAVibeShieldSupport@microsoft.com)
> - Office Hour: [Contact Us](https://microsoft.sharepoint.com/teams/CELAEngineeringFundamentals/SitePages/Contact-Us.aspx)
>
> Once the SPEAR team confirms your infrastructure is ready, come back and say **"resume deployment"** to continue.

## Stage 4 Blocking Template

If the monitor detects missing SCs (shouldn't normally happen if Stage 3 passed), **block monitoring**:

> ⛔ **Monitoring blocked — service connection(s) not found**
>
> One or more service connections used by this pipeline no longer exist in Azure DevOps. This may indicate the infrastructure was modified after deployment started.
>
> Please contact the **CELA SPEAR team** and say **"resume deployment"** once resolved.

## User Opt-Out

This prompt does NOT auto-run any pipeline. Infrastructure provisioning is handled out-of-band by the SPEAR team. The agent only verifies SC existence — it never provisions resources.
