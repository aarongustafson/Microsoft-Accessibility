<#
.SYNOPSIS
    Creates the resource group (one-time setup) to be used for the Azure resources.


.DESCRIPTION
    This script creates the resource group that will contain all Azure resources.
    The resource group is created once and reused for daily deployments.

    Configuration values (project, location, etc.) are defined in Config.ps1.

.NOTES
    Required permissions:
    - Contributor role at subscription scope is the minimum built-in role to run this script.
      It covers Microsoft.Resources/subscriptions/resourceGroups/write,
      Microsoft.Resources/subscriptions/resourceGroups/read,
      Microsoft.Resources/deployments/write, and Microsoft.Resources/deployments/read.

    - Contributor CANNOT assign RBAC roles on the created resource group. To grant
      permissions afterward (e.g., Managed Identity access, developer role assignments),
      the caller needs Owner or User Access Administrator at the resource group or
      subscription scope, which carry Microsoft.Authorization/roleAssignments/write.

    Recommendation: Use Contributor for resource group creation, then a separate
    privileged identity (Owner or User Access Administrator) scoped appropriately
    for role assignments -- aligning with SFI least-privilege and JIT principles.

.EXAMPLE
    .\Create-ResourceGroup.ps1
    Creates the resource group using settings from Config.ps1.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Load shared configuration (single source of truth)
$configPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Config.ps1'
. $configPath

# Use values from Config.ps1
$ResourceGroupName = $script:DefaultResourceGroup
$Location = $script:Location

# Resolve infra path (parent directory of this script)
$infraPath = Resolve-Path (Split-Path $PSScriptRoot -Parent) -ErrorAction SilentlyContinue
if (-not $infraPath) {
    Write-Host "ERROR: Cannot find infra folder. Expected at: $(Split-Path $PSScriptRoot -Parent)" -ForegroundColor Red
    exit 1
}
$resourceGroupTemplatePath = Join-Path $infraPath.Path 'resourcegroup.bicep'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Resource Group Creation" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Check if logged in to Azure
Write-Host "Checking Azure login status..." -ForegroundColor Yellow
$accountJson = az account show 2>$null
if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
    Write-Host "Not logged in to Azure. Please run 'az login' first." -ForegroundColor Red
    exit 1
}
$account = $accountJson | ConvertFrom-Json

Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($account.name)" -ForegroundColor Green
Write-Host ""

# Check if resource group already exists
Write-Host "Checking if resource group exists..." -ForegroundColor Yellow
$rgExistsJson = az group exists --name $ResourceGroupName 2>$null
if ($LASTEXITCODE -ne 0 -or -not $rgExistsJson) {
    Write-Host "Failed to check resource group existence." -ForegroundColor Red
    exit 1
}
$rgExists = $rgExistsJson | ConvertFrom-Json

if ($rgExists) {
    Write-Host "Resource group '$ResourceGroupName' already exists." -ForegroundColor Yellow
    Write-Host "No action needed." -ForegroundColor Green
} else {
    Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Yellow

    az deployment sub create `
        --location $Location `
        --template-file $resourceGroupTemplatePath `
        --parameters resourceGroupName=$ResourceGroupName location=$Location `
        --name "create-rg-$(Get-Date -Format 'yyyyMMddHHmmss')"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Resource group created successfully!" -ForegroundColor Green
    } else {
        Write-Host "Failed to create resource group." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Resource Group Ready" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
