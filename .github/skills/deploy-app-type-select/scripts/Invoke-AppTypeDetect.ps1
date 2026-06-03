#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Centralized app type detection engine — the sole authority for AppType identification.

.DESCRIPTION
    Data-driven marker-matching engine that reads app type definitions from
    deploy-config.json and scans workspace files to identify the project type.

    Exposes two functions:
      - Get-AppType: single-path detection (workspace root or specified path)
      - Get-ModuleAppTypes: multi-module detection (recursive scan)

    This script is self-contained — no SharedHelpers.ps1 dependency.
    It only reads deploy-config.json for the appTypes array.

.NOTES
    All app type rules (markers, build commands, test commands, SDK floors)
    are defined in deploy-config.json, NOT in this script.
    Adding a new app type = adding a JSON entry. No code changes.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load appTypes config ────────────────────────────────────
function Get-AppTypeConfig {
    <# Reads the appTypes array from deploy-config.json.
       Searches: workspace path, then relative to this script's location in the repo. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification='Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param([string]$WorkspacePath = $PWD.Path)

    $searchPaths = @(
        (Join-Path -Path $WorkspacePath -ChildPath '.github' 'config' 'deploy-config.json'),
        (Join-Path -Path (Split-Path -Path $WorkspacePath -Parent) -ChildPath '.github' 'config' 'deploy-config.json')
    )
    # Also search relative to the script's own location (handles test workspaces
    # that don't have deploy-config.json — the script lives in the VibeShield-Deploy repo)
    if ($PSScriptRoot) {
        $resolved1 = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\config\deploy-config.json' | Resolve-Path -ErrorAction SilentlyContinue
        $resolved2 = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\config\deploy-config.json' | Resolve-Path -ErrorAction SilentlyContinue
        if ($resolved1) { $searchPaths += $resolved1.Path }
        if ($resolved2) { $searchPaths += $resolved2.Path }
    }

    foreach ($p in $searchPaths) {
        if (-not $p) { continue }
        if (Test-Path $p) {
            try {
                $config = Get-Content $p -Raw | ConvertFrom-Json
                if ($config.appTypes -and $config.appTypes.Count -gt 0) {
                    return $config.appTypes
                }
            } catch {
                Write-Warning "Failed to parse deploy-config.json: $($_.Exception.Message)"
            }
        }
    }

    Write-Warning "deploy-config.json not found or has no appTypes — using empty config"
    return @()
}

