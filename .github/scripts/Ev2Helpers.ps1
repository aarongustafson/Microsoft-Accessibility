#!/usr/bin/env pwsh
#Requires -Version 7.0
Set-StrictMode -Version Latest
<#
.SYNOPSIS
    EV2 and tenant-mapping helper functions extracted from SharedHelpers.ps1.
.DESCRIPTION
    Contains EV2 handover data collection, EV2 artifact validation,
    tenant mapping, and extension identity resolution.
    These functions are used only by the OneBranch/EV2 deployment path.

    Requires SharedHelpers.ps1 to be loaded first (provides Invoke-AzCommand,
    Get-DeployConfig, Get-DeployContext, Get-ServiceDescription).
#>

# -- Idempotency guard: skip if already loaded --------
if (Get-Command Get-Ev2HandoverData -ErrorAction SilentlyContinue) { return }

# -- Ensure SharedHelpers is loaded (dependency) ------
$_shPath = Join-Path -Path $PSScriptRoot -ChildPath 'SharedHelpers.ps1'
if (-not (Get-Command Get-DeployConfig -ErrorAction SilentlyContinue)) {
    if (Test-Path $_shPath) { . $_shPath }
}

# ════════════════════════════════════════════════════════════
# Tenant Mapping — reads from deploy-config.json
# ════════════════════════════════════════════════════════════
# TME tenant  : ONLY for MS Graph identity lookups during user onboarding
#               (resolving email, username, Object ID) in poc/dev environments.
# Corp tenant : Used for ALL other operations — ADO git auth, ADO API calls,
#               service connections, pipeline runtime, RBAC, and also for
#               Graph identity lookups in uat/prod environments.

function Get-OnboardingTenantId {
    <#
    .SYNOPSIS Returns the Entra ID tenant for onboarding, determined by projectType.
    .DESCRIPTION
        Resolves the tenant for user onboarding (Graph identity lookups, service
        connection creation, RBAC). Uses the default tenant for the projectType
        (first in projectTypes.<type>.tenants array).
          prototype   → TME tenant  (70a036f6-...)
          businessUse → Corp tenant (72f988bf-...)
        Reads from deploy-config.json (projectTypes.<type>.tenants[0]).
    .PARAMETER ProjectType
        One of: prototype, businessUse.
    .OUTPUTS System.String — the tenant GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('prototype', 'businessUse')]
        [string]$ProjectType
    )
    $cfg = Get-DeployConfig
    $tenants = $cfg.projectTypes.$ProjectType.tenants
    if (-not $tenants -or $tenants.Count -eq 0) {
        Write-Error "No tenants configured for projectType '$ProjectType'. Check deploy-config.json projectTypes.$ProjectType.tenants."
        return $null
    }
    $defaultTenantKey = $tenants[0]
    return $cfg.tenants.$defaultTenantKey.id
}

# ════════════════════════════════════════════════════════════
# EV2 Handover Helpers
# ════════════════════════════════════════════════════════════

function Get-TenantDisplayName {
    <#
    .SYNOPSIS Returns the ev2-demo-agent display name for a tenant key.
    .PARAMETER TenantKey  One of: tme, corp. Case-insensitive.
    .OUTPUTS System.String — e.g. 'TME', 'Corpnet'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantKey
    )
    $cfg = Get-DeployConfig
    $key = $TenantKey.ToLower()
    # New structure: tenants.<key>.displayName
    if ($cfg.PSObject.Properties['tenants'] -and $cfg.tenants -and
        $cfg.tenants.PSObject.Properties[$key] -and
        $cfg.tenants.$key.PSObject.Properties['displayName']) {
        return $cfg.tenants.$key.displayName
    }
    Write-Error "No display name configured for tenant key '$key'. Check deploy-config.json tenants.$key.displayName."
    return $null
}


function Get-Ev2PolicyDirectives {
    <#
    .SYNOPSIS Generates mandatory SFI-compliant policy directives for EV2 handover (WI-4).
    .PARAMETER BackingServices  Output from Get-ApplicationBackingServices.
    .PARAMETER IdentityResourceId  Extension identity resource ID (from identity resolution).
    .OUTPUTS Array of directive hashtables with Id, Priority, Rule, Details.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification='Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [array]$BackingServices = @(),
        [string]$IdentityResourceId = ''
    )

    $directives = [System.Collections.ArrayList]::new()

    # DIRECTIVE 1: Identity
    $identityDetails = 'SQL Server with Entra-only auth additionally requires Directory Readers role on its MI.'
    $null = $directives.Add(@{
        Id       = 'IDENTITY'
        Priority = 'MANDATORY'
        Rule     = 'Every ARM resource that supports managed identity MUST include identity block with type: SystemAssigned.'
        Details  = $identityDetails
    })

    # DIRECTIVE 2: Network
    $null = $directives.Add(@{
        Id       = 'NETWORK'
        Priority = 'MANDATORY'
        Rule     = 'Every resource with defaultAction: Deny MUST have a Private Endpoint or VNet rule in the same rollout.'
        Details  = 'Deploy VNet, subnets, NSGs, and PEs BEFORE or WITH the resources they protect.'
    })

    # DIRECTIVE 3: RBAC
    $rbacDetails = [System.Collections.ArrayList]::new()
    $hasStorage = $BackingServices | Where-Object { $_.Type -in @('Storage', 'BlobStorage') }
    $hasKV = $BackingServices | Where-Object { $_.Type -eq 'KeyVault' }
    if ($hasStorage) { $null = $rbacDetails.Add('Function App -> Storage: Blob Data Owner, Queue Contributor, Table Contributor') }
    if ($hasKV) { $null = $rbacDetails.Add('App Service + Function App -> Key Vault: Secrets User') }
    $null = $rbacDetails.Add('App Service + Function App -> App Insights: Monitoring Metrics Publisher')
    $null = $directives.Add(@{
        Id       = 'RBAC'
        Priority = 'MANDATORY'
        Rule     = 'Every MI->resource data plane relationship needs a roleAssignment ARM template.'
        Details  = $rbacDetails -join '; '
    })

    # DIRECTIVE 4: Shell Extensions
    $shellDetails = "Use provided extension identity ($IdentityResourceId). Always az account set after az login --identity."
    $hasSQL = $BackingServices | Where-Object { $_.Type -in @('SQL', 'PostgreSQL') }
    if ($hasSQL) { $shellDetails += ' Use mssql-tools18 for SQL operations, NOT go-sqlcmd.' }
    $null = $directives.Add(@{
        Id       = 'SHELL_EXTENSIONS'
        Priority = 'MANDATORY'
        Rule     = $shellDetails
        Details  = 'Shell extensions run in ACI. Use ARM for resource creation; shell ext only for app deploy, slot swaps, SQL data plane.'
    })

    # DIRECTIVE 5: Resource Creation
    $null = $directives.Add(@{
        Id       = 'RESOURCE_CREATION'
        Priority = 'MANDATORY'
        Rule     = 'Use ARM templates for resource creation. Shell extensions only for app code deploy, slot swaps, SQL data plane.'
        Details  = 'Shell extensions run in ACI outside VNet and are blocked by network firewalls. ARM uses control plane.'
    })

    # DIRECTIVE 6: Migrations
    $hasMigrations = $BackingServices | Where-Object { $_.Type -in @('SQLMigrations', 'EFMigrations') }
    if ($hasMigrations) {
        $migInfo = $hasMigrations | Select-Object -First 1
        $rollbackPattern = if ($migInfo.RollbackPattern) { $migInfo.RollbackPattern } else { 'rollback-*' }
        $null = $directives.Add(@{
            Id       = 'MIGRATIONS'
            Priority = 'MANDATORY'
            Rule     = "Run only forward migrations. Exclude files matching '$rollbackPattern'."
            Details  = "Forward: $($migInfo.ForwardCount ?? 'unknown') files. Verify results with SELECT after applying."
        })
    }

    # DIRECTIVE 7: Dependencies
    $null = $directives.Add(@{
        Id       = 'DEPENDENCIES'
        Priority = 'MANDATORY'
        Rule     = 'Deploy data stores BEFORE compute. Compute without its data layer is a broken deployment.'
        Details  = 'Order: Foundation -> Network -> Platform Services -> Compute -> RBAC -> Data Config -> App Deploy'
    })

    return @($directives)
}

