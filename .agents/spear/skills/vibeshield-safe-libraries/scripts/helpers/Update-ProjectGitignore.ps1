function Update-ProjectGitignore {
    <#
    .SYNOPSIS
        Creates or updates .gitignore to exclude .venv/.

    .DESCRIPTION
        If .gitignore exists and does not contain .venv/, appends it.
        If .gitignore does not exist, creates it with .venv/.

    .PARAMETER ProjectRoot
        Absolute path to the project root directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = [PSCustomObject]@{ Created = 0; Skipped = 0; Warned = 0; Failed = 0 }

    Write-Host '' -ForegroundColor Cyan
    Write-Host '--- .gitignore ---' -ForegroundColor Cyan

    $gitignorePath = Join-Path $ProjectRoot '.gitignore'
    $venvEntry = '.venv/'

    if (Test-Path $gitignorePath) {
        $gitignoreContent = @(Get-Content -Path $gitignorePath -ErrorAction SilentlyContinue)
        $hasVenvEntry = $false
        foreach ($line in $gitignoreContent) {
            if ($line.Trim() -eq $venvEntry) {
                $hasVenvEntry = $true
                break
            }
        }
        if (-not $hasVenvEntry) {
            if ($PSCmdlet.ShouldProcess($gitignorePath, 'Append .venv/ entry')) {
                Add-Content -Path $gitignorePath -Value "`n$venvEntry"
                Write-Host '  UPDATED: .gitignore (appended .venv/)' -ForegroundColor Green
                $result.Created++
            }
        } else {
            Write-Host '  SKIPPED: .gitignore already contains .venv/' -ForegroundColor Cyan
            $result.Skipped++
        }
    } else {
        if ($PSCmdlet.ShouldProcess($gitignorePath, 'Create .gitignore with .venv/ entry')) {
            Set-Content -Path $gitignorePath -Value $venvEntry
            Write-Host '  CREATED: .gitignore (with .venv/)' -ForegroundColor Green
            $result.Created++
        }
    }

    return $result
}
