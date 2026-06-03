---
name: deploy-docker-image
description: 'Deploy Docker container images to Azure Container Apps. Use when: Docker deployment, container image, Dockerfile, ACR push, container registry, Docker build, containerized app, Container Apps deployment, Docker image to Azure, ACR login, container update.'
---

# Docker Image Deployment to Azure

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Dockerfile detection** | Identifies Dockerfiles in the workspace for container-based deployments |
| **ACR integration** | Configures Azure Container Registry login, build, and push pipeline tasks |
| **Container Apps deployment** | Generates Deploy stage tasks for Azure Container Apps with container image references |
| **Multi-stage Docker builds** | Supports multi-stage Dockerfile patterns for optimized image sizes |
| **Image tagging** | Configures commit-SHA-based image tagging for version traceability |

## When to Use

- Deploying an application that has a `Dockerfile`
- Building and pushing container images to Azure Container Registry (ACR)
- Deploying container images to Azure Container Apps
- Configuring the container build and deploy pipeline stages
- Troubleshooting Docker build or container deployment failures

## Hard Constraints

- Docker builds MUST use `1ES-BuildPool` with `os: windows`. The Linux build image (`1ES-BuildPool-Ubuntu`) is not yet ready.
- The target Azure service for Docker/container apps is **Azure Container Apps** (not App Service, not ACI).
- Container images MUST be pushed to **Azure Container Registry (ACR)** — no Docker Hub, GitHub Container Registry, or other external registries.
- The `Dockerfile` MUST exist in the workspace. Do not generate Dockerfiles — that is the user's responsibility. If missing, stop and ask the user to provide one.
- **Honor the existing Dockerfile as-is.** The user's Dockerfile defines the build process (dependencies, compilation, runtime setup). Do NOT modify, replace, or override it. If the Dockerfile contains multi-stage builds, custom build steps, or specific base images, respect those choices. Only flag issues listed in the Dockerfile Best Practices section below as recommendations, never as blockers.
- Never hardcode registry credentials. Use the service connection (`AzureCLI@2`) or `Docker@2` task with a service connection for ACR authentication.
- Go and Rust apps that have a `Dockerfile` follow this same container deployment pipeline.

## Pipeline Architecture

Container deployments use a two-stage pipeline:

### Build Stage

Uses `build-container.yml` (`.github/templates/build-container.yml`).

1. **Checkout** source code
2. **Docker build** — validates the Dockerfile compiles successfully (`Docker@2` with `command: build`)
3. **Publish artifact** — publishes the source (including Dockerfile) for the deploy stage

```yaml
- task: Docker@2
  displayName: 'Validate Docker build'
  inputs:
    command: 'build'
    Dockerfile: '**/Dockerfile'
    tags: '$(Build.BuildId)'
```

The build stage does NOT push the image. It only validates the Docker build succeeds.

### Deploy Stage

Uses `deploy-containerapp.yml` (`.github/templates/deploy-containerapp.yml`).

1. **Checkout** source code (for Bicep templates)
2. **Bicep provisioning** — creates/updates Azure infrastructure including ACR and Container App
3. **Docker build + push** — builds the image and pushes to ACR (`Docker@2` with `command: buildAndPush`)
4. **Container App update** — updates the Container App to use the new image

```yaml
- task: Docker@2
  displayName: 'Build and push container image'
  inputs:
    containerRegistry: '$(containerRegistryConnection)'
    repository: '$(appName)'
    command: 'buildAndPush'
    Dockerfile: '**/Dockerfile'
    tags: '$(Build.BuildId)'

- task: AzureCLI@2
  displayName: 'Update Container App'
  inputs:
    azureSubscription: '$(serviceConnection)'
    scriptType: 'bash'
    scriptLocation: 'inlineScript'
    inlineScript: |
      az containerapp update \
        --name $(appName) \
        --resource-group $(resourceGroup) \
        --image $(acrLoginServer)/$(appName):$(Build.BuildId)
```

## Pipeline Variables

Container deployments require these additional variables beyond the standard set:

| Variable | Value | Description |
|----------|-------|-------------|
| `containerRegistryConnection` | `sc-acrsandboxcuspoc-acr` | Docker registry service connection in Azure DevOps — used by `Docker@2` task for ACR authentication |
| `acrLoginServer` | ACR login server (e.g., `acrsandboxcuspoc.azurecr.io`) | ACR URL for image references in `az containerapp update`. Set from Bicep output or user input |
| `resourceGroup` | User-provided resource group | Standard variable |
| `appName` | Application/container name | Used as ACR repository name |
| `serviceConnection` | `sc-vibe-<name>-ARM` | Standard ARM service connection |

