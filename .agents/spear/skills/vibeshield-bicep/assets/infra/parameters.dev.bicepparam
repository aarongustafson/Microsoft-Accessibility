// ============================================================================
// Development Environment Parameters
// ============================================================================
// Example parameters for daily development work with cost optimization.
// - 30-day log retention
// - ACR Premium with private endpoint for secure container images
// - AKS with Standard_B2s nodes for cost-effective development
// ============================================================================

using 'main.bicep'

// Project name - required here for Bicep compile-time validation, but overridden at deployment by Config.ps1
param project = '{{REPLACE-WITH-11-CHAR-PROJECT-NAME}}' // Placeholder value - overridden by CLI from Config.ps1 ($script:Project)

param environment = 'dev'
param locationShort = 'cus'
