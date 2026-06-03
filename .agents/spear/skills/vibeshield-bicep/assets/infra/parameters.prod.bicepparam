// ============================================================================
// Production Environment Parameters
// ============================================================================
// Example parameters for production deployment with enhanced retention and security.
// - 365-day log retention
// - AKS with Standard_D2s_v5 nodes for production workloads
// ============================================================================

using 'main.bicep'

// Project name - required here for Bicep compile-time validation, but overridden at deployment by Config.ps1
param project = '{{REPLACE-WITH-11-CHAR-PROJECT-NAME}}' // Placeholder value - overridden by CLI from Config.ps1 ($script:Project)

param environment = 'prod'
param locationShort = 'cus'
