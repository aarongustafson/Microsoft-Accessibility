. (Join-Path $PSScriptRoot 'Install-OrgList.ps1')
$script:ValidCfsOrganizations = Get-ValidCfsOrganization

# Regex: ADO pypi feed URL (project-scoped or org-scoped)
$script:PipFeedUrlPattern = '^https://pkgs\.dev\.azure\.com/([^/]+)/([^/]+/_packaging/[^/]+|_packaging/[^/]+)/pypi/simple/?$'

# Sentinel file name and magic string for managed venv lifecycle
$script:VibeShieldVenvSentinelFile  = '.vibeshield-managed'
$script:VibeShieldVenvSentinelMagic = '# Managed by VibeShield Install-PipFeedConfig.ps1 - safe to remove.'

function Test-ValidCfsPipFeed {
    <#
    .SYNOPSIS
        Validates whether pip config lines represent a valid CFS feed.

    .DESCRIPTION
        Parses INI-style pip config lines and checks for a valid internal ADO
        pypi feed in [global], with exactly one index-url. Detects unsafe
        directives (extra-index-url, URL find-links, install index-url override).

    .PARAMETER Lines
        Array of lines from the pip config file.

    .OUTPUTS
        PSCustomObject with IsValid, HasUnsafeDirectives, OrgName, FeedUrl.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    Set-StrictMode -Version Latest

    $result = [PSCustomObject]@{
        IsValid             = $false
        HasUnsafeDirectives = $false
        OrgName             = $null
        FeedUrl             = $null
    }

    $currentSection = $null
    $globalIndexUrls = @()
    $hasUnsafe = $false

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        # Skip empty lines and comments
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }

        # Section header
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $currentSection = $Matches[1].ToLowerInvariant()
            continue
        }

        # Parse key=value
        $eqIndex = $trimmed.IndexOf('=')
        if ($eqIndex -lt 0) { continue }
        $key = $trimmed.Substring(0, $eqIndex).Trim().ToLowerInvariant()
        $value = $trimmed.Substring($eqIndex + 1).Trim()

        if ($currentSection -eq 'global') {
            if ($key -eq 'index-url') {
                $globalIndexUrls += $value
            }
            if ($key -eq 'extra-index-url') {
                $hasUnsafe = $true
            }
            if ($key -eq 'find-links' -and $value -match '^https?://') {
                $hasUnsafe = $true
            }
        }

        if ($currentSection -eq 'install') {
            if ($key -eq 'extra-index-url') {
                $hasUnsafe = $true
            }
            if ($key -eq 'find-links' -and $value -match '^https?://') {
                $hasUnsafe = $true
            }
            if ($key -eq 'index-url') {
                $hasUnsafe = $true
            }
        }
    }

    # Step 1: Must have [global] section with index-url
    if ($null -eq $currentSection -and $globalIndexUrls.Count -eq 0) {
        # No sections found at all
        return $result
    }

    # Check that we found a [global] section
    $foundGlobal = $false
    foreach ($line in $Lines) {
        if ($line.Trim() -match '^\[global\]$') {
            $foundGlobal = $true
            break
        }
    }
    if (-not $foundGlobal) {
        return $result
    }

    # Step 2a: Exactly one index-url in [global]
    if ($globalIndexUrls.Count -ne 1) {
        return $result
    }

    $feedUrl = $globalIndexUrls[0]
    $result.FeedUrl = $feedUrl

    # Step 2b: URL matches ADO pypi feed pattern
    if ($feedUrl -notmatch $script:PipFeedUrlPattern) {
        return $result
    }

    $orgName = $Matches[1]
    $result.OrgName = $orgName

    # Step 2c: Org is in known-org list (case-insensitive)
    $orgMatch = $false
    foreach ($validOrg in $script:ValidCfsOrganizations) {
        if ($validOrg -ieq $orgName) {
            $orgMatch = $true
            break
        }
    }
    if (-not $orgMatch) {
        return $result
    }

    # Valid CFS feed
    $result.IsValid = $true
    $result.HasUnsafeDirectives = $hasUnsafe

    return $result
}

