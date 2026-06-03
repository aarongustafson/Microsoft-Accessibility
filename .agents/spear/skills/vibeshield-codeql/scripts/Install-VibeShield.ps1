#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    CodeQL Vibe installer -- one-command setup for any project.

.DESCRIPTION
    Installs CodeQL Vibe agent files into the current workspace via sparse
    checkout from the source repo, copies template files for zero-LLM
    fast-path setup, wires CLAUDE.md, copilot-instructions.md, and AGENTS.md
    with idempotent marker blocks, and optionally triggers CodeQL setup
    via the first available CLI (Claude or Copilot).

    Auth: Uses Microsoft Entra OAuth access token (from Azure CLI) and injects it
    into Git via per-command -c flags (no process-wide credential leakage).

.PARAMETER Branch
    The branch or tag to pull from the source repo. Default: dev.

.PARAMETER ProjectPath
    The project directory to install into. Default: current directory.

.PARAMETER SkipSetup
    Install agent files only -- do not trigger CLI-driven CodeQL setup.

.PARAMETER Force
    Skip the interactive confirmation prompt before executing network-fetched scripts.

.PARAMETER CommitSHA
    Expected commit SHA of the cloned source. When provided, the installer verifies
    that the cloned repository HEAD matches this value before proceeding. Use this to
    pin installations to an immutable ref and prevent supply-chain attacks.

.PARAMETER SourceRepo
    Override the source repository URL.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -NoProfile -File Install-VibeShield.ps1

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -NoProfile -File Install-VibeShield.ps1 -Branch "release/2.0"

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -NoProfile -File Install-VibeShield.ps1 -SkipSetup
#>
[CmdletBinding()]
param(
    [string]$Branch = 'dev',
    [string]$ProjectPath = (Get-Location).Path,
    [switch]$SkipSetup,
    [switch]$Force,
    [string]$CommitSHA,
    [string]$SourceRepo = 'https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/CodeQL-Vibe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = $Force

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Vibeshield.CapabilityContract.psm1')

# ---------- helpers ----------

function Write-Step {
    param([int]$N, [int]$Total, [string]$Message)
    Write-Host '' -ForegroundColor Cyan
    Write-Host ('=' * 50) -ForegroundColor Cyan
    Write-Host " [$N/$Total] $Message" -ForegroundColor Cyan
    Write-Host ('=' * 50) -ForegroundColor Cyan
}

function Write-Pass { param([string]$Msg) Write-Host "[PASS] $Msg" -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }

function Resolve-UnzipTool {
    <#
    .SYNOPSIS
        Ensures the unzip utility is available on non-Windows platforms.
        On Windows, Expand-Archive handles extraction -- this is a no-op.
        On Linux/WSL/macOS, checks for unzip and attempts installation if missing.
    #>
    [CmdletBinding()]
    param()

    $isWindowsOS = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    if ($isWindowsOS) {
        return
    }

    $unzipCmd = Get-Command unzip -CommandType Application -ErrorAction SilentlyContinue
    if ($unzipCmd) {
        Write-Pass 'unzip: detected'
        return
    }

    Write-Warn 'unzip not found -- attempting installation...'

    $isMacOSHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX)

    if ($isMacOSHost) {
        # macOS ships with unzip; if missing, try Homebrew
        $brew = Get-Command brew -CommandType Application -ErrorAction SilentlyContinue
        if ($brew) {
            $global:LASTEXITCODE = 0
            & brew install unzip 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Get-Command unzip -CommandType Application -ErrorAction SilentlyContinue)) {
                Write-Pass 'unzip: installed via Homebrew'
                return
            }
        }
        throw 'unzip is not installed and could not be installed. Run: brew install unzip'
    }

    # Linux / WSL -- detect package manager and install
    $installed = $false
    $aptGet = Get-Command apt-get -CommandType Application -ErrorAction SilentlyContinue
    $dnf    = Get-Command dnf -CommandType Application -ErrorAction SilentlyContinue
    $yum    = Get-Command yum -CommandType Application -ErrorAction SilentlyContinue

    if ($aptGet) {
        Write-Host '  Installing unzip via apt-get...' -ForegroundColor DarkGray
        $global:LASTEXITCODE = 0
        & sudo apt-get install -y unzip 2>&1 | Out-Null
        $installed = ($LASTEXITCODE -eq 0)
    } elseif ($dnf) {
        Write-Host '  Installing unzip via dnf...' -ForegroundColor DarkGray
        $global:LASTEXITCODE = 0
        & sudo dnf install -y unzip 2>&1 | Out-Null
        $installed = ($LASTEXITCODE -eq 0)
    } elseif ($yum) {
        Write-Host '  Installing unzip via yum...' -ForegroundColor DarkGray
        $global:LASTEXITCODE = 0
        & sudo yum install -y unzip 2>&1 | Out-Null
        $installed = ($LASTEXITCODE -eq 0)
    } else {
        throw 'unzip is not installed and no supported package manager (apt-get, dnf, yum) was found. Install unzip manually and retry.'
    }

    if ($installed -and (Get-Command unzip -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Pass 'unzip: installed successfully'
    } else {
        throw 'unzip installation failed. Install unzip manually and retry.'
    }
}

