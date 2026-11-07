# Run negative evals (tests/evals/negative/) across all models.
param(
    [ValidateRange(1, 1000)]
    [int]$SamplesPerTest = 5,

    # Path to a consideration YAML file or a unique alias (e.g. nonvisual-access).
    [string]$Consideration,

    [string[]]$TaskSpecs,

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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).ProviderPath

if (-not $TaskSpecs) {
    if ($Consideration) {
        $alias = Resolve-ConsiderationAlias -ConsiderationInput $Consideration -RepoRoot $repoRoot
        $evalsRoot = Join-Path $repoRoot 'tests\evals'
        $spec = "negative/eval_${alias}_difficulties.py"
        $fullPath = Join-Path $evalsRoot ($spec -replace '/', '\')
        if (-not (Test-Path $fullPath)) {
            throw "Negative eval not found: $spec (searched $fullPath)"
        }
        $TaskSpecs = @($spec)
    } else {
        # Default: all negative evals (exclude files starting with _)
        $evalsRoot = Join-Path $repoRoot 'tests\evals\negative'
        $TaskSpecs = @(Get-ChildItem -Path $evalsRoot -Filter "eval_*.py" -File |
            ForEach-Object { "negative/$($_.Name)" })
    }
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
