<#
.SYNOPSIS
    Deploys infrastructure to Azure.

.DESCRIPTION
    Deploys the complete infrastructure.

    Configuration values (project, location, etc.) are defined in Config.ps1.

.PARAMETER Environment
    Environment type (dev or prod). Defaults to value in Config.ps1.

.EXAMPLE
    .\Deploy.ps1
    Deploys infrastructure with default (dev) settings.

.EXAMPLE
    .\Deploy.ps1 -Environment "prod"
    Deploys infrastructure with production settings.

.NOTES
    Prerequisites:
    - Set your project name in Config.ps1 (one-time setup, max 11 characters)
    - Run Create-SecurityGroups.ps1 first (one-time setup for admin access)
    - Run subscription-configuration/Create-ResourceGroup.ps1 first (one-time setup)
    - Azure CLI must be installed and logged in (az login)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("dev", "prod")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Load shared configuration and deployment helpers
. (Join-Path $PSScriptRoot 'Config.ps1')


function Get-InfraPath {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    $path = Resolve-Path $ScriptRoot -ErrorAction SilentlyContinue
    if (-not $path) {
        Write-Host "ERROR: Cannot find infra folder. Expected at: $ScriptRoot" -ForegroundColor Red
        exit 1
    }
    return $path.Path
}

function Test-AzureLogin {
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
    return $account
}

function Test-ResourceGroupExist {
    param([Parameter(Mandatory)][string]$ResourceGroupName)
    Write-Host "Checking resource group..." -ForegroundColor Yellow
    $rgExistsJson = az group exists --name $ResourceGroupName 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $rgExistsJson) {
        Write-Host "Failed to check resource group existence." -ForegroundColor Red
        exit 1
    }
    $rgExists = $rgExistsJson | ConvertFrom-Json
    if (-not $rgExists) {
        Write-Host "Resource group '$ResourceGroupName' does not exist." -ForegroundColor Red
        Write-Host "Please run subscription-configuration/Create-ResourceGroup.ps1 first." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Resource group found: $ResourceGroupName" -ForegroundColor Green
    Write-Host ""
}

function Get-AdminGroupObjectId {
    param([string]$Environment = $script:DefaultEnvironment)
    $groupName = Get-SecurityGroupName -Suffix "aks-admins" -Environment $Environment
    Write-Host "Looking up admin group: $groupName..." -ForegroundColor Yellow

    # Use az ad group show (simpler, more reliable than list with JMESPath filter)
    $groupId = az ad group show --group $groupName --query "id" -o tsv 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to retrieve security group '$groupName'." -ForegroundColor Red
        Write-Host "  Error: $groupId" -ForegroundColor Red
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    - Group doesn't exist (run Create-SecurityGroups.ps1)" -ForegroundColor Yellow
        Write-Host "    - Azure CLI not logged in (run 'az login')" -ForegroundColor Yellow
        Write-Host "    - Insufficient permissions to read Entra ID groups" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "  Group Object ID: $groupId" -ForegroundColor Green
    Write-Host ""
    return $groupId
}
function Show-DeploymentSummary {
    Write-Host "Deploying infrastructure..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This deployment includes:" -ForegroundColor Yellow

    # TBD
}

# Apply defaults from config if not provided
if (-not $Environment) { $Environment = $script:DefaultEnvironment }
$ResourceGroupName = Get-ResourceGroupName -Environment $Environment
$infraPath = Get-InfraPath -ScriptRoot $PSScriptRoot
$mainTemplatePath = Join-Path $infraPath 'main.bicep'
$parameterFilePath = Join-Path $infraPath "parameters.$Environment.bicepparam"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Infrastructure Deployment" -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Test-AzureLogin | Out-Null
Test-ResourceGroupExist -ResourceGroupName $ResourceGroupName
Show-DeploymentSummary
Write-Host ""


$deploymentName = "$ResourceGroupName-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Build deployment parameters
$deployParams = @(
    "project=$script:Project"
)


az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $mainTemplatePath `
    --parameters $parameterFilePath `
    --parameters @deployParams `
    --name $deploymentName `
    --verbose

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "Deployment Successful!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""

    # Get deployment outputs
    $deploymentOutputs = az deployment group show `
        --resource-group $ResourceGroupName `
        --name $deploymentName `
        --query "properties.outputs" `
        --output json | ConvertFrom-Json

    if ($deploymentOutputs) {
        Write-Host "Deployment Outputs:" -ForegroundColor Cyan
        $deploymentOutputs.PSObject.Properties | ForEach-Object {
            Write-Host "  $($_.Name): $($_.Value.value)" -ForegroundColor White
        }
    }
    #Write-Host "Next Steps:" -ForegroundColor Yellow
    #Write-Host "  1. Connect to Jumpbox via Azure Portal > Bastion (Login with Azure AD)" -ForegroundColor White
    #Write-Host "  2. See Documentation/GettingStarted.md for complete setup instructions" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "Deployment Failed!" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red

    exit 1
}
