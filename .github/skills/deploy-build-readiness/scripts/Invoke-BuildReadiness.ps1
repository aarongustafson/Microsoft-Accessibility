#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    VibeShield-Deploy build & deploy readiness — verifies every workspace module
    builds and tests locally, validates pipeline SDK alignment, confirms
    deployability, and checks Bicep coverage.

.DESCRIPTION
    Reads the workspace manifest produced by Invoke-WorkspaceAnalysis.ps1 and
    checks each module against the pipeline YAML.

    Checks:
      BR-01  Per-module local build
      BR-02  Per-module local tests
      BR-03  Pipeline SDK alignment
      BR-04  Pipeline stage completeness
      BR-05  Module deployability (composite)
      BR-06  Multi-module Bicep coverage

    Exit code 0 = all checks passed. Exit code 1 = one or more checks failed.

.PARAMETER ManifestPath
    Path to the workspace-manifest.json from Invoke-WorkspaceAnalysis.
    Defaults to .vibeshield/results/workspace-manifest.json in workspace.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER PipelineYmlPath
    Path to the pipeline YAML. Defaults to .azdo/pipelines/azure-pipeline.yml in workspace.

.PARAMETER SkipBuild
    Skip local build checks (BR-01).

.PARAMETER SkipTests
    Skip local test checks (BR-02).

.PARAMETER SkipBuildProbe
    Skip the BR-00 buildability probe (-SkipBuildProbe). All modules default to 'unknown'.

.PARAMETER SarifPath
    Path to write the SARIF results file.
    Defaults to .vibeshield/results/build-readiness-results.sarif.

.EXAMPLE
    ./.github/skills/deploy-build-readiness/scripts/Invoke-BuildReadiness.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural nouns are intentional for collection-returning functions')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipBuildProbe', Justification='Reserved for future use')]
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$WorkspacePath = $PWD.Path,
    [string]$PipelineYmlPath,
    [ValidateSet('ARM','EV2','')][string]$InfraDeployMethod = '',
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$SkipBuildProbe,
    [string]$SarifPath,
    [switch]$UpdateState,
    [string]$StateJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load shared helpers (for Write-DeployState) ─────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }

# ── Results collector ───────────────────────────────────────
$script:Results  = [System.Collections.ArrayList]::new()
$script:ExitCode = 0

$script:CheckNames = @{
    'BR-00' = 'Build Probe'
    'BR-01' = 'Local Build'
    'BR-02' = 'Local Unit Tests'
    'BR-03' = 'SDK Alignment'
    'BR-04' = 'Pipeline Stage Completeness'
    'BR-05' = 'Module Deployability'
    'BR-06' = 'Bicep Coverage'
    'BR-07' = 'Startup Smoke Test'
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

    $icon = switch ($Status) { 'PASS' { '✅' } 'FAIL' { '❌' } 'WARN' { '⚠️' } 'SKIP' { '⏭️' } }
    Write-Output "  $icon ${Id}: $name — $Message"

    # ── Structured log ──────────────────────────────────────
    $logLevel = switch ($Status) { 'PASS' {'info'} 'FAIL' {'error'} 'WARN' {'warn'} 'SKIP' {'info'} default {'info'} }
    if (Get-Command Write-VsdLog -ErrorAction SilentlyContinue) {
        Write-VsdLog -Message "$Id $name — $Message" -Category 'build-readiness' -Level $logLevel `
            -Agent 'vibeshield-deploy-pipeline-author' -Skill 'deploy-build-readiness' `
            -Script 'Invoke-BuildReadiness.ps1' -CheckId $Id -Stage 2 `
            -WorkspacePath $WorkspacePath `
            -Extra @{ status = $Status; fix = if ($Fix) { $Fix } else { '' } }
    }
}

# ════════════════════════════════════════════════════════════
#  Helper — get build/test commands for an app type
#  Delegates to centralized deploy-app-type-select engine.
# ════════════════════════════════════════════════════════════

function Get-BuildTestCommands {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AppType', Justification='Interface contract parameter')]
    param([string]$AppType, [string]$ModulePath)

    # Use centralized detection engine — reads build/test commands from deploy-config.json
    if (Get-Command Get-AppType -ErrorAction SilentlyContinue) {
        $detection = Get-AppType -Path $ModulePath -WorkspacePath $script:WorkspacePath
        if ($detection) {
            return [pscustomobject]@{ BuildCmd = $detection.BuildCmd; TestCmd = $detection.TestCmd }
        }
    }

    # Fallback: return null commands if centralized engine unavailable
    return [pscustomobject]@{ BuildCmd = $null; TestCmd = $null }
}

# ════════════════════════════════════════════════════════════
#  Helper — run a shell command in a module directory
# ════════════════════════════════════════════════════════════

function Invoke-ModuleCommand {
    param([string]$Command, [string]$ModulePath)

    $runOnWindows = $IsWindows -or ($env:OS -eq 'Windows_NT')
    $shell = if ($runOnWindows) { 'cmd' } else { 'sh' }
    $shellArgs = if ($runOnWindows) { "/c `"$Command`"" } else { "-c `"$Command`"" }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $shell
    $psi.Arguments = $shellArgs
    $psi.WorkingDirectory = $ModulePath
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $null = $proc.WaitForExit(120000) # 2 minute timeout
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            Stdout   = ''
            Stderr   = $_.Exception.Message
        }
    }
}

# ════════════════════════════════════════════════════════════
#  Helper — detect local SDK version from project files
# ════════════════════════════════════════════════════════════

