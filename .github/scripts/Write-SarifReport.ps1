#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Write a SARIF 2.1.0 report from structured check results.

.DESCRIPTION
    Shared helper used by all VibeShield-Deploy agents to produce
    machine-readable SARIF output.  Each agent collects results as
    a JSON array of objects and calls this script to emit the file.

    Result objects must have these keys:
      id      - Check identifier (e.g. "1", "SC-01")
      name    - Human-readable check name
      status  - PASS, FAIL, WARN, or SKIP
      message - Detail message
      fix     - (optional) Remediation guidance
      evidence - (optional) Hashtable with: command (what was run),
                 output (what was returned), threshold (what was expected).
                 Provides an audit trail of the reasoning behind each check.

.PARAMETER ToolName
    Name of the tool / phase producing the report
    (e.g. "Pipeline Author", "Pipeline Push", "Deploy Monitor", "Bicep Generator").

.PARAMETER ToolVersion
    Semantic version of the tool. Defaults to 1.0.0.

.PARAMETER ResultsJson
    JSON string - array of result objects (see description above).

.PARAMETER OutputPath
    Absolute or relative path for the SARIF file.

.PARAMETER PropertiesJson
    Optional JSON string of extra key-value pairs to store in
    invocation.properties (e.g. appType, azureService, pipelineRunId).

.EXAMPLE
    $results = @(
        @{ id='1'; name='YAML Syntax'; status='PASS'; message='Valid YAML' },
        @{ id='2'; name='1ES Schema'; status='FAIL'; message='Missing SDL section'; fix='Add sdl.credscan.enabled: true' }
    ) | ConvertTo-Json -Depth 5

    ./.github/scripts/Write-SarifReport.ps1 `
        -ToolName 'Pipeline Author' `
        -ResultsJson $results `
        -OutputPath '.vibeshield/results/pipeline-author-results.sarif'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolName,
    [string]$ToolVersion = '1.0.0',
    [Parameter(Mandatory)][string]$ResultsJson,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$PropertiesJson,
    [string]$DeploymentId,
    [string]$PerformedBy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load shared config for sourceRepoUrl
$_sarifCfgPath = Join-Path -Path $PSScriptRoot -ChildPath 'SharedHelpers.ps1'
if (Test-Path $_sarifCfgPath) { . $_sarifCfgPath }

# ── Parse inputs ────────────────────────────────────────────
try {
    $results = $ResultsJson | ConvertFrom-Json
} catch {
    Write-Warning "Failed to parse ResultsJson: $($_.Exception.Message). Writing empty SARIF."
    $results = @()
}
if ($null -eq $results) { $results = @() }
if ($results -isnot [System.Array]) { $results = @($results) }

$extraProps = $null
if ($PropertiesJson) {
    try {
        $extraProps = $PropertiesJson | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse PropertiesJson: $($_.Exception.Message). Ignoring extra properties."
    }
}

# ── Build SARIF structures ─────────────────────────────────
$sarifRules   = [System.Collections.ArrayList]::new()
$sarifResults = [System.Collections.ArrayList]::new()

$totalCount   = $results.Count
$passedCount  = 0
$failedCount  = 0
$warnedCount  = 0
$skippedCount = 0

foreach ($r in $results) {
    $level = switch ($r.status) {
        'FAIL' { 'error' }
        'WARN' { 'warning' }
        'PASS' { 'note' }
        'SKIP' { 'none' }
        default {
            Write-Warning "Unexpected status '$($r.status)' for result '$($r.id)' — defaulting to 'note'"
            'note'
        }
    }

    switch ($r.status) {
        'PASS' { $passedCount++ }
        'FAIL' { $failedCount++ }
        'WARN' { $warnedCount++ }
        'SKIP' { $skippedCount++ }
    }

    $ruleId = "vibeshield/$($r.id)"

    if (-not ($sarifRules | Where-Object { $_.id -eq $ruleId })) {
        $ruleObj = [ordered]@{
            id               = $ruleId
            name             = $r.name
            shortDescription = [ordered]@{ text = $r.name }
        }
        # Add helpUri based on check ID prefix
        if ($r.id -match '^OB-') {
            $ruleObj['helpUri'] = 'https://aka.ms/obpipelines'
        } elseif ($r.id -match '^PF-') {
            $_repoUrl = try { (Get-DeployConfig).ado.sourceRepoUrl } catch { '' }
            if ($_repoUrl) { $ruleObj['helpUri'] = "$_repoUrl`?path=/docs/checks-reference.md" }
        }
        $null = $sarifRules.Add($ruleObj)
    }

    $hasFix = ($r.PSObject.Properties.Name -contains 'fix') -and $r.fix
    $msgText = $r.message
    if ($hasFix) { $msgText += "`nFix: $($r.fix)" }

    $resultObj = [ordered]@{
        ruleId     = $ruleId
        level      = $level
        message    = [ordered]@{ text = $msgText }
        properties = [ordered]@{
            status    = $r.status
            checkId   = $r.id
            checkName = $r.name
        }
    }
    if ($hasFix) {
        $resultObj.properties.fix = $r.fix
    }
    # Evidence trail — audit what was checked and what was found
    $hasEvidence = ($r.PSObject.Properties.Name -contains 'evidence') -and $r.evidence
    if ($hasEvidence) {
        $evidenceObj = [ordered]@{}
        if ($r.evidence.PSObject.Properties['command'])   { $evidenceObj.command   = $r.evidence.command }
        if ($r.evidence.PSObject.Properties['output'])    { $evidenceObj.output    = $r.evidence.output }
        if ($r.evidence.PSObject.Properties['threshold']) { $evidenceObj.threshold = $r.evidence.threshold }
        if ($r.evidence.PSObject.Properties['source'])    { $evidenceObj.source    = $r.evidence.source }
        if ($evidenceObj.Count -gt 0) { $resultObj.properties.evidence = $evidenceObj }
    }
    $null = $sarifResults.Add($resultObj)
}

