#!/usr/bin/env pwsh
#Requires -Version 7.0
Set-StrictMode -Version Latest
<#
.SYNOPSIS
    Shared CLI wrapper functions used by multiple VibeShield-Deploy scripts.
.DESCRIPTION
    Dot-source this file to load Invoke-GitCommand and Invoke-AzCommand.
    These wrappers route all external CLI calls through a single point so
    Pester can mock them consistently across PipelinePush and DeployMonitor.
#>

# ── Growth Policy ──────────────────────────────────────────
# This file is 3K+ lines / 55 functions. Before adding a new function:
#   1. Can you consume existing Get-AppType / Get-DeployConfig output instead?
#   2. Does the function belong in the consuming skill's own Functions.ps1?
#   3. Is it used by ≥ 3 scripts? If not, it doesn't belong here.
# Budget: ≤ 5,000 lines / ≤ 80 functions / no single function > 650 lines.
# EV2/tenant functions live in Ev2Helpers.ps1 (same directory).
# See: docs/shared-helpers-refactoring-plan.md
# ──────────────────────────────────────────────────────────

# ════════════════════════════════════════════════════════════
# Deploy Config — single source of truth
# ════════════════════════════════════════════════════════════
# All persistent configuration lives in .github/config/deploy-config.json.
# Use Get-DeployConfig to access it (cached per session).
$script:DeployConfig = $null

# ── Auto-load app type detection engine ─────────────────────
# Ensures Get-AppType is available to any script that loads SharedHelpers,
# without requiring callers to dot-source the detection script separately.
if (-not (Get-Command Get-AppType -ErrorAction SilentlyContinue)) {
    $script:_detectScript = Join-Path -Path $PSScriptRoot -ChildPath '..\skills\deploy-app-type-select\scripts\Invoke-AppTypeDetect.ps1'
    if (Test-Path $script:_detectScript) { . $script:_detectScript }
}

function Get-DeployConfig {
    <#
    .SYNOPSIS Returns the parsed deploy-config.json object, cached per session.
    .DESCRIPTION Loads .github/config/deploy-config.json relative to SharedHelpers.ps1.
                 Throws if the file is missing or contains invalid JSON.
    #>
    # Use try/catch to tolerate Pester 5 scope isolation: the $script:DeployConfig
    # variable may have been set in the Discovery phase scope while the function
    # executes in the Run phase scope, causing a strict-mode "has not been set" error.
    $cfg = try { $script:DeployConfig } catch { $null }
    if ($null -eq $cfg) {
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath '..\config\deploy-config.json'
        if (-not (Test-Path $configPath)) {
            throw "Deploy config not found at '$configPath'. Run Install-VibeShield.ps1 to restore."
        }
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $script:DeployConfig = $cfg
    }
    return $cfg
}

# ════════════════════════════════════════════════════════════
# Config-Backed Path & Naming Helpers (guarded with fallback defaults)
# ════════════════════════════════════════════════════════════

function Get-ConfigPath {
    <#
    .SYNOPSIS Returns a config-backed path with fallback default.
    .PARAMETER Key     Config key under 'paths' section (e.g., 'stateFile', 'resultsDir').
    .PARAMETER Default Fallback value if config is unavailable.
    #>
    param([string]$Key, [string]$Default)
    try {
        $cfg = Get-DeployConfig
        if ($cfg.PSObject.Properties['paths'] -and $cfg.paths.PSObject.Properties[$Key]) {
            return $cfg.paths.$Key
        }
    } catch { <# config unavailable — use default #> $null = $_ }
    return $Default
}

function Get-StateFilePath {
    <#
    .SYNOPSIS Returns the relative state file path from config or default.
    #>
    param([string]$WorkspacePath = $PWD.Path)
    $relPath = Get-ConfigPath -Key 'stateFile' -Default '.vibeshield/deploy-state.json'
    return Join-Path -Path $WorkspacePath -ChildPath $relPath
}

function Get-ResultsDir {
    <#
    .SYNOPSIS Returns the relative results directory path from config or default.
    #>
    param([string]$WorkspacePath = $PWD.Path)
    $relPath = Get-ConfigPath -Key 'resultsDir' -Default '.vibeshield/results'
    return Join-Path -Path $WorkspacePath -ChildPath $relPath
}

function Get-PipelineYamlRelPath {
    <#
    .SYNOPSIS Returns the relative pipeline YAML path from config, auto-detected, or default.
    .DESCRIPTION
        Scans pipeline output directories from pipelineFrameworks config for existing
        pipeline YAML files. Returns the first found, or the 1ES config default.
    .PARAMETER WorkspacePath Root of the workspace. Defaults to current directory.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([string]$WorkspacePath = $PWD.Path)

    # Read output dirs from paths config
    $_1esOutputDir = Get-ConfigPath -Key 'pipelineDir1ES' -Default '.azdo/pipelines'
    $_obOutputDir = Get-ConfigPath -Key 'pipelineDirOneBranch' -Default '.azure-pipelines'

    # Check 1ES default path first (from pipeline.defaultYamlPath)
    $_1esDefault = try { (Get-DeployConfig).pipeline.defaultYamlPath } catch { "$_1esOutputDir/azure-pipeline.yml" }
    if (-not $_1esDefault) { $_1esDefault = "$_1esOutputDir/azure-pipeline.yml" }
    if (Test-Path (Join-Path -Path $WorkspacePath -ChildPath $_1esDefault)) { return $_1esDefault }

    # Check for any 1ES YAML in the directory
    $_1esDir = Join-Path -Path $WorkspacePath -ChildPath $_1esOutputDir
    if (Test-Path $_1esDir) {
        $_1esFiles = @(Get-ChildItem -Path $_1esDir -Filter '*.yml' -ErrorAction SilentlyContinue)
        if ($_1esFiles.Count -gt 0) { return "$_1esOutputDir/$($_1esFiles[0].Name)" }
    }

    # Check OneBranch directory
    $_obDir = Join-Path -Path $WorkspacePath -ChildPath $_obOutputDir
    if (Test-Path $_obDir) {
        $_obFiles = @(Get-ChildItem -Path $_obDir -Filter '*.yml' -ErrorAction SilentlyContinue)
        if ($_obFiles.Count -gt 0) { return "$_obOutputDir/$($_obFiles[0].Name)" }
    }

    # Default to 1ES config path (no existing files found)
    return $_1esDefault
}

# ════════════════════════════════════════════════════════════
# Pipeline Framework Resolution
# ════════════════════════════════════════════════════════════

function Get-PipelineFramework {
    <#
    .SYNOPSIS Resolves the pipeline framework, variant, and infra deploy method
              from target environment + project type.
    .DESCRIPTION
        Uses the frameworkSelection decision table in deploy-config.json to
        deterministically map (environment, projectType) → (framework, variant, infraDeploy).
        Test/UAT/Prod are always BusinessUse regardless of the ProjectType parameter.
    .PARAMETER TargetEnvironment
        Target deployment environment: POC, DEV, Test, UAT, or Prod.
    .PARAMETER ProjectType
        Project type: 'BusinessUse' or 'Prototype'. Ignored for Test/UAT/Prod.
    .OUTPUTS PSCustomObject with Framework, Variant, InfraDeploy properties.
    .EXAMPLE
        Get-PipelineFramework -TargetEnvironment 'Prod' -ProjectType 'BusinessUse'
        # Returns: Framework=OneBranch, Variant=Official, InfraDeploy=EV2
    .EXAMPLE
        Get-PipelineFramework -TargetEnvironment 'DEV' -ProjectType 'Prototype'
        # Returns: Framework=1ES, Variant=Unofficial, InfraDeploy=ARM
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('POC','DEV','Test','UAT','Prod')][string]$TargetEnvironment,
        [Parameter(Mandatory)][ValidateSet('BusinessUse','Prototype')][string]$ProjectType
    )

    # Test/UAT/Prod require BusinessUse — block Prototype
    $alwaysBusinessUse = @('Test', 'UAT', 'Prod')
    if ($TargetEnvironment -in $alwaysBusinessUse -and $ProjectType -eq 'Prototype') {
        Write-Error "Environment '$TargetEnvironment' requires BusinessUse project type. Prototype projects must change to BusinessUse before deploying to Test/UAT/Prod. Update projectType in project-config.json."
        return $null
    }
    $effectiveType = $ProjectType

    try {
        $cfg = Get-DeployConfig
        $selectionTable = $cfg.frameworkSelection

        if ($effectiveType -eq 'BusinessUse') {
            $entry = $selectionTable.businessUse.PSObject.Properties[$TargetEnvironment]
        } else {
            $entry = $selectionTable.prototype.PSObject.Properties[$TargetEnvironment]
        }

        if ($entry) {
            $val = $entry.Value
            $fw  = $val.framework
            $var = if ($val.PSObject.Properties['variant']) { $val.variant } else { $null }
            $infra = $val.infraDeploy

            # ── Policy enforcement: variant must be valid for the framework ──
            $validVariants = @{
                '1ES'       = @('Unofficial', 'Official')
                'OneBranch' = @('NonOfficial', 'Official')
            }
            if ($var -and $validVariants.ContainsKey($fw) -and $var -notin $validVariants[$fw]) {
                Write-Warning "Framework selection policy violation: variant '$var' is not valid for framework '$fw'. Valid variants: $($validVariants[$fw] -join ', '). Falling back to default."
                $var = $validVariants[$fw][0]
            }

            # ── Policy enforcement: Prod requires Official variant ──
            $envRestrictions = @{ 'Prod' = @('Official') }
            if ($envRestrictions.ContainsKey($TargetEnvironment) -and $var -notin $envRestrictions[$TargetEnvironment]) {
                Write-Warning "Framework selection policy violation: environment '$TargetEnvironment' requires variant in ($($envRestrictions[$TargetEnvironment] -join ', ')), got '$var'. Overriding to 'Official'."
                $var = 'Official'
            }

            # ── Policy enforcement: infraDeploy must be ARM or EV2 ──
            if ($infra -notin @('ARM', 'EV2')) {
                Write-Warning "Framework selection policy violation: infraDeploy '$infra' is not valid. Must be ARM or EV2. Falling back to ARM."
                $infra = 'ARM'
            }

            return [PSCustomObject]@{
                Framework   = $fw
                Variant     = $var
                InfraDeploy = $infra
            }
        }
    } catch {
        Write-Verbose "Framework selection config unavailable: $_"
    }

    # Fallback: hardcoded decision table
    if ($effectiveType -eq 'BusinessUse') {
        $variant = if ($TargetEnvironment -in @('POC','DEV')) { 'NonOfficial' } else { 'Official' }
        return [PSCustomObject]@{ Framework = 'OneBranch'; Variant = $variant; InfraDeploy = 'EV2' }
    } else {
        return [PSCustomObject]@{ Framework = '1ES'; Variant = 'Unofficial'; InfraDeploy = 'ARM' }
    }
}

function Get-PipelineOutputPath {
    <#
    .SYNOPSIS Returns the pipeline output directory based on framework.
    .PARAMETER Framework '1ES' or 'OneBranch'.
    .PARAMETER WorkspacePath Root of the workspace.
    .OUTPUTS Absolute path to the pipeline output directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('1ES','OneBranch')][string]$Framework,
        [string]$WorkspacePath = $PWD.Path
    )

    try {
        $cfg = Get-DeployConfig
        $fw = $cfg.pipelineFrameworks.PSObject.Properties[$Framework]
        if ($fw) {
            $dir = $fw.Value.outputDir
            if ($dir) { return Join-Path -Path $WorkspacePath -ChildPath $dir }
        }
    } catch {
        Write-Verbose "Pipeline framework config unavailable: $_"
    }

    # Fallback — read from paths config
    $pathKey = if ($Framework -eq 'OneBranch') { 'pipelineDirOneBranch' } else { 'pipelineDir1ES' }
    $defaultDir = if ($Framework -eq 'OneBranch') { '.azure-pipelines' } else { '.azdo/pipelines' }
    $dir = Get-ConfigPath -Key $pathKey -Default $defaultDir
    return Join-Path -Path $WorkspacePath -ChildPath $dir
}

function Get-PipelineFileNames {
    <#
    .SYNOPSIS Returns the pipeline file name(s) for a given framework, variant, and app name.
    .PARAMETER Framework '1ES' or 'OneBranch'.
    .PARAMETER Variant Resolved variant (e.g., 'Unofficial', 'Official', 'NonOfficial').
    .PARAMETER AppName Application name (used in file naming).
    .OUTPUTS Array of file names.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('1ES','OneBranch')][string]$Framework,
        [string]$Variant,
        [string]$AppName = 'app'
    )

    if ($Framework -eq '1ES') {
        # 1ES: single file per variant
        $v = if ($Variant) { $Variant } else { 'Unofficial' }
        return @("1ES-$v-$AppName.yml")
    }

    # OneBranch: always both Buddy + Official
    return @(
        "OneBranch-Buddy-$AppName.yml",
        "OneBranch-Official-$AppName.yml"
    )
}

# ════════════════════════════════════════════════════════════
# Project Config — .vibeshield/project-config.json
# ════════════════════════════════════════════════════════════

$script:ProjectConfig = $null
$script:ProjectConfigPath = $null

function Get-ProjectConfigPath {
    <#
    .SYNOPSIS Returns the absolute path to .vibeshield/project-config.json.
    .PARAMETER WorkspacePath Root of the workspace.
    #>
    param([string]$WorkspacePath = $PWD.Path)
    $relPath = Get-ConfigPath -Key 'projectConfig' -Default '.vibeshield/project-config.json'
    return Join-Path -Path $WorkspacePath -ChildPath $relPath
}

function Get-ProjectConfig {
    <#
    .SYNOPSIS Reads .vibeshield/project-config.json and returns the parsed object.
    .DESCRIPTION
        Returns the project config if it exists, or $null if it doesn't.
        Cached per session — subsequent calls return the cached object.
        Call Set-ProjectConfig to create or update.
    .PARAMETER WorkspacePath Root of the workspace.
    .PARAMETER Force Re-read from disk even if cached.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PWD.Path,
        [switch]$Force
    )
    $path = Get-ProjectConfigPath -WorkspacePath $WorkspacePath
    if ($Force) { $script:ProjectConfig = $null }
    if ($null -ne $script:ProjectConfig -and $script:ProjectConfigPath -eq $path) {
        return $script:ProjectConfig
    }
    if (-not (Test-Path $path)) {
        return $null
    }
    try {
        $script:ProjectConfig = Get-Content $path -Raw | ConvertFrom-Json
        $script:ProjectConfigPath = $path
        return $script:ProjectConfig
    } catch {
        Write-Warning "Failed to read project config at '$path': $($_.Exception.Message)"
        return $null
    }
}

