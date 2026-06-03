#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    VibeShield-Deploy workspace analysis — discovers all deployable modules,
    classifies app types, inventories tests, and detects existing Bicep.

.DESCRIPTION
    Scans the target workspace to produce a structured workspace manifest (JSON)
    that drives pipeline generation and Bicep coordination.

    Phases:
      WA-01  Source code discovery (root + recursive subdirectory scan)
      WA-02  Per-module app type classification
      WA-02c Scaffolding completeness (lock files, solution files) — ex PF-01b
      WA-03  Test suite inventory (unit / integration / e2e per module)
      WA-04  Existing Bicep discovery and gap analysis
      WA-05  Pipeline stage coverage check (if pipeline YAML exists)

    Exit code 0 = analysis completed. Exit code 1 = no deployable modules found.

.PARAMETER WorkspacePath
    Path to the application workspace. Defaults to current directory.

.PARAMETER SourcePath
    Optional relative path to a specific subdirectory to scope analysis to.
    When set, only this subdirectory (and its children) are scanned for
    deployable modules. The rest of the workspace is ignored.
    Example: 'dpia-system-starter' or 'src/MyApp'.

.PARAMETER PipelineYmlPath
    Relative path to the pipeline YAML file. Defaults to .azdo/pipelines/azure-pipeline.yml.

.PARAMETER OutputPath
    Path to write the workspace manifest JSON file.
    Defaults to .vibeshield/results/workspace-manifest.json in the workspace.

.EXAMPLE
    ./.github/skills/deploy-workspace-analysis/scripts/Invoke-WorkspaceAnalysis.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Plural nouns are intentional for collection-returning functions')]