# ── Invocation properties ──────────────────────────────────
$invocationProps = [ordered]@{
    total   = $totalCount
    passed  = $passedCount
    failed  = $failedCount
    warned  = $warnedCount
    skipped = $skippedCount
}

if ($DeploymentId) {
    $invocationProps['deploymentId'] = $DeploymentId
}

if ($PerformedBy) {
    $invocationProps['performedBy'] = $PerformedBy
}

if ($extraProps) {
    foreach ($prop in $extraProps.PSObject.Properties) {
        $invocationProps[$prop.Name] = $prop.Value
    }
}

# ── Assemble SARIF document ────────────────────────────────
$toolNameFull = "VibeShield-Deploy $ToolName"

$sarifDoc = [ordered]@{
    '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json'
    version   = '2.1.0'
    runs      = @(
        [ordered]@{
            tool = [ordered]@{
                driver = [ordered]@{
                    name           = $toolNameFull
                    version        = $ToolVersion
                    informationUri = (Get-DeployConfig).ado.sourceRepoUrl
                    rules          = @($sarifRules)
                }
            }
            results     = @($sarifResults)
            invocations = @(
                [ordered]@{
                    executionSuccessful = ($failedCount -eq 0)
                    properties          = $invocationProps
                }
            )
            properties  = $invocationProps
        }
    )
}

# ── Write file ──────────────────────────────────────────────
$dir = Split-Path -Path $OutputPath -Parent
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$sarifJson = $sarifDoc | ConvertTo-Json -Depth 10

# Sanitize sensitive content from SARIF messages before writing
if (Get-Command Remove-SensitiveContent -ErrorAction SilentlyContinue) {
    $sarifJson = Remove-SensitiveContent -Text $sarifJson
}

Set-Content -Path $OutputPath -Value $sarifJson -Encoding UTF8

# ── Emit compact _summary.txt for agent consumption ─────────
if (Get-Command Format-SarifSummary -ErrorAction SilentlyContinue) {
    $summaryText = Format-SarifSummary -ToolName $toolNameFull -Results $results
    $summaryPath = $OutputPath -replace '\.sarif$', '_summary.txt'
    Set-Content -Path $summaryPath -Value $summaryText -Encoding UTF8
}

# ── Terminal summary (same style as preflight) ──────────────
$failures = @($results | Where-Object { $_.status -eq 'FAIL' })
$warnings = @($results | Where-Object { $_.status -eq 'WARN' })

Write-Output "" | Out-Host
Write-Output "================================================================" | Out-Host
Write-Output "  $toolNameFull" | Out-Host
Write-Output "  Total: $totalCount  |  Passed: $passedCount  |  Failed: $failedCount  |  Warnings: $warnedCount  |  Skipped: $skippedCount" | Out-Host
Write-Output "================================================================" | Out-Host

if ($failures.Count -gt 0) {
    Write-Output "" | Out-Host
    Write-Output "  ACTIONS REQUIRED ($($failures.Count) failure(s)):" | Out-Host
    Write-Output "" | Out-Host
    $i = 1
    foreach ($f in $failures) {
        Write-Output "    $i. $($f.name)" | Out-Host
        Write-Output "       $($f.message)" | Out-Host
        if (($f.PSObject.Properties.Name -contains 'fix') -and $f.fix) { Write-Output "       -> $($f.fix)" | Out-Host }
        Write-Output "" | Out-Host
        $i++
    }
}

if ($warnings.Count -gt 0) {
    Write-Output "" | Out-Host
    Write-Output "  WARNINGS ($($warnings.Count) item(s)):" | Out-Host
    Write-Output "" | Out-Host
    $i = 1
    foreach ($w in $warnings) {
        Write-Output "    $i. $($w.name)" | Out-Host
        Write-Output "       $($w.message)" | Out-Host
        if (($w.PSObject.Properties.Name -contains 'fix') -and $w.fix) { Write-Output "       -> $($w.fix)" | Out-Host }
        Write-Output "" | Out-Host
        $i++
    }
}

Write-Output "  Full details: $OutputPath" | Out-Host
Write-Output "" | Out-Host
if ($failedCount -gt 0) {
    Write-Output "  $failedCount check(s) failed. See details above." | Out-Host
} else {
    Write-Output "  All checks passed." | Out-Host
}
Write-Output "" | Out-Host

# SARIF path printed above — user opens manually if needed
