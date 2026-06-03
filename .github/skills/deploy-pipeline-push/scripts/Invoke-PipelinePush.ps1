#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    VibeShield-Deploy pipeline push — validates, commits, pushes code and registers
    the Azure DevOps pipeline with zero interactive prompts.

.DESCRIPTION
    Runs all Code Push checks end-to-end: validates required files, checks .gitignore,
    detects sensitive/large files, stages and commits, pushes to Azure DevOps, registers
    (or reuses) the pipeline, authorizes the service connection for the pipeline, and
    confirms a run was triggered. All values are supplied as parameters so the script
    needs no user interaction.

    PRECONDITION: Before invoking this script, the calling agent MUST have completed:
    - PP-00a (Bicep Validity & Deployability Gate) — vibeshield-bicep confirmed all
      Bicep templates are valid and deployable, OR no Bicep files exist.
    - PP-00b (Pipeline Runability Validation) — deploy-pipeline-validation confirmed
      all PA-01 through PA-33 checks pass with no stage conflicts.
    These are agent-level gates, not script-level checks.

    Exit code 0 = all checks passed. Exit code 1 = one or more checks failed.

    Results are written to a SARIF file for machine-readable consumption.

.PARAMETER Email
    Microsoft email address (e.g. user@microsoft.com). Used to derive the service
    connection name sc-vibe-<prefix>-ARM.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL (e.g. https://dev.azure.com/myorg).

.PARAMETER AdoProject
    Azure DevOps project name.

.PARAMETER RepoName
    Azure DevOps repository name. If omitted, derived from workspace folder or git remote.

.PARAMETER AppType
    Detected application type (e.g. '.NET', 'Node.js backend', 'Container').
    Used to validate required files. If omitted, auto-detected from workspace files.

.PARAMETER CommitMessage
    Commit message. Defaults to 'chore: add 1ES deployment pipeline for Azure'.

.PARAMETER BranchName
    Branch to push. Defaults to 'main'.

.PARAMETER PipelineName
    Name for the ADO pipeline. Defaults to 'VibeShield-Deploy-<RepoName>'.

.PARAMETER PipelineYmlPath
    Relative path to the pipeline YAML file.
    Defaults to '.azdo/pipelines/azure-pipeline.yml'.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER SkipPush
    Skip the actual git push (dry-run mode). Useful for validation-only runs.

.PARAMETER SkipPipelineRegistration
    Skip pipeline creation/registration in Azure DevOps.

.PARAMETER SarifPath
    Output path for the SARIF results file.
    Defaults to .vibeshield/results/pipeline-push-results.sarif in the workspace.

.EXAMPLE
    ./.github/skills/deploy-pipeline-push/scripts/Invoke-PipelinePush.ps1 `
        -Email user@microsoft.com `
        -AdoOrgUrl https://dev.azure.com/oneCELA `
        -AdoProject CELA_Demos_and_POCs `
        -RepoName MyApp

.EXAMPLE
    # Dry-run: validate everything but don't push
    ./.github/skills/deploy-pipeline-push/scripts/Invoke-PipelinePush.ps1 `
        -Email user@microsoft.com `
        -AdoOrgUrl https://dev.azure.com/oneCELA `
        -AdoProject CELA_Demos_and_POCs `
        -SkipPush
#>
[CmdletBinding()]
param(
    [string]$Email,
    [string]$AdoOrgUrl,
    [string]$AdoProject,
    [string]$RepoName,
    [string]$AppType,
    [string]$CommitMessage,
    [string]$BranchName,
    [string]$PipelineName,
    [string]$PipelineYmlPath,
    [string]$WorkspacePath = $PWD.Path,
    [switch]$SkipPush,
    [switch]$SkipPipelineRegistration,
    [string]$SarifPath,
    [switch]$UpdateState,
    [string]$StateJson,
    [int]$SelectedPipelineId = 0,
    [ValidateSet('','author-new','run-existing','resume')]
    [string]$DeploymentIntent = '',
    [ValidateSet('','ARM','EV2')]
    [string]$InfraDeploy = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load testable functions ─────────────────────────────────
. (Join-Path -Path $PSScriptRoot -ChildPath 'PipelinePush.Functions.ps1')
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

# ── Input parameter validation ──────────────────────────────
$_pfArgs = @{}
if ($Email)      { $_pfArgs['Email'] = $Email }
if ($BranchName) { $_pfArgs['BranchName'] = $BranchName }
if ($_pfArgs.Count -gt 0) {
    $pf = Test-ParameterFormat @_pfArgs
    if (-not $pf.Valid) {
        Write-Error "Parameter validation failed: $($pf.Issues -join '; ')"
        $global:LASTEXITCODE = 1
        exit 1
    }
}

# ── Read defaults from deploy-config.json ───────────────────
try {
    $_cfg = Get-DeployConfig
} catch {
    Write-Warning "Could not load deploy-config.json: $($_.Exception.Message). Using built-in defaults."
    $_cfg = [pscustomobject]@{ pipeline = [pscustomobject]@{ defaultCommitMessage = 'VibeShield-Deploy: automated deployment'; defaultBranchName = 'vibeshield-deploy'; defaultYamlPath = '.azdo/pipelines/azure-pipeline.yml' } }
}
if (-not $CommitMessage)  { $CommitMessage  = $_cfg.pipeline.defaultCommitMessage }
if (-not $BranchName)     { $BranchName     = $_cfg.pipeline.defaultBranchName }
if (-not $PipelineYmlPath){ $PipelineYmlPath = Get-PipelineYamlRelPath -WorkspacePath $WorkspacePath }

# ── Resolve parameters via Get-DeployContext ────────────────
$overrides = @{}
if ($Email)     { $overrides['Email']      = $Email }
if ($AdoOrgUrl) { $overrides['AdoOrgUrl']  = $AdoOrgUrl }
if ($AdoProject){ $overrides['AdoProject'] = $AdoProject }
if ($RepoName)  { $overrides['RepoName']   = $RepoName }
if ($AppType)   { $overrides['AppType']    = $AppType }

try {
    $deployCtx = Get-DeployContext -WorkspacePath $WorkspacePath -Overrides $overrides
} catch {
    Write-Error "Failed to resolve deployment context: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
    exit 1
}

$Email      = $deployCtx.Email
$AdoOrgUrl  = $deployCtx.AdoOrgUrl
$AdoProject = $deployCtx.AdoProject
$RepoName   = $deployCtx.RepoName

# ── Resolve InfraDeploy (ARM vs EV2) ───────────────────────
# Priority 1: explicit parameter (from orchestrator or CLI)
# Priority 2: project-config.json pipeline entry
# Priority 3: auto-detect from pipeline YAML (legacy fallback)
if (-not $InfraDeploy) {
    $projCfg = try { Get-ProjectConfig -WorkspacePath $WorkspacePath } catch { $null }
    if ($projCfg -and $projCfg.PSObject.Properties['pipelines']) {
        $pipelineMatch = @($projCfg.pipelines | Where-Object {
            $_.PSObject.Properties['name'] -and $_.name -eq $PipelineName
        }) | Select-Object -First 1
        if ($pipelineMatch -and $pipelineMatch.PSObject.Properties['infraDeploy']) {
            $InfraDeploy = $pipelineMatch.infraDeploy
        }
    }
}
if (-not $InfraDeploy) {
    $pipelineFullPathForDetect = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
    if (Test-Path $pipelineFullPathForDetect) {
        $yamlForDetect = Get-Content $pipelineFullPathForDetect -Raw
        if (Test-IsEv2Pipeline -PipelineContent $yamlForDetect) {
            $InfraDeploy = 'EV2'
        } else {
            $InfraDeploy = 'ARM'
        }
    } else {
        $InfraDeploy = 'ARM'
    }
}
Write-Output "  InfraDeploy: $InfraDeploy"
$AppType    = $deployCtx.AppType

if (-not $Email) {
    Write-Error 'Could not auto-detect email. Please provide -Email parameter.'
    $global:LASTEXITCODE = 1
    exit 1
}
if ($deployCtx.Source['Email'] -ne 'override') {
    Write-Output "Auto-detected email: $Email (source: $($deployCtx.Source['Email']))"
}

if (-not $AdoOrgUrl -or -not $AdoProject) {
    Write-Error 'Could not detect Azure DevOps org/project from git remote. Please provide -AdoOrgUrl and -AdoProject parameters.'
    $global:LASTEXITCODE = 1
    exit 1
}
if ($deployCtx.Source['AdoOrgUrl'] -ne 'override') {
    Write-Output "Auto-detected from context: Org=$AdoOrgUrl  Project=$AdoProject"
}

if (-not $PipelineName) { $PipelineName = "VibeShield-Deploy-$RepoName" }

# ── Derived naming (from deploy context) ────────────────────
$Username = $deployCtx.Username
$ScName   = $deployCtx.ServiceConnection

if (-not $AppType -or $AppType -eq 'Unknown') {
    Write-Output "Auto-detected app type: $AppType"
}

# ── Required files map (must NOT be git-ignored) ────────────
# Read core config files from deploy-config.json, then append push-specific
# lock files / auxiliary files that aren't part of app-type detection config.
$RequiredFilesMap = @{}
if ($_cfg.PSObject.Properties['appTypes'] -and $_cfg.appTypes) {
    foreach ($at in $_cfg.appTypes) {
        if ($at.name -and $at.configFiles) {
            $RequiredFilesMap[$at.name] = @($at.configFiles)
        }
    }
}
# Push-specific extras: lock files and auxiliary files that should be tracked
$_pushExtras = @{
    '.NET'             = @('*.sln', '*.slnx')
    'Node.js backend'  = @('package-lock.json', 'yarn.lock')
    'Static frontend'  = @('package-lock.json', 'yarn.lock')
    'Java'             = @('gradle.properties')
    'Container'        = @('.dockerignore')
}
foreach ($key in $_pushExtras.Keys) {
    if ($RequiredFilesMap.ContainsKey($key)) {
        $RequiredFilesMap[$key] = @($RequiredFilesMap[$key]) + @($_pushExtras[$key])
    } else {
        $RequiredFilesMap[$key] = @($_pushExtras[$key])
    }
}

# EV2-specific required files — validated when InfraDeploy=EV2
# These are EV2 deployment artifacts that must exist for the pipeline to succeed.
# Read from deploy-config.json ev2 section if available.
$script:Ev2RequiredFiles = @()
if ($_cfg.PSObject.Properties['ev2'] -and $_cfg.ev2.PSObject.Properties['requiredFiles']) {
    $script:Ev2RequiredFiles = @($_cfg.ev2.requiredFiles)
}
if ($script:Ev2RequiredFiles.Count -eq 0) {
    $script:Ev2RequiredFiles = @('RolloutSpec.json', 'ServiceModel.json')
}

# Patterns that should always be in .gitignore — read from deploy-config.json
$_safety = if ($_cfg.PSObject.Properties['safety'] -and $_cfg.safety) { $_cfg.safety } else { $null }
$ExcludePatterns = if ($_safety -and $_safety.PSObject.Properties['gitignoreExcludes']) { @($_safety.gitignoreExcludes) } else { @() }

# Sensitive file patterns that must never be committed
$SensitivePatterns = if ($_safety -and $_safety.PSObject.Properties['sensitiveFilePatterns']) { @($_safety.sensitiveFilePatterns) } else { @() }

# Large directory patterns that must never be committed
$LargeDirPatterns = if ($_safety -and $_safety.PSObject.Properties['largeDirPatterns']) { @($_safety.largeDirPatterns) } else { @() }

# ── Results collector ───────────────────────────────────────
$script:Results  = [System.Collections.ArrayList]::new()
$script:ExitCode = 0
$script:CommitSha = ''
$script:PipelineRunId = ''
$script:PipelineUrl = ''

$script:CheckNames = @{
    'PP-01' = 'Pipeline File Exists'
    'PP-02' = 'Required Files Tracked'
    'PP-02b' = 'App Name Consistency'
    'PP-03' = 'No Sensitive Files Staged'
    'PP-04' = 'Gitignore Sensible'
    'PP-05' = 'No Large Binaries'
    'PP-06' = 'Dry-Run Staging'
    'PP-06a' = 'Application Build & Tests'
    'PP-06b' = 'Bicep Build'
    'PP-06c' = 'Pipeline-Infrastructure Alignment'
    'PP-07' = 'Git Commit'
    'PP-08' = 'Git Push'
    'PP-09' = 'Pipeline Registration'
    'PP-09b' = 'Service Connection Authorized'
    'PP-09c' = 'EV2 Service Connection Authorized'
    'PP-10' = 'Pipeline Run Triggered'
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','WARN','SKIP')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Fix
    )
    $name = if ($script:CheckNames.ContainsKey($Id)) { $script:CheckNames[$Id] } else { "Check $Id" }
    $null = $script:Results.Add([pscustomobject]@{Id=$Id; Name=$name; Status=$Status; Message=$Message; Fix=$Fix})
    if ($Status -eq 'FAIL') { $script:ExitCode = 1 }

    $icon  = switch ($Status) { 'PASS' {'✅'} 'FAIL' {'❌'} 'WARN' {'⚠️'} 'SKIP' {'⏭️'} }
    $line  = "  $icon ${Id}: $name"
    if ($Status -ne 'PASS') { $line += " — $Message" }
    Write-Output $line

    # ── Structured log ──────────────────────────────────────
    $logLevel = switch ($Status) { 'PASS' {'info'} 'FAIL' {'error'} 'WARN' {'warn'} 'SKIP' {'info'} default {'info'} }
    if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
        Write-VsdLog -Message "$Id $name — $Message" -Category 'pipeline-push' -Level $logLevel `
            -Agent 'vibeshield-deploy-pipeline-push' -Skill 'deploy-pipeline-push' `
            -Script 'Invoke-PipelinePush.ps1' -CheckId $Id -Stage 3 `
            -WorkspacePath $WorkspacePath `
            -Extra @{ status = $Status; fix = if ($Fix) { $Fix } else { '' } }
    }
}

# ── Workspace ───────────────────────────────────────────────
$WorkspacePath = (Resolve-Path -Path $WorkspacePath -ErrorAction Stop).Path
Push-Location $WorkspacePath

try {

Write-Output ""
Write-Output "================================================================"
Write-Output "  VibeShield-Deploy Pipeline Push"
Write-Output "================================================================"
Write-Output ""
Write-Output "  Workspace       : $WorkspacePath"
Write-Output "  User            : $Username ($Email)"
Write-Output "  ADO Org         : $AdoOrgUrl"
Write-Output "  ADO Project     : $AdoProject"
Write-Output "  Repository      : $RepoName"
Write-Output "  App Type        : $AppType"
Write-Output "  Branch          : $BranchName"
Write-Output "  Pipeline        : $PipelineName"
Write-Output "  Pipeline YAML   : $PipelineYmlPath"
Write-Output "  Service Conn    : $ScName"
Write-Output ""

# ── Configure az devops defaults ───────────────────────────
# Sets the default org and project so az devops commands resolve identity correctly.
# Without this, az devops may fail with TF400813 / unresolved user identity.
Invoke-AzCommand 'devops', 'configure', '--defaults', "organization=$AdoOrgUrl", "project=$AdoProject" | Out-Null

# ── Inject ADO bearer token for git HTTP operations ────────
# Reuses the az login session already required for pipeline registration,
# service connection auth, and email detection — no extra user step needed.
$remoteUrl = (Invoke-GitCommand 'remote', 'get-url', 'origin').Output
if (-not (Get-AdoGitToken -RemoteUrl $remoteUrl)) {
    Write-Output "  ⚠️  Could not inject ADO bearer token — git push will rely on stored credentials."
    Write-Output "      If push fails (PP-08 auth error), run: az login"
}

# ════════════════════════════════════════════════════════════
# SECTION 0 — SC Existence Pre-Check
# ════════════════════════════════════════════════════════════
# Check if all service connections referenced in the pipeline YAML exist in ADO.
# Uses the shared Test-AllPipelineSCsExist from SharedHelpers (canonical implementation,
# shared with deploy-user-onboarding).
$script:AllSCsExist = $false
$pipelineFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
if (Test-Path $pipelineFullPath) {
    $_yamlContent = Get-Content $pipelineFullPath -Raw
    if ($AdoOrgUrl -and $AdoProject) {
        $scPreCheck = Test-AllPipelineSCsExist -YamlContent $_yamlContent -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
        if ($scPreCheck.TotalSCs -gt 0) {
            Write-Output "  [SC Pre-Check] Verifying $($scPreCheck.TotalSCs) service connection(s)..."
            foreach ($sc in $scPreCheck.FoundSCs) {
                Write-Output "    ✅ $($sc.Name)"
            }
            foreach ($sc in $scPreCheck.MissingSCs) {
                Write-Output "    ❌ $sc — not found"
            }
            $script:AllSCsExist = $scPreCheck.AllExist
            if ($scPreCheck.AllExist) {
                Write-Output "  ✅ All service connections verified — onboarding pipeline can be skipped"
            }
            Write-Output ""
        }
    }
}

# ════════════════════════════════════════════════════════════
# SECTION 1 — Pre-Push Validation (PP-01 through PP-06)
# ════════════════════════════════════════════════════════════
Write-Output "  Running checks:"

# ── PP-01: Pipeline file exists ────────────────────────────
$r = Test-PipelineFileExists -WorkspacePath $WorkspacePath -PipelineYmlPath $PipelineYmlPath
Add-Result -Id 'PP-01' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# ── PP-02: Required files tracked ──────────────────────────
$r = Test-RequiredFilesTracked -WorkspacePath $WorkspacePath -AppType $AppType -RequiredFilesMap $RequiredFilesMap
Add-Result -Id 'PP-02' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# ── PP-02 (EV2): EV2 deployment artifacts exist ───────────
if ($InfraDeploy -eq 'EV2') {
    $ev2Missing = @()
    foreach ($ev2File in $script:Ev2RequiredFiles) {
        $ev2Path = Get-ChildItem -Path $WorkspacePath -Filter $ev2File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ev2Path) { $ev2Missing += $ev2File }
    }
    if ($ev2Missing.Count -gt 0) {
        Add-Result -Id 'PP-02' -Status WARN `
            -Message "EV2 required files missing: $($ev2Missing -join ', ')" `
            -Fix "EV2 pipelines require these files in ev2/ServiceGroupRoot/. Run the EV2 artifact generator."
    } else {
        Add-Result -Id 'PP-02' -Status PASS -Message "EV2 deployment artifacts found ($($script:Ev2RequiredFiles -join ', '))"
    }
}

# ── PP-02b: App name consistency ───────────────────────────
$r = Test-AppNameConsistency -WorkspacePath $WorkspacePath -PipelineYmlPath $PipelineYmlPath
Add-Result -Id 'PP-02b' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# Get dry-run output for PP-03, PP-05, PP-06
$dryRunResult = Invoke-GitCommand 'add', '-A', '--dry-run'
$dryRunLines  = $dryRunResult.Output -split "`n" | Where-Object { $_ -match '\S' }

# ── PP-03: No sensitive files staged ───────────────────────
$r = Test-SensitiveFilesStaged -DryRunLines $dryRunLines -SensitivePatterns $SensitivePatterns
Add-Result -Id 'PP-03' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# ── PP-04: .gitignore is sensible ─────────────────────────
$r = Test-GitignoreContent -WorkspacePath $WorkspacePath -ExcludePatterns $ExcludePatterns
Add-Result -Id 'PP-04' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# ── PP-05: No large binaries staged ───────────────────────
$r = Test-LargeBinariesStaged -DryRunLines $dryRunLines -LargeDirPatterns $LargeDirPatterns
Add-Result -Id 'PP-05' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# ── PP-06: Dry-run staging summary ────────────────────────
$r = Get-StagingSummary -DryRunLines $dryRunLines
Add-Result -Id 'PP-06' -Status $r.Status -Message $r.Message -Fix $r['Fix']

# ════════════════════════════════════════════════════════════
# SECTION 1b — Build & Infrastructure Verification (PP-06a, PP-06b, PP-06c)
# These gates ensure the code and infrastructure are deployable before pushing.
# SKIPPED when DeploymentIntent=run-existing — the existing pipeline already
# has validated build/deploy stages. Only authoring (new pipeline) needs this.
# ════════════════════════════════════════════════════════════

$isRunExisting = ($DeploymentIntent -eq 'run-existing')

if ($isRunExisting) {
    Add-Result -Id 'PP-06a' -Status SKIP -Message 'Skipped — running existing pipeline (build validated at pipeline runtime)'
    Add-Result -Id 'PP-06b' -Status SKIP -Message 'Skipped — running existing pipeline (Bicep validated at pipeline runtime)'
    Add-Result -Id 'PP-06c' -Status SKIP -Message 'Skipped — running existing pipeline (deploy stage already defined)'
} else {

# ── PP-06a: Application builds and tests pass locally ─────
# Resolve confirmed module paths from workspace manifest so the build gate
# only verifies selected deployment modules (not the entire workspace).
# Filter to modules that have corresponding Build/Deploy stages in the pipeline
# YAML — unconfirmed modules (excluded by the user during workspace analysis)
# do not get pipeline stages and must not be build-gated.
$hasTests = $true  # default: assume tests exist
$modulePaths = @()  # list of confirmed module source paths
$manifestPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'workspace-manifest.json'
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.modules -and $manifest.modules.Count -gt 0) {
            # Read pipeline YAML to determine which modules have Build stages
            $pipelineFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
            $pipelineContent = if (Test-Path $pipelineFullPath) { Get-Content $pipelineFullPath -Raw } else { '' }

            foreach ($mod in $manifest.modules) {
                $modPath = if ($mod.path -eq '.') { $WorkspacePath } else { Join-Path -Path $WorkspacePath -ChildPath $mod.path }

                # Only include modules that have a corresponding stage in the pipeline YAML.
                # The primary module always has a 'Build' stage; secondary modules have 'Build_<suffix>'.
                $isRoot = ($mod.path -eq '.' -or $null -eq $mod.path)
                $modSlug = if (-not $isRoot -and $mod.path) { ($mod.path -replace '[^a-zA-Z0-9]', '_') } else { $null }
                $hasPipelineStage = $isRoot -or ($modSlug -and $pipelineContent -match "Build_$modSlug|stage:\s*Build_$modSlug")

                if ($hasPipelineStage -and (Test-Path $modPath)) {
                    $modulePaths += $modPath
                    if ($mod.tests -and $mod.tests.unit) { $hasTests = $true }
                }
            }
            if ($modulePaths.Count -eq 0) {
                $hasTests = [bool]($manifest.modules | Where-Object { $_.tests -and $_.tests.unit })
            }
        }
    } catch {
        Write-Warning "Could not parse workspace manifest: $_"
    }
}

