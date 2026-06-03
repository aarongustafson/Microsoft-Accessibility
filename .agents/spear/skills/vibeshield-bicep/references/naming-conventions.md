# Naming Conventions

## Project Name

`Config.ps1` defines `$script:Project` — the single source of truth for all resource names. Maximum **11 characters** due to downstream Azure limits (ACR: 50 chars, Key Vault: 24 chars global unique).

Suggestion: 4 chars from user alias + 7 random chars (e.g., `ldat081319`).

## Naming Pattern

```
{resourceType}-{project}-{suffix}-{environment}-{locationShort}
```

Example: `rg-ldat081319-dev-cus`, `kv-ldat081319-01-dev-cus`

## Naming Functions in Config.ps1

| Function | Constraint |
|----------|-----------|
| `Get-ResourceGroupName` | Standard pattern |
| `Get-ResourceName` | Generic pattern-based naming |
| `Get-AcrName` | No hyphens allowed (Azure ACR restriction) |
| `Get-KeyVaultName` | 24-char limit, globally unique |
| `Get-SecurityGroupName` | Entra ID security group naming |
| `Get-KmsKeyName` | Key name for disk encryption |
| `Get-AcrAgentPoolName` | 3–20 chars, compact format (no hyphens) |

All functions derive from `$script:Project`. Change the project name in one place — all names update.

## Always Consult MCP Servers

**Before adding a new resource type**, query MCP servers for current naming restrictions:

- `get_bicep_best_practices` — Bicep MCP server for resource-specific constraints
- `get_bestpractices` — Azure MCP server for WAF guidance and naming limits

Azure naming rules change per resource type: character sets, length limits, global uniqueness, and reserved prefixes all vary. MCP servers have current data — static docs go stale.

## Synchronization

The project name must stay in sync across three file types. See [psrule-sync.md](psrule-sync.md) for the full synchronization requirement and why PSRule needs static placeholders.
