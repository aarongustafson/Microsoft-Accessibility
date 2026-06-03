#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Validates a 1ES pipeline YAML against all structural and semantic checks.

.DESCRIPTION
    Runs PA-01 through PA-41 (structural checks PA-01–PA-18b and semantic checks PA-19–PA-41)
    from the vibeshield-deploy-pipeline-author validation checklist. Emits results via
    Write-SarifReport.ps1.

    Exit code 0 = all checks passed. Exit code 1 = one or more checks failed.

.PARAMETER PipelineYmlPath
    Relative path to the pipeline YAML file (default: .azdo/pipelines/azure-pipeline.yml).

.PARAMETER AppType
    Detected application type (e.g., .NET, Node.js, Python, Java, Container, Functions).

.PARAMETER TargetAzureService
    Target Azure service (e.g., AppService, ContainerApps, Functions, StaticWebApps).

.PARAMETER ServiceConnectionName
    Expected service connection name (sc-vibe-<name>-ARM).

.PARAMETER WorkspacePath
    Path to the workspace root. Defaults to current directory.

.PARAMETER SarifPath
    Path for the SARIF output file. Defaults to .vibeshield/results/pipeline-author-results.sarif.

.PARAMETER ComponentsJson
    Optional JSON array of secondary components detected by preflight. Each
    element must have AppType, TargetAzureService, and ComponentPath. When
    provided, enables multi-component checks PA-34 through PA-39.

.EXAMPLE
    ./.github/skills/deploy-pipeline-validation/scripts/Invoke-PipelineAuthorValidation.ps1 `
        -AppType 'Node.js' `
        -TargetAzureService 'AppService' `
        -ServiceConnectionName 'sc-vibe-user.name-ARM'
#>
[CmdletBinding()]
param(
    [string]$PipelineYmlPath = '.azdo/pipelines/azure-pipeline.yml',
    [Parameter(Mandatory)][string]$AppType,
    [Parameter(Mandatory)][string]$TargetAzureService,
    [Parameter(Mandatory)][string]$ServiceConnectionName,
    [string]$WorkspacePath = $PWD.Path,
    [string]$SarifPath,
    [string]$ComponentsJson,
    [string]$SkipChecks,
    [switch]$AutoFix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Initialize multi-component list (used by PA-26 and PA-34+) ──
$script:Components = @()

# ── Load shared helpers ─────────────────────────────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

# ── Parse -SkipChecks into a lookup set ─────────────────────
$script:SkipCheckIds = @{}
if ($SkipChecks) {
    foreach ($raw in ($SkipChecks -split ',')) {
        $id = $raw.Trim()
        if ($id) { $script:SkipCheckIds[$id] = $true }
    }
}

function Test-SkipResume {
    param([string]$Id)
    if ($script:SkipCheckIds.ContainsKey($Id)) {
        Add-CheckResult -Id $Id -Name 'Resumed' -Status SKIP-RESUME -Message "Previously passed — skipped on resume"
        return $true
    }
    # Also accept without PA- prefix or with it
    $alt = if ($Id -match '^PA-') { $Id -replace '^PA-', '' } else { "PA-$Id" }
    if ($script:SkipCheckIds.ContainsKey($alt)) {
        Add-CheckResult -Id $Id -Name 'Resumed' -Status SKIP-RESUME -Message "Previously passed — skipped on resume"
        return $true
    }
    return $false
}

# ── Clean start ─────────────────────────────────────────────
if (-not $SarifPath) {
    $SarifPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'pipeline-author-results.sarif'
}
Initialize-SarifCleanStart -SarifPath $SarifPath

# ── Resolve full pipeline path ──────────────────────────────
$fullYmlPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
if (-not (Test-Path $fullYmlPath)) {
    Write-Error "Pipeline YAML not found at: $fullYmlPath"
    $global:LASTEXITCODE = 1
    exit 1
}

# ── Parse YAML ──────────────────────────────────────────────
# Use PowerShell-yaml module if available; otherwise basic text parsing
$yamlContent = (Get-Content $fullYmlPath -Raw) -replace "`r`n", "`n"  # Normalize line endings for cross-platform regex
$null        = Get-Content $fullYmlPath  # yamlLines reserved for future line-level parsing

# ── Script-level timeout guard ──────────────────────────────
$script:ValidationDeadline = (Get-Date).AddSeconds(120)
function Assert-NotTimedOut {
    if ((Get-Date) -ge $script:ValidationDeadline) {
        Write-Error 'Pipeline validation timed out after 120 seconds. YAML may be too large or complex.'
        $global:LASTEXITCODE = 1
        exit 1
    }
}

# Try to load powershell-yaml for structured parsing
try {
    if (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue) {
        Import-Module powershell-yaml -ErrorAction Stop
        $null = ConvertFrom-Yaml -Yaml $yamlContent
    }
} catch { <# powershell-yaml not available or parse failure #> $null = $_ }

# ── Results collector ───────────────────────────────────────
$script:Results  = [System.Collections.ArrayList]::new()
$script:ExitCode = 0

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','WARN','SKIP','SKIP-RESUME')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Fix
    )
    $null = $script:Results.Add([pscustomobject]@{id=$Id; name=$Name; status=$Status; message=$Message; fix=$Fix})
    if ($Status -eq 'FAIL') { $script:ExitCode = 1 }
    $icon  = switch ($Status) { 'PASS' {'✅'} 'FAIL' {'❌'} 'WARN' {'⚠️'} 'SKIP' {'⏭️'} 'SKIP-RESUME' {'⏩'} }
    $line  = "  $icon ${Id}: $Name"
    if ($Status -ne 'PASS') { $line += " — $Message" }
    Write-Output $line | Out-Host

    # ── Structured log ──────────────────────────────────────
    $logLevel = switch ($Status) { 'PASS' {'info'} 'FAIL' {'error'} 'WARN' {'warn'} 'SKIP' {'info'} 'SKIP-RESUME' {'info'} default {'info'} }
    if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
        Write-VsdLog -Message "$Id $Name — $Message" -Category 'pipeline-author' -Level $logLevel `
            -Agent 'vibeshield-deploy-pipeline-author' -Skill 'deploy-pipeline-validation' `
            -Script 'Invoke-PipelineAuthorValidation.ps1' -CheckId $Id -Stage 2 `
            -WorkspacePath $WorkspacePath `
            -Extra @{ status = $Status; fix = if ($Fix) { $Fix } else { '' } }
    }
}

Write-Output "" | Out-Host
Write-Output "================================================================" | Out-Host
Write-Output "  Pipeline Author Validation" | Out-Host
Write-Output "================================================================" | Out-Host
Write-Output "" | Out-Host
Write-Output "  Pipeline  : $PipelineYmlPath" | Out-Host
Write-Output "  App Type  : $AppType" | Out-Host
Write-Output "  Target    : $TargetAzureService" | Out-Host
Write-Output "  SC Name   : $ServiceConnectionName" | Out-Host
Write-Output "" | Out-Host
Write-Output "  Running checks:" | Out-Host

# ════════════════════════════════════════════════════════════
# STRUCTURAL CHECKS (PA-01 through PA-18)
# ════════════════════════════════════════════════════════════

# ── EV2 detection ───────────────────────────────────────────
# Infrastructure provisioning can be either ARM (Bicep via AzureCLI@2) or EV2
# (Ev2RARollout@2). Several checks below are Bicep-specific and must be skipped
# or adapted when the Provision stage uses EV2.
$isEv2Provision = $yamlContent -match 'Ev2RARollout@2|ob_ev2|ServiceGroupRoot'

# Resolve expected template values from config
$_templateName = Get-PipelineTemplateSetting -Key 'name' -Default '1ES.Unofficial@1'
$_templateRepo = Get-PipelineTemplateSetting -Key 'repoName' -Default '1ESPipelineTemplates'
# Build the expected extends pattern: e.g., "1ES.Unofficial.PipelineTemplate.yml@1ESPipelineTemplates"
$_templateBaseName = ($_templateName -replace '@.*$','')  # "1ES.Unofficial"
$_extendsPattern = "$_templateBaseName.PipelineTemplate.yml@$_templateRepo"

# PA-01: extends.template references 1ES.Unofficial
if ($yamlContent -match [regex]::Escape($_extendsPattern)) {
    Add-CheckResult -Id 'PA-01' -Name '1ES Template Reference' -Status PASS -Message "extends.template references $_extendsPattern"
} else {
    Add-CheckResult -Id 'PA-01' -Name '1ES Template Reference' -Status FAIL -Message "Pipeline does not extend $_extendsPattern" -Fix "Set extends.template to v1/$_extendsPattern"
}

# PA-02: resources.repositories includes template repo
if ($yamlContent -match "repository:\s*$_templateRepo") {
    Add-CheckResult -Id 'PA-02' -Name '1ES Repository Resource' -Status PASS -Message "resources.repositories includes $_templateRepo"
} else {
    Add-CheckResult -Id 'PA-02' -Name '1ES Repository Resource' -Status FAIL -Message "$_templateRepo not found in resources.repositories" -Fix "Add $_templateRepo repository resource"
}

