#requires -Version 7.0
<#
.SYNOPSIS
    Installs Copilot CLI MCP server configuration into the target project.

.DESCRIPTION
    Ensures the target project has a .mcp.json file at the repo root with
    entries for the Bicep and Azure MCP servers required by the vibeshield-bicep
    agent.

    If .mcp.json does not exist, creates it from the skill asset template.
    If .mcp.json exists but is missing one or both server entries, adds the
    missing entries without disturbing existing configuration.
    If .mcp.json already contains both entries, skips without modification.

    After configuring .mcp.json, the script performs best-effort installation
    of MCP server tools. Both the Bicep MCP server and Azure MCP server are
    managed as .NET global tools:
      - dotnet tool install/update -g Azure.Bicep.McpServer
      - dotnet tool install/update -g azure.mcp

    This script EXITS NON-ZERO when a required MCP server tool fails to
    install or its shim cannot be resolved on PATH after install. The
    parent install pipeline must surface this as an actionable failure
    (the previous "always exit 0" comment was tied to an obsolete
    orchestrator contract and has been removed).

.PARAMETER ProjectPath
    Optional. Path to the project root. If omitted, the script dot-sources
    Resolve-RepoRoot.ps1 and walks up the directory tree to find the .git
    directory, falling back to the current working directory.

.EXAMPLE
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-McpConfig.ps1

.EXAMPLE
    pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-McpConfig.ps1 -ProjectPath C:\myproject

.NOTES
    Exit Codes:
      0 - .mcp.json configured and all required MCP tool shims are
          resolvable on PATH (or the script intentionally skipped tool
          install because dotnet CLI was not available).
      1 - One or more MCP tool installs failed, OR a tool install
          succeeded but the shim could not be resolved on PATH after a
          registry-backed PATH refresh. Inspect the WARNING messages
          for the specific failure and remediation.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Tracks failures from tool install/repair/resolution so the script can
# emit a single accurate exit code at the end (P0-5).
$script:McpInstallFailures = New-Object System.Collections.Generic.List[string]

