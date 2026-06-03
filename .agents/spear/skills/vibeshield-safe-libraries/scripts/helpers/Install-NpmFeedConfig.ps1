. (Join-Path $PSScriptRoot 'Install-OrgList.ps1')
$script:ValidCfsOrganizations = Get-ValidCfsOrganization

function Test-ValidCfsNpmFeed {
    <#
    .SYNOPSIS
        Validates whether .npmrc lines represent a valid CFS-backed npm feed.

    .DESCRIPTION
        Parses .npmrc content line-by-line and checks:
        - Exactly one global registry= line (not scoped)
        - URL matches internal ADO npm feed pattern
        - Organization is in the known-org list (case-insensitive)
        - No scoped registries point to non-internal feeds

    .PARAMETER Lines
        Array of strings representing .npmrc lines.

    .OUTPUTS
        PSCustomObject with IsValid, Organization, IsKnownOrg, Reason.
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

    $feedPattern = '^https://pkgs\.dev\.azure\.com/([^/]+)/([^/]+/_packaging/[^/]+|_packaging/[^/]+)/npm/registry/?$'

    $output = [PSCustomObject]@{
        IsValid    = $false
        Organization = $null
        IsKnownOrg = $false
        Reason     = $null
    }

    # Filter out comments (# or ;) and blank lines
    $effectiveLines = @($Lines | Where-Object {
        $trimmed = $_.Trim()
        -not [string]::IsNullOrWhiteSpace($trimmed) -and
        -not $trimmed.StartsWith('#') -and
        -not $trimmed.StartsWith(';')
    })

    # Separate global registry= from @scope:registry=
    $globalRegistryLines = @($effectiveLines | Where-Object {
        $_.Trim() -match '^registry=' -and $_.Trim() -notmatch '^@'
    })
    $scopedRegistryLines = @($effectiveLines | Where-Object {
        $_.Trim() -match '^@[^:]+:registry='
    })

    # Validate exactly one global registry= line
    if ($globalRegistryLines.Count -ne 1) {
        if ($globalRegistryLines.Count -eq 0) {
            $output.Reason = 'No global registry= line found'
        } else {
            $output.Reason = 'Multiple global registry= lines found'
        }
        return $output
    }

    # Extract the URL from the registry= line
    $registryLine = $globalRegistryLines[0].Trim()
    $registryUrl = $registryLine -replace '^registry=\s*', ''

    # Match against the ADO feed pattern
    if ($registryUrl -notmatch $feedPattern) {
        $output.Reason = 'Registry URL does not match internal ADO npm feed pattern'
        return $output
    }

    $org = $Matches[1]
    $output.Organization = $org

    # Case-insensitive org check
    $output.IsKnownOrg = $org -iin $script:ValidCfsOrganizations

    if (-not $output.IsKnownOrg) {
        $output.Reason = 'Organization is not in known CFS org list'
        return $output
    }

    # Check scoped registries - all must point to internal feeds
    foreach ($scopedLine in $scopedRegistryLines) {
        $scopedUrl = ($scopedLine.Trim() -replace '^@[^:]+:registry=\s*', '')
        if ($scopedUrl -notmatch $feedPattern) {
            $output.Reason = 'Scoped registry points to non-internal feed'
            return $output
        }
    }

    $output.IsValid = $true
    return $output
}