function Set-ProjectConfig {
    <#
    .SYNOPSIS Creates or updates .vibeshield/project-config.json.
    .DESCRIPTION
        Merges the provided data into the existing project config (if any),
        updates lastModifiedUtc, and writes to disk. Creates the .vibeshield/
        directory if it doesn't exist. Invalidates the cache.
        Accepts either -Data hashtable OR individual named parameters.
    .PARAMETER WorkspacePath Root of the workspace.
    .PARAMETER Data Hashtable of fields to set or update.
    .PARAMETER ProjectType Optional. Sets projectType field.
    .PARAMETER AdoOrgUrl Optional. Sets adoOrgUrl field.
    .PARAMETER AdoProject Optional. Sets adoProject field.
    .PARAMETER RepoName Optional. Sets repoName field.
    .PARAMETER PreferenceProfile Optional. Sets preferenceProfile field.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [hashtable]$Data,
        [string]$ProjectType,
        [string]$AdoOrgUrl,
        [string]$AdoProject,
        [string]$RepoName,
        [string]$PreferenceProfile
    )

    # Build Data hashtable from named parameters if -Data not provided
    if (-not $Data) { $Data = @{} }
    if ($ProjectType)       { $Data['projectType'] = $ProjectType }
    if ($AdoOrgUrl)         { $Data['adoOrgUrl'] = $AdoOrgUrl }
    if ($AdoProject)        { $Data['adoProject'] = $AdoProject }
    if ($RepoName)          { $Data['repoName'] = $RepoName }
    if ($PreferenceProfile) { $Data['preferenceProfile'] = $PreferenceProfile }

    if ($Data.Count -eq 0) {
        Write-Warning "Set-ProjectConfig called with no data to set."
        return
    }
    $path = Get-ProjectConfigPath -WorkspacePath $WorkspacePath
    $dir = Split-Path -Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    # Read existing or start fresh
    $existing = $null
    if (Test-Path $path) {
        try {
            $existing = Get-Content $path -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Existing project config is corrupt — recreating: $($_.Exception.Message)"
        }
    }

    if (-not $existing) {
        $existing = [ordered]@{
            '$comment'       = 'VibeShield-Deploy project configuration — git-tracked'
            projectType      = $null
            adoOrgUrl        = $null
            adoProject       = $null
            repoName         = $null
            preferenceProfile = 'developer'
            onboarding       = @{}
            createdUtc       = (Get-Date).ToUniversalTime().ToString('o')
            lastModifiedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    # Merge provided data
    foreach ($key in $Data.Keys) {
        if ($key -eq 'onboarding' -and $existing.PSObject -and $existing.PSObject.Properties['onboarding']) {
            # Merge onboarding map — don't overwrite, merge SC entries
            $obData = $Data[$key]
            if ($obData -is [hashtable]) {
                $existingOb = $existing.onboarding
                if ($existingOb -is [PSCustomObject]) {
                    foreach ($scName in $obData.Keys) {
                        $existingOb | Add-Member -NotePropertyName $scName -NotePropertyValue $obData[$scName] -Force
                    }
                }
            }
        } else {
            if ($existing -is [PSCustomObject]) {
                if ($existing.PSObject.Properties[$key]) {
                    $existing.$key = $Data[$key]
                } else {
                    $existing | Add-Member -NotePropertyName $key -NotePropertyValue $Data[$key] -Force
                }
            } else {
                $existing[$key] = $Data[$key]
            }
        }
    }

    # Update timestamp
    if ($existing -is [PSCustomObject]) {
        $existing.lastModifiedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } else {
        $existing['lastModifiedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    }

    # Write
    $json = $existing | ConvertTo-Json -Depth 10
    Set-Content -Path $path -Value $json -Encoding UTF8 -NoNewline
    Write-Output "  Project config written: $path"

    # Invalidate cache
    $script:ProjectConfig = $null
    $script:ProjectConfigPath = $null
}

function Get-NamingPattern {
    <#
    .SYNOPSIS Returns a naming pattern from config with {username} placeholder, or fallback.
    .PARAMETER Key     Config key under 'naming' section.
    .PARAMETER Default Fallback pattern string.
    #>
    param([string]$Key, [string]$Default)
    try {
        $cfg = Get-DeployConfig
        if ($cfg.PSObject.Properties['naming'] -and $cfg.naming.PSObject.Properties[$Key]) {
            return $cfg.naming.$Key
        }
    } catch { <# config unavailable — use default #> $null = $_ }
    return $Default
}

function Resolve-NamingPattern {
    <#
    .SYNOPSIS Resolves a naming pattern by substituting {username}, {slug}, {date}.
    .PARAMETER Pattern Pattern string with placeholders.
    .PARAMETER Username User's derived username (email prefix).
    #>
    param([string]$Pattern, [string]$Username)
    return $Pattern -replace '\{username\}', $Username -replace '\{date\}', (Get-Date -Format 'yyyyMMdd') -replace '\{slug\}', ($Username -replace '[^a-z0-9]', '')
}

function Get-ServiceConnectionName {
    <#
    .SYNOPSIS Derives SC name from username using config naming pattern.
    #>
    param([string]$Username)
    $pattern = Get-NamingPattern -Key 'serviceConnectionPattern' -Default 'sc-vibe-{username}-ARM'
    return Resolve-NamingPattern -Pattern $pattern -Username $Username
}

function Get-MgmtResourceGroupName {
    <#
    .SYNOPSIS Derives management RG name from username using config naming pattern.
    #>
    param([string]$Username)
    $pattern = Get-NamingPattern -Key 'mgmtResourceGroupPattern' -Default 'rg-vibe-{username}'
    return Resolve-NamingPattern -Pattern $pattern -Username $Username
}

function Get-ManagedIdentityName {
    <#
    .SYNOPSIS Derives managed identity name from username using config naming pattern.
    #>
    param([string]$Username)
    $pattern = Get-NamingPattern -Key 'managedIdentityPattern' -Default 'uami-vibe-{username}'
    return Resolve-NamingPattern -Pattern $pattern -Username $Username
}

function Test-ServiceConnectionExists {
    <#
    .SYNOPSIS Checks whether a named service connection exists in an Azure DevOps project.
    .DESCRIPTION
        Queries the ADO service endpoint list and checks if a SC with the given name exists.
        Returns a result object with Exists, EndpointId, and Error fields.
        Does NOT authorize the SC — only checks existence.
    .PARAMETER ScName   Service connection name to check.
    .PARAMETER AdoOrgUrl Azure DevOps organization URL.
    .PARAMETER AdoProject Azure DevOps project name.
    .OUTPUTS PSCustomObject with Exists (bool), EndpointId (string or $null), Error (string or $null).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Invoke-AzCommand uses ValueFromRemainingArguments')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScName,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )
    try {
        $result = Invoke-AzCommand 'devops' 'service-endpoint' 'list' `
            '--org' $AdoOrgUrl '--project' $AdoProject '-o' 'json' `
            -TimeoutSeconds 60
        if ($result.ExitCode -ne 0 -or -not $result.Output) {
            return [pscustomobject]@{ Exists = $false; EndpointId = $null; Error = "ADO query failed: $($result.Output)" }
        }
        $endpoints = @($result.Output | ConvertFrom-Json)
        $match = @($endpoints | Where-Object { $_.name -eq $ScName })
        if ($match.Count -gt 0) {
            return [pscustomobject]@{ Exists = $true; EndpointId = $match[0].id; Error = $null }
        }
        return [pscustomobject]@{ Exists = $false; EndpointId = $null; Error = $null }
    } catch {
        return [pscustomobject]@{ Exists = $false; EndpointId = $null; Error = $_.Exception.Message }
    }
}

function Get-PipelineServiceConnections {
    <#
    .SYNOPSIS Extracts all service connection names referenced in a pipeline YAML file.
    .DESCRIPTION
        Parses the YAML content for azureSubscription, ConnectedServiceName, and
        serviceConnection variable definitions. Returns an array of unique SC names.
        Resolves $(variableName) references by looking up the variable definition in the YAML.
    .PARAMETER YamlContent  Raw YAML content as a string.
    .OUTPUTS String array of unique service connection names found.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$YamlContent
    )
    $scNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Literal azureSubscription values (not variable references)
    $azSubMatches = [regex]::Matches($YamlContent, "(?mi)azureSubscription:\s*'([^'$]+)'")
    foreach ($m in $azSubMatches) { $null = $scNames.Add($m.Groups[1].Value.Trim()) }
    $azSubMatches2 = [regex]::Matches($YamlContent, '(?mi)azureSubscription:\s*"([^"$]+)"')
    foreach ($m in $azSubMatches2) { $null = $scNames.Add($m.Groups[1].Value.Trim()) }

    # 2. Literal ConnectedServiceName values
    $csnMatches = [regex]::Matches($YamlContent, "(?mi)ConnectedServiceName:\s*'([^'$]+)'")
    foreach ($m in $csnMatches) { $null = $scNames.Add($m.Groups[1].Value.Trim()) }
    $csnMatches2 = [regex]::Matches($YamlContent, '(?mi)ConnectedServiceName:\s*"([^"$]+)"')
    foreach ($m in $csnMatches2) { $null = $scNames.Add($m.Groups[1].Value.Trim()) }

    # 3. Variable references: azureSubscription: '$(varName)' or ConnectedServiceName: '$(varName)'
    $varRefMatches = [regex]::Matches($YamlContent, '(?mi)(?:azureSubscription|ConnectedServiceName):\s*[''"]\$\((\w+)\)[''"]')
    foreach ($m in $varRefMatches) {
        $varName = $m.Groups[1].Value
        # Look up variable definition in the YAML
        $varDefMatch = [regex]::Match($YamlContent, "(?mi)^\s+${varName}:\s*'?([^'\r\n$]+)'?")
        if ($varDefMatch.Success) {
            $resolvedValue = $varDefMatch.Groups[1].Value.Trim().Trim("'").Trim('"')
            if ($resolvedValue -and $resolvedValue -notmatch '^\$') {
                $null = $scNames.Add($resolvedValue)
            }
        }
    }

    return @($scNames)
}

function Test-AllPipelineSCsExist {
    <#
    .SYNOPSIS Verifies all service connections referenced in a pipeline YAML exist in ADO.
    .DESCRIPTION
        Extracts SC names from the pipeline YAML via Get-PipelineServiceConnections,
        then checks each one via Test-ServiceConnectionExists.
        Returns a result object with AllExist, MissingSCs, FoundSCs, and TotalSCs.
        This is the canonical implementation — used by both deploy-user-onboarding
        and deploy-pipeline-push to avoid duplicating the check loop.
    .PARAMETER YamlContent  Raw YAML content as a string.
    .PARAMETER AdoOrgUrl    Azure DevOps organization URL.
    .PARAMETER AdoProject   Azure DevOps project name.
    .OUTPUTS PSCustomObject with AllExist (bool), MissingSCs (string[]), FoundSCs (hashtable[]), TotalSCs (int).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$YamlContent,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    $scNames = @(Get-PipelineServiceConnections -YamlContent $YamlContent)

    if ($scNames.Count -eq 0) {
        return [pscustomobject]@{
            AllExist   = $true
            MissingSCs = @()
            FoundSCs   = @()
            TotalSCs   = 0
        }
    }

    $allExist   = $true
    $missingSCs = @()
    $foundSCs   = @()

    foreach ($sc in $scNames) {
        $check = Test-ServiceConnectionExists -ScName $sc -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject
        if ($check.Exists) {
            $foundSCs += @{ Name = $sc; EndpointId = $check.EndpointId }
        } else {
            $allExist = $false
            $missingSCs += $sc
        }
    }

    return [pscustomobject]@{
        AllExist   = $allExist
        MissingSCs = @($missingSCs)
        FoundSCs   = @($foundSCs)
        TotalSCs   = $scNames.Count
    }
}

function Grant-ServiceConnectionAccess {
    <#
    .SYNOPSIS Authorizes a service connection for pipeline use in Azure DevOps.
    .DESCRIPTION
        Supports two authorization scopes:
        - AllPipelines: blanket authorization via az devops service-endpoint update --enable-for-all
        - SpecificPipeline: per-pipeline authorization via REST API PATCH pipelinepermissions/endpoint
        Returns a result object with Status, Message, EndpointId.
    .PARAMETER ScName       Service connection name.
    .PARAMETER AdoOrgUrl    Azure DevOps organization URL.
    .PARAMETER AdoProject   Azure DevOps project name.
    .PARAMETER Scope        Authorization scope: 'AllPipelines' or 'SpecificPipeline'.
    .PARAMETER PipelineId   Required when Scope is 'SpecificPipeline'. The pipeline definition ID.
    .OUTPUTS Hashtable with Status (PASS/WARN/FAIL), Message, EndpointId.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScName,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject,
        [ValidateSet('AllPipelines','SpecificPipeline')]
        [string]$Scope = 'AllPipelines',
        [int]$PipelineId = 0
    )

    if ($Scope -eq 'SpecificPipeline' -and $PipelineId -le 0) {
        return @{
            Status  = 'FAIL'
            Message = 'PipelineId is required when Scope is SpecificPipeline'
        }
    }

    # Look up the service endpoint by name
    $epResult = Invoke-AzCommand 'devops', 'service-endpoint', 'list', `
        '--org', $AdoOrgUrl, '--project', $AdoProject, `
        '--query', "[?name=='$ScName'].{id:id, name:name}", '-o', 'json'

    if ($epResult.ExitCode -ne 0 -or -not $epResult.Output -or $epResult.Output -eq '[]') {
        return @{
            Status  = 'WARN'
            Message = "Service connection '$ScName' not found yet \u2014 the pipeline will prompt for authorization on first run"
            Fix     = "Contact the CELA SPEAR team (CELAVibeShieldSupport@microsoft.com) to provision it."
        }
    }

    $endpointId = $null
    try {
        $endpoints = @($epResult.Output | ConvertFrom-Json)
        if ($endpoints.Count -gt 0) { $endpointId = $endpoints[0].id }
    } catch {
        return @{
            Status  = 'FAIL'
            Message = "Could not parse service endpoint response: $($_.Exception.Message)"
            Fix     = "Run: az devops service-endpoint list --org $AdoOrgUrl --project $AdoProject -o table"
        }
    }

    if (-not $endpointId) {
        return @{
            Status  = 'WARN'
            Message = "Service connection '$ScName' not found yet \u2014 the pipeline will prompt for authorization on first run"
            Fix     = "If the SC should already exist: Project Settings > Service connections > New > Azure Resource Manager"
        }
    }

    if ($Scope -eq 'AllPipelines') {
        # Blanket authorization: enable for all pipelines
        $authResult = Invoke-AzCommand 'devops', 'service-endpoint', 'update', `
            '--id', $endpointId, '--enable-for-all', 'true', `
            '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json'

        if ($authResult.ExitCode -eq 0) {
            return @{
                Status     = 'PASS'
                Message    = "Service connection '$ScName' authorized for all pipelines"
                EndpointId = $endpointId
            }
        }

        # Detect unresolved identity (null GUID pattern) — re-login to Corp tenant and retry
        if ($authResult.Output -match 'TF400813' -and $authResult.Output -match '[0a]{8}-[0a]{4}-[0a]{4}-[0a]{4}-[0a]{12}') {
            $corpTenantId = (Get-DeployConfig).tenants.corp.id
            Write-Output "  ⚠️ ADO cannot resolve your identity — re-authenticating to Corp tenant..." | Out-Host
            $loginResult = Invoke-AzCommand login --tenant $corpTenantId --only-show-errors -TimeoutSeconds 120
            if ($loginResult.ExitCode -eq 0) {
                $retryResult = Invoke-AzCommand 'devops', 'service-endpoint', 'update', `
                    '--id', $endpointId, '--enable-for-all', 'true', `
                    '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json'
                if ($retryResult.ExitCode -eq 0) {
                    return @{
                        Status     = 'PASS'
                        Message    = "Service connection '$ScName' authorized for all pipelines (after re-login)"
                        EndpointId = $endpointId
                    }
                }
            }
            return @{
                Status  = 'WARN'
                Message = "ADO cannot resolve your identity (TF400813). Your account may lack Project Collection Administrator or Endpoint Administrator permissions."
                Fix     = "Authorize manually: Project Settings > Service connections > '$ScName' > Security > Grant access to all pipelines. If you lack access, contact the CELA SPEAR team (CELAVibeShieldSupport@microsoft.com)."
            }
        }

        return @{
            Status  = 'WARN'
            Message = "Could not authorize service connection programmatically: $($authResult.Output)"
            Fix     = "Authorize manually: Project Settings > Service connections > '$ScName' > Security > Grant access to all pipelines"
        }
    }

    # SpecificPipeline: per-pipeline authorization via REST API
    $apiUrl = "$AdoOrgUrl/$AdoProject/_apis/pipelines/pipelinepermissions/endpoint/$($endpointId)?api-version=7.1-preview.1"
    $body = @{
        pipelines = @(
            @{ id = $PipelineId; authorized = $true }
        )
    } | ConvertTo-Json -Depth 3 -Compress

    $authResult = Invoke-AzCommand 'rest', '--method', 'PATCH', `
        '--uri', $apiUrl, `
        '--body', $body, `
        '--headers', 'Content-Type=application/json', '-o', 'json'

    if ($authResult.ExitCode -eq 0) {
        return @{
            Status     = 'PASS'
            Message    = "Service connection '$ScName' authorized for pipeline (definition $PipelineId)"
            EndpointId = $endpointId
        }
    }

    # Check if error indicates already authorized
    if ($authResult.Output -match 'already authorized|already has access') {
        return @{
            Status     = 'PASS'
            Message    = "Service connection '$ScName' already authorized for pipeline"
            EndpointId = $endpointId
        }
    }

    # Detect unresolved identity (null GUID pattern) — re-login to Corp tenant and retry
    if ($authResult.Output -match 'TF400813' -and $authResult.Output -match '[0a]{8}-[0a]{4}-[0a]{4}-[0a]{4}-[0a]{12}') {
        $corpTenantId = (Get-DeployConfig).tenants.corp.id
        Write-Output "  ⚠️ ADO cannot resolve your identity — re-authenticating to Corp tenant..." | Out-Host
        $loginResult = Invoke-AzCommand login --tenant $corpTenantId --only-show-errors -TimeoutSeconds 120
        if ($loginResult.ExitCode -eq 0) {
            $retryResult = Invoke-AzCommand 'rest', '--method', 'PATCH', `
                '--uri', $apiUrl, `
                '--body', $body, `
                '--headers', 'Content-Type=application/json', '-o', 'json'
            if ($retryResult.ExitCode -eq 0) {
                return @{
                    Status     = 'PASS'
                    Message    = "Service connection '$ScName' authorized for pipeline (after re-login)"
                    EndpointId = $endpointId
                }
            }
        }
        return @{
            Status  = 'WARN'
            Message = "ADO cannot resolve your identity (TF400813). Your account may lack Endpoint Administrator permissions for this project."
            Fix     = "Authorize manually: open the pipeline in ADO portal > click 'Authorize resources' when prompted on first run. If you lack access, contact the CELA SPEAR team (CELAVibeShieldSupport@microsoft.com)."
        }
    }

    return @{
        Status  = 'WARN'
        Message = "Could not authorize service connection programmatically: $($authResult.Output)"
        Fix     = "Authorize manually: open the pipeline in ADO portal > click 'Authorize resources' when prompted on first run"
    }
}

function Get-PipelineTemplateSetting {
    <#
    .SYNOPSIS Returns a pipeline template setting from config or default.
    .DESCRIPTION
        Reads from pipelineFrameworks.1ES first (canonical), falls back to
        legacy pipelineTemplate section for backward compatibility.
    .PARAMETER Key     Config key (name, poolName, repoName, repoRef).
    .PARAMETER Default Fallback value.
    #>
    param([string]$Key, [string]$Default)
    try {
        $cfg = Get-DeployConfig
        # Primary: pipelineFrameworks.1ES
        if ($cfg.PSObject.Properties['pipelineFrameworks'] -and $cfg.pipelineFrameworks.PSObject.Properties['1ES']) {
            $fw = $cfg.pipelineFrameworks.'1ES'
            # Map legacy keys to framework structure
            $val = switch ($Key) {
                'name'     { if ($fw.PSObject.Properties['unofficial']) { $fw.unofficial.templateName } else { $null } }
                'poolName' { if ($fw.PSObject.Properties['pool'] -and $fw.pool.PSObject.Properties['name']) { $fw.pool.name } else { $null } }
                'repoName' { if ($fw.PSObject.Properties['repoName']) { $fw.repoName } else { $null } }
                'repoRef'  { if ($fw.PSObject.Properties['repoRef']) { $fw.repoRef } else { $null } }
                default    { $null }
            }
            if ($val) { return $val }
        }
        # Fallback: legacy pipelineTemplate section
        if ($cfg.PSObject.Properties['pipelineTemplate'] -and $cfg.pipelineTemplate.PSObject.Properties[$Key]) {
            return $cfg.pipelineTemplate.$Key
        }
    } catch { <# config unavailable — use default #> $null = $_ }
    return $Default
}

function Get-ServiceDescription {
    <#
    .SYNOPSIS Auto-generates a service description (max 40 chars) from workspace metadata.
    .DESCRIPTION
        Tries these sources in order:
        1. package.json → description
        2. *.csproj → <Description>
        3. pyproject.toml → description
        4. First non-empty, non-heading line of README.md
        5. Fallback: "{ServiceName} service"
    .PARAMETER WorkspacePath  Root of the workspace.
    .PARAMETER ServiceName    Fallback service name for constructing default description.
    .OUTPUTS System.String — max 40 characters.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PWD.Path,
        [string]$ServiceName = ''
    )
    $desc = $null

    # 1. package.json
    $pkgJson = Join-Path -Path $WorkspacePath -ChildPath 'package.json'
    if (Test-Path $pkgJson) {
        try {
            $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
            if ($pkg.description) { $desc = $pkg.description }
        } catch { $null = $_ }
    }

    # 2. *.csproj <Description>
    if (-not $desc) {
        $csproj = Get-ChildItem -Path $WorkspacePath -Filter '*.csproj' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($csproj) {
            $content = Get-Content $csproj.FullName -Raw
            if ($content -match '<Description>([^<]+)</Description>') {
                $desc = $Matches[1].Trim()
            }
        }
    }

    # 3. pyproject.toml
    if (-not $desc) {
        $pyproj = Join-Path -Path $WorkspacePath -ChildPath 'pyproject.toml'
        if (Test-Path $pyproj) {
            $lines = Get-Content $pyproj
            foreach ($line in $lines) {
                if ($line -match '^\s*description\s*=\s*"([^"]+)"') {
                    $desc = $Matches[1]
                    break
                }
            }
        }
    }

    # 4. README.md first content line
    if (-not $desc) {
        $readme = Join-Path -Path $WorkspacePath -ChildPath 'README.md'
        if (Test-Path $readme) {
            $lines = Get-Content $readme
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -and $trimmed -notmatch '^#') {
                    $desc = $trimmed
                    break
                }
            }
        }
    }

    # 5. Fallback
    if (-not $desc) {
        $desc = if ($ServiceName) { "$ServiceName service" } else { 'Application service' }
    }

    # Truncate to 40 chars
    if ($desc.Length -gt 40) { $desc = $desc.Substring(0, 37) + '...' }
    return $desc
}

function Get-ApplicationBackingServices {
    <#
    .SYNOPSIS Scans workspace to discover required Azure backing services (WI-1).
    .DESCRIPTION
        Analyzes csproj package references, appsettings connection strings,
        ARM template appSettings, migration directories, and system spec files
        to determine what Azure services the application requires.
    .PARAMETER WorkspacePath  Workspace root.
    .OUTPUTS Array of hashtables with Type, Source, and optional metadata fields.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)

    $services = [System.Collections.ArrayList]::new()

    # 1. Scan *.csproj for database provider packages
    $csprojFiles = Get-ChildItem $WorkspacePath -Recurse -Depth 5 -Filter '*.csproj' -ErrorAction SilentlyContinue
    foreach ($f in $csprojFiles) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match 'Microsoft\.EntityFrameworkCore\.SqlServer') {
            $null = $services.Add(@{ Type = 'SQL'; Source = "PackageRef in $($f.Name)" })
        }
        if ($content -match 'Npgsql\.EntityFrameworkCore|Npgsql') {
            $null = $services.Add(@{ Type = 'PostgreSQL'; Source = "PackageRef in $($f.Name)" })
        }
        if ($content -match 'Azure\.Storage\.Blobs|WindowsAzure\.Storage') {
            $null = $services.Add(@{ Type = 'BlobStorage'; Source = "PackageRef in $($f.Name)" })
        }
        if ($content -match 'Azure\.Messaging\.ServiceBus') {
            $null = $services.Add(@{ Type = 'ServiceBus'; Source = "PackageRef in $($f.Name)" })
        }
        if ($content -match 'Azure\.Security\.KeyVault') {
            $null = $services.Add(@{ Type = 'KeyVault'; Source = "PackageRef in $($f.Name)" })
        }
        if ($content -match 'MongoDB\.Driver') {
            $null = $services.Add(@{ Type = 'CosmosDB'; Source = "PackageRef in $($f.Name)" })
        }
        if ($content -match 'Microsoft\.Azure\.Cosmos') {
            $null = $services.Add(@{ Type = 'CosmosDB'; Source = "PackageRef in $($f.Name)" })
        }
    }

    # 2. Scan appsettings*.json for connection string keys
    $appSettings = Get-ChildItem $WorkspacePath -Recurse -Depth 5 -Filter 'appsettings*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'node_modules|bin[/\\]|obj[/\\]' }
    foreach ($f in $appSettings) {
        try {
            $json = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($json -and $json.PSObject.Properties['ConnectionStrings']) {
                foreach ($prop in $json.ConnectionStrings.PSObject.Properties) {
                    $connType = 'SQL'  # default
                    if ($prop.Value -match 'AccountEndpoint.*documents\.azure\.com') { $connType = 'CosmosDB' }
                    elseif ($prop.Value -match 'BlobEndpoint|blob\.core') { $connType = 'BlobStorage' }
                    $null = $services.Add(@{ Type = $connType; Source = "ConnectionString '$($prop.Name)' in $($f.Name)" })
                }
            }
            # Detect KeyVault from endpoint URL properties
            $jsonContent = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($jsonContent -match 'KeyVaultEndpoint|KeyVault.*vault\.azure\.net|KEYVAULT_URI') {
                $null = $services.Add(@{ Type = 'KeyVault'; Source = "KeyVault endpoint in $($f.Name)" })
            }
        } catch { $null = $_ }
    }

    # 3. Scan ARM/Bicep template appSettings for service patterns
    $templateFiles = @()
    $templateFiles += @(Get-ChildItem $WorkspacePath -Recurse -Depth 5 -Filter '*.Template.json' -ErrorAction SilentlyContinue)
    $infraDir = Join-Path -Path $WorkspacePath -ChildPath 'infra'
    if (Test-Path $infraDir) {
        $templateFiles += @(Get-ChildItem $infraDir -Recurse -Depth 3 -Filter '*.bicep' -ErrorAction SilentlyContinue)
    }
    foreach ($f in $templateFiles) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match 'ConnectionStrings__') {
            $null = $services.Add(@{ Type = 'SQL'; Source = "AppSetting in $($f.Name)" })
        }
        if ($content -match 'AzureWebJobsStorage') {
            $null = $services.Add(@{ Type = 'Storage'; Source = "AppSetting in $($f.Name)" })
        }
        if ($content -match 'KeyVaultEndpoint|KeyVault|KEYVAULT_URI') {
            $null = $services.Add(@{ Type = 'KeyVault'; Source = "AppSetting in $($f.Name)" })
        }
        if ($content -match 'APPLICATIONINSIGHTS_CONNECTION_STRING|ApplicationInsights') {
            $null = $services.Add(@{ Type = 'AppInsights'; Source = "AppSetting in $($f.Name)" })
        }
    }

    # 4. Check for migration directories
    $migrationPaths = @('sql/migrations', 'sql/Migrations', 'Migrations', 'db/migrations')
    foreach ($mp in $migrationPaths) {
        $dir = Join-Path -Path $WorkspacePath -ChildPath $mp
        if (Test-Path $dir) {
            $allFiles = Get-ChildItem $dir -Filter '*.sql' -ErrorAction SilentlyContinue
            $forward = @($allFiles | Where-Object { $_.Name -notmatch '^rollback' })
            $rollback = @($allFiles | Where-Object { $_.Name -match '^rollback' })
            $null = $services.Add(@{
                Type           = 'SQLMigrations'
                Source         = $mp
                ForwardCount   = $forward.Count
                RollbackCount  = $rollback.Count
                RollbackPattern = 'rollback-*.sql'
            })
        }
    }
    # Also check for EF Core migrations (C# files)
    $efMigrations = Join-Path -Path $WorkspacePath -ChildPath 'Migrations'
    if ((Test-Path $efMigrations) -and (Get-ChildItem $efMigrations -Filter '*.cs' -ErrorAction SilentlyContinue)) {
        $csFiles = @(Get-ChildItem $efMigrations -Filter '*.cs' -ErrorAction SilentlyContinue)
        $null = $services.Add(@{
            Type          = 'EFMigrations'
            Source        = 'Migrations/'
            MigrationCount = $csFiles.Count
        })
    }

    # 5. Read system spec if it exists
    $specFiles = Get-ChildItem $WorkspacePath -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'spec.*\.md$|requirements.*\.md$' -and -not $_.PSIsContainer } |
        Select-Object -First 1
    if ($specFiles) {
        $specContent = Get-Content $specFiles.FullName -Raw -ErrorAction SilentlyContinue
        if ($specContent) {
            if ($specContent -match 'Azure SQL|SQL Database') {
                $null = $services.Add(@{ Type = 'SQL'; Source = "Spec: $($specFiles.Name)" })
            }
            if ($specContent -match 'Blob Storage|Azure Storage') {
                $null = $services.Add(@{ Type = 'Storage'; Source = "Spec: $($specFiles.Name)" })
            }
            if ($specContent -match 'Key Vault') {
                $null = $services.Add(@{ Type = 'KeyVault'; Source = "Spec: $($specFiles.Name)" })
            }
            if ($specContent -match 'Application Insights') {
                $null = $services.Add(@{ Type = 'AppInsights'; Source = "Spec: $($specFiles.Name)" })
            }
            # Extract storage SKU
            if ($specContent -match 'Standard[\s_]GRS') {
                $null = $services.Add(@{ Type = 'StorageSKU'; Source = "Spec: $($specFiles.Name)"; Value = 'Standard_GRS' })
            }
            if ($specContent -match 'Standard[\s_]LRS') {
                $null = $services.Add(@{ Type = 'StorageSKU'; Source = "Spec: $($specFiles.Name)"; Value = 'Standard_LRS' })
            }
        }
    }

    # Deduplicate by type, merge sources
    $grouped = $services | Group-Object { $_.Type }
    $result = [System.Collections.ArrayList]::new()
    foreach ($g in $grouped) {
        $sources = @($g.Group | ForEach-Object { $_.Source } | Select-Object -Unique)
        $entry = @{ Type = $g.Name; Sources = $sources }
        # Carry forward metadata from typed entries
        $meta = $g.Group | Where-Object { $_.Keys.Count -gt 2 } | Select-Object -First 1
        if ($meta) {
            foreach ($k in $meta.Keys) {
                if ($k -notin @('Type', 'Source')) { $entry[$k] = $meta[$k] }
            }
        }
        $null = $result.Add($entry)
    }
    return @($result)
}