# PA-03: SDL credscan enabled
if ($yamlContent -match 'credscan:\s*\n\s*enabled:\s*true') {
    Add-CheckResult -Id 'PA-03' -Name 'SDL CredScan' -Status PASS -Message 'SDL credscan is enabled'
} else {
    Add-CheckResult -Id 'PA-03' -Name 'SDL CredScan' -Status FAIL -Message 'SDL credscan not enabled' -Fix 'Add credscan: enabled: true under sdl section'
}

# PA-04: SDL policheck enabled
if ($yamlContent -match 'policheck:\s*\n\s*enabled:\s*true') {
    Add-CheckResult -Id 'PA-04' -Name 'SDL PoliCheck' -Status PASS -Message 'SDL policheck is enabled'
} else {
    Add-CheckResult -Id 'PA-04' -Name 'SDL PoliCheck' -Status FAIL -Message 'SDL policheck not enabled' -Fix 'Add policheck: enabled: true under sdl section'
}

# PA-05: SDL git.submodules: false and checkout.submodules: false
$hasGitSubmodules = $yamlContent -match 'git:\s*\n\s*submodules:\s*false'
$hasCheckoutSubmodules = $yamlContent -match 'checkout:\s*\n\s*submodules:\s*false'
if ($hasGitSubmodules -and $hasCheckoutSubmodules) {
    Add-CheckResult -Id 'PA-05' -Name 'SDL Submodule Suppression' -Status PASS -Message 'SDL submodule suppression configured (git + checkout)'
} else {
    $missing = @()
    if (-not $hasGitSubmodules) { $missing += 'git.submodules: false' }
    if (-not $hasCheckoutSubmodules) { $missing += 'checkout.submodules: false' }
    Add-CheckResult -Id 'PA-05' -Name 'SDL Submodule Suppression' -Status FAIL -Message "Missing SDL submodule suppression: $($missing -join ', ')" -Fix 'Add git.submodules: false and checkout.submodules: false under sdl section'
}

# PA-06: SDL sourceAnalysisPool must use 1ES-BuildPool with os: windows
if ($yamlContent -match 'sourceAnalysisPool:\s*\n\s*name:\s*1ES-BuildPool\s*\n\s*os:\s*windows') {
    Add-CheckResult -Id 'PA-06' -Name 'SDL Source Analysis Pool' -Status PASS -Message 'sourceAnalysisPool is set to 1ES-BuildPool with os: windows'
} elseif ($yamlContent -match 'sourceAnalysisPool:\s*\n\s*name:\s*1ES-BuildPool') {
    Add-CheckResult -Id 'PA-06' -Name 'SDL Source Analysis Pool' -Status FAIL -Message 'sourceAnalysisPool must use os: windows' -Fix 'Set sourceAnalysisPool os to windows under sdl section'
} else {
    Add-CheckResult -Id 'PA-06' -Name 'SDL Source Analysis Pool' -Status FAIL -Message 'sourceAnalysisPool not set to 1ES-BuildPool' -Fix 'Add sourceAnalysisPool with name: 1ES-BuildPool and os: windows under sdl section'
}

# PA-07: Deploy stages use regular job (not deployment job)
if ($yamlContent -match '(?i)- deployment:') {
    Add-CheckResult -Id 'PA-07' -Name 'Regular Job (not deployment)' -Status FAIL -Message 'Deploy stage uses deployment job — must use regular job' -Fix 'Replace "- deployment:" with "- job:" in deploy stages'
} elseif ($yamlContent -match '(?i)environment:' -and $yamlContent -match '(?i)strategy:\s*\n\s*runOnce:') {
    Add-CheckResult -Id 'PA-07' -Name 'Regular Job (not deployment)' -Status FAIL -Message 'Deploy stage uses environment/strategy — must use regular job' -Fix 'Remove environment and strategy.runOnce; use regular job blocks'
} else {
    Add-CheckResult -Id 'PA-07' -Name 'Regular Job (not deployment)' -Status PASS -Message 'Deploy stages use regular job blocks'
}

# PA-08: No hardcoded secrets or tokens
$secretPatterns = @(
    '(?i)password\s*[:=]\s*[''"][^$][^''"]+'
    '(?i)secret\s*[:=]\s*[''"][^$][^''"]+'
    '(?i)token\s*[:=]\s*[''"][^$][^''"]+'
    '(?i)connectionstring\s*[:=]\s*[''"][^$][^''"]+'
)
$foundSecrets = $false
foreach ($pat in $secretPatterns) {
    if ($yamlContent -match $pat) { $foundSecrets = $true; break }
}
if (-not $foundSecrets) {
    Add-CheckResult -Id 'PA-08' -Name 'No Hardcoded Secrets' -Status PASS -Message 'No hardcoded secrets detected'
} else {
    Add-CheckResult -Id 'PA-08' -Name 'No Hardcoded Secrets' -Status FAIL -Message 'Potential hardcoded secrets found in pipeline YAML' -Fix 'Remove secrets; use Azure DevOps pipeline variables or Key Vault'
}

# PA-09: Service connection name follows convention
if ($yamlContent -match [regex]::Escape($ServiceConnectionName)) {
    Add-CheckResult -Id 'PA-09' -Name 'SC Name Convention' -Status PASS -Message "Service connection '$ServiceConnectionName' referenced correctly"
} elseif ($yamlContent -match 'sc-vibe-[^''"]+\-ARM') {
    Add-CheckResult -Id 'PA-09' -Name 'SC Name Convention' -Status WARN -Message "SC name found but doesn't match expected '$ServiceConnectionName'" -Fix "Update serviceConnection variable to '$ServiceConnectionName'"
} else {
    Add-CheckResult -Id 'PA-09' -Name 'SC Name Convention' -Status FAIL -Message 'No sc-vibe-*-ARM service connection reference found' -Fix "Set serviceConnection variable to '$ServiceConnectionName'"
}

# PA-10: CI trigger on main branch
if ($yamlContent -match '(?s)trigger:(?:(?!\npr:).)*?branches:.*?include:.*?-\s*main') {
    Add-CheckResult -Id 'PA-10' -Name 'CI Trigger on main' -Status PASS -Message 'CI trigger configured for main branch'
} else {
    Add-CheckResult -Id 'PA-10' -Name 'CI Trigger on main' -Status FAIL -Message 'CI trigger not set on main branch' -Fix 'Add trigger: branches: include: - main'
}

# PA-11: PR validation on main
if ($yamlContent -match '(?s)pr:.*?branches:.*?include:.*?-\s*main') {
    Add-CheckResult -Id 'PA-11' -Name 'PR Validation on main' -Status PASS -Message 'PR validation configured for main branch'
} else {
    Add-CheckResult -Id 'PA-11' -Name 'PR Validation on main' -Status FAIL -Message 'PR validation not set on main branch' -Fix 'Add pr: branches: include: - main'
}

# PA-12: Build stage publishes an artifact
$isContainer = $AppType -match 'Container'
if ($isContainer) {
    # Container apps use Docker image as artifact — no PublishPipelineArtifact needed
    if ($yamlContent -match 'Docker@2' -or $yamlContent -match 'buildAndPush') {
        Add-CheckResult -Id 'PA-12' -Name 'Build Artifact' -Status PASS -Message 'Container build uses Docker@2 as artifact mechanism'
    } else {
        Add-CheckResult -Id 'PA-12' -Name 'Build Artifact' -Status FAIL -Message 'Container pipeline missing Docker@2 build task' -Fix 'Add Docker@2 task with build command'
    }
} else {
    if ($yamlContent -match '1ES\.PublishBuildArtifacts@1|PublishPipelineArtifact@1') {
        Add-CheckResult -Id 'PA-12' -Name 'Build Artifact' -Status PASS -Message 'Build stage publishes an artifact'
    } else {
        Add-CheckResult -Id 'PA-12' -Name 'Build Artifact' -Status FAIL -Message 'Build stage does not publish an artifact' -Fix 'Add 1ES.PublishBuildArtifacts@1 task to Build stage'
    }
}

# PA-13: Deploy stage downloads artifact and deploys
if ($isContainer) {
    # Container exception: no artifact download needed
    Add-CheckResult -Id 'PA-13' -Name 'Deploy Artifact Download' -Status PASS -Message 'Container deployment uses Docker image — no artifact download needed'
} else {
    if ($yamlContent -match 'DownloadPipelineArtifact@2|download.*artifact') {
        Add-CheckResult -Id 'PA-13' -Name 'Deploy Artifact Download' -Status PASS -Message 'Deploy stage downloads the build artifact'
    } else {
        Add-CheckResult -Id 'PA-13' -Name 'Deploy Artifact Download' -Status FAIL -Message 'Deploy stage does not download the build artifact' -Fix 'Add DownloadPipelineArtifact@2 task to Deploy stage'
    }
}