function Install-NpmFeedConfig {
    <#
    .SYNOPSIS
        Installs CFS-backed npm feed configuration and vsts-npm-auth.

    .DESCRIPTION
        Copies .npmrc from skill assets to the project root and installs
        vsts-npm-auth globally. Validates existing .npmrc for CFS compliance
        using the decision tree before deciding to skip or replace.

    .PARAMETER ProjectRoot
        Absolute path to the project root directory.

    .PARAMETER AssetsDir
        Absolute path to the skill assets directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$AssetsDir
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = [PSCustomObject]@{ Created = 0; Skipped = 0; Warned = 0; Failed = 0 }

    Write-Host '' -ForegroundColor Cyan
    Write-Host '--- npm Configuration ---' -ForegroundColor Cyan

    $hasNpm = $null -ne (Get-Command 'npm' -ErrorAction SilentlyContinue)
    if (-not $hasNpm) {
        # Probe Agency-managed Node.js for npm
        $agencyNodeDir = Join-Path -Path $HOME -ChildPath '.agency' -AdditionalChildPath 'nodejs'
        if (Test-Path -LiteralPath $agencyNodeDir) {
            $nodeDirs = @(Get-ChildItem -Path $agencyNodeDir -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue)
            if ($nodeDirs.Count -gt 0) {
                $latestDir = $nodeDirs | Sort-Object -Property Name -Descending | Select-Object -First 1
                if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
                    $npmBinary = 'npm.cmd'
                }
                else {
                    $npmBinary = 'npm'
                }
                $npmPath = Join-Path -Path $latestDir.FullName -ChildPath $npmBinary
                if (Test-Path -LiteralPath $npmPath) {
                    $env:PATH = '{0}{1}{2}' -f $latestDir.FullName, [System.IO.Path]::PathSeparator, $env:PATH
                    Write-Verbose -Message ('Added Agency-managed Node.js to PATH: {0}' -f $latestDir.FullName)
                    $hasNpm = $true
                }
            }
        }
    }
    if (-not $hasNpm) {
        Write-Host '  WARNING: npm not found -- skipping npm configuration.' -ForegroundColor Yellow
        Write-Host '           Install Node.js or run agency copilot to enable npm feed configuration.' -ForegroundColor Yellow
        $result.Warned++
        return $result
    }

    $npmrcSource = Join-Path $AssetsDir '.npmrc'
    $npmrcTarget = Join-Path $ProjectRoot '.npmrc'

    if (-not (Test-Path $npmrcSource)) {
        Write-Host '  ERROR: .npmrc not found in skill assets.' -ForegroundColor Red
        $result.Failed++
    } elseif (Test-Path $npmrcTarget) {
        # Check for exact match first (fast path)
        $rawExisting = Get-Content $npmrcTarget -Raw
        $existingContent = if ($null -eq $rawExisting) { '' } else { $rawExisting.Trim() -replace '\r\n', "`n" }
        $assetContent = (Get-Content $npmrcSource -Raw).Trim() -replace '\r\n', "`n"
        if ($existingContent -eq $assetContent) {
            Write-Host '  SKIPPED: .npmrc already configured for CFS' -ForegroundColor Green
            $result.Skipped++
        } else {
            # CFS detection decision tree
            $existingLines = @(Get-Content $npmrcTarget)
            $cfsResult = Test-ValidCfsNpmFeed -Lines $existingLines

            if ($cfsResult.IsValid) {
                # Path 3: Valid CFS from a known org
                Write-Host '  SKIPPED: .npmrc already configured with a valid CFS feed' -ForegroundColor Green
                Write-Host ('           Organization: {0}' -f $cfsResult.Organization) -ForegroundColor Cyan
                $result.Skipped++
            } else {
                # Backup before replacement
                $bakTarget = Join-Path $ProjectRoot '.npmrc.bak'
                Copy-Item -Path $npmrcTarget -Destination $bakTarget -Force
                Write-Host '  BACKUP:  .npmrc -> .npmrc.bak' -ForegroundColor Cyan

                if ($null -ne $cfsResult.Organization -and -not $cfsResult.IsKnownOrg) {
                    # Path 4: Unknown ADO org
                    Write-Host ('  WARNING: .npmrc points to unknown ADO organization ''{0}''.' -f $cfsResult.Organization) -ForegroundColor Yellow
                    Write-Host '           Cannot confirm CFS protection. Replacing with known' -ForegroundColor Yellow
                    Write-Host '           CFS feed.' -ForegroundColor Yellow
                } else {
                    # Path 5: Invalid config (public, multiple registries, etc.)
                    Write-Host '  WARNING: .npmrc exists but is not CFS-configured.' -ForegroundColor Yellow
                    Write-Host '           Replacing to ensure supply-chain protection.' -ForegroundColor Yellow
                    Write-Host '           Without CFS, packages are fetched from public sources' -ForegroundColor Yellow
                    Write-Host '           without malware or vulnerability scanning.' -ForegroundColor Yellow
                }

                # Redact sensitive keys before displaying to avoid leaking secrets in CI logs
                $secretRedactPattern = '((?:_authToken|_auth|_password)\s*=\s*).+'
                $secretRedactReplace = '$1[REDACTED]'

                Write-Host '           --- Old content ---' -ForegroundColor Yellow
                $oldContent = (Get-Content $npmrcTarget -Raw) -replace $secretRedactPattern, $secretRedactReplace
                Write-Host $oldContent -ForegroundColor Yellow
                Write-Host '           --- New content (CFS) ---' -ForegroundColor Cyan
                $newContent = (Get-Content $npmrcSource -Raw) -replace $secretRedactPattern, $secretRedactReplace
                Write-Host $newContent -ForegroundColor Cyan

                Copy-Item -Path $npmrcSource -Destination $npmrcTarget -Force
                Write-Host '  REPLACED: .npmrc' -ForegroundColor Green
                $result.Created++
            }
        }
    } else {
        Copy-Item -Path $npmrcSource -Destination $npmrcTarget
        Write-Host '  CREATED: .npmrc' -ForegroundColor Green
        $result.Created++
    }

    # Install vsts-npm-auth globally
    Write-Host '  Installing vsts-npm-auth globally...' -ForegroundColor Cyan
    try {
        & npm install -g vsts-npm-auth 2>&1 | Out-Null
        Write-Host '  INSTALLED: vsts-npm-auth' -ForegroundColor Green
        $result.Created++
    } catch {
        Write-Host "  WARNING: Could not install vsts-npm-auth: $_" -ForegroundColor Yellow
        Write-Host '           Run manually: npm install -g vsts-npm-auth' -ForegroundColor Yellow
        $result.Warned++
    }

    Write-Host '' -ForegroundColor Cyan
    Write-Host '  REMINDER: Run the following command once per terminal session before using npm:' -ForegroundColor Yellow
    Write-Host '            npx vsts-npm-auth -config .npmrc' -ForegroundColor Yellow

    return $result
}