function Repair-PipFeedConfig {
    <#
    .SYNOPSIS
        Removes unsafe directives from pip config while preserving valid settings.

    .DESCRIPTION
        Removes extra-index-url lines from [global] and [install], URL-based
        find-links from [global] and [install], and index-url from [install].
        Preserves local find-links and all other settings.

    .PARAMETER Lines
        Array of lines from the pip config file.

    .OUTPUTS
        System.String[] - Cleaned lines.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    Set-StrictMode -Version Latest

    $currentSection = $null
    $cleaned = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        # Section header
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $currentSection = $Matches[1].ToLowerInvariant()
            $cleaned.Add($line)
            continue
        }

        # Only filter in [global] and [install]
        if ($currentSection -eq 'global' -or $currentSection -eq 'install') {
            # Parse key=value
            $eqIndex = $trimmed.IndexOf('=')
            if ($eqIndex -ge 0) {
                $key = $trimmed.Substring(0, $eqIndex).Trim().ToLowerInvariant()
                $value = $trimmed.Substring($eqIndex + 1).Trim()

                # Remove extra-index-url
                if ($key -eq 'extra-index-url') { continue }

                # Remove URL-based find-links
                if ($key -eq 'find-links' -and $value -match '^https?://') { continue }

                # Remove index-url from [install]
                if ($currentSection -eq 'install' -and $key -eq 'index-url') { continue }
            }
        }

        $cleaned.Add($line)
    }

    return @($cleaned)
}

function Test-VenvCapability {
    <#
    .SYNOPSIS
        Probes whether the given Python command can create venvs with pip.
    .OUTPUTS
        PSCustomObject with CanCreateVenv [bool] and ExitCode [int].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PythonCommand
    )

    Set-StrictMode -Version Latest

    $null = & $PythonCommand -c 'import ensurepip, venv' 2>&1
    $ec = $LASTEXITCODE
    return [PSCustomObject]@{
        CanCreateVenv = ($ec -eq 0)
        ExitCode      = $ec
    }
}

function Test-VenvStructure {
    <#
    .SYNOPSIS
        Checks whether a venv directory has the expected structural files.
    .OUTPUTS
        PSCustomObject with Present [bool], Healthy [bool], Reason [string].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VenvDir,

        [Parameter(Mandatory)]
        [bool]$RunningOnWindows
    )

    Set-StrictMode -Version Latest

    if (-not (Test-Path $VenvDir -PathType Container)) {
        return [PSCustomObject]@{ Present = $false; Healthy = $false; Reason = 'Directory does not exist' }
    }

    $pyvenvCfg = Join-Path $VenvDir 'pyvenv.cfg'
    if (-not (Test-Path $pyvenvCfg -PathType Leaf)) {
        return [PSCustomObject]@{ Present = $true; Healthy = $false; Reason = 'Missing pyvenv.cfg' }
    }

    if ($RunningOnWindows) {
        $subDir  = 'Scripts'
        $pipName = 'pip.exe'
        $pyName  = 'python.exe'
    } else {
        $subDir  = 'bin'
        $pipName = 'pip'
        $pyName  = 'python'
    }

    $binDir = Join-Path $VenvDir $subDir
    $pipPath = Join-Path $binDir $pipName
    $pyPath  = Join-Path $binDir $pyName

    if (-not (Test-Path $pyPath -PathType Leaf)) {
        return [PSCustomObject]@{ Present = $true; Healthy = $false; Reason = ('Missing {0}/{1}' -f $subDir, $pyName) }
    }
    if (-not (Test-Path $pipPath -PathType Leaf)) {
        return [PSCustomObject]@{ Present = $true; Healthy = $false; Reason = ('Missing {0}/{1}' -f $subDir, $pipName) }
    }

    return [PSCustomObject]@{ Present = $true; Healthy = $true; Reason = '' }
}