# Run BV per confirmed module path (or once with no SourcePath as fallback)
if ($modulePaths.Count -gt 0) {
    $allBvPass = $true
    $bvMessages = @()
    $bvDetails = @()
    foreach ($modPath in $modulePaths) {
        $modName = if ($modPath -eq $WorkspacePath) { '.' } else { [System.IO.Path]::GetRelativePath($WorkspacePath, $modPath) }
        $buildGateArgs = @{
            WorkspacePath   = $WorkspacePath
            AppType         = $AppType
            PipelineYmlPath = $PipelineYmlPath
            HasTests        = $hasTests
            SourcePath      = $modPath
        }
        $r = Invoke-AppBuildGate @buildGateArgs
        if ($r.Status -eq 'FAIL') {
            $allBvPass = $false
            $bvMessages += "$modName — $($r.Message)"
        } else {
            $bvMessages += "$modName — PASS"
        }
        if ($r.Details) { $bvDetails += $r.Details }
    }
    if ($allBvPass) {
        Add-Result -Id 'PP-06a' -Status PASS -Message "All $($modulePaths.Count) confirmed module(s) build successfully"
    } else {
        $failSummary = ($bvMessages | Where-Object { $_ -match 'FAIL' }) -join '; '
        Add-Result -Id 'PP-06a' -Status FAIL -Message "Build verification failed: $failSummary" -Fix 'Fix build errors in the failing module(s) before pushing.'
    }
    foreach ($d in $bvDetails) {
        Write-Output "       └─ $($d.CheckId): [$($d.Status)] $($d.Message)"
    }
} else {
    # Fallback: no manifest — run once without SourcePath (legacy behavior)
    $r = Invoke-AppBuildGate -WorkspacePath $WorkspacePath -AppType $AppType -PipelineYmlPath $PipelineYmlPath -HasTests $hasTests
    Add-Result -Id 'PP-06a' -Status $r.Status -Message $r.Message -Fix $r['Fix']
    if ($r.Details) {
        foreach ($d in $r.Details) {
            Write-Output "       └─ $($d.CheckId): [$($d.Status)] $($d.Message)"
        }
    }
}

