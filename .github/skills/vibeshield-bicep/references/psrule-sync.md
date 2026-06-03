# PSRule Synchronization

## The Problem

PSRule does static analysis — it expands Bicep files using mock deployment context defined in YAML. It cannot execute PowerShell. This means values that `Config.ps1` computes dynamically must be duplicated as static values in PSRule config files.

If these values drift, PSRule validates against wrong resource names — causing false positives or missed violations.

## Three Files Must Stay in Sync

When the project name changes, update all three:

| File | Field | Role |
|------|-------|------|
| `Config.ps1` | `$script:Project` | **Source of truth** — used at deploy time |
| `parameters.*.bicepparam` | `param project` | Placeholder for Bicep compile; overridden by CLI at deployment |
| `PSRule.*.yaml` | `AZURE_PARAMETER_DEFAULTS.project` | Static value PSRule uses during file expansion |

## Additional PSRule Sync Points

Beyond the project name, these PSRule YAML values must also match `Config.ps1`:

| PSRule YAML field | Must match |
|-------------------|-----------|
| `AZURE_PARAMETER_DEFAULTS.project` | `$script:Project` |
| `AZURE_RESOURCE_GROUP.name` | `Get-ResourceGroupName` output |
| `AZURE_RESOURCE_GROUP.location` | `$script:Location` |
| `AZURE_DEPLOYMENT.location` | `$script:Location` |

## Why PSRule Needs Placeholders

PSRule's `AZURE_BICEP_FILE_EXPANSION` expands `main.bicep` into a full deployment graph for analysis. To do this, it needs:

- **`AZURE_PARAMETER_DEFAULTS`** — supplies values for required Bicep parameters not in `.bicepparam`
- **`AZURE_RESOURCE_GROUP`** — mocks `resourceGroup().name` and `resourceGroup().location`
- **`AZURE_DEPLOYMENT`** — mocks `deployment().name` and `deployment().location`

These are static YAML values. PSRule cannot call `Config.ps1` to compute them at analysis time.

## Onboarding

The scaffolding uses `{{REPLACE-WITH-11-CHAR-PROJECT-NAME}}` as a placeholder across all three file types. When onboarding a new project, replace this placeholder everywhere with your actual project name.

## Dev vs Prod

Both `PSRule.dev.yaml` and `PSRule.prod.yaml` have their own sync points. Dev uses `-dev-` in the resource group name; prod does not. Update both configs when the project name changes.
