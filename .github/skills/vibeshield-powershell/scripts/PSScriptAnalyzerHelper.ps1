<#
.SYNOPSIS
    Shared function library for vibeshield-powershell validation scripts.

.DESCRIPTION
    Dot-sourced by Invoke-PSScriptAnalyzer.ps1, Test-PowerShellScripts.ps1,
    and Invoke-PSScriptAnalyzerHook.ps1 to consolidate duplicated logic for
    module bootstrapping, path exclusion, single-file analysis, and SARIF
    envelope construction.

    This file does NOT set Set-StrictMode or $ErrorActionPreference at file
    scope -- callers are responsible for those settings. Functions inherit
    the caller's error action preference.

    This file does NOT call exit -- functions throw on failure or return
    results to the caller.
#>

# -- Script-scope constants ---------------------------------------------------
$script:ExcludedRules = @('PSAvoidUsingWriteHost')
$script:ExcludedDirPattern = '(^|[\\/])(output|\.specify)([\\/]|$)'

# -- Functions ----------------------------------------------------------------

function Initialize-PSScriptAnalyzer {
    <#
    .SYNOPSIS
        Ensures PSScriptAnalyzer is available and imported.

    .DESCRIPTION
        Checks whether PSScriptAnalyzer is installed. If not, attempts to
        install it from PSGallery for the current user. Imports the module
        and returns the version string. Throws if the module cannot be
        loaded after the install attempt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Write-Host 'PSScriptAnalyzer not installed. Installing...' -ForegroundColor Yellow
        Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
    }

    Import-Module PSScriptAnalyzer -ErrorAction Stop

    $loadedModule = Get-Module PSScriptAnalyzer
    if (-not $loadedModule) {
        throw 'PSScriptAnalyzer module could not be loaded after install attempt.'
    }

    return $loadedModule.Version.ToString()
}

function Test-ExcludedPath {
    <#
    .SYNOPSIS
        Checks whether a relative path is under an excluded directory.

    .DESCRIPTION
        Returns $true if the supplied relative path matches the excluded
        directory pattern (output/ or .specify/). Used to skip files that
        should not be validated.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RelativePath
    )

    return [bool]($RelativePath -match $script:ExcludedDirPattern)
}

function Invoke-SingleFileAnalysis {
    <#
    .SYNOPSIS
        Runs PSScriptAnalyzer against a single file and returns SARIF results.

    .DESCRIPTION
        Invokes Invoke-ScriptAnalyzer on the specified file, excluding rules
        listed in $script:ExcludedRules. Returns an array of hashtables in
        SARIF result format. PSScriptAnalyzer must already be imported
        (call Initialize-PSScriptAnalyzer first).

        Throws if the file does not exist or cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot
    )

    if (-not (Test-Path $FilePath)) {
        throw "File not found: $FilePath"
    }

    # Verify the file is readable by attempting to open it
    try {
        $null = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    }
    catch {
        throw "Access denied or cannot read file: $FilePath -- $($_.Exception.Message)"
    }

    $diagnostics = @(Invoke-ScriptAnalyzer -Path $FilePath -ExcludeRule $script:ExcludedRules)

    # Compute relative path and SARIF URI
    $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $FilePath)
    $sarifUri = $relativePath -replace '\\', '/'

    # Map PSScriptAnalyzer severity to SARIF level
    $severityMap = @{
        'Error'       = 'error'
        'Warning'     = 'warning'
        'Information' = 'note'
    }

    $sarifResults = @(foreach ($d in $diagnostics) {
        $level = $severityMap[$d.Severity.ToString()]
        if (-not $level) { $level = 'warning' }

        @{
            ruleId    = $d.RuleName
            level     = $level
            message   = @{ text = $d.Message }
            locations = @(@{
                physicalLocation = @{
                    artifactLocation = @{ uri = $sarifUri }
                    region           = @{ startLine = $d.Line; startColumn = $d.Column }
                }
            })
        }
    })

    return $sarifResults
}

function New-SarifEnvelope {
    <#
    .SYNOPSIS
        Constructs a SARIF v2.1.0 envelope from results and tool version.

    .DESCRIPTION
        Builds a complete SARIF v2.1.0 document hashtable containing the
        schema reference, version, and a single run with the supplied
        results array and PSScriptAnalyzer version. The returned hashtable
        is ready for ConvertTo-Json.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory hashtable; does not modify system state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$Results,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ToolVersion
    )

    return @{
        '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json'
        version   = '2.1.0'
        runs      = @(@{
            tool    = @{ driver = @{ name = 'PSScriptAnalyzer'; version = $ToolVersion } }
            results = $Results
        })
    }
}