function Get-NodeAppRequirements {
    <#
    .SYNOPSIS Scans a Node.js module directory for deployment requirements (IL-1).
    .DESCRIPTION
        Analyzes package.json, .env files, and source code to discover:
        entry point, startup command, required env vars, eager SDK initializations,
        archive root, workspace configuration, filesystem write patterns, and CORS origins.
    .PARAMETER ModulePath  Path to the Node.js module directory.
    .PARAMETER WorkspacePath  Root workspace path (for relative path calculations).
    .OUTPUTS PSCustomObject with EntryPoint, StartupCommand, RequiredEnvVars, EagerSdkInits,
             ArchiveRoot, UsesWorkspaces, WritesFilesystem, CorsOrigins, NeedsSCMBuildOff.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [string]$WorkspacePath = $ModulePath
    )

    $result = [PSCustomObject]@{
        EntryPoint       = $null
        StartupCommand   = $null
        RequiredEnvVars  = [System.Collections.ArrayList]::new()
        EagerSdkInits    = [System.Collections.ArrayList]::new()
        ArchiveRoot      = $null
        UsesWorkspaces   = $false
        WritesFilesystem = [System.Collections.ArrayList]::new()
        CorsOrigins      = [System.Collections.ArrayList]::new()
        NeedsSCMBuildOff = $false
    }

    # 1. Parse package.json for entry point and workspaces
    $pkgPath = Join-Path -Path $ModulePath -ChildPath 'package.json'
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($pkg) {
                # Entry point: main > scripts.start > default
                if ($pkg.PSObject.Properties['main']) {
                    $result.EntryPoint = $pkg.main
                } elseif ($pkg.PSObject.Properties['scripts'] -and $pkg.scripts.PSObject.Properties['start']) {
                    $startScript = $pkg.scripts.start
                    # Extract the file from "node server.js" or "nodemon index.js" etc
                    if ($startScript -match '(?:node|nodemon|ts-node|tsx)\s+(.+?)(?:\s|$)') {
                        $result.EntryPoint = $Matches[1].Trim()
                    } else {
                        $result.EntryPoint = $startScript
                    }
                }

                # Workspaces
                if ($pkg.PSObject.Properties['workspaces']) {
                    $result.UsesWorkspaces = $true
                }
            }
        } catch { Write-Verbose "Failed to parse $pkgPath`: $_" }
    }

    # Default entry point
    if (-not $result.EntryPoint) {
        foreach ($candidate in @('index.js', 'server.js', 'app.js', 'src/index.js', 'dist/index.js')) {
            if (Test-Path (Join-Path -Path $ModulePath -ChildPath $candidate)) {
                $result.EntryPoint = $candidate
                break
            }
        }
    }

    # Derive startup command from entry point
    if ($result.EntryPoint) {
        $result.StartupCommand = "node $($result.EntryPoint)"
    }

    # Determine archive root (relative to workspace)
    if ($ModulePath -ne $WorkspacePath) {
        $relPath = [System.IO.Path]::GetRelativePath($WorkspacePath, $ModulePath)
        $result.ArchiveRoot = ($relPath -replace '\\', '/').TrimEnd('/')
    }

    # 2. Parse .env.example / .env.sample for required env vars
    $envFiles = @('.env.example', '.env.sample', '.env.template')
    foreach ($envFile in $envFiles) {
        $envPath = Join-Path -Path $ModulePath -ChildPath $envFile
        if (Test-Path $envPath) {
            $lines = Get-Content $envPath -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=' -and $line -notmatch '^\s*#') {
                    $null = $result.RequiredEnvVars.Add($Matches[1])
                }
            }
        }
    }

    # 3. Scan source files for process.exit guards, SDK inits, fs writes, CORS
    $jsFiles = Get-ChildItem $ModulePath -Recurse -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.js', '.ts', '.mjs', '.cjs') -and
                       $_.FullName -notmatch 'node_modules|\.test\.|\.spec\.|__tests__' }

    foreach ($f in $jsFiles) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # process.exit gated on missing env vars
        $exitMatches = [regex]::Matches($content, 'if\s*\(\s*!process\.env\.([A-Z_][A-Z0-9_]*)\s*\)[\s\S]{0,100}process\.exit')
        foreach ($m in $exitMatches) {
            $varName = $m.Groups[1].Value
            if ($varName -notin $result.RequiredEnvVars) {
                $null = $result.RequiredEnvVars.Add($varName)
            }
        }

        # Eager SDK initializations that throw without keys
        $sdkPatterns = @(
            @{ Pattern = 'new\s+OpenAI\s*\('; Name = 'OpenAI' }
            @{ Pattern = 'new\s+Stripe\s*\('; Name = 'Stripe' }
            @{ Pattern = 'new\s+Twilio\s*\('; Name = 'Twilio' }
            @{ Pattern = 'new\s+SendGrid\s*\('; Name = 'SendGrid' }
        )
        foreach ($sdk in $sdkPatterns) {
            if ($content -match $sdk.Pattern) {
                # Heuristic: check if the SDK init is at module level (not deeply nested)
                # Use regex match index to determine line number safely
                try {
                    $match = [regex]::Match($content, $sdk.Pattern)
                    if ($match.Success) {
                        $beforeMatch = $content.Substring(0, $match.Index)
                        $lineNum = ($beforeMatch -split "`n").Count
                        if ($lineNum -lt 50) {
                            if ($sdk.Name -notin $result.EagerSdkInits) {
                                $null = $result.EagerSdkInits.Add($sdk.Name)
                            }
                        }
                    }
                } catch { $null = $_ }  # Safe fallback — skip this SDK check
            }
        }

        # Filesystem writes (data persistence risk)
        $fsWriteMatches = [regex]::Matches($content, "(?:fs\.writeFileSync|fs\.mkdirSync|fs\.appendFileSync)\s*\(\s*['""]?([^'"")\s,]+)")
        foreach ($m in $fsWriteMatches) {
            $writePath = $m.Groups[1].Value
            # Normalize — resolve path.join patterns
            if ($writePath -match 'path\.join' -or $writePath -match '__dirname') { continue }  # too complex to resolve statically
            if ($writePath -notin $result.WritesFilesystem) {
                $null = $result.WritesFilesystem.Add($writePath)
            }
        }

        # CORS origins
        $corsMatches = [regex]::Matches($content, "cors\s*\(\s*\{\s*origin\s*:\s*['""]([^'""]+)['""]")
        foreach ($m in $corsMatches) {
            $origin = $m.Groups[1].Value
            if ($origin -notin $result.CorsOrigins) {
                $null = $result.CorsOrigins.Add($origin)
            }
        }
    }

    # 4. Determine if SCM build should be disabled
    # If node_modules exists or package-lock.json exists (pipeline will install), ZIP deploy should skip Oryx
    $hasLockFile = (Test-Path (Join-Path -Path $ModulePath -ChildPath 'package-lock.json')) -or
                   (Test-Path (Join-Path -Path $ModulePath -ChildPath 'yarn.lock')) -or
                   (Test-Path (Join-Path -Path $ModulePath -ChildPath 'pnpm-lock.yaml'))
    if ($hasLockFile) {
        $result.NeedsSCMBuildOff = $true  # Pipeline will install deps; Oryx should not re-run
    }

    # Deduplicate
    $result.RequiredEnvVars = [System.Collections.ArrayList]::new(@($result.RequiredEnvVars | Select-Object -Unique))

    return $result
}

function Get-ResourceGroupContext {
    <#
    .SYNOPSIS Infers resource group location from naming convention and flags mismatches (WI-3).
    .PARAMETER ResourceGroupName  Name of the resource group.
    .OUTPUTS PSCustomObject with InferredLocation, InferredLocationCode, WARNING.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceGroupName)

    $locationMap = @{
        'eus'  = 'eastus';       'eus2' = 'eastus2';      'wus'  = 'westus'
        'wus2' = 'westus2';      'wus3' = 'westus3';      'cus'  = 'centralus'
        'ncus' = 'northcentralus'; 'scus' = 'southcentralus'
        'weu'  = 'westeurope';   'neu'  = 'northeurope'
        'sea'  = 'southeastasia'; 'aue' = 'australiaeast'
        'uks'  = 'uksouth';      'jpe'  = 'japaneast'
    }

    $result = [PSCustomObject]@{
        ResourceGroupName   = $ResourceGroupName
        InferredLocation    = $null
        InferredLocationCode = $null
        WARNING             = $null
    }

    foreach ($code in ($locationMap.Keys | Sort-Object { $_.Length } -Descending)) {
        if ($ResourceGroupName -match "[-_]${code}(\d|$|-|_)") {
            $result.InferredLocation = $locationMap[$code]
            $result.InferredLocationCode = $code
            break
        }
    }

    if ($result.InferredLocation) {
        $result.WARNING = "RG name suggests '$($result.InferredLocation)' but actual Azure location may differ. " +
            "Verify RG location and set explicit location parameters for region-restricted resources (e.g., SQL Server)."
    } else {
        $result.WARNING = "Could not infer location from RG name '$ResourceGroupName'. " +
            "Set explicit location parameters for all resources."
    }

    return $result
}

function Invoke-GitCommand {
    <#
    .SYNOPSIS Runs a git command and returns output + exit code.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for the command. Defaults to 120 (2 minutes).
        Set to 0 for no timeout.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Cross-module token cache by design')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '')]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    # Extract -TimeoutSeconds from Arguments if present (PowerShell can't mix
    # ValueFromRemainingArguments with other named params reliably)
    $TimeoutSeconds = 120
    $cleanArgs = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '-TimeoutSeconds' -and $i + 1 -lt $Arguments.Count) {
            $TimeoutSeconds = [int]$Arguments[$i + 1]; $i++
        } else { $cleanArgs += $Arguments[$i] }
    }
    $Arguments = $cleanArgs
    # Suppress interactive prompts: no credential UI, no editor, no pager
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_EDITOR = 'true'
    $env:GCM_INTERACTIVE = 'never'
    $env:GIT_PAGER = ''
    # Suppress VS Code's built-in credential UI (separate from GCM_INTERACTIVE)
    $env:GIT_ASKPASS = ''

    # Bearer token is injected via GIT_CONFIG_* env vars (set by Get-AdoGitToken).
    # Do NOT inject -c credential.helper= (disables GCM fallback) or -c http.extraheader
    # (duplicates the env-var header and uses wrong casing, causing HTTP 400 on ADO).
    # GCM remains as a fallback if the bearer token is missing/expired.

    if ($TimeoutSeconds -le 0) {
        $raw = & git @Arguments 2>&1 | Out-String
        $ec  = $LASTEXITCODE
        return [pscustomobject]@{ Output = $raw.Trim(); ExitCode = $ec }
    }

    # Snapshot GIT_CONFIG_* env vars so the bearer token propagates into the job.
    # Start-Job runs in a new process that does not inherit the parent's env vars.
    $gitConfigCount = 0
    if ($env:GIT_CONFIG_COUNT -and [int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$gitConfigCount) -and $gitConfigCount -gt 0) {
        $gitConfigKeys   = @()
        $gitConfigValues = @()
        for ($i = 0; $i -lt $gitConfigCount; $i++) {
            $k = (Get-Item -Path "Env:GIT_CONFIG_KEY_$i" -ErrorAction SilentlyContinue).Value
            $v = (Get-Item -Path "Env:GIT_CONFIG_VALUE_$i" -ErrorAction SilentlyContinue).Value
            $gitConfigKeys   += $k
            $gitConfigValues += $v
        }
    } else {
        $gitConfigKeys   = @()
        $gitConfigValues = @()
        $gitConfigCount  = 0
    }

    # Run with timeout using Start-Job — capture $LASTEXITCODE inside the job
    $job = Start-Job -ScriptBlock {
        param($args_, [int]$cfgCount, [string[]]$cfgKeys, [string[]]$cfgValues)
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GIT_EDITOR = 'true'
        $env:GCM_INTERACTIVE = 'never'
        $env:GIT_PAGER = ''
        # Propagate bearer token auth (and any other git config entries) from parent process
        if ($cfgCount -gt 0) {
            $env:GIT_CONFIG_COUNT = "$cfgCount"
            for ($i = 0; $i -lt $cfgCount; $i++) {
                if ($i -lt $cfgKeys.Count -and $cfgKeys[$i]) { Set-Item -Path "Env:GIT_CONFIG_KEY_$i"   -Value $cfgKeys[$i] }
                if ($i -lt $cfgValues.Count -and $cfgValues[$i]) { Set-Item -Path "Env:GIT_CONFIG_VALUE_$i" -Value $cfgValues[$i] }
            }
        }
        $out = & git @args_ 2>&1 | Out-String
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } -ArgumentList (,$Arguments), $gitConfigCount, (,$gitConfigKeys), (,$gitConfigValues)

    $completed = $job | Wait-Job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
        $job | Stop-Job -PassThru | Remove-Job -Force
        return [pscustomobject]@{ Output = "ERROR: git command timed out after ${TimeoutSeconds}s. Arguments: $($Arguments -join ' ')"; ExitCode = 124 }
    }
    $result = $job | Receive-Job
    $job | Remove-Job -Force
    if ($result -is [hashtable] -and $result.ContainsKey('ExitCode')) {
        [pscustomobject]@{ Output = "$($result.Output)".Trim(); ExitCode = [int]$result.ExitCode }
    } else {
        # Fallback if job returned raw output (e.g. job failed before return)
        $ec = if ($job.State -eq 'Failed') { 1 } else { 0 }
        [pscustomobject]@{ Output = "$result".Trim(); ExitCode = $ec }
    }
}

function Invoke-AzCommand {
    <#
    .SYNOPSIS Runs an az CLI command and returns output + exit code.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for the command. Defaults to 300 (5 minutes).
        Set to 0 for no timeout.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '')]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    # Extract -TimeoutSeconds from Arguments if present
    $TimeoutSeconds = 300
    $cleanArgs = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '-TimeoutSeconds' -and $i + 1 -lt $Arguments.Count) {
            $TimeoutSeconds = [int]$Arguments[$i + 1]; $i++
        } else { $cleanArgs += $Arguments[$i] }
    }
    $Arguments = $cleanArgs
    # Suppress interactive prompts and browser-based login
    $env:AZURE_CORE_NO_PROMPT = 'true'

    if ($TimeoutSeconds -le 0) {
        $raw = & az @Arguments --only-show-errors 2>&1 | Out-String
        $ec  = $LASTEXITCODE
        return [pscustomobject]@{ Output = $raw.Trim(); ExitCode = $ec }
    }

    # Run with timeout using Start-Job — capture $LASTEXITCODE inside the job
    $job = Start-Job -ScriptBlock {
        param($args_)
        $env:AZURE_CORE_NO_PROMPT = 'true'
        $out = & az @args_ --only-show-errors 2>&1 | Out-String
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } -ArgumentList (,$Arguments)

    $completed = $job | Wait-Job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
        $job | Stop-Job -PassThru | Remove-Job -Force
        return [pscustomobject]@{ Output = "ERROR: az command timed out after ${TimeoutSeconds}s. Arguments: $($Arguments -join ' ')"; ExitCode = 124 }
    }
    $result = $job | Receive-Job
    $job | Remove-Job -Force
    if ($result -is [hashtable] -and $result.ContainsKey('ExitCode')) {
        [pscustomobject]@{ Output = "$($result.Output)".Trim(); ExitCode = [int]$result.ExitCode }
    } else {
        # Fallback if job returned raw output (e.g. job failed before return)
        $ec = if ($job.State -eq 'Failed') { 1 } else { 0 }
        [pscustomobject]@{ Output = "$result".Trim(); ExitCode = $ec }
    }
}

# Global-scope token cache — populated on first call to Get-AdoGitToken.
# Uses global scope so the cache is reliably accessible across all dot-source and module boundaries.
# Get-AdoGitToken sets GIT_CONFIG_COUNT/KEY_0/VALUE_0 env vars so that git commands
# automatically pick up the bearer token without per-command -c flags.
if (-not (Get-Variable -Name 'AdoGitTokenCache' -Scope Global -ErrorAction SilentlyContinue)) {
    New-Variable -Name 'AdoGitTokenCache' -Scope Global -Value $null
}

function Clear-AdoGitTokenCache {
    <#
    .SYNOPSIS Clears the cached ADO bearer token so the next Get-AdoGitToken call re-acquires a fresh token.
    .DESCRIPTION
        Call this when a git operation returns HTTP 400/401/403 to force token re-acquisition.
        Clears both the global variable and the GIT_CONFIG_* env vars.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Cross-module token cache by design')]
    [CmdletBinding()]
    param()
    $global:AdoGitTokenCache = $null
    Remove-Item Env:GIT_CONFIG_COUNT   -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_KEY_0   -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
}

function Get-AdoGitToken {
    <#
    .SYNOPSIS
        Acquires a short-lived Azure DevOps bearer token from the Azure CLI.
        Returns the token string on success, $true for SSH remotes (no token needed),
        or $false if az CLI is unavailable or not logged in.
        Sets GIT_CONFIG_COUNT/KEY_0/VALUE_0 env vars for automatic git auth.
    .DESCRIPTION
        Caches the token in $global:AdoGitTokenCache so repeated calls within
        the same script run do not incur additional az CLI overhead.
        Reads the Corp tenant ID and ADO resource ID from deploy-config.json.
    .PARAMETER RemoteUrl
        The git remote URL. SSH URLs (git@, ssh://, ssh.dev.azure.com) are
        skipped — they use key-based auth and do not need the bearer header.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Cross-module token cache by design')]
    [CmdletBinding()]
    param(
        [string]$RemoteUrl = ''
    )

    # SSH remotes use key-based auth — bearer token injection does not apply
    if ($RemoteUrl -match '^git@|^ssh://|ssh\.dev\.azure\.com') {
        return $true
    }

    # Return cached token if already acquired this run
    if ($global:AdoGitTokenCache) {
        $env:GIT_CONFIG_COUNT   = '1'
        $env:GIT_CONFIG_KEY_0   = 'http.extraHeader'
        $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $($global:AdoGitTokenCache)"
        return $global:AdoGitTokenCache
    }

    $cfg = Get-DeployConfig
    $global:LASTEXITCODE = 0
    $token = $null
    try {
        $corpTenantId = $cfg.tenants.corp.id
        $token = (& az account get-access-token `
            --tenant $corpTenantId `
            --resource $cfg.azure.adoResourceId `
            --query accessToken -o tsv 2>$null)?.Trim()
    } catch { $null = $_ }

    if (-not $token -or $LASTEXITCODE -ne 0) {
        # Session expired or not logged in — attempt az login and retry
        Write-Output "  \u26a0\ufe0f Azure CLI session expired — running 'az login' to re-authenticate..." | Out-Host
        $global:LASTEXITCODE = 0
        $loginResult = Invoke-AzCommand login --tenant $corpTenantId --only-show-errors -TimeoutSeconds 120
        if ($loginResult.ExitCode -ne 0) {
            Write-Output "  \u274c az login failed — user must authenticate manually." | Out-Host
            return $false
        }
        # Retry token acquisition after successful login
        $token = $null
        $global:LASTEXITCODE = 0
        try {
            $token = (& az account get-access-token `
                --tenant $corpTenantId `
                --resource $cfg.azure.adoResourceId `
                --query accessToken -o tsv 2>$null)?.Trim()
        } catch { $null = $_ }
        if (-not $token -or $LASTEXITCODE -ne 0) { return $false }
    }

    $global:AdoGitTokenCache = $token
    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = 'http.extraHeader'
    $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $token"
    return $token
}

# ════════════════════════════════════════════════════════════
# CLI Pre-Checks
# ════════════════════════════════════════════════════════════

function Test-CliPrerequisites {
    <#
    .SYNOPSIS Validates that az CLI and git are installed, configured, and authenticated.
    .DESCRIPTION
        Run at orchestrator startup before Stage 1. Returns a list of issues.
        Empty issues means all prerequisites are met.
    .OUTPUTS PSCustomObject with Valid (bool), Issues (string[])
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [CmdletBinding()]
    param()

    $issues = @()

    # Check git is installed
    try {
        $null = & git --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $issues += 'git is not installed or not in PATH. Install Git from https://git-scm.com/' }
    } catch {
        $issues += 'git is not installed or not in PATH. Install Git from https://git-scm.com/'
    }

    # Check git user.email is configured
    if ($issues.Count -eq 0) {
        try {
            $gitEmail = & git config user.email 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitEmail)) {
                $issues += "git user.email is not configured. Run: git config --global user.email 'you@microsoft.com'"
            }
        } catch {
            $issues += "git user.email is not configured. Run: git config --global user.email 'you@microsoft.com'"
        }
    }

    # Check az CLI is installed
    try {
        $null = & az version -o tsv 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $issues += 'Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli' }
    } catch {
        $issues += 'Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli'
    }

    # Check az is logged in
    if (-not ($issues | Where-Object { $_ -match 'az.*not installed' })) {
        try {
            $null = & az account show -o json 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $issues += "Azure CLI is not logged in. Run: az login"
            }
        } catch {
            $issues += "Azure CLI is not logged in. Run: az login"
        }
    }

    [pscustomobject]@{
        Valid  = ($issues.Count -eq 0)
        Issues = $issues
    }
}

# ════════════════════════════════════════════════════════════
# Transient Retry with Exponential Backoff
# ════════════════════════════════════════════════════════════

function Invoke-WithRetry {
    <#
    .SYNOPSIS Retries a script block with exponential backoff for transient failures.
    .DESCRIPTION
        Executes the given script block. If it throws and the error matches a
        transient pattern, retries with increasing delays (30s, 60s, 120s).
        Non-transient errors are re-thrown immediately without retry.
    .PARAMETER ScriptBlock
        The code to execute.
    .PARAMETER MaxRetries
        Maximum retry attempts. Defaults to 3.
    .PARAMETER TransientPatterns
        Regex patterns that identify transient/retryable errors. Defaults to
        common Azure transient errors (503, 429, timing, throttle).
    .OUTPUTS The output of the script block on success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [string[]]$TransientPatterns = @(
            '503\s*Service Unavailable',
            '429\s*Too Many Requests',
            'Too many requests',
            'Cannot modify resource while it is being created',
            'throttled',
            'rate limit',
            'ETIMEDOUT',
            'ECONNRESET'
        )
    )

    $attempt = 0
    $backoffSeconds = 30

    while ($true) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            $errorMsg = $_.Exception.Message

            # Check if error is transient
            $isTransient = $false
            foreach ($pattern in $TransientPatterns) {
                if ($errorMsg -match $pattern) { $isTransient = $true; break }
            }

            if (-not $isTransient -or $attempt -ge $MaxRetries) {
                throw
            }

            Write-Warning "Transient error (attempt $attempt of $MaxRetries): $errorMsg"
            Write-Warning "Retrying in ${backoffSeconds}s..."
            Start-Sleep -Seconds $backoffSeconds
            $backoffSeconds = [Math]::Min($backoffSeconds * 2, 300)
        }
    }
}

# ════════════════════════════════════════════════════════════
# Output Sanitization
# ════════════════════════════════════════════════════════════

