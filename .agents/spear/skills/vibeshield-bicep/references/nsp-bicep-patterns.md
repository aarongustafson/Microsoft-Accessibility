# NSP Bicep Patterns Reference

**Agent: Load this document when implementing Network Security Perimeter (NSP) resources in Bicep.**

## 1. API Version Guidance

- **Use `@2025-07-01`** for all NSP resources — newest version accepted by the resource provider
- The bicep-types-az catalog only goes up to `2025-05-01` — `@2025-07-01` is NOT in type metadata
- **All NSP resources require `#disable-next-line BCP081`** suppression

Place `#disable-next-line BCP081` on the line immediately preceding each NSP resource declaration. Include the following explanatory comment block **once** near the top of the file (or above the first NSP resource) to document why the suppression exists — do **not** repeat it before every resource:

```bicep
// BCP081 is expected and suppressed on every Microsoft.Network/networkSecurityPerimeters*
// resource below: the bicep-types-az catalog currently tops out at API version
// 2025-05-01 for the Microsoft.Network namespace, so no installed/available `az bicep`
// has type metadata for `@2025-07-01` (nsp, profiles, profiles/accessRules,
// resourceAssociations). The resource provider accepts the API version; deployment is
// not blocked. Remove these suppressions once bicep-types-az publishes 2025-07-01 for
// Microsoft.Network. Upstream catalog: https://github.com/Azure/bicep-types-az/tree/main/generated/network/microsoft.network
```

Example usage at each NSP resource:

```bicep
#disable-next-line BCP081
resource nsp 'Microsoft.Network/networkSecurityPerimeters@2025-07-01' = {
  name: nspName
  location: location
}
```

**No AVM modules exist for NSP** — must use manual Bicep templates.

## 2. NSP Resource Types Reference

| Resource Type | Bicep Type String | Purpose |
|--------------|-------------------|---------|
| Network Security Perimeter | `Microsoft.Network/networkSecurityPerimeters@2025-07-01` | Root NSP resource. One per region per subscription recommended (max 2500 associations). |
| Profile | `Microsoft.Network/networkSecurityPerimeters/profiles@2025-07-01` | Groups access rules. One profile per access pattern (e.g., "corpnet-access"). |
| Access Rule | `Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2025-07-01` | Inbound: `serviceTags`, `addressPrefixes`, `subscriptions`. Outbound: `fullyQualifiedDomainNames`. |
| Resource Association | `Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2025-07-01` | Binds PaaS resource to profile. `accessMode`: `Enforced` or `Learning`. `privateLinkResource.id` = PaaS resource ID. |
| Logging Configuration | `Microsoft.Network/networkSecurityPerimeters/loggingConfigurations@2025-07-01` | NSP traffic logging. Properties: `enabledLogCategories` (string[]), `version`. Critical for Learning → Enforced workflow. |
| Link | `Microsoft.Network/networkSecurityPerimeters/links@2025-07-01` | Cross-NSP/profile linking. |
| Link Reference | `Microsoft.Network/networkSecurityPerimeters/linkReferences@2025-07-01` | Reference to links. |

All require `#disable-next-line BCP081`. All have a `name` property with maxLength 80 and pattern: `(^[a-zA-Z0-9]+[a-zA-Z0-9_.-]*[a-zA-Z0-9_]+$)|(^[a-zA-Z0-9]$)`.

## 3. Access Rule Schema Details

**Inbound rules:**
```bicep
{
  direction: 'Inbound'
  serviceTags: string[]        // e.g., ['CorpNetPublic'], ['CorpNetSAW']
  addressPrefixes: string[]    // IPv4/IPv6 CIDR e.g., ['10.0.0.0/8']
  subscriptions: [{ id: '<subscription-resource-id>' }]  // cross-subscription access
}
```

**Outbound rules:**
```bicep
{
  direction: 'Outbound'
  fullyQualifiedDomainNames: string[]  // e.g., ['*.contoso.com']
}
```

## 4. CorpNetSAW / CorpNetPublic Service Tag Rules

- **Behind feature flag**: `Microsoft.Network/EnableServiceTagsInNsp`
- **VibeShield deploy target subscriptions already have this enabled**
- For new subscriptions: reference `Register-NspServiceTagFeature.ps1` in `assets/infra/subscription-configuration/` (one-time, subscription-scoped, 10-20 min propagation)
- May not work in AME tenant
- **Create separate rules per service tag** — independent lifecycle management
- Must be configured via CLI/PowerShell/ARM/Bicep (not Portal UI)