function Get-AdoAccessToken {
    <#
    .SYNOPSIS
        Acquires an Azure DevOps access token via Azure CLI (Entra OAuth).
        Auto-triggers az login if not authenticated.
    #>
    $corpTenant = '72f988bf-86f1-41af-91ab-2d7cd011db47'
    $adoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'  # Azure DevOps resource ID
    $global:LASTEXITCODE = 0
    $token = $null

    try {
        $token = (az account get-access-token --resource $adoResourceId --tenant $corpTenant --query accessToken -o tsv 2>$null)?.Trim()
    } catch { $null = $_ }

    if (-not $token -or $LASTEXITCODE -ne 0) {
        Write-Host '  Not authenticated -- running az login...' -ForegroundColor Yellow

        $loginExpV2 = $null
        try { $loginExpV2 = (az config get core.login_experience_v2 --only-show-errors -o tsv 2>$null)?.Trim() } catch { $null = $_ }
        $loginExpV2WasOn = ($loginExpV2 -eq 'on')
        $loginExpV2WasUnset = (-not $loginExpV2)

        try { az config set core.login_experience_v2=off --only-show-errors 2>$null } catch { $null = $_ }

        $global:LASTEXITCODE = 0
        try {
            az login --allow-no-subscriptions --tenant $corpTenant --output none
        } catch {
            $global:LASTEXITCODE = 1
        }

        $loginExitCode = $LASTEXITCODE

        if ($loginExpV2WasOn) {
            try { az config set core.login_experience_v2=on --only-show-errors 2>$null } catch { $null = $_ }
        } elseif ($loginExpV2WasUnset) {
            try { az config unset core.login_experience_v2 --only-show-errors 2>$null } catch { $null = $_ }
        }

        if ($loginExitCode -ne 0) {
            throw 'az login failed or was cancelled. Authentication is required to continue.'
        }

        $global:LASTEXITCODE = 0
        $token = $null
        try {
            $token = (az account get-access-token --resource $adoResourceId --tenant $corpTenant --query accessToken -o tsv 2>$null)?.Trim()
        } catch { $null = $_ }
    }

    if (-not $token -or $LASTEXITCODE -ne 0) {
        throw 'Cannot acquire Azure DevOps access token. Verify Azure CLI and tenant access.'
    }

    return $token
}

# Resolve git binary path to avoid PowerShell name collision
$script:GitBin = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1)?.Source
if (-not $script:GitBin) {
    throw 'git is not installed or not found in PATH. Install Git (https://git-scm.com/) and try again.'
}

if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is not installed or not found in PATH. Install it (https://aka.ms/installazurecli) and try again.'
}