function Resolve-ExtensionIdentity {
    <#
    .SYNOPSIS Discovers the managed identity for EV2 shell extensions (WI-2).
    .DESCRIPTION
        Queries the EV2 service connection via az devops to find its managed identity,
        then resolves the UAMI resource ID. Returns identity details or $null.
    .PARAMETER Ev2ServiceConnectionName  Name of the EV2 service connection.
    .PARAMETER AdoOrgUrl  Azure DevOps organization URL.
    .PARAMETER AdoProject  Azure DevOps project name.
    .OUTPUTS PSCustomObject with ResourceId, ClientId, Name, Source, WARNING, or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ev2ServiceConnectionName,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    # Query service connection for the identity
    $scListResult = $null
    try {
        $scListResult = Invoke-AzCommand 'devops', 'service-endpoint', 'list',
            '--org', $AdoOrgUrl,
            '--project', $AdoProject,
            '--query', "[?name=='$Ev2ServiceConnectionName']", '-o', 'json' -TimeoutSeconds 30
    } catch { return $null }

    $scClientId = $null
    if ($scListResult -and $scListResult.ExitCode -eq 0 -and $scListResult.Output -and $scListResult.Output -ne '[]') {
        try {
            $scEndpoints = @($scListResult.Output | ConvertFrom-Json)
            if ($scEndpoints.Count -gt 0 -and
                $scEndpoints[0].PSObject.Properties['authorization'] -and
                $scEndpoints[0].authorization.PSObject.Properties['parameters'] -and
                $scEndpoints[0].authorization.parameters.PSObject.Properties['serviceprincipalid']) {
                $scClientId = $scEndpoints[0].authorization.parameters.serviceprincipalid
            }
        } catch { Write-Warning "Failed to parse EV2 SC endpoint response: $_" }
    }

    if (-not $scClientId) { return $null }

    # Resolve the UAMI resource ID from the client ID
    $uamiResult = $null
    try {
        $uamiResult = Invoke-AzCommand 'identity', 'list',
            '--query', "[?clientId=='$scClientId']", '-o', 'json' -TimeoutSeconds 30
    } catch { return $null }

    if ($uamiResult -and $uamiResult.ExitCode -eq 0 -and $uamiResult.Output -and $uamiResult.Output -ne '[]') {
        try {
            $uamiList = @($uamiResult.Output | ConvertFrom-Json)
            if ($uamiList.Count -gt 0) {
                return [PSCustomObject]@{
                    ResourceId = $uamiList[0].id
                    ClientId   = $scClientId
                    Name       = $uamiList[0].name
                    Source     = "EV2 service connection ($Ev2ServiceConnectionName)"
                    WARNING    = $null
                }
            }
        } catch { Write-Warning "Failed to parse UAMI list response: $_" }
    }

    return $null
}


