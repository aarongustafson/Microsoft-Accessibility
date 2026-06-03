// ============================================================================
// Main Orchestration Bicep File
// ============================================================================
// Deploys the foundational infrastructure for the project.
// Works in conjunction with Config.ps1 for centralized naming and parameter management.
// ============================================================================

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Project name for all resources (max 11 chars). Set in Config.ps1, passed by deployment scripts.')
@minLength(1)
@maxLength(11)
param project string

@description('Environment type (dev or prod)')
@allowed(['dev', 'prod'])
param environment string = 'dev'

@description('Short location code for resource naming (e.g., cus for centralus)')
param locationShort string = 'cus'


// ============================================================================
// Variables
// ============================================================================

var location string = resourceGroup().location

// Common tags for all resources
var commonTags = {
  environment: environment
  project: project
  managedBy: 'bicep'
}

// ============================================================================
// Example naming.  Keep in sync with Config.ps1.
//

// Centralized naming convention: ${resourceType}-${project}-${environment}-${location}
// Resource naming
// var logAnalyticsName = 'law-${project}-${environment}-${locationShort}'
// var hubVnetName = 'vnet-${project}-hub-${environment}-${locationShort}'
// var spokeVnetName = 'vnet-${project}-spoke-${environment}-${locationShort}'
// var bastionName = 'bas-${project}-${environment}-${locationShort}'
// var bastionPipName = 'pip-${project}-bastion-${environment}-${locationShort}'
// var jumpboxName = 'vm-${project}-jumpbox-${environment}-${locationShort}'

// // ACR name must be globally unique and alphanumeric only (no hyphens)
// var acrName = replace('acr${project}${environment}${locationShort}', '-', '')
// var acrPrivateEndpointName = 'pe-${project}-acr-${environment}-${locationShort}'

// // AKS and Application Gateway naming
// var aksName = 'aks-${project}-${environment}-${locationShort}'
// var aksIdentityName = 'uami-${project}-aks-${environment}-${locationShort}'
// var appGatewayName = 'agw-${project}-${environment}-${locationShort}'
// var appGatewayPipName = 'pip-${project}-appgw-${environment}-${locationShort}'

// // NSG naming follows standard pattern: nsg-${project}-${purpose}-${environment}-${location}
// var hubBastionNsgName = 'nsg-${project}-hub-bastion-${environment}-${locationShort}'
// var hubJumpboxNsgName = 'nsg-${project}-hub-jumpbox-${environment}-${locationShort}'
// var spokeAksNsgName = 'nsg-${project}-spoke-aks-${environment}-${locationShort}'
// var spokeAppGwNsgName = 'nsg-${project}-spoke-appgw-${environment}-${locationShort}'
// var spokePeNsgName = 'nsg-${project}-spoke-pe-${environment}-${locationShort}'
// var spokeApiServerNsgName = 'nsg-${project}-spoke-apiserver-${environment}-${locationShort}'

// // Azure Monitor Private Link Scope (AMPLS) naming
// var amplsName = 'ampls-${project}-${environment}-${locationShort}'
// var dceName = 'dce-${project}-${environment}-${locationShort}'
// var dcrPerfName = 'dcr-${project}-perf-${environment}-${locationShort}'
// var dcrSecuritySyslogName = 'dcr-${project}-security-syslog-${environment}-${locationShort}'
// var dcrAppSyslogName = 'dcr-${project}-app-syslog-${environment}-${locationShort}'
// var cpuAlertName = 'alert-${project}-cpu-high-${environment}-${locationShort}'

// // NAT Gateway naming
// var natGatewayName = 'nat-${project}-${environment}-${locationShort}'
// var natGatewayPipName = 'pip-${project}-nat-${environment}-${locationShort}'

// // Spoke NAT Gateway REMOVED - no longer needed for ACR Agent Pool
// // All dependencies are now pre-staged to ACR as OCI artifacts.
// // Cost savings: ~$32/month eliminated.
// var spokeAcrAgentPoolNsgName = 'nsg-${project}-spoke-acragentpool-${environment}-${locationShort}'
// // ACR Agent Pool name must be 3-20 chars, pattern ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$
// // Compact format uses short env codes: d=dev, p=prod (e.g., ap-nccoe-beta1dcus = 18 chars)
// var acrAgentPoolEnvShort = environment == 'prod' ? 'p' : 'd'
// var acrAgentPoolName = 'ap-${project}${acrAgentPoolEnvShort}${locationShort}'

// // Key Vault private endpoint naming (Key Vault name comes from parameter due to suffix)
// var keyVaultPrivateEndpointName = 'pe-${project}-kv-${environment}-${locationShort}'

// // ARC Workload Identity naming
// var arcIdentityName = 'uami-${project}-arc-${environment}-${locationShort}'

// // ARC Runner identity naming (for ACR builds)
// var arcRunnerIdentityName = 'id-arc-runner-${project}-${environment}-${locationShort}'

// // Jumpbox identity naming (for managed identity login in device-code-restricted tenants)
// var jumpboxIdentityName = 'id-jumpbox-${project}-${environment}-${locationShort}'

// ============================================================================
// Modules
// ============================================================================

// Example modules
// Log Analytics Workspace - No dependencies
// module logAnalytics 'modules/loganalytics.bicep' = {
//   name: 'logAnalytics'
//   params: {
//     workspaceName: logAnalyticsName
//     location: location
//     environment: environment
//     tags: commonTags
//   }
// }


// ============================================================================
// Outputs - Required for subsequent steps
// ============================================================================

// Output examples
// Log Analytics outputs
// @description('Resource ID of the Log Analytics Workspace')
// output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId

// @description('Name of the Log Analytics Workspace')
// output logAnalyticsWorkspaceName string = logAnalytics.outputs.workspaceName
