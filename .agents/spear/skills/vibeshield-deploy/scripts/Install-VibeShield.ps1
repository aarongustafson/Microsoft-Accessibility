#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Installs VibeShield-Deploy .github assets into the current project.

.DESCRIPTION
    Sparse-checkouts only the .github/ folder from VibeShield-Deploy and merges
    VSD-owned subfolders into the target project.

    Auth: Uses Microsoft Entra OAuth access token from Azure CLI and injects it
    into Git via HTTP Authorization bearer header for Azure Repos Git.

.PARAMETER Branch
    Branch to pull from. Default: dev

.PARAMETER ProjectPath
    Target project root. Default: current directory

.EXAMPLE
    .\Install-VibeShield.ps1 -Branch 'feature/seguriluvan/1.0.0'

.EXAMPLE
    .\Install-VibeShield.ps1 -Branch main -ProjectPath 'C:\projects\MyApp'
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Branch = 'dev',

    [Parameter()]
    [string]$ProjectPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Vibeshield.CapabilityContract.psm1')

$script:DeployRepoUrl = 'https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeShield-Deploy'
$script:GitBin = $null

function Write-DeployStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Output $Message
}

function Invoke-AzCli {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter()]
        [switch]$Capture
    )

    $global:LASTEXITCODE = 0
    if ($Capture) {
        return @(az @Arguments 2>$null)
    }

    az @Arguments 2>$null
    return @()
}

function Test-DeployPrerequisite {
    [CmdletBinding()]
    param()

    $gitCommand = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
    if ($gitCommand.Count -eq 0) {
        throw 'PREREQ_MISSING: git'
    }

    $azCommand = @(Get-Command az -CommandType Application -ErrorAction SilentlyContinue)
    if ($azCommand.Count -eq 0) {
        throw 'PREREQ_MISSING: az'
    }

    $script:GitBin = $gitCommand[0].Source

    $gitVer = & $script:GitBin --version 2>$null
    if ($gitVer -match '(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 25)) {
            throw "PREREQ_GIT_VERSION_TOO_OLD: git 2.25+ required for sparse-checkout (found: $gitVer)"
        }
    }

    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -lt 7) {
        throw "PREREQ_POWERSHELL_VERSION_TOO_OLD: PowerShell 7+ required (found: $psVer)"
    }
}

