function Test-FeedConnectivity {
    <#
    .SYNOPSIS
        Multi-tier connectivity and provider check for the Azure Artifacts CFS feed.

    .DESCRIPTION
        Tests feed usability in three tiers. Each tier short-circuits on failure
        with an actionable message. This is advisory only -- failures produce
        warnings, not errors.

        Tier 1 - DNS Resolution:  Resolves the feed hostname. Failure means
                 DNS is broken or the machine is offline.
        Tier 2 - TCP Connection:  Opens a TCP socket to port 443. Failure
                 means a firewall, proxy, or VPN is blocking the connection.
        Tier 3 - Provider Smoke Tests:  For each ecosystem whose config file
                 was installed (nuget.config, .npmrc, pip in .venv), runs a
                 lightweight non-interactive command to verify the credential
                 provider is functional and the feed is configured.

    .PARAMETER ProjectRoot
        Absolute path to the project root directory. Used to locate config
        files (nuget.config, .npmrc, .venv) for Tier 3 checks.

    .PARAMETER FeedUrl
        URL used to derive the hostname for DNS and TCP checks. Defaults to
        the CFS NuGet v3 index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$FeedUrl = 'https://pkgs.dev.azure.com/oneCELA/CELA_Demos_and_POCs/_packaging/CELADemosAndPOCs/nuget/v3/index.json'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = [PSCustomObject]@{ Created = 0; Skipped = 0; Warned = 0; Failed = 0 }

    Write-Host '' -ForegroundColor Cyan
    Write-Host '--- Connectivity Check ---' -ForegroundColor Cyan

    $feedUri  = [System.Uri]::new($FeedUrl)
    $hostname = $feedUri.Host
    $port     = if ($feedUri.Port -gt 0) { $feedUri.Port } else { 443 }

    # -----------------------------------------------------------------------
    # Tier 1 -- DNS Resolution
    # -----------------------------------------------------------------------
    Write-Host "  Tier 1: DNS resolution for $hostname" -ForegroundColor Cyan
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($hostname))
        if ($addresses.Count -eq 0) {
            Write-Host "  WARNING: DNS resolved but returned no addresses for $hostname." -ForegroundColor Yellow
            Write-Host '           Check network settings or VPN connection.' -ForegroundColor Yellow
            $result.Warned++
            return $result
        }
        Write-Host "  PASS:  $hostname resolved to $($addresses[0])." -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: DNS lookup failed for $hostname." -ForegroundColor Yellow
        Write-Host '           The machine may be offline or DNS is misconfigured.' -ForegroundColor Yellow
        $result.Warned++
        return $result
    }

    # -----------------------------------------------------------------------
    # Tier 2 -- TCP Connection
    # -----------------------------------------------------------------------
    Write-Host "  Tier 2: TCP connection to ${hostname}:${port}" -ForegroundColor Cyan
    $tcpClient = $null
    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $tcpClient.ConnectAsync($hostname, $port)
        if (-not $connectTask.Wait(10000)) {
            Write-Host "  WARNING: TCP connection to ${hostname}:${port} timed out." -ForegroundColor Yellow
            Write-Host '           A firewall, proxy, or VPN may be blocking the connection.' -ForegroundColor Yellow
            $result.Warned++
            return $result
        }
        if ($connectTask.IsFaulted) {
            throw $connectTask.Exception.InnerException
        }
        Write-Host "  PASS:  TCP connection to ${hostname}:${port} succeeded." -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: TCP connection to ${hostname}:${port} failed." -ForegroundColor Yellow
        Write-Host "           $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '           A firewall, proxy, or VPN may be blocking the connection.' -ForegroundColor Yellow
        $result.Warned++
        return $result
    } finally {
        if ($null -ne $tcpClient) { $tcpClient.Dispose() }
    }

    # -----------------------------------------------------------------------
    # Tier 3 -- Provider Smoke Tests (only for configured ecosystems)
    # -----------------------------------------------------------------------
    Write-Host '  Tier 3: Credential-provider smoke tests' -ForegroundColor Cyan
    $feedName = 'CELADemosAndPOCs'

    # -- NuGet --
    $nugetConfig = Join-Path $ProjectRoot 'nuget.config'
    if (Test-Path $nugetConfig) {
        $dotnetCmd = Get-Command 'dotnet' -ErrorAction SilentlyContinue
        if ($dotnetCmd) {
            try {
                $sourceOutput = & dotnet nuget list source --configfile $nugetConfig 2>&1
                $sourceText = ($sourceOutput | Out-String)
                if ($sourceText -match $feedName) {
                    Write-Host "  PASS:  NuGet -- $feedName feed is configured." -ForegroundColor Green
                } else {
                    Write-Host "  WARNING: NuGet -- $feedName feed not found in dotnet nuget list source." -ForegroundColor Yellow
                    Write-Host '           Run: dotnet nuget list source --configfile nuget.config' -ForegroundColor Yellow
                    $result.Warned++
                }
            } catch {
                Write-Host '  WARNING: NuGet -- dotnet nuget list source failed.' -ForegroundColor Yellow
                Write-Host "           $($_.Exception.Message)" -ForegroundColor Yellow
                $result.Warned++
            }
        } else {
            Write-Host '  SKIP:  NuGet -- dotnet not found on PATH.' -ForegroundColor DarkGray
        }
    } else {
        Write-Host '  SKIP:  NuGet -- nuget.config not found.' -ForegroundColor DarkGray
    }

    # -- pip --
    $runningOnWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    $pipSubDir = if ($runningOnWindows) { 'Scripts' } else { 'bin' }
    $pipExeName = if ($runningOnWindows) { 'pip.exe' } else { 'pip' }
    $pythonExeName = if ($runningOnWindows) { 'python.exe' } else { 'python' }
    $pipExe = Join-Path $ProjectRoot (Join-Path '.venv' (Join-Path $pipSubDir $pipExeName))
    $pythonExe = Join-Path $ProjectRoot (Join-Path '.venv' (Join-Path $pipSubDir $pythonExeName))
    if (Test-Path $pipExe) {
        # Check 1: artifacts-keyring package is installed
        try {
            $pipOutput = & $pipExe show artifacts-keyring 2>&1
            $pipText = ($pipOutput | Out-String)
            if ($pipText -match 'artifacts-keyring') {
                Write-Host '  PASS:  pip  -- artifacts-keyring is installed in .venv.' -ForegroundColor Green
            } else {
                Write-Host '  WARNING: pip  -- artifacts-keyring not found in .venv.' -ForegroundColor Yellow
                $remedPip = Join-Path (Join-Path '.venv' $pipSubDir) $pipExeName
                Write-Host "           Run: $remedPip install artifacts-keyring" -ForegroundColor Yellow
                $result.Warned++
            }
        } catch {
            Write-Host '  WARNING: pip  -- pip show artifacts-keyring failed.' -ForegroundColor Yellow
            Write-Host "           $($_.Exception.Message)" -ForegroundColor Yellow
            $result.Warned++
        }
        # Check 2: Verify keyring backend is registered
        if (Test-Path $pythonExe) {
            try {
                $backends = & $pythonExe -m keyring --list-backends 2>&1
                $backendText = ($backends | Out-String)
                if ($LASTEXITCODE -eq 0 -and $backendText -match 'ArtifactsKeyringBackend') {
                    Write-Host '  PASS:  pip  -- ArtifactsKeyringBackend is registered.' -ForegroundColor Green
                } else {
                    Write-Host '  WARNING: pip  -- ArtifactsKeyringBackend not found in keyring backends.' -ForegroundColor Yellow
                    Write-Host "           Backends: $($backendText.Trim())" -ForegroundColor Yellow
                    $result.Warned++
                }
            } catch {
                Write-Host '  WARNING: pip  -- keyring --list-backends failed.' -ForegroundColor Yellow
                Write-Host "           $($_.Exception.Message)" -ForegroundColor Yellow
                $result.Warned++
            }
        }
    } else {
        Write-Host '  SKIP:  pip  -- .venv not found.' -ForegroundColor DarkGray
    }

    # -- npm --
    $npmrcFile = Join-Path $ProjectRoot '.npmrc'
    if (Test-Path $npmrcFile) {
        $npmCmd = Get-Command 'npm' -ErrorAction SilentlyContinue
        if ($npmCmd) {
            try {
                # Suppress PSAvoidUsingPositionalParameters -- npm is an external tool, not a PowerShell cmdlet
                $npmArgs = @('config', 'get', 'registry', '--userconfig', $npmrcFile)
                $registryOutput = & npm @npmArgs 2>&1
                $registryText = ($registryOutput | Out-String)
                if ($registryText -match $feedName) {
                    Write-Host "  PASS:  npm  -- registry points to $feedName feed." -ForegroundColor Green
                } else {
                    Write-Host "  WARNING: npm  -- registry does not point to $feedName feed." -ForegroundColor Yellow
                    Write-Host "           Got: $($registryText.Trim())" -ForegroundColor Yellow
                    $result.Warned++
                }
            } catch {
                Write-Host '  WARNING: npm  -- npm config get registry failed.' -ForegroundColor Yellow
                Write-Host "           $($_.Exception.Message)" -ForegroundColor Yellow
                $result.Warned++
            }
        } else {
            Write-Host '  SKIP:  npm  -- npm not found on PATH.' -ForegroundColor DarkGray
        }
    } else {
        Write-Host '  SKIP:  npm  -- .npmrc not found.' -ForegroundColor DarkGray
    }

    return $result
}