function Remove-SensitiveContent {
    <#
    .SYNOPSIS Sanitizes CLI output by redacting subscription IDs, tokens, connection strings, and secrets.
    .DESCRIPTION
        Applies regex replacements to remove common sensitive patterns from Azure CLI
        and git output before displaying to users or writing to SARIF files.
    .OUTPUTS System.String — sanitized text with sensitive values replaced by [REDACTED].
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][string]$Text)

    process {
        $sanitized = $Text
        # Subscription IDs (UUID format in /subscriptions/ paths)
        $sanitized = $sanitized -replace '/subscriptions/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', '/subscriptions/[REDACTED]'
        # Standalone UUIDs that look like tenant/client IDs (only in error context)
        $sanitized = $sanitized -replace '\b(tenant[Ii]d|client[Ii]d|appId|objectId)[''"\s:=]+[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', '$1=[REDACTED]'
        # Connection strings
        $sanitized = $sanitized -replace '(?i)(connection\s*string|Server=|Data Source=|AccountKey=)[^\s;''"]+', '$1[REDACTED]'
        # Bearer tokens
        $sanitized = $sanitized -replace '(?i)(Bearer\s+|token[''"\s:=]+)[A-Za-z0-9\-._~+/]+=*', '$1[REDACTED]'
        # Common secret patterns in key=value format
        $sanitized = $sanitized -replace '(?i)(password|apikey|secret|clientsecret|accesskey)[''"\s:=]+[^\s''"]+', '$1=[REDACTED]'

        return $sanitized
    }
}

function Test-ConfigFileSafe {
    <#
    .SYNOPSIS Validates that infra/config.ps1 only contains safe content.
    .DESCRIPTION
        Checks that the file matches an expected structure: either a simple
        '$Config = @{ ... }' hashtable assignment, or the VibeShield-Bicep
        convention using '$script:ResourceNames', functions, and scalar variables.
        Rejects files containing dangerous patterns like Invoke-Expression,
        network cmdlets, or destructive operations.
    .OUTPUTS PSCustomObject with Safe (bool) and Issues (string[]).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        return [pscustomobject]@{ Safe = $false; Issues = @("Config file not found: $ConfigPath") }
    }

    $issues = @()
    $content = Get-Content $ConfigPath -Raw

    # Must contain either $Config = @{ or $script:ResourceNames = @{
    if ($content -notmatch '\$Config\s*=\s*@\{' -and
        $content -notmatch '\$script:ResourceNames\s*=\s*@\{') {
        $issues += 'File does not contain expected $Config = @{ ... } or $script:ResourceNames = @{ ... } structure'
    }

    # Strip comment lines and inline comments before checking dangerous patterns
    # to avoid false positives from documentation (e.g., "soft-delete" in comments)
    $codeOnly = ($content -split "`n" | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"

    # Must NOT contain dangerous patterns (function definitions are allowed
    # for naming-convention helpers like Get-ResourceGroupName)
    $dangerousPatterns = @(
        @{ Pattern = 'Invoke-Expression|iex\s'; Description = 'Invoke-Expression calls' },
        @{ Pattern = 'Start-Process|Invoke-WebRequest|Invoke-RestMethod'; Description = 'Process/network cmdlets' },
        @{ Pattern = '\|\s*(ForEach|Where|Select|Sort)'; Description = 'Pipeline expressions' },
        @{ Pattern = '&\s+\$|&\s+[''"]'; Description = 'Call operator with dynamic target' },
        @{ Pattern = 'Remove-Item|(?<!\w)Delete(?!\w)|rm\s+-'; Description = 'Destructive operations' },
        @{ Pattern = 'New-Object\s+System\.Net'; Description = 'Network object creation' }
    )

    foreach ($dp in $dangerousPatterns) {
        if ($codeOnly -match $dp.Pattern) {
            $issues += "Unsafe content detected: $($dp.Description)"
        }
    }

    [pscustomobject]@{
        Safe   = ($issues.Count -eq 0)
        Issues = $issues
    }
}

# ════════════════════════════════════════════════════════════
# Input Validation
# ════════════════════════════════════════════════════════════

function Test-ParameterFormat {
    <#
    .SYNOPSIS Validates common deployment parameter formats.
    .DESCRIPTION
        Checks email, resource group name, branch name, and file path formats.
        Returns a list of issues. Empty list = all valid.
    .OUTPUTS PSCustomObject with Valid (bool) and Issues (string[]).
    #>
    [CmdletBinding()]
    param(
        [string]$Email,
        [string]$ResourceGroup,
        [string]$BranchName,
        [string]$FilePath
    )

    $issues = @()

    if ($Email -and $Email -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
        $issues += "Invalid email format: '$Email'"
    }
    if ($ResourceGroup -and $ResourceGroup -notmatch '^[a-zA-Z0-9._()-]{1,90}$') {
        $issues += "Invalid resource group name: '$ResourceGroup' (must be 1-90 chars: letters, digits, dots, hyphens, underscores, parentheses)"
    }
    if ($BranchName -and $BranchName -match '[;|&`$<>\\]') {
        $issues += "Invalid branch name: '$BranchName' (contains shell metacharacters)"
    }
    if ($FilePath -and ($FilePath -like '../*' -or $FilePath -like '*/../*' -or [System.IO.Path]::IsPathRooted($FilePath))) {
        $issues += "Invalid file path: '$FilePath' (path traversal or absolute path not allowed)"
    }

    [pscustomobject]@{
        Valid  = ($issues.Count -eq 0)
        Issues = $issues
    }
}

# ════════════════════════════════════════════════════════════
# SARIF Helpers
# ════════════════════════════════════════════════════════════

function Initialize-SarifCleanStart {
    <#
    .SYNOPSIS Archives previous SARIF to history, then deletes to ensure a clean start.
    .DESCRIPTION
        Before deleting the SARIF file, archives it to .vibeshield/results/history/
        with a timestamp suffix. Enforces a retention policy (default 10 per stage)
        deleting the oldest files when exceeded.
        Ensures the parent directory exists so Write-SarifReport does not fail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SarifPath)

    # Ensure output directory exists
    $sarifDir = Split-Path -Path $SarifPath -Parent
    if ($sarifDir -and -not (Test-Path $sarifDir)) {
        New-Item -ItemType Directory -Path $sarifDir -Force | Out-Null
    }

    # Archive existing SARIF before deletion
    if (Test-Path $SarifPath) {
        try {
            $historyDir = Join-Path -Path $sarifDir -ChildPath 'history'
            if (-not (Test-Path $historyDir)) {
                New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
            }

            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SarifPath)
            $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ')
            $archiveName = "${baseName}-${ts}.sarif"
            $archivePath = Join-Path -Path $historyDir -ChildPath $archiveName
            Copy-Item -Path $SarifPath -Destination $archivePath -Force

            # Enforce retention policy (keep last N per stage)
            $keepCount = 10
            try {
                $cfg = Get-DeployConfig
                if ($cfg.PSObject.Properties['logging'] -and $cfg.logging.PSObject.Properties['sarifHistoryCount'] -and $cfg.logging.sarifHistoryCount) {
                    $val = [int]$cfg.logging.sarifHistoryCount
                    if ($val -gt 0) { $keepCount = $val }
                }
            } catch { <# use default #> $null = $_ }

            $historyFiles = @(Get-ChildItem -Path $historyDir -Filter "${baseName}-*.sarif" |
                Sort-Object Name -Descending)
            if ($historyFiles.Count -gt $keepCount) {
                $historyFiles[$keepCount..($historyFiles.Count - 1)] | Remove-Item -Force
            }
        } catch {
            Write-Warning "Failed to archive SARIF to history: $_"
        }

        Remove-Item $SarifPath -Force
        Write-Output "  Cleaned previous SARIF: $SarifPath" | Out-Host
    }

    $bakPath = "$SarifPath.bak"
    if (Test-Path $bakPath) {
        Remove-Item $bakPath -Force
        Write-Output "  Cleaned legacy backup: $bakPath" | Out-Host
    }
}

function Format-SarifSummary {
    <#
    .SYNOPSIS  Produces a compact text summary from SARIF results.
    .DESCRIPTION
        Accepts an array of result objects (with status, name, message, and optional fix)
        and returns a multi-line string containing counts plus details for non-PASS results.
        Used by Write-SarifReport.ps1 to emit a _summary.txt alongside the .sarif file,
        giving agents a lightweight alternative to parsing full SARIF JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][object[]]$Results
    )

    $total   = $Results.Count
    $passed  = @($Results | Where-Object { $_.status -eq 'PASS' }).Count
    $failed  = @($Results | Where-Object { $_.status -eq 'FAIL' }).Count
    $warned  = @($Results | Where-Object { $_.status -eq 'WARN' }).Count
    $skipped = @($Results | Where-Object { $_.status -eq 'SKIP' }).Count

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("$ToolName — Total: $total | Passed: $passed | Failed: $failed | Warnings: $warned | Skipped: $skipped")

    $failures = @($Results | Where-Object { $_.status -eq 'FAIL' })
    if ($failures.Count -gt 0) {
        [void]$sb.AppendLine("FAILURES:")
        $i = 1
        foreach ($f in $failures) {
            [void]$sb.AppendLine("  $i. $($f.name): $($f.message)")
            if (($f.PSObject.Properties.Name -contains 'fix') -and $f.fix) {
                [void]$sb.AppendLine("     -> $($f.fix)")
            }
            $i++
        }
    }

    $warnings = @($Results | Where-Object { $_.status -eq 'WARN' })
    if ($warnings.Count -gt 0) {
        [void]$sb.AppendLine("WARNINGS:")
        $i = 1
        foreach ($w in $warnings) {
            [void]$sb.AppendLine("  $i. $($w.name): $($w.message)")
            if (($w.PSObject.Properties.Name -contains 'fix') -and $w.fix) {
                [void]$sb.AppendLine("     -> $($w.fix)")
            }
            $i++
        }
    }

    return $sb.ToString().TrimEnd()
}

# ════════════════════════════════════════════════════════════
# Build Pool OS Selection
# ════════════════════════════════════════════════════════════

function Get-BuildPoolOs {
    <#
    .SYNOPSIS Returns the pool OS for a given app type and pipeline framework.
    .DESCRIPTION
        Reads pool configuration from deploy-config.json:
        - Default OS from pipelineFrameworks.<framework>.pool.os (1ES) or .build.type (OneBranch)
        - Per-app-type overrides from pipelineFrameworks.<framework>.poolOverrides.<AppType>
        When no override exists, returns the framework default.
    .PARAMETER AppType  Canonical app type (e.g., '.NET', 'Python', 'Container').
    .PARAMETER Framework Pipeline framework: '1ES' or 'OneBranch'. Defaults to '1ES'.
    .OUTPUTS System.String — OS value (e.g., 'windows', 'linux') for 1ES, or type value for OneBranch.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppType,
        [ValidateSet('1ES','OneBranch')]
        [string]$Framework = '1ES'
    )

    $cfg = Get-DeployConfig
    $fwCfg = $cfg.pipelineFrameworks.$Framework

    # Check per-app-type override first
    if ($fwCfg.PSObject.Properties['poolOverrides'] -and
        $fwCfg.poolOverrides -is [PSCustomObject] -and
        $fwCfg.poolOverrides.PSObject.Properties[$AppType]) {
        return $fwCfg.poolOverrides.$AppType
    }

    # Return framework default
    if ($Framework -eq '1ES') {
        if ($fwCfg.pool.PSObject.Properties['os']) { return $fwCfg.pool.os } else { return 'windows' }
    } else {
        if ($fwCfg.pool.build.PSObject.Properties['type']) { return $fwCfg.pool.build.type } else { return 'windows' }
    }
}

# ════════════════════════════════════════════════════════════
# Deploy Context — Single Source of Truth for Parameters
# ════════════════════════════════════════════════════════════

function Resolve-ConfigPath {
    <#
    .SYNOPSIS Returns the resolved path to infra/config.ps1, handling case-insensitive
              filesystems (Linux) where the file may be named Config.ps1 or CONFIG.PS1.
    #>
    param([string]$WorkspacePath = $PWD.Path)
    $configPath = Join-Path -Path $WorkspacePath -ChildPath 'infra/config.ps1'
    if (-not (Test-Path $configPath)) {
        $infraDir = Get-ChildItem -Path $WorkspacePath -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq 'infra' } | Select-Object -First 1
        if ($infraDir) {
            $match = Get-ChildItem -Path $infraDir.FullName -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ieq 'config.ps1' } | Select-Object -First 1
            if ($match) { return $match.FullName }
        }
    }
    return $configPath
}

function Get-DeployContext {
    <#
    .SYNOPSIS Resolves deployment parameters from a multi-tier cascade.
    .DESCRIPTION
        Builds a deployment context by resolving each field through tiers:
        Tier 0 — Explicit overrides (always win)
        Tier 0.5 — deploy-config.json (tenants, ADO defaults, naming conventions)
        Tier 1 — infra/config.ps1 ($Config hashtable)
        Tier 2 — .vibeshield/deploy-state.json (workflow state)
        Tier 3 — Auto-detection (git config, git remote, workspace markers)
        Derived — Computed from Email (Username, ServiceConnection, MgmtResourceGroup, UamiName)

    .PARAMETER WorkspacePath
        Root of the target workspace. Defaults to current directory.

    .PARAMETER Overrides
        Hashtable of explicit overrides (Tier 0). Keys matching context fields win unconditionally.

    .PARAMETER SkipAutoDetect
        Skip tier-3 auto-detection (useful in tests or when config is known-complete).

    .OUTPUTS PSCustomObject with: Email, Username, AdoOrgUrl, AdoProject, RepoName,
        AppName, ResourceGroup, Location, ServiceConnection, MgmtResourceGroup,
        UamiName, UamiClientId, AppType, BuildPool, BuildPoolOs, UserObjectId, Source (hashtable of tier per key).
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PWD.Path,
        [hashtable]$Overrides = @{},
        [switch]$SkipAutoDetect
    )

    # ── Initialise empty context ────────────────────────────
    $fields = @(
        'Email', 'Username', 'AdoOrgUrl', 'AdoProject', 'RepoName',
        'AppName', 'ResourceGroup', 'Location', 'ServiceConnection',
        'MgmtResourceGroup', 'UamiName', 'UamiClientId',
        'AppType', 'TargetAzureService', 'BuildPool', 'BuildPoolOs', 'UserObjectId'
    )
    $ctx    = @{}
    $source = @{}   # tracks which tier provided each value
    foreach ($f in $fields) { $ctx[$f] = ''; $source[$f] = '' }

    # ── Tier 0: Explicit overrides ──────────────────────────
    foreach ($key in $Overrides.Keys) {
        if ($fields -contains $key -and -not [string]::IsNullOrWhiteSpace($Overrides[$key])) {
            $ctx[$key]    = $Overrides[$key]
            $source[$key] = 'override'
        }
    }

    # ── Tier 1: infra/config.ps1 (authoritative for project config) ──
    # Supports two conventions:
    #   - VSD's own $Config = @{ ... } hashtable (legacy/simple)
    #   - VibeShield-Bicep's $script:ResourceNames = @{ ... } hashtable
    $configPath = Resolve-ConfigPath -WorkspacePath $WorkspacePath
    if (Test-Path $configPath) {
        # Safety gate: validate config.ps1 structure before execution
        $configSafety = Test-ConfigFileSafe -ConfigPath $configPath
        if (-not $configSafety.Safe) {
            Write-Warning "Unsafe infra/config.ps1 — skipping: $($configSafety.Issues -join '; ')"
        } else {
        try {
            $Config = $null
            $script:ResourceNames = $null
            $script:Location = $null
            . $configPath
            # Prefer $Config if present; fall back to $script:ResourceNames
            # (VibeShield-Bicep uses $script: scope for its variables)
            $configHt = if ($Config -is [hashtable]) { $Config }
                        elseif ($script:ResourceNames -is [hashtable]) { $script:ResourceNames }
                        else { $null }
            if ($configHt) {
                $configMap = @{
                    ResourceGroup    = 'ResourceGroup'
                    AppName          = 'AppName'
                    Location         = 'Location'
                    ServiceConnection = 'ServiceConnection'
                    Username         = 'Username'
                    Email            = 'Email'
                    UserObjectId     = 'UserObjectId'
                    MgmtResourceGroup = 'MgmtResourceGroup'
                    UamiName         = 'UamiName'
                    UamiClientId     = 'UamiClientId'
                    AppType          = 'AppType'
                    TargetAzureService = 'TargetAzureService'
                    BuildPool        = 'BuildPool'
                    BuildPoolOs      = 'BuildPoolOs'
                }
                foreach ($ck in $configMap.Keys) {
                    $ctxKey = $configMap[$ck]
                    if ($source[$ctxKey] -ne '' -and $null -ne $source[$ctxKey]) { continue }
                    if ($configHt.ContainsKey($ck) -and
                        -not [string]::IsNullOrWhiteSpace($configHt[$ck])) {
                        $ctx[$ctxKey] = $configHt[$ck]
                        $source[$ctxKey] = 'config'
                    }
                }
            }
            # VibeShield-Bicep stores Location as $script:Location (not in the hashtable)
            if ([string]::IsNullOrWhiteSpace($ctx['Location']) -and
                ($source['Location'] -eq '' -or $null -eq $source['Location']) -and
                -not [string]::IsNullOrWhiteSpace($script:Location)) {
                $ctx['Location'] = $script:Location
                $source['Location'] = 'config'
            }
        } catch {
            Write-Verbose "Could not load infra/config.ps1: $_"
        } finally {
            # Clean up script-scope variables to avoid leaking
            $script:ResourceNames = $null
            $script:Location = $null
        }
        } # end else (config is safe)
    }

    # ── Tier 2: deploy-state.json (workflow state only) ────
    # Only maps workflow-specific fields NOT in config.ps1 (AdoOrgUrl, AdoProject).
    # Config.ps1 fields (Email, AppName, ResourceGroup, ServiceConnection,
    # AppType, TargetAzureService) are never read from state — config.ps1
    # is authoritative for those.
    $stateFilePath = Get-StateFilePath -WorkspacePath $WorkspacePath
    if (Test-Path $stateFilePath) {
        try {
            $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
            $stateMap = @{
                AdoOrgUrl          = 'AdoOrgUrl'
                AdoProject         = 'AdoProject'
            }
            foreach ($sk in $stateMap.Keys) {
                $ck = $stateMap[$sk]
                if ($source[$ck] -ne '' -and $null -ne $source[$ck]) { continue }  # already set
                if ($stateObj.PSObject.Properties[$sk] -and
                    -not [string]::IsNullOrWhiteSpace($stateObj.$sk)) {
                    $ctx[$ck]    = $stateObj.$sk
                    $source[$ck] = 'state'
                }
            }
        } catch {
            Write-Verbose "Could not read deploy-state.json: $_"
        }
    }

    # ── Tier 3: Auto-detection (az CLI, git, workspace) ────
    if (-not $SkipAutoDetect) {
        # Email from az account / git config
        if ([string]::IsNullOrWhiteSpace($ctx['Email'])) {
            try {
                $acctRaw = az account show -o json 2>$null | Out-String
                if ($LASTEXITCODE -eq 0 -and $acctRaw.Trim()) {
                    $acct = $acctRaw | ConvertFrom-Json
                    if ($acct.user -and $acct.user.name -match '@') {
                        $ctx['Email'] = $acct.user.name
                        $source['Email'] = 'az-cli'
                    }
                }
            } catch { <# Intentionally suppressed — fallback detection #> $null = $_ }
            if ([string]::IsNullOrWhiteSpace($ctx['Email'])) {
                try {
                    $gitEmail = git config user.email 2>$null | Out-String
                    if ($LASTEXITCODE -eq 0 -and $gitEmail.Trim() -match '@') {
                        $ctx['Email'] = $gitEmail.Trim()
                        $source['Email'] = 'git'
                    }
                } catch { <# Intentionally suppressed — fallback detection #> $null = $_ }
            }
        }

        # ADO org/project/repo from git remote
        if ([string]::IsNullOrWhiteSpace($ctx['AdoOrgUrl']) -or
            [string]::IsNullOrWhiteSpace($ctx['AdoProject']) -or
            [string]::IsNullOrWhiteSpace($ctx['RepoName'])) {
            try {
                $remoteUrl = (git remote get-url origin 2>$null | Out-String).Trim()
            } catch { $remoteUrl = '' }
            if ($remoteUrl) {
                $orgUrl = $null; $proj = $null; $repo = $null
                if ($remoteUrl -match 'dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/\s]+)') {
                    $orgUrl = "https://dev.azure.com/$($Matches[1])"; $proj = $Matches[2]; $repo = $Matches[3]
                } elseif ($remoteUrl -match 'ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/([^/\s]+)') {
                    $orgUrl = "https://dev.azure.com/$($Matches[1])"; $proj = $Matches[2]; $repo = $Matches[3]
                } elseif ($remoteUrl -match '([^/.]+)\.visualstudio\.com/([^/]+)/_git/([^/\s]+)') {
                    $orgUrl = "https://dev.azure.com/$($Matches[1])"; $proj = $Matches[2]; $repo = $Matches[3]
                }
                if ($orgUrl -and [string]::IsNullOrWhiteSpace($ctx['AdoOrgUrl'])) {
                    $ctx['AdoOrgUrl'] = $orgUrl; $source['AdoOrgUrl'] = 'git-remote'
                }
                if ($proj -and [string]::IsNullOrWhiteSpace($ctx['AdoProject'])) {
                    $ctx['AdoProject'] = $proj; $source['AdoProject'] = 'git-remote'
                }
                if ($repo -and [string]::IsNullOrWhiteSpace($ctx['RepoName'])) {
                    $ctx['RepoName'] = $repo; $source['RepoName'] = 'git-remote'
                }
            }
        }

        # AppType from workspace files (centralized engine)
        if ([string]::IsNullOrWhiteSpace($ctx['AppType'])) {
            if (Get-Command Get-AppType -ErrorAction SilentlyContinue) {
                $det = Get-AppType -Path $WorkspacePath -WorkspacePath $WorkspacePath
                if ($det -and $det.AppType -ne 'Unknown') {
                    $ctx['AppType'] = $det.AppType
                    $source['AppType'] = 'workspace'
                }
            }
        }
    }

    # ── Derived values (always computed from resolved fields) ──
    if (-not [string]::IsNullOrWhiteSpace($ctx['Email'])) {
        $derivedUsername = ($ctx['Email'] -split '@')[0]
        if ([string]::IsNullOrWhiteSpace($ctx['Username'])) {
            $ctx['Username'] = $derivedUsername; $source['Username'] = 'derived'
        }
        if ([string]::IsNullOrWhiteSpace($ctx['ServiceConnection'])) {
            $ctx['ServiceConnection'] = Get-ServiceConnectionName -Username $derivedUsername; $source['ServiceConnection'] = 'derived'
        }
        if ([string]::IsNullOrWhiteSpace($ctx['MgmtResourceGroup'])) {
            $ctx['MgmtResourceGroup'] = Get-MgmtResourceGroupName -Username $derivedUsername; $source['MgmtResourceGroup'] = 'derived'
        }
        if ([string]::IsNullOrWhiteSpace($ctx['UamiName'])) {
            $ctx['UamiName'] = Get-ManagedIdentityName -Username $derivedUsername; $source['UamiName'] = 'derived'
        }
    }

    # RepoName / AppName fallbacks
    if ([string]::IsNullOrWhiteSpace($ctx['RepoName'])) {
        $ctx['RepoName'] = Split-Path -Path $WorkspacePath -Leaf
        $source['RepoName'] = 'workspace-folder'
    }
    if ([string]::IsNullOrWhiteSpace($ctx['AppName'])) {
        $ctx['AppName'] = $ctx['RepoName']
        $source['AppName'] = 'repo-name'
    }

    # ── Build output ────────────────────────────────────────
    $result = [pscustomobject]@{}
    foreach ($f in $fields) {
        $result | Add-Member -NotePropertyName $f -NotePropertyValue $ctx[$f]
    }
    $result | Add-Member -NotePropertyName 'Source' -NotePropertyValue $source
    return $result
}

# ════════════════════════════════════════════════════════════
# Config File Validation
# ════════════════════════════════════════════════════════════

function Test-ConfigFile {
    <#
    .SYNOPSIS Validates infra/config.ps1 by dot-sourcing and checking required keys.
    .DESCRIPTION
        Attempts to dot-source the given config file in a child scope. If it
        loads successfully, verifies that either $Config or $ResourceNames
        is a hashtable containing all required keys with non-empty values.
        Supports both VSD's $Config convention and VibeShield-Bicep's
        $script:ResourceNames convention.
    .OUTPUTS PSCustomObject with Valid (bool), Issues (string[]), Config (hashtable or $null)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $issues = @()
    $loadedConfig = $null

    if (-not (Test-Path $ConfigPath)) {
        return [pscustomobject]@{ Valid = $false; Issues = @("Config file not found: $ConfigPath"); Config = $null }
    }

    try {
        $Config = $null
        $script:ResourceNames = $null
        . $ConfigPath
        $loadedConfig = if ($Config -is [hashtable]) { $Config }
                        elseif ($script:ResourceNames -is [hashtable]) { $script:ResourceNames }
                        else { $null }
    } catch {
        return [pscustomobject]@{ Valid = $false; Issues = @("Failed to dot-source config file: $_"); Config = $null }
    } finally {
        $script:ResourceNames = $null
    }

    if ($loadedConfig -isnot [hashtable]) {
        return [pscustomobject]@{ Valid = $false; Issues = @('Neither $Config nor $ResourceNames is a hashtable after dot-sourcing'); Config = $null }
    }

    $requiredKeys = @(
        'ResourceGroup', 'AppName', 'Location', 'ServiceConnection', 'Username',
        'Email', 'UserObjectId', 'MgmtResourceGroup', 'UamiName', 'UamiClientId',
        'BuildPool', 'BuildPoolOs'
    )
    foreach ($key in $requiredKeys) {
        if (-not $loadedConfig.ContainsKey($key)) {
            $issues += "Missing required key: $key"
        } elseif ([string]::IsNullOrWhiteSpace($loadedConfig[$key])) {
            $issues += "Empty value for key: $key"
        }
    }

    [pscustomobject]@{
        Valid  = ($issues.Count -eq 0)
        Issues = $issues
        Config = $loadedConfig
    }
}

function Update-ConfigFile {
    <#
    .SYNOPSIS Merges discovered key-value pairs into an existing infra/config.ps1.
    .DESCRIPTION
        Reads the existing config file, adds any keys from NewValues that are
        missing or empty. When the file exists, inserts new keys in-place
        without rewriting or destroying other content. Does NOT overwrite
        existing non-empty values. Creates the file from scratch only when
        it does not exist.
    .PARAMETER ConfigPath
        Path to infra/config.ps1.
    .PARAMETER NewValues
        Hashtable of key-value pairs to merge into the config.
    .OUTPUTS PSCustomObject with Updated (bool), AddedKeys (string[]), Path (string)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][hashtable]$NewValues
    )

    $addedKeys = @()
    $existingConfig = @{}

    # Load existing config if present
    if (Test-Path $ConfigPath) {
        try {
            $Config = $null
            $script:ResourceNames = $null
            . $ConfigPath
            if ($Config -is [hashtable]) { $existingConfig = $Config }
            elseif ($script:ResourceNames -is [hashtable]) { $existingConfig = $script:ResourceNames }
        } catch { <# Intentionally suppressed — config load is best-effort #> $null = $_ } finally {
            $script:ResourceNames = $null
        }
    }

    # Merge: only add keys that are missing or empty
    foreach ($key in $NewValues.Keys) {
        if (-not $existingConfig.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($existingConfig[$key])) {
            if (-not [string]::IsNullOrWhiteSpace($NewValues[$key])) {
                $existingConfig[$key] = $NewValues[$key]
                $addedKeys += $key
            }
        }
    }

    if ($addedKeys.Count -eq 0) {
        return [pscustomobject]@{ Updated = $false; AddedKeys = @(); Path = $ConfigPath }
    }

    # Ensure directory exists
    $dir = Split-Path -Path $ConfigPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $ConfigPath) {
        # ── In-place update: preserve original file content, only modify/insert keys ──
        $rawText = Get-Content -Path $ConfigPath -Raw
        $keysToInsert = @()
        foreach ($key in $addedKeys) {
            $val = $existingConfig[$key] -replace "'", "''"
            $newLine = "    $key$((' ' * [Math]::Max(1, 18 - $key.Length)))= '$val'"
            # If the key already exists as a line (e.g. empty value), replace it in-place
            $pattern = "(?m)^(\s*)$key\s*=\s*'[^']*'\s*$"
            if ($rawText -match $pattern) {
                $rawText = $rawText -replace $pattern, $newLine
            } else {
                $keysToInsert += $newLine
            }
        }
        # Insert truly new keys before the closing brace of the $Config hashtable
        if ($keysToInsert.Count -gt 0) {
            $closingBraceIndex = $rawText.LastIndexOf('}')
            if ($closingBraceIndex -ge 0) {
                $insertText = ($keysToInsert -join "`n") + "`n"
                $rawText = $rawText.Substring(0, $closingBraceIndex) + $insertText + $rawText.Substring($closingBraceIndex)
            }
        }
        Set-Content -Path $ConfigPath -Value $rawText -NoNewline -Encoding UTF8
    } else {
        # ── Create from scratch: file does not exist ──
        $orderedKeys = @(
            'ResourceGroup', 'AppName', 'Location', 'ServiceConnection', 'Username',
            'Email', 'UserObjectId', 'MgmtResourceGroup', 'UamiName', 'UamiClientId',
            'AppType', 'TargetAzureService', 'BuildPool', 'BuildPoolOs'
        )
        $lines = @(
            '# VibeShield-Deploy configuration — generated by vibeshield-bicep'
            '# This file is the single source of truth for deployment settings.'
            '# All deploy agents and pipeline scripts source this file automatically.'
            '# Do NOT hardcode secrets, tokens, or passwords here.'
            ''
            '$Config = @{'
        )
        $written = @{}
        foreach ($key in $orderedKeys) {
            if ($existingConfig.ContainsKey($key)) {
                $val = $existingConfig[$key] -replace "'", "''"
                $lines += "    $key$((' ' * [Math]::Max(1, 18 - $key.Length)))= '$val'"
                $written[$key] = $true
            }
        }
        foreach ($key in ($existingConfig.Keys | Sort-Object)) {
            if (-not $written.ContainsKey($key)) {
                $val = $existingConfig[$key] -replace "'", "''"
                $lines += "    $key$((' ' * [Math]::Max(1, 18 - $key.Length)))= '$val'"
            }
        }
        $lines += '}'
        Set-Content -Path $ConfigPath -Value ($lines -join "`n") -Encoding UTF8
    }

    # Write hash for integrity verification
    $hashPath = "$ConfigPath.sha256"
    $hash = (Get-FileHash -Path $ConfigPath -Algorithm SHA256).Hash
    Set-Content -Path $hashPath -Value $hash -Encoding UTF8

    [pscustomobject]@{ Updated = $true; AddedKeys = $addedKeys; Path = $ConfigPath; Hash = $hash }
}