function Get-AdoAccessToken {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $corpTenant = '72f988bf-86f1-41af-91ab-2d7cd011db47'
    $tokenArguments = @(
        'account', 'get-access-token',
        '--resource', '499b84ac-1321-427f-aa17-267ca6975798',
        '--tenant', $corpTenant,
        '--query', 'accessToken',
        '-o', 'tsv'
    )

    $token = $null
    try {
        $tokenResult = @(Invoke-AzCli -Arguments $tokenArguments -Capture)
        $token = ($tokenResult -join '').Trim()
    } catch {
        Write-Verbose -Message 'Azure CLI token acquisition failed before login.'
    }

    if ([string]::IsNullOrWhiteSpace($token) -or $LASTEXITCODE -ne 0) {
        Write-Output '  Not authenticated - running az login...'

        $loginExpV2 = $null
        try {
            $loginExpV2Result = @(Invoke-AzCli -Arguments @('config', 'get', 'core.login_experience_v2', '--only-show-errors', '-o', 'tsv') -Capture)
            $loginExpV2 = ($loginExpV2Result -join '').Trim()
        } catch {
            Write-Verbose -Message 'Azure CLI config read failed before login.'
        }
        $loginExpV2WasOn = ($loginExpV2 -eq 'on')

        try {
            Invoke-AzCli -Arguments @('config', 'set', 'core.login_experience_v2=off', '--only-show-errors') | Out-Null
        } catch {
            Write-Verbose -Message 'Azure CLI login experience setting could not be disabled.'
        }

        try {
            Invoke-AzCli -Arguments @('login', '--allow-no-subscriptions', '--tenant', $corpTenant, '--output', 'none') | Out-Null
        } catch {
            $global:LASTEXITCODE = 1
        }

        if ($loginExpV2WasOn) {
            try {
                Invoke-AzCli -Arguments @('config', 'set', 'core.login_experience_v2=on', '--only-show-errors') | Out-Null
            } catch {
                Write-Verbose -Message 'Azure CLI login experience setting could not be restored.'
            }
        }

        if ($LASTEXITCODE -ne 0) {
            throw 'AUTH_FAILED: azure-cli'
        }

        $token = $null
        try {
            $tokenResult = @(Invoke-AzCli -Arguments $tokenArguments -Capture)
            $token = ($tokenResult -join '').Trim()
        } catch {
            Write-Verbose -Message 'Azure CLI token acquisition failed after login.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($token) -or $LASTEXITCODE -ne 0) {
        throw 'AUTH_TOKEN_UNAVAILABLE: azure-cli'
    }

    return $token
}

function Invoke-GitCommand {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter()]
        [string]$Cwd,

        [Parameter()]
        [string]$AdoToken,

        [Parameter()]
        [switch]$Capture
    )

    if ([string]::IsNullOrWhiteSpace($script:GitBin)) {
        throw 'PREREQ_MISSING: git'
    }

    $commandArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $commandArgs += @('-C', $Cwd)
    }

    $commandArgs += @('-c', 'credential.helper=')

    if (-not [string]::IsNullOrWhiteSpace($AdoToken)) {
        $commandArgs += @('-c', "http.extraheader=AUTHORIZATION: bearer $AdoToken")
    }

    $commandArgs += $ArgumentList

    $global:LASTEXITCODE = 0
    if ($Capture) {
        return @(& $script:GitBin @commandArgs 2>&1)
    }

    & $script:GitBin @commandArgs | Out-Default
    return @()
}

function Resolve-DeployWorkingDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    $vibeshieldDir = Join-Path -Path $ProjectPath -ChildPath '.vibeshield'
    $workRoot = Join-Path -Path $vibeshieldDir -ChildPath 'work'
    $leaf = 'vibeshield-deploy-{0}' -f ([System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    return Join-Path -Path $workRoot -ChildPath $leaf
}

function Clear-DeployEnvironment {
    [CmdletBinding()]
    param()

    Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
}

function Get-DeployFailureInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $errorMessage = $ErrorRecord.Exception.Message
    $safeMessage = 'UNEXPECTED_FAILURE'
    $category = 'unexpected'

    if ($errorMessage -match '^TARGET_PATH_MISSING$') {
        $safeMessage = 'TARGET_PATH_MISSING'
        $category = 'input'
    } elseif ($errorMessage -match '^PREREQ_MISSING: (git|az)$') {
        $safeMessage = $Matches[0]
        $category = 'prerequisite'
    } elseif ($errorMessage -match '^AUTH_(FAILED|TOKEN_UNAVAILABLE): azure-cli$') {
        $safeMessage = $Matches[0]
        $category = 'auth'
    } elseif ($errorMessage -match '^FETCH_FAILED$') {
        $safeMessage = 'FETCH_FAILED'
        $category = 'source-fetch'
    } elseif ($errorMessage -match '^CHECKOUT_FAILED$') {
        $safeMessage = 'CHECKOUT_FAILED'
        $category = 'source-checkout'
    } elseif ($errorMessage -match '^SOURCE_GITHUB_MISSING$') {
        $safeMessage = 'SOURCE_GITHUB_MISSING'
        $category = 'source-layout'
    } elseif ($errorMessage -match '^PREREQ_GIT_VERSION_TOO_OLD:') {
        $safeMessage = 'PREREQ_GIT_VERSION_TOO_OLD'
        $category = 'prerequisite'
    } elseif ($errorMessage -match '^PREREQ_POWERSHELL_VERSION_TOO_OLD:') {
        $safeMessage = 'PREREQ_POWERSHELL_VERSION_TOO_OLD'
        $category = 'prerequisite'
    }

    return @{
        Message = $safeMessage
        Details = @{
            phase = $Phase
            category = $category
        }
    }
}