function Get-LocalSdkVersion {
    param([string]$AppType, [string]$ModulePath)

    switch ($AppType) {
        { $_ -in @('.NET', 'F#', 'VB.NET', 'Functions') } {
            $globalJsonPath = Join-Path -Path $ModulePath -ChildPath 'global.json'
            if (-not (Test-Path $globalJsonPath)) {
                $wsRoot = Split-Path -Path $ModulePath -Parent
                $rootGlobalJson = Join-Path -Path $wsRoot -ChildPath 'global.json'
                if (Test-Path $rootGlobalJson) { $globalJsonPath = $rootGlobalJson }
            }
            if (Test-Path $globalJsonPath) {
                try {
                    $globalJson = Get-Content $globalJsonPath -Raw | ConvertFrom-Json
                    if ($globalJson.PSObject.Properties['sdk'] -and $globalJson.sdk.PSObject.Properties['version']) {
                        $sdkVer = $globalJson.sdk.version
                        if ($sdkVer -match '(\d+)\.(\d+)') {
                            return [pscustomobject]@{ SdkName = '.NET'; Version = "$($Matches[1]).$($Matches[2])"; Raw = "global.json sdk.version=$sdkVer"; Source = 'global.json' }
                        }
                    }
                } catch { <# Intentionally suppressed — global.json parse is best-effort #> $null = $_ }
            }

            try {
                $dotnetOutput = & dotnet --version 2>$null
                if ($LASTEXITCODE -eq 0 -and $dotnetOutput -match '(\d+)\.(\d+)\.(\d+)') {
                    $dotnetVer = $dotnetOutput.Trim()
                    return [pscustomobject]@{ SdkName = '.NET'; Version = "$($Matches[1]).$($Matches[2])"; Raw = "dotnet --version=$dotnetVer"; Source = 'dotnet-cli' }
                }
            } catch { <# dotnet not installed — continue to next priority #> $null = $_ }

            $slnxFiles = Get-ChildItem -Path $ModulePath -Filter '*.slnx' -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $slnxFiles) {
                $wsRoot = Split-Path -Path $ModulePath -Parent
                $slnxFiles = Get-ChildItem -Path $wsRoot -Filter '*.slnx' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($slnxFiles) {
                return [pscustomobject]@{ SdkName = '.NET'; Version = '9.0'; Raw = ".slnx requires SDK 9.0+"; Source = 'slnx' }
            }

            $projFile = Get-ChildItem -Path $ModulePath -Filter '*.csproj' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $projFile) { $projFile = Get-ChildItem -Path $ModulePath -Filter '*.fsproj' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if (-not $projFile) { $projFile = Get-ChildItem -Path $ModulePath -Filter '*.vbproj' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if ($projFile) {
                $content = Get-Content $projFile.FullName -Raw
                if ($content -match '<TargetFramework>(net\d+\.\d+)</TargetFramework>') {
                    $tfm = $Matches[1]
                    if ($tfm -match 'net(\d+)\.(\d+)') {
                        return [pscustomobject]@{ SdkName = '.NET'; Version = "$($Matches[1]).$($Matches[2])"; Raw = "TargetFramework=$tfm (FALLBACK — may not reflect actual SDK needed)"; Source = 'targetframework' }
                    }
                }
            }
        }
        { $_ -in @('Node.js backend', 'Static frontend') } {
            $pkgPath = Join-Path -Path $ModulePath -ChildPath 'package.json'
            if (Test-Path $pkgPath) {
                try {
                    $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
                    if ($pkg.PSObject.Properties['engines'] -and $pkg.engines.PSObject.Properties['node']) {
                        $nodeVer = $pkg.engines.node
                        if ($nodeVer -match '(\d+)') {
                            return [pscustomobject]@{ SdkName = 'Node.js'; Version = "$($Matches[1]).x"; Raw = $nodeVer }
                        }
                    }
                } catch { <# Intentionally suppressed — package.json parse is best-effort #> $null = $_ }
            }
        }
        'Python' {
            $pvFile = Join-Path -Path $ModulePath -ChildPath '.python-version'
            if (Test-Path $pvFile) {
                $ver = (Get-Content $pvFile -Raw).Trim()
                if ($ver -match '(\d+)\.(\d+)') {
                    return [pscustomobject]@{ SdkName = 'Python'; Version = "$($Matches[1]).$($Matches[2])"; Raw = $ver }
                }
            }
            $pyproj = Join-Path -Path $ModulePath -ChildPath 'pyproject.toml'
            if (Test-Path $pyproj) {
                $content = Get-Content $pyproj -Raw
                if ($content -match 'python_requires\s*=\s*"[><=]*(\d+)\.(\d+)') {
                    return [pscustomobject]@{ SdkName = 'Python'; Version = "$($Matches[1]).$($Matches[2])"; Raw = $Matches[0] }
                }
            }
        }
        'Java' {
            $pomPath = Join-Path -Path $ModulePath -ChildPath 'pom.xml'
            if (Test-Path $pomPath) {
                $content = Get-Content $pomPath -Raw
                if ($content -match '<maven\.compiler\.source>(\d+)</maven\.compiler\.source>') {
                    return [pscustomobject]@{ SdkName = 'Java'; Version = $Matches[1]; Raw = "maven.compiler.source=$($Matches[1])" }
                }
            }
            $gradlePath = Join-Path -Path $ModulePath -ChildPath 'build.gradle'
            if (Test-Path $gradlePath) {
                $content = Get-Content $gradlePath -Raw
                if ($content -match "sourceCompatibility\s*=\s*'?(\d+)'?") {
                    return [pscustomobject]@{ SdkName = 'Java'; Version = $Matches[1]; Raw = "sourceCompatibility=$($Matches[1])" }
                }
            }
        }
        'Go' {
            $goMod = Join-Path -Path $ModulePath -ChildPath 'go.mod'
            if (Test-Path $goMod) {
                $content = Get-Content $goMod -Raw
                if ($content -match 'go\s+(\d+)\.(\d+)') {
                    return [pscustomobject]@{ SdkName = 'Go'; Version = "$($Matches[1]).$($Matches[2])"; Raw = "go $($Matches[1]).$($Matches[2])" }
                }
            }
        }
        'Rust' {
            $cargoPath = Join-Path -Path $ModulePath -ChildPath 'Cargo.toml'
            if (Test-Path $cargoPath) {
                $content = Get-Content $cargoPath -Raw
                if ($content -match 'rust-version\s*=\s*"(\d+)\.(\d+)"') {
                    return [pscustomobject]@{ SdkName = 'Rust'; Version = "$($Matches[1]).$($Matches[2])"; Raw = "rust-version=$($Matches[1]).$($Matches[2])" }
                }
            }
        }
    }

    return $null
}

# ════════════════════════════════════════════════════════════
#  Helper — extract TargetFramework version from .csproj/.fsproj/.vbproj
# ════════════════════════════════════════════════════════════

function Get-TargetFrameworkVersion {
    param([string]$AppType, [string]$ModulePath)

    if ($AppType -notin @('.NET', 'F#', 'VB.NET', 'Functions')) { return $null }

    $projFile = Get-ChildItem -Path $ModulePath -Filter '*.csproj' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $projFile) { $projFile = Get-ChildItem -Path $ModulePath -Filter '*.fsproj' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $projFile) { $projFile = Get-ChildItem -Path $ModulePath -Filter '*.vbproj' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $projFile) { return $null }

    $content = Get-Content $projFile.FullName -Raw
    if ($content -match '<TargetFramework>(net(\d+)\.(\d+))</TargetFramework>') {
        return [pscustomobject]@{
            Tfm     = $Matches[1]
            Major   = [int]$Matches[2]
            Minor   = [int]$Matches[3]
            Version = "$($Matches[2]).$($Matches[3])"
        }
    }
    return $null
}

# ════════════════════════════════════════════════════════════
#  Helper — detect pipeline TFM SDK install (UseDotNet with matching TFM version)
# ════════════════════════════════════════════════════════════

function Get-PipelineRuntimeVersion {
    param(
        [string]$PipelineContent,
        [string]$TfmVersion = $null
    )

    if ($TfmVersion) {
        $escaped = [regex]::Escape($TfmVersion)
        if ($PipelineContent -match "UseDotNet@2[\s\S]*?version:\s*['""""']?${escaped}") {
            return $TfmVersion
        }
        return $null
    }

    if ($PipelineContent -match "packageType:\s*['""""']?(?:sdk|runtime)['""""']?\s*\n\s*version:\s*['""""']?(\d+\.\d+)") {
        return $Matches[1]
    }
    if ($PipelineContent -match "version:\s*['""""']?(\d+\.\d+)[^\n]*\n[^#\n]*packageType:\s*['""""']?(?:sdk|runtime)") {
        return $Matches[1]
    }
    return $null
}

# ════════════════════════════════════════════════════════════
#  Helper — detect pipeline SDK version from YAML content
# ════════════════════════════════════════════════════════════

function Get-PipelineSdkVersion {
    param([string]$SdkName, [string]$PipelineContent)

    switch ($SdkName) {
        '.NET' {
            if ($PipelineContent -match 'UseDotNet@\d+[\s\S]*?version:\s*[''"]?(\d+\.\d+)') {
                return $Matches[1]
            }
        }
        'Node.js' {
            if ($PipelineContent -match 'NodeTool@\d+[\s\S]*?versionSpec:\s*[''"]?(\d+)') {
                return "$($Matches[1]).x"
            }
        }
        'Python' {
            if ($PipelineContent -match 'UsePythonVersion@\d+[\s\S]*?versionSpec:\s*[''"]?(\d+\.\d+)') {
                return $Matches[1]
            }
        }
        'Java' {
            if ($PipelineContent -match 'JavaToolInstaller@\d+[\s\S]*?versionSpec:\s*[''"]?(\d+)') {
                return $Matches[1]
            }
        }
        'Go' {
            if ($PipelineContent -match 'GoTool@\d+[\s\S]*?version:\s*[''"]?(\d+\.\d+)') {
                return $Matches[1]
            }
        }
        'Rust' {
            if ($PipelineContent -match 'rustup\s+default\s+(\d+\.\d+)') {
                return $Matches[1]
            }
        }
    }
    return $null
}

# ════════════════════════════════════════════════════════════
#  Helper — required files for push per AppType
# ════════════════════════════════════════════════════════════

function Get-RequiredFiles {
    <# Returns required files for an app type from deploy-config.json.
       Delegates to the centralized Get-AppType engine instead of maintaining
       a hardcoded switch table. Falls back to empty array if config unavailable. #>
    param([string]$AppType, [string]$ModulePath)

    if ((Get-Command Get-AppType -ErrorAction SilentlyContinue) -and $ModulePath) {
        $detection = Get-AppType -Path $ModulePath -WorkspacePath $script:WorkspacePath
        if ($detection -and $detection.ConfigFiles) {
            return @($detection.ConfigFiles)
        }
    }

    # Fallback: read config directly by app type name
    try {
        $cfg = Get-DeployConfig
        if ($cfg.appTypes) {
            $entry = $cfg.appTypes | Where-Object { $_.name -eq $AppType } | Select-Object -First 1
            if ($entry -and $entry.configFiles) { return @($entry.configFiles) }
        }
    } catch { $null = $_ }

    return @()
}

# ════════════════════════════════════════════════════════════
#  BR-00 — Three-Tier Build Probe (Buildability Gate)
#  Sole authority for determining module buildability.
#  Cascade: Tier 1 fail → skip Tier 2 & 3; Tier 2 fail → skip Tier 3.
# ════════════════════════════════════════════════════════════

function Test-ModuleBuildability {
    param(
        [Parameter(Mandatory)][string]$AppType,
        [Parameter(Mandatory)][string]$ModulePath
    )

    $result = [ordered]@{
        buildability = [ordered]@{
            status            = 'unknown'
            tier1_toolchain   = 'unknown'
            tier2_sdkCompat   = 'unknown'
            tier3_restore     = 'unknown'
            failReason        = $null
            sdkVersionInstalled = $null
            sdkVersionRequired  = $null
            probeTimeSeconds  = 0
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # ── Tier 1 — Toolchain Presence ──────────────────────────
    $tier1Cmd = switch ($AppType) {
        { $_ -in @('.NET', 'F#', 'VB.NET', 'Functions') } { 'dotnet --version' }
        { $_ -in @('Node.js backend', 'Static frontend') }  { 'node --version' }
        'Python'           { 'python --version' }
        'Java'             { 'java --version' }
        'Go'               { 'go version' }
        'Rust'             { 'rustc --version' }
        'Container'        { 'docker info' }
        'Static website'   { $null }
        default            { $null }
    }

    if (-not $tier1Cmd) {
        # No toolchain needed (e.g., Static website) — pass all tiers
        $result.buildability.tier1_toolchain = 'pass'
        $result.buildability.tier2_sdkCompat = 'pass'
        $result.buildability.tier3_restore   = 'pass'
        $result.buildability.status          = 'pass'
        $sw.Stop()
        $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $result
    }

    try {
        # Python fallback: try python3 --version if python --version fails
        if ($AppType -eq 'Python') {
            try {
                $null = & python --version 2>&1
                if ($LASTEXITCODE -ne 0) { throw 'python failed' }
            } catch {
                $null = & python3 --version 2>&1
                if ($LASTEXITCODE -ne 0) { throw 'python3 failed' }
            }
        } else {
            $cmdParts = $tier1Cmd -split ' ', 2
            $null = & $cmdParts[0] $cmdParts[1] 2>&1
            if ($LASTEXITCODE -ne 0) { throw "$($cmdParts[0]) exited with code $LASTEXITCODE" }
        }
        $result.buildability.tier1_toolchain = 'pass'
    } catch {
        # Tier 1 toolchain fail — cascade: skip Tier 2 & 3
        $result.buildability.tier1_toolchain = 'fail'
        $result.buildability.status    = 'fail'
        $result.buildability.failReason = "Toolchain not installed: $tier1Cmd"
        $sw.Stop()
        $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $result
    }

    # ── Tier 2 — SDK Version Compatibility ───────────────────
    $localSdk = Get-LocalSdkVersion -AppType $AppType -ModulePath $ModulePath
    if ($localSdk) {
        $result.buildability.sdkVersionInstalled = $localSdk.Version
        $result.buildability.sdkVersionRequired  = $localSdk.Raw

        # Check .slnx requires SDK 9.0+ for .NET
        $slnxFiles = Get-ChildItem -Path $ModulePath -Filter '*.slnx' -Depth 1 -ErrorAction SilentlyContinue
        if ($slnxFiles -and $localSdk.SdkName -eq '.NET') {
            if ($localSdk.Version -match '^(\d+)' -and [int]$Matches[1] -lt 9) {
                $result.buildability.tier2_sdkCompat = 'fail'
                $result.buildability.status    = 'fail'
                $result.buildability.failReason = "SDK version mismatch: installed $($localSdk.Version), .slnx requires SDK 9.0+"
                $sw.Stop()
                $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                return $result
            }
        }

        # Check global.json pin
        $globalJsonPath = Join-Path -Path $ModulePath -ChildPath 'global.json'
        if (Test-Path $globalJsonPath) {
            try {
                $gj = Get-Content $globalJsonPath -Raw | ConvertFrom-Json
                if ($gj.sdk -and $gj.sdk.version) {
                    $result.buildability.sdkVersionRequired = $gj.sdk.version
                    $reqMajor = if ($gj.sdk.version -match '^(\d+)') { [int]$Matches[1] } else { -1 }
                    $instMajor = if ($localSdk.Version -match '^(\d+)') { [int]$Matches[1] } else { -1 }
                    if ($reqMajor -gt 0 -and $instMajor -gt 0 -and $instMajor -lt $reqMajor) {
                        $result.buildability.tier2_sdkCompat = 'fail'
                        $result.buildability.status    = 'fail'
                        $result.buildability.failReason = "SDK version mismatch: installed $($localSdk.Version), required $($gj.sdk.version)"
                        $sw.Stop()
                        $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                        return $result
                    }
                }
            } catch { $null = $_  <# global.json parse failed — treat as unknown #> }
        }

        # Check TargetFramework compatibility (fallback)
        $tfmInfo = Get-TargetFrameworkVersion -AppType $AppType -ModulePath $ModulePath
        if ($tfmInfo -and $localSdk.SdkName -eq '.NET') {
            $instMajor = if ($localSdk.Version -match '^(\d+)') { [int]$Matches[1] } else { -1 }
            if ($instMajor -gt 0 -and $instMajor -lt $tfmInfo.Major) {
                $result.buildability.tier2_sdkCompat = 'fail'
                $result.buildability.status    = 'fail'
                $result.buildability.failReason = "SDK version mismatch: installed $($localSdk.Version), TargetFramework requires $($tfmInfo.Version)+"
                $sw.Stop()
                $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                return $result
            }
        }

        $result.buildability.tier2_sdkCompat = 'pass'
    } else {
        # SDK version not detectable — treat as unknown (graceful degradation)
        $result.buildability.tier2_sdkCompat = 'unknown'
    }

    # ── Tier 3 — Restore Probe ───────────────────────────────
    $tier3Cmd = switch ($AppType) {
        { $_ -in @('.NET', 'F#', 'VB.NET', 'Functions') } { 'dotnet restore' }
        { $_ -in @('Node.js backend', 'Static frontend') }  { 'npm install --package-lock-only' }
        'Python'           { 'pip install --dry-run -r requirements.txt' }
        'Java'             { 'mvn validate -q' }
        'Go'               { 'go vet ./...' }
        'Rust'             { 'cargo check' }
        'Container'        { $null }  # Dockerfile syntax only
        'Static website'   { $null }
        default            { $null }
    }

    if (-not $tier3Cmd) {
        # No restore needed — pass
        $result.buildability.tier3_restore = 'pass'
        $result.buildability.status = if ($result.buildability.tier2_sdkCompat -eq 'unknown') { 'unknown' } else { 'pass' }
        $sw.Stop()
        $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $result
    }

    try {
        $restoreResult = Invoke-ModuleCommand -Command $tier3Cmd -ModulePath $ModulePath
        if ($restoreResult.ExitCode -eq 0) {
            $result.buildability.tier3_restore = 'pass'
            $result.buildability.status = if ($result.buildability.tier2_sdkCompat -eq 'unknown') { 'unknown' } else { 'pass' }
        } else {
            $firstError = ($restoreResult.Stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if (-not $firstError) { $firstError = 'Restore probe failed — see output' }
            $result.buildability.tier3_restore = 'fail'
            $result.buildability.status    = 'fail'
            $result.buildability.failReason = $firstError
        }
    } catch {
        $result.buildability.tier3_restore = 'unknown'
        $result.buildability.status = 'unknown'
        $result.buildability.failReason = "Restore probe timed out or errored: $_"
    }

    $sw.Stop()
    $result.buildability.probeTimeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    return $result
}

# ── Guard: skip setup & main when dot-sourced (tests only need functions) ──
if ($MyInvocation.InvocationName -eq '.') { return }

# ── Load shared helpers ─────────────────────────────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

# ── Load centralized app type detection engine ──────────────
$script:WorkspacePath = $WorkspacePath
$detectScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-app-type-select', 'scripts', 'Invoke-AppTypeDetect.ps1'
if (-not (Test-Path $detectScript) -and $PSScriptRoot) {
    $detectScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\deploy-app-type-select\scripts\Invoke-AppTypeDetect.ps1'
}
if (Test-Path $detectScript) { . $detectScript }
# Restore ErrorActionPreference after dot-sourcing (Invoke-AppTypeDetect sets 'Stop')
$ErrorActionPreference = 'Continue'

# ── Resolve workspace ──────────────────────────────────────
$WorkspacePath = (Resolve-Path $WorkspacePath -ErrorAction Stop).Path

# ── Resolve manifest path ──────────────────────────────────
if (-not $ManifestPath) {
    $ManifestPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'workspace-manifest.json'
}
if (-not (Test-Path $ManifestPath)) {
    Write-Error "Workspace manifest not found at $ManifestPath. Run Invoke-WorkspaceAnalysis.ps1 first."
    $global:LASTEXITCODE = 1
    exit 1
}

# ── Resolve pipeline path ──────────────────────────────────
if (-not $PipelineYmlPath) {
    $PipelineYmlPath = Join-Path -Path $WorkspacePath -ChildPath (Get-PipelineYamlRelPath)
} elseif (-not [System.IO.Path]::IsPathRooted($PipelineYmlPath)) {
    $PipelineYmlPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
}

# ── Load manifest ──────────────────────────────────────────
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

if (-not $manifest.modules -or $manifest.modules.Count -eq 0) {
    Write-Error "Manifest contains no modules. Re-run Invoke-WorkspaceAnalysis.ps1."
    $global:LASTEXITCODE = 1
    exit 1
}

# ════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════

Write-Output ""
Write-Output "════════════════════════════════════════════════════════════"
Write-Output "  VibeShield-Deploy Build & Deploy Readiness"
Write-Output "  Workspace: $WorkspacePath"
Write-Output "  Modules:   $($manifest.modules.Count)"
Write-Output "════════════════════════════════════════════════════════════"
Write-Output ""

# Load pipeline content once
$pipelineContent = $null
if (Test-Path $PipelineYmlPath) {
    $pipelineContent = (Get-Content $PipelineYmlPath -Raw) -replace "`r`n", "`n"  # Normalize line endings
}

# Track per-module results for BR-05
$moduleStatus = @{}

foreach ($mod in $manifest.modules) {
    $modPath = if ($mod.path -eq '.') { $WorkspacePath } else { Join-Path -Path $WorkspacePath -ChildPath $mod.path }
    $modLabel = "$($mod.path) ($($mod.appType))"
    $moduleStatus[$mod.path] = @{ Build = $false; Tests = $false; Sdk = $false; Stages = $false; Files = $false }

    Write-Output "── Module: $modLabel ────────────────────────"

    $cmds = Get-BuildTestCommands -AppType $mod.appType -ModulePath $modPath

    # ── BR-01: Local Build ──────────────────────────────────
    if ($SkipBuild) {
        Add-Result -Id 'BR-01' -Status SKIP -Message "[$modLabel] Build skipped (--SkipBuild)"
        $moduleStatus[$mod.path].Build = $true  # treat skip as non-blocking
    } elseif (-not $cmds.BuildCmd) {
        Add-Result -Id 'BR-01' -Status SKIP -Message "[$modLabel] No build step required"
        $moduleStatus[$mod.path].Build = $true
    } else {
        $buildResult = Invoke-ModuleCommand -Command $cmds.BuildCmd -ModulePath $modPath
        if ($buildResult.ExitCode -eq 0) {
            Add-Result -Id 'BR-01' -Status PASS -Message "[$modLabel] Build succeeded ($($cmds.BuildCmd))"
            $moduleStatus[$mod.path].Build = $true
        } else {
            $firstError = ($buildResult.Stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if (-not $firstError) { $firstError = ($buildResult.Stdout -split "`n" | Where-Object { $_ -match 'error|Error|ERROR' } | Select-Object -First 1) }
            if (-not $firstError) { $firstError = 'No error details captured' }
            Add-Result -Id 'BR-01' -Status FAIL `
                -Message "[$modLabel] Build failed" `
                -Fix "Error: $firstError"
        }
    }

    # ── BR-02: Local Tests (cascading gate: skip if build failed) ──
    $hasTests = $mod.tests -and $mod.tests.unit
    if (-not $moduleStatus[$mod.path].Build) {
        # Cascading gate: build failed → skip tests
        Add-Result -Id 'BR-02' -Status SKIP -Message "[$modLabel] Tests skipped — build failed (BR-01)"
    } elseif ($SkipTests) {
        Add-Result -Id 'BR-02' -Status SKIP -Message "[$modLabel] Tests skipped (--SkipTests)"
        $moduleStatus[$mod.path].Tests = $true
    } elseif (-not $hasTests) {
        Add-Result -Id 'BR-02' -Status SKIP -Message "[$modLabel] No tests detected"
        $moduleStatus[$mod.path].Tests = $true
    } elseif (-not $cmds.TestCmd) {
        Add-Result -Id 'BR-02' -Status SKIP -Message "[$modLabel] No test command for $($mod.appType)"
        $moduleStatus[$mod.path].Tests = $true
    } else {
        $testResult = Invoke-ModuleCommand -Command $cmds.TestCmd -ModulePath $modPath
        if ($testResult.ExitCode -eq 0) {
            Add-Result -Id 'BR-02' -Status PASS -Message "[$modLabel] Tests passed ($($cmds.TestCmd))"
            $moduleStatus[$mod.path].Tests = $true
        } else {
            $firstFailure = ($testResult.Stdout -split "`n" | Where-Object { $_ -match 'fail|FAIL|Failed' } | Select-Object -First 1)
            if (-not $firstFailure) { $firstFailure = 'See test output for details' }
            Add-Result -Id 'BR-02' -Status FAIL `
                -Message "[$modLabel] Tests failed" `
                -Fix "First failure: $firstFailure"
        }
    }

    # ── BR-03: SDK Alignment ────────────────────────────────
    if (-not $pipelineContent) {
        Add-Result -Id 'BR-03' -Status SKIP -Message "[$modLabel] No pipeline YAML — cannot validate SDK"
        $moduleStatus[$mod.path].Sdk = $true  # non-blocking when no pipeline
    } else {
        $localSdk = Get-LocalSdkVersion -AppType $mod.appType -ModulePath $modPath
        if (-not $localSdk) {
            Add-Result -Id 'BR-03' -Status SKIP -Message "[$modLabel] SDK version not detectable from project files"
            $moduleStatus[$mod.path].Sdk = $true
        } else {
            $pipelineSdk = Get-PipelineSdkVersion -SdkName $localSdk.SdkName -PipelineContent $pipelineContent
            if (-not $pipelineSdk) {
                Add-Result -Id 'BR-03' -Status WARN `
                    -Message "[$modLabel] Local $($localSdk.SdkName) $($localSdk.Version) — no SDK setup task found in pipeline" `
                    -Fix "Add a $($localSdk.SdkName) version setup task to the pipeline Build stage"
            } elseif ($pipelineSdk -like "$($localSdk.Version)*" -or $localSdk.Version -like "$pipelineSdk*") {
                Add-Result -Id 'BR-03' -Status PASS -Message "[$modLabel] $($localSdk.SdkName) $($localSdk.Version) matches pipeline ($pipelineSdk)"
                $moduleStatus[$mod.path].Sdk = $true
            } else {
                Add-Result -Id 'BR-03' -Status WARN `
                    -Message "[$modLabel] SDK mismatch — local: $($localSdk.SdkName) $($localSdk.Version), pipeline: $pipelineSdk" `
                    -Fix "Update the pipeline SDK version task to match local version ($($localSdk.Version))"
            }
        }
    }

    # ── BR-03b: SDK vs TargetFramework Runtime Mismatch ─────
    if ($pipelineContent -and $localSdk -and $localSdk.SdkName -eq '.NET') {
        $tfmInfo = Get-TargetFrameworkVersion -AppType $mod.appType -ModulePath $modPath
        if ($tfmInfo) {
            $sdkMajor = if ($localSdk.Version -match '^(\d+)') { [int]$Matches[1] } else { -1 }
            $tfmMajor = $tfmInfo.Major
            if ($sdkMajor -ne $tfmMajor -and $sdkMajor -gt 0) {
                # SDK and TFM majors differ — pipeline needs runtime for TFM
                $pipelineRuntime = Get-PipelineRuntimeVersion -PipelineContent $pipelineContent -TfmVersion $tfmInfo.Version
                if ($pipelineRuntime) {
                    Add-Result -Id 'BR-03b' -Status PASS `
                        -Message "[$modLabel] SDK $($localSdk.Version) differs from TargetFramework $($tfmInfo.Tfm) — pipeline installs $($tfmInfo.Tfm) SDK ($pipelineRuntime) for ASP.NET Core runtime"
                } else {
                    Add-Result -Id 'BR-03b' -Status WARN `
                        -Message "[$modLabel] SDK $($localSdk.Version) differs from TargetFramework $($tfmInfo.Tfm) — pipeline missing TFM SDK install for $($tfmInfo.Tfm)" `
                        -Fix "Add a UseDotNet@2 with packageType 'sdk' and version '$($tfmInfo.Version).x' BEFORE the build SDK step (do NOT use 'runtime' — it misses Microsoft.AspNetCore.App)"
                }
            } else {
                Add-Result -Id 'BR-03b' -Status PASS `
                    -Message "[$modLabel] SDK and TargetFramework majors match ($sdkMajor) — no extra runtime needed"
            }
        }
    }

    # ── BR-04: Pipeline Stage Completeness ──────────────────
    if (-not $pipelineContent) {
        Add-Result -Id 'BR-04' -Status FAIL `
            -Message "[$modLabel] No pipeline YAML found — cannot verify stages" `
            -Fix "Run vibeshield-deploy-pipeline-author to generate the pipeline YAML first"
    } else {
        $hasBuild  = $mod.pipelineStages -and $mod.pipelineStages.build
        $hasDeploy = $mod.pipelineStages -and $mod.pipelineStages.deploy
        if ($hasBuild -and $hasDeploy) {
            Add-Result -Id 'BR-04' -Status PASS -Message "[$modLabel] Build and Deploy stages present"
            $moduleStatus[$mod.path].Stages = $true
        } else {
            $missing = @()
            if (-not $hasBuild)  { $missing += 'Build' }
            if (-not $hasDeploy) { $missing += 'Deploy' }
            Add-Result -Id 'BR-04' -Status FAIL `
                -Message "[$modLabel] Missing pipeline stages: $($missing -join ', ')" `
                -Fix "Add the missing stages to the pipeline YAML for module '$($mod.path)'"
        }
    }

    # ── BR-05: Required files check ─────────────────────────
    $requiredFiles = @(Get-RequiredFiles -AppType $mod.appType -ModulePath $modPath)
    if ($requiredFiles.Count -eq 0) {
        $moduleStatus[$mod.path].Files = $true
    } else {
        $found = $false
        foreach ($pattern in $requiredFiles) {
            if (Get-ChildItem -Path $modPath -Filter $pattern -Depth 0 -ErrorAction SilentlyContinue) {
                $found = $true
                break
            }
        }
        $moduleStatus[$mod.path].Files = $found
    }
    Write-Output ""
}

# ── BR-05: Composite Deployability ─────────────────────────
# Minimum guarantee: module builds successfully (BR-01).
# Test failure (BR-02) does NOT block deployment — test steps are omitted from the pipeline instead.
Write-Output "── Deployability Assessment ────────────────────────"
$allDeployable = $true
foreach ($mod in $manifest.modules) {
    $ms = $moduleStatus[$mod.path]
    $modLabel = "$($mod.path) ($($mod.appType))"
    # Deployability requires: build + stages + files. Tests are advisory.
    $isDeployable = $ms.Build -and $ms.Stages -and $ms.Files
    if ($isDeployable) {
        if ($ms.Tests) {
            Add-Result -Id 'BR-05' -Status PASS -Message "[$modLabel] Deployable — build, tests, pipeline stages, and required files all verified"
        } else {
            Add-Result -Id 'BR-05' -Status WARN `
                -Message "[$modLabel] Deployable (tests excluded) — build passed but tests failed; test steps will be omitted from the pipeline" `
                -Fix 'Fix failing tests to restore test coverage in the pipeline'
        }
    } else {
        $gaps = @()
        if (-not $ms.Build)  { $gaps += 'build failed (BR-01)' }
        if (-not $ms.Stages) { $gaps += 'pipeline stages missing (BR-04)' }
        if (-not $ms.Files)  { $gaps += 'required project files missing' }
        Add-Result -Id 'BR-05' -Status FAIL `
            -Message "[$modLabel] Not deployable" `
            -Fix "Blocked by: $($gaps -join '; ')"
        $allDeployable = $false
    }
}
Write-Output ""

# ── BR-06: Bicep Coverage ──────────────────────────────────
# For EV2: check ev2/ServiceGroupRoot/Templates/ first (legacy ARM path).
# If present, treat as covered. If absent, fall through to Bicep check.
# For ARM: always check Bicep.
Write-Output "── Bicep Coverage ────────────────────────────────────"
$ev2LegacyCovered = $false
if ($InfraDeployMethod -eq 'EV2') {
    $ev2TemplatesDir = Join-Path -Path $WorkspacePath -ChildPath 'ev2' -AdditionalChildPath 'ServiceGroupRoot', 'Templates'
    if (Test-Path $ev2TemplatesDir) {
        $armFiles = Get-ChildItem -Path $ev2TemplatesDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
        if ($armFiles.Count -gt 0) {
            $ev2LegacyCovered = $true
            Add-Result -Id 'BR-06' -Status PASS `
                -Message "EV2 deployment — ARM templates found in ev2/ServiceGroupRoot/Templates/ ($($armFiles.Count) file(s)). Bicep not required for legacy EV2 projects."
        }
    }
}
if (-not $ev2LegacyCovered) {
    if ($manifest.bicep.exists) {
        if ($manifest.bicep.coversAllModules) {
            Add-Result -Id 'BR-06' -Status PASS `
                -Message "Bicep at '$($manifest.bicep.path)' covers all $($manifest.modules.Count) modules"
        } else {
            $gapCount = if ($manifest.bicep.gaps) { $manifest.bicep.gaps.Count } else { 0 }
            $gapList  = if ($manifest.bicep.gaps) { ($manifest.bicep.gaps -join ', ') } else { 'unknown' }
            Add-Result -Id 'BR-06' -Status FAIL `
                -Message "Bicep at '$($manifest.bicep.path)' has gaps — missing infrastructure for $gapCount module(s): $gapList" `
                -Fix "Delegate to vibeshield-bicep to extend existing Bicep for missing modules — all selected installable modules must have infrastructure definitions"
        }
    } else {
        Add-Result -Id 'BR-06' -Status WARN `
            -Message "No Bicep found — all selected installable modules need infrastructure definitions" `
            -Fix "Delegate to vibeshield-bicep to generate infra/main.bicep covering all selected modules"
    }
}
Write-Output ""

# ── BR-07: Startup Smoke Test (IL-4) ──────────────────────
# For Node.js modules: start the server, wait, probe health endpoint, kill
Write-Output "── Startup Smoke Test ─────────────────────────────────"
if ($SkipBuild) {
    Add-Result -Id 'BR-07' -Status SKIP -Message "Startup test skipped (--SkipBuild)"
} else {
    $nodeModules = @($manifest.modules | Where-Object { $_.appType -eq 'Node.js backend' })
    if ($nodeModules.Count -eq 0) {
        Add-Result -Id 'BR-07' -Status SKIP -Message "No Node.js modules — startup test not applicable"
    } else {
        foreach ($mod in $nodeModules) {
            $modPath = if ($mod.path -eq '.') { $WorkspacePath } else { Join-Path -Path $WorkspacePath -ChildPath $mod.path }
            $modLabel = "$($mod.path) ($($mod.appType))"
            $pkgPath = Join-Path -Path $modPath -ChildPath 'package.json'
            $entryPoint = $null

            if (Test-Path $pkgPath) {
                try {
                    $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($pkg.PSObject.Properties['main']) { $entryPoint = $pkg.main }
                    elseif ($pkg.scripts -and $pkg.scripts.PSObject.Properties['start']) {
                        $startScript = $pkg.scripts.start
                        if ($startScript -match '(?:node|nodemon|ts-node|tsx)\s+(.+?)(?:\s|$)') { $entryPoint = $Matches[1].Trim() }
                    }
                } catch { $null = $_ }
            }
            if (-not $entryPoint) {
                foreach ($c in @('index.js', 'server.js', 'app.js')) {
                    if (Test-Path (Join-Path -Path $modPath -ChildPath $c)) { $entryPoint = $c; break }
                }
            }

            if (-not $entryPoint -or -not (Test-Path (Join-Path -Path $modPath -ChildPath $entryPoint))) {
                Add-Result -Id 'BR-07' -Status WARN `
                    -Message "[$modLabel] Cannot determine entry point — skipping startup test" `
                    -Fix "Set 'main' or 'scripts.start' in package.json"
                continue
            }

            # Attempt to start and probe
            $port = 19876 + (Get-Random -Maximum 100)
            $env:PORT = $port
            $env:NODE_ENV = 'production'
            $proc = $null
            $_tempDir = [IO.Path]::GetTempPath()
            try {
                $proc = Start-Process -FilePath 'node' -ArgumentList $entryPoint `
                    -WorkingDirectory $modPath -PassThru -NoNewWindow `
                    -RedirectStandardOutput (Join-Path -Path $_tempDir -ChildPath 'br07-stdout.txt') `
                    -RedirectStandardError (Join-Path -Path $_tempDir -ChildPath 'br07-stderr.txt') `
                    -ErrorAction Stop

                # Wait up to 8 seconds for startup
                $probeOk = $false
                for ($i = 0; $i -lt 8; $i++) {
                    Start-Sleep -Seconds 1
                    if ($proc.HasExited) { break }
                    try {
                        $resp = Invoke-WebRequest -Uri "http://localhost:$port/" -TimeoutSec 2 -UseBasicParsing -ErrorAction SilentlyContinue
                        if ($resp.StatusCode -lt 500) { $probeOk = $true; break }
                    } catch { $null = $_ }
                }

                if ($proc.HasExited -and $proc.ExitCode -ne 0) {
                    $stderr = Get-Content (Join-Path -Path $_tempDir -ChildPath 'br07-stderr.txt') -Raw -ErrorAction SilentlyContinue
                    $errorSnippet = if ($stderr) { ($stderr -split "`n" | Select-Object -First 3) -join '; ' } else { 'unknown error' }
                    Add-Result -Id 'BR-07' -Status FAIL `
                        -Message "[$modLabel] Server crashed on startup (exit code $($proc.ExitCode)): $errorSnippet" `
                        -Fix "Fix the startup error before deploying. Common causes: missing env vars, eager SDK init without API keys, module not found."
                    $allDeployable = $false
                } elseif ($probeOk) {
                    Add-Result -Id 'BR-07' -Status PASS -Message "[$modLabel] Server started and responded on port $port"
                } else {
                    Add-Result -Id 'BR-07' -Status WARN `
                        -Message "[$modLabel] Server started but did not respond within 8 seconds on port $port" `
                        -Fix "Check if the server listens on the PORT environment variable. Ensure health endpoint exists."
                }
            } catch {
                Add-Result -Id 'BR-07' -Status WARN `
                    -Message "[$modLabel] Could not start server for smoke test: $($_.Exception.Message)" `
                    -Fix "Ensure 'node' is installed and the entry point is valid."
            } finally {
                if ($proc -and -not $proc.HasExited) {
                    $proc.Kill()
                    $proc.WaitForExit(3000)
                }
                Remove-Item (Join-Path -Path $_tempDir -ChildPath 'br07-stdout.txt') -ErrorAction SilentlyContinue
                Remove-Item (Join-Path -Path $_tempDir -ChildPath 'br07-stderr.txt') -ErrorAction SilentlyContinue
            }
        }
    }
}
Write-Output ""

# ════════════════════════════════════════════════════════════
# Structured JSON Output
# ════════════════════════════════════════════════════════════

$checkSummary = @{}
foreach ($checkId in @('BR-01','BR-02','BR-03','BR-04','BR-05','BR-06','BR-07')) {
    $checkResults = $script:Results | Where-Object { $_.Id -eq $checkId }
    $worstStatus = 'PASS'
    $moduleResults = @{}
    foreach ($cr in $checkResults) {
        # Extract module path from message
        if ($cr.Message -match '^\[([^\]]+)\]') {
            $moduleResults[$Matches[1]] = $cr.Status
        }
        if ($cr.Status -eq 'FAIL') { $worstStatus = 'FAIL' }
        elseif ($cr.Status -eq 'WARN' -and $worstStatus -ne 'FAIL') { $worstStatus = 'WARN' }
    }
    $checkSummary[$checkId] = [ordered]@{ status = $worstStatus; moduleResults = $moduleResults }
}

$blockers = @()
$testWarnings = @()
foreach ($mod in $manifest.modules) {
    $ms = $moduleStatus[$mod.path]
    if (-not ($ms.Build -and $ms.Stages -and $ms.Files)) {
        $gaps = @()
        if (-not $ms.Build)  { $gaps += 'build failed' }
        if (-not $ms.Stages) { $gaps += 'missing pipeline stages' }
        if (-not $ms.Files)  { $gaps += 'missing required files' }
        $blockers += [ordered]@{ module = $mod.path; reason = ($gaps -join '; ') }
    }
    if (-not $ms.Tests -and $ms.Build) {
        $testWarnings += [ordered]@{ module = $mod.path; reason = 'tests failed — test steps will be omitted from pipeline' }
    }
}

$readinessReport = [ordered]@{
    checks             = $checkSummary
    allModulesDeployable = $allDeployable
    blockers           = $blockers
    testWarnings       = $testWarnings
}

# Write readiness report alongside manifest
$reportPath = Join-Path -Path (Split-Path -Path $ManifestPath -Parent) -ChildPath 'build-readiness-report.json'
$reportDir  = Split-Path -Path $reportPath -Parent
if ($reportDir -and -not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
$readinessReport | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8

# ════════════════════════════════════════════════════════════
# SARIF Output
# ════════════════════════════════════════════════════════════
if (-not $SarifPath) {
    $SarifPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'build-readiness-results.sarif'
}
if (Get-Command Initialize-SarifCleanStart -ErrorAction SilentlyContinue) {
    Initialize-SarifCleanStart -SarifPath $SarifPath
}

$sarifRules   = [System.Collections.ArrayList]::new()
$sarifResults = [System.Collections.ArrayList]::new()

foreach ($r in $script:Results) {
    $level = switch ($r.Status) {
        'FAIL' { 'error' }
        'WARN' { 'warning' }
        'PASS' { 'note' }
        'SKIP' { 'none' }
    }

    $ruleId = "build-readiness/$($r.Id)"

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

$total   = $script:Results.Count
$passed  = @($script:Results | Where-Object Status -eq 'PASS').Count
$failed  = @($script:Results | Where-Object Status -eq 'FAIL').Count
$warned  = @($script:Results | Where-Object Status -eq 'WARN').Count
$skipped = @($script:Results | Where-Object Status -eq 'SKIP').Count

$sarifDoc = [ordered]@{
    '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json'
    version   = '2.1.0'
    runs      = @(
        [ordered]@{
            tool = [ordered]@{
                driver = [ordered]@{
                    name           = 'VibeShield-Deploy Build Readiness'
                    version        = '1.0.0'
                    informationUri = (Get-DeployConfig).ado.sourceRepoUrl
                    rules          = @($sarifRules)
                }
            }
            results     = @($sarifResults)
            invocations = @(
                [ordered]@{
                    executionSuccessful = ($script:ExitCode -eq 0)
                    properties = [ordered]@{
                        total   = $total
                        passed  = $passed
                        failed  = $failed
                        warned  = $warned
                        skipped = $skipped
                    }
                }
            )
            properties = [ordered]@{
                total   = $total
                passed  = $passed
                failed  = $failed
                warned  = $warned
                skipped = $skipped
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

# ════════════════════════════════════════════════════════════
# Terminal Summary
# ════════════════════════════════════════════════════════════
Write-Output "════════════════════════════════════════════════════════════"
Write-Output "  Build & Deploy Readiness Summary"
Write-Output "  Total: $total  |  Passed: $passed  |  Failed: $failed  |  Warnings: $warned  |  Skipped: $skipped"
Write-Output "════════════════════════════════════════════════════════════"

$failures = @($script:Results | Where-Object Status -eq 'FAIL')
if ($failures.Count -gt 0) {
    Write-Output ""
    Write-Output "  ACTIONS REQUIRED ($($failures.Count) failure(s)):"
    Write-Output ""
    $i = 1
    foreach ($f in $failures) {
        Write-Output "    $i. $($f.Id): $($f.Name) — $($f.Message)"
        if ($f.Fix) { Write-Output "       Fix: $($f.Fix)" }
        $i++
    }
}

Write-Output ""
Write-Output "  Readiness report: $reportPath"
Write-Output "  SARIF report: $SarifPath"
Write-Output ""

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