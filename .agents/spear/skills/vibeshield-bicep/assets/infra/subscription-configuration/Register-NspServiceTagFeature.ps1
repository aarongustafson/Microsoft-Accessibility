<#
.SYNOPSIS
    Registers the Microsoft.Network/EnableServiceTagsInNsp subscription feature
    required for NSP access rules that reference the CorpNetPublic or CorpNetSAW
    service tags.

.DESCRIPTION
    Why this is needed:
    NSP access rules referencing the CorpNetPublic or CorpNetSAW service tags will
    fail deployment with a mysterious error like "Invalid service tag ID CorpNetPublic"
    (and the same for CorpNetSAW) unless the 'EnableServiceTagsInNsp' subscription
    feature is registered first. CorpNetPublic and CorpNetSAW are special tags that
    allow traffic from the Microsoft corporate network (CorpNetPublic) and Secure
    Admin Workstations (CorpNetSAW). They are not fully onboarded by the IPAM system
    and are treated as an internal special feature -- gated behind this subscription
    feature flag. They may not work in the AME tenant.

    Subscription features cannot be registered from Bicep, so Deploy.ps1 (and anyone
    deploying the NSP module manually) must run this script first. The feature is
    registered once per subscription and then covers all service-tag-based NSP rules
    in that subscription -- no per-rule registration is needed.

    Idempotent: queries current state and only registers + polls when not already
    'Registered'. Also re-registers the Microsoft.Network provider so the newly
    enabled feature takes effect.

.PARAMETER TimeoutMinutes
    Maximum time to wait for the feature to reach 'Registered'. Defaults to 30.

.PARAMETER PollSeconds
    Delay between state polls. Defaults to 15.

.EXAMPLE
    .\Register-NspServiceTagFeature.ps1

.NOTES
    Prerequisites:
    - Azure CLI installed and logged in (az login)
    - Signed-in identity pointed at the correct subscription -- verify with
      `az account show` and switch with `az account set --subscription <id>` if needed

    Required Azure RBAC (at subscription scope):
    - `Microsoft.Features/*` -- list, register, and read preview features
      (covers `az feature register` and `az feature show`)
    - `Microsoft.Network/register/action` -- re-register the Microsoft.Network provider
      (covers `az provider register --namespace Microsoft.Network`)

    Built-in roles that grant both: **Contributor** or **Owner** at subscription scope.
    A custom role containing just the two actions above is sufficient and preferred
    per least-privilege (SFI). Per the constitution, use JIT/JEA elevation rather
    than standing Contributor assignments.

    Scope note: Feature and provider registration are subscription-level operations.
    Resource-group-scoped role assignments will not work. Registering once per
    subscription covers all NSP service-tag access rules in that subscription.

    References:
    - Preview feature registration required access:
      https://learn.microsoft.com/azure/azure-resource-manager/management/preview-features#required-access
    - Resource provider registration required access:
      https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types#register-resource-provider
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$TimeoutMinutes = 30,

    [Parameter()]
    [int]$PollSeconds = 15
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "Ensuring Microsoft.Network/EnableServiceTagsInNsp feature is registered..." -ForegroundColor Yellow

$state = az feature show --namespace Microsoft.Network --name EnableServiceTagsInNsp --query "properties.state" -o tsv 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to query feature registration state. Is 'az login' current?" -ForegroundColor Red
    exit 1
}

if ($state -ne 'Registered') {
    Write-Host "  Current state: $state. Registering (this can take 10-20 minutes)..." -ForegroundColor Yellow
    az feature register --namespace Microsoft.Network --name EnableServiceTagsInNsp | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: 'az feature register' failed." -ForegroundColor Red
        exit 1
    }

    $started = Get-Date
    while ($state -ne 'Registered') {
        Start-Sleep -Seconds $PollSeconds
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        if ($elapsed -ge ($TimeoutMinutes * 60)) {
            Write-Host ""
            Write-Host "ERROR: Feature registration did not complete within $TimeoutMinutes minutes." -ForegroundColor Red
            Write-Host "  Check status with: az feature show --namespace Microsoft.Network --name EnableServiceTagsInNsp" -ForegroundColor Yellow
            exit 1
        }
        $state = az feature show --namespace Microsoft.Network --name EnableServiceTagsInNsp --query "properties.state" -o tsv 2>$null
        Write-Host "`r  [${elapsed}s elapsed] State: $state   " -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""

    az provider register --namespace Microsoft.Network | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: 'az provider register' failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Feature registered." -ForegroundColor Green
Write-Host ""