# ════════════════════════════════════════════════════════════
# Cross-Stage Retry Routing
# ════════════════════════════════════════════════════════════

function Get-CrossStageRetryTarget {
    <#
    .SYNOPSIS Returns the loop-back target stage for a given failure type.
    .DESCRIPTION
        Implements the cross-stage retry routing table from
        deploy-cross-stage-retry.prompt.md. Returns the stage number
        to loop back to, or $null if the failure is non-loopable.

        Enforces max 2 loop-backs per deployment. If LoopBackCount >= 2
        and the same error recurs, returns Loopable = $false with an
        escalation reason. Callers must pass the current LoopBackCount
        and LastLoopBackError from deploy-state.json.
    .OUTPUTS PSCustomObject with TargetStage, Path, Loopable, Reason, NewLoopBackCount
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'LastLoopBackError', Justification='Reserved for future loop-back diagnostics')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,4)][int]$DiscoveringStage,
        [Parameter(Mandatory)][ValidateSet(
            'Bicep','PipelineYaml','BuildCode','SCAuth',
            'MissingBicep','RBAC','Quota','Compliance',
            'SecretFound','SCMissing','RGMissing'
        )][string]$IssueType,
        [int]$LoopBackCount = 0,
        [string]$LastLoopBackError = ''
    )

    # Non-loopable failures — require user or admin action
    $nonLoopable = @('RBAC','Quota','Compliance','SecretFound','SCMissing','RGMissing')
    if ($IssueType -in $nonLoopable) {
        return [pscustomobject]@{
            TargetStage      = $null
            Path             = $null
            Loopable         = $false
            Reason           = "Issue type '$IssueType' requires user or admin action"
            NewLoopBackCount = $LoopBackCount
        }
    }

    # Enforce max loop-backs — halt if same error recurs
    $maxLoopBacks = 2
    try {
        $cfgLb = Get-DeployConfig
        if ($cfgLb.monitor.PSObject.Properties['maxLoopBacks']) {
            $maxLoopBacks = $cfgLb.monitor.maxLoopBacks
        }
    } catch { <# use default #> $null = $_ }
    if ($LoopBackCount -ge $maxLoopBacks) {
        return [pscustomobject]@{
            TargetStage      = $null
            Path             = $null
            Loopable         = $false
            Reason           = "Maximum $maxLoopBacks loop-backs reached (count: $LoopBackCount). Same issue '$IssueType' recurred. Escalating to user."
            NewLoopBackCount = $LoopBackCount
        }
    }

    # Stage 4 (Monitor) loop-back table
    if ($DiscoveringStage -eq 4) {
        switch ($IssueType) {
            'Bicep'        { return [pscustomobject]@{ TargetStage = 1; Path = 'Monitor > Preflight > vibeshield-bicep > re-validate > resume at Stage 3'; Loopable = $true; Reason = $null; NewLoopBackCount = $LoopBackCount + 1 } }
            'PipelineYaml' { return [pscustomobject]@{ TargetStage = 2; Path = 'Monitor > Pipeline Author fixes YAML > resume at Stage 3'; Loopable = $true; Reason = $null; NewLoopBackCount = $LoopBackCount + 1 } }
            'BuildCode'    { return [pscustomobject]@{ TargetStage = 3; Path = 'Monitor applies code fix > Pipeline Push > resume at Stage 4'; Loopable = $true; Reason = $null; NewLoopBackCount = $LoopBackCount + 1 } }
            'SCAuth'       { return [pscustomobject]@{ TargetStage = 2; Path = 'Monitor > Pipeline Author re-authorizes SC > resume at Stage 3'; Loopable = $true; Reason = $null; NewLoopBackCount = $LoopBackCount + 1 } }
        }
    }

    # Stage 3 (Push) loop-back table
    if ($DiscoveringStage -eq 3) {
        switch ($IssueType) {
            'MissingBicep' { return [pscustomobject]@{ TargetStage = 1; Path = 'Push > Preflight > vibeshield-bicep > re-validate > resume at Stage 2'; Loopable = $true; Reason = $null; NewLoopBackCount = $LoopBackCount + 1 } }
        }
    }

    return [pscustomobject]@{
        TargetStage      = $null
        Path             = $null
        Loopable         = $false
        Reason           = "No loop-back rule for Stage $DiscoveringStage + IssueType '$IssueType'"
        NewLoopBackCount = $LoopBackCount
    }
}

# ════════════════════════════════════════════════════════════
# Admin Escalation Formatting
# ════════════════════════════════════════════════════════════

function Get-SupportInfo {
    <#
    .SYNOPSIS Returns the support contact info from deploy-config.json.
    .DESCRIPTION
        Reads the support section from deploy-config.json and returns a
        hashtable with email, officeHourUrl, userGuideUrl, and teamName.
        Falls back to hardcoded defaults if config is unavailable.
    .OUTPUTS Hashtable with Email, OfficeHourUrl, UserGuideUrl, TeamName.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param()

    $defaults = @{
        Email         = 'CELAVibeShieldSupport@microsoft.com'
        OfficeHourUrl = 'https://microsoft.sharepoint.com/teams/CELAEngineeringFundamentals/SitePages/Contact-Us.aspx'
        UserGuideUrl  = ''
        TeamName      = 'CELA SPEAR'
    }

    $cfg = try { Get-DeployConfig } catch { return $defaults }
    if (-not $cfg.PSObject.Properties['support']) { return $defaults }
    $s = $cfg.support

    return @{
        Email         = if ($s.PSObject.Properties['email'] -and $s.email) { $s.email } else { $defaults.Email }
        OfficeHourUrl = if ($s.PSObject.Properties['officeHourUrl'] -and $s.officeHourUrl) { $s.officeHourUrl } else { $defaults.OfficeHourUrl }
        UserGuideUrl  = if ($s.PSObject.Properties['userGuideUrl'] -and $s.userGuideUrl) { $s.userGuideUrl } else { $defaults.UserGuideUrl }
        TeamName      = if ($s.PSObject.Properties['teamName'] -and $s.teamName) { $s.teamName } else { $defaults.TeamName }
    }
}

function Format-AdminEscalation {
    <#
    .SYNOPSIS Formats a standardized admin escalation message.
    .DESCRIPTION
        Generates the Admin Escalation Template defined in
        deploy-shared-rules.prompt.md for failures requiring
        AI4CELA SPEAR team intervention.
    .OUTPUTS System.String — the formatted escalation block
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$ResourceName,
        [string]$Reason = 'This is needed so their deployment pipeline can access Azure resources.'
    )

    $support = Get-SupportInfo

    @"

> :warning: **Action needed from the $($support.TeamName) team**
>
> The $($support.TeamName) team (the team that manages Azure infrastructure for VibeShield-Deploy) needs to:
> - $Action
>
> :email: Contact: [$($support.Email)](mailto:$($support.Email)) · [Office Hour]($($support.OfficeHourUrl))
>
> :clipboard: **Message to forward:**
> > "Please $Action for user $Email. Resource: $ResourceName. $Reason"
>
> :arrows_counterclockwise: **After they fix this**, come back here and say **"Re-run the readiness check"** to continue where you left off.
"@
}

# ════════════════════════════════════════════════════════════
# Failure Diagnosis / Classification
# ════════════════════════════════════════════════════════════

function Get-FailureDiagnosis {
    <#
    .SYNOPSIS Classifies a pipeline failure based on error text.
    .DESCRIPTION
        Matches error messages against known failure patterns from
        deploy-deployment-diagnostics and returns category, root cause,
        recommended fix, and alternative hypotheses for causal reasoning.
    .OUTPUTS PSCustomObject with Category, RootCause, Fix, Transient, Alternatives
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ErrorMessage)

    # Guard against empty or whitespace-only error messages
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        return [pscustomobject]@{
            Category     = 'Unknown'
            RootCause    = 'No error message available — pipeline timeline may have failed to parse or stages were skipped'
            Fix          = 'Manually review the pipeline run logs in Azure DevOps to identify the failing stage and error'
            Transient    = $false
            Alternatives = @(
                'Check if a stage was skipped due to a condition or dependency failure',
                'Verify the pipeline timeline API returned valid JSON',
                'Look for stage-level conditions that prevented execution'
            )
        }
    }

    # Build failures
    if ($ErrorMessage -match 'MSBUILD\s*:\s*error\s+MSB') {
        return [pscustomobject]@{ Category = 'Build'; RootCause = 'Missing NuGet packages or incompatible SDK'; Fix = 'Run dotnet restore; verify SDK version matches TargetFramework'; Transient = $false; Alternatives = @('SDK version mismatch with TargetFramework', 'Bicep provisioning did not create required resources', 'Package feed authentication failed silently') }
    }
    if ($ErrorMessage -match 'npm ERR!\s*code\s+ERESOLVE') {
        return [pscustomobject]@{ Category = 'Build'; RootCause = 'npm dependency conflict'; Fix = 'Run npm install --legacy-peer-deps or resolve version conflicts'; Transient = $false; Alternatives = @('package-lock.json out of sync with package.json', 'Registry URL changed or unreachable') }
    }
    if ($ErrorMessage -match 'ModuleNotFoundError') {
        return [pscustomobject]@{ Category = 'Build'; RootCause = 'Missing Python package'; Fix = 'Add missing package to requirements.txt and re-run pip install'; Transient = $false; Alternatives = @('requirements.txt out of sync with imports', 'Feed authentication failed — package not found in private feed') }
    }
    if ($ErrorMessage -match 'BUILD FAILURE') {
        return [pscustomobject]@{ Category = 'Build'; RootCause = 'Maven/Gradle compilation error'; Fix = 'Check pom.xml/build.gradle for dependency versions; run mvn dependency:resolve'; Transient = $false; Alternatives = @('Java version mismatch', 'Missing Maven settings for private repository') }
    }
    if ($ErrorMessage -match 'error TS\d') {
        return [pscustomobject]@{ Category = 'Build'; RootCause = 'TypeScript compilation error'; Fix = 'Fix the reported type error in the source file'; Transient = $false; Alternatives = @('tsconfig.json misconfigured', 'Missing @types package') }
    }

    # Authentication failures
    if ($ErrorMessage -match 'Could not find service connection') {
        return [pscustomobject]@{ Category = 'Auth'; RootCause = 'Service connection name mismatch'; Fix = 'Verify sc-vibe-<name>-ARM exists; check spelling'; Transient = $false; Alternatives = @('SC was renamed', 'SC is in a different ADO project') }
    }
    if ($ErrorMessage -match 'AADSTS700016') {
        return [pscustomobject]@{ Category = 'Auth'; RootCause = 'Service principal deleted or misconfigured'; Fix = 'Re-create the service connection in Azure DevOps'; Transient = $false; Alternatives = @('SP certificate expired', 'Tenant ID changed', 'SC was valid in Stage 2 but SP was deleted between stages') }
    }
    if ($ErrorMessage -match 'AuthorizationFailed') {
        return [pscustomobject]@{ Category = 'Auth'; RootCause = 'Service principal lacks required role'; Fix = 'Assign Owner role on the resource group to the service principal'; Transient = $false; Alternatives = @('Role assignment was scoped to wrong resource group', 'PIM elevation expired') }
    }
    if ($ErrorMessage -match 'not authorized to use this service connection') {
        return [pscustomobject]@{ Category = 'Auth'; RootCause = 'Pipeline not authorized for service connection'; Fix = 'Run az devops service-endpoint update --id <id> --enable-for-all true'; Transient = $false; Alternatives = @('SC authorization was revoked after Stage 2', 'Different pipeline definition ID used') }
    }

    # Deployment failures
    if ($ErrorMessage -match 'ResourceNotFound') {
        return [pscustomobject]@{ Category = 'Deploy'; RootCause = 'Target Azure resource does not exist'; Fix = 'Re-run Bicep provisioning with az deployment group create'; Transient = $false; Alternatives = @('Bicep provisioning stage was skipped or failed', 'Resource was deleted externally', 'Wrong resource group targeted') }
    }
    if ($ErrorMessage -match 'Cannot modify resource while it is being created') {
        return [pscustomobject]@{ Category = 'Deploy'; RootCause = 'Previous deployment still in progress'; Fix = 'Wait 2 minutes and retry — this is a transient timing issue'; Transient = $true; Alternatives = @() }
    }
    if ($ErrorMessage -match 'The site is stopped') {
        return [pscustomobject]@{ Category = 'Deploy'; RootCause = 'App Service is in stopped state'; Fix = 'Run az webapp start --name <app> --resource-group <rg>'; Transient = $false; Alternatives = @('App was stopped due to quota limit', 'Health check failures triggered auto-stop') }
    }
    if ($ErrorMessage -match 'ImagePullBackOff') {
        return [pscustomobject]@{ Category = 'Deploy'; RootCause = 'Container image not found in registry'; Fix = 'Verify image name/tag; check ACR login credentials'; Transient = $false; Alternatives = @('ACR login failed', 'Image was built but not pushed', 'Wrong ACR name in pipeline variables') }
    }
    if ($ErrorMessage -match 'Insufficient quota') {
        return [pscustomobject]@{ Category = 'Deploy'; RootCause = 'Not enough resources in the subscription'; Fix = 'Check quota with az vm list-usage; request increase or change SKU'; Transient = $false; Alternatives = @('Wrong region selected — try a different location', 'SKU not available in this region') }
    }

    # 1ES Compliance failures
    if ($ErrorMessage -match 'CredScan found') {
        return [pscustomobject]@{ Category = 'Compliance'; RootCause = 'Hardcoded secrets detected in source code'; Fix = 'Remove secrets from code; use Key Vault or pipeline variables'; Transient = $false; Alternatives = @() }
    }
    if ($ErrorMessage -match 'PoliCheck violation') {
        return [pscustomobject]@{ Category = 'Compliance'; RootCause = 'Non-inclusive or policy-violating terms found'; Fix = 'Replace flagged terms with approved alternatives'; Transient = $false; Alternatives = @() }
    }
    if ($ErrorMessage -match 'Component Governance alert') {
        return [pscustomobject]@{ Category = 'Compliance'; RootCause = 'Vulnerable or banned dependency detected'; Fix = 'Update the dependency to a patched version'; Transient = $false; Alternatives = @() }
    }

    # Health check failures
    if ($ErrorMessage -match '502\s*Bad Gateway') {
        return [pscustomobject]@{ Category = 'Health'; RootCause = 'App crashed on startup'; Fix = 'Check logs with az webapp log tail'; Transient = $false; Alternatives = @(
            @{ Hypothesis = 'Missing environment variable or app setting'; Likelihood = 'Most likely' },
            @{ Hypothesis = 'Wrong startup command configured'; Likelihood = 'Possible' },
            @{ Hypothesis = 'Database connection string invalid'; Likelihood = 'Possible' },
            @{ Hypothesis = 'Port mismatch — app not listening on expected port'; Likelihood = 'Less common' }
        ) }
    }
    if ($ErrorMessage -match '503\s*Service Unavailable') {
        return [pscustomobject]@{ Category = 'Health'; RootCause = 'App still starting or overloaded'; Fix = 'Wait 30 seconds and retry; check app plan resources'; Transient = $true; Alternatives = @(
            @{ Hypothesis = 'App plan scaled to zero instances'; Likelihood = 'Possible' },
            @{ Hypothesis = 'Cold start taking longer than expected'; Likelihood = 'Possible' }
        ) }
    }
    if ($ErrorMessage -match 'Connection refused') {
        return [pscustomobject]@{ Category = 'Health'; RootCause = 'App not listening on expected port'; Fix = 'Verify PORT environment variable and app configuration'; Transient = $false; Alternatives = @(
            @{ Hypothesis = 'App crashed before binding to port'; Likelihood = 'Most likely' },
            @{ Hypothesis = 'Wrong port in App Service configuration'; Likelihood = 'Possible' },
            @{ Hypothesis = 'Container not exposing the correct port'; Likelihood = 'Less common' }
        ) }
    }

    # EV2 rollout failures (must come before generic timeout/network patterns)
    if ($ErrorMessage -match 'Ev2RARollout.*failed|Ev2Rollout.*error|ev2.*rollout.*fail') {
        return [pscustomobject]@{ Category = 'EV2'; RootCause = 'EV2 managed rollout failed'; Fix = 'Check EV2 rollout logs in the Azure DevOps pipeline run'; Transient = $false; Alternatives = @('ServiceGroupRoot artifacts may be invalid', 'EV2 service connection may have expired', 'Target region may be unavailable') }
    }
    if ($ErrorMessage -match 'ServiceGroupRoot.*validation|Invalid.*RolloutSpec|Invalid.*ServiceModel|ServiceModel.*error') {
        return [pscustomobject]@{ Category = 'EV2'; RootCause = 'EV2 artifact validation error — ServiceGroupRoot contents are invalid'; Fix = 'Re-generate EV2 artifacts via ev2-demo-agent (/ev2)'; Transient = $false; Alternatives = @('RolloutSpec.json schema mismatch', 'ServiceModel.json missing required fields', 'ARM template JSON is malformed') }
    }
    if ($ErrorMessage -match 'ob_release_environment.*missing|ob_release_servicetreeid.*missing|ob_release.*not set') {
        return [pscustomobject]@{ Category = 'EV2'; RootCause = 'Missing OneBranch release variables required by EV2'; Fix = 'Add ob_release_environment and ob_release_servicetreeid to pipeline variables block'; Transient = $false; Alternatives = @('Pipeline was generated without EV2 stage variables', 'Variables block was removed during manual editing') }
    }
    if ($ErrorMessage -match 'cn-ev2deploy.*not found|Ev2Endpoint.*not found|Ev2.*service connection.*not found') {
        return [pscustomobject]@{ Category = 'EV2-Auth'; RootCause = 'EV2 service connection not found in Azure DevOps project'; Fix = 'Create Ev2Endpoint service connection: cn-ev2deploy-{service}-{environment}'; Transient = $false; Alternatives = @('SC name mismatch — check naming convention', 'SC exists in a different ADO project') }
    }
    if ($ErrorMessage -match 'subscription.*not registered.*ev2|ev2.*subscription.*not.*registered|subscription.*not.*registered.*rollout') {
        return [pscustomobject]@{ Category = 'EV2-Auth'; RootCause = 'Azure subscription not registered with EV2 — ev2 subscription register was not run before pipeline trigger'; Fix = 'Run: ev2 subscription register --id <SubscriptionId> (the subscription GUID is in the handover data)'; Transient = $false; Alternatives = @('Subscription was registered but registration expired', 'Wrong subscription ID used') }
    }
    if ($ErrorMessage -match 'ev2.*timed?\s*out|rollout.*timeout|EV2.*timeout') {
        return [pscustomobject]@{ Category = 'EV2'; RootCause = 'EV2 rollout timed out'; Fix = 'Increase rollout timeout; check target region availability and resource quota'; Transient = $true; Alternatives = @('Large deployment taking longer than expected', 'Region capacity constraints') }
    }

    # Rate limiting / throttling
    if ($ErrorMessage -match '429|Too many requests|rate limit|throttl') {
        return [pscustomobject]@{ Category = 'Throttle'; RootCause = 'Azure API rate limit exceeded'; Fix = 'Wait 60 seconds and retry with exponential backoff'; Transient = $true; Alternatives = @() }
    }

    # Timeout
    if ($ErrorMessage -match 'timed out|ETIMEDOUT|ECONNRESET') {
        return [pscustomobject]@{ Category = 'Network'; RootCause = 'Network timeout or connection reset'; Fix = 'Check network connectivity and retry'; Transient = $true; Alternatives = @('Azure service experiencing an outage', 'Firewall or NSG blocking traffic') }
    }

    # Unknown — provide structured troubleshooting instead of immediate escalation
    return [pscustomobject]@{ Category = 'Unknown'; RootCause = 'Unrecognized error pattern'; Fix = 'Review the full error log and contact the AI4CELA SPEAR team'; Transient = $false; Alternatives = @('Check if the error is in a Provision stage (Bicep or EV2 issue)', 'Check if the error is in the Build stage (code/dependency issue)', 'Check if service connection was modified since Stage 2', 'Verify resource group still exists') }
}

