# SFI Pillars and KPIs — Bicep Agent Reference

The Microsoft **Secure Future Initiative (SFI)** defines **six pillars** of security practice. This reference is the authoritative source for SFI pillar definitions, their Bicep-expressible controls, and the KPIs that target specific resource types.

> Source: Microsoft internal — CELA Engineering Fundamentals / SFI (Microsoft-tenant SharePoint).

**Note on scope:** Pillar 4 (Protect engineering systems) is fully delegated to `vibeshield-deploy-orchestrator` (pipelines, build identities, code signing, SBOM) and `vibeshield-safe-libraries` (package feeds, supply-chain policy). Delegated KPIs are omitted from the resource-type index below; see those agents' specs for pillar 4 coverage. The `SFI-ES*` prefix is retained in the legend and in the load triggers so that if a user mentions one, this file still loads and routes correctly.

## When to load this reference

Load this reference when:
- The user is deploying or modifying an Azure resource type listed in the **by-Resource-Type index** (Storage, Key Vault, SQL, Cosmos DB, Event Hubs, Service Bus, AKS, VMSS, API Management, Container Apps, Redis, Cognitive Services, etc.). Jump directly to that resource's section.
- The user asks *which KPI* applies to a specific resource, or references an SFI control ID (SFI-ID*, SFI-TI*, SFI-NS*, SFI-ES*, SFI-SM*, SFI-AR*). If the reference is `SFI-ES*` or otherwise pillar-4, route the user to `vibeshield-deploy-orchestrator` / `vibeshield-safe-libraries` after consulting.
- You need pillar-level guidance beyond the six one-line bullets in the agent's Phase 3 design workflow — especially for the pillars whose Bicep controls aren't rehearsed often in Phase 3: tenant isolation, monitoring/detection, and response/remediation.

---

## The Six SFI Pillars

### 1. Protect identities and secrets

> Reduce the risk of unauthorized access by implementing and enforcing best-in-class standards across all identity and secrets infrastructure, and user and application authentication and authorization.

