# Shared eval-running logic. Dot-source this from wrapper scripts.
# Expects the caller to have set:
#   $script:EvalParams — hashtable with keys matching the param block below.

function Invoke-EvalSuite {
    param(
        [ValidateRange(1, 1000)]
        [int]$SamplesPerTest = 5,

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

        [switch]$DryRun,

        [ValidateSet("md", "schema")]
        [string]$ConsiderationSource
    )

    $ErrorActionPreference = "Stop"

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).ProviderPath
    $pythonExe = Join-Path $repoRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path $pythonExe)) {
        $pythonExe = Join-Path $repoRoot ".venv/bin/python"
    }
    $logSummaryScript = Join-Path $repoRoot "scripts\summarize_eval_logs.py"
    $defaultJudgeModel = "copilot/gpt-5-mini"

    if (-not (Test-Path $pythonExe)) {
        throw "Python executable not found at $pythonExe. Create the venv first or update this script."
    }

    # Resolve the real Copilot CLI binary — the VS Code shim (copilot.bat) is
    # often 0-bytes and causes WinError 193 when spawned as a subprocess.
    if (-not $DryRun -and -not $env:COPILOT_CLI_PATH) {
        $copilotCmd = Get-Command copilot.cmd -ErrorAction SilentlyContinue
        $copilotExe = Get-Command copilot.exe -ErrorAction SilentlyContinue
        $copilotPosix = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue
        if ($copilotCmd) {
            $env:COPILOT_CLI_PATH = $copilotCmd.Source
        } elseif ($copilotExe) {
            $env:COPILOT_CLI_PATH = $copilotExe.Source
        } elseif ($copilotPosix) {
            $env:COPILOT_CLI_PATH = $copilotPosix.Source
        } else {
            throw "Cannot find a valid copilot CLI. Install @github/copilot globally or set COPILOT_CLI_PATH."
        }
        Write-Host "COPILOT_CLI_PATH: $env:COPILOT_CLI_PATH"
    }
    if (-not (Test-Path $logSummaryScript)) {
        throw "Log summary helper not found at $logSummaryScript."
    }

    $logsDir = Join-Path $repoRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -ErrorAction Stop | Out-Null
    }

    if (-not $TaskSpecs -or $TaskSpecs.Count -eq 0) {
        throw "TaskSpecs must be provided."
    }

    $considerationSource = if ($ConsiderationSource) { $ConsiderationSource } elseif ($env:CONSIDERATION_SOURCE -and $env:CONSIDERATION_SOURCE.Trim()) { $env:CONSIDERATION_SOURCE.Trim().ToLowerInvariant() } else { "md" }
    if ($considerationSource -notin @("md", "schema")) {
        throw "Unsupported CONSIDERATION_SOURCE '$considerationSource'; use 'md' or 'schema'."
    }
    $previousConsiderationSource = $env:CONSIDERATION_SOURCE

    Write-Host "Repo root: $repoRoot"
    Write-Host "Python:    $pythonExe"
    Write-Host "Samples:   $SamplesPerTest"
    Write-Host "Tasks:     $($TaskSpecs -join ', ')"
    Write-Host "Models:    $($Models.Count)"
    Write-Host ""

    $results = @()

    foreach ($model in $Models) {
        $previousLoopConsiderationSource = $env:CONSIDERATION_SOURCE
        $env:CONSIDERATION_SOURCE = $considerationSource
        try {
            $existingLogs = @{}
            Get-ChildItem -Path $logsDir -Filter *.eval -File | ForEach-Object {
                $existingLogs[$_.FullName] = $true
            }

            $evalArgs = @("-m", "tests.evals")
            $evalArgs += @("--samples_per_test", $SamplesPerTest.ToString())
            $evalArgs += @("--consideration_context_mode", $ConsiderationContextMode)

            if ($HeuristicContextMode) {
                $evalArgs += @("--heuristic_context_mode", $HeuristicContextMode)
            }
            if ($SeverityExpectationMode) {
                $evalArgs += @("--severity_expectation_mode", $SeverityExpectationMode)
            }
            if ($Quick) {
                $evalArgs += "--quick"
            }

            $judgeModel = Get-JudgeModelOverride -Model $model -AvailableModels $Models -Overrides $JudgeOverrides -DefaultJudgeModel $defaultJudgeModel
            if ($judgeModel) {
                $evalArgs += @("--judge_model", $judgeModel)
            }

            $evalArgs += $model
            $evalArgs += $TaskSpecs

            if ($judgeModel) {
                Write-Host "Judge override: $judgeModel"
            }

            Write-Host "============================================================"
            Write-Host "Running model: $model"
            Write-Host "Command: $pythonExe $($evalArgs -join ' ')"

            if ($DryRun) {
                $results += [pscustomobject]@{
                    Model = $model
                    Task = "(dry-run)"
                    Harness = "dry-run"
                    ExitCode = 0
                    Status = "dry-run"
                    Samples = $SamplesPerTest
                    AvgTokensExJudge = $null
                    AvgJudgeTokens = $null
                    SampleAccuracies = "[]"
                }
                continue
            }

            & $pythonExe @evalArgs
            $exitCode = $LASTEXITCODE

            $newLogs = Get-ChildItem -Path $logsDir -Filter *.eval -File |
                Where-Object { -not $existingLogs.ContainsKey($_.FullName) } |
                Sort-Object LastWriteTime, Name

            if ($newLogs.Count -eq 0) {
                $results += [pscustomobject]@{
                    Model = $model
                    Task = "(no logs found)"
                    Harness = "unknown"
                    ExitCode = $exitCode
                    Status = if ($exitCode -eq 0) { "success" } else { "failed" }
                    Samples = 0
                    AvgTokensExJudge = $null
                    AvgJudgeTokens = $null
                    SampleAccuracies = "[]"
                }
                continue
            }

            $summaryArgs = @($logSummaryScript, "--model", $model)
            foreach ($taskSpec in $TaskSpecs) {
                $summaryArgs += @("--task-spec", $taskSpec)
            }
            $summaryArgs += @($newLogs | ForEach-Object { $_.FullName })
            $summaryJson = & $pythonExe @summaryArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to summarize eval logs for $model"
            }

            $taskSummaries = $summaryJson | ConvertFrom-Json
            foreach ($taskSummary in @($taskSummaries)) {
                $results += [pscustomobject]@{
                    Model = $taskSummary.model
                    Task = $taskSummary.task
                    Harness = $taskSummary.harness
                    ExitCode = $exitCode
                    Status = $taskSummary.status
                    Samples = $taskSummary.sample_count
                    AvgTokensExJudge = $taskSummary.avg_tokens_ex_judge
                    AvgJudgeTokens = $taskSummary.avg_judge_tokens
                    SampleAccuracies = (@($taskSummary.sample_accuracies) | ConvertTo-Json -Compress)
                }
            }
        }
        finally {
            $env:CONSIDERATION_SOURCE = $previousLoopConsiderationSource
        }
    }

    $env:CONSIDERATION_SOURCE = $previousConsiderationSource

    Write-Host ""
    Write-Host "============================== Summary =============================="
    $hostWidth = try { $Host.UI.RawUI.BufferSize.Width } catch { 120 }
    $tableRows = $results | Select-Object Model, Task, Harness, ExitCode, Status, Samples, AvgTokensExJudge, AvgJudgeTokens, SampleAccuracies
    $tableOutput = $tableRows | Format-Table -Wrap -AutoSize | Out-String -Width $hostWidth

    $candidateTokenTotal = 0.0
    $judgeTokenTotal = 0.0
    foreach ($row in $results) {
        if ($null -eq $row.Samples -or $null -eq $row.AvgTokensExJudge -or $null -eq $row.AvgJudgeTokens) {
            continue
        }
        $candidateTokenTotal += ([double]$row.AvgTokensExJudge) * ([int]$row.Samples)
        $judgeTokenTotal += ([double]$row.AvgJudgeTokens) * ([int]$row.Samples)
    }
    $totalTokens = $candidateTokenTotal + $judgeTokenTotal
    $considerationFormatLabel = if ($considerationSource -eq "schema") { "schema" } else { "markdown" }

    $footerLines = @(
        "Consideration Format: $considerationFormatLabel",
        "Total Tokens: $('{0:N0}' -f [math]::Round($totalTokens, 0)) (Candidate: $('{0:N0}' -f [math]::Round($candidateTokenTotal, 0)), Judge: $('{0:N0}' -f [math]::Round($judgeTokenTotal, 0)))"
    )

    $summaryOutput = $tableOutput + [Environment]::NewLine + ($footerLines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Host $summaryOutput

    $testOutputsDir = Join-Path $repoRoot "tests\test_outputs"
    if (-not (Test-Path $testOutputsDir)) {
        New-Item -ItemType Directory -Path $testOutputsDir | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $outputFile = Join-Path $testOutputsDir $timestamp
    Set-Content -Path $outputFile -Value $summaryOutput
    Write-Host "Summary table written to: $outputFile"

    $failed = @($results | Where-Object { $_.ExitCode -ne 0 })
    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Host "One or more model runs failed." -ForegroundColor Red
        return 1
    }

    return 0
}

