#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Resolves and optionally authorizes the VibeShield service connection.

.DESCRIPTION
    Derives the service connection name from the user's email (ARM) or from
    the EV2 naming pattern (Ev2Endpoint), queries Azure DevOps for its
    existence, and optionally authorizes it for all pipelines.
    Returns a structured result object.

    Exit code 0 = found (and authorized if -Authorize). Exit code 1 = not found or error.

.PARAMETER Email
    Microsoft email address (e.g. user@microsoft.com). Required for ARM SC resolution.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL (e.g. https://dev.azure.com/myorg).

.PARAMETER AdoProject
    Azure DevOps project name.

.PARAMETER Authorize
    When set, authorizes the service connection for all pipelines.

.PARAMETER InfraDeployMethod
    Infrastructure deployment method: 'ARM' (default) or 'EV2'.
    When 'EV2', resolves the EV2 service connection (cn-ev2deploy-{service}-{environment})
    in addition to the ARM service connection.

.PARAMETER Ev2ServiceName
    Service name component for EV2 SC pattern. Required when InfraDeployMethod is 'EV2'.

.PARAMETER Ev2Environment
    Target environment for EV2 SC pattern (Dev, UAT, Prod). Required when InfraDeployMethod is 'EV2'.

.EXAMPLE
    # ARM SC resolution (default)
    ./.github/skills/deploy-service-connection-resolve/scripts/Invoke-ServiceConnectionResolve.ps1 `
        -Email user@microsoft.com `
        -AdoOrgUrl https://dev.azure.com/oneCELA `
        -AdoProject CELA_Demos_and_POCs

.EXAMPLE
    # EV2 SC resolution (resolves both ARM + EV2)
    ./.github/skills/deploy-service-connection-resolve/scripts/Invoke-ServiceConnectionResolve.ps1 `
        -Email user@microsoft.com `
        -AdoOrgUrl https://dev.azure.com/oneCELA `
        -AdoProject CELA_Demos_and_POCs `
        -InfraDeployMethod EV2 `
        -Ev2ServiceName cela-eo14117-durability `
        -Ev2Environment Dev
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$AdoOrgUrl,
    [Parameter(Mandatory)][string]$AdoProject,
    [switch]$Authorize,
    [string]$WorkspacePath,
    [ValidateSet('ARM','EV2')][string]$InfraDeployMethod = 'ARM',
    [string]$Ev2ServiceName,
    [string]$Ev2Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load shared helpers ─────────────────────────────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
$_wsRoot = if ($WorkspacePath) { $WorkspacePath } else { (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..') -ErrorAction SilentlyContinue)?.Path }
if ($_wsRoot) { Assert-ScriptIntegrity -WorkspacePath $_wsRoot }

# ── Resolve SC name ──────────────────────────────────────────
# Priority order:
#   1. deploy-state.json ServiceConnectionName (set by onboarding pipeline — authoritative)
#   2. Pipeline YAML serviceConnection variable (what the pipeline actually uses)
#   3. infra/config.ps1 $Config.ServiceConnection (explicit config for uat/prod)
#   4. Derive from email (fallback for poc/dev when nothing else exists)
$ScName = $null

# Priority 1: Read from deploy-state.json (onboarding pipeline output)
if ($_wsRoot) {
    $_statePath = Get-StateFilePath -WorkspacePath $_wsRoot
    if (Test-Path $_statePath) {
        try {
            $_state = Get-Content $_statePath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($_state.PSObject.Properties['ServiceConnectionName'] -and $_state.ServiceConnectionName) {
                $ScName = $_state.ServiceConnectionName
            }
        } catch { $null = $_ }
    }
}

# Priority 2: Read from pipeline YAML (the deployed pipeline's actual SC — check both 1ES and OneBranch dirs)
if (-not $ScName -and $_wsRoot) {
    $_ymlPaths = @(
        (Join-Path -Path $_wsRoot -ChildPath '.azdo/pipelines/azure-pipeline.yml'),
        (Join-Path -Path $_wsRoot -ChildPath '.azdo/pipelines/azure-pipelines.yml')
    )
    # Also scan OneBranch directory
    $_obDir = Join-Path -Path $_wsRoot -ChildPath '.azure-pipelines'
    if (Test-Path $_obDir) {
        $_ymlPaths += @(Get-ChildItem -Path $_obDir -Filter '*.yml' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    foreach ($_yp in $_ymlPaths) {
        if (Test-Path $_yp) {
            $_ymlContent = Get-Content $_yp -Raw -ErrorAction SilentlyContinue
            if ($_ymlContent -match '(?m)^\s+serviceConnection:\s*(.+)$') {
                $_scCandidate = $Matches[1].Trim().Trim("'""")
                # Only use if it's a literal value (not a variable reference like $(serviceConnection))
                if ($_scCandidate -notmatch '^\$\(' -and $_scCandidate -match '^sc-vibe-') {
                    $ScName = $_scCandidate
                }
            }
            # Also check the variables block
            if (-not $ScName -and $_ymlContent -match '(?m)^\s+serviceConnection:\s*(.+)$') {
                # Look for the variable definition: serviceConnection: sc-vibe-xxx-ARM
                if ($_ymlContent -match '(?m)^\s+serviceConnection:\s*([^$\n]+)$') {
                    $_scVar = $Matches[1].Trim().Trim("'""")
                    if ($_scVar -match '^sc-vibe-') { $ScName = $_scVar }
                }
            }
            break
        }
    }
}

# Priority 3: Read from infra/config.ps1 (explicit SC for uat/prod)
if (-not $ScName -and $_wsRoot) {
    $configPath = if (Get-Command Resolve-ConfigPath -ErrorAction SilentlyContinue) {
        Resolve-ConfigPath -WorkspacePath $_wsRoot
    } else {
        Join-Path -Path $_wsRoot -ChildPath 'infra/config.ps1'
    }
    if (Test-Path $configPath) {
        $configSafe = if (Get-Command Test-ConfigFileSafe -ErrorAction SilentlyContinue) {
            Test-ConfigFileSafe -ConfigPath $configPath
        } else { [pscustomobject]@{ Safe = $true; Issues = @() } }
        if ($configSafe.Safe) {
            $Config = $null
            try { . $configPath } catch { $null = $_ }
            if ($Config -and $Config.ServiceConnection) {
                $ScName = $Config.ServiceConnection
            }
        } else {
            Write-Warning "Unsafe infra/config.ps1 — skipping SC read: $($configSafe.Issues -join '; ')"
        }
    }
}

# Priority 4: Derive from email (fallback for poc/dev)
if (-not $ScName) {
    $Username = ($Email -split '@')[0]
    $ScName   = Get-ServiceConnectionName -Username $Username
}

# ── Validate email format ───────────────────────────────────
if ($Email -notmatch '@microsoft\.com$') {
    Write-Warning "Email '$Email' is not a @microsoft.com address. Service connection name '$ScName' may be incorrect."
}

Write-Output "" | Out-Host
Write-Output "  Resolving service connection: $ScName" | Out-Host
Write-Output "    Org     : $AdoOrgUrl" | Out-Host
Write-Output "    Project : $AdoProject" | Out-Host
Write-Output "" | Out-Host

# ── Query for service endpoint (with transient retry) ───────
$scCheck = $null
try {
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        $scCheck = Invoke-WithRetry -ScriptBlock {
            $r = Test-ServiceConnectionExists -ScName $ScName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
            if ($r.Error -and $r.Error -match '503|429|timed out|throttl') { throw $r.Error }
            $r
        } -MaxRetries 3
    } else {
        $scCheck = Test-ServiceConnectionExists -ScName $ScName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
    }
} catch {
    $scCheck = [pscustomobject]@{ Exists = $false; EndpointId = $null; Error = $_.Exception.Message }
}

if ($scCheck.Error) {
    Write-Warning "Failed to query service endpoints: $($scCheck.Error)"
    [pscustomobject]@{
        Found      = $false
        EndpointId = $null
        ScName     = $ScName
        Authorized = $false
        Error      = $scCheck.Error
    }
    $global:LASTEXITCODE = 1
    exit 1
}

if (-not $scCheck.Exists) {
    Write-Output "  ❌ Service connection '$ScName' not found" | Out-Host
    # List available SCs for diagnostic output
    $listResult = Invoke-AzCommand 'devops' 'service-endpoint' 'list' `
        '--org' $AdoOrgUrl '--project' $AdoProject '-o' 'json' -TimeoutSeconds 60
    if ($listResult.ExitCode -eq 0 -and $listResult.Output) {
        try {
            $allEndpoints = @($listResult.Output | ConvertFrom-Json)
            Write-Output "     Available service connections:" | Out-Host
            foreach ($ep in $allEndpoints) {
                Write-Output "       - $($ep.name) ($($ep.type))" | Out-Host
            }
        } catch { $null = $_ }
    }
    [pscustomobject]@{
        Found      = $false
        EndpointId = $null
        ScName     = $ScName
        Authorized = $false
        Error      = "Service connection '$ScName' not found in project"
    }
    $global:LASTEXITCODE = 1
    exit 1
}