function Get-Ev2HandoverData {
    <#
    .SYNOPSIS Collects all fields needed by ev2-demo-agent for EV2 artifact generation.
    .DESCRIPTION
        Auto-resolves as many fields as possible from workspace metadata and config.
        Returns a structured object with Resolved fields, Missing field names, and
        a pre-built HandoverPrompt for the user to send to /ev2.
    .PARAMETER WorkspacePath   Root of the workspace.
    .PARAMETER TargetEnvironment  Target deployment environment (POC, DEV, Test, UAT, Prod).
    .PARAMETER ProjectType     Project type: 'prototype' or 'businessUse'. Determines tenant and subscription.
    .PARAMETER ServiceName     Override for service name (if already known from workspace analysis).
    .PARAMETER ServiceShortName Override for short name.
    .PARAMETER ServiceGroupName Override for service group name.
    .PARAMETER Regions         Override for regions (comma-separated string).
    .PARAMETER Components      Array of module objects from workspace-manifest.json (after user selection).
    .PARAMETER BicepPath       Relative path to the Bicep directory (default: not set). E.g. 'infra'.
    .PARAMETER BicepValidated  Boolean. When -BicepPath is set, this must be $true or the handover is blocked.
    .OUTPUTS PSCustomObject with Resolved, Missing, HandoverPrompt, Blocked, BlockReason.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PWD.Path,
        [Parameter(Mandatory)]
        [ValidateSet('POC','DEV','Test','UAT','Prod')]
        [string]$TargetEnvironment,
        [ValidateSet('prototype','businessUse')]
        [string]$ProjectType = 'businessUse',
        [string]$ServiceName,
        [string]$ServiceShortName,
        [string]$ServiceGroupName,
        [string]$Regions,
        [PSCustomObject[]]$Components,
        [string]$BicepPath,
        [switch]$BicepValidated
    )

    $cfg = Get-DeployConfig
    $resolved = @{}
    $missing = [System.Collections.ArrayList]::new()

    # ── Service Tree ID (REQUIRED — never ask) ──
    $esPath = Join-Path -Path $WorkspacePath -ChildPath 'es-metadata.yml'
    if (Test-Path $esPath) {
        $esContent = Get-Content $esPath -Raw
        if ($esContent -match 'service:\s*([0-9a-fA-F-]{36})') {
            $resolved['ServiceTreeId'] = $Matches[1]
        } else {
            return [PSCustomObject]@{
                Resolved       = $resolved
                Missing        = @()
                HandoverPrompt = ''
                Blocked        = $true
                BlockReason    = 'es-metadata.yml exists but does not contain a valid Service Tree ID (GUID under providers[0].metadata.accountableOwners.service).'
            }
        }
    } else {
        return [PSCustomObject]@{
            Resolved       = $resolved
            Missing        = @()
            HandoverPrompt = ''
            Blocked        = $true
            BlockReason    = 'es-metadata.yml not found. Register your service in Service Tree first, then add es-metadata.yml to the repo root.'
        }
    }

    # ── Tenant (default for projectType — first in projectTypes.<type>.tenants) ──
    $ptTenantRaw = if ($cfg.PSObject.Properties['projectTypes'] -and $cfg.projectTypes.PSObject.Properties[$ProjectType] -and
                     $cfg.projectTypes.$ProjectType.PSObject.Properties['tenants']) { $cfg.projectTypes.$ProjectType.tenants } else { $null }
    [array]$ptTenants = @($ptTenantRaw)
    $ev2TenantKey = if ($ptTenants.Count -gt 0 -and $ptTenants[0]) { $ptTenants[0] } else { 'corp' }
    $resolved['Tenant'] = Get-TenantDisplayName -TenantKey $ev2TenantKey

    # ── Subscription ID (from tenants.<tenantKey>.subscriptions.default) ──
    $tenantObj = $cfg.tenants.$ev2TenantKey
    if ($tenantObj -and $tenantObj.PSObject.Properties['subscriptions'] -and
        $tenantObj.subscriptions.PSObject.Properties['default']) {
        $resolved['SubscriptionId'] = $tenantObj.subscriptions.default
    } else {
        $null = $missing.Add('SubscriptionId')
    }

    # ── Tenant ID (G1-01: only emit if non-empty) ──
    if ($tenantObj -and $tenantObj.PSObject.Properties['id'] -and $tenantObj.id) {
        $resolved['TenantId'] = $tenantObj.id
    } else {
        $null = $missing.Add('TenantId')
    }

    # ── Environments ──
    $ev2Env = if ($cfg.PSObject.Properties['ev2'] -and $cfg.ev2.PSObject.Properties['environmentMapping'] -and
                  $cfg.ev2.environmentMapping.PSObject.Properties[$TargetEnvironment]) {
        $cfg.ev2.environmentMapping.PSObject.Properties[$TargetEnvironment]
    } else { $null }
    if ($ev2Env) {
        $resolved['Environments'] = $ev2Env.Value
    } else {
        $resolved['Environments'] = $TargetEnvironment
    }

    # ── Project Environment ──
    $resolved['ProjectEnvironment'] = $TargetEnvironment

    # ── Owner ──
    $owner = $null
    try {
        $gitEmail = git config user.email 2>$null
        if ($gitEmail) { $owner = $gitEmail.Trim() }
    } catch { $null = $_ }
    if (-not $owner) {
        try {
            $azAccount = az account show --query user.name -o tsv 2>$null
            if ($azAccount) { $owner = $azAccount.Trim() }
        } catch { $null = $_ }
    }
    if ($owner) { $resolved['Owner'] = $owner }
    else { $resolved['Owner'] = 'unknown@microsoft.com' }

    # ── Service Name ──
    if ($ServiceName) {
        $resolved['ServiceName'] = $ServiceName
    } else {
        # Try infra/config.ps1
        $infraConfig = Join-Path -Path $WorkspacePath -ChildPath 'infra' 'config.ps1'
        if (Test-Path $infraConfig) {
            $configContent = Get-Content $infraConfig -Raw
            if ($configContent -match '\$AppName\s*=\s*[''"]([^''"]+)[''"]') {
                $resolved['ServiceName'] = $Matches[1]
            }
        }
        if (-not $resolved.ContainsKey('ServiceName')) {
            # Try package.json name
            $pkgJson = Join-Path -Path $WorkspacePath -ChildPath 'package.json'
            if (Test-Path $pkgJson) {
                try {
                    $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
                    if ($pkg.name) { $resolved['ServiceName'] = $pkg.name }
                } catch { $null = $_ }
            }
        }
        if (-not $resolved.ContainsKey('ServiceName')) {
            # Try .csproj name
            $csproj = Get-ChildItem -Path $WorkspacePath -Filter '*.csproj' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($csproj) {
                $resolved['ServiceName'] = $csproj.BaseName
            }
        }
        if (-not $resolved.ContainsKey('ServiceName')) {
            # Fallback: workspace folder name
            $resolved['ServiceName'] = (Split-Path -Path $WorkspacePath -Leaf) -replace '[^a-zA-Z0-9-]', ''
        }
    }

    # ── Service Short Name (always derived — ServiceName always resolves) ──
    if ($ServiceShortName) {
        $resolved['ServiceShortName'] = $ServiceShortName
    } else {
        $short = ($resolved['ServiceName'] -replace '[^a-zA-Z0-9]', '').ToLower()
        if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
        $resolved['ServiceShortName'] = $short
    }

    # ── Service Description ──
    $svcName = if ($resolved.ContainsKey('ServiceName')) { $resolved['ServiceName'] } else { '' }
    $resolved['ServiceDescription'] = Get-ServiceDescription -WorkspacePath $WorkspacePath -ServiceName $svcName

    # ── Service Group Name ──
    if ($ServiceGroupName) {
        $resolved['ServiceGroupName'] = $ServiceGroupName
    } elseif ($resolved.ContainsKey('ServiceName')) {
        $resolved['ServiceGroupName'] = "Microsoft.CELA.$($resolved['ServiceName'])"
    } else {
        $null = $missing.Add('ServiceGroupName')
    }

    # ── Regions (default: centralus) ──
    if ($Regions) {
        $resolved['Regions'] = $Regions
    } else {
        $infraConfig = Join-Path -Path $WorkspacePath -ChildPath 'infra' 'config.ps1'
        if (Test-Path $infraConfig) {
            $configContent = Get-Content $infraConfig -Raw
            if ($configContent -match '\$Location\s*=\s*[''"]([^''"]+)[''"]') {
                $resolved['Regions'] = $Matches[1]
            }
        }
        if (-not $resolved.ContainsKey('Regions')) {
            $resolved['Regions'] = 'centralus'
        }
    }

    # ── Region Map with short codes (G4-01 through G4-03) ──
    $regionStr = $resolved['Regions']
    $shortCodes = if ($cfg.ev2.PSObject.Properties['regionShortCodes']) { $cfg.ev2.regionShortCodes } else { $null }
    if ($shortCodes -and $shortCodes -is [PSCustomObject] -and $regionStr) {
        $regionMap = @{}
        foreach ($r in ($regionStr -split ',\s*')) {
            $r = $r.Trim()
            if (-not $r) { continue }
            if ($shortCodes.PSObject.Properties[$r]) {
                $regionMap[$r] = $shortCodes.$r
            } else {
                # G4-01: Fallback — truncate to first 3 chars
                $code = $r.Substring(0, [Math]::Min(3, $r.Length))
                Write-Warning "Region '$r' not in regionShortCodes — using truncated short code '$code'"
                $regionMap[$r] = $code
            }
        }
        $resolved['RegionMap'] = $regionMap
    }

    # ── EV2 Service Connection Name (G1-02: only emit if fully resolved) ──
    $ev2ScPattern = $cfg.ev2.serviceConnectionPattern
    if ($ev2ScPattern -and $resolved.ContainsKey('ServiceName')) {
        $scName = $ev2ScPattern `
            -replace '\{service\}', $resolved['ServiceName'] `
            -replace '\{environment\}', $TargetEnvironment
        if ($scName -notmatch '\{') {
            $resolved['Ev2ServiceConnection'] = $scName
        } else {
            $null = $missing.Add('Ev2ServiceConnection')
        }
    }

    # ── Modules (G2-01 through G2-06: enriched from Components) ──
    if ($Components -and $Components.Count -gt 0) {
        $enriched = [System.Collections.ArrayList]::new()
        foreach ($c in $Components) {
            # G2-02: Skip components missing required fields
            if (-not $c.Name -or -not $c.Path -or -not $c.AppType) {
                Write-Warning "Component missing required fields (Name/Path/AppType) — skipping: $($c | ConvertTo-Json -Compress -ErrorAction SilentlyContinue)"
                continue
            }
            $shortName = ($c.Name -replace '[^a-zA-Z0-9]', '').ToLower()
            $null = $enriched.Add([PSCustomObject]@{
                Name             = $c.Name
                Path             = $c.Path
                AppType          = $c.AppType
                AzureService     = if ($c.PSObject.Properties['TargetAzureService']) { $c.TargetAzureService } else { '' }
                SourceFile       = if ($c.PSObject.Properties['ProjectFile']) { $c.ProjectFile } else { '' }
                BuildOutputPath  = "`$(ob_outputDirectory)/$shortName"
                DeployMethod     = 'Zip deploy to staging slot → slot swap'
                NeedsStagingSlot = $true
            })
        }
        # G2-05: Warn on duplicate short names
        $shorts = @($enriched | ForEach-Object { $_.BuildOutputPath })
        if ($shorts.Count -gt 1 -and ($shorts | Select-Object -Unique).Count -ne $shorts.Count) {
            Write-Warning 'Duplicate module short names detected — build output paths may collide'
        }
        $resolved['Modules'] = @($enriched)
    }

    # ── Bicep location (G2-03, G2-04: validate Bicep exists and has resources) ──
    if ($BicepPath) {
        $bicepFile = Join-Path -Path $WorkspacePath -ChildPath $BicepPath 'main.bicep'
        if (-not (Test-Path $bicepFile)) {
            return [PSCustomObject]@{
                Resolved       = $resolved
                Missing        = @($missing)
                HandoverPrompt = ''
                Blocked        = $true
                BlockReason    = "Bicep file not found at $bicepFile. Run vibeshield-bicep first."
            }
        }
        $bicepContent = Get-Content $bicepFile -Raw -ErrorAction SilentlyContinue
        if ($bicepContent -notmatch "resource\s+\w+\s+'Microsoft\.") {
            return [PSCustomObject]@{
                Resolved       = $resolved
                Missing        = @($missing)
                HandoverPrompt = ''
                Blocked        = $true
                BlockReason    = "infra/main.bicep has no active resource declarations. Delegate to vibeshield-bicep to author infrastructure."
            }
        }
        # G7-01: Bicep validation gate — block if BicepPath is set but BicepValidated is not
        if (-not $BicepValidated) {
            return [PSCustomObject]@{
                Resolved       = $resolved
                Missing        = @($missing)
                HandoverPrompt = ''
                Blocked        = $true
                BlockReason    = "Bicep exists but has not been validated by vibeshield-bicep. Delegate to vibeshield-bicep to validate syntax, resource types, and parameter consistency before EV2 routing."
            }
        }
        $resolved['BicepPath'] = "$BicepPath/main.bicep"
    }

    # ── WI-1: Application Backing Service Discovery ──
    $backingServices = @(Get-ApplicationBackingServices -WorkspacePath $WorkspacePath)
    if ($backingServices.Count -gt 0) {
        $resolved['BackingServices'] = $backingServices
    }

    # ── WI-3: Resource Group Context ──
    $rgName = $null
    try {
        $infraConfig = Join-Path -Path $WorkspacePath -ChildPath 'infra' 'config.ps1'
        if (Test-Path $infraConfig) {
            $configContent = Get-Content $infraConfig -Raw
            if ($configContent -match '\$ResourceGroup\s*=\s*[''"]([^''"]+)[''"]') {
                $rgName = $Matches[1]
            }
        }
    } catch { $null = $_ }
    if ($rgName) {
        $rgContext = Get-ResourceGroupContext -ResourceGroupName $rgName
        $resolved['ResourceGroupContext'] = $rgContext
    }

    # ── Extension Identity (RP-2 + WI-2: resolve from EV2 SC or explicit config) ──
    $extIdCfg = if ($cfg.ev2.PSObject.Properties['extensionIdentity']) { $cfg.ev2.extensionIdentity } else { $null }
    $extIdSource = if ($extIdCfg -and $extIdCfg.PSObject.Properties['source']) { $extIdCfg.source } else { 'serviceConnection' }
    $extIdFallback = if ($extIdCfg -and $extIdCfg.PSObject.Properties['fallbackBehavior']) { $extIdCfg.fallbackBehavior } else { 'block' }

    if ($extIdSource -eq 'explicit' -and $extIdCfg.PSObject.Properties['resourceId'] -and $extIdCfg.PSObject.Properties['clientId']) {
        # Explicit identity from config
        $resolved['ExtensionIdentityResourceId'] = $extIdCfg.resourceId
        $resolved['ExtensionIdentityClientId']   = $extIdCfg.clientId
        $resolved['ExtensionIdentityName']       = ($extIdCfg.resourceId -split '/')[-1]
        $resolved['ExtensionIdentitySource']     = 'Explicit (deploy-config.json)'
    } elseif ($extIdSource -eq 'serviceConnection' -and $resolved.ContainsKey('Ev2ServiceConnection')) {
        # Discover identity via standalone Resolve-ExtensionIdentity (WI-2)
        $deployCtx = Get-DeployContext -WorkspacePath $WorkspacePath -SkipAutoDetect
        $ctxAdoOrg = if ($deployCtx.AdoOrgUrl) { $deployCtx.AdoOrgUrl } else { '' }
        $ctxAdoProj = if ($deployCtx.AdoProject) { $deployCtx.AdoProject } else { '' }
        if ($ctxAdoOrg -and $ctxAdoProj) {
            $extId = Resolve-ExtensionIdentity -Ev2ServiceConnectionName $resolved['Ev2ServiceConnection'] `
                -AdoOrgUrl $ctxAdoOrg -AdoProject $ctxAdoProj
            if ($extId) {
                $resolved['ExtensionIdentityResourceId'] = $extId.ResourceId
                $resolved['ExtensionIdentityClientId']   = $extId.ClientId
                $resolved['ExtensionIdentityName']       = $extId.Name
                $resolved['ExtensionIdentitySource']     = $extId.Source
            }
        }

        # If discovery failed and fallback is 'block', warn (only if ADO context was available)
        if (-not $resolved.ContainsKey('ExtensionIdentityResourceId') -and $extIdFallback -eq 'block' -and $ctxAdoOrg -and $ctxAdoProj) {
            Write-Warning "Could not discover extension identity from EV2 service connection '$($resolved['Ev2ServiceConnection'])'. Ensure 'az login' is active and the SC exists in ADO."
        }
    }

    # ── Deployment Architecture (G3-01, G3-02: standard EV2 pattern) ──
    $moduleCount = if ($resolved.ContainsKey('Modules')) { $resolved['Modules'].Count } else { if ($Components) { $Components.Count } else { 1 } }
    $resolved['DeploymentArchitecture'] = [PSCustomObject]@{
        RolloutSpecSplit  = if ($moduleCount -gt 1) { 'Split (RolloutSpec.Infra.json + RolloutSpec.App.json)' } else { 'Single (RolloutSpec.json)' }
        InfraMethod       = 'ARM templates via EV2 deploy action'
        AppMethod         = 'Shell extensions (zip deploy to staging slot, then slot swap)'
        ExtensionImage    = if ($cfg.ev2.PSObject.Properties['extensionImage']) { $cfg.ev2.extensionImage } else { 'adm-mariner-20-l:v8' }
        ExtensionAuth     = if ($cfg.ev2.PSObject.Properties['extensionAuth']) { $cfg.ev2.extensionAuth } else { 'User Assigned Managed Identity' }
        ExtensionIdentityResourceId = if ($resolved.ContainsKey('ExtensionIdentityResourceId')) { $resolved['ExtensionIdentityResourceId'] } else { $null }
        ExtensionIdentityClientId   = if ($resolved.ContainsKey('ExtensionIdentityClientId')) { $resolved['ExtensionIdentityClientId'] } else { $null }
        ArtifactPackaging = 'Pipeline publishes to $(ob_outputDirectory)/{module}, bundled as tar (script + zip) at ev2/ServiceGroupRoot/bin/'
    }

    # ── WI-4: Policy Directives ──
    $extIdResId = if ($resolved.ContainsKey('ExtensionIdentityResourceId')) { $resolved['ExtensionIdentityResourceId'] } else { '' }
    $policyDirectives = Get-Ev2PolicyDirectives -BackingServices ($resolved['BackingServices'] ?? @()) -IdentityResourceId $extIdResId
    $resolved['Directives'] = $policyDirectives

    # ── Build handover prompt (categorized format) ──
    $promptLines = [System.Collections.ArrayList]::new()
    $null = $promptLines.Add('@ev2 Please generate EV2 ServiceGroupRoot artifacts for my service:')
    $null = $promptLines.Add('')

    # Helper to emit a field line
    function _field([string]$label, [string]$key) {
        $val = if ($resolved.ContainsKey($key) -and $resolved[$key]) { $resolved[$key] } else { '<MISSING>' }
        $null = $promptLines.Add("- **$label**: $val")
    }

    # Service Identity
    $null = $promptLines.Add('**Service Identity:**')
    _field 'Service Name'        'ServiceName'
    _field 'Service Short Name'  'ServiceShortName'
    _field 'Service Description' 'ServiceDescription'
    _field 'Service Tree ID'     'ServiceTreeId'
    _field 'Service Group Name'  'ServiceGroupName'
    _field 'Owner'               'Owner'
    $null = $promptLines.Add('')

    # Target Environment
    $null = $promptLines.Add('**Target Environment:**')
    $tenantLine = if ($resolved.ContainsKey('Tenant')) { $resolved['Tenant'] } else { '<MISSING>' }
    if ($resolved.ContainsKey('TenantId')) { $tenantLine += " (Tenant ID: $($resolved['TenantId']))" }
    $null = $promptLines.Add("- **Tenant**: $tenantLine")
    _field 'Subscription ID'     'SubscriptionId'
    $envLine = if ($resolved.ContainsKey('Environments')) { $resolved['Environments'] } else { '<MISSING>' }
    if ($resolved.ContainsKey('ProjectEnvironment')) { $envLine += " (Project Environment: $($resolved['ProjectEnvironment']))" }
    $null = $promptLines.Add("- **EV2 Environment**: $envLine")
    # Regions — use RegionMap if available
    if ($resolved.ContainsKey('RegionMap')) {
        $mapStr = ($resolved['RegionMap'].GetEnumerator() | ForEach-Object { "`"$($_.Key)`": `"$($_.Value)`"" }) -join ', '
        $null = $promptLines.Add("- **Regions**: { $mapStr }")
    } else {
        _field 'Regions' 'Regions'
    }
    _field 'EV2 Service Connection' 'Ev2ServiceConnection'
    $null = $promptLines.Add('')

    # Deployable Modules (only if Components were provided)
    if ($resolved.ContainsKey('Modules') -and $resolved['Modules'].Count -gt 0) {
        $null = $promptLines.Add('**Selected Modules for Deployment (only these — do NOT add others):**')
        $null = $promptLines.Add('| Module | Source Path | App Type | Azure Service | Requires Infra | Build Output | Deploy Method |')
        $null = $promptLines.Add('|--------|-----------|----------|---------------|---------------|-------------|---------------|')
        foreach ($m in $resolved['Modules']) {
            $src = if ($m.SourceFile) { $m.SourceFile } else { $m.Path }
            $infraFlag = if ($m.PSObject.Properties['RequiresInfrastructure'] -and $m.RequiresInfrastructure) { 'Yes' } else { 'No' }
            $null = $promptLines.Add("| $($m.Name) | $src | $($m.AppType) | $($m.AzureService) | $infraFlag | $($m.BuildOutputPath) | $($m.DeployMethod) |")
        }
        $null = $promptLines.Add('')
    }

    # Infrastructure (only if BicepPath was provided)
    if ($resolved.ContainsKey('BicepPath')) {
        $null = $promptLines.Add('**Infrastructure:**')
        $null = $promptLines.Add("- Bicep source: $($resolved['BicepPath']) (authored by vibeshield-bicep — read this file for the full resource graph)")
        $paramFile = ($resolved['BicepPath'] -replace '\.bicep$', '.bicepparam')
        $null = $promptLines.Add("- Parameter file: $paramFile")
        $null = $promptLines.Add('')
    }

    # Deployment Architecture
    if ($resolved.ContainsKey('DeploymentArchitecture')) {
        $da = $resolved['DeploymentArchitecture']
        $null = $promptLines.Add('**Deployment Architecture:**')
        $null = $promptLines.Add("- RolloutSpec: $($da.RolloutSpecSplit)")
        $null = $promptLines.Add("- Infra method: $($da.InfraMethod)")
        $null = $promptLines.Add("- App method: $($da.AppMethod)")
        $null = $promptLines.Add("- Extension image: $($da.ExtensionImage)")
        $null = $promptLines.Add("- Extension auth: $($da.ExtensionAuth)")
        $null = $promptLines.Add("- Artifact packaging: $($da.ArtifactPackaging)")
    }

    # Extension Identity — explicit block to prevent EV2 agent from inventing one
    if ($resolved.ContainsKey('ExtensionIdentityResourceId')) {
        $null = $promptLines.Add('')
        $null = $promptLines.Add('**Extension Identity (MUST USE — do NOT create a new managed identity):**')
        $null = $promptLines.Add("- **Identity Name**: $($resolved['ExtensionIdentityName'])")
        $null = $promptLines.Add("- **Resource ID**: $($resolved['ExtensionIdentityResourceId'])")
        $null = $promptLines.Add("- **Client ID**: $($resolved['ExtensionIdentityClientId'])")
        $null = $promptLines.Add("- **Source**: $($resolved['ExtensionIdentitySource'])")
        $null = $promptLines.Add('- All shell extensions MUST reference this identity in their parameters.')
        $null = $promptLines.Add('- Do NOT create ExtensionIdentityServiceResourceDefinition or ExtensionRbacServiceResourceDefinition in ServiceModel.json.')
        $null = $promptLines.Add('- Do NOT generate ARM templates under Templates/identity/ for extension identities.')
    }

    # Complete Infrastructure Requirements — the EV2 agent's bill of materials
    $null = $promptLines.Add('')
    $null = $promptLines.Add('**COMPLETE INFRASTRUCTURE REQUIREMENTS (generate ARM templates for ALL of the following):**')
    $null = $promptLines.Add('')

    # A. Compute — from modules
    $null = $promptLines.Add('**A. Compute Resources (one per module):**')
    if ($resolved.ContainsKey('Modules') -and $resolved['Modules'].Count -gt 0) {
        foreach ($m in $resolved['Modules']) {
            if (-not $m.PSObject.Properties['RequiresInfrastructure'] -or -not $m.RequiresInfrastructure) { continue }
            $null = $promptLines.Add("- $($m.Name): $($m.AzureService) — ARM template with SystemAssigned managed identity, staging slot, app settings from Bicep")
        }
    } else {
        $null = $promptLines.Add('- (modules not yet confirmed — generate compute based on Bicep resource declarations)')
    }
    $null = $promptLines.Add('- Shared App Service Plan (`Microsoft.Web/serverfarms`) — used by all Web/Function apps')
    $null = $promptLines.Add('')

    # B. Backing Services — from workspace scan
    $null = $promptLines.Add('**B. Backing Services (data stores and platform services):**')
    $backingSvcs = if ($resolved.ContainsKey('BackingServices')) { $resolved['BackingServices'] } else { @() }
    $hasBackingSvc = $false
    foreach ($svc in $backingSvcs) {
        if ($svc.Type -in @('StorageSKU', 'SQLMigrations', 'EFMigrations')) { continue }
        $hasBackingSvc = $true
        $srcList = if ($svc.Sources) { ($svc.Sources -join ', ') } else { $svc.Source ?? 'unknown' }
        switch ($svc.Type) {
            'SQL'         { $null = $promptLines.Add("- **Azure SQL Server + Database**: Entra-only auth, SystemAssigned identity (for CREATE USER FROM EXTERNAL PROVIDER). Discovered in: $srcList") }
            'PostgreSQL'  { $null = $promptLines.Add("- **Azure Database for PostgreSQL**: Entra auth, SystemAssigned identity. Discovered in: $srcList") }
            'Storage'     { $null = $promptLines.Add("- **Storage Account**: allowSharedKeyAccess: false (identity-based). Discovered in: $srcList") }
            'BlobStorage' { $null = $promptLines.Add("- **Storage Account** (Blob): allowSharedKeyAccess: false. Discovered in: $srcList") }
            'KeyVault'    { $null = $promptLines.Add("- **Key Vault**: RBAC authorization, purge protection enabled. Discovered in: $srcList") }
            'AppInsights' { $null = $promptLines.Add("- **Application Insights** + Log Analytics Workspace. Discovered in: $srcList") }
            'CosmosDB'    { $null = $promptLines.Add("- **Cosmos DB**: Discovered in: $srcList") }
            'ServiceBus'  { $null = $promptLines.Add("- **Service Bus**: Discovered in: $srcList") }
            default       { $null = $promptLines.Add("- **$($svc.Type)**: Discovered in: $srcList") }
        }
    }
    if (-not $hasBackingSvc) {
        $null = $promptLines.Add('- (no backing services discovered — check Bicep for resource declarations)')
    }
    # Storage SKU
    $skuEntry = $backingSvcs | Where-Object { $_.Type -eq 'StorageSKU' } | Select-Object -First 1
    if ($skuEntry) { $null = $promptLines.Add("- Storage SKU override: **$($skuEntry.Value)** (from spec)") }
    $null = $promptLines.Add('')

    # C. Security — always required
    $null = $promptLines.Add('**C. Security & Networking (MANDATORY for every deployment):**')
    $null = $promptLines.Add('- **Managed Identity**: Every resource that supports it MUST have `"identity": { "type": "SystemAssigned" }`. No exceptions.')
    $null = $promptLines.Add('- **RBAC Assignments**: One roleAssignment ARM template per managed-identity-to-resource relationship:')
    if ($hasBackingSvc) {
        $hasStorageSvc = $backingSvcs | Where-Object { $_.Type -in @('Storage', 'BlobStorage') }
        $hasKvSvc = $backingSvcs | Where-Object { $_.Type -eq 'KeyVault' }
        if ($hasStorageSvc) {
            $null = $promptLines.Add('  - Function App MI -> Storage: `Storage Blob Data Owner`, `Storage Queue Data Contributor`, `Storage Table Data Contributor`')
        }
        if ($hasKvSvc) {
            $null = $promptLines.Add('  - App Service MI + Function App MI -> Key Vault: `Key Vault Secrets User`')
        }
        $null = $promptLines.Add('  - App Service MI + Function App MI -> App Insights: `Monitoring Metrics Publisher`')
    }
    $null = $promptLines.Add('- **VNet + Private Endpoints**: If any resource has `defaultAction: Deny`, deploy VNet, subnets, NSGs, and Private Endpoints in the SAME rollout.')
    $null = $promptLines.Add('- **Diagnostic Settings**: Enable diagnostic logging to Log Analytics for all resources.')
    $null = $promptLines.Add('')

    # D. Deployment Order
    $null = $promptLines.Add('**D. Deployment Order (orchestrated steps in RolloutSpec):**')
    $null = $promptLines.Add('1. Foundation: VNet, subnets, NSGs, Log Analytics')
    $null = $promptLines.Add('2. Platform Services: Storage, Key Vault, SQL Server + Database, App Insights')
    $null = $promptLines.Add('3. Private Endpoints: PE for each firewalled resource')
    $null = $promptLines.Add('4. Compute: App Service Plan, App Service, Function App (with staging slots)')
    $null = $promptLines.Add('5. RBAC: All role assignments (after both compute and platform services exist)')
    $null = $promptLines.Add('6. Data Configuration: Blob containers (via ARM, NOT shell extension), SQL schema migrations')
    $null = $promptLines.Add('7. App Deploy: Shell extension zip deploy to staging slot')
    $null = $promptLines.Add('8. Slot Swap: Shell extension swap staging to production')
    $null = $promptLines.Add('')
    $null = $promptLines.Add('IMPORTANT: Do NOT skip any category. A deployment missing its data layer, security layer, or networking layer is a broken deployment.')

    # Prerequisites — explicit instructions for the EV2 agent
    $null = $promptLines.Add('')
    $null = $promptLines.Add('**Prerequisites (MUST complete before pipeline trigger):**')
    $subId = if ($resolved.ContainsKey('SubscriptionId')) { $resolved['SubscriptionId'] } else { '<SUBSCRIPTION_ID>' }
    $null = $promptLines.Add("1. Register subscription ``$subId`` with EV2 (``ev2 subscription register --id $subId``)")
    $null = $promptLines.Add('2. Include staging slot ARM resources (`Microsoft.Web/sites/slots`) for all modules with NeedsStagingSlot: true, with mirrored app settings')
    $null = $promptLines.Add('3. Include Storage RBAC role assignments (`Storage Blob Data Owner` + `Storage Queue Data Contributor`) for all Functions modules using managed identity auth')
    if ($ProjectType -eq 'businessUse' -and $TargetEnvironment -in @('UAT','Prod')) {
        $null = $promptLines.Add('4. Include VNET subnet integration (`subnetIds`) for ACI shell extensions — SFI compliance required for businessUse uat/prod')
    } else {
        $null = $promptLines.Add('4. [Optional] VNET subnet integration for ACI shell extensions — recommended for SFI compliance but not blocking for poc/dev')
    }

    # WI-6: Required Backing Services (discovered by workspace scan)
    if ($resolved.ContainsKey('BackingServices') -and $resolved['BackingServices'].Count -gt 0) {
        $null = $promptLines.Add('')
        $null = $promptLines.Add('**Required Backing Services (discovered by VSD — every service below MUST have a corresponding ARM template):**')
        foreach ($svc in $resolved['BackingServices']) {
            if ($svc.Type -in @('StorageSKU', 'SQLMigrations', 'EFMigrations')) { continue }
            $srcList = if ($svc.Sources) { ($svc.Sources -join ', ') } else { $svc.Source }
            $null = $promptLines.Add("- **$($svc.Type)** — discovered in: $srcList")
        }
        # Surface storage SKU if found
        $skuEntry = $resolved['BackingServices'] | Where-Object { $_.Type -eq 'StorageSKU' }
        if ($skuEntry) { $null = $promptLines.Add("- **Storage SKU**: $($skuEntry.Value) (from spec)") }
        # Surface migration info
        $migEntry = $resolved['BackingServices'] | Where-Object { $_.Type -in @('SQLMigrations', 'EFMigrations') }
        if ($migEntry) {
            $mig = $migEntry | Select-Object -First 1
            $null = $promptLines.Add("- **Migrations**: $($mig.ForwardCount ?? $mig.MigrationCount) forward files in $($mig.Source). Exclude rollback files matching '$($mig.RollbackPattern ?? 'rollback-*')'.")
        }
        $null = $promptLines.Add('')
        $null = $promptLines.Add('IMPORTANT: If any backing service above is missing from the generated ARM templates, STOP and report the gap. Do NOT proceed with a partial deployment.')
    }

    # WI-6: Environment Context
    if ($resolved.ContainsKey('ResourceGroupContext')) {
        $rgCtx = $resolved['ResourceGroupContext']
        $null = $promptLines.Add('')
        $null = $promptLines.Add('**Environment Context:**')
        $null = $promptLines.Add("- **Resource Group**: $($rgCtx.ResourceGroupName)")
        if ($rgCtx.InferredLocation) {
            $null = $promptLines.Add("- **Inferred Location**: $($rgCtx.InferredLocation) (from RG name)")
        }
        if ($rgCtx.WARNING) {
            $null = $promptLines.Add("- **WARNING**: $($rgCtx.WARNING)")
        }
    }

    # WI-6: Mandatory Directives
    if ($resolved.ContainsKey('Directives') -and $resolved['Directives'].Count -gt 0) {
        $null = $promptLines.Add('')
        $null = $promptLines.Add('**MANDATORY DIRECTIVES (non-negotiable — implement ALL of them):**')
        $null = $promptLines.Add('')
        foreach ($d in $resolved['Directives']) {
            $null = $promptLines.Add("**$($d.Id)** [$($d.Priority)]: $($d.Rule)")
            if ($d.Details) { $null = $promptLines.Add("  Details: $($d.Details)") }
        }
    }

    # G6-01: Check for critical <MISSING> fields
    $promptStr = $promptLines -join "`n"
    if ($promptStr -match '<MISSING>') {
        Write-Warning 'Handover prompt contains unresolved fields (<MISSING>)'
    }
    # G6-02: Prompt length sanity
    if ($promptStr.Length -gt 10000) {
        Write-Warning "Handover prompt exceeds 10K chars ($($promptStr.Length)) — consider reducing module detail"
    }

    return [PSCustomObject]@{
        Resolved       = $resolved
        Missing        = @($missing)
        HandoverPrompt = $promptStr
        Blocked        = $false
        BlockReason    = ''
    }
}