[CmdletBinding()]
param(
    [string]$WorkspacePath = $PWD.Path,
    [string]$SourcePath,
    [string]$PipelineYmlPath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Load shared helpers ─────────────────────────────────────
$sharedHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\SharedHelpers.ps1'
if (Test-Path $sharedHelpersPath) { . $sharedHelpersPath }
Assert-ScriptIntegrity -WorkspacePath $WorkspacePath

# ── Resolve pipeline YAML path from config if not provided ──
if (-not $PipelineYmlPath) { $PipelineYmlPath = Get-PipelineYamlRelPath }

# ── Resolve workspace ──────────────────────────────────────
$WorkspacePath = (Resolve-Path -Path $WorkspacePath -ErrorAction Stop).Path

# ── Output path ─────────────────────────────────────────────
if (-not $OutputPath) {
    $OutputPath = Join-Path -Path (Get-ResultsDir -WorkspacePath $WorkspacePath) -ChildPath 'workspace-manifest.json'
}
$outDir = Split-Path -Path $OutputPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# ── Constants ───────────────────────────────────────────────
$script:ExcludeDirs = @(
    'node_modules', 'bin', 'obj', '.git', '.github', '.azdo',
    '.vibeshield', 'infra', 'dist', 'build', 'out', 'target',
    '__pycache__', '.venv', 'venv', '.vs', '.idea', 'coverage',
    '.next', '.nuxt', 'packages',
    # Backup / recovered / archive directories
    '_recovered', '_backup', '_bak', '_old', '_archive', '_deprecated',
    'backup', 'bak', 'old', 'archive', 'deprecated', 'archived'
)

$script:MarkerFiles = @(
    'host.json', 'Dockerfile', '*.csproj', '*.fsproj', '*.vbproj',
    'package.json', 'pom.xml', 'build.gradle', 'build.gradle.kts',
    'requirements.txt', 'pyproject.toml', 'go.mod', 'Cargo.toml',
    'index.html'
)

# ── Load centralized app type detection engine ──────────────
$script:WorkspacePath = $WorkspacePath
$detectScript = Join-Path -Path $WorkspacePath -ChildPath '.github' -AdditionalChildPath 'skills', 'deploy-app-type-select', 'scripts', 'Invoke-AppTypeDetect.ps1'
if (-not (Test-Path $detectScript) -and $PSScriptRoot) {
    # Fallback: resolve relative to this script's location (handles test workspaces)
    $detectScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\deploy-app-type-select\scripts\Invoke-AppTypeDetect.ps1'
}
if (Test-Path $detectScript) {
    . $detectScript
} else {
    Write-Warning "Centralized detection script not found — Get-ModuleAppType will return Unknown"
}
# Restore ErrorActionPreference after dot-sourcing (Invoke-AppTypeDetect sets 'Stop')
$ErrorActionPreference = 'Continue'

# ════════════════════════════════════════════════════════════
# Helper: Classify a module by its marker files
# Delegates to centralized deploy-app-type-select detection engine.
# ════════════════════════════════════════════════════════════
function Get-ModuleAppType {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Markers', Justification='Interface contract parameter')]
    param(
        [string]$ModulePath,
        [string[]]$Markers
    )

    # Use centralized detection engine if available
    if (Get-Command Get-AppType -ErrorAction SilentlyContinue) {
        $detection = Get-AppType -Path $ModulePath -WorkspacePath $script:WorkspacePath
        if ($detection) {
            return [pscustomobject]@{
                AppType             = $detection.AppType
                TargetService       = $detection.TargetService
                Runtime             = $detection.Runtime
                DetectionConfidence = if ($detection.ContainsKey('DetectionConfidence')) { $detection.DetectionConfidence } else { 95 }
                DetectionNotes      = if ($detection.ContainsKey('DetectionNotes')) { $detection.DetectionNotes } else { @() }
            }
        }
    }

    # Fallback: return Unknown if centralized detection unavailable
    return [pscustomobject]@{
        AppType       = 'Unknown'
        TargetService = 'Unknown'
        Runtime       = $null
    }
}

# ════════════════════════════════════════════════════════════
# Helper: Detect test suites for a module
# ════════════════════════════════════════════════════════════
function Get-ModuleTests {
    param(
        [string]$ModulePath,
        [string]$AppType
    )

    $hasUnit        = $false
    $hasIntegration = $false
    $hasE2E         = $false
    $framework      = $null
    $testPaths      = @()

    $effectiveType = $AppType
    if ($effectiveType -in @('F#', 'VB.NET')) { $effectiveType = '.NET' }
    if ($effectiveType -eq 'Static frontend') { $effectiveType = 'Node.js backend' }

    switch ($effectiveType) {
        '.NET' {
            # Look for *.Tests.csproj / *.Test.csproj in sibling or child directories
            # Use parent directory for sibling search, but never go above the workspace root
            $parentSearch = Split-Path -Path $ModulePath -Parent
            $resolvedParent = (Resolve-Path -Path $parentSearch -ErrorAction SilentlyContinue).Path
            $resolvedWorkspace = (Resolve-Path -Path $WorkspacePath -ErrorAction SilentlyContinue).Path
            if (-not $resolvedParent -or -not $resolvedWorkspace -or -not $resolvedParent.StartsWith($resolvedWorkspace)) {
                $parentSearch = $ModulePath
            }
            $testProjects = Get-ChildItem -Path $parentSearch -Recurse -Depth 3 `
                -Include '*.Tests.csproj','*.Test.csproj' -ErrorAction SilentlyContinue
            if (-not $testProjects) {
                $testProjects = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 `
                    -Include '*.Tests.csproj','*.Test.csproj' -ErrorAction SilentlyContinue
            }
            if ($testProjects) {
                $hasUnit = $true
                $testPaths = @($testProjects | ForEach-Object {
                    $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $_.DirectoryName)
                    $rel -replace '\\','/'
                })
                # Detect framework from csproj content
                foreach ($tp in $testProjects) {
                    $content = Get-Content $tp.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content -match 'xunit') { $framework = 'xunit'; break }
                    if ($content -match 'NUnit') { $framework = 'nunit'; break }
                    if ($content -match 'MSTest|Microsoft\.VisualStudio\.TestPlatform') { $framework = 'mstest'; break }
                }
            }
        }
        'Node.js backend' {
            $pkgPath = Join-Path -Path $ModulePath -ChildPath 'package.json'
            if (Test-Path $pkgPath) {
                try {
                    $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    $devDeps = @()
                    if ($pkg.PSObject.Properties['devDependencies']) {
                        $devDeps = $pkg.devDependencies.PSObject.Properties.Name
                    }
                    if ($devDeps -match 'jest') { $framework = 'jest'; $hasUnit = $true }
                    elseif ($devDeps -match 'vitest') { $framework = 'vitest'; $hasUnit = $true }
                    elseif ($devDeps -match 'mocha') { $framework = 'mocha'; $hasUnit = $true }
                    if ($devDeps -match 'cypress') { $hasE2E = $true }
                    if ($devDeps -match 'playwright') { $hasE2E = $true }
                } catch { <# JSON parse may fail #> $null = $_ }
            }
            # Check for test directories
            $testDirs = @('test', '__tests__', 'tests', 'spec')
            foreach ($td in $testDirs) {
                $tdPath = Join-Path -Path $ModulePath -ChildPath $td
                if (Test-Path $tdPath) {
                    $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $tdPath)
                    $testPaths += $rel -replace '\\','/'
                    if (-not $hasUnit) { $hasUnit = $true }
                }
            }
            # Test files in module root
            $testFiles = Get-ChildItem -Path $ModulePath -Depth 2 `
                -Include '*.test.js','*.spec.js','*.test.ts','*.spec.ts' -ErrorAction SilentlyContinue
            if ($testFiles -and -not $hasUnit) { $hasUnit = $true }
        }
        'Python' {
            $testDirs = @('tests', 'test')
            foreach ($td in $testDirs) {
                $tdPath = Join-Path -Path $ModulePath -ChildPath $td
                if (Test-Path $tdPath) {
                    $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $tdPath)
                    $testPaths += $rel -replace '\\','/'
                    $hasUnit = $true
                }
            }
            $testFiles = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 `
                -Include 'test_*.py','*_test.py' -ErrorAction SilentlyContinue
            if ($testFiles) { $hasUnit = $true }
            # Check for pytest in requirements or pyproject
            $reqPath = Join-Path -Path $ModulePath -ChildPath 'requirements.txt'
            $reqDevPath = Join-Path -Path $ModulePath -ChildPath 'requirements-dev.txt'
            $pyprojectPath = Join-Path -Path $ModulePath -ChildPath 'pyproject.toml'
            $allReqContent = ''
            foreach ($rp in @($reqPath, $reqDevPath, $pyprojectPath)) {
                if (Test-Path $rp) { $allReqContent += Get-Content $rp -Raw -ErrorAction SilentlyContinue }
            }
            if ($allReqContent -match 'pytest') { $framework = 'pytest' }
            elseif ($allReqContent -match 'unittest') { $framework = 'unittest' }
        }
        'Java' {
            $srcTestJava = Join-Path -Path $ModulePath -ChildPath 'src/test/java'
            if (Test-Path $srcTestJava) {
                $hasUnit = $true
                $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $srcTestJava)
                $testPaths += $rel -replace '\\','/'
            }
            $pomPath = Join-Path -Path $ModulePath -ChildPath 'pom.xml'
            if (Test-Path $pomPath) {
                $content = Get-Content $pomPath -Raw -ErrorAction SilentlyContinue
                if ($content -match 'junit') { $framework = 'junit' }
                elseif ($content -match 'testng') { $framework = 'testng' }
            }
        }
        'Go' {
            $goTestFiles = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 `
                -Include '*_test.go' -ErrorAction SilentlyContinue
            if ($goTestFiles) {
                $hasUnit = $true
                $framework = 'go test'
                $testPaths = @($goTestFiles | ForEach-Object {
                    $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $_.DirectoryName)
                    $rel -replace '\\','/'
                } | Sort-Object -Unique)
            }
        }
        'Rust' {
            $testsDir = Join-Path -Path $ModulePath -ChildPath 'tests'
            if (Test-Path $testsDir) {
                $hasUnit = $true
                $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $testsDir)
                $testPaths += $rel -replace '\\','/'
            }
            # Check for #[test] in src files
            $rsFiles = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 -Include '*.rs' -ErrorAction SilentlyContinue
            foreach ($rf in $rsFiles) {
                if ((Get-Content $rf.FullName -Raw -ErrorAction SilentlyContinue) -match '#\[test\]') {
                    $hasUnit = $true
                    $framework = 'cargo test'
                    break
                }
            }
        }
        'Functions' {
            # Functions test detection follows the runtime language pattern
            # Delegate to the runtime language patterns above would require recursion;
            # instead do a simple search for test files
            $funcParentSearch = Split-Path -Path $ModulePath -Parent
            $resolvedFuncParent = (Resolve-Path -Path $funcParentSearch -ErrorAction SilentlyContinue).Path
            $resolvedFuncWorkspace = (Resolve-Path -Path $WorkspacePath -ErrorAction SilentlyContinue).Path
            if (-not $resolvedFuncParent -or -not $resolvedFuncWorkspace -or -not $resolvedFuncParent.StartsWith($resolvedFuncWorkspace)) {
                $funcParentSearch = $ModulePath
            }
            $testProjects = Get-ChildItem -Path $funcParentSearch -Recurse -Depth 3 `
                -Include '*.Tests.csproj','*.Test.csproj' -ErrorAction SilentlyContinue
            $testFiles = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 `
                -Include '*.test.js','*.spec.js','*.test.ts','*.spec.ts','test_*.py','*_test.py','*_test.go','*Test.java' `
                -ErrorAction SilentlyContinue
            if ($testProjects -or $testFiles) {
                $hasUnit = $true
                $testPaths = @(($testProjects + $testFiles) | Where-Object { $_ } | ForEach-Object {
                    $d = if ($_.PSIsContainer) { $_.FullName } else { $_.DirectoryName }
                    $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $d)
                    $rel -replace '\\','/'
                } | Sort-Object -Unique)
            }
        }
    }

    # Integration test detection (cross-language)
    $integrationDirs = @('integration-tests', 'tests/integration', 'test/integration')
    foreach ($id in $integrationDirs) {
        $idPath = Join-Path -Path $ModulePath -ChildPath $id
        if (Test-Path $idPath) {
            $hasIntegration = $true
            $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $idPath)
            $testPaths += $rel -replace '\\','/'
        }
    }
    $integrationFiles = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 `
        -Include '*.integration.test.*','*.integration.spec.*' -ErrorAction SilentlyContinue
    if ($integrationFiles) { $hasIntegration = $true }

    # E2E test detection (cross-language)
    $e2eDirs = @('e2e', 'cypress', 'playwright')
    foreach ($ed in $e2eDirs) {
        $edPath = Join-Path -Path $ModulePath -ChildPath $ed
        if (Test-Path $edPath) {
            $hasE2E = $true
            $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $edPath)
            $testPaths += $rel -replace '\\','/'
        }
    }
    $e2eFiles = Get-ChildItem -Path $ModulePath -Recurse -Depth 3 `
        -Include '*.e2e.*' -ErrorAction SilentlyContinue
    if ($e2eFiles) { $hasE2E = $true }

    return [pscustomobject]@{
        Unit        = $hasUnit
        Integration = $hasIntegration
        E2E         = $hasE2E
        Framework   = $framework
        Paths       = @($testPaths | Sort-Object -Unique)
    }
}

