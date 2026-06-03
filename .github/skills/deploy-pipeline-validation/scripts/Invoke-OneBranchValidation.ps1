#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Validates OneBranch pipeline YAML against OB-01 through OB-30 structural and semantic checks.

.DESCRIPTION
    Runs 30 checks in 4 categories:
    - Structural (OB-01 — OB-15)
    - EV2 & Deploy (OB-16 — OB-22)
    - Signing & Compliance (OB-23 — OB-27)
    - Cross-Pipeline (OB-28 — OB-30)

.PARAMETER PipelinePath
    Path to the OneBranch pipeline YAML file to validate.

.PARAMETER BuddyPath
    Path to the Buddy (NonOfficial) pipeline file.

.PARAMETER OfficialPath
    Path to the Official pipeline file.

.PARAMETER Variant
    Which variant PipelinePath represents: 'Buddy' or 'Official'.

.PARAMETER WorkspacePath
    Root path of the workspace.

.PARAMETER SarifPath
    Path for the SARIF output file.

.PARAMETER HasEv2Stages
    Whether the pipeline includes EV2 deploy stages.

.PARAMETER IsOfficial
    Whether validating the Official variant.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural nouns are intentional for collection-returning functions')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PipelinePath,
    [string]$BuddyPath,
    [string]$OfficialPath,
    [ValidateSet('Buddy','Official')][string]$Variant = 'Buddy',
    [string]$WorkspacePath = $PWD.Path,
    [string]$SarifPath,
    [switch]$HasEv2Stages,
    [switch]$IsOfficial
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:ValidationDeadline = (Get-Date).AddSeconds(120)

function Assert-NotTimedOut {
    if ((Get-Date) -ge $script:ValidationDeadline) {
        Write-Error 'OneBranch validation timed out after 120 seconds.'
        $global:LASTEXITCODE = 1
        exit 1
    }
}

$script:Results  = [System.Collections.ArrayList]::new()
$script:ExitCode = 0

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','WARN','SKIP')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Fix
    )
    $null = $script:Results.Add([pscustomobject]@{id=$Id; name=$Name; status=$Status; message=$Message; fix=$Fix})
    if ($Status -eq 'FAIL') { $script:ExitCode = 1 }
    $icon  = switch ($Status) { 'PASS' {'✅'} 'FAIL' {'❌'} 'WARN' {'⚠️'} 'SKIP' {'⏭️'} }
    $line  = "  $icon ${Id}: $Name"
    if ($Status -ne 'PASS') { $line += " — $Message" }
    Write-Output $line | Out-Host

    # ── Structured log ──────────────────────────────────────
    $logLevel = switch ($Status) { 'PASS' {'info'} 'FAIL' {'error'} 'WARN' {'warn'} 'SKIP' {'info'} default {'info'} }
    if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
        Write-VsdLog -Message "$Id $Name — $Message" -Category 'pipeline-author' -Level $logLevel `
            -Agent 'vibeshield-deploy-pipeline-author' -Skill 'deploy-pipeline-validation' `
            -Script 'Invoke-OneBranchValidation.ps1' -CheckId $Id -Stage 2 `
            -WorkspacePath $WorkspacePath `
            -Extra @{ status = $Status; fix = if ($Fix) { $Fix } else { '' } }
    }
}

function Test-BothFiles {
    return ($BuddyPath -and (Test-Path (Join-Path -Path $WorkspacePath -ChildPath $BuddyPath))) -and ($OfficialPath -and (Test-Path (Join-Path -Path $WorkspacePath -ChildPath $OfficialPath)))
}

# ── Load pipeline YAML ──────────────────────────────────────
$fullPath = Join-Path -Path $WorkspacePath -ChildPath $PipelinePath
if (-not (Test-Path $fullPath)) {
    Write-Error "Pipeline file not found: $fullPath"
    $global:LASTEXITCODE = 1
    exit 1
}
$yamlContent = Get-Content $fullPath -Raw

Write-Output "" | Out-Host
Write-Output "================================================================" | Out-Host
Write-Output "  OneBranch Pipeline Validation ($Variant)" | Out-Host
Write-Output "================================================================" | Out-Host
Write-Output "  Pipeline : $PipelinePath" | Out-Host
Write-Output "  Variant  : $Variant" | Out-Host
Write-Output "  EV2      : $HasEv2Stages" | Out-Host
Write-Output "" | Out-Host

