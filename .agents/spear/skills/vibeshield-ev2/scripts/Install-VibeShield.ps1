#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Installs VibeShield-EV2 agent files into the target project workspace.

.DESCRIPTION
    Sparse-clones the ev2-demo-agent GitHub repository, copies agent, prompt,
    and resource files into the target project's .github/ directory, and wires
    the vibeshield-ev2 section into .github/copilot-instructions.md using
    idempotent marker blocks.

    Supports re-installation -- existing files are overwritten and the
    copilot-instructions marker block is replaced in-place.

    The source repository is private and requires GitHub CLI (gh)
    authentication with SAML SSO authorization. If gh is not installed,
    the script attempts to install it automatically. Authentication is
    mandatory -- the script will not attempt unauthenticated cloning.

.PARAMETER Branch
    Branch or tag to pull from the source repo. Default: main.

.PARAMETER ProjectPath
    Target project root directory. Default: current directory.

.EXAMPLE
    # Windows
    pwsh -ExecutionPolicy Bypass -NoProfile -File Install-VibeShield.ps1

.EXAMPLE
    # Linux / macOS / WSL
    pwsh -NoProfile -File Install-VibeShield.ps1

.EXAMPLE
    pwsh -NoProfile -File Install-VibeShield.ps1 -Branch "release/1.0"

.EXAMPLE
    pwsh -NoProfile -File Install-VibeShield.ps1 -ProjectPath "/home/user/projects/MyApp"
#>

[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $PSScriptRoot/Vibeshield.CapabilityContract.psm1

# ---------- helpers ----------

function Write-Step {
    param([int]$N, [int]$Total, [string]$Message)
    Write-Host ''                          -ForegroundColor Cyan
    Write-Host ('=' * 50)                  -ForegroundColor Cyan
    Write-Host " [$N/$Total] $Message"     -ForegroundColor Cyan
    Write-Host ('=' * 50)                  -ForegroundColor Cyan
}

function Write-Pass { param([string]$Msg) Write-Host "[PASS] $Msg" -ForegroundColor Green  }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red    }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }

function Open-BrowserUrl {
    <#
    .SYNOPSIS
        Opens a URL in the default browser. Handles WSL, Windows, macOS, and Linux.
    #>
    param([Parameter(Mandatory)][string]$Url)

    try {
        if ($script:RunOnWSL) {
            # Use explorer.exe instead of cmd.exe /c start to avoid both:
            #  - cmd.exe shell metacharacter injection (&, |, etc.)
            #  - PowerShell 7 Linux argument-passing that escapes quotes with
            #    backslashes (POSIX), which cmd.exe cannot parse.
            & explorer.exe $Url 2>$null
        } elseif ($script:RunOnWindows) {
            Start-Process $Url
        } elseif ($script:RunOnMacOS) {
            & open $Url 2>$null
        } else {
            $xdgOpen = Get-Command xdg-open -ErrorAction SilentlyContinue
            if ($xdgOpen) { & xdg-open $Url 2>$null }
        }
    } catch {
        $null = $_
    }
}

function Copy-ToClipboard {
    <#
    .SYNOPSIS
        Copies text to the system clipboard. Handles Windows, WSL, macOS, and Linux.
        Best-effort -- silently ignores failures so the install can continue.
    #>
    param([Parameter(Mandatory)][string]$Text)

    try {
        if ($script:RunOnWSL) {
            # PowerShell pipe to clip.exe is unreliable under WSL interop.
            # Use the Process API for explicit stdin control instead.
            $clipBin = (Get-Command clip.exe -ErrorAction SilentlyContinue)?.Source
            if (-not $clipBin) {
                $winClip = '/mnt/c/Windows/System32/clip.exe'
                if (Test-Path $winClip) { $clipBin = $winClip }
            }
            if ($clipBin) {
                $p = [System.Diagnostics.Process]::new()
                $p.StartInfo.FileName = $clipBin
                $p.StartInfo.UseShellExecute = $false
                $p.StartInfo.RedirectStandardInput = $true
                $null = $p.Start()
                $p.StandardInput.Write($Text)
                $p.StandardInput.Close()
                $exited = $p.WaitForExit(3000)
                if (-not $exited -and -not $p.HasExited) {
                    Write-Verbose 'clip.exe did not exit within timeout; killing process'
                    try { $p.Kill() } catch { $null = $_ }
                    $null = $p.WaitForExit(1000)
                }

                $p.Dispose()
            } else {
                Write-Verbose 'clip.exe not found -- clipboard not available on this WSL instance'
            }
        } elseif ($script:RunOnWindows) {
            Set-Clipboard -Value $Text
        } elseif ($script:RunOnMacOS) {
            $Text | pbcopy
        } else {
            $xclip = Get-Command xclip -ErrorAction SilentlyContinue
            if ($xclip) {
                $Text | & xclip -selection clipboard
            } else {
                $xsel = Get-Command xsel -ErrorAction SilentlyContinue
                if ($xsel) { $Text | & xsel --clipboard --input }
            }
        }
    } catch {
        # Clipboard is best-effort -- don't fail the install
        Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
    }
}

