Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-VibeShieldCapabilityResult {
    <#
    .SYNOPSIS
        Writes a VibeShield capability handshake result file per the v1 contract.

    .DESCRIPTION
        Builds the handshake JSON object defined in section 2 of
        documentation/vibeshield-capability-contract.md (schemaVersion=1) and
        writes it to the path supplied by the installer in
        $env:VIBESHIELD_RESULT_PATH. The file is written as UTF-8 without a
        byte-order mark (BOM), bypassing the default BOM behavior of
        Set-Content on Windows PowerShell which would corrupt the contract.

        The function reads three required environment variables that the
        installer sets per invocation:
            VIBESHIELD_RESULT_PATH       - destination file path
            VIBESHIELD_HANDSHAKE_VERSION - handshake schema version (currently '1')
            VIBESHIELD_CAPABILITY_NAME   - capability name in '<source>/<capability>' form

        If any of these env vars is missing the function throws. This is an
        agent / capability author error and should never happen at runtime
        when invoked by install-core.ps1.

    .PARAMETER Status
        Required. One of 'ok', 'partial', 'fail'. See section 2.4 of the
        contract for status semantics.

    .PARAMETER Message
        Optional but recommended. Human-readable summary. Truncated to 512
        characters by the installer before logging. See PII guidance in
        section 6 of the contract. If not supplied, an empty string is used
        (the field is required by the schema).

    .PARAMETER Details
        Optional. Free-form hashtable forwarded verbatim to telemetry. Omitted
        from the JSON when not supplied. See PII guidance in section 6.

    .PARAMETER SubSteps
        Optional. Array of hashtables, each with keys: name (string, required),
        status (string, required), message (string, optional). Up to 50
        entries; excess is truncated by the installer. Omitted from the JSON
        when not supplied.

    .EXAMPLE
        Set-VibeShieldCapabilityResult -Status ok -Message 'CodeQL CLI 2.20.0 installed' -Details @{ tool = 'codeql'; version = '2.20.0' }

    .EXAMPLE
        Set-VibeShieldCapabilityResult -Status fail -Message 'PREREQ_MISSING: unzip not available' -Details @{ missingTool = 'unzip' }

    .NOTES
        Spec: documentation/vibeshield-capability-contract.md sections 2 and 3.
        Migration plan: documentation/capability-contract-migration-plan-to-v0.6.md section 7.3.
        ASCII source only. Single exported function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ok', 'partial', 'fail')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [hashtable]$Details,

        [Parameter(Mandatory = $false)]
        [hashtable[]]$SubSteps
    )

    $resultPath       = $env:VIBESHIELD_RESULT_PATH
    $handshakeVersion = $env:VIBESHIELD_HANDSHAKE_VERSION
    $capabilityName   = $env:VIBESHIELD_CAPABILITY_NAME

    if ([string]::IsNullOrEmpty($resultPath)) {
        throw 'Set-VibeShieldCapabilityResult: required environment variable VIBESHIELD_RESULT_PATH is not set. The installer must set this per capability invocation (agent / capability author error).'
    }
    if ([string]::IsNullOrEmpty($handshakeVersion)) {
        throw 'Set-VibeShieldCapabilityResult: required environment variable VIBESHIELD_HANDSHAKE_VERSION is not set. The installer must set this per capability invocation (agent / capability author error).'
    }
    if ([string]::IsNullOrEmpty($capabilityName)) {
        throw 'Set-VibeShieldCapabilityResult: required environment variable VIBESHIELD_CAPABILITY_NAME is not set. The installer must set this per capability invocation (agent / capability author error).'
    }

    $messageValue = if ($PSBoundParameters.ContainsKey('Message')) { $Message } else { '' }

    $payload = [ordered]@{
        schemaVersion = 1
        capability    = $capabilityName
        status        = $Status
        message       = $messageValue
    }

    if ($PSBoundParameters.ContainsKey('Details') -and $null -ne $Details) {
        $payload['details'] = $Details
    }

    if ($PSBoundParameters.ContainsKey('SubSteps') -and $null -ne $SubSteps) {
        $subStepArray = @($SubSteps)
        if ($subStepArray.Count -gt 0) {
            $payload['subSteps'] = $subStepArray
        }
    }

    $payload['ts'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $json = $payload | ConvertTo-Json -Depth 10 -Compress:$false

    $parentDir = Split-Path -Parent -Path $resultPath
    if (-not [string]::IsNullOrEmpty($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($resultPath, $json, $utf8NoBom)
}

Export-ModuleMember -Function Set-VibeShieldCapabilityResult