# ── PP-06b: Bicep templates compile ───────────────────────
if ($InfraDeploy -eq 'EV2') {
    Add-Result -Id 'PP-06b' -Status SKIP -Message 'EV2 pipeline — Bicep not used for deployment (EV2 uses ServiceGroupRoot ARM templates)'
} else {
    $r = Test-BicepBuildable -WorkspacePath $WorkspacePath -PipelineYmlPath $PipelineYmlPath
    Add-Result -Id 'PP-06b' -Status $r.Status -Message $r.Message -Fix $r['Fix']
}

# ── PP-06c: Pipeline deploy stage matches AppType & Bicep ─
$r = Test-PipelineInfraAlignment -WorkspacePath $WorkspacePath -AppType $AppType -PipelineYmlPath $PipelineYmlPath -InfraDeploy $InfraDeploy
Add-Result -Id 'PP-06c' -Status $r.Status -Message $r.Message -Fix $r['Fix']

} # end: else (not run-existing) — PP-06a/b/c block

# ════════════════════════════════════════════════════════════
# Abort if any pre-push validation failed
# ════════════════════════════════════════════════════════════
$preCheckFails = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($preCheckFails.Count -gt 0) {
    Write-Output ""
    Write-Output "  Pre-push validation failed. Skipping push and pipeline registration."
    Add-Result -Id 'PP-07' -Status SKIP -Message 'Skipped — pre-push validation failed'
    Add-Result -Id 'PP-08' -Status SKIP -Message 'Skipped — pre-push validation failed'
    Add-Result -Id 'PP-09' -Status SKIP -Message 'Skipped — pre-push validation failed'
    Add-Result -Id 'PP-09b' -Status SKIP -Message 'Skipped — pre-push validation failed'
    Add-Result -Id 'PP-10' -Status SKIP -Message 'Skipped — pre-push validation failed'
    # Fall through to SARIF output
} else {
    # ════════════════════════════════════════════════════════
    # SECTION 2 — Git Commit & Push (PP-07, PP-08)
    # ════════════════════════════════════════════════════════

    # ── Read state for branch reuse ────────────────────────
    $stateBranchName = ''
    $stateManagerPath = Join-Path -Path $WorkspacePath -ChildPath '.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1'
    if (Test-Path $stateManagerPath) {
        try {
            $global:LASTEXITCODE = 0
            $stateResult = & $stateManagerPath -Action Read -WorkspacePath $WorkspacePath
            if ($stateResult -and $stateResult.Found -and $stateResult.State) {
                $stateObj = $stateResult.State
                if ($stateObj.PSObject.Properties['BranchName'] -and $stateObj.BranchName) {
                    $stateBranchName = $stateObj.BranchName
                    Write-Output "  ℹ️ Found previously-pushed branch in state: $stateBranchName" | Out-Host
                }
            }
        } catch {
            Write-Output "  ℹ️ Could not read deploy state for branch reuse: $($_.Exception.Message)" | Out-Host
        }
    }

    # ── PP-07: Stage and commit ────────────────────────────
    $r = Invoke-GitCommitChanges -CommitMessage $CommitMessage
    Add-Result -Id 'PP-07' -Status $r.Status -Message $r.Message -Fix $r['Fix']
    $commitOk = ($r.Status -eq 'PASS')
    if ($r.ContainsKey('CommitSha') -and $r.CommitSha) { $script:CommitSha = $r.CommitSha }

    # ── PP-08: Push ────────────────────────────────────────
    if (-not $commitOk) {
        Add-Result -Id 'PP-08' -Status SKIP -Message 'Skipped — commit failed'
    } elseif ($SkipPush) {
        Add-Result -Id 'PP-08' -Status SKIP -Message 'Skipped — SkipPush flag set (dry-run mode)'
    } else {
        $r = Invoke-GitPushChanges -BranchName $BranchName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject `
            -StateBranchName $stateBranchName -AppType $AppType
        Add-Result -Id 'PP-08' -Status $r.Status -Message $r.Message -Fix $r['Fix']
        if ($r.ContainsKey('CommitSha') -and $r.CommitSha) { $script:CommitSha = $r.CommitSha }
        # Update BranchName if the function auto-renamed to avoid remote collision
        if ($r.ContainsKey('BranchName') -and $r.BranchName) { $BranchName = $r.BranchName }

        # Write SubStep checkpoint for resume after context reset
        if ($r.Status -in @('PASS','WARN')) {
            $stateManagerPath = Join-Path -Path $WorkspacePath -ChildPath '.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1'
            if (Test-Path $stateManagerPath) {
                $global:LASTEXITCODE = 0
                & $stateManagerPath -Action Write -WorkspacePath $WorkspacePath -State @{
                    LastCompletedStage = 2
                    SubStep            = 'pushed'
                    BranchName         = $BranchName
                    CommitSha          = $script:CommitSha
                    Timestamp          = (Get-Date -Format 'o')
                }
            }

            # Clean up stale local deploy/* branches from previous push cycles
            Remove-StaleDeployBranches -CurrentBranch $BranchName
        }
    }

    # ════════════════════════════════════════════════════════
    # SECTION 3 — Pipeline Registration & Authorization (PP-09, PP-09b, PP-10)
    # ════════════════════════════════════════════════════════

    $pushResult = $script:Results | Where-Object { $_.Id -eq 'PP-08' }
    $pushOk = $pushResult -and $pushResult.Status -in @('PASS','WARN')

    # ── PP-09: Register or reuse pipeline ──────────────────
    $pipelineDefId = $null
    if ($SkipPipelineRegistration -or $SkipPush) {
        Add-Result -Id 'PP-09' -Status SKIP -Message 'Skipped — SkipPipelineRegistration or SkipPush flag set'
    } elseif (-not $pushOk) {
        Add-Result -Id 'PP-09' -Status SKIP -Message 'Skipped — push did not succeed'
    } elseif ($SelectedPipelineId -gt 0) {
        # RUN EXISTING: pipeline already identified by intent detection — skip lookup
        $pipelineDefId = $SelectedPipelineId
        $script:PipelineUrl = "$AdoOrgUrl/$AdoProject/_build?definitionId=$pipelineDefId"
        Add-Result -Id 'PP-09' -Status PASS `
            -Message "Pipeline selected by user (ID: $pipelineDefId) — reusing existing definition"
    } else {
        $r = Register-Pipeline -PipelineName $PipelineName -RepoName $RepoName -BranchName $BranchName `
            -PipelineYmlPath $PipelineYmlPath -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
        Add-Result -Id 'PP-09' -Status $r.Status -Message $r.Message -Fix $r['Fix']
        if ($r.ContainsKey('PipelineUrl') -and $r.PipelineUrl) { $script:PipelineUrl = $r.PipelineUrl }
        if ($r.ContainsKey('PipelineId') -and $r.PipelineId) { $pipelineDefId = $r.PipelineId }

        # Write SubStep checkpoint after registration
        if ($r.Status -eq 'PASS' -and $pipelineDefId) {
            $stateManagerPath = Join-Path -Path $WorkspacePath -ChildPath '.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1'
            if (Test-Path $stateManagerPath) {
                $global:LASTEXITCODE = 0
                & $stateManagerPath -Action Write -WorkspacePath $WorkspacePath -State @{
                    LastCompletedStage = 2
                    SubStep            = 'registered'
                    BranchName         = $BranchName
                    CommitSha          = $script:CommitSha
                    PipelineName       = $PipelineName
                    PipelineId         = $pipelineDefId
                    Timestamp          = (Get-Date -Format 'o')
                }
            }
        }
    }

    # ── PP-09a: Verify reused pipeline definition matches expectations ──
    if ($pipelineDefId -and (Get-Command Test-PipelineDefinitionMatch -ErrorAction SilentlyContinue)) {
        $matchResult = Test-PipelineDefinitionMatch `
            -PipelineId $pipelineDefId `
            -ExpectedYamlPath $PipelineYmlPath `
            -ExpectedBranch $BranchName `
            -AdoOrgUrl $AdoOrgUrl `
            -AdoProject $AdoProject
        if ($matchResult.Status -eq 'WARN') {
            Write-Warning "PP-09a: $($matchResult.Message)"
            Add-Result -Id 'PP-09a' -Status WARN -Message $matchResult.Message
        } elseif ($matchResult.Status -eq 'PASS') {
            Add-Result -Id 'PP-09a' -Status PASS -Message $matchResult.Message
        }
        # SKIP: don't add a result (non-blocking — ADO query may fail in restricted environments)
    }

    # ── PP-09b: Authorize service connection for pipeline ──
    $regResult = $script:Results | Where-Object { $_.Id -eq 'PP-09' }
    $regOk = $regResult -and $regResult.Status -eq 'PASS'

    if ($SkipPipelineRegistration -or $SkipPush) {
        Add-Result -Id 'PP-09b' -Status SKIP -Message 'Skipped — SkipPipelineRegistration or SkipPush flag set'
    } elseif (-not $regOk -or -not $pipelineDefId) {
        Add-Result -Id 'PP-09b' -Status SKIP -Message 'Skipped — pipeline registration did not succeed'
    } elseif ($InfraDeploy -eq 'EV2') {
        # EV2 pipelines may not use the ARM SC — check if it's referenced
        $_yamlForScCheck = if (Test-Path (Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath)) { Get-Content (Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath) -Raw } else { '' }
        if ($_yamlForScCheck -match [regex]::Escape($ScName)) {
            $r = Authorize-ServiceConnection -ScName $ScName -PipelineId $pipelineDefId `
                -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
            Add-Result -Id 'PP-09b' -Status $r.Status -Message "ARM SC (referenced in EV2 pipeline): $($r.Message)" -Fix $r['Fix']
        } else {
            Add-Result -Id 'PP-09b' -Status SKIP -Message "EV2 pipeline — ARM SC '$ScName' not referenced in YAML"
        }
    } else {
        $r = Authorize-ServiceConnection -ScName $ScName -PipelineId $pipelineDefId `
            -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
        Add-Result -Id 'PP-09b' -Status $r.Status -Message $r.Message -Fix $r['Fix']
    }

    # ── PP-09c: Authorize EV2 service connection (if pipeline uses Ev2RARollout) ──
    $pipelineFullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
    $_pipelineYaml = if (Test-Path $pipelineFullPath) { Get-Content $pipelineFullPath -Raw } else { '' }
    $_isEv2Pipeline = Test-IsEv2Pipeline -PipelineContent $_pipelineYaml

    if (-not $_isEv2Pipeline) {
        Add-Result -Id 'PP-09c' -Status SKIP -Message 'Not an EV2 pipeline — no EV2 SC authorization needed'
    } elseif ($SkipPipelineRegistration -or $SkipPush -or -not $pipelineDefId) {
        Add-Result -Id 'PP-09c' -Status SKIP -Message 'Skipped — pipeline registration did not succeed or push skipped'
    } else {
        # Extract EV2 SC name from pipeline YAML (ConnectedServiceName input on Ev2RARollout task)
        $_ev2ScName = $null
        # Look for ConnectedServiceName with a literal value (cn-ev2deploy-...)
        if ($_pipelineYaml -match 'ConnectedServiceName:\s*''?([^''$\r\n]+)''?') {
            $_candidate = $Matches[1].Trim().Trim("'").Trim('"')
            if ($_candidate -match '^cn-ev2') { $_ev2ScName = $_candidate }
        }
        # If not found as literal, try variable reference: ConnectedServiceName: $(varName)
        if (-not $_ev2ScName -and $_pipelineYaml -match 'ConnectedServiceName:\s*''\$\((\w+)\)''') {
            $_varName = $Matches[1]
            if ($_pipelineYaml -match "(?m)^\s+${_varName}:\s*(.+)$") {
                $_candidate = $Matches[1].Trim().Trim("'").Trim('"')
                if ($_candidate -match '^cn-ev2') { $_ev2ScName = $_candidate }
            }
        }

        if (-not $_ev2ScName) {
            Add-Result -Id 'PP-09c' -Status WARN `
                -Message 'EV2 pipeline detected but could not extract EV2 SC name from ConnectedServiceName' `
                -Fix 'The pipeline will prompt for EV2 SC authorization on first run'
        } else {
            $r = Authorize-ServiceConnection -ScName $_ev2ScName -PipelineId $pipelineDefId `
                -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
            Add-Result -Id 'PP-09c' -Status $r.Status -Message "EV2 SC: $($r.Message)" -Fix $r['Fix']
        }
    }

    # ── PP-10: Verify pipeline run triggered ───────────────
    $null = $script:Results | Where-Object { $_.Id -eq 'PP-09b' }

    if ($SkipPipelineRegistration -or $SkipPush) {
        Add-Result -Id 'PP-10' -Status SKIP -Message 'Skipped — SkipPipelineRegistration or SkipPush flag set'
    } elseif (-not $regOk) {
        Add-Result -Id 'PP-10' -Status SKIP -Message 'Skipped — pipeline registration did not succeed'
    } else {
        $triggerArgs = @{
            PipelineName = $PipelineName
            BranchName   = $BranchName
            AdoOrgUrl    = $AdoOrgUrl
            AdoProject   = $AdoProject
        }
        if ($pipelineDefId) { $triggerArgs['PipelineId'] = $pipelineDefId }
        if ($script:CommitSha) { $triggerArgs['CommitSha'] = $script:CommitSha }
        $r = Confirm-PipelineTriggered @triggerArgs
        Add-Result -Id 'PP-10' -Status $r.Status -Message $r.Message -Fix $r['Fix']
        if ($r.ContainsKey('PipelineRunId') -and $r.PipelineRunId) { $script:PipelineRunId = $r.PipelineRunId }
        if ($r.ContainsKey('PipelineRunUrl') -and $r.PipelineRunUrl) { $script:PipelineUrl = $r.PipelineRunUrl }

        # Write final SubStep checkpoint with RunId for monitor resume
        if ($r.Status -in @('PASS','WARN') -and $script:PipelineRunId) {
            $stateManagerPath = Join-Path -Path $WorkspacePath -ChildPath '.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1'
            if (Test-Path $stateManagerPath) {
                $stateToWrite = @{
                    LastCompletedStage = 3
                    SubStep            = 'triggered'
                    BranchName         = $BranchName
                    CommitSha          = $script:CommitSha
                    PipelineName       = $PipelineName
                    PipelineRunId      = $script:PipelineRunId
                    Timestamp          = (Get-Date -Format 'o')
                }
                if ($pipelineDefId) { $stateToWrite['PipelineId'] = $pipelineDefId }
                $global:LASTEXITCODE = 0
                & $stateManagerPath -Action Write -WorkspacePath $WorkspacePath -State $stateToWrite
            }
        }
    }
}

Write-Output ""

# ════════════════════════════════════════════════════════════
# SARIF Output
# ════════════════════════════════════════════════════════════
$total   = $script:Results.Count
$passed  = @($script:Results | Where-Object Status -eq 'PASS').Count
$failed  = @($script:Results | Where-Object Status -eq 'FAIL').Count
$warned  = @($script:Results | Where-Object Status -eq 'WARN').Count
$skipped = @($script:Results | Where-Object Status -eq 'SKIP').Count

$failures = @($script:Results | Where-Object Status -eq 'FAIL')
$warnings = @($script:Results | Where-Object Status -eq 'WARN')

if (-not $SarifPath) {
    $SarifPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'pipeline-push-results.sarif'
}
Initialize-SarifCleanStart -SarifPath $SarifPath

# Build SARIF via the shared helper script
$sarifHelperPath = Join-Path -Path $WorkspacePath -ChildPath '.github/scripts/Write-SarifReport.ps1'
if (Test-Path $sarifHelperPath) {
    $resultsJsonArr = $script:Results | ForEach-Object {
        [ordered]@{
            id      = $_.Id
            name    = $_.Name
            status  = $_.Status
            message = $_.Message
            fix     = $_.Fix
        }
    }
    $resultsJson = $resultsJsonArr | ConvertTo-Json -Depth 5

    $propsObj = [ordered]@{
        appType       = $AppType
        branch        = $BranchName
        commitSha     = $script:CommitSha
        pipelineRunId = $script:PipelineRunId
        pipelineUrl   = $script:PipelineUrl
    }
    $propsJson = $propsObj | ConvertTo-Json -Depth 3 -Compress

    $global:LASTEXITCODE = 0
    & $sarifHelperPath `
        -ToolName 'Pipeline Push' `
        -ResultsJson $resultsJson `
        -OutputPath $SarifPath `
        -PropertiesJson $propsJson
} else {
    # Fallback: inline SARIF generation (same pattern as preflight script)
    $sarifRules   = [System.Collections.ArrayList]::new()
    $sarifResults = [System.Collections.ArrayList]::new()

    foreach ($r in $script:Results) {
        $level = switch ($r.Status) {
            'FAIL' { 'error' }
            'WARN' { 'warning' }
            'PASS' { 'note' }
            'SKIP' { 'none' }
        }

        $ruleId = "vibeshield/$($r.Id)"

        if (-not ($sarifRules | Where-Object { $_.id -eq $ruleId })) {
            $ruleObj = [ordered]@{
                id               = $ruleId
                name             = $r.Name
                shortDescription = [ordered]@{ text = $r.Name }
            }
            $null = $sarifRules.Add($ruleObj)
        }

        $msgText = $r.Message
        if ($r.Fix) { $msgText += "`nFix: $($r.Fix)" }

        $resultObj = [ordered]@{
            ruleId     = $ruleId
            level      = $level
            message    = [ordered]@{ text = $msgText }
            properties = [ordered]@{
                status    = $r.Status
                checkId   = $r.Id
                checkName = $r.Name
            }
        }
        if ($r.Fix) { $resultObj.properties.fix = $r.Fix }
        $null = $sarifResults.Add($resultObj)
    }

    $sarifDoc = [ordered]@{
        '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            [ordered]@{
                tool = [ordered]@{
                    driver = [ordered]@{
                        name           = 'VibeShield-Deploy Pipeline Push'
                        version        = '1.0.0'
                        informationUri = $_cfg.ado.sourceRepoUrl
                        rules          = @($sarifRules)
                    }
                }
                results     = @($sarifResults)
                invocations = @(
                    [ordered]@{
                        executionSuccessful = ($script:ExitCode -eq 0)
                        properties          = [ordered]@{
                            total         = $total
                            passed        = $passed
                            failed        = $failed
                            warned        = $warned
                            skipped       = $skipped
                            appType       = $AppType
                            commitSha     = $script:CommitSha
                            pipelineRunId = $script:PipelineRunId
                            pipelineUrl   = $script:PipelineUrl
                        }
                    }
                )
                properties  = [ordered]@{
                    total         = $total
                    passed        = $passed
                    failed        = $failed
                    warned        = $warned
                    skipped       = $skipped
                    appType       = $AppType
                    commitSha     = $script:CommitSha
                    pipelineRunId = $script:PipelineRunId
                    pipelineUrl   = $script:PipelineUrl
                }
            }
        )
    }

    $sarifDir = Split-Path -Path $SarifPath -Parent
    if ($sarifDir -and -not (Test-Path $sarifDir)) {
        New-Item -ItemType Directory -Path $sarifDir -Force | Out-Null
    }
    $sarifJson = $sarifDoc | ConvertTo-Json -Depth 10
    Set-Content -Path $SarifPath -Value $sarifJson -Encoding UTF8

    # Print summary since we didn't go through the helper
    Write-Output ""
    Write-Output "================================================================"
    Write-Output "  VibeShield-Deploy Pipeline Push"
    Write-Output "  Total: $total  |  Passed: $passed  |  Failed: $failed  |  Warnings: $warned  |  Skipped: $skipped"
    Write-Output "================================================================"

    if ($failures.Count -gt 0) {
        Write-Output ""
        Write-Output "  ACTIONS REQUIRED ($($failures.Count) failure(s)):"
        Write-Output ""
        $i = 1
        foreach ($f in $failures) {
            Write-Output "    $i. $($f.Name)"
            Write-Output "       $($f.Message)"
            if ($f.Fix) { Write-Output "       -> $($f.Fix)" }
            Write-Output ""
            $i++
        }
    }

    if ($warnings.Count -gt 0) {
        Write-Output ""
        Write-Output "  WARNINGS ($($warnings.Count) item(s)):"
        Write-Output ""
        $i = 1
        foreach ($w in $warnings) {
            Write-Output "    $i. $($w.Name)"
            Write-Output "       $($w.Message)"
            if ($w.Fix) { Write-Output "       -> $($w.Fix)" }
            Write-Output ""
            $i++
        }
    }

    Write-Output "  Full details: $SarifPath"
    Write-Output ""
    if ($failed -gt 0) {
        Write-Output "  $failed check(s) failed. See details above."
    } else {
        Write-Output "  All checks passed. Pipeline push complete."
    }
    Write-Output ""
}

# SARIF path printed above — user opens manually if needed

} finally {
    Pop-Location
}

# ── State write (Phase 2: fold state writes into scripts) ───
if ($UpdateState -and $script:ExitCode -eq 0 -and $StateJson) {
    try {
        $stateData = $StateJson | ConvertFrom-Json -AsHashtable
        Write-DeployState -WorkspacePath $WorkspacePath -StateData $stateData
    } catch {
        Write-Warning "State update failed: $_"
    }
}

exit $script:ExitCode