function Get-FailurePlainLanguage {
    <#
    .SYNOPSIS Returns a beginner-friendly plain-language description for a failure category.
    .DESCRIPTION
        Maps the Category from Get-FailureDiagnosis to a sentence understandable by
        someone with zero DevOps experience. Used by the two-tier message rule to
        populate the primary message while technical details go in the collapsible block.
    .PARAMETER Diagnosis
        The PSCustomObject returned by Get-FailureDiagnosis.
    .OUTPUTS String — plain-language description.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Diagnosis)

    $map = @{
        'Build'      = "Your app's code couldn't be compiled — a required software package is missing or there's a code error."
        'Auth'       = "The pipeline doesn't have permission to deploy to your Azure account — the saved credentials need to be fixed."
        'Deploy'     = "The pipeline built your app successfully, but couldn't deploy it to Azure — the target resource may be missing or misconfigured."
        'Compliance' = "A security scan found an issue in your code — this must be resolved before deployment can continue."
        'Health'     = "Your app was deployed but isn't responding correctly — it may have crashed on startup or is missing a configuration setting."
        'EV2'        = "The infrastructure deployment (EV2 rollout) failed — the deployment artifacts may need to be regenerated."
        'EV2-Auth'   = "The infrastructure deployment can't authenticate — the EV2 service connection is missing or misconfigured."
        'Throttle'   = "Azure is temporarily limiting requests — this usually resolves itself after a short wait."
        'Network'    = "A network connection timed out — this is usually temporary and resolves on retry."
        'Unknown'    = "Something unexpected went wrong — the error doesn't match any known pattern."
    }

    if ($map.ContainsKey($Diagnosis.Category)) {
        return $map[$Diagnosis.Category]
    }
    return "The pipeline encountered an error ($($Diagnosis.Category))."
}

# ════════════════════════════════════════════════════════════
# Preflight Skip Decision
# ════════════════════════════════════════════════════════════

function Get-PreflightSkipDecision {
    <#
    .SYNOPSIS Decides whether to skip Stage 1 (Preflight) for a returning deployment.
    .DESCRIPTION
        Implements the preflight skip rule from deploy-resume-protocol.prompt.md:
        If the last deployment completed successfully (Stage 4) AND the state
        timestamp is from today, skip preflight. Otherwise, run it.
    .PARAMETER ReadResult
        The PSCustomObject returned by Invoke-StateFileManager.ps1 -Action Read.
        Must have .Found, .LastCompletedStage, and .State.Timestamp.
    .PARAMETER CurrentDate
        Override for the current date (for testing). Defaults to today.
    .OUTPUTS PSCustomObject with Skip (bool) and Reason (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ReadResult,
        [datetime]$CurrentDate = (Get-Date).Date
    )

    # No state file → run preflight
    if (-not $ReadResult.Found) {
        return [pscustomobject]@{ Skip = $false; Reason = 'No state file found — fresh deployment' }
    }

    # Last deployment did not complete successfully → run preflight
    if ($ReadResult.LastCompletedStage -ne 4) {
        return [pscustomobject]@{ Skip = $false; Reason = "Last completed stage was $($ReadResult.LastCompletedStage), not 4 — preflight required" }
    }

    # Stage 4 complete — check if timestamp is today
    $timestamp = $null
    if ($ReadResult.State -and $ReadResult.State -is [hashtable] -and $ReadResult.State.ContainsKey('Timestamp') -and $ReadResult.State['Timestamp']) {
        $timestamp = [datetime]::Parse($ReadResult.State['Timestamp'])
    }

    if (-not $timestamp) {
        return [pscustomobject]@{ Skip = $false; Reason = 'State file has no timestamp — preflight required' }
    }

    if ($timestamp.Date -eq $CurrentDate) {
        return [pscustomobject]@{ Skip = $true; Reason = 'Last deployment succeeded today — skipping preflight' }
    }

    return [pscustomobject]@{ Skip = $false; Reason = 'Last deployment succeeded on a previous day — preflight required' }
}