$endpointId = $scCheck.EndpointId
Write-Output "  ✅ Found: $ScName (ID: $endpointId)" | Out-Host

# ── Authorize if requested (uses shared Grant-ServiceConnectionAccess) ──
$isAuthorized = $false
if ($Authorize) {
    Write-Output "  Authorizing for all pipelines..." | Out-Host
    $authResult = Grant-ServiceConnectionAccess -ScName $ScName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject -Scope AllPipelines
    if ($authResult.Status -eq 'PASS') {
        Write-Output "  ✅ Authorized for all pipelines" | Out-Host
        $isAuthorized = $true
    } else {
        Write-Output "  ⚠️  Authorization: $($authResult.Message)" | Out-Host
    }
}

# ── Return result ───────────────────────────────────────────
$output = [pscustomobject]@{
    Found      = $true
    EndpointId = $endpointId
    ScName     = $ScName
    Authorized = $isAuthorized
    Error      = $null
}

# ── EV2 Service Connection Resolution (when InfraDeployMethod is EV2) ───
if ($InfraDeployMethod -eq 'EV2') {
    if (-not $Ev2ServiceName -or -not $Ev2Environment) {
        Write-Warning "EV2 resolution requires -Ev2ServiceName and -Ev2Environment parameters"
        $output | Add-Member -NotePropertyName 'Ev2Found' -NotePropertyValue $false
        $output | Add-Member -NotePropertyName 'Ev2ScName' -NotePropertyValue $null
        $output | Add-Member -NotePropertyName 'Ev2Error' -NotePropertyValue 'Missing Ev2ServiceName or Ev2Environment parameter'
    } else {
        # Resolve EV2 SC name from config pattern
        $_cfg = if (Get-Command Get-DeployConfig -ErrorAction SilentlyContinue) { Get-DeployConfig } else { $null }
        $_ev2Pattern = if ($_cfg -and $_cfg.ev2.serviceConnectionPattern) {
            $_cfg.ev2.serviceConnectionPattern
        } else {
            'cn-ev2deploy-{service}-{environment}'
        }
        # Map environment to EV2 SC environment suffix (lowercase)
        $_ev2EnvMap = @{ 'Dev' = 'dev'; 'UAT' = 'dev'; 'Prod' = 'prod'; 'Test' = 'dev' }
        $_ev2EnvSuffix = if ($_ev2EnvMap.ContainsKey($Ev2Environment)) { $_ev2EnvMap[$Ev2Environment] } else { $Ev2Environment.ToLower() }
        $Ev2ScName = $_ev2Pattern -replace '\{service\}', $Ev2ServiceName -replace '\{environment\}', $_ev2EnvSuffix

        Write-Output "" | Out-Host
        Write-Output "  Resolving EV2 service connection: $Ev2ScName" | Out-Host

        $ev2Check = Test-ServiceConnectionExists -ScName $Ev2ScName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
        if ($ev2Check.Exists) {
            Write-Output "  ✅ Found EV2 SC: $Ev2ScName (ID: $($ev2Check.EndpointId))" | Out-Host

            # Authorize EV2 SC if requested
            $_ev2Auth = $false
            if ($Authorize) {
                Write-Output "  Authorizing EV2 SC for all pipelines..." | Out-Host
                $ev2AuthResult = Grant-ServiceConnectionAccess -ScName $Ev2ScName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject -Scope AllPipelines
                if ($ev2AuthResult.Status -eq 'PASS') {
                    Write-Output "  ✅ EV2 SC authorized for all pipelines" | Out-Host
                    $_ev2Auth = $true
                } else {
                    Write-Output "  ⚠️  EV2 SC authorization: $($ev2AuthResult.Message)" | Out-Host
                }
            }

            $output | Add-Member -NotePropertyName 'Ev2Found' -NotePropertyValue $true
            $output | Add-Member -NotePropertyName 'Ev2ScName' -NotePropertyValue $Ev2ScName
            $output | Add-Member -NotePropertyName 'Ev2EndpointId' -NotePropertyValue $ev2Check.EndpointId
            $output | Add-Member -NotePropertyName 'Ev2Authorized' -NotePropertyValue $_ev2Auth
            $output | Add-Member -NotePropertyName 'Ev2Error' -NotePropertyValue $null
        } else {
            Write-Output "  ❌ EV2 service connection '$Ev2ScName' not found" | Out-Host
            if ($ev2Check.Error) {
                Write-Output "     Error: $($ev2Check.Error)" | Out-Host
            }
            $output | Add-Member -NotePropertyName 'Ev2Found' -NotePropertyValue $false
            $output | Add-Member -NotePropertyName 'Ev2ScName' -NotePropertyValue $Ev2ScName
            $output | Add-Member -NotePropertyName 'Ev2Error' -NotePropertyValue "EV2 service connection '$Ev2ScName' not found in project"
        }
    }
}

Write-Output "" | Out-Host
$output
exit 0