function Get-GitHubToken {
    <#
    .SYNOPSIS
        Acquires a GitHub access token via the GitHub CLI (gh).
        Auto-triggers gh auth login if not authenticated.
    #>
    $ghBin = (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1)?.Source

    if (-not $ghBin) {
        throw 'GitHub CLI (gh) is not installed or not found in PATH. Install it (https://cli.github.com/) and try again.'
    }

    $global:LASTEXITCODE = 0
    $token = $null

    try {
        $token = (& $ghBin auth token 2>$null)?.Trim()
    } catch { $null = $_ }

    if (-not $token -or $LASTEXITCODE -ne 0) {
        Write-Host '  Not authenticated to GitHub -- launching browser login...' -ForegroundColor Yellow

        # Open the device login page ourselves -- gh's browser detection
        # is unreliable on WSL (no wslview/xdg-open). We open the page
        # before calling gh so the browser is ready when the code appears.
        Open-BrowserUrl -Url 'https://github.com/login/device'

        # Set BROWSER env var so gh doesn't try cmd.exe /c start (which
        # fails on WSL due to PowerShell 7 argument-passing quoting).
        $prevBrowser = $env:BROWSER
        if ($script:RunOnWSL) { $env:BROWSER = 'explorer.exe' }

        $global:LASTEXITCODE = 0
        try {
            & $ghBin auth login --git-protocol https --web 2>&1 | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
                Write-Host $line
                if ($line -match 'code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})') {
                    Copy-ToClipboard -Text $Matches[1]
                    Write-Host '  >> One-time code copied to clipboard' -ForegroundColor Green
                }
            }
        } catch {
            $global:LASTEXITCODE = 1
        }
        finally {
            if ($script:RunOnWSL) { $env:BROWSER = $prevBrowser }
        }

        if ($LASTEXITCODE -ne 0) {
            throw 'gh auth login failed or was cancelled. GitHub authentication is required for private repositories.'
        }

        $global:LASTEXITCODE = 0
        $token = $null
        try {
            $token = (& $ghBin auth token 2>$null)?.Trim()
        } catch { $null = $_ }
    }

    if (-not $token -or $LASTEXITCODE -ne 0) {
        throw 'Cannot acquire GitHub token. Run "gh auth login" and try again.'
    }

    return $token
}

function Resolve-GitExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $gitBin = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($gitBin.Count -eq 0 -or [string]::IsNullOrWhiteSpace($gitBin[0].Source)) {
        throw 'PREREQ_GIT_MISSING: git executable not found'
    }

    return $gitBin[0].Source
}

function Invoke-GitVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$GitBin
    )

    return & $GitBin --version 2>$null
}

function Get-PowerShellRuntimeVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()

    return $PSVersionTable.PSVersion
}

function Test-GitHubCliAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $ghCommand = @(Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    return ($ghCommand.Count -gt 0)
}