# ════════════════════════════════════════════════════════════
# Helper: Discover Bicep files
# ════════════════════════════════════════════════════════════
function Get-BicepInfo {
    param([string]$WorkspacePath)

    $bicepExists = $false
    $bicepPath = $null
    $bicepResources = @()

    # Standard locations (ordered by priority)
    $searchPaths = @(
        (Join-Path -Path $WorkspacePath -ChildPath 'infra/main.bicep'),
        (Join-Path -Path $WorkspacePath -ChildPath 'infra'),
        (Join-Path -Path $WorkspacePath -ChildPath 'deploy'),
        (Join-Path -Path $WorkspacePath -ChildPath 'infrastructure'),
        (Join-Path -Path $WorkspacePath -ChildPath 'azure')
    )

    # Check primary path
    $mainBicep = Join-Path -Path $WorkspacePath -ChildPath 'infra/main.bicep'
    if (Test-Path $mainBicep) {
        $bicepExists = $true
        $bicepPath = 'infra/main.bicep'
    }

    # If not at standard location, search alternatives
    if (-not $bicepExists) {
        foreach ($sp in $searchPaths) {
            if (Test-Path $sp) {
                $files = Get-ChildItem -Path $sp -Filter '*.bicep' -ErrorAction SilentlyContinue
                if ($files) {
                    $bicepExists = $true
                    $bicepPath = [System.IO.Path]::GetRelativePath($WorkspacePath, $files[0].FullName) -replace '\\','/'
                    break
                }
            }
        }
    }

    # Also check workspace root
    if (-not $bicepExists) {
        $rootBicep = Get-ChildItem -Path $WorkspacePath -Filter '*.bicep' -Depth 0 -ErrorAction SilentlyContinue
        if ($rootBicep) {
            $bicepExists = $true
            $bicepPath = $rootBicep[0].Name
        }
    }

    # Parse Bicep to find Azure resource types
    if ($bicepExists -and $bicepPath) {
        $fullPath = Join-Path -Path $WorkspacePath -ChildPath $bicepPath
        $bicepContent = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
        if ($bicepContent) {
            $resourceMatches = [regex]::Matches($bicepContent, "resource\s+\w+\s+'(Microsoft\.[^']+)'")
            $bicepResources = @($resourceMatches | ForEach-Object {
                # Strip API version suffix (e.g. '@2023-12-01') to get just the resource type
                ($_.Groups[1].Value -replace '@.*$', '')
            } | Sort-Object -Unique)
        }
    }

    # Check for bicepparam files
    $hasParams = $false
    if ($bicepExists) {
        $bicepDir = Join-Path -Path $WorkspacePath -ChildPath (Split-Path -Path $bicepPath -Parent)
        if (Test-Path $bicepDir) {
            $paramFiles = Get-ChildItem -Path $bicepDir -Filter '*.bicepparam' -ErrorAction SilentlyContinue
            if ($paramFiles) { $hasParams = $true }
        }
    }

    return [pscustomobject]@{
        Exists       = $bicepExists
        Path         = $bicepPath
        Resources    = $bicepResources
        HasParams    = $hasParams
    }
}