function Update-DeployConfigAdoSection {
    <#
    .SYNOPSIS
        Overwrites the ADO section in deploy-config.json with the target project's
        git remote coordinates, preventing VSD scripts from accidentally targeting
        the source repo.
    .OUTPUTS
        [string] 'updated', 'skipped-no-config', or 'skipped-no-remote'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [string]$DestGitHub
    )

    $deployConfigPath = Join-Path -Path $DestGitHub -ChildPath (Join-Path 'config' 'deploy-config.json')
    if (-not (Test-Path -LiteralPath $deployConfigPath)) {
        Write-Output '  SKIP: deploy-config.json not found'
        return 'skipped-no-config'
    }

    $targetOrgUrl = $null
    $targetProject = $null
    $targetRepoName = $null
    try {
        $remoteOutput = @(Invoke-GitCommand -ArgumentList @('remote', 'get-url', 'origin') -Cwd $ProjectPath -Capture)
        $remoteUrl = ($remoteOutput -join '').Trim()
        if ($remoteUrl -match 'dev\.azure\.com/([^/]+)/([^/]+)/_git/(.+)') {
            $targetOrgUrl = "https://dev.azure.com/$($Matches[1])"
            $targetProject = $Matches[2]
            $targetRepoName = $Matches[3]
        } elseif ($remoteUrl -match '([^@]+)@ssh\.dev\.azure\.com.*?/([^/]+)/([^/]+)/(.+)') {
            $targetOrgUrl = "https://dev.azure.com/$($Matches[2])"
            $targetProject = $Matches[3]
            $targetRepoName = $Matches[4]
        }
    } catch {
        Write-Verbose -Message 'Could not read git remote for deploy-config.json override.'
    }

    if ([string]::IsNullOrWhiteSpace($targetOrgUrl) -or [string]::IsNullOrWhiteSpace($targetProject)) {
        Write-Output '  SKIP: No Azure DevOps git remote found -- deploy-config.json ADO section unchanged'
        return 'skipped-no-remote'
    }

    try {
        $dcContent = Get-Content -Path $deployConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $dcContent.ado.defaultOrgUrl = $targetOrgUrl
        $dcContent.ado.defaultProject = $targetProject
        if (-not [string]::IsNullOrWhiteSpace($targetRepoName)) {
            $dcContent.ado.sourceRepoUrl = "$targetOrgUrl/$targetProject/_git/$targetRepoName"
        }
        $dcContent | ConvertTo-Json -Depth 10 | Set-Content -Path $deployConfigPath -Encoding utf8
        Write-Output "  UPDATED: deploy-config.json ADO section -> $targetOrgUrl/$targetProject"
        return 'updated'
    } catch {
        Write-Warning "Could not update deploy-config.json ADO section: $($_.Exception.Message)"
        return 'skipped-no-config'
    }
}