function Install-GitHubCli {
    <#
    .SYNOPSIS
        Installs the GitHub CLI (gh) by downloading the prebuilt binary from
        GitHub releases into ~/.local/bin. No sudo or package manager required.
        On Windows, prints manual install instructions and returns $false.
    .OUTPUTS
        [bool] $true if gh was installed successfully, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($IsWindows) {
        Write-Warn 'Automatic gh install is not supported on Windows. Install from https://cli.github.com/'
        return $false
    }

    # Determine platform and architecture for the release tarball
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
    $ghArch = switch ($arch) {
        'x64'   { 'amd64' }
        'arm64' { 'arm64' }
        default { 'amd64' }
    }
    $ghOs = if ($IsMacOS) { 'macOS' } else { 'linux' }

    # Resolve latest version from GitHub API
    $ghVersion = $null
    try {
        $releaseInfo = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers @{ 'User-Agent' = 'vibeshield-installer' } -ErrorAction Stop
        if ($releaseInfo.tag_name -match 'v?(.+)') {
            $ghVersion = $Matches[1]
        }
    } catch {
        Write-Verbose -Message "GitHub API call failed: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($ghVersion)) {
        Write-Warn 'Could not determine latest gh version from GitHub API'
        return $false
    }

    $tarballName = "gh_${ghVersion}_${ghOs}_${ghArch}.tar.gz"
    $downloadUrl = "https://github.com/cli/cli/releases/download/v${ghVersion}/${tarballName}"

    # Install to user-local bin directory (no sudo required)
    $localBin = Join-Path -Path $HOME -ChildPath '.local' -AdditionalChildPath 'bin'
    if (-not (Test-Path $localBin)) {
        New-Item -ItemType Directory -Path $localBin -Force | Out-Null
    }

    $tempTar = Join-Path ([System.IO.Path]::GetTempPath()) $tarballName
    try {
        Write-Host "  Downloading gh $ghVersion ($ghOs/$ghArch)..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempTar -ErrorAction Stop

        Write-Host '  Extracting to ~/.local/bin...' -ForegroundColor Yellow
        $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ('gh-extract-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

        & tar -xzf $tempTar -C $tempExtract 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'tar extraction failed'
            return $false
        }

        # The tarball extracts to gh_<version>_<os>_<arch>/bin/gh
        $extractedBin = Join-Path -Path $tempExtract -ChildPath "gh_${ghVersion}_${ghOs}_${ghArch}" -AdditionalChildPath 'bin', 'gh'
        if (-not (Test-Path $extractedBin)) {
            Write-Warn "Expected binary not found at: $extractedBin"
            return $false
        }

        Copy-Item -Path $extractedBin -Destination (Join-Path $localBin 'gh') -Force
        & chmod +x (Join-Path $localBin 'gh') 2>$null

        # Add to PATH for this session if not already there
        if ($env:PATH -notlike "*$localBin*") {
            $env:PATH = "${localBin}:$env:PATH"
        }

        Write-Host "  gh $ghVersion installed to $localBin" -ForegroundColor Green
        return (Test-GitHubCliAvailable)
    } catch {
        Write-Warn "gh download/install failed: $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path $tempTar -ErrorAction SilentlyContinue) {
            Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
        }
        if ($tempExtract -and (Test-Path $tempExtract -ErrorAction SilentlyContinue)) {
            Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Convert-VibeShieldEv2ErrorToMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ErrorText
    )

    if ($ErrorText -match '^TARGET_PATH_MISSING:') {
        return 'TARGET_PATH_MISSING: target project path does not exist'
    }
    if ($ErrorText -match '^PREREQ_GIT_MISSING:') {
        return 'PREREQ_GIT_MISSING: git executable not found'
    }
    if ($ErrorText -match '^PREREQ_GIT_VERSION_TOO_OLD:') {
        return 'PREREQ_GIT_VERSION_TOO_OLD: git 2.25 or later is required'
    }
    if ($ErrorText -match '^PREREQ_POWERSHELL_VERSION_TOO_OLD:') {
        return 'PREREQ_POWERSHELL_VERSION_TOO_OLD: PowerShell 7 or later is required'
    }
    if ($ErrorText -match '^GIT_CLONE_FAILED:') {
        return 'GIT_CLONE_FAILED: source repository clone failed'
    }
    if ($ErrorText -match '^GIT_SPARSE_CHECKOUT_FAILED:') {
        return 'GIT_SPARSE_CHECKOUT_FAILED: sparse checkout failed'
    }
    if ($ErrorText -match '^SOURCE_GITHUB_MISSING:') {
        return 'SOURCE_GITHUB_MISSING: sparse checkout did not include GitHub assets'
    }
    if ($ErrorText -match '^GITHUB_AUTH_FAILED:') {
        return 'GITHUB_AUTH_FAILED: GitHub authentication failed'
    }
    if ($ErrorText -match '^GITHUB_AUTH_DECLINED:') {
        return 'GITHUB_AUTH_DECLINED: user declined GitHub login required to clone EV2 agent source repo -- re-run installer when ready'
    }

    return 'EV2_INSTALL_FAILED: install did not complete'
}

function Invoke-Git {
    <#
    .SYNOPSIS
        Fully isolated git wrapper. All configuration is injected via per-command
        -c flags so nothing leaks into the target workspace's git environment.
        Disables credential helpers, terminal prompts, and GCM interactive mode.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$GitArgs,
        [string]$Cwd,
        [string]$AuthToken,
        [switch]$Capture
    )

    $cmd = @()
    if ($Cwd) { $cmd += @('-C', $Cwd) }

    # Isolation flags -- per-command, no process-wide side effects
    $cmd += @('-c', 'credential.helper=')
    $cmd += @('-c', 'core.askPass=')

    # Inject auth header per-command if token is provided
    # GitHub uses Basic auth with 'x-access-token' as the username
    if ($AuthToken) {
        $encodedToken = [System.Convert]::ToBase64String(
            [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$AuthToken"))
        $cmd += @('-c', "http.extraHeader=Authorization: Basic $encodedToken")
    }

    $cmd += $GitArgs

    # Temporarily suppress prompts for this invocation only
    $prevGitPrompt = $env:GIT_TERMINAL_PROMPT
    $prevGcmInteractive = $env:GCM_INTERACTIVE
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'

        $global:LASTEXITCODE = 0
        if ($Capture) { return (& $script:GitBin @cmd 2>&1) }
        & $script:GitBin @cmd | Out-Default
        return $null
    }
    finally {
        # Restore previous values (or remove if they weren't set)
        if ($null -eq $prevGitPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
        else { $env:GIT_TERMINAL_PROMPT = $prevGitPrompt }
        if ($null -eq $prevGcmInteractive) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue }
        else { $env:GCM_INTERACTIVE = $prevGcmInteractive }
    }
}