$buddyTemplate = 'OneBranch.NonOfficial.CrossPlat.yml@templates'
$officialTemplate = 'OneBranch.Official.CrossPlat.yml@templates'

# ═══ STRUCTURAL (OB-01 — OB-15) ═══════════════════════════

$expectedTemplate = if ($Variant -eq 'Official') { $officialTemplate } else { $buddyTemplate }
if ($yamlContent -match [regex]::Escape($expectedTemplate)) {
    Add-CheckResult -Id 'OB-01' -Name 'Template Reference' -Status PASS -Message "Extends $expectedTemplate"
} else {
    Add-CheckResult -Id 'OB-01' -Name 'Template Reference' -Status FAIL -Message "Does not extend $expectedTemplate" -Fix "Set extends.template to v2/$expectedTemplate"
}
Assert-NotTimedOut

if ($yamlContent -match 'OneBranch\.Pipelines/GovernedTemplates' -and $yamlContent -match 'refs/heads/main') {
    Add-CheckResult -Id 'OB-02' -Name 'Repository Resource' -Status PASS -Message 'GovernedTemplates at refs/heads/main'
} else {
    Add-CheckResult -Id 'OB-02' -Name 'Repository Resource' -Status FAIL -Message 'Missing GovernedTemplates repo' -Fix 'Add: name: OneBranch.Pipelines/GovernedTemplates, ref: refs/heads/main'
}

if ($yamlContent -match 'globalSdl:') {
    Add-CheckResult -Id 'OB-03' -Name 'globalSdl Block' -Status PASS -Message 'Present'
} else {
    Add-CheckResult -Id 'OB-03' -Name 'globalSdl Block' -Status FAIL -Message 'Missing' -Fix 'Add globalSdl under extends.parameters'
}

if ($yamlContent -match 'CDP_DEFINITION_BUILD_COUNT') {
    Add-CheckResult -Id 'OB-04' -Name 'Build Counter Variable' -Status PASS -Message 'Present'
} else {
    Add-CheckResult -Id 'OB-04' -Name 'Build Counter Variable' -Status FAIL -Message 'Missing CDP_DEFINITION_BUILD_COUNT' -Fix "Add: CDP_DEFINITION_BUILD_COUNT: \$[counter('', 0)]"
}
Assert-NotTimedOut

if ($yamlContent -match 'onebranch\.pipeline\.version@1') {
    Add-CheckResult -Id 'OB-05' -Name 'Versioning Task' -Status PASS -Message 'Present'
} else {
    Add-CheckResult -Id 'OB-05' -Name 'Versioning Task' -Status FAIL -Message 'Missing' -Fix 'Add onebranch.pipeline.version@1 to build stage'
}

if ($yamlContent -match 'ob_outputDirectory') {
    Add-CheckResult -Id 'OB-06' -Name 'Output Directory' -Status PASS -Message 'ob_outputDirectory set'
} else {
    Add-CheckResult -Id 'OB-06' -Name 'Output Directory' -Status FAIL -Message 'Missing ob_outputDirectory' -Fix "Add to build job variables"
}

if ($yamlContent -match 'type:\s*windows') {
    Add-CheckResult -Id 'OB-07' -Name 'Build Pool' -Status PASS -Message 'type: windows'
} else {
    Add-CheckResult -Id 'OB-07' -Name 'Build Pool' -Status FAIL -Message 'Not type: windows' -Fix 'Set pool: { type: windows }'
}
Assert-NotTimedOut

if ($HasEv2Stages) {
    if ($yamlContent -match 'type:\s*release') {
        Add-CheckResult -Id 'OB-08' -Name 'Deploy Pool' -Status PASS -Message 'type: release'
    } else {
        Add-CheckResult -Id 'OB-08' -Name 'Deploy Pool' -Status FAIL -Message 'EV2 deploy not type: release' -Fix 'Set pool: { type: release }'
    }
} else {
    Add-CheckResult -Id 'OB-08' -Name 'Deploy Pool' -Status SKIP -Message 'No EV2 stages'
}

