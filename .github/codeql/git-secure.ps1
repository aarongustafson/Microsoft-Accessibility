# CodeQL bypass prevention wrapper for PowerShell
# Strips --no-verify and -n flags from git commit commands
param([Parameter(ValueFromRemainingArguments)]$gitArgs)

$ErrorActionPreference = 'Continue'

# Find the real git executable (not this wrapper)
$realGit = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
if (-not $realGit) { $realGit = 'git.exe' }

$cleaned = @()
$stripped = $false
$isCommit = $false

foreach ($arg in $gitArgs) {
    if ($arg -eq 'commit' -and -not $isCommit) {
        $isCommit = $true
        $cleaned += $arg
    }
    elseif ($isCommit -and $arg -eq '--no-verify') {
        $stripped = $true
    }
    elseif ($isCommit -and $arg -match '^-[a-zA-Z]*n[a-zA-Z]*$') {
        # Combined short flags containing -n (e.g., -an, -nm, -anm)
        $stripped = $true
        $remainder = $arg -replace 'n', ''
        if ($remainder -ne '-') {
            $cleaned += $remainder
        }
    }
    else {
        $cleaned += $arg
    }
}

if ($stripped) {
    Write-Host "[WARN] --no-verify is disabled. CodeQL security scan cannot be bypassed." -ForegroundColor Yellow
}

& $realGit @cleaned
exit $LASTEXITCODE
