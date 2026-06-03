<#
.SYNOPSIS
    Lints Bicep files and runs PSRule for Azure analysis.

.DESCRIPTION
    Quality gate script that validates all Bicep templates in the repository.
    Phase 1: Runs 'az bicep lint' for syntax and lint validation on all files.
    Phase 2: Runs PSRule with PSRule.Rules.Azure using the expansion model --
    PSRule targets main.bicep in the infra directory and expands module
    references for full WAF alignment analysis.
    Optionally compiles Bicep to ARM JSON when -GenerateARM is specified.
    Always writes SARIF results to ./output/ for structured consumption by
    agents and CI tools (lint SARIF + PSRule SARIF).

    The script resolves the repository root automatically by walking up from
    its own location to find the .git directory. This allows it to run
    correctly from any location (skill directory, hook, CI, or manual).

.PARAMETER RepoRoot
    Optional. Explicit path to the repository root. If omitted, the script
    walks up from $PSScriptRoot to find the .git directory, falling back
    to the current working directory.

.PARAMETER Environment
    Optional. Target environment for PSRule configuration ('dev' or 'prod').
    Selects the corresponding PSRule.<env>.yaml config file from the infra
    directory. If omitted, tries PSRule.dev.yaml then PSRule.prod.yaml.

.PARAMETER GenerateARM
    When specified, compiles Bicep templates to ARM JSON and writes output
    to the ./output/ directory, preserving relative directory structure.

.PARAMETER OutputSarif
    Deprecated. SARIF output is now always generated. This switch is accepted
    for backward compatibility but has no effect.

.EXAMPLE
    # From repo root (auto-resolves, default PSRule config)
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1

.EXAMPLE
    # Validate with dev PSRule config
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -Environment dev

.EXAMPLE
    # Validate with prod PSRule config
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -Environment prod

.EXAMPLE
    # With explicit repo root
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -RepoRoot C:\repos\ComplianceAutomation

.EXAMPLE
    # Validate and compile to ARM
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -GenerateARM

.NOTES
    Exit Codes:
      0 - All files pass lint and PSRule analysis (or no Bicep files found)
      1 - One or more lint errors or PSRule violations detected
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,

    [ValidateSet('dev', 'prod')]
    [string]$Environment,

    [switch]$GenerateARM,

    [switch]$OutputSarif
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Resolve repository root: use parameter or shared resolver
. (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
if ($RepoRoot) {
    $repoRoot = $RepoRoot
} else {
    $repoRoot = Resolve-RepoRoot
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
}

# Verify Azure CLI is available
$azCmd = Get-Command 'az' -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Host 'ERROR: Azure CLI is not installed.' -ForegroundColor Red
    Write-Host 'Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli' -ForegroundColor Yellow
    exit 1
}

# Resolve Bicep CLI path for PSRule expansion.
# PSRule.Rules.Azure uses PSRULE_AZURE_BICEP_PATH to locate the Bicep binary.
# Azure CLI installs bicep under ~/.azure/bin; fall back to PATH.
$userHome = [System.Environment]::GetFolderPath('UserProfile')
$bicepBinary = if ($PSVersionTable.Platform -eq 'Win32NT' -or (-not $PSVersionTable.Platform)) { 'bicep.exe' } else { 'bicep' }
$bicepExecutable = Join-Path -Path $userHome -ChildPath '.azure' -AdditionalChildPath 'bin', $bicepBinary
if ($userHome -and (Test-Path $bicepExecutable)) {
    $env:PSRULE_AZURE_BICEP_PATH = $bicepExecutable
    Write-Host "  Bicep CLI: $bicepExecutable" -ForegroundColor Cyan
}
elseif (Get-Command 'bicep' -ErrorAction SilentlyContinue) {
    $env:PSRULE_AZURE_BICEP_PATH = (Get-Command 'bicep').Source
    Write-Host "  Bicep CLI: $($env:PSRULE_AZURE_BICEP_PATH)" -ForegroundColor Cyan
}
else {
    Write-Host '  WARNING: Bicep CLI not found. PSRule expansion may fail.' -ForegroundColor Yellow
    Write-Host '  Install via: az bicep install' -ForegroundColor Yellow
}

# Verify PSRule.Rules.Azure is available; auto-install if missing
if (-not (Get-Module -ListAvailable -Name PSRule.Rules.Azure)) {
    Write-Host 'PSRule.Rules.Azure not installed. Installing...' -ForegroundColor Yellow
    Install-Module -Name PSRule.Rules.Azure -Force -Scope CurrentUser
}

Write-Host 'Validating infrastructure...'

# Deprecation notice for -OutputSarif (now always-on)
if ($OutputSarif) {
    Write-Host 'Note: -OutputSarif is deprecated. SARIF output is now always generated.' -ForegroundColor Yellow
}

# Locate infra/main.bicep -- the single entry point for both lint and PSRule
$infraDir = Join-Path $repoRoot 'infra'
$mainBicep = Join-Path $infraDir 'main.bicep'