# ════════════════════════════════════════════════════════════
# Helper: Map TargetAzureService to required Bicep resources
# ════════════════════════════════════════════════════════════
function Get-RequiredBicepResources {
    param([string]$TargetService)

    # Core resources: mandatory for the service to function
    # Supporting resources: commonly needed (monitoring, identity, config)
    switch ($TargetService) {
        'Azure App Service' {
            return @{
                core       = @('Microsoft.Web/sites', 'Microsoft.Web/serverfarms')
                supporting = @('Microsoft.Insights/components', 'Microsoft.KeyVault/vaults', 'Microsoft.ManagedIdentity/userAssignedIdentities')
                staging    = @('Microsoft.Web/sites/slots')
            }
        }
        'Azure Functions' {
            return @{
                core       = @('Microsoft.Web/sites', 'Microsoft.Web/serverfarms', 'Microsoft.Storage/storageAccounts')
                supporting = @('Microsoft.Insights/components', 'Microsoft.KeyVault/vaults', 'Microsoft.ManagedIdentity/userAssignedIdentities')
                staging    = @('Microsoft.Web/sites/slots')
            }
        }
        'Azure Container Apps' {
            return @{
                core       = @('Microsoft.App/containerApps', 'Microsoft.App/managedEnvironments')
                supporting = @('Microsoft.ContainerRegistry/registries', 'Microsoft.Insights/components', 'Microsoft.KeyVault/vaults')
                staging    = @()
            }
        }
        'Azure Static Web Apps' {
            return @{
                core       = @('Microsoft.Web/staticSites')
                supporting = @()
                staging    = @()
            }
        }
        default {
            return @{ core = @(); supporting = @(); staging = @() }
        }
    }
}

# ════════════════════════════════════════════════════════════
# Main script
# ════════════════════════════════════════════════════════════

Write-Output ""
Write-Output "================================================================"
Write-Output "  VibeShield-Deploy Workspace Analysis"
Write-Output "================================================================"
Write-Output ""
Write-Output "  Workspace: $WorkspacePath"
Write-Output ""

# ── Phase 1: Source Code Discovery ──────────────────────────
Write-Output "  Phase 1: Source Code Discovery"