# ── Core detection ──────────────────────────────────────────
function Get-AppType {
    <# Detects the app type for a single path by matching marker files
       against the appTypes config entries in priority order.

       Returns a hashtable with: AppType, TargetService, BuildCmd, TestCmd,
       ConfigFiles, Runtime, SdkVersionFloor — or $null if no match. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification='Returns dynamic PSCustomObject/hashtable')]
    [CmdletBinding()]
    param(
        [string]$Path = $PWD.Path,
        [string]$WorkspacePath = $PWD.Path
    )

    $appTypeEntries = Get-AppTypeConfig -WorkspacePath $WorkspacePath
    if ($appTypeEntries.Count -eq 0) { return $null }

    foreach ($entry in $appTypeEntries) {
        $markers = @($entry.markers)
        $depth = if ($null -ne $entry.markerDepth) { [int]$entry.markerDepth } else { 0 }

        # Check if any marker file exists at the specified path
        $matchedMarker = $null
        foreach ($marker in $markers) {
            # Marker can be a filename (e.g., 'host.json') or extension (e.g., '.csproj')
            $isExtension = $marker.StartsWith('.')
            $found = if ($isExtension) {
                Get-ChildItem -Path $Path -Recurse -Depth $depth -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -eq $marker } | Select-Object -First 1
            } else {
                Get-ChildItem -Path $Path -Recurse -Depth $depth -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $marker } | Select-Object -First 1
            }
            if ($found) { $matchedMarker = $found; break }
        }

        if (-not $matchedMarker) { continue }

        # ── Match found — build the result ──────────────────
        $result = @{
            AppType        = $entry.name
            TargetService  = $entry.targetService
            BuildCmd       = $entry.buildCmd
            TestCmd        = $entry.testCmd
            ConfigFiles    = @($entry.configFiles)
            Runtime        = $null
            SdkVersionFloor = $entry.sdkVersionFloor
            MatchedMarker  = $matchedMarker.Name
            DetectionConfidence = 95   # Primary marker match = high confidence
            DetectionNotes = @()       # Reasoning trail for confidence adjustments
        }

        # ── Sub-detection: variants (F#, VB.NET from .NET) ──
        if ($entry.PSObject.Properties['variants'] -and $entry.variants) {
            $ext = $matchedMarker.Extension
            $variantProps = $entry.variants.PSObject.Properties
            foreach ($v in $variantProps) {
                if ($v.Name -eq $ext) {
                    $result.AppType = $v.Value
                    $result.DetectionNotes += "Variant sub-detection: $($v.Name) -> $($v.Value)"
                    break
                }
            }
        }

        # ── Sub-detection: runtimes (Functions sub-type) ────
        if ($entry.PSObject.Properties['runtimes'] -and $entry.runtimes) {
            $runtimeProps = $entry.runtimes.PSObject.Properties
            $runtimeMatchCount = 0
            foreach ($rt in $runtimeProps) {
                $rtConfig = $rt.Value
                $rtMarkers = @($rtConfig.markers)
                $rtDepth = if ($rtConfig.PSObject.Properties['markerDepth'] -and $null -ne $rtConfig.markerDepth) { [int]$rtConfig.markerDepth } else { 0 }
                $rtFound = $false
                foreach ($rm in $rtMarkers) {
                    $isExt = $rm.StartsWith('.')
                    $match = if ($isExt) {
                        Get-ChildItem -Path $Path -Recurse -Depth $rtDepth -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Extension -eq $rm } | Select-Object -First 1
                    } else {
                        Get-ChildItem -Path $Path -Recurse -Depth $rtDepth -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -eq $rm } | Select-Object -First 1
                    }
                    if ($match) { $rtFound = $true; break }
                }
                if ($rtFound) {
                    $runtimeMatchCount++
                    $result.Runtime = $rt.Name
                    $result.DetectionNotes += "Runtime detected: $($rt.Name) via marker match"
                    # Runtime can override build/test commands
                    if ($rtConfig.PSObject.Properties['buildCmd'] -and $rtConfig.buildCmd) { $result.BuildCmd = $rtConfig.buildCmd }
                    if ($rtConfig.PSObject.Properties['testCmd'] -and $rtConfig.testCmd)  { $result.TestCmd = $rtConfig.testCmd }
                    break
                }
            }
            # Functions with no detected runtime is lower confidence
            if ($runtimeMatchCount -eq 0 -and $entry.name -eq 'Functions') {
                $result.DetectionConfidence = 70
                $result.DetectionNotes += 'host.json found but no runtime markers detected nearby — confidence reduced'
            }
        }

        # ── Sub-detection: frontend override (Node.js) ──────
        if ($entry.PSObject.Properties['frontendDetection'] -and $entry.frontendDetection) {
            $fd = $entry.frontendDetection
            $pkgPath = Join-Path -Path $Path -ChildPath 'package.json'
            if (Test-Path $pkgPath) {
                try {
                    $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
                    $allDeps = @()
                    if ($pkg.PSObject.Properties['dependencies'])    { $allDeps += $pkg.dependencies.PSObject.Properties.Name }
                    if ($pkg.PSObject.Properties['devDependencies']) { $allDeps += $pkg.devDependencies.PSObject.Properties.Name }
                    $depsJoined = $allDeps -join ','
                    $isFrontend = $false
                    foreach ($pattern in $fd.dependencyPatterns) {
                        if ($depsJoined -match $pattern) { $isFrontend = $true; break }
                    }
                    if ($isFrontend) {
                        $result.AppType = $fd.overrideName
                        $result.TargetService = $fd.overrideTargetService
                        $result.DetectionConfidence = 85
                        $result.DetectionNotes += "Frontend override: dependency pattern matched ($($fd.dependencyPatterns -join ', ')) — reclassified from Node.js backend to $($fd.overrideName)"
                    }
                } catch {
                    $null = $_ # Parse error — stay with backend classification
                }
            }
        }

        # ── Sub-detection: build command overrides ──────────
        if ($entry.PSObject.Properties['buildCmdOverrides'] -and $entry.buildCmdOverrides) {
            $overrideProps = $entry.buildCmdOverrides.PSObject.Properties
            foreach ($ov in $overrideProps) {
                $ovMarker = $ov.Name
                $ovFound = Get-ChildItem -Path $Path -Depth 0 -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $ovMarker } | Select-Object -First 1
                if ($ovFound) {
                    $ovConfig = $ov.Value
                    if ($ovConfig.PSObject.Properties['buildCmd'] -and $ovConfig.buildCmd)       { $result.BuildCmd = $ovConfig.buildCmd }
                    if ($ovConfig.PSObject.Properties['testCmd'] -and $ovConfig.testCmd)         { $result.TestCmd = $ovConfig.testCmd }
                    if ($ovConfig.PSObject.Properties['configFiles'] -and $ovConfig.configFiles) { $result.ConfigFiles = @($ovConfig.configFiles) }
                    break
                }
            }
        }

        # ── Check if build script exists (Node.js) ──────────
        if ($result.AppType -in @('Node.js backend', 'Static frontend') -and -not $result.BuildCmd) {
            $pkgPath = Join-Path -Path $Path -ChildPath 'package.json'
            if (Test-Path $pkgPath) {
                try {
                    $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
                    if ($pkg.PSObject.Properties['scripts'] -and $pkg.scripts.PSObject.Properties['build']) {
                        $result.BuildCmd = 'npm run build'
                    }
                } catch { $null = $_ }
            }
        }

        return $result
    }

    # No match
    return $null
}