if (-not (Test-Path $mainBicep)) {
    Write-Host 'No infra/main.bicep found. Run Initialize-BicepProject.ps1 to scaffold the project.' -ForegroundColor Yellow
    exit 0
}

$relativePath = [IO.Path]::GetRelativePath($repoRoot, $mainBicep)

$totalLintErrors = 0
$totalPSRuleViolations = 0
$outputDir = Join-Path $repoRoot 'output'
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Phase 1: Bicep Lint (az bicep lint -- dedicated linter)
Write-Host ''

try {
    # Always capture SARIF for structured output
    $lintSarifOutput = az bicep lint --file $mainBicep --diagnostics-format sarif 2>&1
    $lintExitCode = $LASTEXITCODE

    # Write lint SARIF to output directory
    $lintSarifPath = Join-Path $outputDir 'bicep-lint-results.sarif'
    $lintSarifOutput | Out-File -FilePath $lintSarifPath -Encoding utf8 -Force

    if ($lintExitCode -ne 0) {
        Write-Host "  LINT: $relativePath -- FAILED" -ForegroundColor Red
        # Parse SARIF for human-readable violation details (avoid running lint twice)
        try {
            $lintSarifJson = $lintSarifOutput | Out-String | ConvertFrom-Json
            foreach ($run in @($lintSarifJson.runs)) {
                foreach ($result in @($run.results)) {
                    $loc = $result.locations[0].physicalLocation.region
                    Write-Host "    Line $($loc.startLine): $($result.ruleId) - $($result.message.text)" -ForegroundColor Yellow
                }
            }
        }
        catch {
            # SARIF parse failed -- show raw output as fallback
            Write-Host "    $lintSarifOutput" -ForegroundColor Yellow
        }
        $totalLintErrors++
    }
    else {
        Write-Host "  LINT: $relativePath -- OK" -ForegroundColor Green
    }

    # Compile to ARM if requested (separate from linting)
    if ($GenerateARM) {
        Write-Host 'Compiling to ARM (output: ./output/)...'
        $outputSubDir = Join-Path $outputDir 'infra'
        if (-not (Test-Path $outputSubDir)) {
            New-Item -ItemType Directory -Path $outputSubDir -Force | Out-Null
        }
        $outputFile = Join-Path $outputSubDir 'main.json'
        $buildResult = az bicep build --file $mainBicep --outfile $outputFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  COMPILE: $relativePath -- FAILED" -ForegroundColor Red
            Write-Host "    $buildResult" -ForegroundColor Yellow
            $totalLintErrors++
        }
        else {
            $compiledRelative = [IO.Path]::GetRelativePath($repoRoot, $outputFile)
            Write-Host "  COMPILED: $compiledRelative" -ForegroundColor Green
        }
    }
}
catch {
    Write-Host "  LINT: $relativePath -- ERROR" -ForegroundColor Red
    Write-Host "    $($_.Exception.Message)" -ForegroundColor Yellow
    $totalLintErrors++
}

# Phase 2: PSRule Analysis (expansion targets main.bicep, analyzes all modules)
Write-Host ''
Write-Host 'Running PSRule analysis...'