# PA-14: Provision stage has checkout: self before Bicep provisioning
if ($isEv2Provision) {
    # EV2 Provision uses download: current or checkout: self — both are valid
    if ($yamlContent -match '(?s)stage:\s*Provision.*?(?:checkout:\s*self|download:\s*current)') {
        Add-CheckResult -Id 'PA-14' -Name 'Provision Checkout Self' -Status PASS -Message 'EV2 Provision stage has checkout or download step'
    } else {
        Add-CheckResult -Id 'PA-14' -Name 'Provision Checkout Self' -Status WARN -Message 'EV2 Provision stage — could not verify checkout/download step' -Fix 'Add checkout: self or download: current in the Provision stage'
    }
} elseif ($yamlContent -match '(?s)stage:\s*Provision.*?checkout:\s*self') {
    Add-CheckResult -Id 'PA-14' -Name 'Provision Checkout Self' -Status PASS -Message 'Provision stage has checkout: self before Bicep step'
} else {
    Add-CheckResult -Id 'PA-14' -Name 'Provision Checkout Self' -Status FAIL -Message 'Provision stage missing checkout: self' -Fix 'Add checkout: self as the first step in the Provision stage'
}

# PA-15: checkout: self has submodules: false, persistCredentials: true, fetchDepth: 1
$checkoutBlocks = [regex]::Matches($yamlContent, '(?s)checkout:\s*self.*?(?=\n\s*-|\n\s*stage:|\z)')
$checkoutOk = $true
$checkoutIssues = @()
foreach ($block in $checkoutBlocks) {
    $blockText = $block.Value
    if ($blockText -notmatch 'submodules:\s*false') { $checkoutOk = $false; $checkoutIssues += 'submodules: false' }
    if ($blockText -notmatch 'persistCredentials:\s*true') { $checkoutOk = $false; $checkoutIssues += 'persistCredentials: true' }
    if ($blockText -notmatch 'fetchDepth:\s*1') { $checkoutOk = $false; $checkoutIssues += 'fetchDepth: 1' }
}
if ($checkoutBlocks.Count -eq 0) {
    Add-CheckResult -Id 'PA-15' -Name 'Checkout Self Config' -Status FAIL -Message 'No checkout: self blocks found' -Fix 'Add checkout: self with submodules: false, persistCredentials: true, fetchDepth: 1'
} elseif ($checkoutOk) {
    Add-CheckResult -Id 'PA-15' -Name 'Checkout Self Config' -Status PASS -Message 'All checkout: self blocks have required properties'
} else {
    Add-CheckResult -Id 'PA-15' -Name 'Checkout Self Config' -Status FAIL -Message "Missing checkout properties: $($checkoutIssues | Select-Object -Unique | ForEach-Object { $_ })" -Fix 'Ensure every checkout: self has submodules: false, persistCredentials: true, fetchDepth: 1'
}

# PA-16: Bicep provisioning uses AzureCLI@2 in Provision stage (not bare script)
# For EV2 pipelines, infrastructure is deployed via Ev2RARollout@2 — not Bicep.
if ($isEv2Provision) {
    Add-CheckResult -Id 'PA-16' -Name 'Bicep via AzureCLI@2' -Status SKIP -Message 'EV2 pipeline — infrastructure deployed via Ev2RARollout@2, not Bicep'
} elseif ($yamlContent -match 'az deployment group create') {
    # Verify it's in a Provision stage
    $inProvisionStage = $yamlContent -match '(?s)stage:\s*Provision.*?az deployment group create'
    if ($yamlContent -match '(?s)AzureCLI@2.*?az deployment group create') {
        if ($inProvisionStage) {
            Add-CheckResult -Id 'PA-16' -Name 'Bicep via AzureCLI@2' -Status PASS -Message 'Bicep provisioning uses AzureCLI@2 in Provision stage'
        } else {
            Add-CheckResult -Id 'PA-16' -Name 'Bicep via AzureCLI@2' -Status FAIL -Message 'Bicep provisioning found but not in a Provision stage' -Fix 'Move Bicep provisioning into a separate Provision stage that runs before Deploy'
        }
    } elseif ($yamlContent -match '(?s)- script:.*?az deployment group create') {
        Add-CheckResult -Id 'PA-16' -Name 'Bicep via AzureCLI@2' -Status FAIL -Message 'Bicep provisioning uses bare script task instead of AzureCLI@2' -Fix 'Replace script task with AzureCLI@2 task for az deployment commands'
    } else {
        Add-CheckResult -Id 'PA-16' -Name 'Bicep via AzureCLI@2' -Status WARN -Message 'az deployment found but could not verify task type' -Fix 'Ensure az deployment commands are in AzureCLI@2 tasks in the Provision stage'
    }
} else {
    Add-CheckResult -Id 'PA-16' -Name 'Bicep via AzureCLI@2' -Status FAIL -Message 'No Bicep provisioning step detected — all pipelines must provision infrastructure before deploying code' -Fix 'Add a Provision stage with AzureCLI@2 step running az deployment group create before the Deploy stage'
}

# PA-16b: Reject subscription-level deployments — all deployments must be resource-group scoped
if ($yamlContent -match 'az deployment sub\b|az deployment subscription\b') {
    Add-CheckResult -Id 'PA-16b' -Name 'Resource-Group Scope Only' -Status FAIL -Message 'Pipeline uses subscription-level deployment (az deployment sub create) — must use az deployment group create' -Fix 'Replace az deployment sub create with az deployment group create --resource-group $(resourceGroup) and ensure Bicep uses targetScope = resourceGroup'
} else {
    Add-CheckResult -Id 'PA-16b' -Name 'Resource-Group Scope Only' -Status PASS -Message 'No subscription-level deployment commands found — pipeline uses resource-group scope'
}

# PA-17: All az CLI commands use AzureCLI@2 (not bare script)
$bareScriptAz = [regex]::Matches($yamlContent, '(?s)- script:(?:(?!- task:|- script:|- checkout:).)*?\baz\s')
if ($bareScriptAz.Count -gt 0) {
    Add-CheckResult -Id 'PA-17' -Name 'All az via AzureCLI@2' -Status FAIL -Message "Found $($bareScriptAz.Count) az commands in bare script tasks" -Fix 'Move all az CLI commands into AzureCLI@2 tasks with azureSubscription'
} else {
    Add-CheckResult -Id 'PA-17' -Name 'All az via AzureCLI@2' -Status PASS -Message 'No az CLI commands found in bare script tasks'
}

# PA-18: variables block at top level (not inside extends.parameters)
# Check that 'variables:' appears before 'extends:' in the file
$variablesIdx = $yamlContent.IndexOf('variables:')
$extendsIdx   = $yamlContent.IndexOf('extends:')
if ($variablesIdx -ge 0 -and $extendsIdx -ge 0 -and $variablesIdx -lt $extendsIdx) {
    Add-CheckResult -Id 'PA-18' -Name 'Variables at Top Level' -Status PASS -Message 'variables block is defined at the top level before extends'
} elseif ($variablesIdx -lt 0) {
    Add-CheckResult -Id 'PA-18' -Name 'Variables at Top Level' -Status FAIL -Message 'No variables block found' -Fix 'Add variables block between resources and extends sections'
} else {
    Add-CheckResult -Id 'PA-18' -Name 'Variables at Top Level' -Status FAIL -Message 'variables block appears inside extends.parameters — must be at top level' -Fix 'Move variables block above the extends section'
}

# PA-18b: resources.repositories contains ONLY 1ESPipelineTemplates (no submodule repos)
$repoMatches = [regex]::Matches($yamlContent, '- repository:\s*(\S+)')
$extraRepos = @()
foreach ($m in $repoMatches) {
    $repoName = $m.Groups[1].Value
    if ($repoName -ne '1ESPipelineTemplates') { $extraRepos += $repoName }
}
if ($extraRepos.Count -eq 0) {
    Add-CheckResult -Id 'PA-18b' -Name 'No Extra Repo Resources' -Status PASS -Message 'resources.repositories contains only 1ESPipelineTemplates'
} else {
    Add-CheckResult -Id 'PA-18b' -Name 'No Extra Repo Resources' -Status FAIL -Message "Extra repositories found: $($extraRepos -join ', ')" -Fix 'Remove non-1ESPipelineTemplates repositories — repos from .gitmodules must not be added'
}

# ════════════════════════════════════════════════════════════
# SEMANTIC CHECKS (PA-19 through PA-27)
# ════════════════════════════════════════════════════════════

# PA-19: Build tasks match detected app type
$buildTaskMap = @{
    '.NET'             = 'DotNetCoreCLI@2|dotnet'
    'Node.js backend'  = 'Npm@1|npm|NodeTool@0'
    'Static frontend'  = 'Npm@1|npm|NodeTool@0'
    'Python'           = 'UsePythonVersion@0|pip'
    'Java'             = 'Maven@|Gradle@|mvn|gradle'
    'Container'        = 'Docker@2'
    'Functions'        = 'DotNetCoreCLI@2|Npm@1|UsePythonVersion@0|Maven@'
    'Go'               = 'Docker@2'
    'Rust'             = 'Docker@2'
}
$expectedBuildPattern = $buildTaskMap[$AppType]
if ($expectedBuildPattern -and $yamlContent -match $expectedBuildPattern) {
    Add-CheckResult -Id 'PA-19' -Name 'Build Task Match' -Status PASS -Message "Build tasks match app type '$AppType'"
} elseif ($expectedBuildPattern) {
    Add-CheckResult -Id 'PA-19' -Name 'Build Task Match' -Status FAIL -Message "Build tasks do not match app type '$AppType'" -Fix "Add appropriate build tasks for '$AppType' — expected pattern: $expectedBuildPattern"
} else {
    Add-CheckResult -Id 'PA-19' -Name 'Build Task Match' -Status SKIP -Message "No build-task mapping for app type '$AppType'"
}