function Test-Ev2ModuleCoverage {
    <#
    .SYNOPSIS Verifies that EV2 artifacts cover all selected modules (IP-3).
    .DESCRIPTION
        Parses ServiceModel.json and RolloutSpec*.json to check that every module
        with requiresInfrastructure=true has a matching service resource definition,
        shell extension deploy script, and orchestrated rollout step.
    .PARAMETER WorkspacePath  Workspace root.
    .PARAMETER Modules        Array of module objects from workspace manifest (confirmed modules).
    .OUTPUTS PSCustomObject with Pass (bool), MissingModules (array), Details (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][PSCustomObject[]]$Modules
    )

    $cfg = Get-DeployConfig
    $sgRoot = Join-Path -Path $WorkspacePath -ChildPath ($cfg.ev2.artifactRoot ?? 'ev2/ServiceGroupRoot')
    $missingModules = [System.Collections.ArrayList]::new()
    $details = [System.Collections.ArrayList]::new()

    # Parse ServiceModel.json
    $smPath = Join-Path -Path $sgRoot -ChildPath 'ServiceModel.json'
    $serviceModel = $null
    if (Test-Path $smPath) {
        try { $serviceModel = Get-Content $smPath -Raw | ConvertFrom-Json } catch { $null = $_ }
    }
    if (-not $serviceModel) {
        return [PSCustomObject]@{
            Pass           = $false
            MissingModules = @($Modules | Where-Object { $_.requiresInfrastructure } | ForEach-Object { $_.path })
            Details        = 'ServiceModel.json not found or unparseable'
        }
    }

    # Get all service resource definition names
    $srdNames = @()
    if ($serviceModel.PSObject.Properties['serviceResourceGroupDefinitions']) {
        foreach ($srgd in $serviceModel.serviceResourceGroupDefinitions) {
            if ($srgd.PSObject.Properties['serviceResourceDefinitions']) {
                $srdNames += @($srgd.serviceResourceDefinitions | ForEach-Object { $_.name })
            }
        }
    }
    $srdNamesLower = @($srdNames | ForEach-Object { $_.ToLower() })

    # Check bin/ directory for shell extension scripts
    $binDir = Join-Path -Path $sgRoot -ChildPath 'bin'
    $binFiles = @()
    if (Test-Path $binDir) {
        $binFiles = @(Get-ChildItem -Path $binDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToLower() })
    }

    foreach ($mod in $Modules) {
        if (-not $mod.requiresInfrastructure) { continue }

        $modName = ($mod.path -split '[/\\]' | Select-Object -Last 1) -replace '[^a-zA-Z0-9]', ''
        $modNameLower = $modName.ToLower()
        $issues = @()

        # Check 1: ServiceModel has a matching serviceResourceDefinition
        $hasSrd = $srdNamesLower | Where-Object { $_ -match $modNameLower -or $modNameLower -match $_ }
        if (-not $hasSrd) {
            $issues += "No serviceResourceDefinition matching '$modName' in ServiceModel.json"
        }

        # Check 2: Deploy script exists in bin/
        $hasDeployScript = $binFiles | Where-Object { $_ -match "deploy.*$modNameLower" -or $_ -match "$modNameLower.*deploy" }
        if (-not $hasDeployScript) {
            $issues += "No deploy script for '$modName' in bin/"
        }

        if ($issues.Count -gt 0) {
            $null = $missingModules.Add($mod.path)
            $null = $details.Add("$($mod.path): $($issues -join '; ')")
        }
    }

    return [PSCustomObject]@{
        Pass           = ($missingModules.Count -eq 0)
        MissingModules = @($missingModules)
        Details        = if ($details.Count -gt 0) { $details -join "`n" } else { 'All modules covered' }
    }
}