# ── Multi-module detection ──────────────────────────────────
function Get-ModuleAppTypes {
    <# Scans a workspace recursively to detect all modules and their app types.
       Returns an array of results, one per detected module.

       Uses the same appTypes config as Get-AppType but scans directories
       to find independent deployable modules. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Plural noun is intentional')]
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PWD.Path,
        [string[]]$ExcludeDirs = @('node_modules', 'bin', 'obj', 'dist', '.git', '.github',
            '.vibeshield', '__pycache__', '.venv', 'venv', '.terraform', 'packages',
            'TestResults', '.vs', '.vscode', '.idea', 'coverage', '.nyc_output',
            'target', 'build', 'out', '.gradle')
    )

    $modules = @()

    # Detect root module
    $rootResult = Get-AppType -Path $WorkspacePath -WorkspacePath $WorkspacePath
    if ($rootResult) {
        $rootResult['ModulePath'] = '.'
        $modules += $rootResult
    }

    # Scan subdirectories for additional modules
    $monorepoRoots = @('src', 'apps', 'packages', 'services', 'modules')
    $subdirs = Get-ChildItem -Path $WorkspacePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -notin $ExcludeDirs) -or ($_.Name -in $monorepoRoots) }

    foreach ($subdir in $subdirs) {
        # Check if this subdirectory is an independent module (skip monorepo root containers)
        if ($subdir.Name -notin $monorepoRoots) {
            $subResult = Get-AppType -Path $subdir.FullName -WorkspacePath $WorkspacePath
            if ($subResult) {
                $relPath = [System.IO.Path]::GetRelativePath($WorkspacePath, $subdir.FullName)
                $subResult['ModulePath'] = $relPath
                $modules += $subResult
            }
        }

        # One level deeper for src/backend, src/frontend patterns
        if ($subdir.Name -in $monorepoRoots) {
            $nestedDirs = Get-ChildItem -Path $subdir.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin $ExcludeDirs }
            foreach ($nested in $nestedDirs) {
                $nestedResult = Get-AppType -Path $nested.FullName -WorkspacePath $WorkspacePath
                if ($nestedResult) {
                    $relPath = [System.IO.Path]::GetRelativePath($WorkspacePath, $nested.FullName)
                    $nestedResult['ModulePath'] = $relPath
                    $modules += $nestedResult
                }
            }
        }
    }

    return $modules
}