function Assert-ScriptIntegrity {
    <#
    .SYNOPSIS Verifies installed VibeShield-Deploy protected files match the integrity manifest.
    .DESCRIPTION
        Reads .vibeshield/deploy-integrity-manifest.json and compares SHA-256 hashes of each
        listed file against the stored values. Terminates execution if any file has
        been modified or deleted after installation.

        Protected file types: .ps1 scripts, .agent.md agent definitions,
        SKILL.md skill definitions, and .prompt.md prompt files.

        The integrity manifest is MANDATORY — it must be committed to the repository
        alongside the installed VSD files. If the manifest is missing, malformed,
        or empty, execution is terminated. Re-run Install-VibeShield.ps1 to generate it.
    .PARAMETER WorkspacePath
        Workspace root directory. Required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    $manifestPath = Join-Path -Path $WorkspacePath -ChildPath (Get-ConfigPath -Key 'integrityManifest' -Default '.vibeshield/deploy-integrity-manifest.json')

    if (-not (Test-Path $manifestPath)) {
        # In the VSD source repo (where Install-VibeShield.ps1 lives), the manifest
        # doesn't exist — it's only generated when VSD is installed into a target project.
        # Skip integrity checking in the source repo; enforce in installed copies only.
        $installerPath = Join-Path -Path $WorkspacePath -ChildPath 'Install-VibeShield.ps1'
        if (Test-Path $installerPath) {
            Write-Verbose "Skipping integrity check — running from VSD source repo (Install-VibeShield.ps1 present)"
            return
        }
        throw "Integrity manifest not found at $manifestPath. The manifest must be committed to the repository. Re-run Install-VibeShield.ps1 to generate it."
    }

    try {
        $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse integrity manifest at ${manifestPath}: $_ — the manifest may be corrupted. Re-run Install-VibeShield.ps1 to regenerate it."
    }

    if (-not $manifest.files -or
        ($manifest.files.PSObject.Properties | Measure-Object).Count -eq 0) {
        throw "Integrity manifest at $manifestPath contains no file entries. Re-run Install-VibeShield.ps1 to regenerate it."
    }

    $failures = @()

    foreach ($entry in $manifest.files.PSObject.Properties) {
        $filePath = Join-Path -Path $WorkspacePath -ChildPath $entry.Name

        if (-not (Test-Path $filePath)) {
            $failures += "MISSING: $($entry.Name)"
            continue
        }

        $currentHash = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash
        if ($currentHash -ne $entry.Value) {
            $failures += "MODIFIED: $($entry.Name) (expected $($entry.Value.Substring(0,12))..., got $($currentHash.Substring(0,12))...)"
        }
    }

    if ($failures.Count -gt 0) {
        $msg = "Script integrity check FAILED — $($failures.Count) file(s) tampered with:`n"
        $msg += ($failures | ForEach-Object { "  - $_" }) -join "`n"
        $msg += "`n`nVibeShield-Deploy scripts have been modified since installation."
        $msg += " Re-run Install-VibeShield.ps1 to restore them to their original state."

        # Log integrity failure
        if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
            Write-VsdLog -Message "Script integrity check FAILED: $($failures.Count) file(s) tampered" `
                -Category 'integrity' -Level 'fatal' `
                -Agent 'vibeshield-deploy-orchestrator' -Script 'SharedHelpers.ps1' `
                -Stage 0 -WorkspacePath $WorkspacePath `
                -Extra @{ failures = $failures }
        }

        throw $msg
    }

    # Super hash verification — mandatory
    if (-not $manifest.PSObject.Properties['superHash'] -or -not $manifest.superHash) {
        throw "Integrity manifest at $manifestPath is missing the superHash field. Re-run Install-VibeShield.ps1 to regenerate it."
    }
    $superHashInput = ($manifest.files.PSObject.Properties | Sort-Object Name |
        ForEach-Object { "$($_.Name):$($_.Value)" }) -join "`n"
    $superHashBytes = [System.Text.Encoding]::UTF8.GetBytes($superHashInput)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $computedSuperHash = ($sha256.ComputeHash($superHashBytes) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
    $sha256.Dispose()
    if ($computedSuperHash -ne $manifest.superHash) {
        if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
            Write-VsdLog -Message 'Script integrity check FAILED: superHash mismatch — manifest may be tampered' `
                -Category 'integrity' -Level 'fatal' `
                -Agent 'vibeshield-deploy-orchestrator' -Script 'SharedHelpers.ps1' `
                -Stage 0 -WorkspacePath $WorkspacePath
        }
        throw "Script integrity check FAILED — superHash mismatch. The manifest file itself may have been tampered with. Re-run Install-VibeShield.ps1 to restore."
    }

    $fileCount = ($manifest.files.PSObject.Properties | Measure-Object).Count
    # Log integrity success
    if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
        Write-VsdLog -Message "Script integrity verified: $fileCount files matched SHA-256 hashes, superHash OK" `
            -Category 'integrity' -Level 'info' `
            -Agent 'vibeshield-deploy-orchestrator' -Script 'SharedHelpers.ps1' `
            -Stage 0 -WorkspacePath $WorkspacePath `
            -Extra @{ fileCount = $fileCount; manifestHash = $manifest.superHash }
    }

    Write-Host "Script integrity verified ($fileCount files, SHA-256)"
}

function Update-IntegrityManifest {
    <#
    .SYNOPSIS Updates the integrity manifest after a skill modifies a script it owns.
    .DESCRIPTION
        Ownership-aware manifest update. Each skill may only update hashes for files
        that live under its own skill directory. The caller declares its SkillName
        (e.g. 'deploy-preflight-checks') and the list of FilePaths that were modified.

        The function:
          1. Validates the manifest exists and is parseable.
          2. Verifies every FilePath is owned by the declared SkillName
             (path must contain '.github/skills/<SkillName>/').
          3. Re-hashes each file and updates the manifest entry.
          4. Updates the 'lastModifiedBy' and 'lastModifiedAt' metadata.
          5. Writes the manifest back atomically (write .tmp then rename).

        If any file is NOT owned by the declared skill, the function throws
        and makes no changes — preventing cross-skill tampering.

    .PARAMETER WorkspacePath
        Workspace root directory. Required.

    .PARAMETER SkillName
        The name of the calling skill (e.g. 'deploy-preflight-checks').
        Must match a subdirectory under .github/skills/.

    .PARAMETER FilePaths
        Array of absolute file paths that were modified by the skill.
        Each must reside under .github/skills/<SkillName>/.

    .EXAMPLE
        Update-IntegrityManifest -WorkspacePath $PWD -SkillName 'deploy-pipeline-push' `
            -FilePaths @("$PWD/.github/skills/deploy-pipeline-push/scripts/PipelinePush.Functions.ps1")
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$SkillName,
        [Parameter(Mandatory)][string[]]$FilePaths
    )

    $manifestPath = Join-Path -Path $WorkspacePath -ChildPath (Get-ConfigPath -Key 'integrityManifest' -Default '.vibeshield/deploy-integrity-manifest.json')

    if (-not (Test-Path $manifestPath)) {
        throw "Integrity manifest not found at $manifestPath — cannot update. Re-run Install-VibeShield.ps1 first."
    }

    try {
        $manifestRaw = Get-Content -Path $manifestPath -Raw
        $manifest = $manifestRaw | ConvertFrom-Json
    } catch {
        throw "Failed to parse integrity manifest: $_"
    }

    if (-not $manifest.files) {
        throw "Integrity manifest has no 'files' section — cannot update."
    }

    # Normalise the ownership prefix for comparison
    $ownerPrefix = ".github/skills/$SkillName/"

    $updated = @()

    foreach ($filePath in $FilePaths) {
        if (-not (Test-Path $filePath)) {
            throw "File not found: $filePath — cannot update manifest for a non-existent file."
        }

        # Compute workspace-relative path (forward slashes)
        $relativePath = [System.IO.Path]::GetRelativePath($WorkspacePath, $filePath) -replace '\\','/'

        # Ownership check: file must live under the declared skill's directory
        if (-not $relativePath.StartsWith($ownerPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Ownership violation: '$relativePath' is not owned by skill '$SkillName' (expected prefix: $ownerPrefix). Only the owning skill may modify a script."
        }

        # Re-hash the file
        $newHash = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash

        # Update or add the entry in the manifest
        if ($manifest.files.PSObject.Properties[$relativePath]) {
            $manifest.files.$relativePath = $newHash
        } else {
            $manifest.files | Add-Member -NotePropertyName $relativePath -NotePropertyValue $newHash
        }

        $updated += $relativePath
    }

    # Update metadata
    if (-not $manifest.PSObject.Properties['lastModifiedBy']) {
        $manifest | Add-Member -NotePropertyName 'lastModifiedBy' -NotePropertyValue $SkillName
    } else {
        $manifest.lastModifiedBy = $SkillName
    }
    if (-not $manifest.PSObject.Properties['lastModifiedAt']) {
        $manifest | Add-Member -NotePropertyName 'lastModifiedAt' -NotePropertyValue (Get-Date -Format 'o')
    } else {
        $manifest.lastModifiedAt = (Get-Date -Format 'o')
    }

    # Recompute super hash to reflect updated file entries
    $superHashInput = ($manifest.files.PSObject.Properties | Sort-Object Name |
        ForEach-Object { "$($_.Name):$($_.Value)" }) -join "`n"
    $superHashBytes = [System.Text.Encoding]::UTF8.GetBytes($superHashInput)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $newSuperHash = ($sha256.ComputeHash($superHashBytes) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
    $sha256.Dispose()
    if ($manifest.PSObject.Properties['superHash']) {
        $manifest.superHash = $newSuperHash
    } else {
        $manifest | Add-Member -NotePropertyName 'superHash' -NotePropertyValue $newSuperHash
    }

    # Atomic write: write to .tmp then rename
    $tmpPath = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmpPath -Encoding UTF8
    Move-Item -Path $tmpPath -Destination $manifestPath -Force

    Write-Output "Integrity manifest updated by '$SkillName': $($updated.Count) file(s) re-hashed"
    foreach ($u in $updated) { Write-Output "  - $u" }
}

function Get-BicepAppNames {
    <# Parses main.bicep outputs to discover app-name outputs and resolves their values
       from .bicepparam files where possible. Bicep deployment outputs are the source of
       truth for deployed resource names in multi-module pipelines.
       Returns: @{ Found; Outputs; Params; MainBicepPath; OutputCount; Message } #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $infraDir = Join-Path -Path $WorkspacePath -ChildPath 'infra'
    if (-not (Test-Path $infraDir)) {
        return @{ Found = $false; Outputs = [ordered]@{}; Params = [ordered]@{}; MainBicepPath = $null; OutputCount = 0; Message = 'infra/ directory not found' }
    }

    # ── 1. Find main.bicep and extract string outputs matching app-name patterns ──
    $mainBicepPath = Join-Path -Path $infraDir -ChildPath 'main.bicep'
    $outputs = [ordered]@{}

    # Track ALL string outputs (not just app-name ones) so callers can distinguish
    # "Bicep has no outputs at all" from "Bicep has outputs but none are app-names".
    $allOutputNames = @()

    if (Test-Path $mainBicepPath) {
        $bicepContent = Get-Content $mainBicepPath -Raw
        # Match: output <name> string = <expression>
        $allOutputs = [regex]::Matches($bicepContent, '(?mi)^output\s+(\w+)\s+string\s*=\s*(.+)$')
        foreach ($m in $allOutputs) {
            $outputName = $m.Groups[1].Value
            $allOutputNames += $outputName
            # Strip trailing inline comments from the expression
            $expression = $m.Groups[2].Value.Trim() -replace '//.*$', ''
            $expression = $expression.Trim()
            # Filter to outputs whose name relates to app/service names
            if ($outputName -notmatch '(?i)(app|api|site|function|web|container)\w*name') { continue }

            $isDynamic  = [bool]($expression -match '\$\{|concat\(|uniqueString\(|toLower\(|toUpper\(|\.')
            $isLiteral  = [bool]($expression -match "^'[^']*'$") -and -not $isDynamic
            $isParamRef = [bool]($expression -match '^\w+$') -and -not $isLiteral

            $outputs[$outputName] = @{
                Expression    = $expression
                IsDynamic     = $isDynamic
                IsParamRef    = $isParamRef
                IsLiteral     = $isLiteral
                ResolvedValue = $null
            }
        }
    }

    # ── 2. Parse all .bicepparam files to collect param values ──
    $paramValues = [ordered]@{}
    $bicepParamFiles = @(Get-ChildItem -Path $infraDir -Filter '*.bicepparam' -ErrorAction SilentlyContinue)
    foreach ($bpf in $bicepParamFiles) {
        $content = Get-Content $bpf.FullName -Raw
        # Single-quoted params: param myParam = 'value'
        $sqMatches = [regex]::Matches($content, "(?m)^param\s+(\w+)\s*=\s*'((?:[^']|'')*)'")
        foreach ($pm in $sqMatches) {
            $paramValues[$pm.Groups[1].Value] = $pm.Groups[2].Value -replace "''", "'"
        }
        # Double-quoted params: param myParam = "value"
        $dqMatches = [regex]::Matches($content, '(?m)^param\s+(\w+)\s*=\s*"((?:[^"]|"")*)"')
        foreach ($pm in $dqMatches) {
            if (-not $paramValues.Contains($pm.Groups[1].Value)) {
                $paramValues[$pm.Groups[1].Value] = $pm.Groups[2].Value -replace '""', '"'
            }
        }
    }

    # ── 3. Resolve output values where possible ──
    foreach ($name in @($outputs.Keys)) {
        $info = $outputs[$name]
        if ($info.IsParamRef -and $paramValues.Contains($info.Expression)) {
            $info.ResolvedValue = $paramValues[$info.Expression]
        }
        elseif ($info.IsLiteral) {
            $litMatch = [regex]::Match($info.Expression, "^'([^']*)'$")
            if ($litMatch.Success) {
                $info.ResolvedValue = $litMatch.Groups[1].Value
            }
        }
    }

    $hasNonNameOutputs = ($allOutputNames.Count -gt $outputs.Count)

    return @{
        Found              = $outputs.Count -gt 0
        Outputs            = $outputs
        Params             = $paramValues
        MainBicepPath      = $mainBicepPath
        OutputCount        = $outputs.Count
        AllOutputNames     = $allOutputNames
        TotalOutputCount   = $allOutputNames.Count
        HasNonNameOutputs  = $hasNonNameOutputs
        Message            = if ($outputs.Count -gt 0) {
            "Found $($outputs.Count) app-name output(s) in main.bicep: $($outputs.Keys -join ', ')"
        } elseif ($hasNonNameOutputs) {
            "main.bicep has $($allOutputNames.Count) output(s) ($($allOutputNames -join ', ')) but NONE match the app-name pattern — delegate to vibeshield-bicep to add app-name outputs"
        } else {
            'No outputs found in main.bicep'
        }
    }
}

# ════════════════════════════════════════════════════════════
# Pipeline Discovery — Get-ExistingPipelines, Format-PipelineSelectionTable
# ════════════════════════════════════════════════════════════

function Get-ExistingPipelines {
    <#
    .SYNOPSIS Discovers existing pipeline definitions for the current repo.
    .DESCRIPTION
        Reads the Pipelines[] array from deploy-state.json if available.
        Optionally queries Azure DevOps via az pipelines list for live data.
        Returns an array of pipeline info objects.
    .PARAMETER WorkspacePath
        Workspace root directory.
    .PARAMETER AdoOrgUrl
        Azure DevOps org URL. If omitted, reads from state or deploy-config.json.
    .PARAMETER AdoProject
        Azure DevOps project. If omitted, reads from state or deploy-config.json.
    .PARAMETER QueryAdo
        If set, queries ADO for live pipeline list (requires az devops login).
        If not set, returns only pipelines from state file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$AdoOrgUrl,
        [string]$AdoProject,
        [switch]$QueryAdo
    )

    $pipelines = @()

    # Source 1: Filesystem scan for pipeline YAML files
    # Read output dirs from paths config
    $_1esDir = Get-ConfigPath -Key 'pipelineDir1ES' -Default '.azdo/pipelines'
    $_obDir = Get-ConfigPath -Key 'pipelineDirOneBranch' -Default '.azure-pipelines'
    $pipelineDirs = @($_1esDir, $_obDir, '.pipelines') | Sort-Object -Unique
    foreach ($dir in $pipelineDirs) {
        $fullDir = Join-Path -Path $WorkspacePath -ChildPath $dir
        if (Test-Path $fullDir) {
            $ymlFiles = @(Get-ChildItem -Path (Join-Path -Path $fullDir -ChildPath '*') -Include '*.yml','*.yaml' -File -ErrorAction SilentlyContinue)
            foreach ($f in $ymlFiles) {
                $relPath = [System.IO.Path]::GetRelativePath($WorkspacePath, $f.FullName) -replace '\\','/'
                $pipelines += [pscustomobject]@{
                    Name          = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                    Id            = 0
                    YmlPath       = $relPath
                    LastRunId     = 0
                    LastRunStatus = ''
                    Source        = 'filesystem'
                }
            }
        }
    }

    # Source 2: State file Pipelines[] array (merge with filesystem, state wins on duplicates)
    $stateFilePath = Get-StateFilePath -WorkspacePath $WorkspacePath
    if (Test-Path $stateFilePath) {
        try {
            $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
            if ($stateObj.PSObject.Properties['Pipelines'] -and $stateObj.Pipelines) {
                foreach ($p in @($stateObj.Pipelines)) {
                    $ymlPath = if ($p.PSObject.Properties['YmlPath']) { $p.YmlPath } else { '' }
                    # If filesystem already found this YAML, upgrade it with state data
                    $existing = $pipelines | Where-Object { $_.YmlPath -eq $ymlPath -and $ymlPath }
                    if ($existing) {
                        $existing.Name = if ($p.PSObject.Properties['PipelineName']) { $p.PipelineName } else { $existing.Name }
                        $existing.Id = if ($p.PSObject.Properties['PipelineId']) { $p.PipelineId } else { 0 }
                        $existing.LastRunId = if ($p.PSObject.Properties['LastRunId']) { $p.LastRunId } else { 0 }
                        $existing.LastRunStatus = if ($p.PSObject.Properties['LastRunStatus']) { $p.LastRunStatus } else { '' }
                        $existing.Source = 'state'
                    } else {
                        $pipelines += [pscustomobject]@{
                            Name         = if ($p.PSObject.Properties['PipelineName']) { $p.PipelineName } else { '' }
                            Id           = if ($p.PSObject.Properties['PipelineId']) { $p.PipelineId } else { 0 }
                            YmlPath      = $ymlPath
                            LastRunId    = if ($p.PSObject.Properties['LastRunId']) { $p.LastRunId } else { 0 }
                            LastRunStatus = if ($p.PSObject.Properties['LastRunStatus']) { $p.LastRunStatus } else { '' }
                            Source       = 'state'
                        }
                    }
                }
            }
        } catch { <# state unreadable — skip #> $null = $_ }
    }

    # Source 3: project-config.json pipelines[] array
    $projCfg = try { Get-ProjectConfig -WorkspacePath $WorkspacePath } catch { $null }
    if ($projCfg -and $projCfg.PSObject.Properties['pipelines'] -and $projCfg.pipelines) {
        foreach ($pc in @($projCfg.pipelines)) {
            $pcName = if ($pc.PSObject.Properties['name']) { $pc.name } else { '' }
            $pcYml  = if ($pc.PSObject.Properties['ymlPath']) { $pc.ymlPath } else { '' }
            # Skip if already found by filesystem or state
            if ($pcYml -and ($pipelines | Where-Object { $_.YmlPath -eq $pcYml })) { continue }
            if ($pcName -and ($pipelines | Where-Object { $_.Name -eq $pcName })) { continue }
            $pipelines += [pscustomobject]@{
                Name          = $pcName
                Id            = if ($pc.PSObject.Properties['pipelineId']) { $pc.pipelineId } else { 0 }
                YmlPath       = $pcYml
                LastRunId     = 0
                LastRunStatus = ''
                Source        = 'project-config'
            }
        }
    }

    # Source 4: Live ADO query (optional)
    if ($QueryAdo) {
        if (-not $AdoOrgUrl -or -not $AdoProject) {
            # Resolve from project-config (target-project-specific) or git remote — NEVER from deploy-config.json.
            # deploy-config.json contains VSD source repo coordinates, not the target project's.
            $projCfgForAdo = try { Get-ProjectConfig -WorkspacePath $WorkspacePath } catch { $null }
            if (-not $AdoOrgUrl -and $projCfgForAdo -and $projCfgForAdo.PSObject.Properties['adoOrgUrl']) {
                $AdoOrgUrl = $projCfgForAdo.adoOrgUrl
            }
            if (-not $AdoProject -and $projCfgForAdo -and $projCfgForAdo.PSObject.Properties['adoProject']) {
                $AdoProject = $projCfgForAdo.adoProject
            }
            # Last resort: parse from git remote origin
            if (-not $AdoOrgUrl -or -not $AdoProject) {
                $remoteUrl = (Invoke-GitCommand 'remote', 'get-url', 'origin').Output
                if ($remoteUrl -match 'dev\.azure\.com/([^/]+)/([^/]+)') {
                    if (-not $AdoOrgUrl)  { $AdoOrgUrl  = "https://dev.azure.com/$($Matches[1])" }
                    if (-not $AdoProject) { $AdoProject = $Matches[2] }
                }
            }
        }

        if ($AdoOrgUrl -and $AdoProject) {
            try {
                $repoName = Split-Path -Path $WorkspacePath -Leaf
                $listResult = Invoke-AzCommand 'pipelines', 'list', `
                    '--org', $AdoOrgUrl, '--project', $AdoProject, `
                    '--query', "[?contains(name, 'VibeShield-Deploy') || contains(name, '$repoName')]", `
                    '-o', 'json'

                if ($listResult.ExitCode -eq 0 -and $listResult.Output -and $listResult.Output -ne '[]') {
                    $adoPipelines = @($listResult.Output | ConvertFrom-Json)
                    foreach ($ap in $adoPipelines) {
                        # Avoid duplicates from state
                        if ($pipelines | Where-Object { $_.Id -eq $ap.id }) { continue }
                        $pipelines += [pscustomobject]@{
                            Name         = $ap.name
                            Id           = $ap.id
                            YmlPath      = if ($ap.PSObject.Properties['configuration'] -and $ap.configuration.PSObject.Properties['path']) { $ap.configuration.path } else { '' }
                            LastRunId    = 0
                            LastRunStatus = ''
                            Source       = 'ado'
                        }
                    }
                }
            } catch { <# ADO query failed — continue with state-only results #> $null = $_ }
        }
    }

    return $pipelines
}

function Format-PipelineSelectionTable {
    <#
    .SYNOPSIS Formats a numbered pipeline selection table for display.
    .PARAMETER Pipelines
        Array of pipeline objects from Get-ExistingPipelines.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][array]$Pipelines)

    $lines = @()
    $lines += ''
    $lines += 'Found existing pipelines for this repo:'
    $lines += ''
    $lines += '  #  Pipeline Name                              Status         Source'
    $lines += '  ── ────────────────────────────────────────── ────────────── ──────'

    for ($i = 0; $i -lt $Pipelines.Count; $i++) {
        $p = $Pipelines[$i]
        $num = ($i + 1).ToString().PadLeft(2)
        $name = $p.Name.PadRight(42)
        $statusVal = if ($p.LastRunStatus) { $p.LastRunStatus } else { 'Unknown' }
        $status = $statusVal.PadRight(14)
        $source = $p.Source
        $lines += "  $num $name $status $source"
    }

    $lines += ''
    return $lines -join "`n"
}

# ════════════════════════════════════════════════════════════
# Monitor Chat Progress
# ════════════════════════════════════════════════════════════

function Format-ChatProgressTable {
    <#
    .SYNOPSIS  Converts a monitor-progress JSON marker into a user-friendly stage status table.
    .DESCRIPTION
        Parses the ##[monitor-progress] JSON emitted by Wait-PipelineCompletion
        and returns a markdown table suitable for chat display. Uses plain-language
        status icons and hides technical details.
    .PARAMETER ProgressJson
        The JSON string from a ##[monitor-progress] marker.
    .OUTPUTS
        String — markdown table for chat display.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgressJson)

    try {
        $data = $ProgressJson | ConvertFrom-Json
    } catch {
        return "⏳ Checking deployment status..."
    }

    $statusIcons = @{
        'succeeded'  = '✅ Done'
        'failed'     = '❌ Failed'
        'canceled'   = '⏹️ Canceled'
        'inProgress' = '🔄 Running'
        'notStarted' = '⏳ Waiting'
        'skipped'    = '⏭️ Skipped'
    }

    $plainNames = @{
        'Build'         = 'Building your app'
        'Provision'     = 'Setting up cloud servers'
        'SecurityScan'  = 'Security check'
        'Security_Scan' = 'Security check'
        'Deploy'        = 'Deploying to Azure'
        'Compliance'    = 'Compliance check'
    }

    $lines = @()

    # ── Progress bar ────────────────────────────────────────
    $stageProps = @($data.stages.PSObject.Properties)
    $totalStages = $stageProps.Count
    $completedStages = @($stageProps | Where-Object {
        $_.Value.status -in @('succeeded', 'failed', 'canceled', 'skipped')
    }).Count
    $runningStages = @($stageProps | Where-Object { $_.Value.status -eq 'inProgress' }).Count
    $pct = if ($totalStages -gt 0) {
        [Math]::Round((($completedStages + ($runningStages * 0.5)) / $totalStages) * 100)
    } else { 0 }
    $barWidth = 20
    $filled = [Math]::Round($barWidth * $pct / 100)
    $empty = $barWidth - $filled
    $bar = ('█' * $filled) + ('░' * $empty)

    # ── Stage chain ─────────────────────────────────────────
    $chainIcons = @{
        'succeeded'  = '✅'
        'failed'     = '❌'
        'canceled'   = '⏹️'
        'inProgress' = '🔄'
        'notStarted' = '⬜'
        'skipped'    = '⏭️'
    }
    $chainParts = @()
    foreach ($prop in $stageProps) {
        $icon = if ($chainIcons.ContainsKey($prop.Value.status)) { $chainIcons[$prop.Value.status] } else { '⬜' }
        $shortName = if ($plainNames.ContainsKey($prop.Name)) { ($prop.Name) } else { $prop.Name }
        $chainParts += "$icon $shortName"
    }
    $chain = $chainParts -join ' → '

    $lines += "🚀 **Deployment Progress**"
    $lines += "``[$bar]`` $pct%  ·  Elapsed: $($data.elapsed)"
    $lines += ''
    $lines += $chain
    $lines += ''
    $lines += '| Step | Status | Time |'
    $lines += '|------|--------|------|'

    foreach ($prop in $data.stages.PSObject.Properties) {
        $name = if ($plainNames.ContainsKey($prop.Name)) { $plainNames[$prop.Name] } else { $prop.Name }
        $status = if ($statusIcons.ContainsKey($prop.Value.status)) { $statusIcons[$prop.Value.status] } else { $prop.Value.status }
        $dur = if ($prop.Value.duration) { $prop.Value.duration } else { '—' }
        $lines += "| $name | $status | $dur |"
    }

    return ($lines -join "`n")
}

# ════════════════════════════════════════════════════════════
# Pipeline YAML Diff Summary
# ════════════════════════════════════════════════════════════

function Get-YamlDiffSummary {
    <#
    .SYNOPSIS  Returns a concise summary of which YAML sections changed before overwrite.
    .DESCRIPTION
        Compares an existing pipeline YAML file with new content and reports which
        top-level sections (trigger, stages, variables, parameters, etc.) were added,
        removed, or modified. Used by Stage 2 to log changes before writing.
    .PARAMETER ExistingPath
        Absolute path to the existing pipeline YAML file.
    .PARAMETER NewContent
        The new YAML content string that will replace the file.
    .OUTPUTS
        Hashtable with Changed (string[]), Added (string[]), Removed (string[]), Summary (string).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExistingPath,
        [Parameter(Mandatory)][string]$NewContent
    )

    $result = @{ Changed = @(); Added = @(); Removed = @(); Summary = '' }

    if (-not (Test-Path $ExistingPath)) {
        $result.Summary = 'New file — no previous version to compare'
        return $result
    }

    $oldContent = Get-Content $ExistingPath -Raw
    if ($oldContent -eq $NewContent) {
        $result.Summary = 'No changes detected'
        return $result
    }

    # Extract top-level YAML keys (lines starting at column 0 with a colon)
    $keyPattern = '(?m)^(\w[\w-]*):'
    $oldKeys = @([regex]::Matches($oldContent, $keyPattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $newKeys = @([regex]::Matches($NewContent, $keyPattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $result.Added   = @($newKeys | Where-Object { $_ -notin $oldKeys })
    $result.Removed = @($oldKeys | Where-Object { $_ -notin $newKeys })

    # For shared keys, compare content between that key and the next top-level key
    foreach ($key in ($oldKeys | Where-Object { $_ -in $newKeys })) {
        $sectionPattern = "(?ms)^$([regex]::Escape($key)):.*?(?=^\w[\w-]*:|\z)"
        $oldSection = [regex]::Match($oldContent, $sectionPattern).Value
        $newSection = [regex]::Match($NewContent,  $sectionPattern).Value
        if ($oldSection -ne $newSection) {
            $result.Changed += $key
        }
    }

    $parts = @()
    if ($result.Changed.Count) { $parts += "Modified: $($result.Changed -join ', ')" }
    if ($result.Added.Count)   { $parts += "Added: $($result.Added -join ', ')" }
    if ($result.Removed.Count) { $parts += "Removed: $($result.Removed -join ', ')" }
    $result.Summary = if ($parts.Count) { $parts -join ' | ' } else { 'Content changed (no top-level key differences)' }

    return $result
}

# Agent Identity — Registry, Resolution, Runtime Surface, Stage Auth
# ════════════════════════════════════════════════════════════

function Resolve-AgentName {
    <#
    .SYNOPSIS Resolves an agent name or alias to the canonical registry name.
    .DESCRIPTION
        Looks up the name in deploy-config.json agents section. Returns the canonical
        name if found (direct match or alias). Emits a warning for unknown names.
        Returns the input unchanged if the registry is unavailable or the name is unknown.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $cfg = try { Get-DeployConfig } catch { return $Name }
    if (-not $cfg.PSObject.Properties['agents']) { return $Name }
    $agents = $cfg.agents

    # Direct match
    if ($agents.PSObject.Properties[$Name]) { return $Name }

    # Alias resolution
    foreach ($agentProp in $agents.PSObject.Properties) {
        $agent = $agentProp.Value
        if ($agent.PSObject.Properties['alias'] -and $agent.alias -contains $Name) {
            return $agentProp.Name
        }
    }

    Write-Warning "Unknown agent name '$Name' — not in deploy-config.json agents registry"
    return $Name
}

function Get-RuntimeSurface {
    <#
    .SYNOPSIS Detects which runtime surface is executing the agent.
    .DESCRIPTION
        Checks environment variables to determine if running under VS Code,
        Copilot CLI, Claude CLI, or CI/CD automation. Returns 'unknown' if
        no recognized surface is detected.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param()

    if ($env:VSCODE_PID -or $env:VSCODE_IPC_HOOK_CLI) { return 'vscode' }
    if ($env:COPILOT_CLI -or $env:GITHUB_COPILOT_CLI) { return 'copilot-cli' }
    if ($env:CLAUDE_CLI -or $env:ANTHROPIC_CLI) { return 'claude-cli' }
    if ($env:TF_BUILD -or $env:BUILD_BUILDID -or $env:GITHUB_ACTIONS) { return 'ci-automation' }
    return 'unknown'
}

function Test-AgentStageAuth {
    <#
    .SYNOPSIS Checks if an agent is authorized to operate in a given stage.
    .DESCRIPTION
        Validates the agent name against the registry's stages list. Orchestrator
        is authorized for all stages. Returns $true if authorized or if the
        registry is unavailable (fail-open for backward compatibility).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][ValidateRange(0,4)][int]$Stage
    )

    $cfg = try { Get-DeployConfig } catch { return $true }
    if (-not $cfg.PSObject.Properties['agents']) { return $true }
    $agents = $cfg.agents

    $resolved = Resolve-AgentName -Name $AgentName
    if (-not $agents.PSObject.Properties[$resolved]) { return $true }

    $agentDef = $agents.$resolved
    if ($agentDef.type -eq 'orchestrator') { return $true }
    if ($Stage -eq 0) { return $true }

    return ($Stage -in @($agentDef.stages))
}

# ════════════════════════════════════════════════════════════
# Logging — Write-VsdLog, Initialize-VsdLogRotation, New-DeploymentId
# ════════════════════════════════════════════════════════════

function New-DeploymentId {
    <#
    .SYNOPSIS Generates a unique deployment correlation ID.
    .DESCRIPTION Format: d- + 8 hex characters (e.g., d-a1b2c3d4).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param()
    return "d-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
}

function Initialize-VsdLogRotation {
    <#
    .SYNOPSIS Rotates deploy.log files at the start of a new deployment.
    .DESCRIPTION
        Shifts deploy.log → deploy.log.1, deploy.log.1 → deploy.log.2, etc.
        Deletes files beyond KeepCount. Called once at Stage 1 start.
    .PARAMETER WorkspacePath
        Workspace root directory.
    .PARAMETER KeepCount
        Number of previous log files to retain. Default: from config or 5.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [int]$KeepCount = 0
    )

    $cfg = try { Get-DeployConfig } catch { $null }
    $logRelPath = if ($cfg -and $cfg.PSObject.Properties['logging'] -and $cfg.logging.PSObject.Properties['logFile']) {
        $cfg.logging.logFile
    } else { '.vibeshield/deploy.log' }
    if ($KeepCount -le 0) {
        $KeepCount = if ($cfg -and $cfg.PSObject.Properties['logging'] -and $cfg.logging.PSObject.Properties['keepLogCount']) {
            [int]$cfg.logging.keepLogCount
        } else { 5 }
    }

    $logPath = Join-Path -Path $WorkspacePath -ChildPath $logRelPath
    $logDir = Split-Path -Path $logPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Shift existing numbered logs: .5 → delete, .4 → .5, ... .1 → .2
    for ($i = $KeepCount; $i -ge 1; $i--) {
        $src = "$logPath.$i"
        if ($i -eq $KeepCount) {
            if (Test-Path $src) { Remove-Item $src -Force }
        } else {
            $dst = "$logPath.$($i + 1)"
            if (Test-Path $src) { Move-Item $src $dst -Force }
        }
    }

    # Current log → .1
    if (Test-Path $logPath) {
        Move-Item $logPath "$logPath.1" -Force
    }
}

function Write-VsdLog {
    <#
    .SYNOPSIS Emits a structured JSON log entry to deploy.log, audit.jsonl, and stdout.
    .DESCRIPTION
        Core logging function for VibeShield-Deploy. Every log entry is a JSON
        object with a fixed schema. Writes to three sinks:
          1. deploy.log (JSONL, all levels)
          2. audit.jsonl (JSONL, info+ lifecycle and check events only)
          3. stdout (human-readable Write-Output, unchanged from current behavior)

        Never throws — logging failures emit Write-Warning and continue.
        All messages are sanitized via Remove-SensitiveContent before writing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Category,
        [ValidateSet('debug','info','warn','error','fatal')]
        [string]$Level = 'info',
        [Parameter(Mandatory)][string]$Agent,
        [string]$Skill,
        [Parameter(Mandatory)][string]$Script,
        [string]$CheckId,
        [int]$Stage,
        [int]$DurationMs = -1,
        [hashtable]$Extra,
        [string]$DeploymentId,
        [string]$WorkspacePath
    )

    try {
        # ── Resolve config ──────────────────────────────────
        $cfg = try { Get-DeployConfig } catch { $null }
        $logCfg = if ($cfg -and $cfg.PSObject.Properties['logging']) { $cfg.logging } else { $null }

        $minLevel = if ($logCfg -and $logCfg.PSObject.Properties['level']) { $logCfg.level } else { 'info' }
        $auditEnabled = if ($logCfg -and $logCfg.PSObject.Properties['auditEnabled']) { [bool]$logCfg.auditEnabled } else { $true }
        $sanitize = if ($logCfg -and $logCfg.PSObject.Properties['sanitizeOutput']) { [bool]$logCfg.sanitizeOutput } else { $true }

        $logRelPath = if ($logCfg -and $logCfg.PSObject.Properties['logFile']) { $logCfg.logFile } else { '.vibeshield/deploy.log' }
        $auditRelPath = if ($logCfg -and $logCfg.PSObject.Properties['auditFile']) { $logCfg.auditFile } else { '.vibeshield/audit.jsonl' }

        $wsPath = if ($WorkspacePath) { $WorkspacePath } else { $PWD.Path }
        $logPath = Join-Path -Path $wsPath -ChildPath $logRelPath
        $auditPath = Join-Path -Path $wsPath -ChildPath $auditRelPath

        # ── Level filtering ─────────────────────────────────
        $levelOrder = @{ 'debug'=0; 'info'=1; 'warn'=2; 'error'=3; 'fatal'=4 }
        $numLevel = if ($levelOrder.ContainsKey($Level)) { $levelOrder[$Level] } else { 1 }
        $numMin = if ($levelOrder.ContainsKey($minLevel)) { $levelOrder[$minLevel] } else { 1 }

        # ── Sanitize ────────────────────────────────────────
        $safeMessage = $Message
        $safeExtra = $Extra
        if ($sanitize -and (Get-Command Remove-SensitiveContent -ErrorAction SilentlyContinue)) {
            $safeMessage = Remove-SensitiveContent -Text $Message
            if ($Extra) {
                $extraJson = ($Extra | ConvertTo-Json -Depth 3 -Compress)
                $extraJson = Remove-SensitiveContent -Text $extraJson
                $safeExtra = $extraJson | ConvertFrom-Json -AsHashtable
            }
        }

        # ── Agent validation & runtime surface ──────────────
        $resolvedAgent = $Agent
        if (Get-Command Resolve-AgentName -ErrorAction SilentlyContinue) {
            $resolvedAgent = Resolve-AgentName -Name $Agent
        }
        if ($Stage -gt 0 -and (Get-Command Test-AgentStageAuth -ErrorAction SilentlyContinue)) {
            if (-not (Test-AgentStageAuth -AgentName $resolvedAgent -Stage $Stage)) {
                Write-Warning "Agent '$resolvedAgent' is not authorized for stage $Stage"
            }
        }
        $surface = if (Get-Command Get-RuntimeSurface -ErrorAction SilentlyContinue) { Get-RuntimeSurface } else { 'unknown' }

        # ── Build entry ─────────────────────────────────────
        $utcNow = (Get-Date).ToUniversalTime()
        $entry = [ordered]@{
            ts             = '{0:yyyy-MM-dd}T{0:HH:mm:ss}.{1}Z' -f $utcNow, $utcNow.ToString('fff')
            deploymentId   = if ($DeploymentId) { $DeploymentId } else { '' }
            stage          = $Stage
            agent          = $resolvedAgent
            runtimeSurface = $surface
            script         = $Script
            level          = $Level
            category       = $Category
            message        = $safeMessage
        }
        if ($Skill) { $entry['skill'] = $Skill }
        if ($CheckId) { $entry['checkId'] = $CheckId }
        if ($DurationMs -ge 0) { $entry['durationMs'] = $DurationMs }
        if ($safeExtra -and $safeExtra.Count -gt 0) { $entry['extra'] = $safeExtra }

        $jsonLine = ($entry | ConvertTo-Json -Depth 5 -Compress)

        # ── Write to deploy.log ─────────────────────────────
        if ($numLevel -ge $numMin) {
            $logDir = Split-Path -Path $logPath -Parent
            if ($logDir -and -not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }

            # Safety cap: if log exceeds maxLogSizeMB, don't write
            $maxSizeMB = if ($logCfg -and $logCfg.PSObject.Properties['maxLogSizeMB'] -and $logCfg.maxLogSizeMB) { [int]$logCfg.maxLogSizeMB } else { 10 }
            $writeLog = $true
            if (Test-Path $logPath) {
                $fileSizeMB = (Get-Item $logPath).Length / 1MB
                if ($fileSizeMB -ge $maxSizeMB) { $writeLog = $false }
            }
            if ($writeLog) {
                [System.IO.File]::AppendAllText($logPath, "$jsonLine`n", [System.Text.Encoding]::UTF8)
            }
        }

        # ── Write to audit.jsonl (info+ lifecycle/check events only) ──
        if ($auditEnabled -and $numLevel -ge 1 -and ($CheckId -or $Category -in @('lifecycle','integrity','state'))) {
            $auditDir = Split-Path -Path $auditPath -Parent
            if ($auditDir -and -not (Test-Path $auditDir)) {
                New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
            }
            [System.IO.File]::AppendAllText($auditPath, "$jsonLine`n", [System.Text.Encoding]::UTF8)

            # ── Audit trim ──────────────────────────────────
            $maxEntries = if ($logCfg -and $logCfg.PSObject.Properties['maxAuditEntries'] -and $logCfg.maxAuditEntries) { [int]$logCfg.maxAuditEntries } else { 5000 }
            $trimPct = if ($logCfg -and $logCfg.PSObject.Properties['auditTrimPercent'] -and $logCfg.auditTrimPercent) { [int]$logCfg.auditTrimPercent } else { 20 }
            if (Test-Path $auditPath) {
                $lines = [System.IO.File]::ReadAllLines($auditPath, [System.Text.Encoding]::UTF8)
                if ($lines.Count -gt $maxEntries) {
                    $removeCount = [Math]::Ceiling($lines.Count * $trimPct / 100)
                    $archivePath = "$auditPath.archive"
                    $trimmed = $lines[0..($removeCount - 1)]
                    [System.IO.File]::AppendAllText($archivePath, (($trimmed -join "`n") + "`n"), [System.Text.Encoding]::UTF8)
                    $kept = $lines[$removeCount..($lines.Count - 1)]
                    [System.IO.File]::WriteAllLines($auditPath, $kept, [System.Text.Encoding]::UTF8)
                }
            }
        }
    }
    catch {
        # Logging must never crash the deployment
        Write-Warning "Write-VsdLog failed: $($_.Exception.Message)"
    }
}

# ════════════════════════════════════════════════════════════
# Stage Timeline & Error History (Phase 4)
# ════════════════════════════════════════════════════════════

function Start-StageTimer {
    <#
    .SYNOPSIS Records the start time for a deployment stage.
    .DESCRIPTION
        Reads the current state file and adds/updates the stageTimeline entry
        for the given stage with a startedAt timestamp. Called at the beginning
        of each runner script.
    .PARAMETER WorkspacePath
        Workspace root directory.
    .PARAMETER Stage
        Stage number (1–4).
    .PARAMETER Agent
        Agent name performing this stage (for provenance tracking).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][ValidateRange(1,4)][int]$Stage,
        [string]$Agent
    )

    $stateFilePath = Get-StateFilePath -WorkspacePath $WorkspacePath
    $state = @{}
    if (Test-Path $stateFilePath) {
        try {
            $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
            foreach ($prop in $stateObj.PSObject.Properties) {
                $state[$prop.Name] = $prop.Value
            }
        } catch { <# start fresh #> $null = $_ }
    }

    # Initialize stageTimeline if missing
    $timeline = @{}
    if ($state.ContainsKey('StageTimeline') -and $null -ne $state['StageTimeline']) {
        $tl = $state['StageTimeline']
        if ($tl -is [hashtable]) { $timeline = $tl }
        elseif ($tl.PSObject) {
            foreach ($p in $tl.PSObject.Properties) { $timeline[$p.Name] = $p.Value }
        }
    }

    $timeline["$Stage"] = @{
        startedAt = (Get-Date -Format 'o')
        performedBy = if ($Agent) { Resolve-AgentName -Name $Agent } else { '' }
        runtimeSurface = (Get-RuntimeSurface)
    }
    $state['StageTimeline'] = $timeline

    # Record runtime surface at deployment level
    if (-not $state.ContainsKey('RuntimeSurface')) {
        $state['RuntimeSurface'] = (Get-RuntimeSurface)
    }

    # Initialize deploymentId if this is Stage 1
    if ($Stage -eq 1 -and -not $state.ContainsKey('DeploymentId')) {
        $state['DeploymentId'] = New-DeploymentId
    }

    # Initialize deploymentAttempts counter
    if (-not $state.ContainsKey('DeploymentAttempts')) {
        $state['DeploymentAttempts'] = 1
    }

    # Capture user identity (from az account)
    if (-not $state.ContainsKey('User')) {
        try {
            $acctJson = az account show -o json 2>$null | Out-String
            if ($LASTEXITCODE -eq 0 -and $acctJson) {
                $acct = $acctJson | ConvertFrom-Json
                if ($acct.user -and $acct.user.name) {
                    $state['User'] = $acct.user.name
                }
            }
        } catch { <# not logged in — skip #> $null = $_ }
    }

    Write-DeployState -WorkspacePath $WorkspacePath -StateData $state
}

function Complete-StageTimer {
    <#
    .SYNOPSIS Records the completion time and duration for a deployment stage.
    .PARAMETER WorkspacePath
        Workspace root directory.
    .PARAMETER Stage
        Stage number (1–4).
    .PARAMETER Passed
        Number of checks that passed.
    .PARAMETER Failed
        Number of checks that failed.
    .PARAMETER Warned
        Number of checks with warnings.
    .PARAMETER Skipped
        Number of checks skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][ValidateRange(1,4)][int]$Stage,
        [int]$Passed = 0,
        [int]$Failed = 0,
        [int]$Warned = 0,
        [int]$Skipped = 0
    )

    $stateFilePath = Get-StateFilePath -WorkspacePath $WorkspacePath
    if (-not (Test-Path $stateFilePath)) { return }

    try {
        $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
        $state = @{}
        foreach ($prop in $stateObj.PSObject.Properties) {
            $state[$prop.Name] = $prop.Value
        }
    } catch { return }

    $timeline = @{}
    if ($state.ContainsKey('StageTimeline') -and $null -ne $state['StageTimeline']) {
        $tl = $state['StageTimeline']
        if ($tl -is [hashtable]) { $timeline = $tl }
        elseif ($tl.PSObject) {
            foreach ($p in $tl.PSObject.Properties) { $timeline[$p.Name] = $p.Value }
        }
    }

    $completedAt = (Get-Date -Format 'o')
    $stageEntry = @{}
    if ($timeline.ContainsKey("$Stage")) {
        $existing = $timeline["$Stage"]
        if ($existing -is [hashtable]) { $stageEntry = $existing }
        elseif ($existing.PSObject) {
            foreach ($p in $existing.PSObject.Properties) { $stageEntry[$p.Name] = $p.Value }
        }
    }

    $stageEntry['completedAt'] = $completedAt
    if ($stageEntry.ContainsKey('startedAt') -and $stageEntry['startedAt']) {
        try {
            $started = [datetime]::Parse($stageEntry['startedAt'])
            $completed = [datetime]::Parse($completedAt)
            $stageEntry['durationMs'] = [int]($completed - $started).TotalMilliseconds
        } catch { <# skip duration calc #> $null = $_ }
    }
    $stageEntry['passed'] = $Passed
    $stageEntry['failed'] = $Failed
    $stageEntry['warned'] = $Warned
    $stageEntry['skipped'] = $Skipped

    $timeline["$Stage"] = $stageEntry
    $state['StageTimeline'] = $timeline

    Write-DeployState -WorkspacePath $WorkspacePath -StateData $state
}

function Add-ErrorToHistory {
    <#
    .SYNOPSIS Appends an error to the deployment error history.
    .DESCRIPTION
        Maintains a bounded list (last 20) of errors with timestamps.
        Called when a stage fails, before retrying.
    .PARAMETER WorkspacePath
        Workspace root directory.
    .PARAMETER Stage
        Stage number where the error occurred.
    .PARAMETER ErrorMessage
        The error message to record.
    .PARAMETER Category
        Error category (e.g., 'build-failure', 'push-rejected', 'pipeline-timeout').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][int]$Stage,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [string]$Category = 'unknown'
    )

    $stateFilePath = Get-StateFilePath -WorkspacePath $WorkspacePath
    if (-not (Test-Path $stateFilePath)) { return }

    try {
        $stateObj = Get-Content $stateFilePath -Raw | ConvertFrom-Json
        $state = @{}
        foreach ($prop in $stateObj.PSObject.Properties) {
            $state[$prop.Name] = $prop.Value
        }
    } catch { return }

    $history = @()
    if ($state.ContainsKey('ErrorHistory') -and $null -ne $state['ErrorHistory']) {
        $history = @($state['ErrorHistory'])
    }

    # Sanitize error message
    $safeMsg = $ErrorMessage
    if (Get-Command Remove-SensitiveContent -ErrorAction SilentlyContinue) {
        $safeMsg = Remove-SensitiveContent -Text $ErrorMessage
    }

    $history += @{
        timestamp = (Get-Date -Format 'o')
        stage     = $Stage
        category  = $Category
        message   = $safeMsg
    }

    # Keep last 20 entries
    if ($history.Count -gt 20) {
        $history = $history[($history.Count - 20)..($history.Count - 1)]
    }

    $state['ErrorHistory'] = $history
    # Increment deployment attempts
    if ($state.ContainsKey('DeploymentAttempts')) {
        $state['DeploymentAttempts'] = [int]$state['DeploymentAttempts'] + 1
    } else {
        $state['DeploymentAttempts'] = 2
    }

    Write-DeployState -WorkspacePath $WorkspacePath -StateData $state
}

