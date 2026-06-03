<#
.SYNOPSIS
    Determines projectType (prototype or businessUse) based on screening answers or prompt signals.

.DESCRIPTION
    Implements the classification strategy from docs/classification-strategy.md.
    For Test/UAT/Prod → always returns businessUse.
    For POC/DEV → runs screening or infers from prompt signals.

.PARAMETER TargetEnvironment
    The deployment target: POC, DEV, Test, UAT, or Prod.

.PARAMETER ScreeningAnswers
    Hashtable of screening question answers. Keys: HandlesPII, SharedAcrossTeams, AIDecisionImpact, EnterpriseIntegrations.
    Values: $true (yes), $false (no), $null (not sure → treated as yes).

.PARAMETER PromptText
    Optional. The user's initial prompt text for signal inference.

.OUTPUTS
    PSCustomObject with ProjectType, Reasoning, ScreeningPath.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('POC', 'DEV', 'Test', 'UAT', 'Prod')]
    [string]$TargetEnvironment,

    [Parameter()]
    [hashtable]$ScreeningAnswers,

    [Parameter()]
    [string]$PromptText
)

# --- Auto-businessUse environments ---
$alwaysBusinessUse = @('Test', 'UAT', 'Prod')
if ($TargetEnvironment -in $alwaysBusinessUse) {
    return [PSCustomObject]@{
        ProjectType   = 'businessUse'
        Reasoning     = "$TargetEnvironment always requires businessUse — no screening needed."
        ScreeningPath = 'auto-environment'
    }
}

# --- Prompt signal inference ---
if ($PromptText) {
    $businessUseSignals = @('customer data', 'PII', 'production', 'compliance', 'customer-facing', 'real users', 'EUII', 'sensitive', 'regulated', 'SOC', 'FedRAMP', 'HIPAA')
    $prototypeSignals = @('hackathon', 'demo', 'sandbox', 'experiment', 'just testing', 'throwaway', 'prototype', 'learning', 'quick POC')

    $lowerPrompt = $PromptText.ToLower()

    foreach ($signal in $businessUseSignals) {
        if ($lowerPrompt.Contains($signal.ToLower())) {
            return [PSCustomObject]@{
                ProjectType   = 'businessUse'
                Reasoning     = "Prompt contains '$signal' — inferred businessUse."
                ScreeningPath = 'prompt-inference'
            }
        }
    }

    foreach ($signal in $prototypeSignals) {
        if ($lowerPrompt.Contains($signal.ToLower())) {
            return [PSCustomObject]@{
                ProjectType   = 'prototype'
                Reasoning     = "Prompt contains '$signal' — inferred prototype."
                ScreeningPath = 'prompt-inference'
            }
        }
    }
}

# --- Screening sequence ---
if (-not $ScreeningAnswers) {
    # No answers provided — caller must ask the user
    return [PSCustomObject]@{
        ProjectType   = $null
        Reasoning     = 'No screening answers or prompt signals — screening questions required.'
        ScreeningPath = 'needs-screening'
    }
}

$questions = @(
    @{ Key = 'HandlesPII';              Label = 'Handles PII or confidential data' }
    @{ Key = 'SharedAcrossTeams';       Label = 'Shared across teams or external users' }
    @{ Key = 'AIDecisionImpact';        Label = 'AI/decision impact on people' }
    @{ Key = 'EnterpriseIntegrations';  Label = 'Enterprise integrations or persistent sensitive storage' }
)

foreach ($q in $questions) {
    $answer = $ScreeningAnswers[$q.Key]
    # $null (not sure) or $true (yes) → businessUse
    if ($null -eq $answer -or $answer -eq $true) {
        $reason = if ($null -eq $answer) { "Not sure about '$($q.Label)' — defaulting to businessUse." }
                  else { "Yes to '$($q.Label)' — classified as businessUse." }
        return [PSCustomObject]@{
            ProjectType   = 'businessUse'
            Reasoning     = $reason
            ScreeningPath = "screening-$($q.Key)"
        }
    }
    # $false (no) → continue to next question
}

# All answers were "no" → prototype
return [PSCustomObject]@{
    ProjectType   = 'prototype'
    Reasoning     = 'All screening questions answered No — classified as prototype.'
    ScreeningPath = 'screening-complete'
}