if ($yamlContent -match 'WindowsHostVersion') {
    Add-CheckResult -Id 'OB-09' -Name 'Feature Flags' -Status PASS -Message 'WindowsHostVersion set'
} else {
    Add-CheckResult -Id 'OB-09' -Name 'Feature Flags' -Status FAIL -Message 'Missing' -Fix "Add featureFlags.WindowsHostVersion: '1ESWindows2022'"
}

if ($yamlContent -match 'vmImage:|demands:') {
    Add-CheckResult -Id 'OB-10' -Name 'No vmImage/demands' -Status FAIL -Message 'Prohibited in OneBranch' -Fix 'Remove vmImage and demands'
} else {
    Add-CheckResult -Id 'OB-10' -Name 'No vmImage/demands' -Status PASS -Message 'Clean'
}
Assert-NotTimedOut

$secretPatterns = @('password\s*:', 'secret\s*:', 'apikey\s*:', 'token\s*:.*[A-Za-z0-9]{20}')
$hasSecrets = $false
foreach ($p in $secretPatterns) { if ($yamlContent -match $p) { $hasSecrets = $true; break } }
if ($hasSecrets) {
    Add-CheckResult -Id 'OB-11' -Name 'No Secrets' -Status FAIL -Message 'Possible hardcoded secret' -Fix 'Use pipeline variables or Key Vault'
} else {
    Add-CheckResult -Id 'OB-11' -Name 'No Secrets' -Status PASS -Message 'Clean'
}

if ($Variant -eq 'Buddy') {
    if ($yamlContent -match 'exclude:\s*\r?\n\s*-\s*main') {
        Add-CheckResult -Id 'OB-12' -Name 'Trigger Config' -Status PASS -Message 'Buddy excludes main'
    } else {
        Add-CheckResult -Id 'OB-12' -Name 'Trigger Config' -Status FAIL -Message 'Buddy should exclude main' -Fix 'Set trigger.branches.exclude: [main]'
    }
} else {
    if ($yamlContent -match 'include:\s*\r?\n\s*-\s*main') {
        Add-CheckResult -Id 'OB-12' -Name 'Trigger Config' -Status PASS -Message 'Official includes main'
    } else {
        Add-CheckResult -Id 'OB-12' -Name 'Trigger Config' -Status FAIL -Message 'Official should include main' -Fix 'Set trigger.branches.include: [main]'
    }
}
Assert-NotTimedOut

$repoMatches = [regex]::Matches($yamlContent, 'repository:\s+(\w+)')
$extraRepos = @($repoMatches | Where-Object { $_.Groups[1].Value -notin @('templates', 'self') })
if ($extraRepos.Count -eq 0) {
    Add-CheckResult -Id 'OB-13' -Name 'No Extra Repos' -Status PASS -Message 'Only GovernedTemplates'
} else {
    Add-CheckResult -Id 'OB-13' -Name 'No Extra Repos' -Status FAIL -Message "Extra: $($extraRepos.ForEach({$_.Groups[1].Value}) -join ', ')" -Fix 'Remove extra repos'
}

if ($yamlContent -match 'WindowsContainerImage') {
    Add-CheckResult -Id 'OB-14' -Name 'Container Image' -Status PASS -Message 'WindowsContainerImage set'
} else {
    Add-CheckResult -Id 'OB-14' -Name 'Container Image' -Status FAIL -Message 'Missing' -Fix "Add WindowsContainerImage variable"
}

if ($yamlContent -match '^\s*-\s+script:' -and $yamlContent -notmatch '^\s*-\s+script:.*#.*ok') {
    Add-CheckResult -Id 'OB-15' -Name 'No Bare Script' -Status FAIL -Message 'Use PowerShell@2 instead' -Fix 'Replace - script: with PowerShell@2'
} else {
    Add-CheckResult -Id 'OB-15' -Name 'No Bare Script' -Status PASS -Message 'Clean'
}
Assert-NotTimedOut

# ═══ EV2 & DEPLOY (OB-16 — OB-22) ════════════════════════

