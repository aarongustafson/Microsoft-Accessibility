# Run all eval harnesses (considerations, deterministic, negative) across all models.
# For running individual harnesses, use the focused scripts:
#   run-consideration-evals.ps1, run-deterministic-evals.ps1, run-negative-evals.ps1
param(
    [ValidateRange(1, 1000)]
    [int]$SamplesPerTest = 5,

    # Path to a consideration YAML file or a unique alias (e.g. nonvisual-access).
    # When set, TaskSpecs is auto-populated from matching evals in considerations/, deterministic/, and negative/.
    [string]$Consideration,

    # Run only the considerations/ eval for the resolved consideration, skipping deterministic/ and negative/.
    [switch]$SingleTask,

    [string[]]$TaskSpecs = @("considerations/eval_keyboard_interaction.py"),

    [string[]]$Models = @(
        "copilot/gpt-5.6-sol",
        "copilot/gpt-5-mini",
        "copilot/claude-sonnet-5",
        "copilot/claude-sonnet-4.6",
        "copilot/claude-opus-4.6",
        "copilot/claude-haiku-4.5",
        "copilot/mai-code-1-flash-picker",
        "copilot/gemini-3.1-pro-preview"
    ),

    [ValidateSet("single", "medium", "all")]
    [string]$ConsiderationContextMode = "single",

    [ValidateSet("slim", "full")]
    [string]$HeuristicContextMode,

    [ValidateSet("strict", "benchmark")]
    [string]$SeverityExpectationMode,

    [hashtable]$JudgeOverrides = @{
        "copilot/gpt-5-mini" = "copilot/claude-opus-4.6"
    },

    [switch]$Quick,

    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "_eval-base.ps1")

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).ProviderPath

if ($Consideration) {
    $alias = Resolve-ConsiderationAlias -ConsiderationInput $Consideration -RepoRoot $repoRoot
    $evalsRoot = Join-Path $repoRoot 'tests\evals'
    $candidates = @(
        "considerations/eval_${alias}.py",
        "deterministic/${alias}.py",
        "negative/eval_${alias}_difficulties.py"
    )
    if ($SingleTask) { $candidates = @($candidates[0]) }

    $found = @()
    foreach ($spec in $candidates) {
        $fullPath = Join-Path $evalsRoot ($spec -replace '/', '\')
        if (Test-Path $fullPath) {
            $found += $spec
        } else {
            Write-Host "Skipping (not found): $spec"
        }
    }

    if ($found.Count -eq 0) {
        throw "No eval files found for consideration '$alias'. Searched in tests/evals/{considerations,deterministic,negative}."
    }
    $TaskSpecs = $found
}

$considerationSource = if ($env:CONSIDERATION_SOURCE -and $env:CONSIDERATION_SOURCE.Trim()) { $env:CONSIDERATION_SOURCE.Trim().ToLowerInvariant() } else { "md" }
if ($Consideration -and $Consideration -match '\.ya?ml$') {
    $considerationSource = "schema"
}

$invokeParams = @{
    SamplesPerTest     = $SamplesPerTest
    TaskSpecs          = $TaskSpecs
    Models             = $Models
    ConsiderationContextMode = $ConsiderationContextMode
    JudgeOverrides     = $JudgeOverrides
    Quick              = $Quick
    DryRun             = $DryRun
    ConsiderationSource      = $considerationSource
}
if ($HeuristicContextMode) { $invokeParams.HeuristicContextMode = $HeuristicContextMode }
if ($SeverityExpectationMode) { $invokeParams.SeverityExpectationMode = $SeverityExpectationMode }

$exitCode = Invoke-EvalSuite @invokeParams

exit $exitCode