# ── SourcePath scoping ──────────────────────────────────────
# When -SourcePath is set, restrict discovery to that subdirectory only.
$scanRoot = $WorkspacePath
$sourceScopeRelPath = $null
if ($SourcePath) {
    $absSource = Join-Path -Path $WorkspacePath -ChildPath $SourcePath
    if (-not (Test-Path $absSource -PathType Container)) {
        Write-Output "  ❌ Specified -SourcePath '$SourcePath' does not exist."
        $global:LASTEXITCODE = 1
        exit 1
    }
    $scanRoot = (Resolve-Path -Path $absSource).Path
    $sourceScopeRelPath = ($SourcePath -replace '\\','/').TrimEnd('/')
    Write-Output "    Scoped to subdirectory: $sourceScopeRelPath"
}

$modules = [System.Collections.ArrayList]::new()

# Helper: find marker files in a directory (non-recursive)
# Uses Where-Object -like (case-insensitive) instead of -Filter (case-sensitive on Linux/macOS)
function Find-MarkerFiles {
    param([string]$Dir)
    $found = @()
    $allFiles = Get-ChildItem -Path $Dir -File -Depth 0 -ErrorAction SilentlyContinue
    foreach ($pattern in $script:MarkerFiles) {
        $matches_ = $allFiles | Where-Object { $_.Name -like $pattern }
        if ($matches_) {
            $found += @($matches_ | ForEach-Object { $_.Name })
        }
    }
    return $found
}

# Helper: check if a path component matches excluded directories
function Test-ExcludedDir {
    param([string]$Path)
    $parts = $Path -split '[/\\]'
    foreach ($part in $parts) {
        if ($part -in $script:ExcludeDirs) {
            return $true
        }
    }
    return $false
}

# Step 1.1: Root-level scan (or scoped directory)
$rootMarkers = @(Find-MarkerFiles -Dir $scanRoot)
if ($rootMarkers.Count -gt 0) {
    $rootRelPath = if ($sourceScopeRelPath) { $sourceScopeRelPath } else { '.' }
    $null = $modules.Add([pscustomobject]@{
        Path        = $rootRelPath
        FullPath    = $scanRoot
        MarkerFiles = $rootMarkers
    })
    Write-Output "    Found root module with markers: $($rootMarkers -join ', ')"
}

# Step 1.2: Recursive subdirectory scan
$allDirs = Get-ChildItem -Path $scanRoot -Directory -Recurse -Depth 5 -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = [System.IO.Path]::GetRelativePath($WorkspacePath, $_.FullName)
        -not (Test-ExcludedDir -Path $rel)
    }

foreach ($dir in $allDirs) {
    $markers = @(Find-MarkerFiles -Dir $dir.FullName)
    if ($markers.Count -gt 0) {
        $relPath = ([System.IO.Path]::GetRelativePath($WorkspacePath, $dir.FullName)) -replace '\\','/'

        # Step 1.3: Deduplication — skip if this is a test project directory
        $dirName = $dir.Name
        $isTestDir = ($dirName -match '\.Tests?$|^tests?$|^__tests__$|^spec$')

        if (-not $isTestDir) {
            $null = $modules.Add([pscustomobject]@{
                Path        = $relPath
                FullPath    = $dir.FullName
                MarkerFiles = $markers
            })
            Write-Output "    Found module at '$relPath' with markers: $($markers -join ', ')"
        }
    }
}

if ($modules.Count -eq 0) {
    Write-Output ""
    Write-Output "  ❌ No deployable modules found in workspace."
    Write-Output ""
    $global:LASTEXITCODE = 1
    exit 1
}

Write-Output "    Total candidate modules: $($modules.Count)"
Write-Output ""

# ── Phase 2: Per-Module App Type Classification ─────────────
Write-Output "  Phase 2: App Type Classification"

$classifiedModules = [System.Collections.ArrayList]::new()

foreach ($mod in $modules) {
    $classification = Get-ModuleAppType -ModulePath $mod.FullPath -Markers $mod.MarkerFiles
    $null = $classifiedModules.Add([pscustomobject]@{
        Path          = $mod.Path
        FullPath      = $mod.FullPath
        MarkerFiles   = $mod.MarkerFiles
        AppType       = $classification.AppType
        TargetService = $classification.TargetService
        Runtime       = $classification.Runtime
    })
    $typeDisplay = $classification.AppType
    if ($classification.Runtime) { $typeDisplay += " ($($classification.Runtime))" }
    Write-Output "    $($mod.Path) → $typeDisplay → $($classification.TargetService)"
}

# ── Phase 2b: Discovery Filter ──────────────────────────
# Remove modules that are not deployable candidates:
# - Unknown app type (no recognized project structure)
# - Path contains backup/recovery indicators (underscore-prefixed dirs like _recovered)
$preBuildCount = $classifiedModules.Count
$classifiedModules = [System.Collections.ArrayList]::new(
    @($classifiedModules | Where-Object {
        $dominated = $false
        # Filter: unknown app type
        if ($_.AppType -eq 'Unknown') {
            Write-Output "    Excluding '$($_.Path)' — unknown app type (not buildable)"
            $dominated = $true
        }
        # Filter: path contains underscore-prefixed segment (backup/recovery convention)
        elseif ($_.Path -match '(^|[/\\])_[^/\\]+') {
            Write-Output "    Excluding '$($_.Path)' — path contains underscore-prefixed directory (likely backup/recovered)"
            $dominated = $true
        }
        -not $dominated
    })
)
if ($classifiedModules.Count -lt $preBuildCount) {
    Write-Output "    Filtered: $preBuildCount → $($classifiedModules.Count) deployable modules"
}

