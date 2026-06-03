. (Join-Path $PSScriptRoot 'Install-OrgList.ps1')
$script:ValidCfsOrganizations = Get-ValidCfsOrganization

# Regex for valid internal ADO NuGet v3 feed URLs (project-scoped or org-scoped)
$script:AdoFeedPattern = '^https://pkgs\.dev\.azure\.com/([^/]+)/([^/]+/_packaging/[^/]+|_packaging/[^/]+)/nuget/v3/index\.json$'

function Test-ValidCfsFeed {
    <#
    .SYNOPSIS
        Validates whether a nuget.config XML document contains a valid CFS feed.

    .DESCRIPTION
        Checks that packageSources has exactly one <add> element, the URL matches
        the internal ADO feed pattern, and the organization is in the known org list.
        Does NOT check <clear /> ordering -- that is the caller's responsibility.

    .PARAMETER XmlDoc
        The parsed [xml] document to validate.

    .OUTPUTS
        PSCustomObject with Valid (bool), Organization (string), FeedName (string).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDoc
    )

    Set-StrictMode -Version Latest

    $resultObj = [PSCustomObject]@{
        Valid        = $false
        Organization = ''
        FeedName     = ''
    }

    # Check for packageSources node
    $pkgSources = $XmlDoc.configuration.packageSources
    if ($null -eq $pkgSources) {
        return $resultObj
    }

    # Count <add> elements
    $addElements = @($pkgSources.GetElementsByTagName('add'))
    if ($addElements.Count -ne 1) {
        return $resultObj
    }

    $feedUrl = $addElements[0].GetAttribute('value')
    if ([string]::IsNullOrWhiteSpace($feedUrl)) {
        return $resultObj
    }

    # Match against the ADO feed regex
    if ($feedUrl -notmatch $script:AdoFeedPattern) {
        return $resultObj
    }

    $orgName = $Matches[1]

    # Check org against known list (case-insensitive)
    if ($orgName -inotin $script:ValidCfsOrganizations) {
        $resultObj.Organization = $orgName
        return $resultObj
    }

    # Extract feed name from the URL path segment
    $pathSegment = $Matches[2]
    if ($pathSegment -match '_packaging/([^/]+)') {
        $resultObj.FeedName = $Matches[1]
    }
    $resultObj.Organization = $orgName
    $resultObj.Valid = $true
    return $resultObj
}