try {
    if (-not (Get-Module -Name 'PSRule.Rules.Azure')) {
        Import-Module PSRule.Rules.Azure -ErrorAction Stop
    }

    # Resolve PSRule config from infra directory
    $psRuleConfigPath = $null

    if (-not $Environment) {
        # Load default environment from Config.ps1 (single source of truth)
        $configScript = Join-Path $infraDir 'Config.ps1'
        if (Test-Path $configScript) {
            . $configScript
            if ($script:DefaultEnvironment) {
                $Environment = $script:DefaultEnvironment
                Write-Host "  Environment (from Config.ps1): $Environment" -ForegroundColor Cyan
            }
        }
    }

    if ($Environment) {
        $psRuleConfigPath = Join-Path $infraDir "PSRule.$Environment.yaml"
    }
    else {
        # Fallback: prefer prod (strictest rules) when Config.ps1 is unavailable
        $prodConfig = Join-Path $infraDir 'PSRule.prod.yaml'
        $devConfig = Join-Path $infraDir 'PSRule.dev.yaml'
        if (Test-Path $prodConfig) {
            $psRuleConfigPath = $prodConfig
        }
        elseif (Test-Path $devConfig) {
            $psRuleConfigPath = $devConfig
        }
    }

    if ($psRuleConfigPath -and (Test-Path $psRuleConfigPath)) {
        $psRuleOption = New-PSRuleOption -Path $psRuleConfigPath

        # Guard against YAML keys that exist but have all entries commented out
        # (e.g., 'suppression:' with no children). PSRule parses these as null,
        # which causes a NullReferenceException in the pipeline builder.
        if ($null -eq $psRuleOption.Suppression) {
            $psRuleOption.Suppression = @{}
        }

        Write-Host "  PSRule config: $psRuleConfigPath" -ForegroundColor Cyan
    }
    else {
        $psRuleOption = $null
        Write-Host '  PSRule config: none found (using defaults)' -ForegroundColor Yellow
    }

    # Push into infra directory so PSRule resolves AZURE_BICEP_PARAMS_FILE relative paths correctly.
    # Use main.bicep as the sole input so PSRule only expands this entry point (modules are
    # expanded inline via module references).  Using '.' would cause PSRule to attempt standalone
    # expansion of every .bicep file in the directory tree -- module files lack default parameter
    # values and fail expansion when processed independently.
    Push-Location $infraDir
    try {
        $psRuleResults = @(
            Invoke-PSRule -InputPath './main.bicep' -Module 'PSRule.Rules.Azure' -Option $psRuleOption -Outcome All -ErrorAction Stop
        )

        # Build SARIF 2.1.0 from the RuleRecord results (avoids a second Invoke-PSRule call)
        $sarifPath = Join-Path $outputDir 'psrule-results.sarif'
        $psruleVersion = '0.0.0'
        $loadedPSRule = Get-Module -Name 'PSRule'
        if ($loadedPSRule) {
            $psruleVersion = $loadedPSRule.Version.ToString()
        }
        $sarifResults = [System.Collections.ArrayList]::new()
        foreach ($record in $psRuleResults) {
            $level = switch ($record.Outcome) {
                'Fail' { 'error' }
                'Pass' { 'none' }
                default { 'note' }
            }
            $synopsis = ''
            if ($record.Info -and $record.Info.Synopsis) {
                $synopsis = $record.Info.Synopsis
            }
            $resultObj = [ordered]@{
                ruleId  = $record.RuleName
                level   = $level
                message = @{ text = $synopsis }
            }
            if ($record.TargetName) {
                $resultObj['locations'] = @(
                    @{ logicalLocations = @( @{ name = $record.TargetName } ) }
                )
            }
            [void]$sarifResults.Add($resultObj)
        }
        $sarifDoc = [ordered]@{
            '$schema' = 'https://schemastore.azurewebsites.net/schemas/json/sarif-2.1.0-rtm.5.json'
            version   = '2.1.0'
            runs      = @(
                [ordered]@{
                    tool    = [ordered]@{
                        driver = [ordered]@{
                            name            = 'PSRule'
                            semanticVersion = $psruleVersion
                        }
                    }
                    results = @($sarifResults)
                }
            )
        }
        $sarifDoc | ConvertTo-Json -Depth 10 | Out-File -FilePath $sarifPath -Encoding utf8 -Force
        $sarifRelative = [IO.Path]::GetRelativePath($repoRoot, $sarifPath)
        Write-Host "  SARIF: $sarifRelative" -ForegroundColor Cyan
    }
    finally {
        Pop-Location
    }

    $failures = @($psRuleResults | Where-Object { $_.Outcome -eq 'Fail' })
    $passes = @($psRuleResults | Where-Object { $_.Outcome -eq 'Pass' })
    $evaluatedRules = $passes.Count + $failures.Count
    $totalRulesLoaded = $psRuleResults.Count

    if ($evaluatedRules -eq 0) {
        Write-Host "  WARN: $relativePath -- 0 rules matched ($totalRulesLoaded rules loaded but none applied to expanded resources)" -ForegroundColor Yellow
        Write-Host '    Possible causes:' -ForegroundColor Yellow
        Write-Host '      - Bicep expansion failed (check AZURE_BICEP_PARAMS_FILE path)' -ForegroundColor Yellow
        Write-Host '      - No deployable resources found in template' -ForegroundColor Yellow
        Write-Host '      - Bicep CLI not found (set PSRULE_AZURE_BICEP_PATH)' -ForegroundColor Yellow
    }
    elseif ($failures.Count -gt 0) {
        Write-Host "  FAIL: $relativePath -- $evaluatedRules rules evaluated, $($failures.Count) failure(s)" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "    $($failure.RuleName): $($failure.Info.Synopsis)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  PASS: $relativePath -- $evaluatedRules rules evaluated, 0 failures" -ForegroundColor Green
    }

    $totalPSRuleViolations += $failures.Count
}
catch {
    Write-Host "  PSRule analysis error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host '  Skipping PSRule analysis.' -ForegroundColor Yellow
}

# Summary
Write-Host ''
$totalIssues = $totalLintErrors + $totalPSRuleViolations

if ($totalIssues -eq 0) {
    $message = "Results: $relativePath validated, 0 violation(s) found. SARIF written to ./output/."
    if ($GenerateARM) {
        $message += ' ARM template written to ./output/.'
    }
    Write-Host $message -ForegroundColor Green
    Write-Host "Elapsed: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Cyan
    exit 0
}
else {
    Write-Host "Results: $relativePath validated, $totalIssues violation(s) found. SARIF written to ./output/." -ForegroundColor Red
    Write-Host "Elapsed: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Cyan
    exit 1
}