Write-Output ""

# ── Phase 2c: Scaffolding Completeness (ex PF-01b) ─────────
Write-Output "  Phase 2c: Scaffolding Completeness"

foreach ($mod in $classifiedModules) {
    $warnings = [System.Collections.ArrayList]::new()
    $mp = $mod.FullPath
    $effectiveType = $mod.AppType
    if ($effectiveType -in @('F#', 'VB.NET')) { $effectiveType = '.NET' }

    switch ($effectiveType) {
        '.NET' {
            # Lock file: packages.lock.json or NuGet.config
            $hasLock = (Test-Path (Join-Path -Path $mp -ChildPath 'packages.lock.json')) -or
                       (Test-Path (Join-Path -Path $mp -ChildPath 'NuGet.config')) -or
                       (Test-Path (Join-Path -Path $mp -ChildPath 'nuget.config'))
            if (-not $hasLock) {
                $null = $warnings.Add('Missing lock file (packages.lock.json) or NuGet.config — restore may be non-deterministic')
            }
            # Multi-project: check for .sln
            $csprojCount = @(Get-ChildItem -Path $mp -Filter '*.csproj' -ErrorAction SilentlyContinue).Count +
                           @(Get-ChildItem -Path $mp -Filter '*.fsproj' -ErrorAction SilentlyContinue).Count +
                           @(Get-ChildItem -Path $mp -Filter '*.vbproj' -ErrorAction SilentlyContinue).Count
            if ($csprojCount -gt 1 -and -not (Test-Path (Join-Path -Path $mp -ChildPath '*.sln'))) {
                $slnFiles = Get-ChildItem -Path $mp -Filter '*.sln' -ErrorAction SilentlyContinue
                if (-not $slnFiles) {
                    $null = $warnings.Add("Multiple project files ($csprojCount) but no .sln solution file — build may fail")
                }
            }
        }
        'Node.js backend' {
            $hasLock = (Test-Path (Join-Path -Path $mp -ChildPath 'package-lock.json')) -or
                       (Test-Path (Join-Path -Path $mp -ChildPath 'yarn.lock')) -or
                       (Test-Path (Join-Path -Path $mp -ChildPath 'pnpm-lock.yaml'))
            if (-not $hasLock) {
                $null = $warnings.Add('Missing lock file (package-lock.json / yarn.lock / pnpm-lock.yaml) — install may be non-deterministic')
            }
        }
        'Python' {
            $hasLock = (Test-Path (Join-Path -Path $mp -ChildPath 'requirements.txt')) -or
                       (Test-Path (Join-Path -Path $mp -ChildPath 'poetry.lock')) -or
                       (Test-Path (Join-Path -Path $mp -ChildPath 'Pipfile.lock'))
            if (-not $hasLock) {
                $null = $warnings.Add('Missing dependency file (requirements.txt / poetry.lock / Pipfile.lock)')
            }
        }
        'Go' {
            if (-not (Test-Path (Join-Path -Path $mp -ChildPath 'go.sum'))) {
                $null = $warnings.Add('Missing go.sum — run "go mod tidy" to generate')
            }
        }
        'Rust' {
            if (-not (Test-Path (Join-Path -Path $mp -ChildPath 'Cargo.lock'))) {
                $null = $warnings.Add('Missing Cargo.lock — run "cargo build" to generate')
            }
        }
        'Java' {
            $hasWrapper = (Test-Path (Join-Path -Path $mp -ChildPath 'mvnw')) -or
                          (Test-Path (Join-Path -Path $mp -ChildPath 'gradlew'))
            if (-not $hasWrapper) {
                $null = $warnings.Add('Missing build wrapper (mvnw / gradlew) — pipeline may need explicit tool install')
            }
        }
    }

    if ($warnings.Count -gt 0) {
        Write-Output "    ⚠ $($mod.Path): $($warnings.Count) warning(s)"
        foreach ($w in $warnings) { Write-Output "      - $w" }
    } else {
        Write-Output "    ✅ $($mod.Path): scaffolding complete"
    }

    # Attach scaffolding warnings to module for manifest output
    $mod | Add-Member -NotePropertyName ScaffoldingWarnings -NotePropertyValue @($warnings) -Force
}

Write-Output ""

# ── Phase 3: Test Suite Inventory ───────────────────────────
Write-Output "  Phase 3: Test Suite Inventory"

foreach ($mod in $classifiedModules) {
    $effectiveAppType = if ($mod.AppType -eq 'Functions' -and $mod.Runtime) { $mod.Runtime } else { $mod.AppType }
    $tests = Get-ModuleTests -ModulePath $mod.FullPath -AppType $effectiveAppType
    $mod | Add-Member -NotePropertyName 'Tests' -NotePropertyValue $tests -Force

    $unitIcon   = if ($tests.Unit)        { '✅' } else { '❌' }
    $intIcon    = if ($tests.Integration) { '✅' } else { '❌' }
    $e2eIcon    = if ($tests.E2E)         { '✅' } else { '❌' }
    $fwDisplay  = if ($tests.Framework)   { " ($($tests.Framework))" } else { '' }
    Write-Output "    $($mod.Path): Unit $unitIcon  Integration $intIcon  E2E $e2eIcon$fwDisplay"
}