function Install-NuGetFeedConfig {
    <#
    .SYNOPSIS
        Installs CFS-backed NuGet feed configuration and credential provider.

    .DESCRIPTION
        Evaluates existing nuget.config using a CFS detection decision tree.
        If the config is already a valid CFS feed it is skipped; if it has a valid
        internal feed but is missing or mis-ordered <clear />, it is fixed in place;
        otherwise it is replaced with the asset nuget.config. Backups are created
        before any write. Also installs the Azure Artifacts Credential Provider.

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
    Write-Host '--- NuGet Configuration ---' -ForegroundColor Cyan

    $hasDotnet = $null -ne (Get-Command 'dotnet' -ErrorAction SilentlyContinue)
    if (-not $hasDotnet) {
        Write-Host '  WARNING: dotnet CLI not found -- skipping NuGet configuration.' -ForegroundColor Yellow
        Write-Host '           Install .NET SDK to enable NuGet feed configuration.' -ForegroundColor Yellow
        $result.Warned++
        return $result
    }

    $nugetSource = Join-Path $AssetsDir 'nuget.config'
    $nugetTarget = Join-Path $ProjectRoot 'nuget.config'
    $nugetBackup = Join-Path $ProjectRoot 'nuget.config.bak'

    if (-not (Test-Path $nugetSource)) {
        Write-Host '  ERROR: nuget.config not found in skill assets.' -ForegroundColor Red
        $result.Failed++
    } elseif (-not (Test-Path $nugetTarget)) {
        # No existing config -- create from asset
        Copy-Item -Path $nugetSource -Destination $nugetTarget
        Write-Host '  CREATED: nuget.config' -ForegroundColor Green
        $result.Created++
    } else {
        # Existing nuget.config -- run CFS detection decision tree
        $existingContent = (Get-Content $nugetTarget -Raw).Trim() -replace '\r\n', "`n"
        $assetContent    = (Get-Content $nugetSource -Raw).Trim() -replace '\r\n', "`n"

        if ($existingContent -eq $assetContent) {
            Write-Host '  SKIPPED: nuget.config already configured for CFS' -ForegroundColor Green
            $result.Skipped++
        } else {
            # Step 1: Try to parse as XML
            $xmlDoc = $null
            $parseOk = $true
            try {
                $xmlDoc = [xml](Get-Content $nugetTarget -Raw)
            } catch {
                $parseOk = $false
            }

            if (-not $parseOk -or $null -eq $xmlDoc) {
                # Malformed XML -- backup then replace
                Copy-Item -Path $nugetTarget -Destination $nugetBackup -Force
                Write-Host '  BACKUP:  nuget.config -> nuget.config.bak' -ForegroundColor Cyan
                Write-Host '  WARNING: nuget.config contains malformed XML and cannot be validated.' -ForegroundColor Yellow
                Write-Host '           Replacing with CFS configuration.' -ForegroundColor Yellow
                Copy-Item -Path $nugetSource -Destination $nugetTarget -Force
                Write-Host '  REPLACED: nuget.config' -ForegroundColor Green
                $result.Created++
            } else {
                # Step 2: Validate feed source
                $feedCheck = Test-ValidCfsFeed -XmlDoc $xmlDoc

                if (-not $feedCheck.Valid) {
                    # Not a valid internal CFS feed -- backup then replace
                    Copy-Item -Path $nugetTarget -Destination $nugetBackup -Force
                    Write-Host '  BACKUP:  nuget.config -> nuget.config.bak' -ForegroundColor Cyan

                    if (-not [string]::IsNullOrWhiteSpace($feedCheck.Organization) -and
                        $feedCheck.Organization -inotin $script:ValidCfsOrganizations) {
                        Write-Host "  WARNING: nuget.config points to unknown ADO organization '$($feedCheck.Organization)'." -ForegroundColor Yellow
                        Write-Host '           Cannot confirm CFS protection. Replacing with known CFS feed.' -ForegroundColor Yellow
                    } else {
                        Write-Host '  WARNING: nuget.config exists with different content.' -ForegroundColor Yellow
                        Write-Host '           Replacing with CFS configuration to ensure supply-chain protection.' -ForegroundColor Yellow
                        Write-Host '           Without CFS, packages are fetched from public sources without malware or vulnerability scanning.' -ForegroundColor Yellow
                    }

                    Write-Host '           --- Old content ---' -ForegroundColor Yellow
                    Write-Host (Get-Content $nugetTarget -Raw) -ForegroundColor Yellow
                    Write-Host '           --- New content (CFS) ---' -ForegroundColor Cyan
                    Write-Host (Get-Content $nugetSource -Raw) -ForegroundColor Cyan
                    Copy-Item -Path $nugetSource -Destination $nugetTarget -Force
                    Write-Host '  REPLACED: nuget.config' -ForegroundColor Green
                    $result.Created++
                } else {
                    # Step 3: Check <clear /> presence and ordering
                    $pkgSources = $xmlDoc.configuration.packageSources
                    $childNodes = @($pkgSources.ChildNodes)
                    $clearNodes = @($childNodes | Where-Object { $_.Name -eq 'clear' })
                    $addNodes   = @($childNodes | Where-Object { $_.Name -eq 'add' })

                    if ($clearNodes.Count -gt 0) {
                        # Find positions
                        $clearIndex = -1
                        $addIndex   = -1
                        for ($i = 0; $i -lt $childNodes.Count; $i++) {
                            if ($childNodes[$i].Name -eq 'clear' -and $clearIndex -eq -1) {
                                $clearIndex = $i
                            }
                            if ($childNodes[$i].Name -eq 'add' -and $addIndex -eq -1) {
                                $addIndex = $i
                            }
                        }

                        if ($clearIndex -lt $addIndex) {
                            # <clear /> is before <add> -- valid CFS config
                            Write-Host '  SKIPPED: nuget.config already configured with a valid CFS feed' -ForegroundColor Green
                            Write-Host "           Organization: $($feedCheck.Organization) | Feed: $($feedCheck.FeedName)" -ForegroundColor Cyan
                            $result.Skipped++
                        } else {
                            # <clear /> is after <add> -- backup then reorder
                            Copy-Item -Path $nugetTarget -Destination $nugetBackup -Force
                            Write-Host '  BACKUP:  nuget.config -> nuget.config.bak' -ForegroundColor Cyan
                            Write-Host '  WARNING: nuget.config has a valid internal feed but <clear />' -ForegroundColor Yellow
                            Write-Host '           is after <add>. Reordering so <clear /> comes first.' -ForegroundColor Yellow
                            Write-Host "           Organization: $($feedCheck.Organization) | Feed: $($feedCheck.FeedName)" -ForegroundColor Cyan

                            # Remove the clear node and re-insert before add
                            $clearNode = $clearNodes[0]
                            $null = $pkgSources.RemoveChild($clearNode)
                            $null = $pkgSources.InsertBefore($clearNode, $addNodes[0])
                            $xmlDoc.Save($nugetTarget)
                            Write-Host '  FIXED:   nuget.config -- reordered <clear /> before existing feed' -ForegroundColor Green
                            $result.Created++
                        }
                    } else {
                        # No <clear /> -- backup then inject
                        Copy-Item -Path $nugetTarget -Destination $nugetBackup -Force
                        Write-Host '  BACKUP:  nuget.config -> nuget.config.bak' -ForegroundColor Cyan
                        Write-Host '  WARNING: nuget.config has a valid internal feed but is missing' -ForegroundColor Yellow
                        Write-Host '           <clear />. Public/inherited sources may leak through.' -ForegroundColor Yellow
                        Write-Host '           Adding <clear /> to seal the configuration.' -ForegroundColor Yellow
                        Write-Host "           Organization: $($feedCheck.Organization) | Feed: $($feedCheck.FeedName)" -ForegroundColor Cyan

                        $clearElement = $xmlDoc.CreateElement('clear')
                        $null = $pkgSources.InsertBefore($clearElement, $addNodes[0])
                        $xmlDoc.Save($nugetTarget)
                        Write-Host '  FIXED:   nuget.config -- added <clear /> before existing feed' -ForegroundColor Green
                        $result.Created++
                    }
                }
            }
        }
    }

    # Install artifacts-credprovider
    Write-Host '  Installing Azure Artifacts Credential Provider...' -ForegroundColor Cyan
    try {
        if ($RunningOnWindows) {
            $cpScript = Invoke-WebRequest -Uri 'https://aka.ms/install-artifacts-credprovider.ps1' -UseBasicParsing
            $tempFile = [System.IO.Path]::GetTempFileName() + '.ps1'
            [System.IO.File]::WriteAllText($tempFile, $cpScript.Content)
            $null = & pwsh -NoProfile -File $tempFile 2>&1
            Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
        } else {
            $cpScript = Invoke-WebRequest -Uri 'https://aka.ms/install-artifacts-credprovider.sh' -UseBasicParsing
            $tempFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tempFile, $cpScript.Content)
            $null = & sh $tempFile 2>&1
            Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
        }
        Write-Host '  INSTALLED: artifacts-credprovider' -ForegroundColor Green
        $result.Created++
    } catch {
        Write-Host "  WARNING: Could not install artifacts-credprovider: $_" -ForegroundColor Yellow
        Write-Host '           You may need to install it manually. See: https://github.com/microsoft/artifacts-credprovider' -ForegroundColor Yellow
        $result.Warned++
    }

    return $result
}
