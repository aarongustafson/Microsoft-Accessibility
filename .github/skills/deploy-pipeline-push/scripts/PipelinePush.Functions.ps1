#!/usr/bin/env pwsh
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural nouns are intentional for collection-returning functions')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Functions return dynamic PSCustomObject/hashtable types')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$global:AdoGitTokenCache is a cross-module token cache shared between dot-sourced scripts')]
param()
Set-StrictMode -Version Latest
<#
.SYNOPSIS
    Testable functions extracted from Invoke-PipelinePush.ps1.

.DESCRIPTION
    Dot-source this file to load pipeline-push check functions, CLI wrappers,
    and auto-detection helpers. All external commands (git, az) are routed
    through Invoke-GitCommand / Invoke-AzCommand so Pester can mock them.
#>

# ════════════════════════════════════════════════════════════
# CLI Wrappers — loaded from shared helpers (mock these in Pester tests)
# ════════════════════════════════════════════════════════════
# Idempotency guard: skip re-dot-source if SharedHelpers is already loaded.
# This preserves Pester mocks that the test's BeforeAll sets up.
# In production, functions aren't pre-loaded so the dot-source runs normally.
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (-not (Get-Command Invoke-GitCommand -ErrorAction SilentlyContinue) -or
    -not (Get-Command Get-DeployConfig -ErrorAction SilentlyContinue)) {
    if (Test-Path $sharedHelpersPath) {
        . $sharedHelpersPath
    } else {
    # Inline fallback if shared helpers not found (e.g. standalone testing)
    function Invoke-GitCommand {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GIT_EDITOR = 'true'
        $env:GCM_INTERACTIVE = 'never'
        $env:GIT_PAGER = ''
        # Suppress VS Code's built-in credential UI (separate from GCM_INTERACTIVE)
        $env:GIT_ASKPASS = ''
        # Strip -TimeoutSeconds from args (not used in fallback)
        $cleanArgs = @(); for ($i=0; $i -lt $Arguments.Count; $i++) { if ($Arguments[$i] -eq '-TimeoutSeconds' -and $i+1 -lt $Arguments.Count) { $i++ } else { $cleanArgs += $Arguments[$i] } }
        # Inject bearer token via GIT_CONFIG_* env vars (matches SharedHelpers pattern).
        # Do NOT use -c credential.helper= (disables GCM fallback) or -c http.extraheader
        # (wrong casing causes HTTP 400 on ADO). GCM remains as fallback if token is missing/expired.
        if ($global:AdoGitTokenCache) {
            $env:GIT_CONFIG_COUNT   = '1'
            $env:GIT_CONFIG_KEY_0   = 'http.extraHeader'
            $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $($global:AdoGitTokenCache)"
        } else {
            # Clear stale env vars so GCM handles auth cleanly after token cache reset
            Remove-Item Env:GIT_CONFIG_COUNT   -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_CONFIG_KEY_0   -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
        }
        $raw = & git @cleanArgs 2>&1 | Out-String
        $ec  = $LASTEXITCODE
        [pscustomobject]@{ Output = $raw.Trim(); ExitCode = $ec }
    }
    function Invoke-AzCommand {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        $env:AZURE_CORE_NO_PROMPT = 'true'
        $cleanArgs = @(); for ($i=0; $i -lt $Arguments.Count; $i++) { if ($Arguments[$i] -eq '-TimeoutSeconds' -and $i+1 -lt $Arguments.Count) { $i++ } else { $cleanArgs += $Arguments[$i] } }
        $raw = & az @cleanArgs --only-show-errors 2>&1 | Out-String
        $ec  = $LASTEXITCODE
        [pscustomobject]@{ Output = $raw.Trim(); ExitCode = $ec }
    }
    function Invoke-WithRetry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxRetries', Justification='Part of retry interface contract; stub delegates to ScriptBlock')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TransientPatterns', Justification='Part of retry interface contract; stub delegates to ScriptBlock')]
        [CmdletBinding()]
        param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [int]$MaxRetries = 3, [string[]]$TransientPatterns = @())
        return & $ScriptBlock
    }
    function Clear-AdoGitTokenCache {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Cross-module token cache by design')]
        [CmdletBinding()]
        param()
        $global:AdoGitTokenCache = $null
        Remove-Item Env:GIT_CONFIG_COUNT   -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_CONFIG_KEY_0   -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    }
    function Get-AdoGitToken {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Cross-module token cache by design')]
        [CmdletBinding()]
        param([string]$RemoteUrl = '')
        if ($RemoteUrl -match '^git@|^ssh://|ssh\.dev\.azure\.com') { return $true }
        if ($global:AdoGitTokenCache) {
            $env:GIT_CONFIG_COUNT   = '1'
            $env:GIT_CONFIG_KEY_0   = 'http.extraHeader'
            $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $($global:AdoGitTokenCache)"
            return $global:AdoGitTokenCache
        }
        # Acquire token with well-known ADO resource ID and Corp tenant
        # (499b84ac-1321-427f-aa17-267ca6975798 = Azure DevOps,
        #  72f988bf-86f1-41af-91ab-2d7cd011db47 = Microsoft Corp tenant)
        $global:LASTEXITCODE = 0
        $token = $null
        try {
            $token = (& az account get-access-token `
                --tenant '72f988bf-86f1-41af-91ab-2d7cd011db47' `
                --resource '499b84ac-1321-427f-aa17-267ca6975798' `
                --query accessToken -o tsv 2>$null)?.Trim()
        } catch { $null = $_ }
        if (-not $token -or $LASTEXITCODE -ne 0) { return $false }
        $global:AdoGitTokenCache = $token
        $env:GIT_CONFIG_COUNT   = '1'
        $env:GIT_CONFIG_KEY_0   = 'http.extraHeader'
        $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $token"
        return $token
    }
}
}  # end idempotency guard

# ════════════════════════════════════════════════════════════
# EV2 Detection — single canonical pattern
# ════════════════════════════════════════════════════════════

function Test-IsEv2Pipeline {
    <#
    .SYNOPSIS Detects whether pipeline YAML content indicates an EV2 deployment.
    .DESCRIPTION
        Single canonical EV2 detection function replacing 4 inconsistent inline
        regex patterns. Checks for EV2 task names, OneBranch EV2 variables,
        and ServiceGroupRoot artifact references.
    .PARAMETER PipelineContent
        Raw YAML content of the pipeline file.
    .OUTPUTS System.Boolean — $true if EV2 markers detected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PipelineContent)

    return [bool]($PipelineContent -match 'Ev2RARollout@2|Ev2Rollout|ob_ev2|ServiceGroupRoot')
}

# ════════════════════════════════════════════════════════════
# Auto-detection functions — thin wrappers over SharedHelpers
# Kept for backward compatibility with tests that mock these.
# Canonical logic lives in Get-DeployContext (SharedHelpers.ps1).
# ════════════════════════════════════════════════════════════

function Get-AutoDetectedEmail {
    <#
    .SYNOPSIS Detects user email. Delegates to Get-DeployContext tier-3.
    .OUTPUTS System.String or $null
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-DeployContext -SkipAutoDetect:$false
    if (-not [string]::IsNullOrWhiteSpace($ctx.Email)) { return $ctx.Email }
    return $null
}

function Get-AdoRemoteInfo {
    <#
    .SYNOPSIS Parses Azure DevOps org, project, and repo.
    .OUTPUTS PSCustomObject with OrgUrl, Project, Repo — or $null.
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-DeployContext -SkipAutoDetect:$false
    if (-not [string]::IsNullOrWhiteSpace($ctx.AdoOrgUrl)) {
        return [pscustomobject]@{
            OrgUrl  = $ctx.AdoOrgUrl
            Project = $ctx.AdoProject
            Repo    = $ctx.RepoName
        }
    }
    return $null
}

function Get-DetectedAppType {
    <#
    .SYNOPSIS Detects application type. Delegates to centralized Get-AppType engine.
    .OUTPUTS System.String
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)
    if (Get-Command Get-AppType -ErrorAction SilentlyContinue) {
        $detection = Get-AppType -Path $WorkspacePath -WorkspacePath $WorkspacePath
        if ($detection) { return $detection.AppType }
    }
    return 'Unknown'
}

# ════════════════════════════════════════════════════════════# Git Hook Detection
# VibeShield-Deploy NEVER installs git hooks. However, other agents
# (e.g. checkin agent) may install pre-commit or pre-push hooks.
# We detect, report, and honor them — never bypass or kill them.
# ════════════════════════════════════════════════════════════

function Get-InstalledGitHooks {
    <#
    .SYNOPSIS Detects active git hooks in the repository.
    .DESCRIPTION
        Scans the git hooks directory for executable hook files (excluding .sample).
        Respects core.hooksPath for custom hook locations.
        Returns an array of objects with Name and Path — or empty array if none found.
    #>
    [CmdletBinding()]
    param(
        [string[]]$HookNames = @('pre-commit', 'commit-msg', 'pre-push')
    )

    # Check core.hooksPath first (custom hook directory)
    $hooksDir = $null
    $cfgResult = Invoke-GitCommand 'config', '--get', 'core.hooksPath'
    if ($cfgResult.ExitCode -eq 0 -and $cfgResult.Output) {
        $hooksDir = $cfgResult.Output
    }

    # Fall back to <git-dir>/hooks
    if (-not $hooksDir -or -not (Test-Path $hooksDir)) {
        $gitDirResult = Invoke-GitCommand 'rev-parse', '--git-dir'
        if ($gitDirResult.ExitCode -ne 0 -or -not $gitDirResult.Output) { return @() }
        $hooksDir = Join-Path -Path $gitDirResult.Output -ChildPath 'hooks'
    }

    if (-not (Test-Path $hooksDir)) { return @() }

    $found = @()
    foreach ($name in $HookNames) {
        $hookPath = Join-Path -Path $hooksDir -ChildPath $name
        if (Test-Path $hookPath) {
            $found += [pscustomobject]@{ Name = $name; Path = $hookPath }
        }
    }
    return $found
}

function Test-HookFailure {
    <#
    .SYNOPSIS Determines if a git command failure was caused by a hook.
    .DESCRIPTION
        Checks the git output for common hook-failure indicators. Git does not
        use a unique exit code for hook failures, so we rely on output patterns.
    .OUTPUTS $true if the failure appears to be hook-related; $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Output,
        [string[]]$ActiveHookNames = @()
    )

    # If no hooks are installed, it can't be a hook failure
    if ($ActiveHookNames.Count -eq 0) { return $false }

    # Common patterns git emits when a hook fails (case-insensitive)
    $hookPatterns = @(
        '(?i)hook.*returned exit code',
        '(?i)hook.*failed',
        '(?i)hook.*rejected',
        '(?i)hook.*declined',
        '(?i)pre-commit.*hook',
        '(?i)commit-msg.*hook',
        '(?i)pre-push.*hook',
        '(?i)husky',
        '(?i)lint-staged'
    )

    foreach ($pat in $hookPatterns) {
        if ($Output -match $pat) { return $true }
    }

    # Fallback: if a known hook name appears in stderr with a non-zero exit,
    # treat it as a hook failure even if the exact message format differs
    foreach ($hookName in $ActiveHookNames) {
        if ($Output -match "(?i)$([regex]::Escape($hookName))") { return $true }
    }

    return $false
}

# ════════════════════════════════════════════════════════════
# Check functions
# Each returns @{ Status = PASS|FAIL|WARN|SKIP; Message; Fix }
# Some checks add extra keys (CommitSha, PipelineUrl, PipelineRunId).
# ════════════════════════════════════════════════════════════

function Test-PipelineFileExists {
    <# PP-01 — Verify pipeline YAML is present. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$PipelineYmlPath
    )
    if (Test-Path (Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath)) {
        return @{ Status = 'PASS'; Message = "$PipelineYmlPath present" }
    }
    return @{
        Status  = 'FAIL'
        Message = "$PipelineYmlPath not found"
        Fix     = 'Run Pipeline Setup to generate the pipeline YAML before pushing.'
    }
}

function Test-RequiredFilesTracked {
    <# PP-02 — Ensure required files aren't git-ignored.
       Multi-module aware: reads workspace manifest and validates per-module config files
       in addition to the primary module's required files. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$AppType,
        [hashtable]$RequiredFilesMap = @{}
    )

    # ── Collect per-module required files from manifest ──
    $allReqPatterns = @{}  # Key = module label, Value = patterns[]

    $manifestPath = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield/results/workspace-manifest.json'
    $modules = @()
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.PSObject.Properties['modules'] -and $manifest.modules) {
                $modules = @($manifest.modules)
            }
        } catch { $null = $_ }
    }

    if ($modules.Count -gt 0) {
        foreach ($mod in $modules) {
            $modAppType = if ($mod.PSObject.Properties['appType']) { $mod.appType } else { '' }
            $modPath = if ($mod.PSObject.Properties['path']) { $mod.path } else { '.' }
            $modLabel = if ($modPath -eq '.') { 'Primary' } else { $modPath }

            $patterns = @()
            if ($modAppType -and $RequiredFilesMap.ContainsKey($modAppType)) {
                foreach ($p in @($RequiredFilesMap[$modAppType])) {
                    # Prefix with module path for non-root modules
                    if ($modPath -ne '.') {
                        $patterns += "$modPath/$p"
                    } else {
                        $patterns += $p
                    }
                }
            }
            if ($patterns.Count -gt 0) { $allReqPatterns[$modLabel] = $patterns }
        }
    } else {
        # Single-module fallback
        $patterns = @()
        if ($RequiredFilesMap.ContainsKey($AppType)) {
            $patterns = @($RequiredFilesMap[$AppType])
        }
        $allReqPatterns['Primary'] = $patterns
    }

    # Always add infra files if infra/ exists
    if (Test-Path (Join-Path -Path $WorkspacePath -ChildPath 'infra')) {
        $infraPatterns = @('infra/main.bicep', 'infra/dev.bicepparam')
        if ($allReqPatterns.ContainsKey('Primary')) {
            $allReqPatterns['Primary'] = @($allReqPatterns['Primary']) + $infraPatterns
        } else {
            $allReqPatterns['Primary'] = $infraPatterns
        }
    }

    $ignoredRequired = @()
    # Collect all candidate files first, then batch-check with a single git call
    $candidateFiles = @()  # Array of @{ Label; RelPath }
    foreach ($label in $allReqPatterns.Keys) {
        foreach ($pat in $allReqPatterns[$label]) {
            $matchingFiles = @(Get-ChildItem -Path $WorkspacePath -Filter (Split-Path -Path $pat -Leaf) -Recurse -Depth 3 -ErrorAction SilentlyContinue)
            if ($matchingFiles.Count -eq 0) { continue }
            foreach ($f in $matchingFiles) {
                $relPath = [System.IO.Path]::GetRelativePath($WorkspacePath, $f.FullName) -replace '\\','/'
                $candidateFiles += @{ Label = $label; RelPath = $relPath }
            }
        }
    }

    if ($candidateFiles.Count -gt 0) {
        # Single git check-ignore call for all files (avoids spawning one process per file)
        $allPaths = $candidateFiles | ForEach-Object { $_.RelPath }
        $result = Invoke-GitCommand 'check-ignore' @allPaths -TimeoutSeconds 30
        $ignoredSet = @{}
        if ($result.Output) {
            foreach ($line in ($result.Output -split "`n")) {
                $trimmed = $line.Trim() -replace '\\','/'
                if ($trimmed) { $ignoredSet[$trimmed] = $true }
            }
        }
        foreach ($c in $candidateFiles) {
            if ($ignoredSet.ContainsKey($c.RelPath)) {
                $ignoredRequired += "[$($c.Label)] $($c.RelPath)"
            }
        }
    }

    if ($ignoredRequired.Count -eq 0) {
        $modCount = if ($modules.Count -gt 0) { $modules.Count } else { 1 }
        return @{ Status = 'PASS'; Message = "All required files are git-tracked ($modCount module(s))" }
    }
    return @{
        Status  = 'FAIL'
        Message = "Required files are git-ignored: $($ignoredRequired -join ', ')"
        Fix     = "Remove these patterns from .gitignore so required config files are tracked"
    }
}

