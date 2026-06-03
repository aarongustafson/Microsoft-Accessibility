<#
.SYNOPSIS
    Resolves the repository root directory.

.DESCRIPTION
    Shared utility that resolves the repository root by walking up the
    directory tree from a starting point to find the .git directory.
    Submodule-aware: only matches .git directories (not .git files,
    which indicate a submodule). Falls back to the current working
    directory if no .git directory is found.

    Designed to be dot-sourced by other scripts:
      . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')

    After dot-sourcing, call Resolve-RepoRoot with an optional
    -StartDir parameter (defaults to $PSScriptRoot of the caller,
    then falls back to the current working directory).

.PARAMETER StartDir
    Optional. Directory to start searching from. Defaults to the
    caller's $PSScriptRoot, then the current working directory.

.OUTPUTS
    [string] Absolute path to the repository root directory, or $null
    if no .git directory is found.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
    $repoRoot = Resolve-RepoRoot

.EXAMPLE
    . (Join-Path $PSScriptRoot 'Resolve-RepoRoot.ps1')
    $repoRoot = Resolve-RepoRoot -StartDir 'C:\projects\myrepo'

.NOTES
    Returns $null if no .git directory is found. Callers should check
    the result and handle the missing-repo case appropriately.
    A .git *file* (not directory) indicates a git submodule -- this
    function skips .git files and keeps walking up to find the actual
    repository root.
#>

function Resolve-RepoRoot {
    [CmdletBinding()]
    param(
        [string]$StartDir
    )

    if (-not $StartDir) {
        $StartDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    }

    $searchDir = $StartDir
    while ($searchDir) {
        $candidate = Join-Path $searchDir '.git'
        if (Test-Path $candidate -PathType Container) {
            return $searchDir
        }
        $parent = Split-Path $searchDir -Parent
        if ($parent -eq $searchDir) { break }
        $searchDir = $parent
    }

    return $null
}
