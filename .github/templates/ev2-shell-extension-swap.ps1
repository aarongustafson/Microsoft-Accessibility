#!/usr/bin/env pwsh
# EV2 Shell Extension — Swap staging slot to production (PowerShell)
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
$SlotName = if ($args[1]) { $args[1] } else { 'staging' }

if (-not $AppName) { Write-Error 'Missing argument: AppName (arg 0)'; exit 1 }

Write-Host "Swapping $AppName`: $SlotName -> production in $env:AzureResourceGroupName ($env:SubscriptionId)"

az webapp deployment slot swap `
    --resource-group $env:AzureResourceGroupName `
    --name $AppName `
    --slot $SlotName `
    --target-slot 'production'

if ($LASTEXITCODE -ne 0) { Write-Error "Swap failed for $AppName"; exit 1 }

Write-Host "Swap complete: $AppName is now serving from former $SlotName"