function Test-AppNameConsistency {
    <# PP-02b — Validate app name flow between Provision and Deploy stages in the pipeline.
       Checks that:
       1. The primary Deploy stage uses $(appName) (a pipeline variable, not a hardcoded literal).
       2. Secondary Deploy stages (Deploy_*) use variable references ($(varName)) backed by
          stageDependencies expressions that pull from Provision outputs — never hardcoded literals.
       3. The Provision stage has name: bicepOutput (required for output addressability)
          when secondary Deploy stages exist.
       Does NOT compare against infra/config.ps1 or Bicep params — those are authoring-time
       concerns, not push-time concerns. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$PipelineYmlPath
    )

    if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath }
    $fullYmlPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
    if (-not (Test-Path $fullYmlPath)) {
        return @{ Status = 'SKIP'; Message = 'Pipeline YAML not found — cannot validate app name consistency' }
    }

    $yamlContent = Get-Content $fullYmlPath -Raw
    $issues = @()

    # ── EV2 pipelines: validate ServiceModel.json app names match pipeline variables ──
    if (Test-IsEv2Pipeline -PipelineContent $yamlContent) {
        return Test-Ev2AppNameConsistency -PipelineContent $yamlContent -WorkspacePath $WorkspacePath
    }

    # ── 1. Find all Deploy stages and classify them as primary or secondary ──
    # Primary Deploy stage: stage name is exactly "Deploy"
    # Secondary Deploy stages: stage name matches "Deploy_*" (e.g., Deploy_Functions)
    # NOTE: stages may be indented (e.g., under extends > parameters > stages) so
    #       allow optional leading whitespace before the '- stage:' marker.
    $allStageMatches = [regex]::Matches($yamlContent, '(?m)^\s*-\s*stage:\s*(\S+)')
    $hasProvisionStage = $false
    $primaryDeployExists = $false
    $secondaryDeployStages = @()

    foreach ($sm in $allStageMatches) {
        $stageName = $sm.Groups[1].Value
        if ($stageName -eq 'Provision') { $hasProvisionStage = $true }
        elseif ($stageName -eq 'Deploy') { $primaryDeployExists = $true }
        elseif ($stageName -match '^Deploy_\w+') { $secondaryDeployStages += $stageName }
    }

    if (-not $primaryDeployExists) {
        return @{ Status = 'SKIP'; Message = 'No Deploy stage found in pipeline YAML' }
    }

    # ── 2. Check primary Deploy stage — appName must be a variable reference ──
    # Extract the Deploy stage block (from "- stage: Deploy" to the next "- stage:" or end)
    # Allow optional leading whitespace for indented stages (e.g., under extends > parameters > stages)
    $primaryBlock = ''
    $primaryPattern = '(?s)(?:^|\n)\s*-\s*stage:\s*Deploy\b(.+?)(?=\n\s*-\s*stage:|\z)'
    $primaryMatch = [regex]::Match($yamlContent, $primaryPattern)
    if ($primaryMatch.Success) {
        $primaryBlock = $primaryMatch.Groups[1].Value
        # Find appName task inputs in the primary Deploy block
        $primaryAppNameInputs = [regex]::Matches($primaryBlock, '(?m)^\s+appName:\s*(.+)$')
        foreach ($m in $primaryAppNameInputs) {
            $val = $m.Groups[1].Value.Trim().Trim("'""")
            # $(appName) or $[...] expression — both valid variable references
            if ($val -match '^\$[\(\[]') { continue }
            # Literal hardcoded value — fail
            $issues += "Primary Deploy stage has hardcoded appName='$val' — must use `$(appName)` pipeline variable"
        }
    }

    # ── 3. Check secondary Deploy stages — appName must use variable references ──
    #        backed by stageDependencies expressions from Provision outputs
    foreach ($secStage in $secondaryDeployStages) {
        $secPattern = "(?s)(?:^|\n)\s*-\s*stage:\s*$([regex]::Escape($secStage))\b(.+?)(?=\n\s*-\s*stage:|\z)"
        $secMatch = [regex]::Match($yamlContent, $secPattern)
        if (-not $secMatch.Success) { continue }
        $secBlock = $secMatch.Groups[1].Value

        # Check that the stage has a stageDependencies variable mapping for Provision outputs
        $hasStageDepsRef = $secBlock -match "stageDependencies\.Provision\.ProvisionJob\.outputs\["
        if (-not $hasStageDepsRef) {
            $issues += "Secondary stage '$secStage' has no stageDependencies variable mapping from Provision outputs — app name must be derived from Bicep deployment outputs"
        }

        # Check appName task inputs — must be variable references, not hardcoded literals
        $secAppNameInputs = [regex]::Matches($secBlock, '(?m)^\s+appName:\s*(.+)$')
        foreach ($m in $secAppNameInputs) {
            $val = $m.Groups[1].Value.Trim().Trim("'""")
            # $(variableName) or $[...] expression — valid
            if ($val -match '^\$[\(\[]') { continue }
            # Literal hardcoded value — fail
            $issues += "Secondary stage '$secStage' has hardcoded appName='$val' — must use a variable reference backed by stageDependencies from Provision outputs"
        }
    }

    # ── 4. Provision stage output addressability ──
    #        Required when secondary Deploy stages exist: name: bicepOutput on AzureCLI task
    if ($secondaryDeployStages.Count -gt 0 -and $hasProvisionStage) {
        $hasBicepOutputName = $yamlContent -match '(?m)^\s+name:\s*bicepOutput'
        if (-not $hasBicepOutputName) {
            $issues += "Provision stage AzureCLI task missing 'name: bicepOutput' — required for secondary Deploy stages to consume Bicep outputs via stageDependencies"
        }
    }

    if ($issues.Count -eq 0) {
        $stageCount = 1 + $secondaryDeployStages.Count
        return @{ Status = 'PASS'; Message = "App name flow is consistent across $stageCount Deploy stage(s) — all use variable references from Provision outputs" }
    }
    return @{
        Status  = 'FAIL'
        Message = $issues -join '; '
        Fix     = 'Ensure primary Deploy uses $(appName) and secondary Deploy stages derive app names from stageDependencies.Provision.ProvisionJob.outputs'
    }
}

function Test-SensitiveFilesStaged {
    <# PP-03 — Check git add dry-run for secrets/sensitive files. #>
    [CmdletBinding()]
    param(
        [string[]]$DryRunLines,
        [Parameter(Mandatory)][string[]]$SensitivePatterns
    )
    $sensitiveFound = @()
    foreach ($line in $DryRunLines) {
        if ($line -match "add '([^']+)'") {
            $filePath = $Matches[1]
            foreach ($sp in $SensitivePatterns) {
                $spRegex = '^' + [regex]::Escape($sp).Replace('\*', '.*').Replace('\?', '.') + '$'
                $fileName = Split-Path -Path $filePath -Leaf
                if ($fileName -match $spRegex) {
                    $sensitiveFound += $filePath
                }
            }
        }
    }

    if ($sensitiveFound.Count -eq 0) {
        return @{ Status = 'PASS'; Message = 'No sensitive files in staging area' }
    }
    return @{
        Status  = 'FAIL'
        Message = "Sensitive files would be committed: $($sensitiveFound -join ', ')"
        Fix     = "Add these to .gitignore: $($sensitiveFound -join ', ')"
    }
}