function Set-MarkerBlock {
    <#
    .SYNOPSIS
        Idempotent insert/replace of a marker-delimited block in a text file.
        - Existing marker block -> replaced in-place (upgrade).
        - File exists, no marker -> block appended.
        - File missing -> created.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Snippet,
        [string]$StartMarker = '<!-- vibeshield-ev2 start -->',
        [string]$EndMarker   = '<!-- vibeshield-ev2 end -->'
    )

    $block = "$StartMarker`n$Snippet`n$EndMarker"

    if (Test-Path $Path) {
        $content = Get-Content $Path -Raw -Encoding UTF8
        $escapedStart = [regex]::Escape($StartMarker)
        $escapedEnd   = [regex]::Escape($EndMarker)
        $pattern      = "(?s)$escapedStart.*?$escapedEnd"

        if ($content -match $pattern) {
            $content = [regex]::Replace($content, $pattern, $block)
            if ($PSCmdlet.ShouldProcess($Path, 'Replace marker block')) {
                Set-Content -Path $Path -Value $content.TrimEnd() -Encoding UTF8
            }
            return 'updated'
        }
        else {
            if ($PSCmdlet.ShouldProcess($Path, 'Append marker block')) {
                Add-Content -Path $Path -Value ("`n`n" + $block) -Encoding UTF8
            }
            return 'appended'
        }
    }
    else {
        $parentDir = Split-Path $Path -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        if ($PSCmdlet.ShouldProcess($Path, 'Create file with marker block')) {
            Set-Content -Path $Path -Value $block -Encoding UTF8
        }
        return 'created'
    }
}