function Invoke-GitCommand {
    <#
    .SYNOPSIS
        Fully isolated git wrapper. Auth and configuration are injected via
        per-command -c flags -- no process-wide credential leakage.
        Matches the deploy/ev2 auth injection pattern.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter()]
        [string]$Cwd,

        [Parameter()]
        [string]$AdoToken,

        [Parameter()]
        [switch]$Capture
    )

    $cmd = @()
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) { $cmd += @('-C', $Cwd) }

    # Per-command isolation -- credential helper disabled per-invocation
    $cmd += @('-c', 'credential.helper=')

    # Inject bearer auth header without placing the token on the process command line.
    # Note: On Linux/macOS, argv is commonly visible via ps/procfs to other users.
    # We instead write a short-lived temp config file (restricted perms) and include it.
    $tempAuthConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($AdoToken)) {
        $tempAuthConfig = Join-Path ([System.IO.Path]::GetTempPath()) ('vibeshield-git-' + [System.IO.Path]::GetRandomFileName())
        Set-Content -Path $tempAuthConfig -Value "[http]`nextraHeader = AUTHORIZATION: bearer $AdoToken" -Encoding UTF8

        if ($IsLinux -or $IsMacOS) {
            $chmod = @(Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($chmod.Count -gt 0) { & $chmod[0].Source 600 $tempAuthConfig 2>$null | Out-Null }
        }

        $cmd += @('-c', "include.path=$tempAuthConfig")
    }

    $cmd += $ArgumentList

    # Suppress interactive prompts per-invocation with save/restore
    $prevGitPrompt = $env:GIT_TERMINAL_PROMPT
    $prevGcmInteractive = $env:GCM_INTERACTIVE
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'

        $global:LASTEXITCODE = 0
        if ($Capture) { return @(& $script:GitBin @cmd 2>&1) }
        & $script:GitBin @cmd | Out-Default
        return @()
    }
    finally {
        if ($null -eq $prevGitPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
        else { $env:GIT_TERMINAL_PROMPT = $prevGitPrompt }
        if ($null -eq $prevGcmInteractive) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue }
        else { $env:GCM_INTERACTIVE = $prevGcmInteractive }
        # Remove temp auth config file
        if ($tempAuthConfig -and (Test-Path $tempAuthConfig)) {
            Remove-Item -Path $tempAuthConfig -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-MarkerBlock {
    <#
    .SYNOPSIS
        Idempotent insert/replace of a delimited block in a Markdown file.
        Uses <!-- codeql-vibe start --> / <!-- codeql-vibe end --> markers.
        - If the marker block exists, replaces it (upgrade path).
        - If the file exists but has no marker, appends the block.
        - If the file does not exist, creates it with an optional header.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string]$Path,
        [string]$Snippet,
        [string]$Header = ''
    )
    $startMarker = '<!-- codeql-vibe start -->'
    $endMarker   = '<!-- codeql-vibe end -->'
    $block = "$startMarker`n$Snippet`n$endMarker"

    if (Test-Path $Path) {
        $content = Get-Content $Path -Raw -Encoding UTF8
        if ($content -match '(?s)<!-- codeql-vibe start -->.*?<!-- codeql-vibe end -->') {
            # Replace existing block (upgrade)
            $content = $content -replace '(?s)<!-- codeql-vibe start -->.*?<!-- codeql-vibe end -->', $block
            if ($PSCmdlet.ShouldProcess($Path, 'Update marker block')) {
                Set-Content -Path $Path -Value $content.TrimEnd() -Encoding UTF8
            }
            return 'updated'
        } else {
            # Append to existing file
            if ($PSCmdlet.ShouldProcess($Path, 'Append marker block')) {
                Add-Content -Path $Path -Value ("`n" + $block) -Encoding UTF8
            }
            return 'appended'
        }
    } else {
        # Create new file
        $value = if ($Header) { $Header.TrimEnd() + "`n`n" + $block } else { $block }
        if ($PSCmdlet.ShouldProcess($Path, 'Create marker block file')) {
            Set-Content -Path $Path -Value $value -Encoding UTF8
        }
        return 'created'
    }
}

function Convert-VibeShieldCodeQLErrorToMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ErrorText
    )

    if ($ErrorText -match 'az login failed') {
        return 'AUTH_FAILED: Azure CLI login failed or was cancelled'
    }
    if ($ErrorText -match 'Cannot acquire Azure DevOps access token') {
        return 'AUTH_TOKEN_UNAVAILABLE: Azure DevOps token acquisition failed'
    }
    if ($ErrorText -match 'git is not installed') {
        return 'PREREQ_MISSING: git executable not found'
    }
    if ($ErrorText -match 'Azure CLI.*is not installed') {
        return 'PREREQ_MISSING: Azure CLI (az) not found'
    }
    if ($ErrorText -match 'git 2\.25\+ required') {
        return 'PREREQ_GIT_VERSION_TOO_OLD: git 2.25 or later is required'
    }
    if ($ErrorText -match 'PowerShell 7\+ required') {
        return 'PREREQ_POWERSHELL_VERSION_TOO_OLD: PowerShell 7 or later is required'
    }
    if ($ErrorText -match 'unzip is not installed|unzip installation failed') {
        return 'PREREQ_MISSING: unzip not available'
    }
    if ($ErrorText -match 'git init failed') {
        return 'GIT_INIT_FAILED: git init failed'
    }
    if ($ErrorText -match 'git clone failed') {
        return 'GIT_CLONE_FAILED: source repository clone failed'
    }
    if ($ErrorText -match 'sparse checkout did not produce') {
        return 'SOURCE_GITHUB_MISSING: sparse checkout did not include GitHub assets'
    }
    if ($ErrorText -match 'Commit SHA mismatch') {
        return 'COMMIT_SHA_MISMATCH: cloned commit does not match pinned SHA'
    }
    if ($ErrorText -match 'Required files are missing') {
        return 'VERIFICATION_FAILED: required agent files missing after install'
    }

    return 'CODEQL_INSTALL_FAILED: install did not complete'
}

function Invoke-InstallVibeShieldCodeQL {
    [CmdletBinding()]
    param(
        [string]$Branch = 'dev',
        [string]$ProjectPath = (Get-Location).Path,
        [switch]$SkipSetup,
        [switch]$Force,
        [string]$CommitSHA,
        [string]$SourceRepo = 'https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/CodeQL-Vibe'
    )

    $null = $Force
    $isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    $isMacOSPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)

# ---------- pre-flight ----------

$totalSteps = 8
$startTime = Get-Date

$ProjectPath = Resolve-Path $ProjectPath
Push-Location $ProjectPath
$phase = 'initialize'

try {

Write-Host '' -ForegroundColor Cyan
Write-Host "  CodeQL Vibe Installer" -ForegroundColor Cyan
Write-Host "  =====================" -ForegroundColor Cyan
Write-Host "  Source: $SourceRepo" -ForegroundColor DarkGray
Write-Host "  Branch: $Branch" -ForegroundColor DarkGray
Write-Host "  Target: $ProjectPath" -ForegroundColor DarkGray
Write-Host ""

# Step 1: Validate prerequisites
$phase = 'prerequisites'
Write-Step -N 1 -Total $totalSteps -Message "Checking prerequisites..."

# Git (already resolved above via $script:GitBin)
$gitVer = & $script:GitBin --version 2>$null
if ($gitVer -match '(\d+)\.(\d+)') {
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 25)) {
        Write-Fail "git 2.25+ required for sparse-checkout (found: $gitVer)"
        throw "git 2.25+ required for sparse-checkout (found: $gitVer)"
    }
}
Write-Pass "git: $gitVer"

# PowerShell
$psVer = $PSVersionTable.PSVersion
if ($psVer.Major -lt 7) {
    Write-Fail "PowerShell 7+ required (found: $psVer)"
    throw "PowerShell 7+ required (found: $psVer)"
}
Write-Pass "PowerShell: $psVer"

# Azure CLI (validated in pre-flight above)
Write-Pass 'Azure CLI: detected'

# unzip (required on non-Windows platforms for CodeQL bundle extraction;
# Resolve-UnzipTool is a no-op on Windows where Expand-Archive handles it)
Resolve-UnzipTool