function Test-GitignoreContent {
    <# PP-04 — Verify .gitignore covers build outputs and sensitive files. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string[]]$ExcludePatterns
    )
    $gitignorePath = Join-Path -Path $WorkspacePath -ChildPath '.gitignore'
    if (Test-Path $gitignorePath) {
        $gitignoreContent = Get-Content $gitignorePath -Raw
        $missingExcludes = @()
        foreach ($pat in $ExcludePatterns) {
            if ($gitignoreContent -notmatch [regex]::Escape($pat)) {
                $exists = (Test-Path (Join-Path -Path $WorkspacePath -ChildPath $pat)) -or
                          (Get-ChildItem -Path $WorkspacePath -Filter $pat -Depth 1 -ErrorAction SilentlyContinue)
                if ($exists) { $missingExcludes += $pat }
            }
        }
        if ($missingExcludes.Count -eq 0) {
            return @{ Status = 'PASS'; Message = '.gitignore excludes build outputs and sensitive files' }
        }
        return @{
            Status  = 'WARN'
            Message = "Missing .gitignore entries: $($missingExcludes -join ', ')"
            Fix     = "Add to .gitignore: $($missingExcludes -join ', ')"
        }
    }

    # No .gitignore — create a minimal default
    $defaultIgnore = @('node_modules/', 'bin/', 'obj/', 'dist/', '__pycache__/', '.env', '*.log',
                       '.venv/', 'venv/', '.terraform/', '*.tfstate*', '.vs/', '*.user')
    try {
        Set-Content -Path $gitignorePath -Value ($defaultIgnore -join "`n") -Encoding UTF8
    } catch {
        return @{
            Status  = 'FAIL'
            Message = "Failed to create .gitignore: $_"
            Fix     = 'Check file permissions in the workspace root.'
        }
    }
    return @{
        Status  = 'WARN'
        Message = 'Created default .gitignore (none existed)'
        Fix     = 'Review the generated .gitignore and adjust as needed.'
    }
}

function Test-LargeBinariesStaged {
    <# PP-05 — Check dry-run output for node_modules, bin, obj, etc. and individual large files (>100MB). #>
    [CmdletBinding()]
    param(
        [string[]]$DryRunLines,
        [Parameter(Mandatory)][string[]]$LargeDirPatterns,
        [long]$MaxFileSizeBytes = 104857600  # 100MB default
    )
    $largeDirsFound = @()
    $largeFilesFound = @()
    foreach ($line in $DryRunLines) {
        if ($line -match "add '([^']+)'") {
            $filePath = $Matches[1]
            # Check directory patterns
            foreach ($ld in $LargeDirPatterns) {
                $ldClean = $ld.TrimEnd('/')
                if ($filePath -like "$ldClean/*" -or $filePath -like "*/$ldClean/*") {
                    if ($ldClean -notin $largeDirsFound) { $largeDirsFound += $ldClean }
                }
            }
            # Check individual file size via git (only for files not already in a large dir)
            if ($largeDirsFound.Count -eq 0 -or -not ($largeDirsFound | Where-Object { $filePath -like "$_/*" -or $filePath -like "*/$_/*" })) {
                try {
                    $sizeResult = Invoke-GitCommand 'cat-file', '-s', ":$filePath"
                    if ($sizeResult.ExitCode -eq 0 -and $sizeResult.Output -match '^\d+$') {
                        $fileSize = [long]$sizeResult.Output
                        if ($fileSize -gt $MaxFileSizeBytes) {
                            $sizeMB = [math]::Round($fileSize / 1MB, 1)
                            $largeFilesFound += "$filePath (${sizeMB}MB)"
                        }
                    }
                } catch { <# Ignore file-size check failures for individual files #> $null = $_ }
            }
        }
    }

    $allIssues = @()
    if ($largeDirsFound.Count -gt 0) { $allIssues += "Large directories: $($largeDirsFound -join ', ')" }
    if ($largeFilesFound.Count -gt 0) { $allIssues += "Large files: $($largeFilesFound -join ', ')" }

    if ($allIssues.Count -eq 0) {
        return @{ Status = 'PASS'; Message = 'No large binary directories or oversized files in staging area' }
    }
    return @{
        Status  = 'FAIL'
        Message = "Large content would be committed: $($allIssues -join '; ')"
        Fix     = 'Add large directories to .gitignore. For large files, remove them or use Git LFS.'
    }
}

function Get-StagingSummary {
    <# PP-06 — Count files in dry-run output. #>
    [CmdletBinding()]
    param([string[]]$DryRunLines)
    $fileCount = @($DryRunLines | Where-Object { $_ -match "add '" }).Count
    if ($fileCount -ge 0) {
        return @{ Status = 'PASS'; Message = "$fileCount file(s) ready to stage" }
    }
    return @{
        Status  = 'WARN'
        Message = 'No files to commit'
        Fix     = 'Ensure your source files are in the workspace.'
    }
}

# ════════════════════════════════════════════════════════════
# Pre-Push Build & Infrastructure Verification (PP-06a, PP-06b, PP-06c)
# These gates ensure the code, infrastructure, and pipeline are all
# consistent and buildable BEFORE any code is pushed.
# ════════════════════════════════════════════════════════════

function Invoke-AppBuildGate {
    <# PP-06a — Verify application builds and tests pass locally by delegating
       to the build readiness script (BR-01 and BR-02). Returns FAIL if the
       app cannot be built or unit tests fail, blocking the push.
       When HasTests is $false, passes -SkipTests to the build readiness script
       so BR-02 is skipped (no test execution).
       When SourcePath is provided, only the specified source directory is built
       (scoped to user-confirmed modules). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AppType', Justification='Interface contract parameter')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$AppType,
        [string]$PipelineYmlPath,
        [bool]$HasTests = $true,
        [string]$SourcePath
    )

    $brScript = Join-Path -Path $WorkspacePath -ChildPath '.github/skills/deploy-build-readiness/scripts/Invoke-BuildReadiness.ps1'
    if (-not (Test-Path $brScript)) {
        return @{
            Status  = 'SKIP'
            Message = 'Build readiness script not found — cannot validate build'
            Details = @()
        }
    }

    # Run the build readiness script and capture its SARIF output.
    $brSarifPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'build-readiness-results.sarif'
    $brParams = @{ WorkspacePath = $WorkspacePath; SarifPath = $brSarifPath }
    if ($PipelineYmlPath) { $brParams['PipelineYmlPath'] = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath }
    if (-not $HasTests) { $brParams['SkipTests'] = $true }
    # Note: Invoke-BuildReadiness does not accept -AppType or -SourcePath directly.
    # AppType is auto-detected from the workspace manifest by BuildReadiness.
    # SourcePath scoping is handled by the manifest's module list, not by a param.
    # If a manifest exists with a specific module, BuildReadiness reads it from ManifestPath.
    if ($SourcePath) {
        # Generate a scoped manifest for this specific module path
        $scopedManifest = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath "build-readiness-manifest-$(Get-Random).json"
        $manifestBase = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'workspace-manifest.json'
        if (Test-Path $manifestBase) {
            try {
                $mfData = Get-Content $manifestBase -Raw | ConvertFrom-Json
                $relSource = if ($SourcePath -eq $WorkspacePath) { '.' } else { [System.IO.Path]::GetRelativePath($WorkspacePath, $SourcePath) -replace '\\','/' }
                $filteredModules = @($mfData.modules | Where-Object { $_.path -eq $relSource -or ($relSource -eq '.' -and ($_.path -eq '.' -or $null -eq $_.path)) })
                if ($filteredModules.Count -gt 0) {
                    $mfData.modules = $filteredModules
                    $mfData | ConvertTo-Json -Depth 10 | Set-Content $scopedManifest -Encoding utf8
                    $brParams['ManifestPath'] = $scopedManifest
                }
            } catch { <# manifest parse error — let BuildReadiness use default #> $null = $_ }
        }
    }

    try {
        $global:LASTEXITCODE = 0
        & $brScript @brParams 2>&1 | Out-Null
        $brExit = $LASTEXITCODE
    } catch {
        return @{
            Status  = 'FAIL'
            Message = "Build readiness script failed to execute: $_"
            Fix     = 'Verify PowerShell 7+ is installed and build tools for your app type are available.'
            Details = @()
        }
    }

    # Parse the SARIF for check results
    $details = @()
    $failures = @()
    if (Test-Path $brSarifPath) {
        try {
            $sarif = Get-Content $brSarifPath -Raw | ConvertFrom-Json
            if ($sarif.runs -and $sarif.runs.Count -gt 0) {
                foreach ($result in $sarif.runs[0].results) {
                    $checkId = if ($result.properties.checkId) { $result.properties.checkId } else { $result.ruleId }
                    $status  = $result.properties.status
                    $msg     = $result.message.text
                    $details += [pscustomobject]@{ CheckId = $checkId; Status = $status; Message = $msg }
                    if ($status -eq 'FAIL') { $failures += "$checkId — $msg" }
                }
            }
        } catch {
            Write-Warning "Could not parse build readiness SARIF: $_"
        }
    }

    if ($brExit -ne 0 -or $failures.Count -gt 0) {
        $failSummary = if ($failures.Count -gt 0) { $failures -join '; ' } else { 'Build readiness returned non-zero exit code' }
        return @{
            Status  = 'FAIL'
            Message = "Build readiness failed: $failSummary"
            Fix     = 'Fix build errors and failing tests before pushing. Run Invoke-BuildReadiness.ps1 locally to see full output.'
            Details = $details
        }
    }

    return @{
        Status  = 'PASS'
        Message = 'Application builds successfully and all checks pass'
        Details = $details
    }
}

function Resolve-InfraPath {
    <# Discovers the infra directory and main Bicep template by:
       1. Parsing pipeline YAML for --template-file argument or infraRoot variable
       2. Falling back to the conventional infra/ directory at workspace root #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$PipelineYmlPath
    )

    $infraDir  = $null
    $mainBicep = $null

    # Try to extract from pipeline YAML
    if ($PipelineYmlPath) {
        $fullYmlPath = if ([System.IO.Path]::IsPathRooted($PipelineYmlPath)) { $PipelineYmlPath } else { Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath }
        if (Test-Path $fullYmlPath) {
            $ymlContent = Get-Content $fullYmlPath -Raw -ErrorAction SilentlyContinue
            if ($ymlContent) {
                # Match --template-file argument (may use pipeline variables like $(infraRoot))
                if ($ymlContent -match '--template-file\s+[''"]?(\S+\.bicep)[''"]?') {
                    $templateRef = $Matches[1]
                    # Resolve pipeline variables like $(infraRoot)/main.bicep
                    if ($templateRef -match '\$\((\w+)\)') {
                        $varName = $Matches[1]
                        # Look for variable definition:  varName: 'value'  or  varName: value
                        if ($ymlContent -match "(?mi)$varName\s*:\s*['""]?([^'""}\r\n]+)['""]?") {
                            $varValue = $Matches[1].Trim()
                            $templateRef = $templateRef -replace '\$\(\w+\)', $varValue
                        }
                    }
                    $resolvedPath = Join-Path -Path $WorkspacePath -ChildPath $templateRef
                    if (Test-Path $resolvedPath) {
                        $mainBicep = $resolvedPath
                        $infraDir  = Split-Path -Path $mainBicep -Parent
                    }
                }

                # Fallback: check for infraRoot variable
                if (-not $infraDir -and $ymlContent -match '(?mi)(?:infraRoot)\s*:\s*[''"]?([^''"}\r\n]+)[''"]?') {
                    $candidate = Join-Path -Path $WorkspacePath -ChildPath $Matches[1].Trim()
                    if (Test-Path $candidate) {
                        $infraDir = $candidate
                        $candidateMain = Join-Path -Path $infraDir -ChildPath 'main.bicep'
                        if (Test-Path $candidateMain) { $mainBicep = $candidateMain }
                    }
                }
            }
        }
    }

    # Fallback: conventional infra/ at workspace root
    if (-not $infraDir) {
        $infraDir = Join-Path -Path $WorkspacePath -ChildPath 'infra'
    }
    if (-not $mainBicep) {
        $mainBicep = Join-Path -Path $infraDir -ChildPath 'main.bicep'
    }

    return @{
        InfraDir  = $infraDir
        MainBicep = $mainBicep
    }
}

