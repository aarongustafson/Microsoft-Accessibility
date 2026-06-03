# Scaffolded infra/ Folder

The `Initialize-BicepProject.ps1` script creates this standard layout:

```
infra/
├── main.bicep                     # Deployment entry point (orchestration)
├── modules/                       # Custom Bicep modules
│   └── nsp-keyvault.bicep.sample  # Commented sample: NSP + service tags on a Key Vault
├── subscription-configuration/    # Subscription-scoped one-time setup scripts
│   ├── Create-ResourceGroup.ps1
│   └── Register-NspServiceTagFeature.ps1
├── Config.ps1                     # Naming and project settings (single source of truth)
├── Deploy.ps1                     # Repeatable deployment (dev/prod)
├── parameters.dev.bicepparam      # Dev environment parameters
├── parameters.prod.bicepparam     # Prod environment parameters
├── PSRule.dev.yaml                # PSRule config — dev (relaxed cost/HA rules)
└── PSRule.prod.yaml               # PSRule config — prod (full WAF enforcement)
```

## Key Files

**`main.bicep`** — Orchestration entry point. All modules are referenced from here. PSRule file expansion analyzes this file and expands all module dependencies. This is a starter template — most resource definitions are commented as examples.

**`modules/`** — Custom Bicep modules live here. AVM registry modules (`br:mcr.microsoft.com/bicep/avm/...`) are also wired through `main.bicep`. Modules are NOT analyzed by PSRule individually — only through expansion from `main.bicep`. The folder is seeded with `nsp-keyvault.bicep.sample`, a fully-commented reference template that demonstrates how to apply a Network Security Perimeter (NSP) to an existing Key Vault and allow inbound traffic from developer machines (`CorpNetPublic`) and Secure Admin Workstations (`CorpNetSAW`) via service tags. The sample requires the `Microsoft.Network/EnableServiceTagsInNsp` subscription feature to be registered first — run `subscription-configuration/Register-NspServiceTagFeature.ps1` before referencing this module from `main.bicep`. Rename to `.bicep` and uncomment to use.

**`Config.ps1`** — Single source of truth for project name, location, and all resource naming. See [naming-conventions.md](naming-conventions.md) for details.

**`subscription-configuration/`** — Subscription-scoped one-time setup scripts. By convention, any future scripts that operate at subscription scope (e.g., security-group provisioning) belong here.

**`subscription-configuration/Create-ResourceGroup.ps1`** — One-time setup. Deploys `resourcegroup.bicep` (in the parent `infra/` folder) at subscription scope via `az deployment sub create`. Requires Contributor at subscription scope. Cannot assign RBAC roles — needs separate Owner or User Access Administrator for that.

**`subscription-configuration/Register-NspServiceTagFeature.ps1`** — One-time setup. Registers the `Microsoft.Network/EnableServiceTagsInNsp` subscription feature required for NSP access rules that reference the `CorpNetPublic` or `CorpNetSAW` service tags. Idempotent; polls until the feature reaches `Registered` and re-registers the `Microsoft.Network` provider so the feature takes effect.

**`Deploy.ps1`** — Repeatable infrastructure deployment. Accepts `-Environment dev|prod`, validates Azure login and RG existence, deploys `main.bicep` with the matching `.bicepparam` file.

**`PSRule.*.yaml`** — Environment-specific PSRule configs. Both use `AZURE_BICEP_FILE_EXPANSION: true` and `pathIgnore` to target only `main.bicep`. Dev relaxes cost/HA rules; prod enforces the full ruleset. See [psrule-sync.md](psrule-sync.md) for synchronization requirements.

## Why This Structure Matters

PSRule file expansion analyzes `main.bicep` and recursively expands all module references into a single deployment graph. This is what enables WAF and SFI validation across the entire infrastructure.

**Breaking the modular pattern breaks validation.** If modules are deployed standalone (not referenced from `main.bicep`), PSRule cannot see them. Keep all module references wired through the entry point.