# Git repo check
if (-not (Test-Path '.git')) {
    Write-Warn 'Not a git repository -- initializing...'
    Invoke-GitCommand -ArgumentList @('init', '--quiet')
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'git init failed'
        throw 'git init failed'
    }
    Write-Pass 'git repository initialized'
} else {
    Write-Pass 'git repository detected'
}

# Step 2: Acquire Azure DevOps access token and sparse checkout (with local cache)
$phase = 'clone-source'
Write-Step -N 2 -Total $totalSteps -Message "Acquiring Azure DevOps token and pulling agent files (branch: $Branch)..."

$adoToken = Get-AdoAccessToken
Write-Pass 'Azure DevOps token acquired.'

# Clone cache -- avoids redundant network fetches when installing across
# multiple workspaces. Cached clones are reused for 1 hour (TTL).
$cacheTTLMinutes = 60
$safeBranch = ($Branch -replace '[^a-zA-Z0-9._-]', '_')
$cacheBaseDir = if ($isWindowsPlatform) {
    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [System.IO.Path]::GetTempPath()
    }
    Join-Path $localAppData 'CodeQL'
} elseif ($isMacOSPlatform) {
    Join-Path $HOME 'Library/Application Support/CodeQL'
} else {
    $xdg = $env:XDG_DATA_HOME
    if (-not $xdg) { $xdg = Join-Path $HOME '.local/share' }
    Join-Path $xdg 'CodeQL'
}
$cacheDir = Join-Path $cacheBaseDir (Join-Path 'agent-cache' $safeBranch)
$cacheStamp = Join-Path $cacheDir '.cache-timestamp'
$cacheGitHubDir = Join-Path $cacheDir '.github'
$useCache = $false

if ((Test-Path $cacheStamp) -and (Test-Path $cacheGitHubDir)) {
    try {
        $cacheAge = (Get-Date) - (Get-Item $cacheStamp).LastWriteTime
        if ($cacheAge.TotalMinutes -lt $cacheTTLMinutes) {
            $useCache = $true
            Write-Pass "Using cached agent files ($([math]::Round($cacheAge.TotalMinutes))m old, TTL=${cacheTTLMinutes}m)"
        } else {
            Write-Host "  Cache expired ($([math]::Round($cacheAge.TotalMinutes))m > ${cacheTTLMinutes}m) -- refreshing" -ForegroundColor DarkGray
        }
    } catch {
        Write-Warn "Cache check failed ($_) -- refreshing"
    }
}

if (-not $useCache) {
    # Fresh clone into cache directory
    if (Test-Path $cacheDir) {
        Remove-Item -Recurse -Force $cacheDir -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    $global:LASTEXITCODE = 0
    $cloneOutput = Invoke-GitCommand -ArgumentList @('clone', '--depth', '1', '--branch', $Branch, '--filter=blob:none', '--sparse', $SourceRepo, $cacheDir) -AdoToken $adoToken -Capture
    $cloneExit = $LASTEXITCODE

    if ($cloneExit -ne 0) {
        Write-Fail "git clone failed (branch: $Branch)"
        Write-Host "  $($cloneOutput | Out-String)" -ForegroundColor DarkGray
        # Clean up failed cache attempt
        Remove-Item -Recurse -Force $cacheDir -ErrorAction SilentlyContinue
        throw "git clone failed (branch: $Branch)"
    }

    $global:LASTEXITCODE = 0
    $sparseOutput = Invoke-GitCommand -ArgumentList @('sparse-checkout', 'set', '.github') -Cwd $cacheDir -AdoToken $adoToken -Capture
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'sparse checkout failed'
        Write-Host "  $($sparseOutput | Out-String)" -ForegroundColor DarkGray
    }

    if (-not (Test-Path $cacheGitHubDir)) {
        Write-Fail 'sparse checkout did not produce .github directory'
        Remove-Item -Recurse -Force $cacheDir -ErrorAction SilentlyContinue
        throw 'sparse checkout did not produce .github directory'
    }

    # Verify commit SHA if pinned (supply-chain integrity check)
    if (-not [string]::IsNullOrWhiteSpace($CommitSHA)) {
        $actualSHA = Invoke-GitCommand -ArgumentList @('rev-parse', 'HEAD') -Cwd $cacheDir -Capture
        $actualSHA = ($actualSHA | Out-String).Trim()
        if ($actualSHA -ne $CommitSHA) {
            Write-Fail "Commit SHA mismatch. Expected: $CommitSHA, Got: $actualSHA"
            Remove-Item -Recurse -Force $cacheDir -ErrorAction SilentlyContinue
            throw "Commit SHA mismatch. Expected: $CommitSHA, Got: $actualSHA"
        }
        Write-Pass "Commit SHA verified: $($actualSHA.Substring(0, 12))"
    }

    # Write cache timestamp
    Set-Content -Path $cacheStamp -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Pass "Agent files cloned and cached"
}