function Test-BicepBuildable {
    <# PP-06b — Verify Bicep templates compile locally using az bicep build.
       Returns FAIL if Bicep files exist but cannot be compiled, blocking the push. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$PipelineYmlPath
    )

    $resolved  = Resolve-InfraPath -WorkspacePath $WorkspacePath -PipelineYmlPath $PipelineYmlPath
    $infraDir  = $resolved.InfraDir
    $mainBicep = $resolved.MainBicep

    # No infra directory or no Bicep files — not applicable
    if (-not (Test-Path $infraDir)) {
        return @{ Status = 'SKIP'; Message = "No infra directory found at $infraDir — Bicep validation not applicable" }
    }

    $bicepFiles = @(Get-ChildItem -Path $infraDir -Filter '*.bicep' -Recurse -ErrorAction SilentlyContinue)
    if ($bicepFiles.Count -eq 0) {
        return @{ Status = 'SKIP'; Message = "No .bicep files found in $infraDir — Bicep validation not applicable" }
    }

    if (-not (Test-Path $mainBicep)) {
        return @{
            Status  = 'FAIL'
            Message = "main.bicep not found at $mainBicep but other .bicep files exist — delegate to vibeshield-bicep agent to generate"
            Fix     = 'Delegate to the vibeshield-bicep agent to generate main.bicep as the entry point.'
        }
    }

    # Try to build the Bicep template
    $buildResult = Invoke-AzCommand 'bicep', 'build', '--file', $mainBicep
    if ($buildResult.ExitCode -eq 0) {
        # Clean up the generated ARM JSON (we only needed to verify it compiles)
        $armJson = $mainBicep -replace '\.bicep$', '.json'
        if (Test-Path $armJson) { Remove-Item $armJson -Force -ErrorAction SilentlyContinue }

        return @{ Status = 'PASS'; Message = 'Bicep templates compile successfully' }
    }

    # Parse error output for details
    $errorLines = ($buildResult.Output -split "`n" | Select-Object -First 5) -join "`n"
    return @{
        Status  = 'FAIL'
        Message = "Bicep build failed — delegate to vibeshield-bicep agent to repair. Errors: $errorLines"
        Fix     = 'Delegate to the vibeshield-bicep agent to fix the Bicep template. Pass the error output so it knows what to repair.'
    }
}