Example (each tag gets its own rule):

```bicep
#disable-next-line BCP081
resource accessRuleCorpNetPublic 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2025-07-01' = {
  parent: nspProfile
  name: 'allow-corpnet-public-inbound'
  location: location
  tags: tags
  properties: {
    direction: 'Inbound'
    serviceTags: [
      'CorpNetPublic'
    ]
  }
}

#disable-next-line BCP081
resource accessRuleCorpNetSaw 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2025-07-01' = {
  parent: nspProfile
  name: 'allow-corpnet-saw-inbound'
  location: location
  tags: tags
  properties: {
    direction: 'Inbound'
    serviceTags: [
      'CorpNetSAW'
    ]
  }
}
```

## 5. Access Modes (Persona-Aware Defaults)

| Mode | API Value | When to Use | Behavior |
|------|-----------|------------|----------|
| **Enforced** | `'Enforced'` | **Default for new resources** (Citizen Developer / Vibe Coder). No existing traffic to break. | All public traffic denied except NSP rules. PE traffic unaffected. |
| **Learning** | `'Learning'` | **Only for existing resource onboarding** (Engineer scenario). | Logs access patterns without blocking. Provides zero protection — security theater for new resources. |
| **Audit** | `'Audit'` | Rarely used. Logs without enforcement, similar to Learning. | Available in API but not recommended for VibeShield workflows. |

> **CRITICAL**: Never silently default to `Learning` for new resources. If the deployment context is ambiguous, ask the user. For greenfield deployments, `Enforced` is the only defensible choice.

**Engineer onboarding workflow (existing resources):**
1. Associate with `accessMode: 'Learning'`
2. Deploy `loggingConfigurations` to enable traffic analysis
3. Analyze traffic patterns using Traffic Analysis Tool
4. Create access rules based on observed legitimate traffic
5. Validate all access is covered
6. Switch `accessMode` to `'Enforced'`

## 6. Architecture Guidance

- **One NSP per Region per Subscription** (recommended; max 2500 resource associations per NSP)
- **One Profile per access pattern** — e.g., a "corpnet-access" profile with CorpNetSAW + CorpNetPublic rules
- Multiple PaaS resources can share the same NSP and profile if their access patterns are identical
- The NSP `location` must match the region of associated resources

## 7. Canonical Pattern Reference

The proven NSP pattern is in `assets/infra/modules/nsp-keyvault.bicep.sample`. It demonstrates:
- NSP → Profile → Access Rules (CorpNetPublic + CorpNetSAW) → Resource Association (Enforced)
- The pattern is **generic** — to associate a different PaaS resource, change only `privateLinkResource.id` to that resource's ID
- All required BCP081 suppressions with tracking comments
- Separate rules per service tag

## 8. What NOT to Do

| Anti-Pattern | Why It's Wrong |
|-------------|---------------|
| Set `publicNetworkAccess: 'SecuredByPerimeter'` on PaaS resource prematurely | Per eng.ms TSG — do NOT set this during onboarding. Let NSP manage the access. |
| Use resource firewalls instead of NSP on supported services | Resource firewalls can be bypassed by resource owners (SQL `Allow *`, Storage Trusted Services). NSP is centrally managed. |
| Combine CorpNet service tags into a single rule | Breaks independent lifecycle management. Each tag should have its own rule. |
| Default to `Learning` for new resources | Provides zero protection. Greenfield → `Enforced`. |
| Use `@2025-05-01` API version | Missing latest features. Use `@2025-07-01` with BCP081 suppressions. |
| Skip BCP081 suppression comments | Without the explanation comment, future maintainers won't know why suppressions exist or when to remove them. |

## Sources

- Canonical pattern: `assets/infra/modules/nsp-keyvault.bicep.sample`
- Feature flag script: `assets/infra/subscription-configuration/Register-NspServiceTagFeature.ps1`
- NSP architecture decision tree: `skills/vibeshield-bicep/references/network-isolation-decision-tree.md`
- Microsoft eng.ms TSG: Network Security Perimeter onboarding guidance
- Azure Resource Provider API: Microsoft.Network/networkSecurityPerimeters@2025-07-01