# PA-20: Deploy task matches target Azure service
$deployTaskMap = @{
    'AppService'    = 'AzureWebApp@1'
    'ContainerApps' = 'AzureContainerApps@1'
    'Functions'     = 'AzureFunctionApp@2|AzureFunctionApp@1'
    'StaticWebApps' = 'AzureStaticWebApp@0|swa deploy'
}
$expectedDeployTask = $deployTaskMap[$TargetAzureService]
# Filter comments before matching deploy tasks
$yamlNonCommentForDeploy = ($yamlContent -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
if ($expectedDeployTask -and $yamlNonCommentForDeploy -match $expectedDeployTask) {
    Add-CheckResult -Id 'PA-20' -Name 'Deploy Task Match' -Status PASS -Message "Deploy task matches target '$TargetAzureService'"
} elseif ($expectedDeployTask) {
    Add-CheckResult -Id 'PA-20' -Name 'Deploy Task Match' -Status FAIL -Message "No deploy task found for target '$TargetAzureService' (expected $expectedDeployTask)" -Fix "Add $expectedDeployTask task to the Deploy stage"
} else {
    Add-CheckResult -Id 'PA-20' -Name 'Deploy Task Match' -Status SKIP -Message "No deploy-task mapping for target '$TargetAzureService'"
}

# PA-21: Stage dependency chain: Provision dependsOn Build, Deploy dependsOn Provision
# For multi-component pipelines, Provision may dependsOn an array like [Build, Build_Functions]
# For EV2 pipelines without a Deploy stage, only check Build → Provision chain.
$provSection21 = ''
if ($yamlContent -match '(?si)(stage:\s*Provision.*?(?=stage:|$))') { $provSection21 = $Matches[1] }
$provDependsOnBuild = $provSection21 -match 'dependsOn.*Build'

$hasDeployStage = $yamlContent -match '(?m)^\s*-?\s*stage:\s*Deploy\b'
if ($isEv2Provision -and -not $hasDeployStage) {
    # EV2 pipeline with no Deploy stage — only check Build → Provision
    if ($provDependsOnBuild) {
        Add-CheckResult -Id 'PA-21' -Name 'Stage Dependency Chain' -Status PASS -Message 'Stage chain is correct: Build → Provision (EV2 — no Deploy stage)'
    } else {
        Add-CheckResult -Id 'PA-21' -Name 'Stage Dependency Chain' -Status FAIL -Message 'Provision stage missing dependsOn: Build' -Fix 'Set Provision dependsOn: Build'
    }
} else {
    $deployDependsOnProv = $yamlContent -match '(?s)stage:\s*Deploy\b.*?dependsOn:\s*Provision'
    if ($provDependsOnBuild -and $deployDependsOnProv) {
        Add-CheckResult -Id 'PA-21' -Name 'Stage Dependency Chain' -Status PASS -Message 'Stage chain is correct: Build → Provision → Deploy'
    } else {
        $issues = @()
        if (-not $provDependsOnBuild) { $issues += 'Provision stage missing dependsOn: Build' }
        if (-not $deployDependsOnProv) { $issues += 'Deploy stage missing dependsOn: Provision' }
        Add-CheckResult -Id 'PA-21' -Name 'Stage Dependency Chain' -Status FAIL -Message ($issues -join '; ') -Fix 'Set Provision dependsOn: Build and Deploy dependsOn: Provision'
    }
}

# PA-22: Artifact name consistency
# Also check artifact/downloadPath patterns
$publishMatch = [regex]::Match($yamlContent, '(?i)(?:artifact|ArtifactName):\s*[''"]?([^''"]+)')
$null = [regex]::Match($yamlContent, '(?i)(?:downloadPath|artifactName):\s*[''"]?([^''"]+)')
if ($isContainer) {
    Add-CheckResult -Id 'PA-22' -Name 'Artifact Name Consistency' -Status PASS -Message 'Container pipeline — Docker image is the artifact'
} elseif ($publishMatch.Success) {
    Add-CheckResult -Id 'PA-22' -Name 'Artifact Name Consistency' -Status PASS -Message 'Artifact reference found in pipeline'
} else {
    Add-CheckResult -Id 'PA-22' -Name 'Artifact Name Consistency' -Status WARN -Message 'Could not verify artifact name consistency' -Fix 'Ensure artifact name in PublishPipelineArtifact matches DownloadPipelineArtifact'
}

# PA-23: All $(variableName) references are defined
$varReferences = [regex]::Matches($yamlContent, '\$\(([^)]+)\)')
$definedVars = @('Build.SourcesDirectory', 'System.ArtifactsDirectory', 'System.DefaultWorkingDirectory',
                 'Build.ArtifactStagingDirectory', 'Pipeline.Workspace', 'Build.BuildId',
                 'Build.SourceVersion', 'Build.SourceBranch')
# Collect user-defined variables
$varSection = [regex]::Match($yamlContent, '(?m)^variables:\s*\n((?:\s+\S+.*\n)*)')
if ($varSection.Success) {
    $varLines = $varSection.Groups[1].Value -split "`n"
    foreach ($line in $varLines) {
        if ($line -match '^\s+(\w+)\s*:') { $definedVars += $Matches[1] }
    }
}
$undefinedVars = @()
foreach ($ref in $varReferences) {
    $varName = $ref.Groups[1].Value
    if ($varName -notin $definedVars -and $varName -notmatch '^(Agent\.|Build\.|System\.|Pipeline\.)') {
        $undefinedVars += $varName
    }
}
$undefinedVars = @($undefinedVars | Select-Object -Unique)
if ($undefinedVars.Count -eq 0) {
    Add-CheckResult -Id 'PA-23' -Name 'Variable References Defined' -Status PASS -Message 'All variable references are defined or are system variables'
} else {
    Add-CheckResult -Id 'PA-23' -Name 'Variable References Defined' -Status WARN -Message "Potentially undefined variables: $($undefinedVars -join ', ')" -Fix 'Define these variables in the variables section or verify they are pipeline parameters'
}

# PA-24: Tasks have required inputs (all deploy task types)
# Filter comments before input validation
$yamlNonCommentForInputs = ($yamlContent -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
$pa24Checked = $false

# AzureWebApp@1 (App Service)
if ($yamlNonCommentForInputs -match 'AzureWebApp@1') {
    $missingInputs = @()
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureWebApp@1.*?azureSubscription') { $missingInputs += 'azureSubscription' }
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureWebApp@1.*?appName') { $missingInputs += 'appName' }
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureWebApp@1.*?package') { $missingInputs += 'package' }
    if ($missingInputs.Count -eq 0) {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status PASS -Message 'AzureWebApp@1 has all required inputs'
    } else {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status FAIL -Message "AzureWebApp@1 missing inputs: $($missingInputs -join ', ')" -Fix "Add missing inputs to AzureWebApp@1: $($missingInputs -join ', ')"
    }
    $pa24Checked = $true
}

# AzureFunctionApp@2 or @1 (Functions)
if (-not $pa24Checked -and $yamlNonCommentForInputs -match 'AzureFunctionApp@[12]') {
    $missingInputs = @()
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureFunctionApp@\d.*?azureSubscription') { $missingInputs += 'azureSubscription' }
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureFunctionApp@\d.*?appName') { $missingInputs += 'appName' }
    if ($missingInputs.Count -eq 0) {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status PASS -Message 'AzureFunctionApp has all required inputs'
    } else {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status FAIL -Message "AzureFunctionApp missing inputs: $($missingInputs -join ', ')" -Fix "Add missing inputs to AzureFunctionApp: $($missingInputs -join ', ')"
    }
    $pa24Checked = $true
}

# AzureStaticWebApp@0 (Static Web Apps)
if (-not $pa24Checked -and $yamlNonCommentForInputs -match 'AzureStaticWebApp@0') {
    $missingInputs = @()
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureStaticWebApp@0.*?app_location') { $missingInputs += 'app_location' }
    if ($missingInputs.Count -eq 0) {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status PASS -Message 'AzureStaticWebApp@0 has all required inputs'
    } else {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status FAIL -Message "AzureStaticWebApp@0 missing inputs: $($missingInputs -join ', ')" -Fix "Add missing inputs to AzureStaticWebApp@0: $($missingInputs -join ', ')"
    }
    $pa24Checked = $true
}

# AzureContainerApps@1 (Container Apps)
if (-not $pa24Checked -and $yamlNonCommentForInputs -match 'AzureContainerApps@1') {
    $missingInputs = @()
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureContainerApps@1.*?azureSubscription') { $missingInputs += 'azureSubscription' }
    if ($yamlNonCommentForInputs -notmatch '(?s)AzureContainerApps@1.*?(?:imageToDeploy|containerAppName)') { $missingInputs += 'imageToDeploy or containerAppName' }
    if ($missingInputs.Count -eq 0) {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status PASS -Message 'AzureContainerApps@1 has all required inputs'
    } else {
        Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status FAIL -Message "AzureContainerApps@1 missing inputs: $($missingInputs -join ', ')" -Fix "Add missing inputs to AzureContainerApps@1: $($missingInputs -join ', ')"
    }
    $pa24Checked = $true
}

if (-not $pa24Checked) {
    Add-CheckResult -Id 'PA-24' -Name 'Task Required Inputs' -Status SKIP -Message 'No deploy task found for input validation'
}

# PA-25: Bicep path uses correct variables (in Provision stage)
if ($yamlContent -match 'az deployment group create') {
    if ($yamlContent -match '\$\(Build\.SourcesDirectory\)/infra/main\.bicep|\$\(Build\.SourcesDirectory\)\\infra\\main\.bicep') {
        Add-CheckResult -Id 'PA-25' -Name 'Path Variables' -Status PASS -Message 'Bicep path uses $(Build.SourcesDirectory)/infra/main.bicep'
    } else {
        Add-CheckResult -Id 'PA-25' -Name 'Path Variables' -Status WARN -Message 'Bicep template path may not use $(Build.SourcesDirectory)' -Fix 'Use $(Build.SourcesDirectory)/infra/main.bicep for Bicep template path'
    }
} else {
    Add-CheckResult -Id 'PA-25' -Name 'Path Variables' -Status FAIL -Message 'No Bicep provisioning step found' -Fix 'Add a Provision stage with Bicep deployment using $(Build.SourcesDirectory)/infra/main.bicep'
}

# PA-26: No duplicate steps
$checkoutSelfCount = ([regex]::Matches($yamlContent, 'checkout:\s*self')).Count
$bicepProvCount    = ([regex]::Matches($yamlContent, 'az deployment group create')).Count
$duplicateIssues = @()
# Multi-component pipelines: each Build stage + Provision = N components + 2 checkout:self expected
$expectedMaxCheckouts = 2 + $script:Components.Count
if ($checkoutSelfCount -gt $expectedMaxCheckouts) { $duplicateIssues += "checkout:self appears $checkoutSelfCount times (expected max $expectedMaxCheckouts for $($script:Components.Count + 1) component(s))" }
if ($bicepProvCount -gt 1) { $duplicateIssues += "Bicep provisioning appears $bicepProvCount times (expected 1)" }
if ($duplicateIssues.Count -eq 0) {
    Add-CheckResult -Id 'PA-26' -Name 'No Duplicate Steps' -Status PASS -Message 'No duplicate checkout or provisioning steps detected'
} else {
    Add-CheckResult -Id 'PA-26' -Name 'No Duplicate Steps' -Status WARN -Message ($duplicateIssues -join '; ') -Fix 'Remove duplicate steps — each stage should have at most one checkout:self and one Bicep step'
}

# PA-27: Stage step ordering — Provision: checkout → Bicep; Deploy: artifact → app deploy
$provisionSection = ''
if ($yamlContent -match '(?s)(stage:\s*Provision.*?)(?=stage:\s*Deploy|\z)') {
    $provisionSection = $Matches[1]
}
$deploySection = ''
if ($yamlContent -match '(?s)(stage:\s*Deploy(?!.*stage:\s*Deploy).*)') {
    $deploySection = $Matches[1]
}
if ($provisionSection) {
    $checkoutIdx  = $provisionSection.IndexOf('checkout: self')
    $bicepIdx     = $provisionSection.IndexOf('az deployment group create')
    if ($bicepIdx -lt 0) { $bicepIdx = $provisionSection.IndexOf('AzureCLI@2') }

    if ($checkoutIdx -ge 0 -and $bicepIdx -ge 0 -and $checkoutIdx -lt $bicepIdx) {
        Add-CheckResult -Id 'PA-27' -Name 'Stage Step Ordering' -Status PASS -Message 'Provision stage: checkout → Bicep; Deploy stage exists'
    } elseif ($checkoutIdx -ge 0 -and $bicepIdx -ge 0) {
        Add-CheckResult -Id 'PA-27' -Name 'Stage Step Ordering' -Status FAIL -Message 'Provision stage: checkout must precede Bicep provisioning' -Fix 'Reorder Provision stage: checkout:self → Bicep provisioning'
    } else {
        $missing = @()
        if ($checkoutIdx -lt 0) { $missing += 'checkout: self' }
        if ($bicepIdx -lt 0)    { $missing += 'Bicep provisioning (az deployment group create)' }
        Add-CheckResult -Id 'PA-27' -Name 'Stage Step Ordering' -Status FAIL -Message "Provision stage missing required steps: $($missing -join ', ')" -Fix 'Provision stage must contain: checkout:self → Bicep provisioning (AzureCLI@2)'
    }
} elseif ($deploySection) {
    # No Provision stage but Deploy stage exists — wrong structure
    Add-CheckResult -Id 'PA-27' -Name 'Stage Step Ordering' -Status FAIL -Message 'No Provision stage found — Bicep must run in a separate Provision stage before Deploy' -Fix 'Split Deploy stage: move Bicep provisioning into a new Provision stage with dependsOn: Build'
} else {
    Add-CheckResult -Id 'PA-27' -Name 'Stage Step Ordering' -Status SKIP -Message 'No Provision or Deploy stages found for ordering validation'
}

Write-Output "" | Out-Host
Write-Output "" | Out-Host

# ── Pool validation ──────────────────────────────────────
# All app types must use 1ES-BuildPool with os: windows (Linux image not yet ready)
$poolOsMatch = [regex]::Match($yamlContent, 'pool:\s*\n\s*name:\s*1ES-BuildPool\s*\n\s*os:\s*(\S+)')
if ($poolOsMatch.Success) {
    $actualOs = $poolOsMatch.Groups[1].Value
    if ($actualOs -eq 'windows') {
        Add-CheckResult -Id 'PA-28' -Name 'Pool OS Match' -Status PASS -Message "Pool OS 'windows' matches expected configuration for '$AppType'"
    } else {
        Add-CheckResult -Id 'PA-28' -Name 'Pool OS Match' -Status FAIL -Message "Pool OS '$actualOs' does not match expected 'windows' for '$AppType'" -Fix "Change pool.os to 'windows'"
    }
} elseif ($yamlContent -match 'name:\s*1ES-BuildPool-Ubuntu') {
    Add-CheckResult -Id 'PA-28' -Name 'Pool OS Match' -Status FAIL -Message "Pool uses 1ES-BuildPool-Ubuntu but Linux image is not yet ready — all app types must use 1ES-BuildPool with os: windows" -Fix 'Change pool to name: 1ES-BuildPool with os: windows'
} elseif ($yamlContent -match 'name:\s*1ES-BuildPool') {
    Add-CheckResult -Id 'PA-28' -Name 'Pool OS Match' -Status WARN -Message 'Pool name is 1ES-BuildPool but could not verify os value' -Fix "Ensure pool.os is set to 'windows'"
} else {
    Add-CheckResult -Id 'PA-28' -Name 'Pool OS Match' -Status FAIL -Message 'Pool name is not recognized' -Fix 'Set pool.name to 1ES-BuildPool with os: windows'
}

# ── PA-29: Package manager feed authentication ─────────────
# Validates that the pipeline has the correct authentication task BEFORE any
# package install/restore step, for whatever feed the project's package manager
# config file defines. This agent does NOT insert or reference any specific feed
# — it only ensures authentication is in place for the feed already configured.
#
# The feed auth task mapping:
#   Python  → PipAuthenticate@1 before pip install
#   .NET    → NuGetAuthenticate@1 before dotnet restore/build
#   Node.js → npmAuthenticate@0 before npm ci/install
#   Java    → MavenAuthenticate@0 before mvn/gradle

# Filter non-comment YAML for accurate matching
$yamlNonComment = ($yamlContent -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

# PA-29: Python feed auth
if ($AppType -eq 'Python' -or ($AppType -eq 'Functions' -and $yamlNonComment -match 'UsePythonVersion@0')) {
    if ($yamlNonComment -match 'PipAuthenticate@1') {
        Add-CheckResult -Id 'PA-29' -Name 'Feed Auth (Python)' -Status PASS -Message 'PipAuthenticate@1 present before pip install'
    } else {
        Add-CheckResult -Id 'PA-29' -Name 'Feed Auth (Python)' -Status FAIL `
            -Message 'Python pipeline missing PipAuthenticate@1 task — pip install will fail with feed auth errors' `
            -Fix 'Add a PipAuthenticate@1 task before any pip install step. Configure it with the feed from your pip.conf/pip.ini.'
    }
} else {
    Add-CheckResult -Id 'PA-29' -Name 'Feed Auth (Python)' -Status SKIP -Message 'Not a Python pipeline'
}

# PA-30: .NET feed auth
if ($AppType -in @('.NET', 'F#', 'VB.NET') -or ($AppType -eq 'Functions' -and $yamlNonComment -match 'DotNetCoreCLI@2|dotnet')) {
    if ($yamlNonComment -match 'NuGetAuthenticate@1') {
        Add-CheckResult -Id 'PA-30' -Name 'Feed Auth (.NET)' -Status PASS -Message 'NuGetAuthenticate@1 present before dotnet restore/build'
    } else {
        Add-CheckResult -Id 'PA-30' -Name 'Feed Auth (.NET)' -Status FAIL `
            -Message '.NET pipeline missing NuGetAuthenticate@1 task — dotnet restore will fail with feed auth errors' `
            -Fix 'Add a NuGetAuthenticate@1 task before any dotnet restore or build step. It will authenticate against the feed in your nuget.config.'
    }
} else {
    Add-CheckResult -Id 'PA-30' -Name 'Feed Auth (.NET)' -Status SKIP -Message 'Not a .NET pipeline'
}

# PA-31: Node.js feed auth
if ($AppType -in @('Node.js backend', 'Static frontend') -or ($AppType -eq 'Functions' -and $yamlNonComment -match 'NodeTool@0|npm')) {
    if ($yamlNonComment -match 'npmAuthenticate@0') {
        Add-CheckResult -Id 'PA-31' -Name 'Feed Auth (Node.js)' -Status PASS -Message 'npmAuthenticate@0 present before npm ci/install'
    } else {
        Add-CheckResult -Id 'PA-31' -Name 'Feed Auth (Node.js)' -Status FAIL `
            -Message 'Node.js pipeline missing npmAuthenticate@0 task — npm ci will fail with feed auth errors' `
            -Fix 'Add an npmAuthenticate@0 task before any npm ci or npm install step. Point it at your .npmrc file.'
    }
} else {
    Add-CheckResult -Id 'PA-31' -Name 'Feed Auth (Node.js)' -Status SKIP -Message 'Not a Node.js pipeline'
}

# PA-32: Java feed auth
if ($AppType -eq 'Java' -or ($AppType -eq 'Functions' -and $yamlNonComment -match 'Maven@4|Gradle@3')) {
    if ($yamlNonComment -match 'MavenAuthenticate@0') {
        Add-CheckResult -Id 'PA-32' -Name 'Feed Auth (Java)' -Status PASS -Message 'MavenAuthenticate@0 present before Maven/Gradle step'
    } else {
        Add-CheckResult -Id 'PA-32' -Name 'Feed Auth (Java)' -Status FAIL `
            -Message 'Java pipeline missing MavenAuthenticate@0 task — Maven/Gradle will fail with feed auth errors' `
            -Fix 'Add a MavenAuthenticate@0 task before any Maven or Gradle step. Configure it with your repository settings.'
    }
} else {
    Add-CheckResult -Id 'PA-32' -Name 'Feed Auth (Java)' -Status SKIP -Message 'Not a Java pipeline'
}

# ── PA-33: App Name Consistency — deploy task appName inputs must use variable references ──
# Validates purely within the pipeline YAML. No config.ps1 dependency.
# Same logic for single-component and multi-component pipelines:
#   - Any $(variableName) reference is valid in task inputs
#   - Any $[expression] is valid in task inputs
#   - Hardcoded literal app names in task inputs are rejected
#   - Variable DEFINITIONS (under `variables:`) are excluded — they legitimately set literal values
$pa33Issues = @()

# Find appName: lines that are task inputs (under `inputs:` blocks), not variable definitions.
# Task inputs are indented deeper (typically 12+ spaces) and appear after an `inputs:` line.
# Variable definitions appear at 2-4 spaces indentation under `variables:`.
# Strategy: find all `- task:` blocks and extract appName from their `inputs:` section.
$taskBlocks = [regex]::Matches($yamlContent, '(?s)-\s*task:\s*\S+.*?inputs:\s*\n((?:\s{10,}\S.*\n?)+)')
$taskAppNameCount = 0
foreach ($tb in $taskBlocks) {
    $inputsBlock = $tb.Groups[1].Value
    $appNameInputs = [regex]::Matches($inputsBlock, '(?m)^\s+appName:\s*(.+)$')
    foreach ($m in $appNameInputs) {
        $taskAppNameCount++
        $val = $m.Groups[1].Value.Trim().Trim("'""")
        # Any ADO variable reference: $(appName), $(apiAppName), $(funcAppName), etc.
        if ($val -match '^\$\(') { continue }
        # Any ADO expression: $[ stageDependencies.Provision... ]
        if ($val -match '^\$\[') { continue }
        # Hardcoded literal in a task input — reject
        $pa33Issues += "Deploy task has hardcoded appName='$val' — must use a pipeline variable reference like `$(appName)` or a Bicep output variable"
    }
}

# Also check az containerapp/webapp/functionapp commands for hardcoded --name
$cliNameArgs = [regex]::Matches($yamlContent, 'az\s+(?:containerapp|webapp|functionapp)\s+\w+.*?--name\s+([^\s\\]+)')
foreach ($m in $cliNameArgs) {
    $cliName = $m.Groups[1].Value.Trim()
    if ($cliName -match '^\$[\(\[]') { continue }
    $pa33Issues += "CLI command has hardcoded --name '$cliName' — must use a pipeline variable reference"
}

if ($taskAppNameCount -eq 0) {
    Add-CheckResult -Id 'PA-33' -Name 'App Name Consistency' -Status SKIP -Message 'No appName task inputs found in pipeline YAML'
} elseif ($pa33Issues.Count -eq 0) {
    Add-CheckResult -Id 'PA-33' -Name 'App Name Consistency' -Status PASS -Message "All $taskAppNameCount appName task input(s) use variable references — no hardcoded values"
} else {
    Add-CheckResult -Id 'PA-33' -Name 'App Name Consistency' -Status FAIL -Message ($pa33Issues -join '; ') `
        -Fix 'Replace hardcoded app names with pipeline variable references: $(appName) for single-component, or $(xxxAppName) backed by stageDependencies for multi-component.'
}

# ── PA-33b: Multi-module Bicep Output Flow ──
# For multi-component pipelines, verify that secondary Deploy stages derive app names
# from Provision stage outputs (stageDependencies) rather than hardcoded values.
if ($ComponentsJson) {
    $bicepNames = Get-BicepAppNames -WorkspacePath $WorkspacePath
    if ($bicepNames.Found -and $bicepNames.OutputCount -gt 0) {
        $outputFlowIssues = @()

        # Check that Provision AzureCLI task has name: bicepOutput
        $hasBicepOutputName = $yamlContent -match '(?m)^\s+name:\s*bicepOutput'
        if (-not $hasBicepOutputName) {
            $outputFlowIssues += "Provision stage AzureCLI task missing 'name: bicepOutput' — required for Deploy stages to consume outputs via stageDependencies"
        }

        # Check that Provision uses --name vsd-provision for retrievable deployment
        $hasDeploymentName = $yamlContent -match '--name\s+vsd-provision'
        if (-not $hasDeploymentName) {
            $outputFlowIssues += "Provision stage missing '--name vsd-provision' in az deployment group create — required for output retrieval"
        }

        # Find secondary Deploy stages and verify they use stageDependencies for app names
        $deployStageMatches = [regex]::Matches($yamlContent, '(?m)^-\s*stage:\s*(Deploy_\w+)')
        foreach ($dsm in $deployStageMatches) {
            $stageName = $dsm.Groups[1].Value
            # Extract the block for this stage (up to the next stage or EOF)
            $stagePattern = "(?s)stage:\s*$stageName\b(.+?)(?=^-\s*stage:|\z)"
            $stageBlock = [regex]::Match($yamlContent, $stagePattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($stageBlock.Success) {
                $block = $stageBlock.Groups[1].Value
                # Check if appName or similar is set via stageDependencies
                $usesOutputs = $block -match "stageDependencies\.Provision\.ProvisionJob\.outputs\["
                # Check for hardcoded appName values (not $(appName) and not stageDependencies)
                $hardcodedNames = [regex]::Matches($block, "(?m)appName:\s*'([^'$]+)'")
                foreach ($hc in $hardcodedNames) {
                    $hardVal = $hc.Groups[1].Value
                    if ($hardVal -ne '$(appName)' -and -not $usesOutputs) {
                        $outputFlowIssues += "Secondary stage '$stageName' has hardcoded appName='$hardVal' — must derive from Provision outputs via stageDependencies"
                    }
                }
                if (-not $usesOutputs) {
                    $outputFlowIssues += "Secondary stage '$stageName' does not reference stageDependencies.Provision for app name — must use Bicep output flow"
                }
            }
        }

        if ($outputFlowIssues.Count -eq 0) {
            Add-CheckResult -Id 'PA-33b' -Name 'Multi-Module Output Flow' -Status PASS `
                -Message "Bicep outputs ($($bicepNames.Outputs.Keys -join ', ')) correctly flow from Provision to Deploy stages"
        } else {
            Add-CheckResult -Id 'PA-33b' -Name 'Multi-Module Output Flow' -Status FAIL `
                -Message ($outputFlowIssues -join '; ') `
                -Fix "Ensure Provision stage has 'name: bicepOutput' and '--name vsd-provision', and secondary Deploy stages use `stageDependencies.Provision.ProvisionJob.outputs['bicepOutput.<outputName>']` for app names"
        }
    } elseif (-not $bicepNames.Found) {
        Add-CheckResult -Id 'PA-33b' -Name 'Multi-Module Output Flow' -Status WARN `
            -Message "Multi-component pipeline detected but main.bicep has no app-name outputs — secondary Deploy stages cannot derive app names from Provision" `
            -Fix 'Add output declarations to main.bicep for each component app name (e.g., output functionAppName string = funcApp.name)'
    }
}

# ════════════════════════════════════════════════════════════
# MULTI-COMPONENT CHECKS (PA-34 through PA-39)
# Runs when ComponentsJson is provided OR workspace manifest has secondary components
# ════════════════════════════════════════════════════════════

$script:Components = @()
if ($ComponentsJson) {
    try {
        $script:Components = $ComponentsJson | ConvertFrom-Json -ErrorAction Stop
        if ($script:Components -isnot [System.Array]) { $script:Components = @($script:Components) }
    } catch {
        Write-Warning "Failed to parse ComponentsJson: $($_.Exception.Message)"
        $script:Components = @()
    }
}

# Fallback: auto-read workspace manifest if -ComponentsJson was not provided
if ($script:Components.Count -eq 0 -and -not $ComponentsJson) {
    $manifestPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'workspace-manifest.json'
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($manifest.components -and $manifest.components.Count -gt 0) {
                $script:Components = @($manifest.components)
                Write-Output "  Auto-discovered $($script:Components.Count) secondary component(s) from workspace manifest" | Out-Host
            }
        } catch {
            Write-Warning "Failed to parse workspace manifest: $($_.Exception.Message)"
        }
    }
}