function Test-PipelineInfraAlignment {
    <# PP-06c — Verify pipeline deploy stages match workspace modules.
       Multi-module aware: reads Components[] from workspace manifest and validates
       each module's deploy stage matches that module's AppType.
       For EV2 pipelines: validates rollout stages reference correct ServiceGroupRoot.
       Falls back to single-AppType mode when manifest is unavailable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$AppType,
        [string]$PipelineYmlPath,
        [string]$InfraDeploy = ''
    )

    if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath }
    $fullYmlPath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
    if (-not (Test-Path $fullYmlPath)) {
        return @{ Status = 'SKIP'; Message = 'Pipeline YAML not found — cannot validate alignment' }
    }

    $pipelineContent = Get-Content $fullYmlPath -Raw
    if (-not $pipelineContent) {
        return @{ Status = 'SKIP'; Message = 'Pipeline YAML is empty' }
    }

    # ── EV2 pipelines: validate rollout stages ──────────────
    if ($InfraDeploy -eq 'EV2' -or (Test-IsEv2Pipeline -PipelineContent $pipelineContent)) {
        return Test-Ev2RolloutAlignment -PipelineContent $pipelineContent -WorkspacePath $WorkspacePath
    }

    $issues = @()

    # Deploy task patterns per AppType
    $expectedDeployPatterns = @{
        '.NET'             = 'AzureWebApp@1|AzureRmWebAppDeployment@4|webApp'
        'F#'               = 'AzureWebApp@1|AzureRmWebAppDeployment@4|webApp'
        'VB.NET'           = 'AzureWebApp@1|AzureRmWebAppDeployment@4|webApp'
        'Node.js backend'  = 'AzureWebApp@1|AzureRmWebAppDeployment@4|webApp'
        'Python'           = 'AzureWebApp@1|AzureRmWebAppDeployment@4|webApp'
        'Java'             = 'AzureWebApp@1|AzureRmWebAppDeployment@4|webApp'
        'Container'        = 'AzureContainerApps@1|ContainerApp|containerApp'
        'Go'               = 'AzureContainerApps@1|ContainerApp|containerApp'
        'Rust'             = 'AzureContainerApps@1|ContainerApp|containerApp'
        'Functions'        = 'AzureFunctionApp@2|AzureFunctionApp@1|functionApp'
        'Static frontend'  = 'AzureStaticWebApp@0|staticWebApp'
        'Static website'   = 'AzureStaticWebApp@0|staticWebApp'
    }

    # ── Try multi-module validation from workspace manifest ──
    $manifestPath = Join-Path -Path $WorkspacePath -ChildPath '.vibeshield/results/workspace-manifest.json'
    $modules = @()
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.PSObject.Properties['modules'] -and $manifest.modules) {
                $modules = @($manifest.modules)
            }
        } catch { <# manifest unreadable — fall back to single AppType #> $null = $_ }
    }

    if ($modules.Count -gt 0) {
        # ── Multi-module: validate each module's deploy stage ──
        foreach ($mod in $modules) {
            $modAppType = if ($mod.PSObject.Properties['appType']) { $mod.appType } else { '' }
            $modPath = if ($mod.PSObject.Properties['path']) { $mod.path } else { '.' }
            $modLabel = if ($modPath -eq '.') { 'Primary' } else { $modPath }

            # Determine expected stage name — uses path-based slug to match Build stage convention
            $isRoot = ($modPath -eq '.' -or $null -eq $modPath)
            $stageName = if ($isRoot) { 'Deploy' } else {
                $slug = $modPath -replace '[^a-zA-Z0-9]', '_'
                "Deploy_$slug"
            }

            # Check deploy stage exists for this module
            if ($pipelineContent -notmatch "(?mi)^\s*-\s*stage:\s*$([regex]::Escape($stageName))") {
                # Try generic Deploy stage for single-module
                if ($modules.Count -eq 1 -and $pipelineContent -match '(?mi)^\s*-\s*stage:\s*Deploy') {
                    # Single module with generic Deploy stage — OK
                } else {
                    $issues += "[$modLabel] No Deploy stage '$stageName' found for module"
                }
            }

            # Check deploy task matches this module's AppType
            if ($modAppType -and $expectedDeployPatterns.ContainsKey($modAppType)) {
                $deployPattern = $expectedDeployPatterns[$modAppType]
                if ($pipelineContent -notmatch $deployPattern) {
                    $issues += "[$modLabel] No deploy task matching AppType '$modAppType' found (expected: $deployPattern)"
                }
            }
        }
    } else {
        # ── Single-module fallback: use $AppType parameter ──
        if ($pipelineContent -notmatch '(?mi)^\s*-\s*stage:\s*Deploy') {
            $issues += 'Pipeline YAML has no Deploy stage — code will build but not deploy'
        }
        if ($AppType -and $expectedDeployPatterns.ContainsKey($AppType)) {
            $deployPattern = $expectedDeployPatterns[$AppType]
            if ($pipelineContent -notmatch $deployPattern) {
                $issues += "No deploy task matching AppType '$AppType' found (expected pattern: $deployPattern)"
            }
        }
    }

    # ── Bicep alignment (ARM only — EV2 returned early) ────
    $resolved  = Resolve-InfraPath -WorkspacePath $WorkspacePath -PipelineYmlPath $PipelineYmlPath
    $infraDir  = $resolved.InfraDir
    $hasBicep = (Test-Path $infraDir) -and @(Get-ChildItem -Path $infraDir -Filter '*.bicep' -ErrorAction SilentlyContinue).Count -gt 0

    if ($hasBicep) {
        if ($pipelineContent -notmatch 'AzureResourceManagerTemplateDeployment@3|az deployment group create|bicep|\.bicep') {
            $issues += "Bicep files exist in $infraDir but pipeline has no infrastructure deployment step"
        }

        # Check Bicep resource types match primary AppType
        if (Test-Path $infraDir) {
            $allBicepFiles = @(Get-ChildItem -Path $infraDir -Filter '*.bicep' -Recurse -ErrorAction SilentlyContinue)
            $bicepContent = ($allBicepFiles | ForEach-Object { Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n"
            if ($bicepContent) {
                $bicepResourceMap = @{
                    '.NET'             = 'Microsoft\.Web/sites'
                    'Node.js backend'  = 'Microsoft\.Web/sites'
                    'Python'           = 'Microsoft\.Web/sites'
                    'Java'             = 'Microsoft\.Web/sites'
                    'Container'        = 'Microsoft\.App/containerApps|Microsoft\.Web/sites'
                    'Go'               = 'Microsoft\.App/containerApps|Microsoft\.Web/sites'
                    'Rust'             = 'Microsoft\.App/containerApps|Microsoft\.Web/sites'
                    'Functions'        = 'Microsoft\.Web/sites'
                    'Static frontend'  = 'Microsoft\.Web/staticSites'
                    'Static website'   = 'Microsoft\.Web/staticSites'
                }

                # Check for each module's expected resource type
                $typesToCheck = if ($modules.Count -gt 0) {
                    @($modules | ForEach-Object { $_.appType } | Where-Object { $_ } | Sort-Object -Unique)
                } else { @($AppType) }

                foreach ($at in $typesToCheck) {
                    if ($at -and $bicepResourceMap.ContainsKey($at)) {
                        $resourcePattern = $bicepResourceMap[$at]
                        if ($bicepContent -notmatch $resourcePattern) {
                            $issues += "Bicep files do not provision expected resource for '$at' (expected: $resourcePattern)"
                        }
                    }
                }
            }
        }
    }

    if ($issues.Count -eq 0) {
        $modCount = if ($modules.Count -gt 0) { $modules.Count } else { 1 }
        return @{ Status = 'PASS'; Message = "Pipeline deploy stages, Bicep resources, and AppType(s) are aligned ($modCount module(s))" }
    }

    return @{
        Status  = 'FAIL'
        Message = $issues -join '; '
        Fix     = 'Ensure pipeline YAML deploy tasks match your AppType and Bicep provisions the correct Azure resources. Delegate Bicep issues to vibeshield-bicep agent; re-run deploy-pipeline-author to regenerate pipeline YAML. Do NOT edit Bicep files directly.'
    }
}

function Test-Ev2RolloutAlignment {
    <# Validates EV2 rollout stages reference correct ServiceGroupRoot paths.
       Called by Test-PipelineInfraAlignment when InfraDeploy=EV2. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipelineContent,
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $issues = @()

    # Check ServiceGroupRoot directory exists
    $ev2Dirs = @(Get-ChildItem -Path $WorkspacePath -Directory -Filter 'ev2' -ErrorAction SilentlyContinue)
    $sgRoot = $null
    foreach ($d in $ev2Dirs) {
        $candidate = Join-Path -Path $d.FullName -ChildPath 'ServiceGroupRoot'
        if (Test-Path $candidate) { $sgRoot = $candidate; break }
    }

    if (-not $sgRoot) {
        $issues += 'EV2 pipeline detected but no ev2/ServiceGroupRoot directory found'
    } else {
        # Check RolloutSpec.json exists
        if (-not (Test-Path (Join-Path -Path $sgRoot -ChildPath 'RolloutSpec.json'))) {
            $issues += 'ev2/ServiceGroupRoot/RolloutSpec.json missing'
        }
        # Check ServiceModel.json exists
        if (-not (Test-Path (Join-Path -Path $sgRoot -ChildPath 'ServiceModel.json'))) {
            $issues += 'ev2/ServiceGroupRoot/ServiceModel.json missing'
        }
    }

    # Check pipeline references ServiceGroupRoot
    if ($PipelineContent -notmatch 'ServiceGroupRoot') {
        $issues += 'EV2 pipeline YAML does not reference ServiceGroupRoot'
    }

    if ($issues.Count -eq 0) {
        return @{ Status = 'PASS'; Message = 'EV2 rollout stages and ServiceGroupRoot artifacts are aligned' }
    }

    return @{
        Status  = 'WARN'
        Message = $issues -join '; '
        Fix     = 'Ensure ev2/ServiceGroupRoot/ contains RolloutSpec.json and ServiceModel.json. Delegate EV2 artifact issues to ev2-demo-agent.'
    }
}

function Test-Ev2AppNameConsistency {
    <# PP-02b (EV2) — Validate app names in ServiceModel.json match pipeline variables.
       Instead of SKIPping EV2 pipelines, checks that ServiceModel's serviceGroup
       and component names align with pipeline variable definitions. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipelineContent,
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $issues = @()

    # Find ServiceModel.json
    $smPath = $null
    $ev2Dirs = @(Get-ChildItem -Path $WorkspacePath -Directory -Filter 'ev2' -ErrorAction SilentlyContinue)
    foreach ($d in $ev2Dirs) {
        $candidate = Join-Path -Path $d.FullName -ChildPath 'ServiceGroupRoot' 'ServiceModel.json'
        if (Test-Path $candidate) { $smPath = $candidate; break }
    }

    if (-not $smPath) {
        return @{ Status = 'SKIP'; Message = 'EV2 pipeline but no ServiceModel.json found — cannot validate app names' }
    }

    try {
        $serviceModel = Get-Content $smPath -Raw | ConvertFrom-Json
    } catch {
        return @{ Status = 'WARN'; Message = "ServiceModel.json is malformed JSON: $_" }
    }

    # Extract component names from ServiceModel
    $componentNames = @()
    if ($serviceModel.PSObject.Properties['serviceGroup'] -and
        $serviceModel.serviceGroup.PSObject.Properties['serviceResources']) {
        foreach ($res in $serviceModel.serviceGroup.serviceResources) {
            if ($res.PSObject.Properties['name']) {
                $componentNames += $res.name
            }
        }
    }

    if ($componentNames.Count -eq 0) {
        return @{ Status = 'WARN'; Message = 'ServiceModel.json has no serviceResources with names — cannot validate consistency' }
    }

    # Check that each ServiceModel component name appears in pipeline YAML
    foreach ($comp in $componentNames) {
        $found = $PipelineContent -match [regex]::Escape($comp)
        if (-not $found) {
            $issues += "ServiceModel component '$comp' not referenced in pipeline YAML — pipeline may target wrong app"
        }
    }

    if ($issues.Count -eq 0) {
        return @{ Status = 'PASS'; Message = "EV2 ServiceModel app names ($($componentNames.Count) component(s)) are referenced in pipeline YAML" }
    }

    return @{
        Status  = 'WARN'
        Message = $issues -join '; '
        Fix     = 'Ensure pipeline YAML variables reference the same component names defined in ServiceModel.json. Check that EV2 rollout artifacts align with the pipeline.'
    }
}

function Get-ChangesSummary {
    <# Summarize staged changes for commit messages and branch names.
       Returns a hashtable with:
         Summary   — one-line human-readable summary of what changed
         ShortSlug — sanitized slug suitable for branch names (max 40 chars) #>
    [CmdletBinding()]
    param()

    $diffResult = Invoke-GitCommand 'diff', '--cached', '--stat', '--stat-width=200'
    if (-not $diffResult.Output -or $diffResult.ExitCode -ne 0) {
        # Fall back to unstaged diff if nothing cached yet
        $diffResult = Invoke-GitCommand 'diff', '--stat', '--stat-width=200'
    }
    if (-not $diffResult.Output -or $diffResult.ExitCode -ne 0) {
        # Fall back to status
        $diffResult = Invoke-GitCommand 'status', '--porcelain'
    }

    $lines = @($diffResult.Output -split "`n" | Where-Object { $_ -match '\S' })
    if ($lines.Count -eq 0) {
        return @{ Summary = 'no changes detected'; ShortSlug = 'no-changes' }
    }

    # Parse changed file paths from diff --stat or status --porcelain
    $changedFiles = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*(\S+)\s*\|') {
            # diff --stat format: " path/to/file | 5 ++--"
            $changedFiles += $Matches[1].Trim()
        } elseif ($line -match '^[MADRCU?!\s]{1,2}\s+(.+)$') {
            # status --porcelain format: "M  path/to/file"
            $changedFiles += $Matches[1].Trim()
        }
    }

    if ($changedFiles.Count -eq 0) {
        return @{ Summary = 'misc changes'; ShortSlug = 'misc-changes' }
    }

    # Categorize changes by area
    $categories = @()
    $pipelineFiles = @($changedFiles | Where-Object { $_ -match '(?i)\.azdo|azure-pipeline|pipeline' })
    $infraFiles    = @($changedFiles | Where-Object { $_ -match '(?i)^infra/|\.bicep$|\.bicepparam$' })
    $srcFiles      = @($changedFiles | Where-Object { $_ -match '(?i)\.(cs|ts|js|py|java|go|rs|ps1|psm1)$' -and $_ -notmatch '(?i)test' })
    $testFiles     = @($changedFiles | Where-Object { $_ -match '(?i)test|spec' })
    $configFiles   = @($changedFiles | Where-Object { $_ -match '(?i)\.json$|\.ya?ml$|\.config$|\.env|\.gitignore' -and $_ -notmatch '(?i)pipeline' })

    if ($pipelineFiles.Count -gt 0) { $categories += 'pipeline' }
    if ($infraFiles.Count -gt 0)    { $categories += 'infra' }
    if ($srcFiles.Count -gt 0)      { $categories += 'src' }
    if ($testFiles.Count -gt 0)     { $categories += 'tests' }
    if ($configFiles.Count -gt 0)   { $categories += 'config' }

    if ($categories.Count -eq 0) { $categories = @('misc') }

    # Build summary
    $fileCount = $changedFiles.Count
    $catLabel = $categories -join '+'
    $summary = "$fileCount file(s) changed: $catLabel"

    # Build short slug for branch name (lowercase, alphanumeric+hyphens, max 40 chars)
    $slug = ($catLabel -replace '[^a-zA-Z0-9+]', '-' -replace '\+', '-').ToLower()
    $slug = $slug -replace '-{2,}', '-' -replace '^-|-$', ''
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) -replace '-$', '' }
    if (-not $slug) { $slug = 'changes' }

    return @{ Summary = $summary; ShortSlug = $slug }
}

function Test-BranchDrift {
    <# Detect drift between local branch HEAD and a remote branch.
       Returns a hashtable with:
         Drifted   — $true if local and remote have diverged (not fast-forwardable)
         Reason    — human-readable explanation
         LocalSha  — local HEAD SHA
         RemoteSha — remote HEAD SHA (or $null if remote doesn't exist) #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BranchName
    )

    $localSha = (Invoke-GitCommand 'rev-parse', 'HEAD').Output

    # Check if remote branch exists
    $remoteBranchCheck = Invoke-GitCommand 'ls-remote', '--heads', 'origin', $BranchName
    if (-not $remoteBranchCheck.Output) {
        return @{
            Drifted   = $false
            Reason    = "Remote branch 'origin/$BranchName' does not exist — no drift possible"
            LocalSha  = $localSha
            RemoteSha = $null
        }
    }

    # Fetch latest remote state
    Invoke-GitCommand 'fetch', 'origin', $BranchName 2>$null | Out-Null
    $remoteSha = (Invoke-GitCommand 'rev-parse', "origin/$BranchName").Output

    if ($localSha -eq $remoteSha) {
        return @{
            Drifted   = $false
            Reason    = 'Local and remote are at the same commit'
            LocalSha  = $localSha
            RemoteSha = $remoteSha
        }
    }

    # Check if local is ancestor of remote (remote is ahead — we can fast-forward)
    $localIsAncestor = (Invoke-GitCommand 'merge-base', '--is-ancestor', 'HEAD', "origin/$BranchName").ExitCode -eq 0
    # Check if remote is ancestor of local (local is ahead — push is fast-forward)
    $remoteIsAncestor = (Invoke-GitCommand 'merge-base', '--is-ancestor', "origin/$BranchName", 'HEAD').ExitCode -eq 0

    if ($remoteIsAncestor) {
        return @{
            Drifted   = $false
            Reason    = 'Local is ahead of remote — push is fast-forward'
            LocalSha  = $localSha
            RemoteSha = $remoteSha
        }
    }

    if ($localIsAncestor) {
        return @{
            Drifted   = $true
            Reason    = "Remote is ahead of local — local branch is behind by commits"
            LocalSha  = $localSha
            RemoteSha = $remoteSha
        }
    }

    # Neither is ancestor — true divergence
    return @{
        Drifted   = $true
        Reason    = 'Local and remote have diverged — neither is an ancestor of the other'
        LocalSha  = $localSha
        RemoteSha = $remoteSha
    }
}

function Remove-StaleDeployBranches {
    <# Clean up old local deploy/* branches created by this agent after a successful push.
       Only targets branches matching the agent's naming pattern (deploy/<slug>-<YYYYMMDD>-...)
       generated by New-InformativeBranchName. Never deletes user-created branches. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurrentBranch
    )

    # Pattern matches only branches created by New-InformativeBranchName:
    #   deploy/<appslug>-<YYYYMMDD>       (date-only)
    #   deploy/<appslug>-<YYYYMMDD>-<slug> (date + change slug / suffix)
    $agentBranchPattern = '^deploy/[a-z0-9-]+-\d{8}'

    $staleBranches = @(
        (Invoke-GitCommand 'branch', '--list', 'deploy/*').Output -split "`n" |
            ForEach-Object { $_.Trim().TrimStart('* ').Trim() } |
            Where-Object { $_ -and $_ -ne $CurrentBranch -and $_ -match $agentBranchPattern }
    )

    if ($staleBranches.Count -eq 0) {
        return @{ Removed = 0; Branches = @() }
    }

    $removed = @()
    foreach ($branch in $staleBranches) {
        $result = Invoke-GitCommand 'branch', '-D', $branch
        if ($result.ExitCode -eq 0) {
            $removed += $branch
        }
    }

    if ($removed.Count -gt 0) {
        Write-Output "  🧹 Cleaned up $($removed.Count) stale agent-created deploy branch(es)" | Out-Host
    }

    return @{ Removed = $removed.Count; Branches = $removed }
}