function Get-JudgeModelOverride {
    param(
        [string]$Model,
        [string[]]$AvailableModels,
        [hashtable]$Overrides,
        [string]$DefaultJudgeModel
    )

    if ($Overrides.ContainsKey($Model)) {
        return $Overrides[$Model]
    }

    if ($Model -ne $DefaultJudgeModel) {
        return $null
    }

    $preferredCandidates = @(
        "copilot/claude-sonnet-4.6",
        "copilot/claude-sonnet-5",
        "copilot/claude-opus-4.6",
        "copilot/claude-haiku-4.5"
    )

    foreach ($candidate in $preferredCandidates) {
        if ($AvailableModels -contains $candidate) {
            return $candidate
        }
    }

    foreach ($candidate in $AvailableModels) {
        if ($candidate -ne $DefaultJudgeModel) {
            return $candidate
        }
    }

    return $null
}

function Resolve-ConsiderationAlias {
    param(
        [string]$ConsiderationInput,
        [string]$RepoRoot
    )

    # Derive alias: strip path, extension(s), and clause prefix (e.g. 4.2.1-)
    $base = [System.IO.Path]::GetFileName($ConsiderationInput) -replace '\.consideration\.ya?ml$', '' -replace '\.ya?ml$', ''
    $alias = ($base -replace '^\d+\.\d+\.?\w*-', '') -replace '-', '_'

    if ($base -match '^\d+(?:\.\d+)+$') {
        $clauseCandidates = @(Get-ChildItem -Path (Join-Path $RepoRoot "schemas") -Filter "${base}-*.consideration.yaml" -File)
        if ($clauseCandidates.Count -gt 1) {
            throw "Multiple considerations for clause '${base}'; require a unique alias."
        }
        if ($clauseCandidates.Count -eq 0) {
            throw "No consideration for clause '${base}'."
        }
        $alias = ($clauseCandidates[0].BaseName -replace '\.consideration$', '' -replace '^\d+(?:\.\d+)+-', '') -replace '-', '_'
    }

    # Explicit source paths must exist; do not silently guess a different file.
    if ($ConsiderationInput -match '\.ya?ml$') {
        $candidate = if ([System.IO.Path]::IsPathRooted($ConsiderationInput)) { $ConsiderationInput } else { Join-Path $RepoRoot $ConsiderationInput }
        if (-not (Test-Path $candidate -PathType Leaf)) {
            throw "Consideration YAML file not found: $candidate"
        }
        $yamlAliases = @(Get-Content $candidate | Select-String '^alias:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim('"', "'") })
        if ($yamlAliases.Count -ne 1) {
            throw "Consideration YAML must define exactly one alias: $candidate"
        }
        $alias = $yamlAliases[0] -replace '-', '_'
    }

    return $alias
}
