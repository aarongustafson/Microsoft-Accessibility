<#
.SYNOPSIS
    Shared configuration to simplify naming and generate parameter files.

.DESCRIPTION
    Central configuration file containing project settings and naming conventions.
    Dot-source this file at the beginning of other scripts:
    . (Join-Path $PSScriptRoot 'Config.ps1')

#>

Set-StrictMode -Version Latest

# =============================================================================
# Project Name - SINGLE SOURCE OF TRUTH for naming.
# =============================================================================

# All resource names derive from the Project value.
# - Passed to Bicep via deployment script Deploy.ps1
# - Max 11 characters (Azure naming constraints: ACR 50-char limit, Key Vault 24-char limit)
# - Must match AZURE_PARAMETER_DEFAULTS.project in PSRule.dev.yaml and PSRule.prod.yaml for validation
# - Change here, not in .bicepparam files or main.bicep
# - Suggestion for uniqueness: 4 chars from user alias + 7 random chars (e.g., ldat081319)
$script:Project = "{{REPLACE-WITH-11-CHAR-PROJECT-NAME}}" # e.g., ldat081319

# =============================================================================
# Project Settings
# =============================================================================
$script:Location = "centralus"
$script:LocationShort = "cus"
$script:DefaultEnvironment = "dev"

# Key Vault suffix (increment if name collision after teardown)
$script:KeyVaultSuffix = "01"

# =============================================================================
# Computed Resource Names (based on naming convention)
# Convention: ${resourceType}-${project}-${environment}-${location}
#
# Note that this is a starter template - these resources don't exist yet and
# are just examples to show how to centralize naming. Adjust as needed for your
# project, but keep consistent with Get-ResourceName function.
# =============================================================================

function Get-ResourceGroupName {
    param([string]$Environment = $script:DefaultEnvironment)
    return "rg-$script:Project-$Environment-$script:LocationShort"
}

function Get-ResourceName {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [string]$Environment = $script:DefaultEnvironment,

        [string]$Suffix = ""
    )

    $name = "$ResourceType-$script:Project"
    if ($Suffix) { $name += "-$Suffix" }
    $name += "-$Environment-$script:LocationShort"
    return $name
}
# Security group naming (Entra ID groups are tenant-scoped, no location)
function Get-SecurityGroupName {
    param(
        [Parameter(Mandatory)]
        [string]$Suffix,
        [string]$Environment = $script:DefaultEnvironment
    )
    return "sg-$script:Project-$Suffix-$Environment"
}

# Key Vault naming (includes suffix for soft-delete name collision avoidance)
function Get-KeyVaultName {
    param([string]$Environment = $script:DefaultEnvironment)
    # Key Vault has 24-char limit, must be globally unique
    # kv12345-78901-dev-cus01 = 23 chars (dev), kv12345-78901-prod-cus01 = 24 chars (prod at limit)
    return "kv$script:Project-$Environment-$script:LocationShort$script:KeyVaultSuffix"
}


# The following are some example naming functions, uncomment to use in this project.
# Sometimes a resource has to have special naming.
# Always consult the MCP servers for the latest information.

# function Get-AcrName {
#     param([string]$Environment = $script:DefaultEnvironment)
#     # ACR names can't have hyphens
#     $projectNoHyphens = $script:Project -replace '-', ''
#     return "acr$projectNoHyphens$Environment$script:LocationShort"
# }

# # ACR Agent Pool naming (3-20 chars, pattern ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$)
# # Compact format uses short env codes: d=dev, p=prod (e.g., ap-12345-678901cus = 18 chars)
# function Get-AcrAgentPoolName {
#     param([string]$Environment = $script:DefaultEnvironment)
#     $envShort = if ($Environment -eq 'prod') { 'p' } else { 'd' }
#     return "ap-$script:Project$envShort$script:LocationShort"
# }

# # ARC Runner identity naming (for Workload Identity with ACR)
# function Get-ArcRunnerIdentityName {
#     param([string]$Environment = $script:DefaultEnvironment)
#     return "id-arc-runner-$script:Project-$Environment-$script:LocationShort"
# }

# # Jumpbox identity naming (for managed identity login in device-code-restricted tenants)
# function Get-JumpboxIdentityName {
#     param([string]$Environment = $script:DefaultEnvironment)
#     return "id-jumpbox-$script:Project-$Environment-$script:LocationShort"
# }