# ════════════════════════════════════════════════════════════
# Write-DeployState — Fold state writes into script exit
# ════════════════════════════════════════════════════════════

function Write-DeployState {
    <#
    .SYNOPSIS Writes deployment state via Invoke-StateFileManager.ps1 (subprocess).
    .DESCRIPTION
        Called by end-of-stage scripts when -UpdateState is set and the script
        succeeded (exit code 0). Runs the state manager as a subprocess (& call)
        to avoid the state manager's `exit 0` terminating the caller.
    .PARAMETER WorkspacePath
        Root of the workspace (passed through to the state manager).
    .PARAMETER StateData
        Hashtable of state values to write (e.g. @{ LastCompletedStage = 1; AppType = '.NET' }).
    .PARAMETER StateJson
        JSON string alternative to StateData. Converted to hashtable internally.
        Accepts the same keys as StateData. Useful for direct CLI invocation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory = $false)][Alias('Data')][hashtable]$StateData,
        [Parameter(Mandatory = $false)][string]$StateJson
    )
    # Accept either -StateData (hashtable) or -StateJson (string)
    if (-not $StateData -and $StateJson) {
        $jsonObj = $StateJson | ConvertFrom-Json
        $StateData = @{}
        foreach ($prop in $jsonObj.PSObject.Properties) {
            $StateData[$prop.Name] = $prop.Value
        }
    }
    if (-not $StateData) {
        Write-Warning "Write-DeployState: No state data provided (pass -StateData or -StateJson)"
        return
    }
    $stateManagerPath = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-state-management', 'scripts', 'Invoke-StateFileManager.ps1'
    if (-not (Test-Path $stateManagerPath)) {
        Write-Warning "State manager not found at: $stateManagerPath"
        return
    }
    Write-Output "  Writing deploy state (LastCompletedStage=$($StateData['LastCompletedStage']))..."
    $global:LASTEXITCODE = 0
    & $stateManagerPath -Action Write -WorkspacePath $WorkspacePath -State $StateData
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  ✅ Deploy state updated successfully"
    } else {
        Write-Warning "State manager returned exit code $LASTEXITCODE"
    }
}

# ════════════════════════════════════════════════════════════
# Response Personalization — User Preference Management
# ════════════════════════════════════════════════════════════

<#
.SYNOPSIS Returns built-in default preferences as a hashtable.
.DESCRIPTION Reads defaults from .github/config/deploy-config.json (preferences.defaults).
#>
function Get-DefaultPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    param()
    $cfg = Get-DeployConfig
    $d   = $cfg.preferences.defaults
    @{
        verbosity          = $d.verbosity
        tone               = $d.tone
        confirmations      = $d.confirmations
        progress_format    = $d.progress_format
        error_detail       = $d.error_detail
        emoji              = [bool]$d.emoji
        inline_definitions = [bool]$d.inline_definitions
        profile            = $d.profile
    }
}

<#
.SYNOPSIS Returns the axis values for a named profile.
.DESCRIPTION Reads profiles from .github/config/deploy-config.json (preferences.profiles).
             Returns $null if the profile name is unrecognized.
#>
function Get-PreferenceProfile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfileName)

    $cfg  = Get-DeployConfig
    $key  = $ProfileName.ToLower()
    $prof = $cfg.preferences.profiles.PSObject.Properties | Where-Object { $_.Name -eq $key }
    if (-not $prof) { return $null }

    $p = $prof.Value
    return @{
        verbosity          = $p.verbosity
        tone               = $p.tone
        confirmations      = $p.confirmations
        progress_format    = $p.progress_format
        error_detail       = $p.error_detail
        emoji              = [bool]$p.emoji
        inline_definitions = [bool]$p.inline_definitions
    }
}

<#
.SYNOPSIS Parses a flat YAML file (key: value pairs, comments, no nesting) into a hashtable.
.DESCRIPTION Handles string, boolean, and null values. Lines starting with # are comments.
             Only supports the flat key-value format used by user-preferences.yaml.
#>
function ConvertFrom-SimpleYaml {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    $result = @{}
    $lines = Get-Content $Path -Encoding utf8

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        # Skip empty lines and comments
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

        # Match key: value (value may contain inline comment after #)
        if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $key   = $Matches[1]
            $value = $Matches[2].Trim()

            # Strip inline comments (# not inside quotes)
            if ($value -match '^([^#]*?)\s+#') {
                $value = $Matches[1].Trim()
            }

            # Type coercion
            switch -Regex ($value) {
                '^true$'  { $result[$key] = $true;  break }
                '^false$' { $result[$key] = $false; break }
                '^null$'  { $result[$key] = $null;  break }
                '^~$'     { $result[$key] = $null;  break }
                default   { $result[$key] = $value }
            }
        }
    }
    return $result
}

<#
.SYNOPSIS Writes a hashtable to a flat YAML file.
#>
function ConvertTo-SimpleYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Data,
        [Parameter(Mandatory)][string]$Path
    )

    $lines = @('# VibeShield-Deploy — User Preferences', "# Generated: $(Get-Date -Format 'o')", '')

    foreach ($key in ($Data.Keys | Sort-Object)) {
        $val = $Data[$key]
        if ($null -eq $val)       { $valStr = 'null' }
        elseif ($val -is [bool])  { $valStr = if ($val) { 'true' } else { 'false' } }
        else                      { $valStr = [string]$val }
        $lines += "${key}: $valStr"
    }

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Set-Content -Path $Path -Value ($lines -join "`n") -Encoding utf8 -NoNewline
}

<#
.SYNOPSIS  Resolves the effective user preferences by layering defaults → team → user → session.
.DESCRIPTION
    Resolution order (highest priority last):
      1. Built-in defaults (Get-DefaultPreferences)
      2. Team preferences  (.vibeshield/team-preferences.yaml — checked into repo)
      3. User preferences  (.vibeshield/user-preferences.yaml — .gitignored)
      4. Session overrides  (passed in via -SessionOverrides hashtable)

    If any layer specifies a 'profile' key, the profile's axes are applied first,
    then any explicit axis values in that same layer override the profile.

    Validates all values against allowed enums. Invalid values are ignored with a warning.

.PARAMETER WorkspacePath
    Root of the workspace. Used to locate .vibeshield/*.yaml files.

.PARAMETER SessionOverrides
    Hashtable of session-level overrides (from inline commands like "be concise").
#>
function Resolve-UserPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [hashtable]$SessionOverrides = @{}
    )

    # ── Allowed values for validation ───────────────────────
    $allowed = @{
        verbosity       = @('minimal', 'standard', 'detailed')
        tone            = @('friendly', 'professional', 'terse')
        confirmations   = @('always', 'irreversible-only', 'auto')
        progress_format = @('grouped', 'per-check', 'silent')
        error_detail    = @('actionable', 'technical', 'both')
    }

    # ── Layer 1: Built-in defaults ──────────────────────────
    $resolved = Get-DefaultPreferences

    # ── Helper: merge one layer into resolved ───────────────
    $mergeLayer = {
        param([hashtable]$Layer)
        if (-not $Layer -or $Layer.Count -eq 0) { return }

        # If layer specifies a profile, apply profile axes first
        if ($Layer.ContainsKey('profile') -and $Layer['profile']) {
            $profileAxes = Get-PreferenceProfile -ProfileName $Layer['profile']
            if ($profileAxes) {
                foreach ($pk in $profileAxes.Keys) {
                    $resolved[$pk] = $profileAxes[$pk]
                }
            } else {
                Write-Warning "Unknown preference profile: '$($Layer['profile'])' — ignoring"
            }
        }

        # Then apply explicit axis values (override profile if both present)
        foreach ($key in $Layer.Keys) {
            if ($key -eq 'profile') { continue }
            if (-not $resolved.ContainsKey($key)) {
                Write-Warning "Unknown preference key: '$key' — ignoring"
                continue
            }
            $val = $Layer[$key]
            # Validate enum values
            if ($allowed.ContainsKey($key)) {
                if ($val -notin $allowed[$key]) {
                    Write-Warning "Invalid value '$val' for preference '$key' (allowed: $($allowed[$key] -join ', ')) — ignoring"
                    continue
                }
            }
            $resolved[$key] = $val
        }
    }

    # ── Layer 2: Team preferences ───────────────────────────
    $teamPath = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield' -AdditionalChildPath 'team-preferences.yaml'
    $teamPrefs = ConvertFrom-SimpleYaml -Path $teamPath
    if ($teamPrefs) { & $mergeLayer $teamPrefs }

    # ── Layer 3: User preferences ───────────────────────────
    $userPath = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield' -AdditionalChildPath 'user-preferences.yaml'
    $userPrefs = ConvertFrom-SimpleYaml -Path $userPath
    if ($userPrefs) { & $mergeLayer $userPrefs }

    # ── Layer 4: Session overrides ──────────────────────────
    if ($SessionOverrides.Count -gt 0) { & $mergeLayer $SessionOverrides }

    # ── Derived rules ───────────────────────────────────────
    # minimal verbosity forces inline_definitions off
    if ($resolved['verbosity'] -eq 'minimal') {
        $resolved['inline_definitions'] = $false
    }

    return $resolved
}

<#
.SYNOPSIS Persists current session preferences to .vibeshield/user-preferences.yaml.
.DESCRIPTION Called when the user says "save these preferences". Writes only non-default
             values to keep the file minimal.
#>
function Save-UserPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural noun is intentional')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][hashtable]$Preferences
    )

    $defaults = Get-DefaultPreferences
    $toSave = @{}

    foreach ($key in $Preferences.Keys) {
        if ($key -eq 'profile') {
            if ($Preferences[$key] -and $Preferences[$key] -ne $defaults['profile']) {
                $toSave[$key] = $Preferences[$key]
            }
            continue
        }
        if ($defaults.ContainsKey($key) -and $Preferences[$key] -ne $defaults[$key]) {
            $toSave[$key] = $Preferences[$key]
        }
    }

    $userPath = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield' -AdditionalChildPath 'user-preferences.yaml'
    if ($toSave.Count -eq 0) {
        Write-Output "All preferences match defaults — nothing to save."
        if (Test-Path $userPath) { Remove-Item $userPath -Force }
        return
    }

    ConvertTo-SimpleYaml -Data $toSave -Path $userPath
    Write-Output "  ✅ Preferences saved to $userPath"
}

<#
.SYNOPSIS Maps inline natural-language toggle commands to session overrides.
.DESCRIPTION Detects phrases like "be concise", "explain more", "skip confirmations"
             and returns a hashtable of preference overrides to merge.
             Returns an empty hashtable if no toggle is detected.
#>
function Get-InlinePreferenceToggle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserMessage)

    $msg = $UserMessage.ToLower().Trim()
    $overrides = @{}

    # Verbosity toggles
    if ($msg -match '\b(be concise|less detail|minimal mode|be brief)\b') {
        $overrides['verbosity'] = 'minimal'
        $overrides['inline_definitions'] = $false
    }
    elseif ($msg -match '\b(explain more|be verbose|more detail|detailed mode)\b') {
        $overrides['verbosity'] = 'detailed'
        $overrides['inline_definitions'] = $true
    }

    # Confirmation toggles
    if ($msg -match '\b(skip confirmations|auto.?confirm)\b') {
        $overrides['confirmations'] = 'auto'
    }

    # Output toggles
    if ($msg -match '\b(show raw output|raw mode)\b') {
        $overrides['progress_format'] = 'per-check'
        $overrides['error_detail'] = 'technical'
    }

    # Profile activation
    if ($msg -match '\buse (beginner|developer|ci.?automation) (mode|profile)\b') {
        $overrides['profile'] = $Matches[1] -replace '[^a-z-]', '-'
    }

    # Save trigger (handled by caller, but detected here)
    if ($msg -match '\b(save (these |my )?preferences)\b') {
        $overrides['_save'] = $true
    }

    return $overrides
}