---
agent: vsd
description: "SC extraction rules — how to parse pipeline YAML for service connection references. Used by Test-ServiceConnectionExists and Get-PipelineServiceConnections in SharedHelpers.ps1."
---

# Service Connection Extraction Rules

Defines how to extract service connection names from pipeline YAML for verification.

## SC Reference Patterns

Pipeline YAML references service connections in three ways:

### 1. Literal `azureSubscription` (ARM SC)

```yaml
- task: AzureCLI@2
  inputs:
    azureSubscription: 'sc-vibe-user.name-ARM'
```

Regex: `azureSubscription:\s*['"]([^'"$]+)['"]`

### 2. Literal `ConnectedServiceName` (EV2 SC)

```yaml
- task: vsrm-ev2.ev2-rollout.ev2-rollout-task.Ev2RARollout@2
  inputs:
    ConnectedServiceName: 'cn-ev2deploy-myservice-dev'
```

Regex: `ConnectedServiceName:\s*['"]([^'"$]+)['"]`

### 3. Variable Reference `$(variableName)`

```yaml
variables:
  serviceConnection: 'sc-vibe-user.name-ARM'

stages:
- stage: Deploy
  jobs:
  - job: DeployJob
    steps:
    - task: AzureWebApp@1
      inputs:
        azureSubscription: '$(serviceConnection)'
```

Resolution: match `$(variableName)` in `azureSubscription` or `ConnectedServiceName`, then look up the variable definition in the YAML variables block.

Regex for reference: `(?:azureSubscription|ConnectedServiceName):\s*['"]?\$\((\w+)\)['"]?`
Regex for lookup: `^\s+{varName}:\s*'?([^'\r\n$]+)'?`

## SCs by InfraDeployMethod

| InfraDeployMethod | Expected SCs | Where in YAML |
|-------------------|-------------|---------------|
| **ARM** | 1: ARM SC | `azureSubscription` on `AzureCLI@2` (Provision) + deploy tasks |
| **EV2** | 2: ARM SC + EV2 SC | `azureSubscription` on deploy tasks + `ConnectedServiceName` on `Ev2RARollout@2` |

## User-Provided SC Names

Users can provide any SC name — it is NOT validated against naming patterns (`sc-vibe-*`, `cn-ev2deploy-*`). Only existence in the ADO project is verified.

## Implementation

These patterns are implemented in `Get-PipelineServiceConnections` in `SharedHelpers.ps1`. The function returns a deduplicated array of SC names extracted from the YAML content.