function Test-VenvSentinel {
    <#
    .SYNOPSIS
        Checks whether the venv has a valid VibeShield sentinel file.
    .OUTPUTS
        Boolean - $true if sentinel exists and first line matches magic.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VenvDir
    )

    Set-StrictMode -Version Latest

    $sentinelPath = Join-Path $VenvDir $script:VibeShieldVenvSentinelFile
    if (-not (Test-Path $sentinelPath -PathType Leaf)) {
        return $false
    }
    try {
        $lines = @(Get-Content -LiteralPath $sentinelPath -TotalCount 1 -Encoding utf8 -ErrorAction Stop)
        if ($lines.Count -eq 0) { return $false }
        $firstLine = [string]$lines[0] -replace '^\xEF\xBB\xBF', '' -replace '^\uFEFF', ''
        return ($firstLine -eq $script:VibeShieldVenvSentinelMagic)
    } catch {
        Write-Verbose -Message ('Could not read venv sentinel {0}: {1}' -f $sentinelPath, $_)
        return $false
    }
}

function Write-VenvSentinel {
    <#
    .SYNOPSIS
        Writes a VibeShield sentinel file into a managed venv directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VenvDir,

        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    Set-StrictMode -Version Latest

    $sentinelPath = Join-Path $VenvDir $script:VibeShieldVenvSentinelFile
    if ($PSCmdlet.ShouldProcess($sentinelPath, 'Write venv sentinel')) {
        $skillVersion = 'unknown'
        $versionJsonPath = Join-Path $PSScriptRoot '..\..\..\..\version.json'
        if (Test-Path $versionJsonPath -PathType Leaf) {
            try {
                $vj = Get-Content -LiteralPath $versionJsonPath -Raw | ConvertFrom-Json
                if ($vj.version) { $skillVersion = $vj.version }
            } catch {
                Write-Verbose -Message ('Could not read version.json for sentinel: {0}' -f $_)
            }
        }
        $lines = @(
            $script:VibeShieldVenvSentinelMagic
            ('created-utc={0:O}' -f [System.DateTimeOffset]::UtcNow)
            ('skill-version={0}' -f $skillVersion)
            ('project-root={0}' -f $ProjectRoot)
        )
        Set-Content -LiteralPath $sentinelPath -Value ($lines -join [System.Environment]::NewLine) -Encoding ASCII -NoNewline
    }
}

function Remove-ManagedVenv {
    <#
    .SYNOPSIS
        Removes a VibeShield-managed venv directory.
    .OUTPUTS
        Boolean - $true if removal succeeded.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VenvDir,

        [string]$Reason = 'structural damage detected'
    )

    Set-StrictMode -Version Latest

    if ($PSCmdlet.ShouldProcess($VenvDir, ('Remove managed venv ({0})' -f $Reason))) {
        try {
            Remove-Item -LiteralPath $VenvDir -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Host ('  ERROR: Could not remove managed venv: {0}' -f $_) -ForegroundColor Red
            return $false
        }
    }
    return $false
}

