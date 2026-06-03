#!/usr/bin/env pwsh
# EV2 Shell Extension — Deploy code to staging slot (PowerShell)
# This script is bundled as a tar and executed by EV2 in an ACI container (Mariner Linux with pwsh).
# EV2 injects: SubscriptionId, AzureResourceGroupName, Location, plus custom parameters.
$ErrorActionPreference = 'Stop'

# CRITICAL: Authenticate and set subscription context
az login --identity
if ($LASTEXITCODE -ne 0) { Write-Error 'Failed to login with managed identity.'; exit 1 }

az account set --subscription $env:SubscriptionId
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to set subscription to $env:SubscriptionId"; exit 1 }

Write-Host "Authenticated. Subscription: $env:SubscriptionId"

$AppName = $args[0]
$ZipPath = $args[1]
$SlotName = if ($args[2]) { $args[2] } else { 'staging' }

if (-not $AppName) { Write-Error 'Missing argument: AppName (arg 0)'; exit 1 }
if (-not $ZipPath) { Write-Error 'Missing argument: ZipPath (arg 1)'; exit 1 }

Write-Host "Deploying $ZipPath to $AppName/$SlotName in $env:AzureResourceGroupName ($env:SubscriptionId)"

az webapp deployment source config-zip `
    --resource-group $env:AzureResourceGroupName `
    --name $AppName `
    --slot $SlotName `
    --src $ZipPath `
    --timeout 300

if ($LASTEXITCODE -ne 0) { Write-Error "Deploy failed for $AppName/$SlotName"; exit 1 }

Write-Host "Deploy complete: $AppName/$SlotName"