if ($script:Components.Count -gt 0) {
    Write-Output "" | Out-Host
    Write-Output "  Components: $($script:Components.Count) secondary component(s) detected" | Out-Host
    foreach ($comp in $script:Components) {
        Write-Output "    - $($comp.AppType) → $($comp.TargetAzureService) at $($comp.ComponentPath)" | Out-Host
    }
    Write-Output "" | Out-Host

    # PA-34: Each secondary component has its own Build stage with a unique name
    $pa34Issues = @()
    foreach ($comp in $script:Components) {
        $suffix = $comp.AppType -replace '[^A-Za-z0-9]', ''
        # Look for stage names like Build_Functions, Build_Container, etc.
        $buildStagePattern = "(?i)stage:\s*Build[_\-]$suffix"
        if (-not ($yamlContent -match $buildStagePattern)) {
            $pa34Issues += "Missing Build stage for secondary component '$($comp.AppType)' (expected stage name like 'Build_$suffix')"
        }
    }
    if ($pa34Issues.Count -eq 0) {
        Add-CheckResult -Id 'PA-34' -Name 'Secondary Build Stages' -Status PASS -Message "Each secondary component has its own Build stage"
    } else {
        Add-CheckResult -Id 'PA-34' -Name 'Secondary Build Stages' -Status FAIL -Message ($pa34Issues -join '; ') `
            -Fix 'Add a separate Build stage for each secondary component with a unique stage name (e.g., Build_Functions)'
    }

    # PA-35: Each secondary Build stage sets workingDirectory to ComponentPath
    $pa35Issues = @()
    foreach ($comp in $script:Components) {
        $suffix = $comp.AppType -replace '[^A-Za-z0-9]', ''
        $buildStagePattern = "(?si)stage:\s*Build[_\-]$suffix.*?(?=stage:|$)"
        $buildMatch = [regex]::Match($yamlContent, $buildStagePattern)
        if ($buildMatch.Success) {
            $stageBlock = $buildMatch.Value
            $expectedPath = [regex]::Escape($comp.ComponentPath)
            if ($stageBlock -notmatch "workingDirectory.*$expectedPath") {
                $pa35Issues += "Build stage for '$($comp.AppType)' does not set workingDirectory to '$($comp.ComponentPath)'"
            }
        }
        # If build stage not found, PA-34 already flags it — skip here
    }
    if ($pa35Issues.Count -eq 0) {
        Add-CheckResult -Id 'PA-35' -Name 'Secondary Build workingDirectory' -Status PASS -Message "Each secondary Build stage uses the correct workingDirectory"
    } else {
        Add-CheckResult -Id 'PA-35' -Name 'Secondary Build workingDirectory' -Status FAIL -Message ($pa35Issues -join '; ') `
            -Fix 'Set workingDirectory in each secondary Build stage to the ComponentPath from workspace analysis'
    }

    # PA-36: Each secondary component has its own Deploy stage with the correct deploy task
    $deployTaskMap = @{
        'AppService'    = 'AzureWebApp@1'
        'Functions'     = 'AzureFunctionApp@2'
        'ContainerApps' = 'AzureContainerApps@1'
        'StaticWebApps' = 'AzureStaticWebApp@0'
    }
    $pa36Issues = @()
    foreach ($comp in $script:Components) {
        $suffix = $comp.AppType -replace '[^A-Za-z0-9]', ''
        $deployStagePattern = "(?si)stage:\s*Deploy[_\-]$suffix.*?(?=stage:|$)"
        $deployMatch = [regex]::Match($yamlContent, $deployStagePattern)
        if (-not $deployMatch.Success) {
            $pa36Issues += "Missing Deploy stage for secondary component '$($comp.AppType)' (expected stage name like 'Deploy_$suffix')"
        } else {
            $expectedTask = $deployTaskMap[$comp.TargetAzureService]
            if ($expectedTask -and $deployMatch.Value -notmatch [regex]::Escape($expectedTask)) {
                $pa36Issues += "Deploy stage for '$($comp.AppType)' missing expected deploy task '$expectedTask'"
            }
        }
    }
    if ($pa36Issues.Count -eq 0) {
        Add-CheckResult -Id 'PA-36' -Name 'Secondary Deploy Stages' -Status PASS -Message "Each secondary component has its own Deploy stage with correct deploy task"
    } else {
        Add-CheckResult -Id 'PA-36' -Name 'Secondary Deploy Stages' -Status FAIL -Message ($pa36Issues -join '; ') `
            -Fix 'Add a separate Deploy stage per secondary component with the correct Azure deploy task for its TargetAzureService'
    }

    # PA-37: Artifact names are unique across all Build/Deploy stage pairs
    $artifactNames = @([regex]::Matches($yamlContent, '(?i)artifact:\s*([^\s\n]+)') | ForEach-Object { $_.Groups[1].Value })
    $publishArtifacts = @([regex]::Matches($yamlContent, '(?si)PublishPipelineArtifact@1.*?artifact:\s*([^\s\n]+)') |
        ForEach-Object { $_.Groups[1].Value })
    # Fallback: just collect all artifact: values
    if ($publishArtifacts.Count -eq 0) { $publishArtifacts = $artifactNames }
    $uniqueArtifacts = @($publishArtifacts | Select-Object -Unique)
    if ($publishArtifacts.Count -eq $uniqueArtifacts.Count) {
        Add-CheckResult -Id 'PA-37' -Name 'Unique Artifact Names' -Status PASS -Message "All artifact names are unique: $($uniqueArtifacts -join ', ')"
    } else {
        $duplicates = $publishArtifacts | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
        Add-CheckResult -Id 'PA-37' -Name 'Unique Artifact Names' -Status FAIL `
            -Message "Duplicate artifact name(s): $($duplicates -join ', ')" `
            -Fix 'Each Build/Deploy pair must use a unique artifact name (e.g., drop, drop-functions)'
    }

    # PA-38: Provision stage dependsOn includes ALL Build stages
    $allBuildStages = @('Build')
    foreach ($comp in $script:Components) {
        $suffix = $comp.AppType -replace '[^A-Za-z0-9]', ''
        $allBuildStages += "Build_$suffix"
    }
    $provisionSection38 = ''
    if ($yamlContent -match '(?si)(stage:\s*Provision.*?(?=stage:|$))') {
        $provisionSection38 = $Matches[1]
    }
    $pa38Pass = $true
    $pa38Missing = @()
    if ($provisionSection38) {
        # Extract just the dependsOn block (list or inline value)
        $dependsOnBlock = ''
        if ($provisionSection38 -match '(?si)dependsOn:\s*((?:-\s*\S+\s*)+)') {
            $dependsOnBlock = $Matches[1]
        } elseif ($provisionSection38 -match '(?i)dependsOn:\s*(\S+)') {
            $dependsOnBlock = $Matches[1]
        }
        foreach ($bs in $allBuildStages) {
            if ($dependsOnBlock -notmatch [regex]::Escape($bs)) {
                $pa38Pass = $false
                $pa38Missing += $bs
            }
        }
    } else {
        $pa38Pass = $false
        $pa38Missing = @('Provision stage not found')
    }
    if ($pa38Pass) {
        Add-CheckResult -Id 'PA-38' -Name 'Provision dependsOn All Builds' -Status PASS -Message "Provision stage depends on all Build stages: $($allBuildStages -join ', ')"
    } else {
        Add-CheckResult -Id 'PA-38' -Name 'Provision dependsOn All Builds' -Status FAIL `
            -Message "Provision stage missing dependsOn for: $($pa38Missing -join ', ')" `
            -Fix "Set Provision stage dependsOn to include all Build stages: [$($allBuildStages -join ', ')]"
    }

    # PA-39: Each Deploy stage dependsOn Provision
    $pa39Issues = @()
    foreach ($comp in $script:Components) {
        $suffix = $comp.AppType -replace '[^A-Za-z0-9]', ''
        $deployStagePattern = "(?si)stage:\s*Deploy[_\-]$suffix.*?(?=stage:|$)"
        $deployMatch = [regex]::Match($yamlContent, $deployStagePattern)
        if ($deployMatch.Success) {
            if ($deployMatch.Value -notmatch 'dependsOn.*Provision') {
                $pa39Issues += "Deploy_$suffix stage missing dependsOn: Provision"
            }
        }
        # Missing stage already flagged by PA-36
    }
    if ($pa39Issues.Count -eq 0) {
        Add-CheckResult -Id 'PA-39' -Name 'Deploy Stages dependsOn Provision' -Status PASS -Message "All Deploy stages depend on Provision"
    } else {
        Add-CheckResult -Id 'PA-39' -Name 'Deploy Stages dependsOn Provision' -Status FAIL -Message ($pa39Issues -join '; ') `
            -Fix 'Set dependsOn: Provision on every Deploy stage'
    }
} else {
    # No secondary components — skip PA-34 through PA-39
    foreach ($paId in @('PA-34','PA-35','PA-36','PA-37','PA-38','PA-39')) {
        $paNames = @{
            'PA-34' = 'Secondary Build Stages'
            'PA-35' = 'Secondary Build workingDirectory'
            'PA-36' = 'Secondary Deploy Stages'
            'PA-37' = 'Unique Artifact Names'
            'PA-38' = 'Provision dependsOn All Builds'
            'PA-39' = 'Deploy Stages dependsOn Provision'
        }
        Add-CheckResult -Id $paId -Name $paNames[$paId] -Status SKIP -Message 'No secondary components — single-component pipeline'
    }
}