try {
    # -------------------------------------------------------------------
    # Resolve project root
    # -------------------------------------------------------------------
    . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
    if ($ProjectPath) {
        $projectRoot = $ProjectPath
    } else {
        $projectRoot = Resolve-RepoRoot
        if (-not $projectRoot) { $projectRoot = (Get-Location).Path }
    }
    $projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

    # ADO #525806 - Sidecar log directory for raw dotnet failure output.
    # Per constitution: 'All build artifacts ... are written to ./output/ by
    # default.' We write per-failure logs here (one per classified dotnet
    # tool install/update failure) so the FULL raw output is preserved for
    # diagnostics while the user-facing warning stays short and actionable.
    # Resolved once here so the in-script Invoke-DotNetToolAction helper can
    # reach it via $script: scope without re-resolving paths.
    $script:McpFailureLogDir = Join-Path -Path $projectRoot -ChildPath 'output'

    # -------------------------------------------------------------------
    # Resolve asset template path
    # -------------------------------------------------------------------
    $assetsDir = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'assets'))
    $assetSource = Join-Path $assetsDir 'mcp.json'

    if (-not (Test-Path $assetSource)) {
        Write-Host "  WARNING: Asset template not found at $assetSource - cannot install MCP config." -ForegroundColor Yellow
        exit 0
    }

    $mcpTarget = Join-Path $projectRoot '.mcp.json'

    # -------------------------------------------------------------------
    # Read asset template (needed for both create and merge paths)
    # -------------------------------------------------------------------
    $assetRaw = Get-Content -Path $assetSource -Raw -Encoding UTF8
    $assetJson = $assetRaw | ConvertFrom-Json

    $assetServers = $assetJson.mcpServers
    if (-not $assetServers) {
        Write-Host "  WARNING: Asset template at $assetSource is missing 'mcpServers' key - re-install the vibeshield-bicep skill to restore it." -ForegroundColor Yellow
        exit 0
    }
    $assetServerNames = @(Get-Member -InputObject $assetServers -MemberType NoteProperty | Select-Object -ExpandProperty Name)

    # -------------------------------------------------------------------
    # Case 1: .mcp.json does not exist - copy from asset
    # -------------------------------------------------------------------
    if (-not (Test-Path $mcpTarget)) {
        Copy-Item -Path $assetSource -Destination $mcpTarget -Force
        Write-Host "  CREATED: .mcp.json (copied from asset template)" -ForegroundColor Green
        Write-Host "  MCP config: $($assetServerNames.Count) server(s) added, 0 skipped." -ForegroundColor Cyan
    } else {
        # -------------------------------------------------------------------
        # Case 2 & 3: .mcp.json exists - check and merge
        # -------------------------------------------------------------------
        $existingRaw = Get-Content -Path $mcpTarget -Raw -Encoding UTF8
        $existingJson = $existingRaw | ConvertFrom-Json

        # Ensure mcpServers property exists
        if (-not (Get-Member -InputObject $existingJson -Name 'mcpServers' -MemberType Properties)) {
            $existingJson | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([pscustomobject]@{})
        }

        $addedCount = 0
        $skippedCount = 0

        $existingServerNames = @(Get-Member -InputObject $existingJson.mcpServers -MemberType NoteProperty | Select-Object -ExpandProperty Name)

        foreach ($serverName in $assetServerNames) {
            $alreadyPresent = $false
            foreach ($existing in $existingServerNames) {
                if ($existing.Equals($serverName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $alreadyPresent = $true
                    break
                }
            }

            if ($alreadyPresent) {
                Write-Host "  SKIPPED: $serverName (already configured)" -ForegroundColor Cyan
                $skippedCount++
            } else {
                $serverValue = $assetServers.$serverName
                $existingJson.mcpServers | Add-Member -NotePropertyName $serverName -NotePropertyValue $serverValue
                Write-Host "  ADDED: $serverName" -ForegroundColor Green
                $addedCount++
            }
        }

        if ($addedCount -gt 0) {
            $jsonText = $existingJson | ConvertTo-Json -Depth 10
            Set-Content -Path $mcpTarget -Value $jsonText -Encoding UTF8
        }

        Write-Host "  MCP config: $addedCount added, $skippedCount skipped." -ForegroundColor Cyan
    }

    # -------------------------------------------------------------------
    # Step 2: Best-effort MCP server tool installation
    # -------------------------------------------------------------------

    # Convert dotnet CLI output (mixed strings + ErrorRecord items) into a
    # single string preserving stdout AND stderr. The previous implementation
    # filtered to ErrorRecord-only, which silently dropped useful diagnostics
    # when failures came through stdout (e.g. "Tool 'X' failed to install.").
    function Format-DotNetOutput {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][object[]]$Output)
        $parts = foreach ($item in @($Output)) {
            if ($null -eq $item) { continue }
            if ($item -is [System.Management.Automation.ErrorRecord]) { $item.ToString() }
            else { [string]$item }
        }
        return ($parts -join [Environment]::NewLine)
    }

    # ADO #525806 - Pure function: classify a 'dotnet tool install/update'
    # failure into one of: ServiceIndexUnreachable, Conflicts,
    # DotnetToolSettingsMissing, TfmMismatch, Unknown. Returns the raw text
    # (OriginalOutput), a credential-provider-stripped variant
    # (FilteredOutput), a single-line user-facing summary, an actionable
    # remediation hint, and category-specific captures.
    #
    # NO SIDE EFFECTS. The helper does NOT mutate $script:McpInstallFailures,
    # does NOT call Write-Host/Write-Warning, and does NOT touch the file
    # system. Callers decide how to surface the result (the script writes a
    # sidecar log + Write-Host; tests can assert on the structured return
    # value without mocking anything).
    #
    # Pattern order matters: most-specific signal first. The credential-
    # provider chatter from the Azure Artifacts Credential Provider
    # (e.g. '[NuGet Manager] [Info] [CredentialProvider]VstsCredentialProvider ...')
    # is stripped from FilteredOutput so even the 'full' output the user
    # sees in the verbose log isn't dominated by chatter that points them
    # at an authentication rabbit hole; the truly-raw text stays in
    # OriginalOutput and the sidecar file for diagnostics.
    function Get-DotNetToolFailureSummary {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$OutputText,
            [string]$PackageId
        )

        $text = if ($null -eq $OutputText) { '' } else { $OutputText }
        $pkgLabel = if ([string]::IsNullOrWhiteSpace($PackageId)) { 'the .NET global tool' } else { "'$PackageId'" }

        # Split on either \r\n or \n; strip credential-provider chatter
        # lines for the filtered view. Non-prefixed content (including the
        # actually-actionable 'Unable to load the service index...' line)
        # is preserved verbatim.
        $allLines = @($text -split "`r?`n")
        $filteredLines = @($allLines | Where-Object {
            $_ -notmatch '^\s*\[NuGet Manager\]\s*\[Info\]\s*\[CredentialProvider\]'
        })
        $filtered = ($filteredLines -join [Environment]::NewLine)

        $result = [pscustomobject]@{
            Category        = 'Unknown'
            OneLineSummary  = $null
            RemediationHint = $null
            OriginalOutput  = $text
            FilteredOutput  = $filtered
            MatchedTokens   = @{}
        }

        # 1. Conflicts -- shim already claimed by another command. Same
        # phrase the C1 (ADO #525807) regex arm uses; this classifier
        # replaces that inline -match going forward.
        if ($text -match '(?i)conflicts\s+with\s+an\s+existing\s+command\s+from\s+another\s+tool') {
            $cmd = $null
            if ($text -match "(?i)Command\s+'([^']+)'\s+conflicts") {
                $cmd = $matches[1]
            }
            $cmdDisplay = if ($cmd) { "'$cmd'" } else { 'a shim command' }
            # R2 S5: substitute the captured ConflictingCommand into the
            # remediation hint so it's copy-pasteable instead of leaving
            # a literal '<cmd>' placeholder (rubric Actionability).
            # R2 F3: render the shim filename list through Get-PlatformShimVariant
            # so the user-facing remediation hint matches what the production
            # deletion code (Remove-DotNetToolOrphanShim) would actually write
            # on the current platform -- '<cmd>.exe/.cmd/.ps1' on Windows,
            # extensionless '<cmd>' on Linux/macOS.
            $shimsForHint = if ($cmd) {
                $variants = Get-PlatformShimVariant -Command $cmd
                $quoted = ($variants | ForEach-Object { "'$_'" }) -join ', '
                "the $quoted shim files for command '$cmd'"
            } else {
                if ($IsWindows) {
                    "the matching '<cmd>.exe', '<cmd>.cmd', '<cmd>.ps1' shim files (run 'dotnet tool list -g' to identify <cmd>)"
                } else {
                    "the matching '<cmd>' shim file (run 'dotnet tool list -g' to identify <cmd>)"
                }
            }
            $result.Category = 'Conflicts'
            $result.OneLineSummary = "Shim conflict installing ${pkgLabel}: command $cmdDisplay is already claimed by an existing shim under '~/.dotnet/tools/' (likely an orphan from a prior install)."
            $result.RemediationHint = "Run 'dotnet tool list -g' to find the owning package. If no registered tool owns the command, the shim is orphaned: delete $shimsForHint under '~/.dotnet/tools/' and re-run 'dotnet tool install -g $PackageId'. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)."
            $result.MatchedTokens = @{ ConflictingCommand = $cmd }
            return $result
        }

        # 2. TFM mismatch -- the SDK explicitly rejects the package's TFM.
        # This is rarer than the cache-corruption surface text below, but
        # when dotnet emits it explicitly we classify it as TfmMismatch so
        # the user gets an SDK-install hint instead of a cache-wipe hint.
        # The DotnetToolSettings.xml surface (next arm) AND a low SDK
        # version is also a TFM mismatch in practice, but that disambiguation
        # requires the SDK version (out of band), so the caller (the existing
        # in-arm SDK preflight in Invoke-DotNetToolAction) does it.
        if ($text -match '(?i)(?:does not support targeting|requires(?:.*?)SDK|framework[^\r\n]*not[^\r\n]*installed)[^\r\n]*?net(\d+)\.\d') {
            $required = $matches[1]
            $result.Category = 'TfmMismatch'
            $result.OneLineSummary = "TFM mismatch installing ${pkgLabel}: package targets net${required}.0 but the selected .NET SDK is older."
            $result.RemediationHint = "Install .NET SDK $required, ensure no global.json pins an older SDK, open a new terminal, and re-run. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.1.1)."
            $result.MatchedTokens = @{ RequiredMajor = $required }
            return $result
        }

        # 3. DotnetToolSettingsMissing -- corrupt extracted package state.
        # Same surface text the C0 (ADO #511672 / #512080) deep-clean arm
        # detected via inline -match; classifier now drives that dispatch.
        if ($text -match '(?i)DotnetToolSettings\.xml') {
            $result.Category = 'DotnetToolSettingsMissing'
            $result.OneLineSummary = "Corrupt .NET global tool cache for ${pkgLabel}: 'DotnetToolSettings.xml' is missing from the extracted package (the deep-clean repair will run automatically)."
            $result.RemediationHint = "If the automatic repair fails, delete '~/.dotnet/tools/.store/$PackageId' and '~/.nuget/packages/$PackageId' (and lowercase variants) manually, then re-run 'dotnet tool install -g $PackageId'. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.1.2)."
            $result.MatchedTokens = @{}
            return $result
        }

        # 4. ServiceIndexUnreachable -- the primary bug 525806 surface.
        # The error is buried in credential-provider chatter on real
        # machines; capturing the URL lets the user-facing summary name
        # the exact feed that's broken so they fix nuget.config instead
        # of chasing the auth red herring.
        if ($text -match '(?i)Unable\s+to\s+load\s+the\s+service\s+index\s+for\s+source\s+(\S+)') {
            $url = $matches[1].TrimEnd('.,;:')
            $result.Category = 'ServiceIndexUnreachable'
            $result.OneLineSummary = "NuGet service index unreachable for source $url while installing ${pkgLabel}."
            $result.RemediationHint = "This is a NuGet configuration issue, NOT a credential-provider/authentication issue (ignore any '[CredentialProvider]' chatter in the full log). Run 'dotnet nuget list source' and remove or fix the stale feed in nuget.config, then re-run 'dotnet tool install -g $PackageId'. See skills/vibeshield-bicep/references/mcp-troubleshooting.md."
            $result.MatchedTokens = @{ Url = $url }
            return $result
        }

        # 5. Unknown -- fallback. Extract the last N non-empty, non-
        # credential-provider lines so the user still sees the REAL dotnet
        # error even when we don't recognize the pattern. Tail-by-design
        # because dotnet error context typically lands near the end.
        # R2 S7: tail length 3 (was 5) and lines joined with a newline
        # (was ' | ') so the surface stays readable instead of producing
        # a 500-800 char one-liner.
        $tail = @($filteredLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3)
        $tailJoined = ($tail -join [Environment]::NewLine)
        if ([string]::IsNullOrWhiteSpace($tailJoined)) { $tailJoined = '(no diagnostic output captured)' }
        $result.OneLineSummary = "Unrecognized failure installing ${pkgLabel}:$([Environment]::NewLine)$tailJoined"
        $result.RemediationHint = "Inspect the sidecar log for the full dotnet output (including any suppressed credential-provider chatter). See skills/vibeshield-bicep/references/mcp-troubleshooting.md."
        return $result
    }

    # ADO #525806 - Write the full raw dotnet output for one failed
    # install/update to a sidecar file under ./output/. Returns the file
    # path so the caller can reference it in the user-facing summary. The
    # filename embeds the sanitized package id + a millisecond-precision
    # timestamp + a 4-char random suffix; concurrent failures on the same
    # package in the same millisecond therefore collide only with
    # vanishingly small probability (1 in 65,536 per ms per package).
    # Failures here are non-fatal (the user-facing summary still emits;
    # we just lose the on-disk artifact). Returns $null when the write
    # is skipped (e.g. -WhatIf) or fails, so callers can branch on the
    # actual on-disk state instead of printing a "preserved at <path>"
    # message that references a file that does not exist.
    function Write-McpInstallFailureLog {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$PackageId,
            [Parameter(Mandatory)][AllowEmptyString()][string]$OriginalOutput,
            [Parameter(Mandatory)][string]$OutputDir
        )

        try {
            if (-not (Test-Path -LiteralPath $OutputDir)) {
                if ($PSCmdlet.ShouldProcess($OutputDir, 'Create output directory for MCP install failure log')) {
                    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
                } else {
                    return $null
                }
            }
            $safe = ($PackageId -replace '[^A-Za-z0-9._-]', '_')
            if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'unknown-package' }
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            # R2 S6: 4-char hex suffix from a GUID disambiguates the
            # otherwise pathological case of two failures for the same
            # package landing in the same millisecond.
            $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 4)
            $logPath = Join-Path -Path $OutputDir -ChildPath ("mcp-install-{0}-{1}-{2}.log" -f $safe, $stamp, $suffix)
            if ($PSCmdlet.ShouldProcess($logPath, 'Write MCP install failure log')) {
                Set-Content -LiteralPath $logPath -Value $OriginalOutput -Encoding UTF8
                return $logPath
            }
            # R2 N8: under -WhatIf the file is never written; returning
            # the candidate path would cause the caller to print
            # "preserved at '<path>'" referencing a file that does not
            # exist. Return $null so the caller falls back to its
            # "log unavailable" message instead.
            return $null
        } catch {
            Write-Verbose ("Failed to write sidecar log for '{0}' under '{1}': {2}" -f $PackageId, $OutputDir, $_.Exception.Message)
            return $null
        }
    }


    # R2 F3: platform-aware shim filename renderer. The deletion logic in
    # Remove-DotNetToolOrphanShim writes '<cmd>.exe', '<cmd>.cmd', '<cmd>.ps1'
    # only on Windows; on Linux/macOS it writes the extensionless command
    # name. User-facing remediation messages MUST mirror that surface so a
    # copy-pasted 'Remove-Item' (or 'rm') is actionable on the user's
    # platform. Single helper -- all message-rendering call sites route
    # through it so the production and message surfaces cannot drift.
    function Get-PlatformShimVariant {
        [CmdletBinding()]
        # Declared as [object[]] (not [string[]]) because PSScriptAnalyzer
        # infers the runtime type from the @(...) literal output as
        # System.Object[]. Callers iterate this with foreach/ForEach-Object
        # and treat each item as a string, which is safe because every
        # element is constructed as a string above.
        [OutputType([object[]])]
        param([Parameter(Mandatory)][string]$Command)
        if ($IsWindows) {
            return @("$Command.exe", "$Command.cmd", "$Command.ps1")
        }
        return @($Command)
    }

    # R2 F2 + F3: render a per-command shim path list for orphan-shim
    # remediation messages. Previously the unverifiable arm of
    # Remove-DotNetToolOrphanShim stashed multiple candidate commands in a
    # comma-joined string field, and downstream format strings rendered
    # them as a single invalid filename like
    # 'azmcp,Azure.Bicep.McpServer.exe'. Emitting one variant set per
    # command makes the manual-remediation hint actually copy-pasteable.
    # F3 update: route through Get-PlatformShimVariant so the rendered
    # filenames match what the production deletion code would actually
    # write on the current platform.
    function Format-OrphanShimRemediationList {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Commands)
        $cmds = @($Commands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($cmds.Count -eq 0) { return '' }
        $parts = foreach ($c in $cmds) {
            $variants = Get-PlatformShimVariant -Command $c
            $quoted = ($variants | ForEach-Object { "'$_'" }) -join ', '
            "$quoted (for command '$c')"
        }
        return ($parts -join '; ')
    }

    # Single helper for both install and update branches. On a failure whose
    # output mentions DotnetToolSettings.xml, attempt one repair: uninstall
    # the (likely partially-extracted) global tool, physically remove the
    # corrupt extracted package state under ~/.dotnet/tools/.store/<pkg>
    # AND clear the local NuGet HTTP cache for the package, then install
    # fresh. P0-6: 'dotnet tool uninstall' only removes the registration
    # -- it does NOT delete the corrupt extracted .store directory or the
    # local NuGet HTTP cache, so a plain uninstall+install loops on the
    # same corrupt state and fails again with 'DotnetToolSettings.xml not
    # found'. We must also wipe both caches.
    function Remove-DotNetToolCorruptState {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param([Parameter(Mandatory)][string]$PackageId)

        # F1-prod: read $env:HOME (mutable) instead of $HOME (ReadOnly,AllScope
        # in PowerShell 7, so tests cannot redirect it). On non-Windows the
        # shell exports HOME, so $env:HOME and $HOME resolve to the same path
        # in production; in tests the file-level BeforeEach redirects
        # $env:HOME to a TestDrive fake so shim-deletion paths cannot touch
        # the real developer profile.
        $userHome = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $env:USERPROFILE
        } else {
            $env:HOME
        }

        # 1. Remove the extracted-package state at ~/.dotnet/tools/.store/<pkg>
        $storeRoot = Join-Path $userHome '.dotnet' | Join-Path -ChildPath 'tools' | Join-Path -ChildPath '.store'
        $candidates = @($PackageId, $PackageId.ToLowerInvariant()) | Select-Object -Unique
        foreach ($candidate in $candidates) {
            $storePath = Join-Path $storeRoot $candidate
            if (Test-Path -LiteralPath $storePath) {
                Write-Host "  REPAIR: Removing corrupt tool store at $storePath" -ForegroundColor Yellow
                Remove-Item -LiteralPath $storePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # 2. Clear the local NuGet HTTP cache entries for the package.
        # Scope-narrow to the package directory rather than running
        # 'dotnet nuget locals http-cache --clear' (which would nuke the
        # cache for ALL packages and slow down unrelated installs).
        # NuGet stores packages under both the original-cased and
        # lowercase-folded paths depending on version; remove both.
        $nugetRoot = Join-Path $userHome '.nuget' | Join-Path -ChildPath 'packages'
        foreach ($candidate in $candidates) {
            $nugetPath = Join-Path $nugetRoot $candidate
            if (Test-Path -LiteralPath $nugetPath) {
                Write-Host "  REPAIR: Removing NuGet cache at $nugetPath" -ForegroundColor Yellow
                Remove-Item -LiteralPath $nugetPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ADO #525807 - Orphan shim repair. The 'DotnetToolSettings.xml' arm only
    # detects ONE class of corrupt-cache failure. A second, equally common
    # post-corruption state surfaces as:
    #   "Failed to create shell shim for tool '<pkg>': Command '<shim>'
    #    conflicts with an existing command from another tool."
    # The trigger is leftover shim files (e.g. ~/.dotnet/tools/azmcp.cmd or
    # ~/.dotnet/tools/Azure.Bicep.McpServer.exe) whose backing .store payload
    # has been wiped but the apphost-with-baked-in-version remains. 'dotnet
    # tool install' refuses to overwrite a shim it doesn't own (registered),
    # so we must delete the orphan shim before retrying.
    #
    # SAFETY: before deleting any shim, query 'dotnet tool list -g' and
    # confirm no OTHER registered package owns the same command. If a
    # different registered tool owns it, refuse to delete and escalate -- a
    # genuine multi-tool conflict is not ours to resolve.
    function Remove-DotNetToolOrphanShim {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$PackageId,
            [Parameter(Mandatory)][string]$Shim,
            [string]$ConflictingCommand
        )

        # Structured return so each caller can decide whether a safety
        # refusal is fatal (conflicts arm: terminal) or merely advisory
        # (DotnetToolSettings arm: defensive cleanup -- retry can still
        # succeed). The helper itself NEVER mutates $script:McpInstallFailures;
        # escalation is the caller's responsibility.
        $result = [pscustomobject]@{
            Cleaned                 = $false
            SafetyRefusal           = $false
            ConflictingOwnerPackage = $null
            ConflictingCommand      = $null
            # R2 F2: array form of ConflictingCommand so the unverifiable
            # branch (which has N>=1 candidate commands) can render a
            # separate per-command shim path triplet in the remediation
            # message. The scalar ConflictingCommand field is retained
            # for back-compat -- it carries the first/display command.
            ConflictingCommands     = @()
            DeletedShims            = @()
        }

        # Build the full set of command names whose shim files we might
        # delete. Both the upstream-reported conflicting command AND the
        # package's declared shim are candidates; in some cases they
        # differ (e.g. azure.mcp declares 'azmcp'). EVERY candidate must
        # be safety-checked -- it would be wrong to safety-check only
        # the conflicting command and then delete files for the other.
        $cmdsToCheck = @(
            $(if (-not [string]::IsNullOrWhiteSpace($ConflictingCommand)) { $ConflictingCommand } else { $null }),
            $Shim
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

        # Safety: scan 'dotnet tool list -g' for another registered
        # package that claims any of the candidate commands. If one
        # exists, this is a real cross-tool conflict, not an orphan,
        # and the user must resolve it. FAIL CLOSED on any signal we
        # cannot trust (exception, non-zero exit) -- it is safe to
        # abort, unsafe to proceed under unverified ownership.
        $listOutput = $null
        $listExit = -1
        $listAvailable = $false
        try {
            $listOutput = & dotnet tool list -g 2>&1
            $listExit = $LASTEXITCODE
            $listAvailable = $true
        } catch {
            Write-Verbose ("'dotnet tool list -g' threw during orphan-shim safety check for '{0}': {1}. Failing closed -- ownership cannot be confirmed." -f $PackageId, $_.Exception.Message)
            $listAvailable = $false
        }

        if (-not $listAvailable -or $listExit -ne 0) {
            $result.SafetyRefusal = $true
            $result.ConflictingOwnerPackage = '<unverifiable>'
            # R2 F2: emit one shim path triplet per candidate command so the
            # rendered remediation message doesn't smush multiple commands
            # into a single invalid filename like 'azmcp,Azure.Bicep.McpServer.exe'.
            # The scalar field is still populated (first candidate, for display
            # and back-compat); the array drives per-command path expansion
            # in callers.
            $cmdsArray = @($cmdsToCheck)
            $result.ConflictingCommands = $cmdsArray
            $result.ConflictingCommand = $cmdsArray[0]
            return $result
        }

        $listLines = @($listOutput | Where-Object { $_ -is [string] })
        foreach ($line in $listLines) {
            $tokens = @(-split $line)
            if ($tokens.Count -lt 3) { continue }
            # Localization-safe header skip: a real data row has a
            # SemVer-shaped token in column 2. The English header
            # ('Package Id  Version  Commands') has 'Id' there;
            # localized headers (CJK/de/fr) have other non-version
            # tokens. The separator row is filtered above by Count.
            if ($tokens[1] -notmatch '^\d+\.\d+') { continue }
            $owningPkg = $tokens[0]
            # The Commands column can be COMMA-separated when a tool
            # registers multiple commands (e.g. 'azmcp, othercmd').
            # Reconstruct the column by joining tokens [2..end] with a
            # space, then splitting on commas. The previous tokens[-1]
            # shortcut missed conflicts where the target command was
            # not the final token.
            $cmdsField = ($tokens[2..($tokens.Count - 1)] -join ' ')
            $owningCmds = @($cmdsField -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            foreach ($owningCmd in $owningCmds) {
                foreach ($cmd in $cmdsToCheck) {
                    if ($owningCmd -ieq $cmd -and $owningPkg -ine $PackageId) {
                        $result.SafetyRefusal = $true
                        $result.ConflictingOwnerPackage = $owningPkg
                        $result.ConflictingCommand = $cmd
                        $result.ConflictingCommands = @($cmd)
                        return $result
                    }
                }
            }
        }

        $userHome = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $env:USERPROFILE
        } else {
            # F1-prod: see comment above $env:HOME usage.
            $env:HOME
        }
        $toolsDir = Join-Path $userHome '.dotnet' | Join-Path -ChildPath 'tools'

        # Whitelist canonical shim filenames only -- we NEVER glob or
        # delete arbitrary entries from ~/.dotnet/tools/.
        $variants = New-Object System.Collections.Generic.List[string]
        foreach ($name in $cmdsToCheck) {
            if ($IsWindows) {
                $variants.Add("$name.exe") | Out-Null
                $variants.Add("$name.cmd") | Out-Null
                $variants.Add("$name.ps1") | Out-Null
            } else {
                $variants.Add($name) | Out-Null
            }
        }

        $deleted = New-Object System.Collections.Generic.List[string]
        foreach ($v in $variants) {
            $shimPath = Join-Path $toolsDir $v
            if (Test-Path -LiteralPath $shimPath) {
                if ($PSCmdlet.ShouldProcess($shimPath, 'Remove orphan dotnet tool shim')) {
                    Write-Host "  REPAIR: Removing orphan shim $shimPath" -ForegroundColor Yellow
                    Remove-Item -LiteralPath $shimPath -Force -ErrorAction SilentlyContinue
                    $deleted.Add($shimPath) | Out-Null
                }
            }
        }

        $result.Cleaned = $true
        $result.DeletedShims = $deleted.ToArray()
        return $result
    }

    function Invoke-DotNetToolAction {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][ValidateSet('install', 'update')][string]$Action,
            [Parameter(Mandatory)][string]$PackageId,
            [Parameter(Mandatory)][string]$Shim
        )

        $output = & dotnet tool $Action -g $PackageId 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            $verb = if ($Action -eq 'install') { 'INSTALLED' } else { 'UPDATED' }
            Write-Host "  ${verb}: $PackageId (.NET global tool)" -ForegroundColor Green
            return $true
        }

        $outputText = Format-DotNetOutput -Output $output

        # ADO #525806 - Classify the failure ONCE up front and dispatch on
        # the structured category. Replaces the inline '-match' chain that
        # previously lived here for DotnetToolSettings.xml (ADO #511672 /
        # #512080) and 'conflicts with an existing command' (ADO #525807).
        # The classifier is pure -- it does not write to disk, does not
        # mutate $script:McpInstallFailures, and does not emit Write-Host.
        # Each arm below decides how to react. R2 F1: TfmMismatch has its
        # OWN dispatch arm now (the prior implementation collapsed it into
        # DotnetToolSettingsMissing, which then re-derived the required
        # major from the local '$requiredSdkMajor' config and discarded
        # the classifier's captured 'RequiredMajor' from the actual dotnet
        # output). When the surface text is the ambiguous
        # 'DotnetToolSettings.xml' (cache corruption OR an SDK-too-old
        # repackaged as cache corruption), the in-arm SDK preflight inside
        # the DotnetToolSettingsMissing arm is still the authoritative
        # disambiguator -- the classifier cannot tell those apart from
        # surface text alone.
        $failure = Get-DotNetToolFailureSummary -OutputText $outputText -PackageId $PackageId
        $dispatchCategory = $failure.Category

        if ($dispatchCategory -eq 'TfmMismatch') {
            # R2 F1: emit the classifier's TFM summary directly (which
            # includes the *captured* RequiredMajor from the actual
            # dotnet output -- e.g. "install .NET SDK 12" if the package
            # genuinely targets net12.0, even though our config-derived
            # $requiredSdkMajor only knows about net10.0). Do NOT route
            # into the cache-wipe / reinstall path -- a reinstall pulls
            # back the same net<N>.0 assets and fails identically.
            Write-Host ("  WARNING: {0} (exit code {1}). {2}" -f $failure.OneLineSummary, $exitCode, $failure.RemediationHint) -ForegroundColor Yellow
            $script:McpInstallFailures.Add(("{0} (exit code {1}). {2}" -f $failure.OneLineSummary, $exitCode, $failure.RemediationHint))
            return $false
        }

        if ($dispatchCategory -eq 'DotnetToolSettingsMissing') {
            # ADO #512080 - Distinguish TFM mismatch from genuine cache
            # corruption. The deep-clean repair below CANNOT recover from
            # a TFM mismatch (selected SDK older than the major required
            # by the package's tools/<TFM>/... layout) - reinstall pulls
            # back the same net<N>.0 assets and fails identically. Only
            # enter the repair branch when the SDK actually meets the
            # required major.
            $sdkOk = $true
            try {
                $sdkText = (& dotnet --version 2>&1 | Out-String).Trim()
                if (-not [string]::IsNullOrWhiteSpace($sdkText)) {
                    # Strip pre-release suffix so e.g. '10.0.100-preview.5'
                    # parses correctly and is not mis-classified as
                    # SDK-compatible by a silent [version] cast failure.
                    $sdkClean = ($sdkText -split '-')[0]
                    try {
                        $sdk = [version]$sdkClean
                        if ($sdk.Major -lt $requiredSdkMajor) { $sdkOk = $false }
                    } catch {
                        Write-Verbose ("Could not parse 'dotnet --version' output '{0}' (cleaned: '{1}') as [version] for TFM-mismatch reclassification of '{2}': {3}. Treating SDK as compatible and entering deep-clean repair." -f $sdkText, $sdkClean, $PackageId, $_.Exception.Message)
                    }
                }
            } catch {
                Write-Verbose ("'dotnet --version' invocation failed during TFM-mismatch reclassification of '{0}': {1}. Treating SDK as compatible and entering deep-clean repair." -f $PackageId, $_.Exception.Message)
            }

            if (-not $sdkOk) {
                Write-Host ("  WARNING: '$PackageId' install failed with 'DotnetToolSettings.xml not found' AND selected .NET SDK is below required major ($requiredSdkMajor). The MCP NuGet packages target net${requiredSdkMajor}.0, so this is a TFM mismatch -- not a corrupt cache. Cache wipe will not help. Install .NET SDK $requiredSdkMajor, ensure no global.json pins an older SDK, open a new terminal, and re-run. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.1.1).") -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("TFM mismatch installing '{0}': selected .NET SDK is below required major {1} (packages target net{1}.0). Install .NET SDK {1}, ensure no global.json pins an older SDK, and re-run." -f $PackageId, $requiredSdkMajor))
                return $false
            }

            Write-Host "  REPAIR: Detected corrupt global tool state for $PackageId - attempting deep clean + reinstall." -ForegroundColor Yellow

            # Best-effort cleanup of registration. Ignore exit code: if the
            # tool is already absent, uninstall returns non-zero but the
            # subsequent cache wipe + install will succeed regardless.
            $null = & dotnet tool uninstall -g $PackageId 2>&1

            # P0-6: physically remove the corrupt extracted .store/<pkg>
            # directory and clear the local NuGet HTTP cache for the
            # package -- without this, the reinstall pulls back the
            # same corrupt state and fails again.
            try {
                Remove-DotNetToolCorruptState -PackageId $PackageId
            } catch {
                Write-Host "  WARNING: Best-effort cache cleanup for $PackageId raised an error - $($_.Exception.Message). Continuing with reinstall." -ForegroundColor Yellow
            }

            # ADO #525807 - Defense-in-depth: ALSO clear orphan shim files.
            # The 'dotnet tool uninstall' above runs with its exit code
            # discarded, so a silent uninstall failure combined with the
            # cache wipe above MANUFACTURES the orphan-shim state that
            # bug 525807 is about. Without this cleanup, the next install
            # would surface as 'Command <X> conflicts with an existing
            # command from another tool' on the user's next run.
            # Failure here (exception OR safety refusal due to another
            # registered tool legitimately owning the shim) is logged but
            # does NOT block the retry -- the DotnetToolSettings.xml
            # repair does not require shim cleanup to succeed. Distinct
            # messages for exception vs safety-refusal so the trace is
            # diagnosable.
            $userHomeForCleanupMsg = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $env:HOME }
            $toolsHintForCleanup = Join-Path $userHomeForCleanupMsg '.dotnet' | Join-Path -ChildPath 'tools'
            try {
                $shimCleanupResult = Remove-DotNetToolOrphanShim -PackageId $PackageId -Shim $Shim
                if ($shimCleanupResult.SafetyRefusal) {
                    $owner = $shimCleanupResult.ConflictingOwnerPackage
                    $cmd = $shimCleanupResult.ConflictingCommand
                    if ($owner -eq '<unverifiable>') {
                        # R2 F2: render one path triplet per candidate command
                        # so a multi-command refusal (Shim != ConflictingCommand)
                        # produces an actionable list rather than a smushed
                        # invalid filename.
                        $cmdsForMsg = @($shimCleanupResult.ConflictingCommands)
                        if ($cmdsForMsg.Count -eq 0) { $cmdsForMsg = @($cmd) }
                        $cmdsDisplay = ($cmdsForMsg | ForEach-Object { "'$_'" }) -join ', '
                        $shimList = Format-OrphanShimRemediationList -Commands $cmdsForMsg
                        Write-Host ("  WARNING: Defensive orphan-shim cleanup for '{0}' SKIPPED -- 'dotnet tool list -g' could not be queried, so ownership of command(s) {1} (shim files under '{2}') cannot be confirmed. Proceeding with reinstall; this is non-fatal because the DotnetToolSettings.xml repair does not require shim cleanup to succeed. If the retry below fails with a 'Command conflicts' error, run 'dotnet tool list -g' yourself and -- only if no other tool owns the command -- manually delete the following from '{2}': {3}. Then re-run. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $PackageId, $cmdsDisplay, $toolsHintForCleanup, $shimList) -ForegroundColor Yellow
                    } else {
                        Write-Host ("  WARNING: Defensive orphan-shim cleanup for '{0}' SKIPPED -- command '{1}' is owned by registered tool '{2}' (shim files under '{3}'). Proceeding with reinstall; this is non-fatal because the DotnetToolSettings.xml repair does not require shim cleanup to succeed. If the retry below fails with a 'Command conflicts' error, the genuine fix is 'dotnet tool uninstall -g {2}' (or rename one of the tools). See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $PackageId, $cmd, $owner, $toolsHintForCleanup) -ForegroundColor Yellow
                    }
                }
            } catch {
                # R2 F3: render shim variants through Get-PlatformShimVariant
                # so the example filenames match what would actually need to
                # be deleted on the current platform.
                $shimVariantsList = (Get-PlatformShimVariant -Command $Shim | ForEach-Object { "'$_'" }) -join ', '
                Write-Host ("  WARNING: Defensive orphan-shim cleanup for '{0}' RAISED an exception: {1}. Shim files were NOT inspected. Continuing with reinstall (non-fatal at this stage). If the retry below fails with a 'Command conflicts' error, manually delete {2} from '{3}', then re-run. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $PackageId, $_.Exception.Message, $shimVariantsList, $toolsHintForCleanup) -ForegroundColor Yellow
            }

            $retryOutput = & dotnet tool install -g $PackageId 2>&1
            $retryExitCode = $LASTEXITCODE

            if ($retryExitCode -eq 0) {
                Write-Host "  REPAIRED: $PackageId" -ForegroundColor Green
                return $true
            }

            $retryText = Format-DotNetOutput -Output $retryOutput
            # R2 F4: classify the RETRY failure and emit through the same
            # sidecar + one-line-summary path the generic arm uses. Before
            # this change, the unfiltered $retryText (which can contain
            # 100+ lines of '[NuGet Manager] [Info] [CredentialProvider]'
            # chatter when the retry hits a service-index error) was
            # splattered into both the WARNING and the FAILED summary --
            # exactly the bug-525806 surface this PR is supposed to fix.
            # The C1 manual-remediation hint stays appended because it's
            # genuinely useful for the deep-clean-failed case.
            $retryFailure = Get-DotNetToolFailureSummary -OutputText $retryText -PackageId $PackageId
            Write-Verbose ("Full dotnet retry output for '{0}' after DotnetToolSettings.xml repair:`n{1}" -f $PackageId, $retryText)
            $retryLogPath = Write-McpInstallFailureLog -PackageId $PackageId -OriginalOutput $retryText -OutputDir $script:McpFailureLogDir
            $retryLogHint = if ($retryLogPath) {
                "Full dotnet output (including any suppressed credential-provider chatter) preserved at '$retryLogPath'."
            } else {
                "Full dotnet output is not available on disk; re-run with -Verbose to capture it on stdout, or verify that '$($script:McpFailureLogDir)' is writable and retry."
            }
            $userHomeForMsg = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $env:HOME }
            $storeHint = Join-Path $userHomeForMsg '.dotnet' | Join-Path -ChildPath 'tools' | Join-Path -ChildPath '.store' | Join-Path -ChildPath $PackageId
            $nugetHint = Join-Path $userHomeForMsg '.nuget' | Join-Path -ChildPath 'packages' | Join-Path -ChildPath $PackageId
            $manualHint = "Manual remediation: delete '$storeHint' and '$nugetHint' (and lowercase variants), then re-run 'dotnet tool install -g $PackageId'."
            # R2 S1: when the classifier re-identifies the retry failure as
            # the same category we just attempted to repair, its
            # RemediationHint already advises the deep-clean. Appending
            # $manualHint then produces two near-identical "delete .store /
            # .nuget" sentences. Suppress the manual hint in that case;
            # keep it when the retry surfaces a DIFFERENT category (e.g.,
            # service-index unreachable) where both signals are valuable.
            $appendManualHint = $retryFailure.Category -ne 'DotnetToolSettingsMissing'
            if ($appendManualHint) {
                Write-Host ("  WARNING: Repair of $PackageId failed (retry exit code $retryExitCode). {0} {1} {2} {3} See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.1.2)." -f $retryFailure.OneLineSummary, $retryFailure.RemediationHint, $manualHint, $retryLogHint) -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("Repair of '{0}' failed after deep clean (exit code {1}). {2} {3} {4} Log: {5}" -f $PackageId, $retryExitCode, $retryFailure.OneLineSummary, $retryFailure.RemediationHint, $manualHint, ($retryLogPath ?? '(unavailable)')))
            } else {
                Write-Host ("  WARNING: Repair of $PackageId failed (retry exit code $retryExitCode). {0} {1} {2} See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.1.2)." -f $retryFailure.OneLineSummary, $retryFailure.RemediationHint, $retryLogHint) -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("Repair of '{0}' failed after deep clean (exit code {1}). {2} {3} Log: {4}" -f $PackageId, $retryExitCode, $retryFailure.OneLineSummary, $retryFailure.RemediationHint, ($retryLogPath ?? '(unavailable)')))
            }
            return $false
        }

        # ADO #525807 - Orphan shim conflict repair. Dispatched from the
        # classifier's 'Conflicts' category (ADO #525806 consolidation);
        # the upstream phrase is 'conflicts with an existing command from
        # another tool' and the conflicting command name (when present) is
        # captured into $failure.MatchedTokens so the safety check matches
        # on the real surface symbol rather than only the package's
        # declared shim.
        if ($dispatchCategory -eq 'Conflicts') {
            $conflictingCommand = $null
            if ($failure.MatchedTokens.ContainsKey('ConflictingCommand')) {
                $conflictingCommand = $failure.MatchedTokens['ConflictingCommand']
            }
            $displayCmd = if ($conflictingCommand) { $conflictingCommand } else { $Shim }
            Write-Host "  REPAIR: Detected orphan shim conflict for $PackageId (command '$displayCmd') - attempting shim cleanup + cache deep clean + reinstall." -ForegroundColor Yellow

            $userHomeForConflict = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $env:HOME }
            $toolsHintConflict = Join-Path $userHomeForConflict '.dotnet' | Join-Path -ChildPath 'tools'

            $shimResult = $null
            try {
                $shimResult = Remove-DotNetToolOrphanShim -PackageId $PackageId -Shim $Shim -ConflictingCommand $conflictingCommand
            } catch {
                # F-silent-success: previously the helper exception was
                # warned-only and the script could exit success despite
                # the install having failed and the repair having been
                # abandoned. Record an actionable failure so the FAILED:
                # summary surfaces the real state.
                # R2 F3: platform-aware shim variant rendering. On Windows
                # this is '<cmd>.exe', '<cmd>.cmd', '<cmd>.ps1'; on
                # Linux/macOS it is the extensionless '<cmd>'.
                $displayShimList = (Get-PlatformShimVariant -Command $displayCmd | ForEach-Object { "'$_'" }) -join ', '
                $msg = "Orphan-shim repair of '{0}' threw during cleanup: {1}. Original install error: {2}. Shim path(s) under '{3}': {4}. Manual remediation: run 'dotnet tool list -g'; if no other tool owns '{5}', delete those shim files and re-run 'dotnet tool install -g {0}'. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $PackageId, $_.Exception.Message, $outputText, $toolsHintConflict, $displayShimList, $displayCmd
                Write-Host ("  WARNING: $msg") -ForegroundColor Yellow
                $script:McpInstallFailures.Add($msg)
                return $false
            }

            if ($shimResult.SafetyRefusal) {
                # Terminal in the conflicts arm: retry would just
                # reproduce the same conflict. Distinct messages for
                # the two refusal causes.
                $owner = $shimResult.ConflictingOwnerPackage
                $cmd = $shimResult.ConflictingCommand
                if ($owner -eq '<unverifiable>') {
                    # R2 F2: per-command shim path triplet list.
                    $cmdsForMsg = @($shimResult.ConflictingCommands)
                    if ($cmdsForMsg.Count -eq 0) { $cmdsForMsg = @($cmd) }
                    $cmdsDisplay = ($cmdsForMsg | ForEach-Object { "'$_'" }) -join ', '
                    $shimList = Format-OrphanShimRemediationList -Commands $cmdsForMsg
                    $msg = "Orphan-shim repair of '{0}' ABORTED -- 'dotnet tool list -g' could not be queried, so ownership of command(s) {1} cannot be confirmed and we will not delete shim files we may not own. Shim files under '{2}': {3}. Manual remediation: run 'dotnet tool list -g' yourself; for any of those commands that no other tool owns, delete its shim files from '{2}' and re-run 'dotnet tool install -g {0}'. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $PackageId, $cmdsDisplay, $toolsHintConflict, $shimList
                } else {
                    # R2 F3: platform-aware shim variant rendering.
                    $cmdShimList = (Get-PlatformShimVariant -Command $cmd | ForEach-Object { "'$_'" }) -join ', '
                    $msg = "Orphan-shim repair of '{0}' ABORTED -- command '{1}' is owned by registered tool '{2}' (a real cross-tool conflict, not an orphan). Shim path(s) under '{3}': {4}. Manual remediation: 'dotnet tool uninstall -g {2}' (or rename one of the tools), then re-run 'dotnet tool install -g {0}'. See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $PackageId, $cmd, $owner, $toolsHintConflict, $cmdShimList
                }
                Write-Host ("  WARNING: $msg") -ForegroundColor Yellow
                $script:McpInstallFailures.Add($msg)
                return $false
            }

            try {
                Remove-DotNetToolCorruptState -PackageId $PackageId
            } catch {
                Write-Host "  WARNING: Best-effort cache cleanup for $PackageId raised an error - $($_.Exception.Message). Continuing with reinstall." -ForegroundColor Yellow
            }

            $retryOutput = & dotnet tool install -g $PackageId 2>&1
            $retryExitCode = $LASTEXITCODE

            if ($retryExitCode -eq 0) {
                Write-Host "  REPAIRED: $PackageId" -ForegroundColor Green
                return $true
            }

            $retryText = Format-DotNetOutput -Output $retryOutput
            # R2 F4: same classifier + sidecar treatment as the
            # DotnetToolSettings arm. Bug-525806 repro on a real machine
            # is an orphan-shim AND an unreachable feed simultaneously;
            # without this, the retry-fail surfaces credential-provider
            # chatter all over again. The C1 manual-remediation hint
            # stays appended -- both signals are valuable.
            $retryFailure = Get-DotNetToolFailureSummary -OutputText $retryText -PackageId $PackageId
            Write-Verbose ("Full dotnet retry output for '{0}' after orphan-shim repair:`n{1}" -f $PackageId, $retryText)
            $retryLogPath = Write-McpInstallFailureLog -PackageId $PackageId -OriginalOutput $retryText -OutputDir $script:McpFailureLogDir
            $retryLogHint = if ($retryLogPath) {
                "Full dotnet output (including any suppressed credential-provider chatter) preserved at '$retryLogPath'."
            } else {
                "Full dotnet output is not available on disk; re-run with -Verbose to capture it on stdout, or verify that '$($script:McpFailureLogDir)' is writable and retry."
            }
            $userHomeForMsg = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $env:HOME }
            $toolsHint = Join-Path $userHomeForMsg '.dotnet' | Join-Path -ChildPath 'tools'
            $storeHint = Join-Path $toolsHint '.store' | Join-Path -ChildPath $PackageId
            $nugetHint = Join-Path $userHomeForMsg '.nuget' | Join-Path -ChildPath 'packages' | Join-Path -ChildPath $PackageId
            # R2 F3: platform-aware example filenames for manual remediation.
            $displayExamples = (Get-PlatformShimVariant -Command $displayCmd | ForEach-Object { "'$_'" }) -join ', '
            $manualHint = "Manual remediation: delete shim files matching '$displayCmd' under '$toolsHint' (e.g. $displayExamples), plus '$storeHint' and '$nugetHint' (and lowercase variants), then re-run 'dotnet tool install -g $PackageId'."
            # R2 S1: same-category suppression -- if the retry still
            # surfaces 'Conflicts', the classifier's RemediationHint
            # already covers it; $manualHint would be a duplicate sentence.
            $appendManualHint = $retryFailure.Category -ne 'Conflicts'
            if ($appendManualHint) {
                Write-Host ("  WARNING: Repair of $PackageId failed (retry exit code $retryExitCode). {0} {1} {2} {3} See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $retryFailure.OneLineSummary, $retryFailure.RemediationHint, $manualHint, $retryLogHint) -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("Repair of '{0}' failed after orphan-shim cleanup (exit code {1}). {2} {3} {4} Log: {5}" -f $PackageId, $retryExitCode, $retryFailure.OneLineSummary, $retryFailure.RemediationHint, $manualHint, ($retryLogPath ?? '(unavailable)')))
            } else {
                Write-Host ("  WARNING: Repair of $PackageId failed (retry exit code $retryExitCode). {0} {1} {2} See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 3.4)." -f $retryFailure.OneLineSummary, $retryFailure.RemediationHint, $retryLogHint) -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("Repair of '{0}' failed after orphan-shim cleanup (exit code {1}). {2} {3} Log: {4}" -f $PackageId, $retryExitCode, $retryFailure.OneLineSummary, $retryFailure.RemediationHint, ($retryLogPath ?? '(unavailable)')))
            }
            return $false
        }

        # ADO #525806 - Generic / unrecognized failure path. Previously this
        # forwarded the raw $outputText verbatim into both the Write-Host
        # warning AND the FAILED summary entry, which on real machines was
        # dominated by '[NuGet Manager] [Info] [CredentialProvider] ...'
        # chatter from the Azure Artifacts Credential Provider plugin.
        # Users followed the credential-provider noise into authentication
        # rabbit holes while the actually-actionable line
        # ('Unable to load the service index for source <url>') was buried
        # in the middle. Now: classifier produces a one-line, copy-pasteable
        # summary plus a category-specific remediation hint; the raw output
        # (including credential-provider chatter, for diagnostics) is
        # preserved in a sidecar log under ./output/; the user-facing
        # warning references the sidecar path so the full text remains
        # reachable without being splattered into the terminal.
        # R2 F2: also Write-Verbose the raw output unconditionally so the
        # "re-run with -Verbose" fallback message is actually truthful
        # when sidecar write fails. And the fallback message itself now
        # describes BOTH the -Verbose path AND the underlying cause
        # (output-dir not writable) so the user has an actionable next
        # step instead of a misleading "re-run with -Verbose" that may
        # not be true if the failure was, e.g., a parameter binding bug.
        Write-Verbose ("Full dotnet output for '{0}':`n{1}" -f $PackageId, $outputText)
        $logPath = Write-McpInstallFailureLog -PackageId $PackageId -OriginalOutput $outputText -OutputDir $script:McpFailureLogDir
        $logHint = if ($logPath) {
            "Full dotnet output (including any suppressed credential-provider chatter) preserved at '$logPath'."
        } else {
            "Full dotnet output is not available on disk; re-run with -Verbose to capture it on stdout, or verify that '$($script:McpFailureLogDir)' is writable and retry."
        }

        Write-Host ("  WARNING: {0} (exit code {1}). {2} {3}" -f $failure.OneLineSummary, $exitCode, $failure.RemediationHint, $logHint) -ForegroundColor Yellow
        $script:McpInstallFailures.Add(("{0} (exit code {1}). {2} Log: {3}" -f $failure.OneLineSummary, $exitCode, $failure.RemediationHint, ($logPath ?? '(unavailable)')))
        return $false
    }

    $dotnetCli = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCli) {
        Write-Host '  WARNING: dotnet CLI not found - skipping MCP server tool installation. Install the .NET SDK and run: dotnet tool install -g Azure.Bicep.McpServer && dotnet tool install -g azure.mcp' -ForegroundColor Yellow
    } else {
        # ---------------------------------------------------------------
        # ADO #512080 - Preflight: verify selected .NET SDK meets the
        # required major version BEFORE attempting any install/update.
        #
        # The Azure MCP and Bicep MCP NuGet packages ship only
        # tools/net<RequiredSdkMajor>.0/... assets. SDKs older than that
        # major cannot extract the tool and produce a misleading
        # "DotnetToolSettings.xml not found" surface error. The deep-clean
        # repair branch (P0-6) cannot recover from this -- it is a TFM
        # mismatch, not corrupt cache. Detect early, emit an actionable
        # message that tells the user to install the right SDK (and to
        # check global.json), and short-circuit to the FAILED summary.
        # ---------------------------------------------------------------
        $skipDotNetToolSteps = $false

        $configPath = Join-Path -Path $projectRoot -ChildPath '.vibeshield' |
            Join-Path -ChildPath 'PackageSupport' |
            Join-Path -ChildPath 'Config' |
            Join-Path -ChildPath 'McpPackages.psd1'
        # Fallback: when the script is invoked from a project that does NOT
        # itself contain .vibeshield (typical orchestrator flow during
        # bootstrap), search upward from $PSScriptRoot for the first ancestor
        # that contains .vibeshield/PackageSupport/Config/McpPackages.psd1.
        # Walking a fixed number of levels is brittle: in the source repo
        # (skills/<skill>/scripts) the config is 3 levels up, but in a
        # deployed install (.github/skills/<skill>/scripts inside a user
        # project) the config lives 4 levels up at the project root past
        # .github/. Bounded at 6 levels to avoid runaway traversal.
        if (-not (Test-Path -LiteralPath $configPath)) {
            $repoConfigPath = $null
            $cursor = $PSScriptRoot
            for ($i = 0; $i -lt 6; $i++) {
                if ([string]::IsNullOrEmpty($cursor)) { break }
                $candidate = Join-Path -Path $cursor -ChildPath '.vibeshield' |
                    Join-Path -ChildPath 'PackageSupport' |
                    Join-Path -ChildPath 'Config' |
                    Join-Path -ChildPath 'McpPackages.psd1'
                if (Test-Path -LiteralPath $candidate) {
                    $repoConfigPath = $candidate
                    break
                }
                $parent = Split-Path -Path $cursor -Parent
                if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
                $cursor = $parent
            }
            if ($null -ne $repoConfigPath) {
                $configPath = [System.IO.Path]::GetFullPath($repoConfigPath)
            } else {
                Write-Verbose ("McpPackages.psd1 not found in any ancestor of '{0}' (searched 6 levels); using hardcoded RequiredSdkMajor fallback." -f $PSScriptRoot)
            }
        }

        $requiredSdkMajor = 10
        if (Test-Path -LiteralPath $configPath) {
            try {
                $reqs = Import-PowerShellDataFile -Path $configPath
                if ($reqs.ContainsKey('RequiredSdkMajor')) {
                    $requiredSdkMajor = [int]$reqs.RequiredSdkMajor
                }
            } catch {
                Write-Host "  WARNING: Failed to load MCP package requirements from '$configPath' - $($_.Exception.Message). Falling back to RequiredSdkMajor=$requiredSdkMajor." -ForegroundColor Yellow
            }
        }

        $selectedSdk = $null
        try {
            $selectedSdkText = (& dotnet --version 2>&1 | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($selectedSdkText)) {
                # Strip pre-release suffix (e.g. '10.0.100-preview.5' ->
                # '10.0.100') so [version] cast doesn't throw on preview SDKs
                # and silently bypass the required-major check.
                $selectedSdkClean = ($selectedSdkText -split '-')[0]
                try {
                    $selectedSdk = [version]$selectedSdkClean
                } catch {
                    Write-Verbose ("Could not parse 'dotnet --version' output '{0}' (cleaned: '{1}') as [version] in preflight: {2}. Treating selected SDK as unknown; downstream install will surface any failure." -f $selectedSdkText, $selectedSdkClean, $_.Exception.Message)
                    $selectedSdk = $null
                }
            }
        } catch {
            # If dotnet itself is broken, leave the existing downstream
            # handling to surface the failure. Don't pre-classify.
            Write-Verbose ("'dotnet --version' invocation failed during preflight: {0}" -f $_.Exception.Message)
            $selectedSdk = $null
        }

        if ($null -ne $selectedSdk -and $selectedSdk.Major -lt $requiredSdkMajor) {
            $installedSdks = ''
            try { $installedSdks = (& dotnet --list-sdks 2>&1 | Out-String).Trim() } catch {
                Write-Verbose ("'dotnet --list-sdks' failed during preflight: {0}" -f $_.Exception.Message)
            }
            $msg = ("Selected .NET SDK is {0} but Azure MCP and Bicep MCP global tools require .NET SDK {1}.x because their NuGet packages target net{1}.0. Install .NET SDK {1}, ensure no global.json pins an older SDK, open a new terminal, and re-run. Installed SDKs:`n{2}" -f $selectedSdk, $requiredSdkMajor, $installedSdks)
            Write-Host ('  WARNING: {0}' -f $msg) -ForegroundColor Yellow
            $script:McpInstallFailures.Add($msg)
            # DO NOT proceed to install/update - the deep-clean repair branch
            # cannot recover from a TFM mismatch. Skip ahead to the FAILED
            # summary so the script exits 1 with this actionable message.
            $skipDotNetToolSteps = $true
        }

        if (-not $skipDotNetToolSteps) {
        $installedTools = @()
        try {
            $installedTools = @(& dotnet tool list -g 2>&1)
        } catch {
            Write-Host "  WARNING: Failed to enumerate installed .NET global tools - $($_.Exception.Message). Proceeding with install attempts; final shim validation will determine success." -ForegroundColor Yellow
        }

        $toolSpecs = @(
            @{ PackageId = 'Azure.Bicep.McpServer'; SearchPattern = '(?i)azure\.bicep\.mcpserver'; Shim = 'Azure.Bicep.McpServer' },
            @{ PackageId = 'azure.mcp'; SearchPattern = '(?i)azure\.mcp\b'; Shim = 'azmcp' }
        )

        foreach ($tool in $toolSpecs) {
            $isInstalled = $false
            foreach ($line in $installedTools) {
                if ($line -is [string] -and $line -match $tool.SearchPattern) {
                    $isInstalled = $true
                    break
                }
            }

            $action = if ($isInstalled) { 'update' } else { 'install' }
            try {
                $null = Invoke-DotNetToolAction -Action $action -PackageId $tool.PackageId -Shim $tool.Shim
            } catch {
                Write-Host "  WARNING: Failed to $action $($tool.PackageId) - $($_.Exception.Message)" -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("Exception during {0} of '{1}': {2}" -f $action, $tool.PackageId, $_.Exception.Message))
            }
        }

        # ---------------------------------------------------------------
        # Step 3: Refresh PATH from the registry (Windows) and validate
        # that each MCP shim is resolvable. P0-5: even when 'dotnet tool
        # install -g' returns 0, the shim is unreachable to VS Code /
        # Copilot CLI if %USERPROFILE%\.dotnet\tools is not on PATH.
        # ---------------------------------------------------------------
        if ($IsWindows) {
            $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
            $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
            $registryPath = '{0};{1}' -f $machinePath, $userPath
            $currentDirs = @($env:Path -split ';' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.TrimEnd('\') })
            $registryDirs = @($registryPath -split ';' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.TrimEnd('\') })
            $extraDirs = @($registryDirs | Where-Object { $_ -notin $currentDirs })
            if ($extraDirs.Count -gt 0) {
                $env:Path = ($currentDirs + $extraDirs) -join ';'
            }

            # Defense-in-depth: also ensure %USERPROFILE%\.dotnet\tools
            # is on the current-process PATH. If Install-VibeShieldDotNet
            # ran in a previous session the user PATH update may not yet
            # be reflected in the registry refresh above (the entry was
            # added but a fresh shell elsewhere is required to pick it
            # up reliably).
            $userHomeForPath = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $HOME }
            $toolsDir = Join-Path $userHomeForPath '.dotnet' | Join-Path -ChildPath 'tools'
            $currentDirsAfter = @($env:Path -split ';' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.TrimEnd('\') })
            if (-not ($currentDirsAfter -contains $toolsDir.TrimEnd('\'))) {
                $env:Path = '{0};{1}' -f $toolsDir, $env:Path
            }
        } else {
            # Linux/macOS: do NOT prepend $HOME/.dotnet/tools to the in-process
            # PATH here. Doing so would mask the real defect on a fresh login
            # shell (where ~/.bashrc / ~/.zshrc / ~/.profile may not export it),
            # making Get-Command below succeed in this process while a fresh
            # Copilot CLI session still fails. Use $env:PATH as the user's
            # shell actually has it; the shim validation loop below is the
            # authoritative gate, and the warning emitted on miss tells the
            # user how to fix their rc file.
            $null = $env:PATH
        }

        foreach ($tool in $toolSpecs) {
            $shim = $tool.Shim
            $resolved = Get-Command $shim -ErrorAction SilentlyContinue
            if (-not $resolved) {
                $userHomeForMsg = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $env:HOME }
                $expectedDir = Join-Path $userHomeForMsg '.dotnet' | Join-Path -ChildPath 'tools'
                if ($IsWindows) {
                    $pathHint = "Verify the directory is on your PATH (restart your terminal if .NET SDK was just installed) or re-run 'dotnet tool install -g $($tool.PackageId)'."
                } else {
                    $pathHint = "Add 'export PATH=`"`$HOME/.dotnet/tools:`$PATH`"' to your login shell rc file (~/.bashrc, ~/.zshrc, or ~/.profile) and start a new shell, or re-run 'dotnet tool install -g $($tool.PackageId)'."
                }
                Write-Host "  WARNING: MCP shim '$shim' for $($tool.PackageId) is NOT resolvable on PATH. Expected at '$expectedDir'. $pathHint See skills/vibeshield-bicep/references/mcp-troubleshooting.md (Step 2A.1) - Copilot CLI requires this PATH entry; VS Code is unaffected." -ForegroundColor Yellow
                $script:McpInstallFailures.Add(("MCP shim '{0}' for package '{1}' is unresolved on PATH after install. Add '{2}' to PATH or reinstall." -f $shim, $tool.PackageId, $expectedDir))
            } else {
                Write-Host "  RESOLVED: $shim -> $($resolved.Source)" -ForegroundColor Green
            }
        }
        } # end if (-not $skipDotNetToolSteps)
    }
} catch {
    Write-Host "  WARNING: Install-McpConfig encountered an error: $($_.Exception.Message)" -ForegroundColor Yellow
    $script:McpInstallFailures.Add(("Unhandled exception in Install-McpConfig: {0}" -f $_.Exception.Message))
}

if ($script:McpInstallFailures.Count -gt 0) {
    Write-Host '' -ForegroundColor Yellow
    Write-Host ('  FAILED: Install-McpConfig encountered {0} unrecoverable failure(s):' -f $script:McpInstallFailures.Count) -ForegroundColor Red
    foreach ($failure in $script:McpInstallFailures) {
        Write-Host ('    - {0}' -f $failure) -ForegroundColor Red
    }
    Write-Host '    See skills/vibeshield-bicep/references/mcp-troubleshooting.md for step-by-step remediation.' -ForegroundColor Red
    exit 1
}

exit 0