# =============================================================================
# Default Resource Names (for dev environment)
# =============================================================================
$script:DefaultResourceGroup = Get-ResourceGroupName

# Resource type prefixes following Azure naming conventions
$script:ResourceNames = @{
    ResourceGroup       = Get-ResourceGroupName

    # Sample naming for some example resources - adjust as needed, but keep consistent with Get-ResourceName function
    # LogAnalytics        = Get-ResourceName -ResourceType "law"
    # HubVNet             = Get-ResourceName -ResourceType "vnet" -Suffix "hub"
    # SpokeVNet           = Get-ResourceName -ResourceType "vnet" -Suffix "spoke"
    # Bastion             = Get-ResourceName -ResourceType "bas"
    # BastionPip          = Get-ResourceName -ResourceType "pip" -Suffix "bastion"
    # Jumpbox             = Get-ResourceName -ResourceType "vm" -Suffix "jumpbox"
    # JumpboxNic          = Get-ResourceName -ResourceType "nic" -Suffix "jumpbox"
    # JumpboxOsDisk       = Get-ResourceName -ResourceType "osdisk" -Suffix "jumpbox"
    # Acr                 = Get-AcrName
    # AcrPrivateEndpoint  = Get-ResourceName -ResourceType "pe" -Suffix "acr"
    # Aks                 = Get-ResourceName -ResourceType "aks"
    # AppGateway          = Get-ResourceName -ResourceType "agw"
    # AppGatewayPip       = Get-ResourceName -ResourceType "pip" -Suffix "appgw"
    # # NAT Gateway for Jumpbox subnet
    # NatGateway          = Get-ResourceName -ResourceType "nat"
    # NatGatewayPip       = Get-ResourceName -ResourceType "pip" -Suffix "nat"
    # # NSGs follow standard pattern: nsg-${project}-${purpose}-${environment}-${location}
    # NsgHubBastion       = Get-ResourceName -ResourceType "nsg" -Suffix "hub-bastion"
    # NsgHubJumpbox       = Get-ResourceName -ResourceType "nsg" -Suffix "hub-jumpbox"
    # NsgSpokeAks         = Get-ResourceName -ResourceType "nsg" -Suffix "spoke-aks"
    # NsgSpokeAppGw       = Get-ResourceName -ResourceType "nsg" -Suffix "spoke-appgw"
    # NsgSpokePe          = Get-ResourceName -ResourceType "nsg" -Suffix "spoke-pe"
    # NsgSpokeApiServer   = Get-ResourceName -ResourceType "nsg" -Suffix "spoke-apiserver"
    # # ACR Agent Pool and Spoke NAT Gateway
    # NsgSpokeAcrAgentPool = Get-ResourceName -ResourceType "nsg" -Suffix "spoke-acragentpool"
    # SpokeNatGateway     = Get-ResourceName -ResourceType "nat" -Suffix "spoke"
    # SpokeNatGatewayPip  = Get-ResourceName -ResourceType "pip" -Suffix "spoke-nat"
    # AcrAgentPool        = Get-AcrAgentPoolName
    # # Security groups (Entra ID, tenant-scoped - no location)
    # SgAksAdmins         = Get-SecurityGroupName -Suffix "aks-admins"
    # # Key Vault for secrets management
    # KeyVault            = Get-KeyVaultName
    # KeyVaultPrivateEndpoint = Get-ResourceName -ResourceType "pe" -Suffix "kv"
    # # AKS user-assigned managed identity (required for custom private DNS zone)
    # AksIdentity         = Get-ResourceName -ResourceType "uami" -Suffix "aks"
    # # ARC user-assigned managed identity (for Workload Identity with Key Vault)
    # ArcIdentity         = Get-ResourceName -ResourceType "uami" -Suffix "arc"
    # # KMS key for AKS etcd secret encryption
    # KmsKey              = Get-KmsKeyName
    # # ARC Runner identity (for Workload Identity with ACR)
    # ArcRunnerIdentity   = Get-ArcRunnerIdentityName
    # # Jumpbox identity (for managed identity login in device-code-restricted tenants)
    # JumpboxIdentity     = Get-JumpboxIdentityName
}

# =============================================================================
# Export for use in scripts
# =============================================================================
Write-Verbose "Config loaded: Project=$script:Project, Location=$script:Location, DefaultRG=$script:DefaultResourceGroup"