function New-InformativeBranchName {
    <# Generate an informative branch name for drift-triggered branch creation.
       Format: deploy/<apptype>-<YYYYMMDD>-<change-slug>
       Falls back to deploy/<apptype>-<YYYYMMDD>-<N> if slug is empty. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [string]$AppType = 'app',
        [string]$ChangeSlug = ''
    )

    # Normalize app type for branch name (lowercase, no spaces/dots, alphanumeric+hyphens)
    $appSlug = ($AppType -replace '[^a-zA-Z0-9]', '-').ToLower()
    $appSlug = $appSlug -replace '-{2,}', '-' -replace '^-|-$', ''
    if (-not $appSlug) { $appSlug = 'app' }

    $datePart = (Get-Date -Format 'yyyyMMdd')

    if ($ChangeSlug) {
        $candidate = "deploy/${appSlug}-${datePart}-${ChangeSlug}"
    } else {
        $candidate = "deploy/${appSlug}-${datePart}"
    }

    # Ensure no collision with existing remote branches — append -N suffix if needed
    $remoteBranchCheck = Invoke-GitCommand 'ls-remote', '--heads', 'origin', $candidate
    if (-not $remoteBranchCheck.Output) {
        return $candidate
    }

    $suffix = 2
    do {
        $tryName = "${candidate}-${suffix}"
        $tryCheck = Invoke-GitCommand 'ls-remote', '--heads', 'origin', $tryName
        if (-not $tryCheck.Output) { return $tryName }
        $suffix++
    } while ($suffix -le 20)

    # Fallback — very unlikely
    return "${candidate}-$(Get-Date -Format 'HHmmss')"
}

function Invoke-GitCommitChanges {
    <# PP-07 — Stage all and commit. Hook-aware: detects pre-commit/commit-msg
       hooks installed by other agents, reports them, waits for completion,
       and provides hook-specific failure guidance. Never uses --no-verify.
       When CommitMessage is the default placeholder, auto-generates a summary
       of the staged changes as the commit message. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommitMessage)

    # Auto-generate commit summary when using the default placeholder message
    $defaultMsg = (Get-DeployConfig).pipeline.defaultCommitMessage
    if ($CommitMessage -eq $defaultMsg) {
        $changeSummary = Get-ChangesSummary
        if ($changeSummary.Summary -ne 'no changes detected') {
            $CommitMessage = "chore(deploy): $($changeSummary.Summary)"
        }
    }

    $addResult = Invoke-GitCommand 'add', '-A'
    if ($addResult.ExitCode -ne 0) {
        return @{
            Status = 'FAIL'; Message = 'git add -A failed'
            Fix    = 'Check file permissions and disk space.'
        }
    }

    $statusResult = Invoke-GitCommand 'status', '--porcelain'
    if (-not $statusResult.Output) {
        $logResult = Invoke-GitCommand 'log', '-1', '--format=%s'
        return @{
            Status    = 'PASS'
            Message   = "Nothing new to commit (latest: $($logResult.Output))"
            CommitSha = ''
        }
    }

    # Re-generate summary from staged changes (now that git add -A has run)
    if ($CommitMessage -eq $defaultMsg) {
        $changeSummary = Get-ChangesSummary
        if ($changeSummary.Summary -ne 'no changes detected') {
            $CommitMessage = "chore(deploy): $($changeSummary.Summary)"
        }
    }

    # Detect commit-related hooks before running git commit
    $commitHooks = @(Get-InstalledGitHooks -HookNames @('pre-commit', 'commit-msg'))
    if ($commitHooks.Count -gt 0) {
        $hookList = ($commitHooks | ForEach-Object { $_.Name }) -join ', '
        Write-Output "  ℹ️ Git hook(s) detected: $hookList — waiting for hook(s) to complete..." | Out-Host
    }

    $commitResult = Invoke-GitCommand 'commit', '-m', $CommitMessage
    if ($commitResult.ExitCode -eq 0) {
        $shaResult = Invoke-GitCommand 'rev-parse', '--short', 'HEAD'
        return @{
            Status    = 'PASS'
            Message   = "Committed (SHA: $($shaResult.Output))"
            CommitSha = $shaResult.Output
        }
    }

    # Classify failure — hook vs. other git error
    $hookNames = @($commitHooks | ForEach-Object { $_.Name })
    if (Test-HookFailure -Output $commitResult.Output -ActiveHookNames $hookNames) {
        return @{
            Status      = 'FAIL'
            Message     = "A git hook blocked the commit: $($commitResult.Output)"
            Fix         = 'A pre-commit or commit-msg hook prevented the commit. Review the hook output above and fix the reported issues, then retry. Do NOT bypass hooks with --no-verify unless the user explicitly requests it.'
            HookFailure = $true
        }
    }

    return @{
        Status = 'FAIL'
        Message = "git commit failed: $($commitResult.Output)"
        Fix    = 'Check git config user.name and user.email are set.'
    }
}