**Bicep-expressible controls:**
- Managed Identity (system-assigned or user-assigned) for all service-to-service auth.
- Entra ID for user auth; Easy Auth / MISE for API token validation (`WEBSITE_AAD_ENABLE_MISE = true` on App Service).
- No local accounts: disable SQL auth, SAS keys, Shared Key storage access, local Cosmos keys, Event Hubs / Service Bus SAS, Redis access keys, Cognitive Services account keys.
- No credentials in parameters, parameter defaults, variables, or outputs. `@secure()` on sensitive parameters; Key Vault references for secrets.
- No passwords or pinned certs on App Registrations; no self-signed certs (can't be revoked during incidents).
- JIT / PIM for Contributor and Owner role assignments; no persistent personal access to production.
- Remove over-privileged role assignments (Owner, Contributor, User Access Administrator, RBAC Admin) — prefer scoped roles and just-enough permissions.

**KPI families:** `SFI-ID2.x` (MISE), `SFI-ID4.x` (Safe Secrets across Storage / SQL / Cosmos / Event Hubs / Service Bus / Cognitive Services / Redis / MSA apps / Entra ID apps), `SFI-TI5.x` (Always JIT / PIM), `SFI-TI3.3.x` (RBAC governance).

### 2. Protect tenants and isolate production systems

> Protect all Microsoft tenants and production environments using consistent, best-in-class security practices and strict isolation to minimize impact.

**Bicep-expressible controls:**
- Do not home customer-facing production workloads in Corpnet — deploy to PME or AME tenants.
- Separate identities, credentials, and certs by cloud and tenant — no duplication across GME/AME/Corp.
- Declare cross-cloud token-trust intent explicitly (services using MISE must configure; services on obsolete identity libraries require code changes).
- Enforce tenant component boundary (TCB) isolation for non-production environments.

**KPI families:** `SFI-TI1.x` (cross-cloud token trust), `SFI-TI3.2.x` (cert separation), `SFI-TI4.x` (identity isolation across clouds, non-prod tenant isolation), `SFI-TI6.x` (enterprise app homing).

### 3. Protect networks

> Protect Microsoft production networks and network isolate Microsoft and customer resources.

**Bicep-expressible controls:**
- Private endpoints and/or Network Security Perimeter (NSP) for all NSP-supported PaaS services (Storage, Key Vault, SQL, Cosmos DB, Data Lake, Event Hubs, etc.). Resource firewalls alone are insufficient — they can be bypassed (e.g., SQL `Allow *`, Storage "Trusted Services").
- Mark all subnets as private; eliminate default outbound; require explicit outbound rules or NAT Gateways.
- Service Tags on all public IPs — no untagged or backfill IPs without business justification. **[Agent support: not yet implemented]** SFI `SFI-NS2.1.x` requires this; however, `vibeshield-bicep` does not currently generate the Bicep or tooling to satisfy it. When a deployment includes Public IP resources, do **not** invent controls — surface this as a known gap: tell the user that Service Tag coverage for Public IPs is an SFI requirement the agent cannot yet automate, and that they must track compliance through their own governance process (e.g., Azure Policy, Resource Graph queries, or the SFI dashboard) until agent support is added.
- Premium Azure Front Door + DDoS Protection Standard for public-facing web apps; WAF configured.
- Bring-Your-Own-IP (BYOIP) + NAT Gateway for Container Apps and ACI (instead of HOBO-provided IPs).
- Disable anonymous access to blob containers.
- Advanced network segmentation to limit lateral movement.

**KPI families:** `SFI-NS1.x` (internet/corpnet isolation, segmentation), `SFI-NS2.1.x` (service tags on public IPs), `SFI-NS2.2.x` (PaaS network isolation — `NS2.2.1` is primary), `SFI-NS2.5.x` (default isolation enforcement, Application DDoS), `SFI-NS2.6.x` (default outbound), `SFI-NS3.2.x` (Container Apps / ACI), `SFI-TI2.3.x` (disable anonymous blob access).

### 4. Protect engineering systems

> Protect software assets and continuously improve code security through governance of the software supply chain and engineering systems infrastructure.

Delegated to `vibeshield-deploy-orchestrator` (pipelines, build identities, code signing, SBOM) and `vibeshield-safe-libraries` (package feeds, supply-chain policy). See those agents' specs for controls and KPI coverage in this pillar.

### 5. Monitor and detect threats

> Comprehensive coverage and automatic detection of threats to Microsoft production infrastructure and services.

**Bicep-expressible controls:**
- `diagnosticSettings` on every resource, routed to a Log Analytics workspace (or Event Hub).
- Microsoft Defender for Cloud plans enabled for deployed resource types (Servers, Storage, SQL, Key Vault, Containers, App Service, etc.).
- Required baseline monitoring agents (Azure Security Pack) deployed on IaaS.
- Alert rules on security-relevant signals (failed auth, access from untrusted locations, policy violations).

**KPI families:** `SFI-SM2.1.x` (Defender for Servers, Azure Security Pack baseline agents).

### 6. Accelerate response and remediation

> Prevent exploitation of vulnerabilities discovered by external and internal entities, through comprehensive and timely remediation.

**Bicep-expressible controls:**
- Auto-OS-patching for VMSS, AKS nodes, single VMs on VMSS Flex.
- First-party Microsoft base images for VMs.
- VMSS auto extension updates.
- Enhanced VM vulnerability management signals.
- Backup / DR policies on stateful resources.
- Key / credential rotation cadence — only feasible when pillar 1 is honored (no hard-coded secrets).

**KPI families:** `SFI-AR1.x` (auto-patching for VMSS / AKS / VM; first-party images; VM vuln management).

---

## KPI Reference — by Resource Type

*"I'm deploying X — what KPIs apply and what must I put in Bicep?"* Find the resource below and apply the listed controls. Cross-cutting KPIs (RBAC, cloud/tenant selection, universal baselines) are grouped at the end.

Pillar 4 KPIs (delegated — `SFI-ES*`, `SFI-SM2.3.x` Continuous SDL, `SFI-TI1.4.x` RDFE migration, `SFI-ES2.6.x` ESME build identities) are **not listed** here; see `vibeshield-deploy-orchestrator` and `vibeshield-safe-libraries`.

### Data & messaging services

**Azure Storage** (blob / file / queue / table)
- `SFI-ID4.2.1` — Disable Shared Key auth; require identity-based access (Managed Identity / Entra ID).
- `SFI-TI2.3` / `SFI-TI2.3.3` — Disable anonymous access to blob containers; no public containers.
- `SFI-NS2.2.1` — Private endpoint and/or NSP. Resource firewall ("Trusted Services" exception) is insufficient.

**Azure Key Vault**
- `SFI-NS2.2.1` — Private endpoint and/or NSP.

**Azure SQL Database**
- `SFI-ID4.2.2` — Entra ID-only authentication; no SQL auth.
- `SFI-NS2.2.1` — Private endpoint and/or NSP. Resource firewall `Allow *` rule is not compliant.

**Azure SQL Managed Instance**
- `SFI-ID4.2.4` — Passwordless authentication.
- `SFI-NS2.2.1` — Private endpoint and/or NSP.

**Azure Cosmos DB**
- `SFI-ID4.2.3` — Disable local keys; require Managed Identity or token-based auth.
- `SFI-NS2.2.1` — Private endpoint and/or NSP.

**Azure Event Hubs**
- `SFI-ID4.3.2` — Disable local / shared keys; require Managed Identity or Entra ID.

**Azure Service Bus**
- `SFI-ID4.3.3` — Disable SAS / local auth; require Managed Identity or Entra ID.

**Azure Cache for Redis**
- `SFI-ID4.2.7` — Eliminate shared keys; require identity-based access.

**Azure Data Lake Storage Gen1**
- `SFI-NS2.2.1` — Network isolation required; restrict account access.

**Azure AI Foundry / Cognitive Services**
- `SFI-ID4` / `SFI-ID4.3.1` (Cognitive Services Safe Secrets) — Disable account keys; require identity-based access.

### Compute

**Virtual Machines (VMs)**
- `SFI-AR1.2.2` — First-party Microsoft base images only.
- `SFI-AR1.2.8` — Enhanced VM vulnerability management signals enabled.
- `SFI-SM2.1.1` — Azure Security Pack baseline agents deployed.
- `SFI-SM2.1.2` — Microsoft Defender for Cloud Server plan enabled.

**VM Scale Sets (VMSS)**
- `SFI-AR1.2.1` — Auto OS image upgrades enabled.
- `SFI-AR1.2.5` — Auto extension updates enabled.
- `SFI-AR1.2.6` — Standardize single-VM workloads on VMSS Flex with auto-updates.

**Azure Kubernetes Service (AKS)**
- `SFI-AR1.2.3` (a.k.a. `AR-1.1.5`) — Node auto-upgrade enabled.
- `SFI-ID2.1.1` — MISE sidecar for token validation when AKS serves APIs.

**App Service / Azure Functions / API workloads**
- `SFI-ID2.1.1` / `SFI-ID2.1.2` — MISE compliance; Easy Auth or MISE libraries for token validation. On App Service, set `WEBSITE_AAD_ENABLE_MISE = true`.
- `SFI-ID2.1.9` — No unauthenticated endpoints.

**Azure Container Apps**
- `SFI-NS3.2.4` — Bring-Your-Own-IP (BYOIP): attach a subnet to the container app environment + a NAT Gateway. 

**Azure Container Instances (ACI)**
- `SFI-NS3.2.1` — NAT Gateway required when ACI is VNet-integrated or accesses AME tenants.

### Network infrastructure

**Virtual Networks / Subnets**
- `SFI-NS2.6.1` — Mark all subnets private; disable default outbound; add explicit outbound rules or a NAT Gateway.
- `SFI-NS1.7.1` / `SFI-NS1.7.3` — No internet or Corpnet connectivity from AP/PF/extended environments.
- `SFI-NS1.13.x` — Advanced segmentation to limit lateral movement.
- `SFI-NS2.5.2` — Default network isolation enforced.

**Public IP Addresses / NSG rules**
- `SFI-NS2.1.1` / `SFI-NS2.1.4` / `SFI-NS2.1.6` — Service Tag required on every public IP; apply service tag if the user has one. Note prototypes should use virtual tags to skip this KPI as acquiring a service tag requires 6-8 weeks and a manual form.
- `SFI-NS2.1` — Replace hard-coded IP ACLs in NSGs / firewall rules with Azure Service Tags.

**Azure Front Door (public-facing web apps)**
- `SFI-NS2.5.3` — Premium SKU + Azure DDoS Protection Standard + WAF configured.

### Identity resources

**Entra ID App Registrations / Enterprise Applications**
- `SFI-ID4.1.1` — No passwords or pinned certs on App Registrations.
- `SFI-ID4.5.1` — No self-signed certs (can't be revoked during incidents).
- `SFI-TI3.1.9` — Enterprise application governance.
- `SFI-TI3.2.2` — Homed Service Principal governance — align SPs and credentials with their home tenant.
- `SFI-TI6.1` — Customer-facing enterprise apps cannot be Corpnet-homed; deploy to PME or AME.
- `SFI-6.1.1` — Declare cross-cloud token-trust intent explicitly (required for MISE services; obsolete identity libraries need code changes).

**Microsoft Account (MSA) apps**
- `SFI-ID4.x` (MSA Apps) — Eliminate hard-coded secrets and app passwords; adopt modern authentication.

### Cross-cutting — apply regardless of resource

**RBAC role assignments**
- `SFI-TI5.1.1` — JIT / PIM required for Contributor and Owner role assignments.
- `SFI-TI6.3.2` — Endpoint least-privilege access on VMs / endpoints.

**Cloud / tenant selection**
- `SFI-TI4.1.1` — Identity, credential, and token isolation across cloud environments.
- `SFI-TI3.2.1` — Certs cannot exist in both GME+AME or AME+Corp.
- `SFI-TI3.2.4` — Same-cloud token issuance — restrict token issuance and acceptance to same-cloud resources.

- `SFI-TI2.3` — No plain-text secrets deployed to Azure subscriptions.

---

## KPI ID prefixes — quick legend

The prefix on each KPI ID identifies its pillar:

| Prefix | Pillar |
|---|---|
| `SFI-ID*` | 1 — Protect identities and secrets |
| `SFI-TI*` | 2 — Protect tenants and isolate production systems (also some identity-adjacent controls like `TI5.x` JIT) |
| `SFI-NS*` | 3 — Protect networks |
| `SFI-ES*` | 4 — Protect engineering systems *(delegated — see `vibeshield-deploy-orchestrator` and `vibeshield-safe-libraries`)* |
| `SFI-SM*` | 5 — Monitor and detect threats (Security Monitoring) |
| `SFI-AR*` | 6 — Accelerate response and remediation |

---

## How to use this reference alongside the agent

- The agent's Phase 3 (Creation Workflow) and Validation §3 reference the **six pillars** at a high level. This file provides the pillar definitions and, separately, a resource-type index for looking up applicable controls.
- **Primary lookup path for design:** go to the by-Resource-Type section. Find the Azure resource the user is deploying (or modifying), read its bulleted list, and apply each KPI's control in Bicep.
- **Lookup path for a KPI ID reference from the user:** the prefix tells you the pillar (see legend). Search the by-Resource-Type section for the ID; if the prefix is `SFI-ES*`, route to `vibeshield-deploy-orchestrator` / `vibeshield-safe-libraries` instead.
- For any NSP-supported PaaS resource, also load `network-isolation-decision-tree.md` and `nsp-bicep-patterns.md` — they go deeper on the Pillar 3 network-isolation decisions than this reference does.
- KPIs evolve over time. Treat this reference as a point-in-time snapshot; the SharePoint source is authoritative for newly added or retired KPIs.