Write-Output ""

# ── Phase 3b: Node.js App Requirements (IL-1) ─────────────
Write-Output "  Phase 3b: Node.js App Requirements"
foreach ($mod in $classifiedModules) {
    if ($mod.AppType -in @('Node.js backend', 'Static frontend')) {
        if (Get-Command Get-NodeAppRequirements -ErrorAction SilentlyContinue) {
            $nodeReqs = Get-NodeAppRequirements -ModulePath $mod.FullPath -WorkspacePath $WorkspacePath
            $mod | Add-Member -NotePropertyName 'NodeRequirements' -NotePropertyValue $nodeReqs -Force
            $envCount = $nodeReqs.RequiredEnvVars.Count
            $sdkCount = $nodeReqs.EagerSdkInits.Count
            Write-Output "    $($mod.Path): entry=$($nodeReqs.EntryPoint ?? 'unknown') envVars=$envCount eagerSdks=$sdkCount archive=$($nodeReqs.ArchiveRoot ?? 'root')"
        }
    }
}

Write-Output ""

# ── Phase 4: Existing Bicep Discovery ──────────────────────
Write-Output "  Phase 4: Bicep Discovery"

$bicepInfo = Get-BicepInfo -WorkspacePath $WorkspacePath

if ($bicepInfo.Exists) {
    Write-Output "    Bicep found at: $($bicepInfo.Path)"
    if ($bicepInfo.Resources.Count -gt 0) {
        Write-Output "    Resources: $($bicepInfo.Resources -join ', ')"
    }
    if ($bicepInfo.HasParams) {
        Write-Output "    Parameter file(s) found"
    }
} else {
    Write-Output "    No Bicep files found"
}

# Gap analysis + infrastructure requirements per module
$bicepGaps = @()
$coversAll = $true
foreach ($mod in $classifiedModules) {
    $resMap = Get-RequiredBicepResources -TargetService $mod.TargetService
    $required = @($resMap.core)

    # IP-1: Attach infrastructure requirements to each module
    $mod | Add-Member -NotePropertyName 'RequiresInfrastructure' -NotePropertyValue ($required.Count -gt 0) -Force
    $mod | Add-Member -NotePropertyName 'RequiredResources' -NotePropertyValue ([ordered]@{
        core       = @($resMap.core)
        supporting = @($resMap.supporting)
        staging    = @($resMap.staging)
    }) -Force

    if ($required.Count -eq 0) { continue }

    $covered = $true
    foreach ($res in $required) {
        if ($res -notin $bicepInfo.Resources) {
            $covered = $false
            break
        }
    }
    if (-not $covered) {
        $coversAll = $false
        $bicepGaps += $mod.Path
    }
}

if ($bicepInfo.Exists) {
    if ($coversAll) {
        Write-Output "    Coverage: All modules covered ✅"
    } else {
        Write-Output "    Coverage: Gaps detected for: $($bicepGaps -join ', ') ⚠️"
    }
}

Write-Output ""

# ── Phase 5: Pipeline Stage Coverage ──────────────────────
Write-Output "  Phase 5: Pipeline Stage Coverage"

$fullPipelinePath = Join-Path -Path $WorkspacePath -ChildPath $PipelineYmlPath
$pipelineExists = Test-Path $fullPipelinePath