function Test-Ev2ArtifactsCompleteness {
    <#
    .SYNOPSIS Deep validation of EV2 artifacts against handover data (WI-8).
    .DESCRIPTION
        Validates ARM templates for identity blocks, network consistency,
        backing service cross-reference, and shell extension identity usage.
        Extends Test-Ev2ModuleCoverage with content-level checks.
    .PARAMETER WorkspacePath   Workspace root.
    .PARAMETER BackingServices  Output from Get-ApplicationBackingServices.
    .PARAMETER ExtensionIdentityResourceId  Expected extension identity resource ID.
    .OUTPUTS PSCustomObject with Pass (bool), Errors (array of strings).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [array]$BackingServices = @(),
        [string]$ExtensionIdentityResourceId = ''
    )

    $cfg = Get-DeployConfig
    $sgRoot = Join-Path -Path $WorkspacePath -ChildPath ($cfg.ev2.artifactRoot ?? 'ev2/ServiceGroupRoot')
    $errors = [System.Collections.ArrayList]::new()

    if (-not (Test-Path $sgRoot)) {
        return [PSCustomObject]@{ Pass = $false; Errors = @('ServiceGroupRoot directory not found') }
    }

    # Parse ServiceModel.json for SRD names
    $smPath = Join-Path -Path $sgRoot -ChildPath 'ServiceModel.json'
    $srdNames = @()
    if (Test-Path $smPath) {
        try {
            $sm = Get-Content $smPath -Raw | ConvertFrom-Json
            if ($sm.PSObject.Properties['serviceResourceGroupDefinitions']) {
                foreach ($srgd in $sm.serviceResourceGroupDefinitions) {
                    if ($srgd.PSObject.Properties['serviceResourceDefinitions']) {
                        $srdNames += @($srgd.serviceResourceDefinitions | ForEach-Object { $_.name })
                    }
                }
            }
        } catch { $null = $errors.Add("Failed to parse ServiceModel.json: $_") }
    }
    $srdNamesJoined = $srdNames -join ' '

    # Check 1: Every required backing service has a matching SRD
    $svcTypeMap = @{
        'SQL'         = 'Sql|Database'
        'PostgreSQL'  = 'Postgres|Database'
        'Storage'     = 'Storage'
        'BlobStorage' = 'Storage'
        'KeyVault'    = 'KeyVault|Vault'
        'AppInsights' = 'Insights|AppInsights'
        'CosmosDB'    = 'Cosmos'
        'ServiceBus'  = 'ServiceBus'
    }
    foreach ($svc in $BackingServices) {
        if ($svc.Type -in @('StorageSKU', 'SQLMigrations', 'EFMigrations')) { continue }
        $pattern = $svcTypeMap[$svc.Type]
        if ($pattern -and $srdNamesJoined -notmatch $pattern) {
            $null = $errors.Add("MISSING_SERVICE: No ARM template for required '$($svc.Type)' (discovered in: $($svc.Sources -join ', '))")
        }
    }

    # Check 2: Identity blocks on ARM templates
    $templatesDir = Join-Path -Path $sgRoot -ChildPath 'Templates'
    if (Test-Path $templatesDir) {
        $armFiles = Get-ChildItem $templatesDir -Recurse -Filter '*.Template.json' -ErrorAction SilentlyContinue
        foreach ($f in $armFiles) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            $supportsIdentity = $content -match 'Microsoft\.(Web/sites|Sql/servers|Storage/storageAccounts|KeyVault/vaults|App/containerApps)'
            $hasIdentity = $content -match '"identity"'
            if ($supportsIdentity -and -not $hasIdentity) {
                $null = $errors.Add("MISSING_IDENTITY: $($f.Name) supports managed identity but has no identity block")
            }
        }
    }

    # Check 3: Network consistency — defaultAction: Deny without PE
    if (Test-Path $templatesDir) {
        $hasFirewall = $false
        $armFiles = Get-ChildItem $templatesDir -Recurse -Filter '*.Template.json' -ErrorAction SilentlyContinue
        foreach ($f in $armFiles) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '"defaultAction":\s*"Deny"') { $hasFirewall = $true; break }
        }
        if ($hasFirewall) {
            $hasPE = $srdNamesJoined -match 'PrivateEndpoint|Pe.*Definition'
            $hasVNet = $srdNamesJoined -match 'Vnet|VirtualNetwork'
            if (-not $hasPE -and -not $hasVNet) {
                $null = $errors.Add("NETWORK_GAP: ARM templates have defaultAction: Deny but no Private Endpoint or VNet SRD found")
            }
        }
    }

    # Check 4: Shell extension identity — should reference the provided identity
    if ($ExtensionIdentityResourceId) {
        $extParamsDir = Join-Path -Path $sgRoot -ChildPath 'Parameters'
        if (Test-Path $extParamsDir) {
            $extFiles = Get-ChildItem $extParamsDir -Recurse -Filter '*.Parameters.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'extension|deploy|swap' }
            foreach ($ef in $extFiles) {
                $content = Get-Content $ef.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match 'userAssignedIdentities|extensionIdentityResourceId') {
                    $expectedName = ($ExtensionIdentityResourceId -split '/')[-1]
                    if ($content -notmatch [regex]::Escape($expectedName) -and $content -notmatch '__EXTENSION_IDENTITY_RESOURCE_ID__') {
                        $null = $errors.Add("WRONG_IDENTITY: $($ef.Name) references a different identity than the provided extension identity ($expectedName)")
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        Pass   = ($errors.Count -eq 0)
        Errors = @($errors)
    }
}

function Test-Ev2ServiceNameConsistency {
    <#
    .SYNOPSIS Validates that all EV2 artifacts use the project-derived service name (G5-08).
    .DESCRIPTION
        Scans ServiceModel.json, ServiceSpecification.json, RolloutSpec*.json,
        parameter files (Microsoft.CELA.*.json), and pipeline YAML for the expected
        ServiceName / ServiceGroupName. Returns a result object with Pass/Fail and
        per-file mismatch details.
    .PARAMETER WorkspacePath      Workspace root.
    .PARAMETER ServiceName        Expected service name (from Get-Ev2HandoverData).
    .PARAMETER ServiceGroupName   Expected service group (e.g., Microsoft.CELA.{ServiceName}).
    .PARAMETER PipelineYamlPath   Optional relative path to pipeline YAML to check ev2ServiceConnection variable.
    .PARAMETER TargetEnvironment  Optional target environment for SC pattern validation.
    .OUTPUTS PSCustomObject with Pass (bool), Mismatches (array of {File, Field, Expected, Found}).
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PWD.Path,
        [Parameter(Mandatory)]
        [string]$ServiceName,
        [string]$ServiceGroupName,
        [string]$PipelineYamlPath,
        [string]$TargetEnvironment
    )

    if (-not $ServiceGroupName) {
        $ServiceGroupName = "Microsoft.CELA.$ServiceName"
    }

    $mismatches = [System.Collections.ArrayList]::new()
    $sgrRoot = Join-Path -Path $WorkspacePath -ChildPath 'ev2' 'ServiceGroupRoot'

    # ── ServiceModel.json ──
    $serviceModelPath = Join-Path -Path $sgrRoot -ChildPath 'ServiceModel.json'
    if (Test-Path $serviceModelPath) {
        try {
            $sm = Get-Content $serviceModelPath -Raw | ConvertFrom-Json
            if ($sm.serviceGroup -and $sm.serviceGroup -cne $ServiceGroupName) {
                $null = $mismatches.Add([PSCustomObject]@{
                    File     = 'ev2/ServiceGroupRoot/ServiceModel.json'
                    Field    = 'serviceGroup'
                    Expected = $ServiceGroupName
                    Found    = $sm.serviceGroup
                })
            }
        } catch {
            $null = $mismatches.Add([PSCustomObject]@{
                File     = 'ev2/ServiceGroupRoot/ServiceModel.json'
                Field    = '(parse error)'
                Expected = $ServiceGroupName
                Found    = "JSON parse failed: $($_.Exception.Message)"
            })
        }
    }

    # ── ServiceSpecification.json ──
    $serviceSpecPath = Join-Path -Path $sgrRoot -ChildPath 'ServiceSpecification.json'
    if (Test-Path $serviceSpecPath) {
        try {
            $ss = Get-Content $serviceSpecPath -Raw | ConvertFrom-Json
            if ($ss.serviceGroup -and $ss.serviceGroup -cne $ServiceGroupName) {
                $null = $mismatches.Add([PSCustomObject]@{
                    File     = 'ev2/ServiceGroupRoot/ServiceSpecification.json'
                    Field    = 'serviceGroup'
                    Expected = $ServiceGroupName
                    Found    = $ss.serviceGroup
                })
            }
        } catch {
            $null = $mismatches.Add([PSCustomObject]@{
                File     = 'ev2/ServiceGroupRoot/ServiceSpecification.json'
                Field    = '(parse error)'
                Expected = $ServiceGroupName
                Found    = "JSON parse failed: $($_.Exception.Message)"
            })
        }
    }

    # ── RolloutSpec*.json — check serviceGroupScope ──
    $rolloutSpecs = Get-ChildItem -Path $sgrRoot -Filter 'RolloutSpec*.json' -ErrorAction SilentlyContinue
    foreach ($rs in $rolloutSpecs) {
        try {
            $rsContent = Get-Content $rs.FullName -Raw
            # serviceGroupScope contains the service group name in its path
            if ($rsContent -match '"serviceGroupScope"\s*:\s*"([^"]+)"') {
                $scopePath = $Matches[1]
                if ($scopePath -notmatch [regex]::Escape($ServiceGroupName)) {
                    $null = $mismatches.Add([PSCustomObject]@{
                        File     = "ev2/ServiceGroupRoot/$($rs.Name)"
                        Field    = 'serviceGroupScope'
                        Expected = "path containing $ServiceGroupName"
                        Found    = $scopePath
                    })
                }
            }
        } catch {
            $null = $mismatches.Add([PSCustomObject]@{
                File     = "ev2/ServiceGroupRoot/$($rs.Name)"
                Field    = '(parse error)'
                Expected = $ServiceGroupName
                Found    = "Parse failed: $($_.Exception.Message)"
            })
        }
    }

    # ── Parameter files (Microsoft.CELA.*.json) — filename must match ServiceGroupName ──
    $paramDir = Join-Path -Path $sgrRoot -ChildPath 'Parameters'
    if (Test-Path $paramDir) {
        $paramFiles = Get-ChildItem -Path $paramDir -Filter 'Microsoft.CELA.*.json' -ErrorAction SilentlyContinue
        foreach ($pf in $paramFiles) {
            if ($pf.Name -notmatch [regex]::Escape($ServiceGroupName)) {
                # Check if the file contains a different service group in its "service" field
                try {
                    $pfContent = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                    $pfService = $null
                    if ($pfContent.PSObject.Properties['service']) { $pfService = $pfContent.service }
                    if ($pfService -and $pfService -cne $ServiceName -and $pfService -cne $ServiceGroupName) {
                        $null = $mismatches.Add([PSCustomObject]@{
                            File     = "ev2/ServiceGroupRoot/Parameters/$($pf.Name)"
                            Field    = 'service'
                            Expected = $ServiceName
                            Found    = $pfService
                        })
                    }
                } catch { $null = $_ }
            }
        }
    }

    # ── Pipeline YAML — ev2ServiceConnection variable ──
    if ($PipelineYamlPath) {
        $yamlFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYamlPath
        if (Test-Path $yamlFullPath) {
            $yamlContent = Get-Content $yamlFullPath -Raw
            # Check ev2ServiceConnection value contains the correct service name
            if ($yamlContent -match 'ev2ServiceConnection:\s*[''"]?([^''"#\r\n]+)[''"]?') {
                $scValue = $Matches[1].Trim()
                # SC pattern: cn-ev2deploy-{ServiceName}-{env}
                if ($scValue -notmatch [regex]::Escape($ServiceName)) {
                    $null = $mismatches.Add([PSCustomObject]@{
                        File     = $PipelineYamlPath
                        Field    = 'ev2ServiceConnection'
                        Expected = "cn-ev2deploy-$ServiceName-$TargetEnvironment"
                        Found    = $scValue
                    })
                }
            }
        }
    }

    return [PSCustomObject]@{
        Pass       = ($mismatches.Count -eq 0)
        Mismatches = @($mismatches)
    }
}