# ══════════════════════════════════════════════════════════════
# PA-40: Windows cmd.exe Quoting — detect bare `- script:` on Windows pools
# ══════════════════════════════════════════════════════════════
Assert-NotTimedOut
$isWindowsPool = $yamlContent -match 'os:\s*(windows|Windows)'
$bareScriptTasks = [regex]::Matches($yamlContent, '(?m)^(\s*)- script:\s*(.+)')

if (-not $isWindowsPool) {
    Add-CheckResult -Id 'PA-40' -Name 'Windows cmd.exe Quoting' -Status PASS `
        -Message 'Pool OS is not Windows — cmd.exe quoting not applicable'
} elseif ($bareScriptTasks.Count -eq 0) {
    Add-CheckResult -Id 'PA-40' -Name 'Windows cmd.exe Quoting' -Status PASS `
        -Message 'No bare script: tasks found — no cmd.exe quoting risk'
} else {
    # Check if any bare script: tasks contain $(...) variable expansions
    $riskyScripts = @()
    foreach ($m in $bareScriptTasks) {
        $scriptLine = $m.Groups[2].Value
        if ($scriptLine -match '\$\(') {
            $riskyScripts += $scriptLine.Trim()
        }
    }
    # Also check multi-line script: blocks
    $multiLineScripts = [regex]::Matches($yamlContent, '(?ms)^(\s*)- script:\s*\|\s*\n((?:\1\s+.+\n?)+)')
    foreach ($ml in $multiLineScripts) {
        $block = $ml.Groups[2].Value
        if ($block -match '\$\(') {
            $riskyScripts += ('(multi-line) ' + ($block -split "`n" | Select-Object -First 1).Trim())
        }
    }

    if ($riskyScripts.Count -gt 0) {
        if ($AutoFix) {
            # Auto-fix: replace bare `- script:` with `- pwsh:` in the pipeline YAML
            $pipelineFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
            if (Test-Path $pipelineFullPath) {
                $originalYaml = Get-Content $pipelineFullPath -Raw
                # Replace single-line: `- script: <cmd>` → `- pwsh: <cmd>`
                $fixedYaml = $originalYaml -replace '(?m)^(\s*)- script:\s*(.+)', '$1- pwsh: $2'
                # Replace multi-line: `- script: |` → `- pwsh: |`
                $fixedYaml = $fixedYaml -replace '(?m)^(\s*)- script:\s*\|', '$1- pwsh: |'
                $fixedYaml | Set-Content $pipelineFullPath -NoNewline
                Add-CheckResult -Id 'PA-40' -Name 'Windows cmd.exe Quoting' -Status PASS `
                    -Message "Auto-fixed $($riskyScripts.Count) bare script: task(s) → pwsh: to avoid cmd.exe quoting issues on Windows pool"
            } else {
                Add-CheckResult -Id 'PA-40' -Name 'Windows cmd.exe Quoting' -Status WARN `
                    -Message "Found $($riskyScripts.Count) risky script: task(s) but pipeline file not found for auto-fix at $pipelineFullPath" `
                    -Fix 'Replace `- script:` with `- pwsh:` for tasks that use $(variable) syntax on Windows pools.'
            }
        } else {
            Add-CheckResult -Id 'PA-40' -Name 'Windows cmd.exe Quoting' -Status WARN `
                -Message "Found $($riskyScripts.Count) bare script: task(s) on a Windows pool using `$(...)` — cmd.exe mishandles variable expansion. Use pwsh: instead." `
                -Fix 'Replace `- script:` with `- pwsh:` for tasks that use $(variable) syntax on Windows pools, or re-run with -AutoFix to apply automatically.'
        }
    } else {
        Add-CheckResult -Id 'PA-40' -Name 'Windows cmd.exe Quoting' -Status PASS `
            -Message "Found $($bareScriptTasks.Count) bare script: task(s) on Windows pool but none use `$(...)` — no quoting risk"
    }
}

# ── PA-41: SWA SKU validation for linked backends (IL-3) ──
if ($TargetAzureService -eq 'StaticWebApps') {
    $bicepPath = Join-Path -Path $WorkspacePath -ChildPath 'infra' 'main.bicep'
    if (Test-Path $bicepPath) {
        $bicepContent = Get-Content $bicepPath -Raw -ErrorAction SilentlyContinue
        $hasLinkedBackend = $bicepContent -match 'linkedBackends|Microsoft\.Web/staticSites/linkedBackends'
        if ($hasLinkedBackend) {
            $hasFreeSku = $bicepContent -match "(?i)(sku|skuName)\s*[:=]\s*['""]?Free['""]?"
            if ($hasFreeSku) {
                Add-CheckResult -Id 'PA-41' -Name 'SWA SKU for Linked Backend' -Status FAIL `
                    -Message 'Bicep uses SWA Free SKU with linkedBackends — Free tier does not support linked backends' `
                    -Fix "Change SWA SKU to 'Standard' in infra/main.bicep. Free tier cannot use linkedBackends."
            } else {
                Add-CheckResult -Id 'PA-41' -Name 'SWA SKU for Linked Backend' -Status PASS `
                    -Message 'SWA with linked backends uses Standard or higher SKU'
            }
        } else {
            Add-CheckResult -Id 'PA-41' -Name 'SWA SKU for Linked Backend' -Status SKIP `
                -Message 'No linkedBackends resource found — SKU check not applicable'
        }
    } else {
        Add-CheckResult -Id 'PA-41' -Name 'SWA SKU for Linked Backend' -Status SKIP `
            -Message 'No Bicep file found at infra/main.bicep'
    }
} else {
    Add-CheckResult -Id 'PA-41' -Name 'SWA SKU for Linked Backend' -Status SKIP `
        -Message 'Not a Static Web App deployment'
}

# ── Emit SARIF ──────────────────────────────────────────────
$sarifScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\Write-SarifReport.ps1'
if (Test-Path $sarifScript) {
    $resultsJson = $script:Results | ForEach-Object {
        @{ id = $_.id; name = $_.name; status = $_.status; message = $_.message; fix = $_.fix }
    } | ConvertTo-Json -Depth 3 -Compress

    $global:LASTEXITCODE = 0
    & $sarifScript `
        -ToolName 'Pipeline Author Validation' `
        -ToolVersion '1.0.0' `
        -ResultsJson $resultsJson `
        -OutputPath $SarifPath
} else {
    Write-Warning "SARIF script not found at $sarifScript — skipping report generation."
}

# ── Summary ─────────────────────────────────────────────────
$passCount = @($script:Results | Where-Object { $_.status -eq 'PASS' }).Count
$failCount = @($script:Results | Where-Object { $_.status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.status -eq 'WARN' }).Count
$skipCount = @($script:Results | Where-Object { $_.status -eq 'SKIP' }).Count
$totalCount = @($script:Results).Count

Write-Output "" | Out-Host
Write-Output "  Summary: $passCount passed, $failCount failed, $warnCount warnings, $skipCount skipped (of $totalCount)" | Out-Host
Write-Output "  SARIF: $SarifPath" | Out-Host
Write-Output "" | Out-Host

# Output results for programmatic consumption (e.g., tests)
Write-Output $script:Results

exit $script:ExitCode
