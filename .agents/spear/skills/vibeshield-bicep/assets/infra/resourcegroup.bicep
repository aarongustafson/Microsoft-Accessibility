// Subscription-scoped module to create the project resource group.
// Called by Create-ResourceGroup.ps1 as a one-time setup step.

targetScope = 'subscription'

@description('Name of the resource group to create')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Azure region for the resource group')
param location string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    createdBy: 'CELA-Vibe-Box'
  }
}

@description('Resource ID of the created resource group')
output resourceGroupId string = rg.id

@description('Name of the created resource group')
output name string = rg.name