## Dockerfile Best Practices

When reviewing a user's Dockerfile before deployment, check for:

### Required

1. **Base image is pinned** — use a specific tag, not `latest` (e.g., `python:3.12-slim` not `python:latest`)
2. **Non-root user** — the container should not run as root in production
3. **EXPOSE directive** — the port the app listens on must be declared
4. **No secrets in the image** — no `ENV` with passwords, no `COPY` of `.env` files with secrets

### Recommended

1. **Multi-stage build** — reduces final image size by separating build and runtime stages
2. **`.dockerignore`** — excludes unnecessary files (node_modules, .git, __pycache__, etc.)
3. **Health check** — `HEALTHCHECK` directive for container orchestrator health probes

### Port Configuration

Azure Container Apps uses the `EXPOSE` port from the Dockerfile or the `targetPort` in Bicep config. These must match:

| Dockerfile | Bicep |
|------------|-------|
| `EXPOSE 8080` | `ingress.targetPort: 8080` |

If no port is specified, Container Apps defaults to port 80.

## Bicep Requirements

Container Apps infrastructure requires these resources (generated by `vibeshield-bicep`):

| Resource | Type | Purpose |
|----------|------|---------|
| Container Registry | `Microsoft.ContainerRegistry/registries` | Stores container images |
| Container Apps Environment | `Microsoft.App/managedEnvironments` | Hosting environment (Consumption) |
| Container App | `Microsoft.App/containerApps` | The deployed application |
| Managed Identity role | ACR Pull (`AcrPull`) | Allows Container App to pull images from ACR |

### Key Bicep Properties

> **Illustrative only.** The snippet below shows the key properties agents should understand. All actual Bicep generation — including API version selection — is owned exclusively by `vibeshield-bicep`. Do NOT copy this API version or override `vibeshield-bicep`'s output.

```bicep
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  properties: {
    configuration: {
      ingress: {
        external: true
        targetPort: 8080          // Must match Dockerfile EXPOSE
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: appName
          image: '${acr.properties.loginServer}/${appName}:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0           // Scale to zero for Consumption
        maxReplicas: 10
      }
    }
  }
}
```

## ACR Authentication

The pipeline authenticates to ACR via the Docker registry service connection `sc-acrsandboxcuspoc-acr`. The `Docker@2` task uses the `containerRegistryConnection` input, which maps to this Azure DevOps Docker registry service connection. The separate `acrLoginServer` variable holds the ACR login server URL (e.g., `acrsandboxcuspoc.azurecr.io`) used in image references for `az containerapp update`.

For managed identity-based pulls at runtime (Container App pulling images), the Bicep template configures ACR Pull role assignment on the managed identity.

## Health Checks

Container Apps health checks use the app's FQDN:

```powershell
Invoke-WebRequest -Uri "https://<app-fqdn>" -UseBasicParsing
```

The FQDN is output by the Bicep deployment and captured by the pipeline. Do not query Azure resources locally:
```
# FQDN is available from the pipeline's Bicep deployment output — do NOT run az commands directly.
# The deploy stage captures it as a pipeline variable for use in health checks.
```

Cold-start wait time for Container Apps is **~60 seconds** (scale-from-zero takes longer than always-on services).

## Image Tagging Strategy

- Build images are tagged with `$(Build.BuildId)` — a unique, incrementing integer
- This ensures every deployment uses a distinct image tag
- Never use `latest` as the deployment tag — it causes ambiguity in rollback scenarios
- The Bicep template's initial image reference uses `latest` as a placeholder; the pipeline updates it to the specific build ID

## Common Mistakes

| Mistake | Correction |
|---------|------------|
| Using `1ES-BuildPool-Ubuntu` for Docker | Use `1ES-BuildPool` with `os: windows` — Linux image not yet ready |
| Pushing to Docker Hub instead of ACR | Use ACR — it integrates with managed identity |
| Using `latest` tag for deployment | Tag with `$(Build.BuildId)` |
| Hardcoding ACR credentials | Use service connection via `Docker@2` task |
| Missing `.dockerignore` | Create one to exclude `.git`, `node_modules`, etc. |
| No `EXPOSE` in Dockerfile | Add `EXPOSE <port>` matching the app's listen port |
| Running as root | Add `USER` directive in Dockerfile |
| Using bare `script` for `az` commands | Use `AzureCLI@2` with `azureSubscription` |
| Forgetting ACR Pull role for managed identity | Include `AcrPull` role assignment in Bicep |
| Mismatched ports (Dockerfile vs Bicep) | `EXPOSE` port must match `ingress.targetPort` |