function Invoke-GitPushChanges {
    <# PP-08 — Push to remote, handling non-fast-forward and protected branches.
       Hook-aware: detects pre-push hooks installed by other agents, reports them,
       waits for completion, and provides hook-specific failure guidance.
       Always pushes to a non-main branch. If BranchName is 'main', auto-creates
       'deploy/add-pipeline' feature branch instead. Never uses --no-verify.

       Drift-aware: When a StateBranchName is provided (from deploy-state.json),
       checks for drift between local HEAD and the recorded remote branch.
       If no drift, reuses the state branch. If drift detected, creates a new
       informative branch name based on AppType + date + change summary. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BranchName,
        [string]$AdoOrgUrl,
        [string]$AdoProject,
        [string]$StateBranchName = '',
        [string]$AppType = ''
    )

    # Guard: never push to governed branches or the remote default branch.
    # This prevents inadvertently overwriting production code and preserves
    # rollback capability to the last known-good codebase.
    $governedPatterns = @('main', 'master', 'release/*', 'production', 'staging')
    $isGoverned = $false
    foreach ($pattern in $governedPatterns) {
        if ($BranchName -like $pattern) { $isGoverned = $true; break }
    }

    # Detect the remote's actual default branch (may differ from 'main')
    $remoteHead = Invoke-GitCommand 'symbolic-ref', 'refs/remotes/origin/HEAD', '--short'
    $remoteDefaultBranch = ''
    if ($remoteHead.ExitCode -eq 0 -and $remoteHead.Output) {
        $remoteDefaultBranch = ($remoteHead.Output -replace '^origin/', '').Trim()
    }

    if (-not $isGoverned -and $remoteDefaultBranch -and $BranchName -eq $remoteDefaultBranch) {
        $isGoverned = $true
        Write-Output "  ⚠️ '$BranchName' is the remote default branch — treating as governed" | Out-Host
    }

    if ($isGoverned) {
        Write-Output "  ⚠️ VSD cannot push to governed branch '$BranchName' — creating feature branch instead" | Out-Host
        $changeSummary = Get-ChangesSummary
        $BranchName = New-InformativeBranchName -AppType $AppType -ChangeSlug $changeSummary.ShortSlug
        Write-Output "  🌿 Using feature branch '$BranchName'" | Out-Host
    }

    # Also guard: if local HEAD is currently on the default/governed branch,
    # ensure we checkout a feature branch BEFORE committing
    $currentBranchCheck = (Invoke-GitCommand 'rev-parse', '--abbrev-ref', 'HEAD').Output
    $isCurrentGoverned = $false
    foreach ($pattern in $governedPatterns) {
        if ($currentBranchCheck -like $pattern) { $isCurrentGoverned = $true; break }
    }
    if (-not $isCurrentGoverned -and $remoteDefaultBranch -and $currentBranchCheck -eq $remoteDefaultBranch) {
        $isCurrentGoverned = $true
    }
    if ($isCurrentGoverned -and $BranchName -ne $currentBranchCheck) {
        Write-Output "  ⚠️ Currently on governed branch '$currentBranchCheck' — switching to '$BranchName' before push" | Out-Host
    }

    # ── Drift-aware branch selection ───────────────────────
    # If a previous push recorded a branch in deploy-state.json, check for drift.
    # Reuse the recorded branch if no drift; create a new informative branch if drifted.
    if ($StateBranchName -and $StateBranchName -ne 'main') {
        $drift = Test-BranchDrift -BranchName $StateBranchName
        if (-not $drift.Drifted) {
            Write-Output "  ♻️ Reusing state branch '$StateBranchName' (no drift detected)" | Out-Host
            $BranchName = $StateBranchName
        } else {
            Write-Output "  ⚠️ Drift detected on state branch '$StateBranchName': $($drift.Reason)" | Out-Host
            $changeSummary = Get-ChangesSummary
            $BranchName = New-InformativeBranchName -AppType $AppType -ChangeSlug $changeSummary.ShortSlug
            Write-Output "  🌿 Creating new branch '$BranchName' due to drift" | Out-Host
        }
    } else {
        # No state branch — check for remote collision on the requested branch
        $remoteBranchCheck = Invoke-GitCommand 'ls-remote', '--heads', 'origin', $BranchName
        if ($remoteBranchCheck.Output) {
            # Remote branch exists — fetch and check ancestry
            Invoke-GitCommand 'fetch', 'origin', $BranchName 2>$null | Out-Null
            $mergeBase = Invoke-GitCommand 'merge-base', '--is-ancestor', 'HEAD', "origin/$BranchName"
            $ancestorOfRemote = ($mergeBase.ExitCode -eq 0)
            $mergeBase2 = Invoke-GitCommand 'merge-base', '--is-ancestor', "origin/$BranchName", 'HEAD'
            $remoteIsAncestor = ($mergeBase2.ExitCode -eq 0)

            if (-not $ancestorOfRemote -and -not $remoteIsAncestor) {
                # Divergent history — create informative branch instead of generic -vN
                $changeSummary = Get-ChangesSummary
                $newBranch = New-InformativeBranchName -AppType $AppType -ChangeSlug $changeSummary.ShortSlug
                Write-Output "  ⚠️ Remote branch '$BranchName' has divergent history — using '$newBranch' instead" | Out-Host
                $BranchName = $newBranch
            }
        }
    }

    # Ensure the local branch exists and is checked out
    $currentBranch = (Invoke-GitCommand 'rev-parse', '--abbrev-ref', 'HEAD').Output
    if ($currentBranch -ne $BranchName) {
        $checkoutResult = Invoke-GitCommand 'checkout', '-B', $BranchName
        if ($checkoutResult.ExitCode -ne 0) {
            return @{
                Status  = 'FAIL'
                Message = "Failed to create feature branch '$BranchName': $($checkoutResult.Output)"
                Fix     = 'Resolve any local branch conflicts and retry.'
            }
        }
        Write-Output "  Switched to branch $BranchName" | Out-Host
    }

    $shaResult = Invoke-GitCommand 'rev-parse', '--short', 'HEAD'
    $commitSha = $shaResult.Output

    $remoteBranch = Invoke-GitCommand 'ls-remote', '--heads', 'origin', $BranchName
    $pushArgs = if (-not $remoteBranch.Output) {
        @('push', '-u', 'origin', $BranchName)
    } else {
        @('push', 'origin', $BranchName)
    }

    # Detect pre-push hooks before running git push
    $pushHooks = @(Get-InstalledGitHooks -HookNames @('pre-push'))
    if ($pushHooks.Count -gt 0) {
        Write-Output "  ℹ️ Pre-push hook detected — waiting for hook to complete..." | Out-Host
    }

    $pushResult = Invoke-GitCommand @pushArgs
    if ($pushResult.ExitCode -eq 0) {
        # Verify the commit actually arrived on the remote
        $null = Invoke-GitCommand 'fetch', 'origin', $BranchName
        $remoteHead = (Invoke-GitCommand 'rev-parse', "origin/$BranchName").Output
        $localHead  = (Invoke-GitCommand 'rev-parse', $BranchName).Output
        if ($remoteHead -and $localHead -and $remoteHead -ne $localHead) {
            # Post-push divergence — auto-increment to a new branch instead of failing
            Write-Output "  ⚠️ Post-push divergence detected on '$BranchName' — remote HEAD differs from local. Auto-incrementing branch..." | Out-Host
            $changeSummary = Get-ChangesSummary
            $newBranch = New-InformativeBranchName -AppType $AppType -ChangeSlug $changeSummary.ShortSlug
            $checkoutResult = Invoke-GitCommand 'checkout', '-B', $newBranch
            if ($checkoutResult.ExitCode -ne 0) {
                return @{
                    Status     = 'FAIL'
                    Message    = "Post-push divergence on '$BranchName' and failed to create new branch '$newBranch': $($checkoutResult.Output)"
                    Fix        = 'Push to a new branch name by re-running the push script. Investigate why the remote branch diverged. Never delete the remote branch (prohibited by workspace rules).'
                    CommitSha  = $commitSha
                    BranchName = $BranchName
                }
            }
            $retryPush = Invoke-GitCommand 'push', '-u', 'origin', $newBranch
            if ($retryPush.ExitCode -eq 0) {
                Write-Output "  ✅ Auto-pushed to new branch '$newBranch' after divergence on '$BranchName'" | Out-Host
                return @{
                    Status     = 'PASS'
                    Message    = "Post-push divergence on '$BranchName' — auto-pushed to origin/$newBranch (SHA: $commitSha)"
                    CommitSha  = $commitSha
                    BranchName = $newBranch
                }
            }
            return @{
                Status     = 'FAIL'
                Message    = "Post-push divergence on '$BranchName' and retry push to '$newBranch' also failed: $($retryPush.Output)"
                Fix        = 'Push to a new branch name by re-running the push script. Investigate why the remote branch diverged. Never delete the remote branch (prohibited by workspace rules).'
                CommitSha  = $commitSha
                BranchName = $newBranch
            }
        }
        return @{
            Status     = 'PASS'
            Message    = "Pushed to origin/$BranchName (SHA: $commitSha)"
            CommitSha  = $commitSha
            BranchName = $BranchName
        }
    }

    $pushOut = $pushResult.Output

    # Check if push failure is hook-related before other classification
    $pushHookNames = @($pushHooks | ForEach-Object { $_.Name })
    if (Test-HookFailure -Output $pushOut -ActiveHookNames $pushHookNames) {
        return @{
            Status      = 'FAIL'
            Message     = "A pre-push hook blocked the push: $pushOut"
            Fix         = 'A pre-push hook prevented the push. Review the hook output above and fix the reported issues, then retry. Do NOT bypass hooks with --no-verify unless the user explicitly requests it.'
            HookFailure = $true
        }
    }

    # Non-fast-forward: rebase with local-wins strategy and retry once
    if ($pushOut -match 'non-fast-forward|rejected|fetch first') {
        # Fetch latest remote state
        Invoke-GitCommand 'fetch', 'origin', $BranchName | Out-Null
        # Rebase onto remote, keeping local changes on conflict (-X theirs means
        # "the branch being rebased wins" in rebase context, i.e. our local commits)
        $rebaseResult = Invoke-GitCommand 'rebase', '-X', 'theirs', "origin/$BranchName"
        if ($rebaseResult.ExitCode -ne 0) {
            # Abort any stuck rebase so the working tree is clean
            Invoke-GitCommand 'rebase', '--abort' | Out-Null
            return @{
                Status  = 'FAIL'
                Message = "Rebase failed: $($rebaseResult.Output)"
                Fix     = 'Check working tree state and retry.'
            }
        }
        $retryResult = Invoke-GitCommand 'push', 'origin', $BranchName
        if ($retryResult.ExitCode -eq 0) {
            $newSha = (Invoke-GitCommand 'rev-parse', '--short', 'HEAD').Output
            return @{
                Status     = 'PASS'
                Message    = "Pushed after rebase (SHA: $newSha)"
                CommitSha  = $newSha
                BranchName = $BranchName
            }
        }
        return @{
            Status  = 'FAIL'
            Message = "Push failed after rebase: $($retryResult.Output)"
            Fix     = 'Check authentication: az devops login or git credential manager.'
        }
    }

    # Protected branch: create feature branch + PR
    if ($pushOut -match 'protected branch|permission|denied') {
        $featureBranch = (Get-DeployConfig).pipeline.defaultBranchName
        Invoke-GitCommand 'checkout', '-b', $featureBranch | Out-Null
        $fbPush = Invoke-GitCommand 'push', 'origin', $featureBranch
        if ($fbPush.ExitCode -eq 0) {
            Invoke-AzCommand 'repos', 'pr', 'create', `
                '--source-branch', $featureBranch, '--target-branch', $BranchName, `
                '--title', 'Add 1ES deployment pipeline', `
                '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json' | Out-Null
            return @{
                Status     = 'WARN'
                Message    = "Branch $BranchName is protected. Pushed to $featureBranch and created PR."
                Fix        = 'Approve and merge the PR in Azure DevOps to trigger the pipeline.'
                CommitSha  = $commitSha
                BranchName = $featureBranch
            }
        }
        return @{
            Status  = 'FAIL'
            Message = "Push to feature branch also failed: $($fbPush.Output)"
            Fix     = 'Check repository permissions.'
        }
    }

    # Auth errors — treat 401/403 as auth; treat 400 as auth only when output
    # contains explicit auth/token indicators (AADSTS, oauth, bearer, token, etc.).
    # Plain HTTP 400 without auth keywords is NOT treated as auth — transport/proxy
    # errors also produce 400 and masking them as "Authentication failed" hides the
    # real push failure from callers.
    $isAuthFailure =
        ($pushOut -match '(?i)(auth|credential|unauthorized|forbidden)') -or
        ($pushOut -match '(?i)\b(401|403)\b') -or
        ( ($pushOut -match '(?i)\b400\b') -and
            ($pushOut -match '(?i)(AADSTS|oauth|bearer|token|authorization|auth|credential)') )

    if ($isAuthFailure) {
        # Clear stale token and retry once with a fresh token before failing.
        # Use inline cleanup instead of calling Clear-AdoGitTokenCache / Get-AdoGitToken
        # because older installed SharedHelpers versions may not define those functions.
        Write-Output "  ⚠️ Push auth failure detected — clearing token cache and retrying..." | Out-Host
        $global:AdoGitTokenCache = $null
        Remove-Item Env:GIT_CONFIG_COUNT   -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_CONFIG_KEY_0   -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue

        # Re-acquire ADO-scoped token (well-known resource ID + Corp tenant)
        $freshToken = $null
        $global:LASTEXITCODE = 0
        try {
            $freshToken = (& az account get-access-token `
                --tenant '72f988bf-86f1-41af-91ab-2d7cd011db47' `
                --resource '499b84ac-1321-427f-aa17-267ca6975798' `
                --query accessToken -o tsv 2>$null)?.Trim()
        } catch { $null = $_ }

        if ($freshToken -and $LASTEXITCODE -eq 0) {
            $global:AdoGitTokenCache = $freshToken
            $env:GIT_CONFIG_COUNT   = '1'
            $env:GIT_CONFIG_KEY_0   = 'http.extraHeader'
            $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $freshToken"

            # Re-check remote branch existence for current $BranchName (may have
            # changed since the original check due to drift/governed-branch logic)
            $retryRemoteCheck = Invoke-GitCommand 'ls-remote', '--heads', 'origin', $BranchName
            $retryArgs = if (-not $retryRemoteCheck.Output) {
                @('push', '-u', 'origin', $BranchName)
            } else {
                @('push', 'origin', $BranchName)
            }
            $retryResult = Invoke-GitCommand @retryArgs
            if ($retryResult.ExitCode -eq 0) {
                $newSha = (Invoke-GitCommand 'rev-parse', '--short', 'HEAD').Output
                return @{
                    Status     = 'PASS'
                    Message    = "Pushed after token refresh (SHA: $newSha)"
                    CommitSha  = $newSha
                    BranchName = $BranchName
                }
            }
            $pushOut = $retryResult.Output
        }
        return @{
            Status  = 'FAIL'
            Message = "Authentication failed: $pushOut"
            Fix     = 'az login was attempted automatically but failed. Verify your Azure CLI session (az login) and that the token audience is the ADO resource (499b84ac-1321-427f-aa17-267ca6975798). Then retry.'
        }
    }

    return @{
        Status  = 'FAIL'
        Message = "Push failed: $pushOut"
        Fix     = 'Check error message above and retry.'
    }
}

function Register-Pipeline {
    <# PP-09 — Register or reuse ADO pipeline definition. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoName', Justification='Used inside Invoke-WithRetry scriptblock closure')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'BranchName', Justification='Used inside Invoke-WithRetry scriptblock closure')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PipelineYmlPath', Justification='Used inside Invoke-WithRetry scriptblock closure')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipelineName,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter(Mandatory)][string]$PipelineYmlPath,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    # Use retry for transient ADO API failures (503, 429, timeout)
    $existingResult = $null
    try {
        $existingResult = Invoke-WithRetry -ScriptBlock {
            $r = Invoke-AzCommand 'pipelines', 'list', `
                '--org', $AdoOrgUrl, '--project', $AdoProject, `
                '--query', "[?name=='$PipelineName']", '-o', 'json'
            if ($r.ExitCode -ne 0 -and $r.Output -match '503|429|timed out|throttl') { throw $r.Output }
            $r
        } -MaxRetries 3
    } catch {
        $existingResult = [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 1 }
    }

    $pipelineUrl = ''
    $pipelineId  = $null
    if ($existingResult.ExitCode -eq 0 -and $existingResult.Output -and $existingResult.Output -ne '[]') {
        try {
            $existing = @($existingResult.Output | ConvertFrom-Json)
            if ($existing.Count -gt 0) {
                $pipelineId  = $existing[0].id
                $pipelineUrl = "$AdoOrgUrl/$AdoProject/_build?definitionId=$pipelineId"
            }
        } catch {
            Write-Warning "Failed to parse pipeline list JSON: $($_.Exception.Message)"
        }
        return @{
            Status      = 'PASS'
            Message     = "Pipeline '$PipelineName' already exists (reused)"
            PipelineUrl = $pipelineUrl
            PipelineId  = $pipelineId
        }
    }

    $createResult = $null
    try {
        $createResult = Invoke-WithRetry -ScriptBlock {
            $r = Invoke-AzCommand 'pipelines', 'create', `
                '--name', $PipelineName, '--repository', $RepoName, `
                '--repository-type', 'tfsgit', `
                '--branch', $BranchName, '--yml-path', $PipelineYmlPath, `
                '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json'
            if ($r.ExitCode -ne 0 -and $r.Output -match '503|429|timed out|throttl') { throw $r.Output }
            $r
        } -MaxRetries 3
    } catch {
        $createResult = [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 1 }
    }

    if ($createResult.ExitCode -eq 0) {
        try {
            $created     = $createResult.Output | ConvertFrom-Json
            $pipelineId  = $created.id
            $pipelineUrl = "$AdoOrgUrl/$AdoProject/_build?definitionId=$pipelineId"
        } catch {
            Write-Warning "Failed to parse pipeline create JSON: $($_.Exception.Message)"
        }
        return @{
            Status      = 'PASS'
            Message     = "Pipeline '$PipelineName' created in Azure DevOps"
            PipelineUrl = $pipelineUrl
            PipelineId  = $pipelineId
        }
    }

    return @{
        Status  = 'FAIL'
        Message = "Pipeline creation failed: $($createResult.Output)"
        Fix     = 'Check permissions: you need Build Administrator role in the ADO project.'
    }
}