function Invoke-InstallVibeShieldEv2 {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Branch = 'main',

        [Parameter()]
        [string]$ProjectPath = (Get-Location).Path
    )

    # ---------- constants ----------

    $SourceRepo = 'https://github.com/gim-home/ev2-demo-agent.git'
    # Always install from main -- this source repo is not maintained by us,
    # so we pin to main to get the latest stable assets.
    $Branch = 'main'

    # NOTE: We do NOT set process-wide GIT_* environment variables (GIT_TERMINAL_PROMPT,
    # GCM_INTERACTIVE, GIT_CONFIG_*) because they leak into the target workspace's git
    # environment. All git isolation is achieved via per-command -c flags in Invoke-Git.

    # Platform detection -- use unique names to avoid colliding with PowerShell 7
    # built-in read-only automatic variables ($IsWindows, $IsMacOS, $IsLinux).
    $script:RunOnWindows = $IsWindows
    $script:RunOnMacOS   = $IsMacOS
    $script:RunOnWSL     = (-not $IsWindows) -and (Test-Path '/proc/version' -ErrorAction SilentlyContinue) -and
        ((Get-Content '/proc/version' -Raw -ErrorAction SilentlyContinue) -match '(?i)microsoft|wsl')

    # ---------- main ----------

    $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('vibeshield-ev2-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    $totalSteps = 6
    $startTime = Get-Date
    $phase = 'initialize'

    try {

        # Validate target path
        $phase = 'validate-target'
        if (-not (Test-Path $ProjectPath)) {
            throw 'TARGET_PATH_MISSING: target project path does not exist'
        }
        $ProjectPath = (Resolve-Path $ProjectPath).Path

        Write-Host ''                                          -ForegroundColor Cyan
        Write-Host '  VibeShield-EV2 Installer'                -ForegroundColor Cyan
        Write-Host '  ========================'                -ForegroundColor Cyan
        $platformLabel = if ($script:RunOnWSL) { 'WSL' }
                          elseif ($script:RunOnWindows) { 'Windows' }
                          elseif ($script:RunOnMacOS) { 'macOS' }
                          else { 'Linux' }
        Write-Host "  Source   : $SourceRepo"                  -ForegroundColor DarkGray
        Write-Host "  Branch   : $Branch"                      -ForegroundColor DarkGray
        Write-Host "  Target   : $ProjectPath"                 -ForegroundColor DarkGray
        Write-Host "  Platform : $platformLabel (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor DarkGray
        Write-Host ''

        # ----------------------------------------------------------
        # Step 1: Validate prerequisites
        # ----------------------------------------------------------
        $phase = 'prerequisites'
        Write-Step -N 1 -Total $totalSteps -Message 'Checking prerequisites...'

        $script:GitBin = Resolve-GitExecutable
        $gitVer = Invoke-GitVersion -GitBin $script:GitBin
        if ($gitVer -match '(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 25)) {
                Write-Fail "git 2.25+ required for sparse-checkout (found: $gitVer)"
                throw 'PREREQ_GIT_VERSION_TOO_OLD: git 2.25 or later is required'
            }
        }
        Write-Pass "git: $gitVer"

        $psVer = Get-PowerShellRuntimeVersion
        if ($psVer.Major -lt 7) {
            Write-Fail "PowerShell 7+ required (found: $psVer)"
            throw 'PREREQ_POWERSHELL_VERSION_TOO_OLD: PowerShell 7 or later is required'
        }
        Write-Pass "PowerShell: $psVer ($platformLabel)"

        $script:GhAvailable = Test-GitHubCliAvailable
        if ($script:GhAvailable) {
            Write-Pass 'GitHub CLI: detected'
        }
        else {
            Write-Host '  GitHub CLI (gh) not found -- attempting automatic install...' -ForegroundColor Yellow
            $installed = Install-GitHubCli
            if ($installed) {
                $script:GhAvailable = $true
                Write-Pass 'GitHub CLI: installed successfully'
            }
            else {
                Write-Fail 'GitHub CLI (gh) is required but could not be installed'
                Write-Host '  Install from https://cli.github.com/ and try again.' -ForegroundColor White
                throw 'GITHUB_AUTH_FAILED: GitHub CLI (gh) is required to clone the private source repository'
            }
        }

        # ----------------------------------------------------------
        # Step 2: Authenticate and sparse clone source repository
        # ----------------------------------------------------------
        $phase = 'clone-source'
        Write-Step -N 2 -Total $totalSteps -Message "Sparse cloning (branch: $Branch)..."

        # Acquire token -- authentication is mandatory for this private repo
        $ghToken = $null
        if ($script:GhAvailable) {
            # Check if already authenticated before prompting the user
            $ghBin = (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1)?.Source
            $existingToken = $null
            try { $existingToken = (& $ghBin auth token 2>$null)?.Trim() } catch { $null = $_ }

            if (-not $existingToken -or $LASTEXITCODE -ne 0) {
                # Not authenticated -- inform the user and ask to proceed
                Write-Host ''
                Write-Host '  ============================================================' -ForegroundColor Yellow
                Write-Host '  GitHub authentication required'                               -ForegroundColor Yellow
                Write-Host '  ============================================================' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '  About this installer:'                                         -ForegroundColor Cyan
                Write-Host '    VibeShield-EV2 installs a Copilot agent that helps you'      -ForegroundColor White
                Write-Host '    author, validate, and deploy ExpressV2 (EV2) service'        -ForegroundColor White
                Write-Host '    rollout specs. It clones agent definitions, prompts, and'    -ForegroundColor White
                Write-Host '    resources from a private GitHub repository into your'         -ForegroundColor White
                Write-Host '    project workspace.'                                          -ForegroundColor White
                Write-Host ''
                Write-Host '  To clone the source repo, you need to authenticate with'      -ForegroundColor White
                Write-Host '  GitHub via a browser-based device login flow.'                 -ForegroundColor White
                Write-Host ''
                Write-Host '  Instructions:'                                                 -ForegroundColor Cyan
                Write-Host '    1. A one-time 8-character code will be displayed below'      -ForegroundColor White
                Write-Host '    2. A browser window will open to https://github.com/login/device' -ForegroundColor White
                Write-Host '    3. Sign in with your Microsoft GMU account'                  -ForegroundColor White
                Write-Host '       (format: <your-alias>_microsoft)'                         -ForegroundColor DarkGray
                Write-Host '    4. Enter the 8-character code when prompted'                 -ForegroundColor White
                Write-Host '  ============================================================' -ForegroundColor Yellow
                Write-Host ''

                $proceed = Read-Host '  Proceed with GitHub login? (Y/n)'
                if ($proceed -and $proceed.Trim().ToUpper() -ne 'Y' -and $proceed.Trim() -ne '') {
                    Write-Host ''
                    Write-Warn 'EV2 agent installation is skipped.'
                    Write-Host ''
                    Write-Host '  To install later:'                                        -ForegroundColor Yellow
                    Write-Host '    Option 1 -- re-run this installer:'                     -ForegroundColor White
                    Write-Host "      pwsh -NoProfile -File skills/vibeshield-ev2/scripts/Install-VibeShield.ps1" -ForegroundColor DarkGray
                    Write-Host '    Option 2 -- clone the source repo directly:'            -ForegroundColor White
                    Write-Host "      $SourceRepo"                                          -ForegroundColor DarkGray
                    Write-Host ''
                    try {
                        Set-VibeShieldCapabilityResult -Status partial -Message 'GITHUB_AUTH_DECLINED: user declined GitHub login -- EV2 agent not installed' -Details @{ phase = $phase }
                    } catch {
                        # Standalone mode -- handshake env vars not set; skip message already printed
                        $null = $_
                    }
                    return
                }
                Write-Host ''
                Write-Host '  Starting GitHub device login flow...' -ForegroundColor Cyan
                Write-Host ''
            }

            if ($script:GhAvailable) {
                try {
                    $ghToken = Get-GitHubToken
                    Write-Pass 'GitHub token acquired'
                }
                catch {
                    Write-Fail 'GitHub authentication failed'
                    throw "GITHUB_AUTH_FAILED: $($_.Exception.Message)"
                }
            }
        }

        if (-not $ghToken) {
            throw 'GITHUB_AUTH_FAILED: GitHub authentication is required to clone the private source repository'
        }

        # Token is passed per-command via Invoke-Git -AuthToken, not via env vars

        if (Test-Path $TempDir) {
            Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

        $cloneArgs = @{
            GitArgs = @(
                'clone', '--depth', '1', '--branch', $Branch,
                '--filter=blob:none', '--sparse',
                $SourceRepo, $TempDir
            )
            Capture = $true
        }
        if ($ghToken) { $cloneArgs['AuthToken'] = $ghToken }

        $global:LASTEXITCODE = 0
        $cloneOutput = Invoke-Git @cloneArgs
        $cloneExit = $LASTEXITCODE

        # Detect SAML SSO 403 and retry after re-authorization
        if ($cloneExit -ne 0) {
            $cloneOutputStr = @($cloneOutput) -join "`n"
            $isSamlSso = $cloneOutputStr -match 'SAML SSO'

            if ($isSamlSso -and $script:GhAvailable) {
                Write-Warn 'Organization requires SAML SSO -- re-authorizing GitHub CLI...'
                Write-Host ''
                Write-Host '  The source repository organization requires SAML SSO.'       -ForegroundColor Yellow
                Write-Host '  A browser will open for you to complete SSO sign-in.'        -ForegroundColor Yellow
                Write-Host '  Return here after completing the sign-in.'                   -ForegroundColor Yellow
                Write-Host ''

                $proceed = Read-Host '  Proceed with GitHub SSO login? (Y/n)'
                if ($proceed -and $proceed.Trim().ToUpper() -ne 'Y' -and $proceed.Trim() -ne '') {
                    Write-Warn 'SSO authorization declined -- clone cannot proceed'
                    throw 'GITHUB_AUTH_DECLINED: user declined GitHub login required to clone EV2 agent source repo -- re-run installer when ready'
                }

                $ghBin = (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -First 1)?.Source
                if ([string]::IsNullOrWhiteSpace($ghBin)) {
                    Write-Warn 'GitHub CLI (gh) was not found while handling SAML SSO re-authorization'
                    throw 'GITHUB_AUTH_FAILED: GitHub CLI (gh) is required to complete SAML SSO authorization'
                }

                Write-Host '  Running gh auth refresh for SAML SSO...' -ForegroundColor Cyan
                Write-Host '  Complete the sign-in in your browser, then return here.' -ForegroundColor White
                Write-Host '  IMPORTANT: On the authorization page, scroll down and'  -ForegroundColor Yellow
                Write-Host '  click "Authorize" next to the gim-home organization.'   -ForegroundColor Yellow
                Write-Host ''

                # Open the device page ourselves -- gh can't find a browser on WSL
                Open-BrowserUrl -Url 'https://github.com/login/device'

                # Set BROWSER env var so gh doesn't try cmd.exe /c start (which
                # fails on WSL due to PowerShell 7 argument-passing quoting).
                $prevBrowser = $env:BROWSER
                if ($script:RunOnWSL) { $env:BROWSER = 'explorer.exe' }

                $global:LASTEXITCODE = 0
                try {
                    & $ghBin auth refresh -h github.com -s repo,read:org 2>&1 | ForEach-Object {
                        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
                        Write-Host $line
                        if ($line -match 'code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})') {
                            Copy-ToClipboard -Text $Matches[1]
                            Write-Host '  >> One-time code copied to clipboard' -ForegroundColor Green
                        }
                    }
                }
                catch { $global:LASTEXITCODE = 1 }
                finally {
                    if ($script:RunOnWSL) { $env:BROWSER = $prevBrowser }
                }

                if ($LASTEXITCODE -eq 0) {
                    Write-Pass 'GitHub CLI re-authorized'

                    # Re-acquire token after refresh
                    try {
                        $ghToken = Get-GitHubToken
                        if ($ghToken) { $cloneArgs['AuthToken'] = $ghToken }
                    } catch {
                        Write-Warn 'Could not re-acquire token after refresh'
                    }

                    # Clean up failed clone directory and retry
                    if (Test-Path $TempDir) {
                        Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
                    }
                    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

                    $cloneArgs['GitArgs'] = @(
                        'clone', '--depth', '1', '--branch', $Branch,
                        '--filter=blob:none', '--sparse',
                        $SourceRepo, $TempDir
                    )

                    $global:LASTEXITCODE = 0
                    $cloneOutput = Invoke-Git @cloneArgs
                    $cloneExit = $LASTEXITCODE
                }
            }
        }

        if ($cloneExit -ne 0) {
            Write-Fail "git clone failed (branch: $Branch)"
            foreach ($line in @($cloneOutput)) {
                Write-Verbose "  git: $line"
            }
            throw 'GIT_CLONE_FAILED: source repository clone failed'
        }

        $sparseArgs = @{
            GitArgs = @('sparse-checkout', 'set', '.github')
            Cwd     = $TempDir
            Capture = $true
        }
        if ($ghToken) { $sparseArgs['AuthToken'] = $ghToken }

        $null = Invoke-Git @sparseArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'sparse-checkout set failed'
            throw 'GIT_SPARSE_CHECKOUT_FAILED: sparse checkout failed'
        }

        $sourceGitHub = Join-Path $TempDir '.github'
        if (-not (Test-Path $sourceGitHub)) {
            Write-Fail 'Sparse checkout did not produce .github directory'
            throw 'SOURCE_GITHUB_MISSING: sparse checkout did not include GitHub assets'
        }

        Write-Pass 'Source repository cloned (sparse, depth 1)'

        # ----------------------------------------------------------
        # Step 3: Copy asset directories
        # ----------------------------------------------------------
        $phase = 'copy-assets'
        Write-Step -N 3 -Total $totalSteps -Message 'Copying agent files into target workspace...'

        $destGitHub = Join-Path $ProjectPath '.github'
        if (-not (Test-Path $destGitHub)) {
            New-Item -ItemType Directory -Path $destGitHub -Force | Out-Null
        }

        $assetDirs   = @('agents', 'prompts', 'resources')
        $copiedCount = 0

        foreach ($dir in $assetDirs) {
            $src = Join-Path $sourceGitHub $dir
            if (-not (Test-Path $src)) {
                Write-Warn "Source directory not found: .github/$dir -- skipping"
                continue
            }

            $dest = Join-Path $destGitHub $dir
            if (-not (Test-Path $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }

            $srcRoot = (Resolve-Path $src).Path
            $items   = @(Get-ChildItem -Path $src -Recurse -Force -ErrorAction SilentlyContinue)

            foreach ($item in $items) {
                $relativePath = [System.IO.Path]::GetRelativePath($srcRoot, $item.FullName)
                $targetPath   = Join-Path $dest $relativePath

                if ($item.PSIsContainer) {
                    if (-not (Test-Path $targetPath)) {
                        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                    }
                }
                else {
                    $targetDir = Split-Path $targetPath -Parent
                    if (-not (Test-Path $targetDir)) {
                        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                    }
                    Copy-Item -Path $item.FullName -Destination $targetPath -Force
                    $copiedCount++
                }
            }

            Write-Pass "Copied .github/$dir"
        }

        Write-Pass "$copiedCount file(s) installed into .github/"

        # ----------------------------------------------------------
        # Step 4: Wire copilot-instructions.md
        # ----------------------------------------------------------
        $phase = 'configure-copilot'
        Write-Step -N 4 -Total $totalSteps -Message 'Configuring .github/copilot-instructions.md...'

        $sourceCopilotPath = Join-Path $sourceGitHub 'copilot-instructions.md'
        $targetCopilotPath = Join-Path $destGitHub 'copilot-instructions.md'
        $startMarker       = '<!-- vibeshield-ev2 start -->'
        $endMarker         = '<!-- vibeshield-ev2 end -->'

        if (Test-Path $sourceCopilotPath) {
            $sourceContent = Get-Content $sourceCopilotPath -Raw -Encoding UTF8

            # Try to extract only the vibeshield-ev2 section from source if it
            # contains markers; otherwise use the entire content as the snippet.
            $escapedStart = [regex]::Escape($startMarker)
            $escapedEnd   = [regex]::Escape($endMarker)
            $sectionPattern = "(?s)$escapedStart\s*\n(.*?)\n\s*$escapedEnd"

            if ($sourceContent -match $sectionPattern) {
                $snippet = $Matches[1]
            }
            else {
                $snippet = $sourceContent.Trim()
            }

            $result = Set-MarkerBlock -Path $targetCopilotPath -Snippet $snippet `
                                      -StartMarker $startMarker -EndMarker $endMarker

            switch ($result) {
                'updated'  { Write-Pass 'copilot-instructions.md vibeshield-ev2 section updated (upgrade)' }
                'appended' { Write-Pass 'vibeshield-ev2 section appended to copilot-instructions.md' }
                'created'  { Write-Pass 'copilot-instructions.md created with vibeshield-ev2 section' }
            }
        }
        else {
            Write-Warn 'Source .github/copilot-instructions.md not found -- skipping snippet wiring'
        }

        # ----------------------------------------------------------
        # Step 5: Create/update .vscode/mcp.json (idempotent merge)
        # ----------------------------------------------------------
        $phase = 'configure-mcp'
        Write-Step -N 5 -Total $totalSteps -Message 'Creating .vscode/mcp.json with EV2 MCP Server configuration...'

        $vscodeDir   = Join-Path $ProjectPath '.vscode'
        $mcpJsonPath = Join-Path $vscodeDir 'mcp.json'

        if (-not (Test-Path $vscodeDir)) {
            New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
        }

        # Define the EV2 server entry to merge
        $ev2Server = [ordered]@{
            type    = 'stdio'
            command = 'dnx'
            args    = @(
                'Ev2.McpServer'
                '--source'
                'https://msazure.pkgs.visualstudio.com/_packaging/Official/nuget/v3/index.json'
                '--interactive'
                '--yes'
            )
            env     = [ordered]@{
                ALLOWED_EV2_ENDPOINTS = 'Test'
            }
        }

        if (Test-Path $mcpJsonPath) {
            # Merge into existing mcp.json -- preserve other server entries
            $existingRaw = Get-Content -Path $mcpJsonPath -Raw -Encoding UTF8
            try {
                $mcpObj = $existingRaw | ConvertFrom-Json -AsHashtable
            }
            catch {
                Write-Warn "Existing mcp.json is not valid JSON -- backing up and recreating"
                Copy-Item -Path $mcpJsonPath -Destination "$mcpJsonPath.bak" -Force
                $mcpObj = $null
            }

            if ($null -eq $mcpObj) {
                $mcpObj = [ordered]@{ servers = [ordered]@{} }
            }
            if (-not $mcpObj.ContainsKey('servers')) {
                $mcpObj['servers'] = [ordered]@{}
            }

            $mcpObj['servers']['Ev2 MCP Server'] = $ev2Server
            $updatedJson = $mcpObj | ConvertTo-Json -Depth 10
            Set-Content -Path $mcpJsonPath -Value $updatedJson -Encoding UTF8
            Write-Pass '.vscode/mcp.json updated with EV2 MCP Server configuration'
        }
        else {
            # Create fresh mcp.json
            $mcpObj = [ordered]@{
                servers = [ordered]@{
                    'Ev2 MCP Server' = $ev2Server
                }
            }
            $newJson = $mcpObj | ConvertTo-Json -Depth 10
            Set-Content -Path $mcpJsonPath -Value $newJson -Encoding UTF8
            Write-Pass '.vscode/mcp.json created with EV2 MCP Server configuration'
        }

        # ----------------------------------------------------------
        # Step 6: Cleanup
        # ----------------------------------------------------------
        $phase = 'cleanup'
        Write-Step -N 6 -Total $totalSteps -Message 'Cleaning up temporary directory...'

        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Pass 'Temporary clone removed'

        # ---------- summary ----------

        $elapsed = (Get-Date) - $startTime
        Write-Host ''
        Write-Host ('=' * 50)                                                         -ForegroundColor Green
        Write-Host " Installation complete ($([math]::Round($elapsed.TotalSeconds, 1))s)" -ForegroundColor Green
        Write-Host ('=' * 50)                                                         -ForegroundColor Green
        Write-Host ''
        Write-Host 'Installed from:'                                                  -ForegroundColor Cyan
        Write-Host "  $SourceRepo (branch: $Branch)"                                  -ForegroundColor White
        Write-Host ''
        Write-Host 'Next steps:'                                                      -ForegroundColor Cyan
        Write-Host '  1. Open VS Code in the target directory'                        -ForegroundColor White
        Write-Host '  2. Review .github/copilot-instructions.md for EV2 routing'      -ForegroundColor White
        Write-Host '  3. Review .vscode/mcp.json for EV2 MCP Server config'           -ForegroundColor White
        Write-Host '  4. Use the EV2 agent from the Copilot Chat agents dropdown'     -ForegroundColor White
        Write-Host ''

        try {
            Set-VibeShieldCapabilityResult -Status ok -Message 'EV2_INSTALL_OK: EV2 capability installed' -Details @{ branch = $Branch; copiedCount = $copiedCount; platform = $platformLabel }
        } catch {
            # Standalone mode -- handshake env vars not set; success already printed above
            $null = $_
        }
        return

    } # end try
    catch {
        $classifiedMessage = Convert-VibeShieldEv2ErrorToMessage -ErrorText $_.Exception.Message
        Write-Fail "Installation failed: $classifiedMessage"
        try {
            Set-VibeShieldCapabilityResult -Status fail -Message $classifiedMessage -Details @{ phase = $phase }
        } catch {
            # Standalone mode -- handshake env vars not set by orchestrator; surface the classified error directly
            Write-Warning $classifiedMessage
        }
        throw
    }
    finally {
        if (-not [string]::IsNullOrEmpty($TempDir) -and (Test-Path $TempDir -ErrorAction SilentlyContinue)) {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        # No process-wide git env vars to clean up -- all isolation is per-command
    }

}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallVibeShieldEv2 @PSBoundParameters
}