try {
    # Copy only agent artifact subdirectories into the workspace.
    # Root-level .github/ files (copilot-instructions.md, CODEOWNERS) are
    # NOT copied -- they belong to the consuming repo and are wired via
    # Set-MarkerBlock in later steps.
    if (-not (Test-Path '.github')) {
        New-Item -ItemType Directory -Path '.github' -Force | Out-Null
    }
    $agentDirs = @('agents', 'prompts', 'skills', 'hooks', 'instructions', 'templates')
    foreach ($dir in $agentDirs) {
        $src = Join-Path $cacheDir (Join-Path '.github' $dir)
        if (Test-Path $src) {
            $dest = Join-Path '.github' $dir
            if (-not (Test-Path $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Copy-Item -Recurse -Force (Join-Path $src '*') $dest
        }
    }
    Write-Pass "Agent files copied to .github/"
}
catch {
    Write-Fail "Failed to copy agent files from cache: $_"
    throw
}
finally {
    # Cache is NOT deleted -- it persists for reuse by other workspaces.
    # Only the .git directory inside the cache is cleaned to save disk space
    # (~50-100 MB of pack files). The .github/ content is kept for reuse.
    $cacheGit = Join-Path $cacheDir '.git'
    if (Test-Path $cacheGit) {
        Remove-Item -Recurse -Force $cacheGit -ErrorAction SilentlyContinue
    }
}

# Step 3: Copy template files (zero-LLM fast path)
$phase = 'copy-templates'
Write-Step -N 3 -Total $totalSteps -Message "Copying template files for fast-path setup..."

$templateDir = Join-Path '.github' (Join-Path 'templates' 'codeql')
$targetDir = Join-Path '.github' 'codeql'

if (Test-Path $templateDir) {
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $templateFiles = Get-ChildItem -Path $templateDir -File -Recurse -ErrorAction SilentlyContinue
    $templateRoot = (Resolve-Path $templateDir).Path
    $copied = 0
    foreach ($f in $templateFiles) {
        $relativePath = [IO.Path]::GetRelativePath($templateRoot, $f.FullName)
        $dest = Join-Path $targetDir $relativePath
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (-not (Test-Path $dest)) {
            Copy-Item $f.FullName $dest -Force
            $copied++
        }
    }

    if ($copied -gt 0) {
        Write-Pass "$copied template file(s) copied to $targetDir"
    } else {
        Write-Pass "Template files already present in $targetDir"
    }
} else {
    Write-Warn "No template directory found at $templateDir -- CLI-assisted setup will generate files"
}

# Write branch stamp so downstream hooks (pre-push) know which branch was used
$branchStampPath = Join-Path $targetDir '.install-branch'
Set-Content -Path $branchStampPath -Value $Branch -Encoding UTF8
Write-Pass "Branch stamp written: $Branch"

# Step 4: Verify required files
$phase = 'verify-installation'
Write-Step -N 4 -Total $totalSteps -Message "Verifying installation..."

$requiredFiles = @(
    (Join-Path '.github' (Join-Path 'agents' 'speckit.codeql.agent.md'))
)
$recommendedFiles = @(
    (Join-Path '.github' (Join-Path 'prompts' 'speckit.codeql.prompt.md'))
)

$allOk = $true
foreach ($f in $requiredFiles) {
    if (Test-Path $f) {
        Write-Pass "Required: $f"
    } else {
        Write-Fail "Required file missing: $f"
        $allOk = $false
    }
}
foreach ($f in $recommendedFiles) {
    if (Test-Path $f) {
        Write-Pass "Recommended: $f"
    } else {
        Write-Warn "Recommended file missing: $f (agent works without it)"
    }
}

if (-not $allOk) {
    Write-Fail 'Required files are missing. Installation incomplete.'
    throw 'Required files are missing. Installation incomplete.'
}

# Step 5: Wire CLAUDE.md
$phase = 'wire-claude'
Write-Step -N 5 -Total $totalSteps -Message "Configuring CLAUDE.md..."

$claudeSnippet = @"
## CodeQL

When asked about CodeQL, security scanning, pre-commit hooks, or vulnerability
remediation, follow the instructions in ``.github/agents/speckit.codeql.agent.md``.
"@

$claudeHeader = "# CLAUDE.md`n`nProject instructions for Claude."
$result = Set-MarkerBlock -Path 'CLAUDE.md' -Snippet $claudeSnippet -Header $claudeHeader
switch ($result) {
    'updated'  { Write-Pass "CLAUDE.md CodeQL section updated (upgrade)" }
    'appended' { Write-Pass "CodeQL section appended to CLAUDE.md" }
    'created'  { Write-Pass "CLAUDE.md created with CodeQL routing" }
}

# Step 6: Wire .github/copilot-instructions.md
$phase = 'wire-copilot'
Write-Step -N 6 -Total $totalSteps -Message "Configuring copilot-instructions.md..."

$copilotSnippet = @"
## CodeQL

For CodeQL setup, scanning, hooks, and vulnerability remediation, read and follow
``.github/agents/speckit.codeql.agent.md``. Use ``/speckit.codeql`` prompts for task routing.
"@

$copilotHeader = "# Copilot Instructions`n`nWorkspace-level instructions for GitHub Copilot."
$copilotPath = Join-Path '.github' 'copilot-instructions.md'
if (-not (Test-Path '.github')) { New-Item -ItemType Directory -Path '.github' -Force | Out-Null }
$result = Set-MarkerBlock -Path $copilotPath -Snippet $copilotSnippet -Header $copilotHeader
switch ($result) {
    'updated'  { Write-Pass "copilot-instructions.md CodeQL section updated (upgrade)" }
    'appended' { Write-Pass "CodeQL section appended to copilot-instructions.md" }
    'created'  { Write-Pass "copilot-instructions.md created with CodeQL routing" }
}

# Step 7: Wire AGENTS.md
$phase = 'wire-agents'
Write-Step -N 7 -Total $totalSteps -Message "Configuring AGENTS.md..."

$agentsSnippet = @"
## CodeQL Vibe

- **Agent file**: ``.github/agents/speckit.codeql.agent.md``
- **Prompt**: ``/speckit.codeql``
- **Purpose**: Non-bypassable CodeQL pre-commit hook for security scanning
- **Triggers**: CodeQL, security scanning, pre-commit hooks, vulnerability remediation
"@

$agentsHeader = "# Agents`n`nAvailable agents in this workspace."
$result = Set-MarkerBlock -Path 'AGENTS.md' -Snippet $agentsSnippet -Header $agentsHeader
switch ($result) {
    'updated'  { Write-Pass "AGENTS.md CodeQL Vibe section updated (upgrade)" }
    'appended' { Write-Pass "CodeQL Vibe section appended to AGENTS.md" }
    'created'  { Write-Pass "AGENTS.md created with CodeQL Vibe entry" }
}

# Step 8: Trigger CLI-driven setup (optional)
$phase = 'trigger-setup'
Write-Step -N 8 -Total $totalSteps -Message "Triggering CodeQL setup..."

if ($SkipSetup) {
    Write-Warn "Setup skipped (-SkipSetup). Run the agent manually:"
    Write-Host "  Copilot: /speckit.codeql Full Setup" -ForegroundColor Cyan
    Write-Host "  Claude:  Set up CodeQL" -ForegroundColor Cyan
} else {
    # Check for install.ps1 (fast path)
    $installScript = Join-Path '.github' (Join-Path 'codeql' 'install.ps1')
    if (Test-Path $installScript) {
        Write-Host "Running install.ps1 (fast path)..." -ForegroundColor Cyan
        if ($isWindowsPlatform) {
            & pwsh -ExecutionPolicy Bypass -NoProfile -File $installScript
        } else {
            & pwsh -NoProfile -File $installScript
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Pass "CodeQL setup completed via install.ps1"
        } else {
            Write-Warn "install.ps1 exited with code $LASTEXITCODE"
            Write-Host "  Try running the agent manually for guided setup." -ForegroundColor Yellow
        }
    } else {
        Write-Warn "install.ps1 not found -- use the agent for setup:"
        Write-Host "  Copilot: /speckit.codeql Full Setup" -ForegroundColor Cyan
        Write-Host "  Claude:  Set up CodeQL" -ForegroundColor Cyan
    }
}

# ---------- integrity manifest ----------
# Compute SHA-256 hashes of all deployed files so the agent can validate
# script integrity before execution. Runtime metadata files are excluded.
$phase = 'integrity-manifest'

if (Test-Path $targetDir) {
    $vibeshieldDir = Join-Path $ProjectPath '.vibeshield'
    if (-not (Test-Path $vibeshieldDir)) { New-Item -ItemType Directory -Path $vibeshieldDir -Force | Out-Null }
    $integrityPath = Join-Path $vibeshieldDir 'vibeshield-codeql.integrity-manifest.json'
    $integrityFiles = @{}
    $metaFiles = @('.install-branch', '.scan-lock',
                   'status.json', 'suppression-log.json', 'scan-history.json')

    $targetRoot = (Resolve-Path $targetDir).Path
    Get-ChildItem -Path $targetDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $metaFiles } |
        ForEach-Object {
            $relPath = [System.IO.Path]::GetRelativePath($targetRoot, $_.FullName)
            $relPath = ($relPath -replace '\\', '/')
            $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
            $integrityFiles[$relPath] = $hash
        }

    $integrityManifest = @{
        version   = 1
        algorithm = 'SHA256'
        created   = (Get-Date -Format 'o')
        branch    = $Branch
        files     = $integrityFiles
    } | ConvertTo-Json -Depth 3

    Set-Content -Path $integrityPath -Value $integrityManifest -Encoding UTF8
    Write-Pass "Integrity manifest: $($integrityFiles.Count) files hashed (SHA-256)"
}

# ---------- summary ----------

$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host " Installation complete ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor Green
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open VS Code in this directory" -ForegroundColor White
Write-Host "  2. Copilot: type /speckit.codeql in chat" -ForegroundColor White
Write-Host "  3. Claude:  ask 'Set up CodeQL'" -ForegroundColor White
Write-Host ""
Write-Host "Documentation: https://aka.ms/CELA-CODEQL" -ForegroundColor DarkGray

try {
    Set-VibeShieldCapabilityResult -Status ok -Message 'CodeQL Vibe agent files installed' -Details @{
        branch = $Branch
        target = $ProjectPath.ToString()
    }
} catch {
    # Standalone mode -- handshake env vars not set; success already printed above
    $null = $_
}

} # end try
catch {
    $classifiedMessage = Convert-VibeShieldCodeQLErrorToMessage -ErrorText $_.Exception.Message
    try {
        Set-VibeShieldCapabilityResult -Status fail -Message $classifiedMessage -Details @{ phase = $phase }
    } catch {
        # Standalone mode -- handshake env vars not set by orchestrator; surface the classified error directly
        Write-Fail $classifiedMessage
    }
    throw
}
finally {
    Pop-Location
}

} # end function Invoke-InstallVibeShieldCodeQL

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallVibeShieldCodeQL @PSBoundParameters
}