if ($HasEv2Stages) {
    $esPath = Join-Path -Path $WorkspacePath -ChildPath 'es-metadata.yml'
    # OB-16: Service Tree ID — check pipeline YAML for CDP_SERVICE_TREE_ID or literal ServiceTreeId GUID, then fall back to es-metadata.yml
    $hasInYaml = ($yamlContent -match 'CDP_SERVICE_TREE_ID') -or ($yamlContent -match 'ServiceTreeId:\s*[''"]?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    $hasEsMeta = Test-Path $esPath
    $esServiceId = $null
    if ($hasEsMeta) {
        $esRaw = Get-Content $esPath -Raw -ErrorAction SilentlyContinue
        if ($esRaw -match 'service:\s*([0-9a-fA-F\-]{36})') { $esServiceId = $Matches[1] }
    }
    if ($hasInYaml) {
        $st = if ($hasEsMeta) { 'PASS' } else { 'WARN' }
        $msg = if ($hasEsMeta) { 'Present + es-metadata.yml exists' } else { 'In YAML but es-metadata.yml missing' }
        Add-CheckResult -Id 'OB-16' -Name 'Service Tree ID' -Status $st -Message $msg
    } elseif ($esServiceId) {
        # Not in pipeline YAML but found in es-metadata.yml — OneBranch resolves it automatically
        Add-CheckResult -Id 'OB-16' -Name 'Service Tree ID' -Status PASS -Message "Resolved from es-metadata.yml: $esServiceId"
    } else {
        Add-CheckResult -Id 'OB-16' -Name 'Service Tree ID' -Status FAIL -Message 'Missing CDP_SERVICE_TREE_ID' -Fix 'Add service GUID to es-metadata.yml or as a pipeline variable'
    }

    $ev2Root = Join-Path -Path $WorkspacePath -ChildPath 'ev2' 'ServiceGroupRoot'
    if (Test-Path $ev2Root) {
        Add-CheckResult -Id 'OB-17' -Name 'EV2 Artifacts' -Status PASS -Message 'ServiceGroupRoot exists'
    } else {
        Add-CheckResult -Id 'OB-17' -Name 'EV2 Artifacts' -Status FAIL -Message 'Missing ev2/ServiceGroupRoot' -Fix 'Run ev2-demo-agent'
    }

    if ($yamlContent -match 'Ev2RARollout@2') {
        $ri = @('EndpointProviderType','ConnectedServiceName','TaskAction','ServiceRootPath','RolloutSpecPath')
        $mi = @($ri | Where-Object { $yamlContent -notmatch $_ })
        if ($mi.Count -eq 0) {
            Add-CheckResult -Id 'OB-18' -Name 'EV2 Task Inputs' -Status PASS -Message 'All present'
        } else {
            Add-CheckResult -Id 'OB-18' -Name 'EV2 Task Inputs' -Status FAIL -Message "Missing: $($mi -join ', ')"
        }
    } else {
        Add-CheckResult -Id 'OB-18' -Name 'EV2 Task Inputs' -Status FAIL -Message 'Ev2RARollout@2 not found' -Fix 'Add EV2 deploy stage'
    }
    Assert-NotTimedOut

    if ($yamlContent -match 'ob_release_environment') {
        Add-CheckResult -Id 'OB-19' -Name 'Release Environment' -Status PASS -Message 'Set'
    } else {
        Add-CheckResult -Id 'OB-19' -Name 'Release Environment' -Status FAIL -Message 'Missing ob_release_environment'
    }

    if ($yamlContent -match 'ob_release_servicetreeid') {
        Add-CheckResult -Id 'OB-20' -Name 'Release STID' -Status PASS -Message 'Set'
    } else {
        Add-CheckResult -Id 'OB-20' -Name 'Release STID' -Status FAIL -Message 'Missing ob_release_servicetreeid'
    }

    if ($yamlContent -match 'cn-ev2deploy-') {
        Add-CheckResult -Id 'OB-21' -Name 'EV2 SC Pattern' -Status PASS -Message 'Follows cn-ev2deploy-*'
    } else {
        Add-CheckResult -Id 'OB-21' -Name 'EV2 SC Pattern' -Status FAIL -Message 'Wrong pattern' -Fix 'Use cn-ev2deploy-<service>-<env>'
    }

    if ($yamlContent -match 'ev2ManagedSdpRolloutConfig') {
        Add-CheckResult -Id 'OB-22' -Name 'Rollout Config' -Status PASS -Message 'Present'
    } else {
        Add-CheckResult -Id 'OB-22' -Name 'Rollout Config' -Status WARN -Message 'Recommended for managed rollouts'
    }
} else {
    16..22 | ForEach-Object { Add-CheckResult -Id "OB-$_" -Name 'EV2 Check' -Status SKIP -Message 'No EV2 stages' }
}
Assert-NotTimedOut

# ═══ SIGNING & COMPLIANCE (OB-23 — OB-27) ═════════════════

if ($IsOfficial -or $Variant -eq 'Official') {
    if ($yamlContent -match 'onebranch\.pipeline\.signing@1' -and $yamlContent -match "command:\s*'sign'" -and $yamlContent -match "command:\s*'verify'") {
        Add-CheckResult -Id 'OB-23' -Name 'Code Signing' -Status PASS -Message 'sign + verify present'
    } else {
        Add-CheckResult -Id 'OB-23' -Name 'Code Signing' -Status FAIL -Message 'Missing sign/verify' -Fix 'Add onebranch.pipeline.signing@1 with both commands'
    }
} else {
    if ($yamlContent -match 'onebranch\.pipeline\.signing@1') {
        Add-CheckResult -Id 'OB-23' -Name 'Code Signing' -Status WARN -Message 'Buddy has signing — typically Official-only'
    } else {
        Add-CheckResult -Id 'OB-23' -Name 'Code Signing' -Status PASS -Message 'Buddy correctly omits signing'
    }
}

if ($yamlContent -match 'sbom:\s*\r?\n\s*enabled:\s*true') {
    Add-CheckResult -Id 'OB-24' -Name 'SBOM' -Status PASS -Message 'Enabled'
} else {
    Add-CheckResult -Id 'OB-24' -Name 'SBOM' -Status WARN -Message 'Not explicitly enabled'
}

if (($Variant -eq 'Buddy' -and $yamlContent -match $buddyTemplate) -or ($Variant -eq 'Official' -and $yamlContent -match $officialTemplate)) {
    Add-CheckResult -Id 'OB-25' -Name 'Variant Match' -Status PASS -Message 'Template matches variant'
} else {
    Add-CheckResult -Id 'OB-25' -Name 'Variant Match' -Status FAIL -Message 'Template/variant mismatch'
}
Assert-NotTimedOut

if (Test-BothFiles) {
    Add-CheckResult -Id 'OB-26' -Name 'Both Variants' -Status PASS -Message 'Buddy + Official exist'
} elseif ($BuddyPath -or $OfficialPath) {
    Add-CheckResult -Id 'OB-26' -Name 'Both Variants' -Status FAIL -Message 'Only one variant' -Fix 'Generate both'
} else {
    Add-CheckResult -Id 'OB-26' -Name 'Both Variants' -Status SKIP -Message 'Paths not provided'
}

$feedAuthTasks = @('NuGetAuthenticate@1','npmAuthenticate@0','PipAuthenticate@1','MavenAuthenticate@0')
$installPatterns = @('dotnet restore','npm ci','pip install','mvn ','gradle ')
$authOk = $true
foreach ($at in $feedAuthTasks) {
    if ($yamlContent -match $at) {
        $aPos = $yamlContent.IndexOf($at)
        foreach ($ip in $installPatterns) {
            if ($yamlContent -match [regex]::Escape($ip)) {
                $iPos = $yamlContent.IndexOf($ip)
                if ($iPos -lt $aPos) { $authOk = $false }
            }
        }
    }
}
if ($authOk) {
    Add-CheckResult -Id 'OB-27' -Name 'Feed Auth Order' -Status PASS -Message 'Auth before install'
} else {
    Add-CheckResult -Id 'OB-27' -Name 'Feed Auth Order' -Status FAIL -Message 'Install before auth' -Fix 'Move auth task before restore/install'
}
Assert-NotTimedOut

# ═══ CROSS-PIPELINE (OB-28 — OB-30) ═══════════════════════

if ($Variant -eq 'Official' -and $yamlContent -match 'pipelines:') {
    Add-CheckResult -Id 'OB-28' -Name 'Pipeline Resource' -Status PASS -Message 'Has resources.pipelines'
} else {
    Add-CheckResult -Id 'OB-28' -Name 'Pipeline Resource' -Status SKIP -Message 'OK for combined pipelines'
}

$paramGated = $yamlContent -match 'parameters\.run(Build|Provision|Deploy)'
if ($paramGated) {
    if ($yamlContent -match '\$\{\{\s*if\s+eq\(parameters\.' -and $yamlContent -match 'dependsOn:') {
        Add-CheckResult -Id 'OB-29' -Name 'Conditional DependsOn' -Status PASS -Message 'Wired correctly'
    } else {
        Add-CheckResult -Id 'OB-29' -Name 'Conditional DependsOn' -Status WARN -Message 'May have incorrect wiring'
    }
} else {
    Add-CheckResult -Id 'OB-29' -Name 'Conditional DependsOn' -Status SKIP -Message 'No parameter-gated stages'
}

$bPos = if ($yamlContent -match 'stage:\s*build') { $yamlContent.IndexOf($Matches[0]) } else { -1 }
# Accept both ARM stage names (Provision/Deploy) and EV2 stage names ({Ev2Env}_Deploy_Infra_*, {Ev2Env}_Deploy_App_*)
$pPos = if ($yamlContent -match 'stage:\s*(Provision|Test_Deploy_Infra|Prod_Deploy_Infra)') { $yamlContent.IndexOf($Matches[0]) } else { -1 }
$dPos = if ($yamlContent -match 'stage:\s*(Deploy(?!_Infra)|Test_Deploy_App|Prod_Deploy_App|Test_Deploy_Corp|Prod_Deploy_Corp)') { $yamlContent.IndexOf($Matches[0]) } else { -1 }
if ($bPos -ge 0 -and $pPos -ge 0 -and $dPos -ge 0 -and $bPos -lt $pPos -and $pPos -lt $dPos) {
    Add-CheckResult -Id 'OB-30' -Name 'Stage Order' -Status PASS -Message 'Build → Provision/Infra → Deploy/App'
} elseif ($bPos -ge 0 -and $dPos -ge 0 -and $pPos -eq -1 -and $bPos -lt $dPos) {
    # Build + Deploy only (no Provision/Infra) — valid for Build+Deploy-only EV2 variant
    Add-CheckResult -Id 'OB-30' -Name 'Stage Order' -Status PASS -Message 'Build → Deploy (no Provision — infra provisioned separately)'
} elseif ($bPos -ge 0 -or $pPos -ge 0 -or $dPos -ge 0) {
    Add-CheckResult -Id 'OB-30' -Name 'Stage Order' -Status WARN -Message 'Not all stages present or order unclear'
} else {
    Add-CheckResult -Id 'OB-30' -Name 'Stage Order' -Status SKIP -Message 'Stage names not found'
}

# ═══ SUMMARY ═══════════════════════════════════════════════

$pc = @($script:Results | Where-Object status -eq 'PASS').Count
$fc = @($script:Results | Where-Object status -eq 'FAIL').Count
$wc = @($script:Results | Where-Object status -eq 'WARN').Count
$sc = @($script:Results | Where-Object status -eq 'SKIP').Count

Write-Output "" | Out-Host
Write-Output "  ────────────────────────────────────────" | Out-Host
Write-Output "  Total: $($script:Results.Count) | ✅ $pc | ❌ $fc | ⚠️ $wc | ⏭️ $sc" | Out-Host
Write-Output "  ────────────────────────────────────────" | Out-Host

if ($fc -gt 0) {
    Write-Output "" | Out-Host
    $script:Results | Where-Object status -eq 'FAIL' | ForEach-Object {
        Write-Output "    ❌ $($_.id): $($_.name) — $($_.message)" | Out-Host
        if ($_.fix) { Write-Output "       Fix: $($_.fix)" | Out-Host }
    }
}

if ($SarifPath) {
    $sd = Split-Path -Path $SarifPath -Parent
    if ($sd -and -not (Test-Path $sd)) { New-Item -Path $sd -ItemType Directory -Force | Out-Null }
    $rj = $script:Results | ConvertTo-Json -Depth 3
    & "$PSScriptRoot/../../../scripts/Write-SarifReport.ps1" -ToolName 'OneBranch-Pipeline-Validation' -ToolVersion '1.0.0' -ResultsJson $rj -OutputPath $SarifPath
}

$global:LASTEXITCODE = $script:ExitCode
exit $script:ExitCode