function Test-PipelineDefinitionMatch {
    <#
    .SYNOPSIS Validates a reused pipeline definition's yamlPath and defaultBranch.
    .DESCRIPTION
        After PP-09 reuses an existing pipeline, this function queries the pipeline
        definition from ADO and verifies that its YAML path and default branch match
        the expected values. Returns PASS, WARN (mismatch), or SKIP (query failed).

        This guards against an attacker modifying the pipeline definition in ADO to
        point to a different YAML file or branch between deployments (threat §9.1
        in redeployment-flow-analysis.md).
    .PARAMETER PipelineId
        The numeric ADO pipeline definition ID.
    .PARAMETER ExpectedYamlPath
        Expected relative path to the pipeline YAML (e.g., '.azdo/pipelines/azure-pipeline.yml').
    .PARAMETER ExpectedBranch
        Expected branch name (e.g., 'deploy/add-pipeline').
    .PARAMETER AdoOrgUrl
        Azure DevOps organization URL.
    .PARAMETER AdoProject
        Azure DevOps project name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PipelineId,
        [Parameter(Mandatory)][string]$ExpectedYamlPath,
        [Parameter(Mandatory)][string]$ExpectedBranch,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    $warnings = @()

    # Query the pipeline definition
    $showResult = $null
    try {
        $showResult = Invoke-AzCommand 'pipelines', 'show', `
            '--id', "$PipelineId", `
            '--org', $AdoOrgUrl, '--project', $AdoProject, `
            '-o', 'json'
    } catch {
        return @{
            Status  = 'SKIP'
            Message = "Could not query pipeline definition (ID: $PipelineId): $($_.Exception.Message)"
        }
    }

    if (-not $showResult -or $showResult.ExitCode -ne 0) {
        return @{
            Status  = 'SKIP'
            Message = "Pipeline definition query failed (ID: $PipelineId)"
        }
    }

    $definition = $null
    try {
        $definition = $showResult.Output | ConvertFrom-Json
    } catch {
        return @{
            Status  = 'SKIP'
            Message = "Could not parse pipeline definition JSON"
        }
    }

    # Check yamlPath
    $adoYamlPath = ''
    if ($definition.PSObject.Properties['configuration']) {
        $config = $definition.configuration
        if ($config.PSObject.Properties['path']) {
            $adoYamlPath = $config.path
        }
    }

    $normalizedExpected = $ExpectedYamlPath.Replace('\', '/').TrimStart('/')
    $normalizedAdo = $adoYamlPath.Replace('\', '/').TrimStart('/')

    if ($normalizedAdo -and $normalizedExpected -and $normalizedAdo -ne $normalizedExpected) {
        $warnings += "YAML path mismatch: ADO definition points to '$adoYamlPath' but expected '$ExpectedYamlPath'. The pipeline may use a different YAML file than intended."
    }

    # Check defaultBranch
    $adoBranch = ''
    if ($definition.PSObject.Properties['configuration'] -and $definition.configuration.PSObject.Properties['repository']) {
        $repo = $definition.configuration.repository
        if ($repo.PSObject.Properties['defaultBranch']) {
            $adoBranch = $repo.defaultBranch -replace '^refs/heads/', ''
        }
    }

    if ($adoBranch -and $ExpectedBranch -and $adoBranch -ne $ExpectedBranch) {
        # This is informational — the pipeline will run from the pushed branch regardless of defaultBranch
        $warnings += "Default branch mismatch: ADO definition defaults to '$adoBranch' but push targets '$ExpectedBranch'. The triggered run will use '$ExpectedBranch' (correct)."
    }

    if ($warnings.Count -gt 0) {
        return @{
            Status  = 'WARN'
            Message = $warnings -join '; '
        }
    }

    return @{
        Status  = 'PASS'
        Message = "Pipeline definition verified: yamlPath='$normalizedAdo', branch='$adoBranch'"
    }
}

function Grant-ServiceConnectionAuthorization {
    <# PP-09b — Authorize the service connection for the pipeline definition.
       Delegates to Grant-ServiceConnectionAccess in SharedHelpers with SpecificPipeline scope. #>
    [Alias('Authorize-ServiceConnection')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScName,
        [Parameter(Mandatory)][int]$PipelineId,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject
    )

    return Grant-ServiceConnectionAccess -ScName $ScName -AdoOrgUrl $AdoOrgUrl -AdoProject $AdoProject `
        -Scope SpecificPipeline -PipelineId $PipelineId
}

function Confirm-PipelineTriggered {
    <# PP-10 — Verify a pipeline run was triggered, fall back to manual trigger.
       When CommitSha is provided, validates that the run's sourceVersion matches
       the pushed commit. Rejects stale runs from prior pushes. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PipelineName', Justification='Used inside Invoke-WithRetry scriptblock closure')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipelineName,
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter(Mandatory)][string]$AdoOrgUrl,
        [Parameter(Mandatory)][string]$AdoProject,
        [int]$PipelineId   = 0,
        [int]$WaitSeconds  = 30,
        [string]$CommitSha = ''
    )

    # Poll at intervals instead of fixed wait — return as soon as a run appears
    $pollInterval = 5
    $elapsed = 0
    $foundRun = $null
    $staleRunId = $null

    if ($PipelineId -le 0) {
        Write-Warning "PP-10: PipelineId not provided — run detection may match the wrong pipeline. Pass -PipelineId for reliable run verification."
    }

    while ($elapsed -lt $WaitSeconds) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval

        $pollArgs = @('pipelines', 'runs', 'list')
        if ($PipelineId -gt 0) { $pollArgs += '--pipeline-ids', "$PipelineId" }
        $pollArgs += '--branch', $BranchName, '--org', $AdoOrgUrl, '--project', $AdoProject,
            '--top', '1', '--query', '[0].{id:id, status:status, result:result, sourceVersion:sourceVersion}', '-o', 'json'

        $pollResult = Invoke-AzCommand @pollArgs
        if ($pollResult.ExitCode -eq 0 -and $pollResult.Output -and $pollResult.Output -ne 'null') {
            try {
                $run = $pollResult.Output | ConvertFrom-Json
                if ($run.id) {
                    # Validate sourceVersion matches pushed commit when CommitSha is known
                    if ($CommitSha -and $run.sourceVersion -and -not $run.sourceVersion.StartsWith($CommitSha)) {
                        $staleRunId = $run.id
                        # Stale run — keep polling for a new one
                        continue
                    }
                    $foundRun = $run
                    break
                }
            } catch {
                Write-Warning "Failed to parse pipeline run JSON: $($_.Exception.Message)"
            }
        }
    }

    if ($foundRun) {
        return @{
            Status          = 'PASS'
            Message         = "Pipeline run #$($foundRun.id) is $($foundRun.status) (detected after ${elapsed}s)"
            PipelineRunId   = $foundRun.id
            PipelineRunUrl  = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$($foundRun.id)&view=results"
        }
    }

    # Build query args for fallback — use --pipeline-ids when numeric ID is available (R2)
    $runListArgs = @('pipelines', 'runs', 'list')
    if ($PipelineId -gt 0) {
        $runListArgs += '--pipeline-ids', "$PipelineId"
    }
    $runListArgs += '--branch', $BranchName, '--org', $AdoOrgUrl, '--project', $AdoProject,
        '--top', '1', '--query', '[0].{id:id, status:status, result:result, sourceVersion:sourceVersion}', '-o', 'json'

    $runsResult = Invoke-AzCommand @runListArgs

    if ($runsResult.ExitCode -eq 0 -and $runsResult.Output -and $runsResult.Output -ne 'null') {
        try {
            $run = $runsResult.Output | ConvertFrom-Json
            if ($run.id) {
                # Reject stale run — sourceVersion doesn't match pushed commit
                if ($CommitSha -and $run.sourceVersion -and -not $run.sourceVersion.StartsWith($CommitSha)) {
                    $staleRunId = $run.id
                } else {
                    return @{
                        Status          = 'PASS'
                        Message         = "Pipeline run #$($run.id) is $($run.status)"
                        PipelineRunId   = $run.id
                        PipelineRunUrl  = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$($run.id)&view=results"
                    }
                }
            }
        } catch { <# Ignore JSON parse failures during pipeline run polling #> $null = $_ }
    }

    if ($staleRunId) {
        Write-Output "  ⚠️ Found run #$staleRunId but it was triggered by a different commit (stale). Triggering manually..." | Out-Host
    }

    # Fallback: manual trigger with retry (R9 — warn about CI misconfiguration)
    Write-Output "  No CI-triggered run found after ${WaitSeconds}s — CI trigger may be misconfigured. Triggering manually..." | Out-Host

    $triggerResult = $null
    try {
        $triggerResult = Invoke-WithRetry -ScriptBlock {
            $r = Invoke-AzCommand 'pipelines', 'run', `
                '--name', $PipelineName, '--branch', $BranchName, `
                '--org', $AdoOrgUrl, '--project', $AdoProject, '-o', 'json'
            if ($r.ExitCode -ne 0 -and $r.Output -match '503|429|timed out|throttl') { throw $r.Output }
            $r
        } -MaxRetries 3
    } catch {
        $triggerResult = [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 1 }
    }

    if ($triggerResult.ExitCode -eq 0) {
        try {
            $triggered = $triggerResult.Output | ConvertFrom-Json
            return @{
                Status          = 'PASS'
                Message         = "Pipeline run #$($triggered.id) manually triggered (CI trigger may be misconfigured)"
                PipelineRunId   = $triggered.id
                PipelineRunUrl  = "$AdoOrgUrl/$AdoProject/_build/results?buildId=$($triggered.id)&view=results"
            }
        } catch {
            Write-Warning "Failed to parse manual trigger JSON: $($_.Exception.Message)"
            return @{
                Status  = 'WARN'
                Message = "Manual trigger returned success but could not parse run ID: $($_.Exception.Message)"
                Fix     = 'Check the pipeline in Azure DevOps portal.'
            }
        }
    }

    return @{
        Status  = 'FAIL'
        Message = "No run appeared and manual trigger failed: $($triggerResult.Output)"
        Fix     = 'Check the CI trigger in azure-pipeline.yml matches the pushed branch.'
    }
}