function Invoke-InstallVibeShieldDeploy {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Branch = 'dev',

        [Parameter()]
        [string]$ProjectPath = (Get-Location).Path
    )

    $phase = 'initialize'
    $tempDir = $null

    try {
        $phase = 'validate-target'
        if (-not (Test-Path -LiteralPath $ProjectPath)) {
            throw 'TARGET_PATH_MISSING'
        }
        $resolvedProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path

        $phase = 'prerequisites'
        Test-DeployPrerequisite

        $phase = 'initialize'
        $tempDir = Resolve-DeployWorkingDirectory -ProjectPath $resolvedProjectPath
        $tempParent = Split-Path -Path $tempDir -Parent
        New-Item -ItemType Directory -Path $tempParent -Force | Out-Null

        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'

        Write-Output "Target workspace : $resolvedProjectPath"
        Write-Output "Repository       : $script:DeployRepoUrl"
        Write-Output "Branch           : $Branch"
        Write-Output ''

        $phase = 'auth'
        Write-DeployStep -Message '[1/7] Acquiring Azure DevOps access token from Azure CLI...'
        $adoToken = Get-AdoAccessToken
        Write-Output '  Azure DevOps token acquired.'

        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'http.extraHeader'
        $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer $adoToken"

        $phase = 'sparse-checkout'
        Write-DeployStep -Message '[2/7] Initialising sparse checkout in work directory...'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Invoke-GitCommand -ArgumentList @('init', '--quiet') -Cwd $tempDir | Out-Null
        Invoke-GitCommand -ArgumentList @('remote', 'add', 'origin', $script:DeployRepoUrl) -Cwd $tempDir | Out-Null
        Invoke-GitCommand -ArgumentList @('config', 'core.sparseCheckout', 'true') -Cwd $tempDir | Out-Null
        Invoke-GitCommand -ArgumentList @('sparse-checkout', 'init', '--cone') -Cwd $tempDir | Out-Null
        Invoke-GitCommand -ArgumentList @('sparse-checkout', 'set', '.github') -Cwd $tempDir | Out-Null

        $phase = 'fetch'
        Write-DeployStep -Message "[3/7] Fetching branch '$Branch' (sparse, depth 1)..."
        $fetchOutput = @(Invoke-GitCommand -ArgumentList @('fetch', '--depth', '1', 'origin', $Branch) -Cwd $tempDir -Capture)
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose -Message ('git fetch failed with {0} output line(s).' -f $fetchOutput.Count)
            throw 'FETCH_FAILED'
        }

        $phase = 'checkout'
        Invoke-GitCommand -ArgumentList @('checkout', 'FETCH_HEAD', '--quiet') -Cwd $tempDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'CHECKOUT_FAILED'
        }
        Write-Output '  Fetch successful, checking out files...'

        $sourceGitHub = Join-Path -Path $tempDir -ChildPath '.github'
        if (-not (Test-Path -LiteralPath $sourceGitHub)) {
            throw 'SOURCE_GITHUB_MISSING'
        }

        $phase = 'copy-assets'
        Write-DeployStep -Message '[4/7] Copying VibeShield-Deploy files to .github/...'
        $destGitHub = Join-Path -Path $resolvedProjectPath -ChildPath '.github'
        if (-not (Test-Path -LiteralPath $destGitHub)) {
            New-Item -ItemType Directory -Path $destGitHub -Force | Out-Null
        }

        $vsdSubdirs = @('agents', 'config', 'prompts', 'scripts', 'skills', 'templates')
        $vsdCopiedCount = 0
        $script:copiedFileCount = 0

        foreach ($subdir in $vsdSubdirs) {
            $src = Join-Path -Path $sourceGitHub -ChildPath $subdir
            if (-not (Test-Path -LiteralPath $src)) {
                continue
            }

            $dest = Join-Path -Path $destGitHub -ChildPath $subdir
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }

            Get-ChildItem -Path $src -Force | ForEach-Object {
                if ($_.Name -like '*.Tests.ps1') {
                    return
                }

                if ($_.PSIsContainer) {
                    $srcFolder = $_.FullName
                    $destFolder = Join-Path -Path $dest -ChildPath $_.Name
                    $srcFolderRoot = (Resolve-Path -LiteralPath $srcFolder).Path
                    Get-ChildItem -Path $srcFolder -Recurse -Force | ForEach-Object {
                        $relativePath = [System.IO.Path]::GetRelativePath($srcFolderRoot, $_.FullName)
                        $targetPath = Join-Path -Path $destFolder -ChildPath $relativePath

                        if ($_.PSIsContainer) {
                            if (-not (Test-Path -LiteralPath $targetPath)) {
                                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                            }
                        } elseif ($_.Name -notlike '*.Tests.ps1') {
                            $targetDir = Split-Path -Path $targetPath -Parent
                            if (-not (Test-Path -LiteralPath $targetDir)) {
                                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                            }
                            Copy-Item -Path $_.FullName -Destination $targetPath -Force
                            $script:copiedFileCount++
                        }
                    }
                } else {
                    Copy-Item -Path $_.FullName -Destination $dest -Force
                    $script:copiedFileCount++
                }
            }
        }
        $vsdCopiedCount = $script:copiedFileCount
        $script:copiedFileCount = 0

        Write-Output ''
        Write-Output "Copied $vsdCopiedCount VSD file(s) into .github/"

        $phase = 'manifest'
        Write-DeployStep -Message '[5/7] Generating integrity manifest for VSD protected files...'
        $protectedFiles = @()
        foreach ($subdir in $vsdSubdirs) {
            $srcSubdirPath = Join-Path -Path $sourceGitHub -ChildPath $subdir
            if (-not (Test-Path -LiteralPath $srcSubdirPath)) {
                continue
            }

            $srcFiles = @(Get-ChildItem -Path $srcSubdirPath -Recurse -File |
                Where-Object { $_.Name -notlike '*.Tests.ps1' } |
                Where-Object {
                    $_.Name -like '*.ps1' -or
                    $_.Name -like '*.agent.md' -or
                    $_.Name -like '*.prompt.md' -or
                    $_.Name -eq 'SKILL.md'
                })

            foreach ($srcFile in $srcFiles) {
                $relFromSrcGitHub = [System.IO.Path]::GetRelativePath($sourceGitHub, $srcFile.FullName)
                $destFilePath = Join-Path -Path $destGitHub -ChildPath $relFromSrcGitHub
                if (Test-Path -LiteralPath $destFilePath) {
                    $protectedFiles += [System.IO.FileInfo]$destFilePath
                }
            }
        }

        $manifest = [ordered]@{
            version = '1.0'
            algorithm = 'SHA256'
            generatedAt = (Get-Date -Format 'o')
            branch = $Branch
            files = [ordered]@{}
        }

        foreach ($file in @($protectedFiles | Sort-Object FullName -Unique)) {
            $relativePath = [System.IO.Path]::GetRelativePath($resolvedProjectPath, $file.FullName).Replace('\', '/')
            $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
            $manifest.files[$relativePath] = $hash
        }

        $superHashInput = ($manifest.files.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "`n"
        $superHashBytes = [System.Text.Encoding]::UTF8.GetBytes($superHashInput)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifest['superHash'] = ($sha256.ComputeHash($superHashBytes) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        } finally {
            $sha256.Dispose()
        }

        $vibeshieldDir = Join-Path -Path $resolvedProjectPath -ChildPath '.vibeshield'
        if (-not (Test-Path -LiteralPath $vibeshieldDir)) {
            New-Item -ItemType Directory -Path $vibeshieldDir -Force | Out-Null
        }

        $manifestPath = Join-Path -Path $vibeshieldDir -ChildPath 'deploy-integrity-manifest.json'
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
        Write-Output "Generated integrity manifest with $(@($protectedFiles).Count) file(s)"
        Write-Output "  -> $manifestPath"

        $phase = 'snippets'
        Write-DeployStep -Message '[6/7] Inserting VibeShield-Deploy snippets into AGENTS.MD, CLAUDE.md, copilot-instructions.md, and .gitignore...'
        $snippetsDir = Join-Path -Path $sourceGitHub -ChildPath 'snippets'

        $agentsTarget = Get-ChildItem -Path $resolvedProjectPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'agents.md' } |
            Select-Object -First 1
        $agentsTargetPath = if ($null -ne $agentsTarget) { $agentsTarget.FullName } else { Join-Path -Path $resolvedProjectPath -ChildPath 'AGENTS.MD' }

        $snippetFiles = @(
            @{ Snippet = Join-Path -Path $snippetsDir -ChildPath 'agents.md'; Target = $agentsTargetPath; StartMarker = '<!-- vibeshield-deploy-start -->'; EndMarker = '<!-- vibeshield-deploy-end -->' }
            @{ Snippet = Join-Path -Path $snippetsDir -ChildPath 'CLAUDE.md'; Target = Join-Path -Path $resolvedProjectPath -ChildPath 'CLAUDE.md'; StartMarker = '# vibeshield-deploy-start'; EndMarker = '# vibeshield-deploy-end' }
            @{ Snippet = Join-Path -Path $snippetsDir -ChildPath 'copilot-instructions.md'; Target = Join-Path -Path $destGitHub -ChildPath 'copilot-instructions.md'; StartMarker = '<!-- vibeshield-deploy-start -->'; EndMarker = '<!-- vibeshield-deploy-end -->' }
            @{ Snippet = Join-Path -Path $snippetsDir -ChildPath 'gitignore'; Target = Join-Path -Path $resolvedProjectPath -ChildPath '.gitignore'; StartMarker = '# vibeshield-deploy-start'; EndMarker = '# vibeshield-deploy-end' }
        )

        foreach ($entry in $snippetFiles) {
            if (-not (Test-Path -LiteralPath $entry.Snippet)) {
                Write-Output "  SKIP: Snippet not found - $($entry.Snippet)"
                continue
            }

            $snippetContent = Get-Content -Path $entry.Snippet -Raw
            $targetName = Split-Path -Path $entry.Target -Leaf

            if (Test-Path -LiteralPath $entry.Target) {
                $existingContent = Get-Content -Path $entry.Target -Raw
                if ($existingContent -match [regex]::Escape($entry.StartMarker)) {
                    $pattern = '(?s)' + [regex]::Escape($entry.StartMarker) + '.*?' + [regex]::Escape($entry.EndMarker)
                    $updatedContent = [regex]::Replace($existingContent, $pattern, $snippetContent.TrimEnd())
                    Set-Content -Path $entry.Target -Value $updatedContent -NoNewline -Encoding utf8
                    Write-Output "  UPDATED: $targetName (replaced existing VibeShield-Deploy section)"
                } else {
                    $newContent = $existingContent.TrimEnd() + "`n`n" + $snippetContent
                    Set-Content -Path $entry.Target -Value $newContent -NoNewline -Encoding utf8
                    Write-Output "  APPENDED: $targetName (added VibeShield-Deploy section)"
                }
            } else {
                Set-Content -Path $entry.Target -Value $snippetContent -NoNewline -Encoding utf8
                Write-Output "  CREATED: $targetName"
            }
        }

        $phase = 'deploy-config'
        Update-DeployConfigAdoSection -ProjectPath $resolvedProjectPath -DestGitHub $destGitHub

        $phase = 'cleanup'
        Write-DeployStep -Message '[7/7] Cleaning up work directory...'
        if (-not [string]::IsNullOrWhiteSpace($tempDir)) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Output ''
        Write-Output "Done. VibeShield-Deploy .github/ installed into '$resolvedProjectPath'."

        try {
            Set-VibeShieldCapabilityResult -Status ok -Message 'VibeShield-Deploy assets installed' -Details @{
                copiedFileCount = $vsdCopiedCount
                protectedFileCount = @($protectedFiles).Count
                manifestGenerated = $true
            }
        } catch {
            # Standalone mode -- handshake env vars not set; success already printed above
            $null = $_
        }
        return
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($tempDir)) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $failureInfo = Get-DeployFailureInfo -ErrorRecord $_ -Phase $phase
        try {
            Set-VibeShieldCapabilityResult -Status fail -Message $failureInfo.Message -Details $failureInfo.Details
        } catch {
            # Standalone mode -- handshake env vars not set by orchestrator; surface the classified error directly
            Write-Warning $failureInfo.Message
        }
        throw
    } finally {
        Clear-DeployEnvironment
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallVibeShieldDeploy @PSBoundParameters
}