function Install-PipFeedConfig {
    <#
    .SYNOPSIS
        Installs CFS-backed pip feed configuration with virtualenv and keyring.

    .DESCRIPTION
        Creates a .venv virtualenv (if absent), copies pip.ini/pip.conf from skill
        assets into the venv, and installs keyring + artifacts-keyring. Validates
        existing pip config using CFS detection decision tree before replacing.

    .PARAMETER ProjectRoot
        Absolute path to the project root directory.

    .PARAMETER AssetsDir
        Absolute path to the skill assets directory.

    .PARAMETER RunningOnWindows
        Whether the current OS is Windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$AssetsDir,

        [Parameter(Mandatory)]
        [bool]$RunningOnWindows
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = [PSCustomObject]@{ Created = 0; Skipped = 0; Warned = 0; Failed = 0 }

    Write-Host '' -ForegroundColor Cyan
    Write-Host '--- Python / pip Configuration ---' -ForegroundColor Cyan

    # Detect python: prefer python3, fall back to python
    # Verify the command is real Python, not the Windows Store stub alias
    $pythonCmd = $null
    foreach ($candidate in @('python3', 'python')) {
        if ($null -ne (Get-Command $candidate -ErrorAction SilentlyContinue)) {
            $null = & $candidate --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $pythonCmd = $candidate
                break
            }
        }
    }

    if (-not $pythonCmd) {
        Write-Host '  WARNING: python3/python not found -- skipping Python configuration.' -ForegroundColor Yellow
        Write-Host '           Install Python to enable pip feed configuration.' -ForegroundColor Yellow
        $result.Warned++
        return $result
    }

    $venvDir = Join-Path $ProjectRoot '.venv'
    $pipConfigName = if ($RunningOnWindows) { 'pip.ini' } else { 'pip.conf' }

    # Pre-flight: probe ensurepip + venv availability
    $capability = Test-VenvCapability -PythonCommand $pythonCmd
    if (-not $capability.CanCreateVenv) {
        if ($RunningOnWindows) {
            Write-Host '  FAIL: Python venv/ensurepip modules are missing.' -ForegroundColor Red
            Write-Host '        Reinstall Python with the default options to include pip and venv.' -ForegroundColor Red
        } else {
            Write-Host '  FAIL: Python venv/ensurepip modules are missing.' -ForegroundColor Red
            Write-Host '        Run: sudo apt install -y python3-venv' -ForegroundColor Red
        }
        if (Test-Path $venvDir -PathType Container) {
            Write-Host '        (Your existing .venv/ is preserved; this check guards future re-creation.)' -ForegroundColor Yellow
        }
        $result.Failed++
        return $result
    }

    # Venv lifecycle decision tree (Bug 517376)
    $structure = Test-VenvStructure -VenvDir $venvDir -RunningOnWindows $RunningOnWindows
    $hasSentinel = Test-VenvSentinel -VenvDir $venvDir
    $needsCreate = $false

    if (-not $structure.Present) {
        # No .venv at all - create fresh
        $needsCreate = $true
    } elseif ($structure.Healthy -and $hasSentinel) {
        # Managed healthy venv - skip
        Write-Host '  SKIPPED: .venv/ already exists (managed by VibeShield)' -ForegroundColor Cyan
        $result.Skipped++
    } elseif ($structure.Healthy -and (-not $hasSentinel)) {
        # Healthy venv we did not create - backward compat, skip without writing sentinel
        Write-Host '  SKIPPED: .venv/ already exists' -ForegroundColor Cyan
        $result.Skipped++
    } elseif ((-not $structure.Healthy) -and $hasSentinel) {
        # Managed but damaged venv - remove and recreate
        Write-Host ('  WARNING: Managed .venv/ is incomplete ({0}). Removing and recreating...' -f $structure.Reason) -ForegroundColor Yellow
        $removed = Remove-ManagedVenv -VenvDir $venvDir -Reason $structure.Reason
        if (-not $removed) {
            $result.Failed++
            return $result
        }
        $needsCreate = $true
    } else {
        # Damaged venv we did not create - refuse to delete
        Write-Host ('  FAIL: .venv/ exists but is incomplete ({0}) and was not created by VibeShield.' -f $structure.Reason) -ForegroundColor Red
        Write-Host '        Remove or repair the .venv/ directory manually and re-run.' -ForegroundColor Red
        $result.Failed++
        return $result
    }

    if ($needsCreate) {
        Write-Host "  Creating virtualenv at .venv using $pythonCmd..." -ForegroundColor Cyan
        try {
            $venvOutput = & $pythonCmd -m venv $venvDir 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ('venv creation returned exit code {0}: {1}' -f $LASTEXITCODE, ($venvOutput -join [System.Environment]::NewLine))
            }
            # Post-create verification: confirm the venv is structurally complete
            $postCheck = Test-VenvStructure -VenvDir $venvDir -RunningOnWindows $RunningOnWindows
            if (-not $postCheck.Healthy) {
                throw ('venv created but incomplete: {0}' -f $postCheck.Reason)
            }
            Write-VenvSentinel -VenvDir $venvDir -ProjectRoot $ProjectRoot
            Write-Host '  CREATED: .venv/' -ForegroundColor Green
            $result.Created++
        } catch {
            Write-Host "  ERROR: Failed to create virtualenv: $_" -ForegroundColor Red
            # Clean up any partial venv we attempted to create
            if (Test-Path $venvDir -PathType Container) {
                try {
                    Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction Stop
                } catch {
                    Write-Host ('  ERROR: Failed to clean up partial venv at {0}: {1}' -f $venvDir, $_) -ForegroundColor Red
                    Write-Host '         Remove the .venv/ directory manually before re-running.' -ForegroundColor Red
                }
            }
            $result.Failed++
            return $result
        }
    }

    # Install keyring + artifacts-keyring BEFORE copying pip config.
    # The pip config redirects to the CFS feed which requires artifacts-keyring
    # for authentication. Installing from public PyPI first avoids the circular
    # dependency (feed requires auth packages that can only be fetched from feed).
    $keyringInstallOk = $false
    if (Test-Path $venvDir -PathType Container) {
        Write-Host '  Installing keyring and artifacts-keyring into .venv...' -ForegroundColor Cyan

        # Use a short temp directory to avoid Windows MAX_PATH (260 char) limit
        # during artifacts-keyring sdist build. When no pre-built wheel exists
        # (e.g., Windows ARM64 + Python 3.14), pip builds from source and the
        # artifacts-keyring package vendors the .NET credential provider DLLs
        # into a deeply nested directory tree. Combined with pip's own temp
        # path (e.g., C:\Users\<user>\AppData\Local\Temp\pip-install-<hash>\
        # artifacts-keyring_<hash>\build\lib.win-arm64-cpython-314\
        # artifacts_keyring\plugins\plugins\netcore\CredentialProvider.Microsoft\)
        # the full path to individual DLLs exceeds 260 chars, causing the build
        # to fail with 'No such file or directory'. A short temp root avoids this.
        # This is only needed on Windows; Linux/macOS have no 260-char limit.
        $shortTmpDir = $null
        $originalTmpDir = $env:TMPDIR
        $originalTemp = $env:TEMP
        $originalTmp = $env:TMP
        if ($RunningOnWindows) {
            $shortTmpDir = Join-Path ([System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())) ('piptmp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $shortTmpDir -Force | Out-Null
            $env:TMPDIR = $shortTmpDir
            $env:TEMP = $shortTmpDir
            $env:TMP = $shortTmpDir
        }

        try {
            $pipSubDir = if ($RunningOnWindows) { 'Scripts' } else { 'bin' }
            $pipExe = if ($RunningOnWindows) { Join-Path (Join-Path $venvDir $pipSubDir) 'pip.exe' } else { Join-Path (Join-Path $venvDir $pipSubDir) 'pip' }
            $pythonExe = if ($RunningOnWindows) { Join-Path (Join-Path $venvDir $pipSubDir) 'python.exe' } else { Join-Path (Join-Path $venvDir $pipSubDir) 'python' }

            if (Test-Path $pipExe) {
                # Explicitly use public PyPI for the credential packages
                $pipOutput = & $pipExe install keyring artifacts-keyring --index-url https://pypi.org/simple/ 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host '  INSTALLED: keyring, artifacts-keyring' -ForegroundColor Green
                    $result.Created++

                    # Verify ArtifactsKeyringBackend is registered
                    if (Test-Path $pythonExe) {
                        $backends = & $pythonExe -m keyring --list-backends 2>&1
                        if ($LASTEXITCODE -eq 0 -and ($backends | Out-String) -match 'ArtifactsKeyringBackend') {
                            Write-Host '  VERIFIED: ArtifactsKeyringBackend is registered' -ForegroundColor Green
                            $keyringInstallOk = $true
                        } else {
                            Write-Host '  ERROR: keyring packages installed but ArtifactsKeyringBackend not detected.' -ForegroundColor Red
                            Write-Host '         Without this backend, pip cannot authenticate against the CFS feed.' -ForegroundColor Red
                            Write-Host "         Backends found: $($backends | Out-String)" -ForegroundColor Yellow
                            $result.Failed++
                        }
                    } else {
                        Write-Host '  ERROR: python executable not found -- cannot verify keyring backend.' -ForegroundColor Red
                        $result.Failed++
                    }
                } else {
                    Write-Host '  ERROR: Failed to install keyring, artifacts-keyring' -ForegroundColor Red
                    Write-Host '         pip output:' -ForegroundColor Red
                    foreach ($line in @($pipOutput)) {
                        Write-Host "         $line" -ForegroundColor Yellow
                    }
                    $result.Failed++
                }
            } else {
                Write-Host "  ERROR: pip executable not found at $pipExe" -ForegroundColor Red
                $result.Failed++
            }
        } catch {
            Write-Host "  ERROR: Could not install keyring packages: $_" -ForegroundColor Red
            $manualPipPath = Join-Path (Join-Path '.venv' $pipSubDir) 'pip'
            Write-Host "         Run manually: $manualPipPath install keyring artifacts-keyring" -ForegroundColor Red
            $result.Failed++
        } finally {
            # Restore original temp directories (only if overridden on Windows)
            if ($null -ne $shortTmpDir) {
                $env:TMPDIR = $originalTmpDir
                $env:TEMP = $originalTemp
                $env:TMP = $originalTmp
                if (Test-Path $shortTmpDir) {
                    Remove-Item -Path $shortTmpDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Gate pip.ini copy on successful keyring installation
        if ($keyringInstallOk) {
            # Copy pip config into the venv (after keyring is installed)
            $pipSource = Join-Path $AssetsDir 'pip.ini'
            $pipTarget = Join-Path $venvDir $pipConfigName
            $pipBakTarget = Join-Path $venvDir ($pipConfigName + '.bak')

            if (-not (Test-Path $pipSource)) {
                Write-Host '  ERROR: pip.ini not found in skill assets.' -ForegroundColor Red
                $result.Failed++
            } elseif (Test-Path $pipTarget) {
                $existingRaw = Get-Content $pipTarget -Raw
                if ($null -eq $existingRaw) { $existingRaw = '' }
                $existingContent = $existingRaw.Trim() -replace '\r\n', "`n"
                $assetContent = (Get-Content $pipSource -Raw).Trim() -replace '\r\n', "`n"
                if ($existingContent -eq $assetContent) {
                    # Exact match with asset
                    Write-Host "  SKIPPED: .venv/$pipConfigName already configured for CFS" -ForegroundColor Green
                    $result.Skipped++
                } else {
                    # Content differs -- run CFS decision tree
                    $existingLines = @(Get-Content $pipTarget)
                    $cfsResult = Test-ValidCfsPipFeed -Lines $existingLines

                    if ($cfsResult.IsValid -and -not $cfsResult.HasUnsafeDirectives) {
                        # Path 3: Valid CFS from different org -- skip
                        Write-Host "  SKIPPED: .venv/$pipConfigName already configured with a valid CFS feed" -ForegroundColor Green
                        Write-Host "           Organization: $($cfsResult.OrgName)" -ForegroundColor Cyan
                        $result.Skipped++
                    } elseif ($cfsResult.IsValid -and $cfsResult.HasUnsafeDirectives) {
                        # Path 5: Valid internal feed with unsafe directives -- fix in place
                        Copy-Item -Path $pipTarget -Destination $pipBakTarget -Force
                        Write-Host "  BACKUP:  .venv/$pipConfigName -> .venv/$($pipConfigName).bak" -ForegroundColor Cyan
                        Write-Host "  WARNING: .venv/$pipConfigName has a valid internal feed but contains" -ForegroundColor Yellow
                        Write-Host '           extra-index-url entries. These allow packages from' -ForegroundColor Yellow
                        Write-Host '           additional sources, bypassing CFS protection.' -ForegroundColor Yellow
                        Write-Host '           Removing extra-index-url to seal the configuration.' -ForegroundColor Yellow
                        Write-Host "           Organization: $($cfsResult.OrgName)" -ForegroundColor Cyan

                        $cleanedLines = Repair-PipFeedConfig -Lines $existingLines
                        $cleanedContent = $cleanedLines -join [System.Environment]::NewLine
                        Set-Content -Path $pipTarget -Value $cleanedContent -NoNewline

                        Write-Host "  FIXED:   .venv/$pipConfigName -- removed unsafe directives" -ForegroundColor Green
                        $result.Created++
                    } elseif ($null -ne $cfsResult.OrgName -and -not $cfsResult.IsValid) {
                        # Path 4: Unknown ADO org -- backup and replace
                        Copy-Item -Path $pipTarget -Destination $pipBakTarget -Force
                        Write-Host "  BACKUP:  .venv/$pipConfigName -> .venv/$($pipConfigName).bak" -ForegroundColor Cyan
                        Write-Host "  WARNING: .venv/$pipConfigName points to unknown ADO organization" -ForegroundColor Yellow
                        Write-Host "           '$($cfsResult.OrgName)'. Cannot confirm CFS protection. Replacing" -ForegroundColor Yellow
                        Write-Host '           with known CFS feed.' -ForegroundColor Yellow
                        # Redact sensitive keys before displaying to avoid leaking secrets in CI logs
                        $pipRedactKey = '(?i)((?:password|token)\s*[=:]\s*).+'
                        $pipRedactUrl = '(https?://)([^@/]+)@'
                        Write-Host '           --- Old content ---' -ForegroundColor Yellow
                        $oldPipContent = (Get-Content $pipTarget -Raw) -replace $pipRedactKey, '$1[REDACTED]' -replace $pipRedactUrl, '$1[REDACTED]@'
                        Write-Host $oldPipContent -ForegroundColor Yellow
                        Write-Host '           --- New content (CFS) ---' -ForegroundColor Cyan
                        $newPipContent = (Get-Content $pipSource -Raw) -replace $pipRedactKey, '$1[REDACTED]' -replace $pipRedactUrl, '$1[REDACTED]@'
                        Write-Host $newPipContent -ForegroundColor Cyan
                        Copy-Item -Path $pipSource -Destination $pipTarget -Force
                        Write-Host "  REPLACED: .venv/$pipConfigName" -ForegroundColor Green
                        $result.Created++
                    } else {
                        # Path 6: Invalid config -- backup and replace
                        Copy-Item -Path $pipTarget -Destination $pipBakTarget -Force
                        Write-Host "  BACKUP:  .venv/$pipConfigName -> .venv/$($pipConfigName).bak" -ForegroundColor Cyan
                        Write-Host "  WARNING: .venv/$pipConfigName exists but is not CFS-configured." -ForegroundColor Yellow
                        Write-Host '           Replacing to ensure supply-chain protection.' -ForegroundColor Yellow
                        Write-Host '           Without CFS, packages are fetched from public sources' -ForegroundColor Yellow
                        Write-Host '           without malware or vulnerability scanning.' -ForegroundColor Yellow
                        # Redact sensitive keys before displaying to avoid leaking secrets in CI logs
                        $pipRedactKey = '(?i)((?:password|token)\s*[=:]\s*).+'
                        $pipRedactUrl = '(https?://)([^@/]+)@'
                        Write-Host '           --- Old content ---' -ForegroundColor Yellow
                        $oldPipContent = (Get-Content $pipTarget -Raw) -replace $pipRedactKey, '$1[REDACTED]' -replace $pipRedactUrl, '$1[REDACTED]@'
                        Write-Host $oldPipContent -ForegroundColor Yellow
                        Write-Host '           --- New content (CFS) ---' -ForegroundColor Cyan
                        $newPipContent = (Get-Content $pipSource -Raw) -replace $pipRedactKey, '$1[REDACTED]' -replace $pipRedactUrl, '$1[REDACTED]@'
                        Write-Host $newPipContent -ForegroundColor Cyan
                        Copy-Item -Path $pipSource -Destination $pipTarget -Force
                        Write-Host "  REPLACED: .venv/$pipConfigName" -ForegroundColor Green
                        $result.Created++
                    }
                }
            } else {
                Copy-Item -Path $pipSource -Destination $pipTarget
                Write-Host "  CREATED: .venv/$pipConfigName" -ForegroundColor Green
                $result.Created++
            }
        } else {
            # Bug 517378: keyring failure is FAIL, not SKIPPED -- this is a hard gate.
            # $result.Failed is intentionally incremented again here (in addition to the
            # pip install failure above) because the pip.ini deployment is a separate
            # deliverable that also cannot be completed.
            Write-Host '  FAIL: pip config -- keyring bootstrap failed, not deploying CFS feed config' -ForegroundColor Red
            Write-Host '        without a working credential provider, pip would get 401 errors.' -ForegroundColor Red
            Write-Host '        Fix the keyring installation above and re-run.' -ForegroundColor Red
            $result.Failed++
        }
    }

    return $result
}