if ($pipelineExists) {
    $pipelineContent = Get-Content $fullPipelinePath -Raw -ErrorAction SilentlyContinue
    if ($pipelineContent) {
        # Strip comments for pattern matching
        $pipelineClean = ($pipelineContent -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    } else {
        $pipelineClean = ''
    }
} else {
    Write-Output "    Pipeline YAML not found — skipping stage coverage check"
    $pipelineClean = $null
}

foreach ($mod in $classifiedModules) {
    $hasBuild  = $false
    $hasDeploy = $false

    if ($pipelineClean) {
        if ($mod.Path -eq '.') {
            # Primary module — look for standard Build/Deploy stages
            $hasBuild  = $pipelineClean -match '(?mi)^\s*-\s*stage:\s*Build\b'
            $hasDeploy = $pipelineClean -match '(?mi)^\s*-\s*stage:\s*Deploy\b'
        } else {
            # Secondary module — look for named stages (e.g., Build_Functions, Deploy_Functions)
            $safeName = ($mod.Path -split '[/\\]' | Select-Object -Last 1) -replace '[^a-zA-Z0-9]','_'
            $hasBuild  = $pipelineClean -match "(?mi)^\s*-\s*stage:\s*Build_${safeName}\b"
            $hasDeploy = $pipelineClean -match "(?mi)^\s*-\s*stage:\s*Deploy_${safeName}\b"
            # Also check for workingDirectory pointing to this module's path
            if (-not $hasBuild) {
                $hasBuild = $pipelineClean -match "workingDirectory:\s*['""]?$([regex]::Escape($mod.Path))"
            }
        }
    }

    $mod | Add-Member -NotePropertyName 'HasBuildStage'  -NotePropertyValue $hasBuild  -Force
    $mod | Add-Member -NotePropertyName 'HasDeployStage' -NotePropertyValue $hasDeploy -Force

    if ($pipelineClean) {
        $bIcon = if ($hasBuild)  { '✅' } else { '❌' }
        $dIcon = if ($hasDeploy) { '✅' } else { '❌' }
        Write-Output "    $($mod.Path): Build $bIcon  Deploy $dIcon"
    }
}

Write-Output ""

# ════════════════════════════════════════════════════════════
# Build output manifest
# ════════════════════════════════════════════════════════════

# Identify primary module (first module, at root '.')
$null = $classifiedModules | Where-Object { $_.Path -eq '.' } | Select-Object -First 1
$secondaryModules = @($classifiedModules | Where-Object { $_.Path -ne '.' })

# Build modules JSON array
$modulesJson = @($classifiedModules | ForEach-Object {
    # Generate a brief human-readable description
    $modName = if ($_.Path -eq '.') { 'Root project' } else { Split-Path -Path $_.Path -Leaf }
    $desc = "$modName — $($_.AppType)"
    if ($_.Runtime) { $desc += " ($($_.Runtime))" }
    $desc += " targeting $($_.TargetService)"
    if ($_.Tests.Unit -gt 0 -or $_.Tests.Integration -gt 0) {
        $testParts = @()
        if ($_.Tests.Unit -gt 0)        { $testParts += "$($_.Tests.Unit) unit" }
        if ($_.Tests.Integration -gt 0) { $testParts += "$($_.Tests.Integration) integration" }
        $desc += " with $($testParts -join ', ') tests"
    }

    [ordered]@{
        path              = $_.Path
        description       = $desc
        appType           = $_.AppType
        targetAzureService = $_.TargetService
        requiresInfrastructure = $_.RequiresInfrastructure
        requiredResources = $_.RequiredResources
        markerFiles       = @($_.MarkerFiles)
        scaffoldingWarnings = @($_.ScaffoldingWarnings)
        tests             = [ordered]@{
            unit        = $_.Tests.Unit
            integration = $_.Tests.Integration
            e2e         = $_.Tests.E2E
            framework   = $_.Tests.Framework
            paths       = @($_.Tests.Paths)
        }
        pipelineStages    = [ordered]@{
            build  = $_.HasBuildStage
            deploy = $_.HasDeployStage
        }
        nodeRequirements  = if ($_.PSObject.Properties['NodeRequirements'] -and $_.NodeRequirements) {
            [ordered]@{
                entryPoint       = $_.NodeRequirements.EntryPoint
                startupCommand   = $_.NodeRequirements.StartupCommand
                requiredEnvVars  = @($_.NodeRequirements.RequiredEnvVars)
                eagerSdkInits    = @($_.NodeRequirements.EagerSdkInits)
                archiveRoot      = $_.NodeRequirements.ArchiveRoot
                usesWorkspaces   = $_.NodeRequirements.UsesWorkspaces
                writesFilesystem = @($_.NodeRequirements.WritesFilesystem)
                corsOrigins      = @($_.NodeRequirements.CorsOrigins)
                needsSCMBuildOff = $_.NodeRequirements.NeedsSCMBuildOff
            }
        } else { $null }
    }
})

# Build components array (secondary modules only, for pipeline-author handoff)
$componentsJson = @($secondaryModules | ForEach-Object {
    [ordered]@{
        AppType            = $_.AppType
        TargetAzureService = $_.TargetService
        ComponentPath      = $_.Path
    }
})

$manifest = [ordered]@{
    sourcePath = $sourceScopeRelPath  # null if full workspace, otherwise the scoped subdirectory
    modules    = $modulesJson
    bicep      = [ordered]@{
        exists           = $bicepInfo.Exists
        path             = $bicepInfo.Path
        coversAllModules = $coversAll
        gaps             = @($bicepGaps)
    }
    components = $componentsJson
}

$manifestJson = $manifest | ConvertTo-Json -Depth 10
Set-Content -Path $OutputPath -Value $manifestJson -Encoding UTF8

# ════════════════════════════════════════════════════════════
# Terminal Summary
# ════════════════════════════════════════════════════════════

Write-Output "================================================================"
Write-Output "  Workspace Analysis Summary"
Write-Output "  Modules: $($classifiedModules.Count)  |  Bicep: $(if ($bicepInfo.Exists) { 'Found' } else { 'None' })  |  Gaps: $($bicepGaps.Count)"
Write-Output "================================================================"

$missingStages = @($classifiedModules | Where-Object { -not $_.HasBuildStage -or -not $_.HasDeployStage })
if ($missingStages.Count -gt 0 -and $pipelineClean) {
    Write-Output ""
    Write-Output "  MISSING PIPELINE STAGES ($($missingStages.Count) module(s)):"
    foreach ($ms in $missingStages) {
        $missing = @()
        if (-not $ms.HasBuildStage)  { $missing += 'Build' }
        if (-not $ms.HasDeployStage) { $missing += 'Deploy' }
        Write-Output "    $($ms.Path) ($($ms.AppType)): Missing $($missing -join ', ')"
    }
}

Write-Output ""
Write-Output "  Manifest: $OutputPath"
Write-Output ""

$global:LASTEXITCODE = 0
exit 0