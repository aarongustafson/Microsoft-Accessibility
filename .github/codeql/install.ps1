# CodeQL Vibe -- Complete Bootstrapper
# Handles: file validation, CodeQL CLI, SARIF Viewer, .gitignore, hooks, profile, validation
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File ".github/codeql/install.ps1"

$ErrorActionPreference = 'Continue'

$startTime = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "Installation started at $($startTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))" -ForegroundColor Cyan

# Auto-detect paths from this script's location (works from .github/codeql/ or .codeql/)
$codeqlDir = $PSScriptRoot
if (-not $codeqlDir) {
    # Fallback: $PSScriptRoot can be empty when invoked through git's MINGW bash layer
    $codeqlDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue)
    if (-not $codeqlDir) { $codeqlDir = (Get-Location).Path }
}
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if ($repoRoot) { $repoRoot = (Resolve-Path $repoRoot -ErrorAction SilentlyContinue).Path }
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
$codeqlRelPath = ($codeqlDir.Substring($repoRoot.Length).TrimStart([char]'\', [char]'/') -replace '\\', '/')
$gitHooksDir = Join-Path (Join-Path $repoRoot ".git") "hooks"

$installState = [ordered]@{
    'File validation'   = 'not-started'
    'CodeQL CLI'        = 'not-started'
    'SARIF Viewer'      = 'not-started'
    '.gitignore'        = 'not-started'
    'Hooks + profile'   = 'not-started'
    'Validation'        = 'not-started'
}

try {
    # ========================================================================
    #  Step 0: File validation
    # ========================================================================

    $installState['File validation'] = 'running'
    $allPassed = $true

    # Validate all .ps1 files EXCEPT install.ps1 itself
    Get-ChildItem "$codeqlDir/*.ps1" | Where-Object { $_.Name -ne 'install.ps1' } | ForEach-Object {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $_.FullName, [ref]$null, [ref]$errors
        )
        if ($errors.Count -gt 0) {
            $allPassed = $false
            Write-Host "[FAIL] Syntax errors in $($_.Name):" -ForegroundColor Red
            $errors | ForEach-Object { Write-Host "  Line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
        } else {
            Write-Host "[PASS] $($_.Name) syntax OK" -ForegroundColor Green
        }
        # Encoding validation
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $nonAsciiCount = 0
        foreach ($b in $bytes) { if ($b -gt 127) { $nonAsciiCount++ } }
        if ($nonAsciiCount -gt 0) {
            # Auto-fix: re-encode as ASCII
            $content = Get-Content $_.FullName -Raw
            $asciiBytes = [System.Text.Encoding]::ASCII.GetBytes($content)
            [System.IO.File]::WriteAllBytes($_.FullName, $asciiBytes)
            # Re-check
            $bytes2 = [System.IO.File]::ReadAllBytes($_.FullName)
            $still = 0
            foreach ($b in $bytes2) { if ($b -gt 127) { $still++ } }
            if ($still -gt 0) {
                $allPassed = $false
                Write-Host "[FAIL] $($_.Name) contains $still non-ASCII bytes after auto-fix" -ForegroundColor Red
            } else {
                Write-Host "[PASS] $($_.Name) encoding fixed (re-encoded as ASCII)" -ForegroundColor Green
            }
        } else {
            Write-Host "[PASS] $($_.Name) encoding OK (ASCII)" -ForegroundColor Green
        }
    }

    # Validate codeql-config.yml
    if (Test-Path "$codeqlDir/codeql-config.yml") {
        $configContent = Get-Content "$codeqlDir/codeql-config.yml" -Raw
        if (-not $configContent -or $configContent.Trim().Length -eq 0) {
            $allPassed = $false
            Write-Host "[FAIL] codeql-config.yml is empty" -ForegroundColor Red
        } elseif ($configContent -notmatch '(?m)^name:') {
            $allPassed = $false
            Write-Host "[FAIL] codeql-config.yml does not start with 'name:'" -ForegroundColor Red
        } elseif ($configContent -notmatch 'paths-ignore:') {
            $allPassed = $false
            Write-Host "[FAIL] codeql-config.yml missing 'paths-ignore:' section" -ForegroundColor Red
        } else {
            Write-Host "[PASS] codeql-config.yml structure OK" -ForegroundColor Green
        }
        # Check for queries: section (should not exist)
        if ($configContent -match '(?m)^queries:') {
            Write-Host "[WARN] codeql-config.yml contains a 'queries:' section -- removing (causes CLI failures)" -ForegroundColor Yellow
            $configContent = $configContent -replace '(?ms)^queries:.*?(?=^[a-z]|\z)', ''
            Set-Content "$codeqlDir/codeql-config.yml" $configContent.TrimEnd() -Encoding UTF8
            Write-Host "[PASS] Removed 'queries:' section from codeql-config.yml" -ForegroundColor Green
        }
    } else {
        $allPassed = $false
        Write-Host "[FAIL] codeql-config.yml not found" -ForegroundColor Red
    }

    # Validate pre-commit hook
    if (Test-Path "$codeqlDir/hooks/pre-commit") {
        $hookContent = Get-Content "$codeqlDir/hooks/pre-commit" -Raw
        if ($hookContent -notmatch '#!/bin/sh') {
            $allPassed = $false
            Write-Host "[FAIL] $codeqlRelPath/hooks/pre-commit missing #!/bin/sh shebang" -ForegroundColor Red
        } elseif ($hookContent -notmatch 'scan\.ps1') {
            $allPassed = $false
            Write-Host "[FAIL] $codeqlRelPath/hooks/pre-commit does not invoke scan.ps1" -ForegroundColor Red
        } else {
            Write-Host "[PASS] $codeqlRelPath/hooks/pre-commit structure OK" -ForegroundColor Green
        }
    } else {
        $allPassed = $false
        Write-Host "[FAIL] $codeqlRelPath/hooks/pre-commit not found" -ForegroundColor Red
    }

    if (-not $allPassed) {
        $installState['File validation'] = 'failed'
        Write-Host "[FAIL] File validation failed. Fix errors above and re-run install.ps1" -ForegroundColor Red
        exit 1
    }
    $installState['File validation'] = 'done'
    Write-Host "[PASS] All file validations passed" -ForegroundColor Green

    # ========================================================================
    #  Step 0b: Augment codeql-config.yml with tech-stack-specific exclusions
    # ========================================================================
    # The default template covers 95% of projects. This step detects additional
    # directories that should be excluded (e.g., .gradle/ for Gradle, Pods/ for
    # CocoaPods) and appends them if not already present.

    if (Test-Path "$codeqlDir/codeql-config.yml") {
        $configLines = Get-Content "$codeqlDir/codeql-config.yml"
        $configText = $configLines -join "`n"
        $extras = @()

        # Detect tech-stack-specific directories to exclude
        if ((Test-Path 'build.gradle') -or (Test-Path 'build.gradle.kts')) {
            if ($configText -notmatch '\.gradle') { $extras += '  - .gradle'; $extras += "  - '**/.gradle/**'" }
        }
        if (Test-Path 'Podfile') {
            if ($configText -notmatch 'Pods') { $extras += '  - Pods'; $extras += "  - '**/Pods/**'" }
        }
        if (Test-Path 'Cargo.toml') {
            if ($configText -notmatch 'target/debug') { $extras += "  - 'target/debug'"; $extras += "  - 'target/release'" }
        }
        if (Test-Path 'Package.swift') {
            if ($configText -notmatch '\.build') { $extras += '  - .build' }
        }
        if (Test-Path 'CMakeLists.txt') {
            if ($configText -notmatch 'cmake-build') { $extras += "  - '**/cmake-build-*'" }
        }
        if ((Test-Path 'mix.exs') -or (Test-Path 'rebar.config')) {
            if ($configText -notmatch '_build') { $extras += '  - _build'; $extras += '  - deps' }
        }

        # Scan for additional top-level non-source directories not already excluded
        $knownDirs = @('node_modules', '.python_packages', 'vendor', 'packages', 'bower_components',
                       'dist', 'build', 'out', 'bin', 'obj', 'target', '__pycache__', '_build', '.next', '.nuget',
                       '.speckit', '.codeql-db', '.codeql', '.github', '.vscode', '.azure', '.devcontainer',
                       'azure-pipelines', 'docs', 'scripts', 'tools', '.git', '.gradle', 'Pods', '.build')
        Get-ChildItem -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notin $knownDirs -and $_.Name.StartsWith('.')
        } | ForEach-Object {
            # Hidden directories (e.g., .terraform, .serverless) are usually not source
            if ($configText -notmatch [regex]::Escape($_.Name)) {
                $extras += "  - $($_.Name)"
            }
        }

        if ($extras.Count -gt 0) {
            $extraBlock = "  # Tech-stack-specific exclusions (auto-detected by install.ps1)"
            Add-Content "$codeqlDir/codeql-config.yml" $extraBlock -Encoding UTF8
            foreach ($line in $extras) {
                Add-Content "$codeqlDir/codeql-config.yml" $line -Encoding UTF8
            }
            Write-Host "[AUTO] Added $($extras.Count) tech-stack exclusions to codeql-config.yml" -ForegroundColor Cyan
        } else {
            Write-Host "[PASS] codeql-config.yml -- no additional exclusions needed" -ForegroundColor Green
        }
    }

    # ========================================================================
    #  Step 1: CodeQL CLI
    # ========================================================================

    $installState['CodeQL CLI'] = 'running'

    $codeqlCmd = Get-Command codeql -ErrorAction SilentlyContinue
    $needsInstall = $true
    $currentVersion = $null

    if ($codeqlCmd) {
        $versionOutput = & codeql version 2>$null | Out-String
        if ($versionOutput -match '(\d+\.\d+\.\d+)') {
            $currentVersion = [version]$Matches[1]
            Write-Host "Found CodeQL CLI v$currentVersion at $($codeqlCmd.Source)" -ForegroundColor Cyan
        }
    }

    # Check for latest release
    $latestVersion = $null
    $latestAsset = $null
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/github/codeql-cli-binaries/releases/latest" -ErrorAction Stop
        if ($release.tag_name -match '(\d+\.\d+\.\d+)') {
            $latestVersion = [version]$Matches[1]
        }
        # Determine platform asset
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $latestAsset = $release.assets | Where-Object { $_.name -match 'codeql-win64\.zip$' } | Select-Object -First 1
        } elseif ($IsMacOS) {
            $latestAsset = $release.assets | Where-Object { $_.name -match 'codeql-osx64\.zip$' } | Select-Object -First 1
        } else {
            $latestAsset = $release.assets | Where-Object { $_.name -match 'codeql-linux64\.zip$' } | Select-Object -First 1
        }
    } catch {
        Write-Host "[WARN] Could not query GitHub for latest CodeQL release: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($currentVersion -and $latestVersion) {
        if ($currentVersion -ge $latestVersion) {
            Write-Host "[PASS] CodeQL CLI already current (v$currentVersion)" -ForegroundColor Green
            $needsInstall = $false
        } else {
            Write-Host "[AUTO] Upgrading CodeQL CLI from v$currentVersion to v$latestVersion" -ForegroundColor Cyan
        }
    } elseif ($currentVersion -and -not $latestVersion) {
        Write-Host "[WARN] Could not check for a newer CodeQL release -- continuing with installed v$currentVersion" -ForegroundColor Yellow
        $needsInstall = $false
    } elseif (-not $currentVersion -and -not $latestVersion) {
        Write-Host "[FAIL] CodeQL CLI not found and cannot download (no network access)." -ForegroundColor Red
        Write-Host "  Download manually: https://github.com/github/codeql-cli-binaries/releases/latest" -ForegroundColor Yellow
        $installState['CodeQL CLI'] = 'failed'
        exit 1
    }

    if ($needsInstall -and $latestAsset) {
        $downloadUrl = $latestAsset.browser_download_url
        # Validate download URL domain
        if ($downloadUrl -notmatch '^https://(github\.com|objects\.githubusercontent\.com)/') {
            Write-Host "[FAIL] Unexpected download URL domain: $downloadUrl" -ForegroundColor Red
            Write-Host "Expected github.com or objects.githubusercontent.com. Aborting for safety." -ForegroundColor Red
            $installState['CodeQL CLI'] = 'failed'
            exit 1
        }

        $sizeMB = [math]::Round($latestAsset.size / 1MB)
        Write-Host "Downloading CodeQL CLI ($sizeMB MB)..." -ForegroundColor Cyan

        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $zipPath = Join-Path $env:TEMP "codeql.zip"
            $wc = New-Object System.Net.WebClient
            try { $wc.DownloadFile($downloadUrl, $zipPath) } finally { $wc.Dispose() }
            $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
            Write-Host "Download complete. SHA-256: $hash" -ForegroundColor Cyan
            Write-Host "Extracting..." -ForegroundColor Cyan
            $parentDir = "$env:LOCALAPPDATA\CodeQL"
            $codeqlDir = Join-Path $parentDir "codeql"
            if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
            if (-not (Test-Path $codeqlDir)) {
                # Fresh install -- extract directly
                if (Get-Command tar -ErrorAction SilentlyContinue) {
                    tar -xf $zipPath -C $parentDir
                } else {
                    Expand-Archive -Path $zipPath -DestinationPath $parentDir -Force
                }
            } else {
                # Upgrade -- extract to temp, then swap
                $tempParent = Join-Path $env:TEMP "codeql_extract_$(Get-Date -Format 'yyyyMMddHHmmss')"
                New-Item -ItemType Directory -Path $tempParent -Force | Out-Null
                if (Get-Command tar -ErrorAction SilentlyContinue) {
                    tar -xf $zipPath -C $tempParent
                } else {
                    Expand-Archive -Path $zipPath -DestinationPath $tempParent -Force
                }
                $extractedDir = Join-Path $tempParent "codeql"
                # Kill CodeQL processes locking the old directory
                Get-Process -ErrorAction SilentlyContinue | Where-Object {
                    $_.Path -and $_.Path.StartsWith($codeqlDir, [System.StringComparison]::OrdinalIgnoreCase)
                } | ForEach-Object {
                    Write-Host "[AUTO] Stopping $($_.Name) (PID $($_.Id))" -ForegroundColor Yellow
                    $_ | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Seconds 2
                # Try to remove old directory
                Remove-Item $codeqlDir -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $codeqlDir)) {
                    # Old dir removed -- move new into place
                    Move-Item $extractedDir $codeqlDir -Force
                } else {
                    # Old dir still locked -- use new dir directly
                    $codeqlDir = Join-Path $parentDir "codeql_$(($latestVersion -replace '\.','_'))"
                    if (Test-Path $codeqlDir) { Remove-Item $codeqlDir -Recurse -Force -ErrorAction SilentlyContinue }
                    Move-Item $extractedDir $codeqlDir -Force
                    Write-Host "[AUTO] Old CodeQL locked -- installed new version at $codeqlDir" -ForegroundColor Yellow
                }
                Remove-Item $tempParent -Recurse -Force -ErrorAction SilentlyContinue
            }
            $codeqlBin = $codeqlDir
            $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
            # Remove any old CodeQL paths and add the current one
            $cleanedPath = ($currentPath -split ';' | Where-Object { $_ -notmatch '\\CodeQL\\' }) -join ';'
            [Environment]::SetEnvironmentVariable("Path", "$codeqlBin;$cleanedPath", "User")
            $env:Path = "$codeqlBin;$env:Path"
            Remove-Item $zipPath -ErrorAction SilentlyContinue
        } else {
            # macOS / Linux
            $zipPath = "/tmp/codeql.zip"
            & curl -sL -o $zipPath $downloadUrl
            Write-Host "Download complete. Extracting..." -ForegroundColor Cyan
            $destDir = Join-Path $HOME ".local/share"
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            & unzip -o $zipPath -d $destDir 2>$null
            $codeqlBin = Join-Path $destDir "codeql"
            if ($env:PATH -notlike "*$codeqlBin*") {
                $env:PATH = "${codeqlBin};$env:PATH"
            }
            # Add to shell profiles
            $pathLine = "export PATH=`"${codeqlBin}:`$PATH`""
            foreach ($rc in @("$HOME/.bashrc", "$HOME/.zshrc")) {
                if (Test-Path $rc) {
                    $rcContent = Get-Content $rc -Raw
                    if ($rcContent -notmatch [regex]::Escape($codeqlBin)) {
                        Add-Content $rc $pathLine
                    }
                }
            }
            Remove-Item $zipPath -ErrorAction SilentlyContinue
        }

        # Verify installation
        $newCmd = Get-Command codeql -ErrorAction SilentlyContinue
        if ($newCmd) {
            $verOut = & codeql version 2>$null | Out-String
            if ($verOut -match '(\d+\.\d+\.\d+)') {
                Write-Host "[PASS] CodeQL CLI v$($Matches[1]) installed at $($newCmd.Source)" -ForegroundColor Green
            } else {
                Write-Host "[PASS] CodeQL CLI installed at $($newCmd.Source)" -ForegroundColor Green
            }
        } else {
            Write-Host "[FAIL] CodeQL CLI installation failed -- not found on PATH" -ForegroundColor Red
            Write-Host "  Download manually: https://github.com/github/codeql-cli-binaries/releases/latest" -ForegroundColor Yellow
            $installState['CodeQL CLI'] = 'failed'
            exit 1
        }

        # Stale session detection (Windows)
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $managedCodeql = Join-Path $env:LOCALAPPDATA 'CodeQL\codeql\codeql.exe'
            $activeCodeql = (Get-Command codeql -ErrorAction SilentlyContinue).Source
            if ($managedCodeql -and $activeCodeql -and (Test-Path $managedCodeql) -and ($activeCodeql -ne $managedCodeql)) {
                $activeVerText = (& $activeCodeql version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1)
                $managedVerText = (& $managedCodeql version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1)
                if ($activeVerText -and $managedVerText) {
                    $activeMatch = [regex]::Match($activeVerText.ToString(), '(\d+\.\d+\.\d+)')
                    $managedMatch = [regex]::Match($managedVerText.ToString(), '(\d+\.\d+\.\d+)')
                    if ($activeMatch.Success -and $managedMatch.Success) {
                        $activeVer = [version]$activeMatch.Groups[1].Value
                        $managedVer = [version]$managedMatch.Groups[1].Value
                        if ($managedVer -gt $activeVer) {
                            Write-Host "[WARN] CodeQL Vibe installed v$managedVer at $managedCodeql, but this session resolves older v$activeVer." -ForegroundColor Yellow
                            Write-Host "  Restart VS Code, open a new terminal, run 'codeql version', then retry." -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    }

    # Quick smoke test
    $qlpackOut = codeql resolve qlpacks 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] 'codeql resolve qlpacks' failed -- CLI may not be fully functional" -ForegroundColor Yellow
    }

    # Download standard query packs (required for codeql database analyze)
    # The CLI binary includes extractors but NOT query packs with .qls suite files.
    # Without this step, the first scan fails with "missing suite file" errors.
    $queryPacks = @(
        'codeql/javascript-queries',
        'codeql/python-queries',
        'codeql/csharp-queries',
        'codeql/java-queries',
        'codeql/cpp-queries',
        'codeql/go-queries',
        'codeql/ruby-queries',
        'codeql/swift-queries'
    )

    # Check which packs are already installed to avoid redundant downloads
    $packCacheDir = Join-Path $env:USERPROFILE '.codeql\packages\codeql'
    $missingPacks = @()
    foreach ($pack in $queryPacks) {
        $packLeaf = ($pack -split '/')[1]  # e.g. 'javascript-queries'
        $packDir = Join-Path $packCacheDir $packLeaf
        if (-not (Test-Path $packDir)) {
            $missingPacks += $pack
        }
    }

    if ($missingPacks.Count -eq 0) {
        Write-Host "[PASS] CodeQL query packs already installed ($($queryPacks.Count) packs)" -ForegroundColor Green
    } else {
        Write-Host "Downloading $($missingPacks.Count) missing CodeQL query pack(s)..." -ForegroundColor Cyan
        foreach ($pack in $missingPacks) {
            & codeql pack download $pack 2>$null
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[PASS] CodeQL query packs downloaded" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Some query packs may not have downloaded -- first scan will download them on demand" -ForegroundColor Yellow
        }
    }

    $installState['CodeQL CLI'] = 'done'

    # ========================================================================
    #  Step 2a-2c: Parallel batch (SARIF Viewer, .gitignore, Hooks + profile)
    # ========================================================================

    $scriptRoot = $PSScriptRoot
    $profilePath = $PROFILE
    if (-not $profilePath) {
        $profilePath = Join-Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell') 'Microsoft.PowerShell_profile.ps1'
    }

    $canParallelize = $true
    try { $testJob = Start-Job -ScriptBlock { 1 }; $testJob | Wait-Job | Out-Null; $testJob | Remove-Job -Force } catch { $canParallelize = $false }

    if ($canParallelize) {
        $jobs = @()

        # 2a. SARIF Viewer
        $jobs += Start-Job -Name "codeql-sarif" -ScriptBlock {
            $codeCmd = Get-Command code -ErrorAction SilentlyContinue
            if (-not $codeCmd) {
                # Try platform-specific paths
                if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                    $codePath = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
                    if (Test-Path $codePath) { $codeCmd = $codePath }
                }
            }
            if ($codeCmd) {
                $codeBin = if ($codeCmd -is [string]) { $codeCmd } else { $codeCmd.Source }
                & $codeBin --install-extension "MS-SarifVSCode.sarif-viewer" --force 2>&1 | Out-Null
                Write-Output "[PASS] SARIF Viewer extension installed"
            } else {
                Write-Output "[INFO] SARIF Viewer skipped -- install manually from VS Code marketplace"
            }

            # Ensure .vscode/extensions.json has the recommendation
            Set-Location $using:repoRoot
            $extJsonPath = '.vscode/extensions.json'
            if (-not (Test-Path '.vscode')) { New-Item -ItemType Directory -Path '.vscode' -Force | Out-Null }
            if (Test-Path $extJsonPath) {
                $extJson = Get-Content $extJsonPath -Raw | ConvertFrom-Json
                if (-not $extJson.recommendations) {
                    $extJson | Add-Member -NotePropertyName 'recommendations' -NotePropertyValue @('MS-SarifVSCode.sarif-viewer')
                } elseif ('MS-SarifVSCode.sarif-viewer' -notin $extJson.recommendations) {
                    $extJson.recommendations = @($extJson.recommendations) + @('MS-SarifVSCode.sarif-viewer')
                }
                $extJson | ConvertTo-Json -Depth 5 | Set-Content $extJsonPath -Encoding UTF8
            } else {
                @{ recommendations = @('MS-SarifVSCode.sarif-viewer') } | ConvertTo-Json -Depth 5 | Set-Content $extJsonPath -Encoding UTF8
            }
        }

        # 2b. .gitignore
        $jobs += Start-Job -Name "codeql-gitignore" -ScriptBlock {
            Set-Location $using:repoRoot
            $cqlRelPath = $using:codeqlRelPath
            $entries = @('.codeql-db/', '.codeql-results.sarif', '.codeql-results-*.sarif', "$cqlRelPath/.scan-lock", "$cqlRelPath/status.json")
            $gitignorePath = '.gitignore'
            $existing = if (Test-Path $gitignorePath) { Get-Content $gitignorePath } else { @() }
            $added = 0
            foreach ($entry in $entries) {
                if ($entry -notin $existing) {
                    Add-Content $gitignorePath $entry
                    $added++
                }
            }
            if ($added -gt 0) {
                Write-Output "[PASS] Added $added entries to .gitignore"
            } else {
                Write-Output "[PASS] .gitignore already up to date"
            }
        }

        # 2c. Hooks + profile
        $jobs += Start-Job -Name "codeql-hooks" -ScriptBlock {
            Set-Location $using:repoRoot
            $prof = $using:profilePath
            $cqlDir = $using:codeqlDir
            $ghDir = $using:gitHooksDir

            # Ensure .git/hooks/ exists
            if (-not (Test-Path $ghDir)) { New-Item -ItemType Directory -Path $ghDir -Force | Out-Null }

            # Backup existing pre-commit hook
            $destHook = Join-Path $ghDir 'pre-commit'
            if (Test-Path $destHook) {
                if (-not (Test-Path "$destHook.backup")) {
                    Copy-Item $destHook "$destHook.backup"
                }
            }

            # Copy pre-commit hook from template into .git/hooks/
            $sourceHook = "$cqlDir/hooks/pre-commit"
            if (Test-Path $sourceHook) {
                Copy-Item $sourceHook $destHook -Force
                Write-Output "[PASS] Pre-commit hook copied to .git/hooks/pre-commit"
            } else {
                Write-Output "[FAIL] Source hook not found at $cqlDir/hooks/pre-commit"
            }

            # Ensure hooks are executable (macOS/Linux)
            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                if (Test-Path $destHook) {
                    chmod +x $destHook 2>$null
                }
                if (Test-Path "$cqlDir/git-secure.sh") {
                    chmod +x "$cqlDir/git-secure.sh" 2>$null
                }
            }

            # Profile setup
            if (-not $prof) {
                Write-Output "[WARN] Could not determine PowerShell profile path -- skipping profile setup"
                Write-Output "       Run install.ps1 from a regular PowerShell terminal to enable the codeql-scan alias"
                return
            }

            $profileDir = Split-Path $prof
            if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }

            # Safety backup
            if ((Test-Path $prof) -and -not (Test-Path "$prof.pre-codeql")) {
                Copy-Item $prof "$prof.pre-codeql"
            }

            # Idempotency: remove existing CodeQL Vibe block
            if (Test-Path $prof) {
                $content = Get-Content $prof -Raw
                if ($content -match '# --- CodeQL Vibe start ---') {
                    $content = $content -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\r?\n?', ''
                    Set-Content $prof $content -Encoding UTF8
                }
            }

            # Write the git wrapper + codeql-scan alias
            $snippet = @'

# --- CodeQL Vibe start ---
function git {
    # Only intercept 'commit' -- all other commands go straight to git.exe (no rev-parse overhead)
    if ($args.Count -gt 0 -and $args[0] -eq 'commit') {
        $repoRoot = & git.exe rev-parse --show-toplevel 2>$null
        if ($repoRoot) {
            $secureScript = '.github/codeql/git-secure.ps1', '.codeql/git-secure.ps1' | ForEach-Object { Join-Path $repoRoot $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($secureScript) {
                & powershell -ExecutionPolicy Bypass -NoProfile -File $secureScript @args
                return
            }
        }
    }
    & git.exe @args
}
function codeql-scan {
    $repoRoot = & git.exe rev-parse --show-toplevel 2>$null
    $scanScript = $null
    if ($repoRoot) {
        $scanScript = '.github/codeql/scan.ps1', '.codeql/scan.ps1' | ForEach-Object { Join-Path $repoRoot $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($scanScript) {
        & powershell -ExecutionPolicy Bypass -NoProfile -File $scanScript @args
    } else {
        Write-Host "[FAIL] Not in a CodeQL-enabled repository" -ForegroundColor Red
    }
}
# --- CodeQL Vibe end ---
'@
            Add-Content $prof $snippet -Encoding UTF8
            Write-Output "[PASS] Git wrapper + codeql-scan alias added to profile"

            # macOS/Linux: also add to bash/zsh
            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                $shellSnippet = @'

# --- CodeQL Vibe start ---
git() {
    if [ "$1" = "commit" ]; then
        local repo_root
        repo_root=$(command git rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$repo_root" ]; then
            local secure_script=""
            if [ -x "$repo_root/.github/codeql/git-secure.sh" ]; then
                secure_script="$repo_root/.github/codeql/git-secure.sh"
            elif [ -x "$repo_root/.codeql/git-secure.sh" ]; then
                secure_script="$repo_root/.codeql/git-secure.sh"
            fi
            if [ -n "$secure_script" ]; then
                "$secure_script" "$@"
                return $?
            fi
        fi
    fi
    command git "$@"
}
codeql-scan() {
    local repo_root
    repo_root=$(command git rev-parse --show-toplevel 2>/dev/null)
    local scan_script=""
    if [ -n "$repo_root" ] && [ -f "$repo_root/.github/codeql/scan.ps1" ]; then
        scan_script="$repo_root/.github/codeql/scan.ps1"
    elif [ -n "$repo_root" ] && [ -f "$repo_root/.codeql/scan.ps1" ]; then
        scan_script="$repo_root/.codeql/scan.ps1"
    fi
    if [ -n "$scan_script" ]; then
        pwsh -ExecutionPolicy Bypass -NoProfile -File "$scan_script" "$@"
    else
        echo "[FAIL] Not in a CodeQL-enabled repository"
    fi
}
# --- CodeQL Vibe end ---
'@
                foreach ($rc in @("$HOME/.bashrc", "$HOME/.zshrc")) {
                    if (Test-Path $rc) {
                        # Backup
                        if (-not (Test-Path "$rc.pre-codeql")) { Copy-Item $rc "$rc.pre-codeql" }
                        # Idempotency
                        $rcContent = Get-Content $rc -Raw
                        if ($rcContent -match '# --- CodeQL Vibe start ---') {
                            $rcContent = $rcContent -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\n?', ''
                            Set-Content $rc $rcContent
                        }
                        Add-Content $rc $shellSnippet
                    }
                }
            }
        }

        # Wait for parallel batch (30s timeout)
        $completed = $jobs | Wait-Job -Timeout 30
        $timedOut = $jobs | Where-Object { $_.State -eq 'Running' }
        if ($timedOut) {
            $timedOut | Stop-Job -ErrorAction SilentlyContinue
            Write-Host "[WARN] Some parallel steps timed out" -ForegroundColor Yellow
        }
        foreach ($job in $jobs) {
            $output = Receive-Job -Job $job 2>&1
            $output | ForEach-Object { Write-Host $_ }
            $stepName = switch -Wildcard ($job.Name) {
                '*sarif*' { 'SARIF Viewer' }
                '*gitignore*' { '.gitignore' }
                '*hooks*' { 'Hooks + profile' }
            }
            if ($job.State -eq 'Failed') {
                $installState[$stepName] = 'failed'
            } else {
                $installState[$stepName] = 'done'
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    } else {
        # Sequential fallback
        Write-Host "[INFO] Start-Job unavailable -- running steps sequentially" -ForegroundColor Yellow

        # 2a. SARIF Viewer
        $installState['SARIF Viewer'] = 'running'
        $codeCmd = Get-Command code -ErrorAction SilentlyContinue
        if ($codeCmd) {
            & code --install-extension "MS-SarifVSCode.sarif-viewer" --force 2>&1 | Out-Null
            Write-Host "[PASS] SARIF Viewer extension installed" -ForegroundColor Green
        } else {
            Write-Host "[INFO] SARIF Viewer skipped -- install manually from VS Code marketplace" -ForegroundColor Yellow
        }
        $installState['SARIF Viewer'] = 'done'

        # 2b. .gitignore
        $installState['.gitignore'] = 'running'
        $entries = @('.codeql-db/', '.codeql-results.sarif', '.codeql-results-*.sarif', "$codeqlRelPath/.scan-lock", "$codeqlRelPath/status.json")
        $existing = if (Test-Path '.gitignore') { Get-Content '.gitignore' } else { @() }
        foreach ($entry in $entries) {
            if ($entry -notin $existing) { Add-Content '.gitignore' $entry }
        }
        Write-Host "[PASS] .gitignore updated" -ForegroundColor Green
        $installState['.gitignore'] = 'done'

        # 2c. Hooks + profile
        $installState['Hooks + profile'] = 'running'

        # Ensure .git/hooks/ exists
        if (-not (Test-Path $gitHooksDir)) { New-Item -ItemType Directory -Path $gitHooksDir -Force | Out-Null }

        # Backup existing pre-commit hook
        $destHook = Join-Path $gitHooksDir 'pre-commit'
        if (Test-Path $destHook) {
            if (-not (Test-Path "$destHook.backup")) {
                Copy-Item $destHook "$destHook.backup"
            }
        }

        # Copy pre-commit hook from template into .git/hooks/
        $sourceHook = "$codeqlDir/hooks/pre-commit"
        if (Test-Path $sourceHook) {
            Copy-Item $sourceHook $destHook -Force
            Write-Host "[PASS] Pre-commit hook copied to .git/hooks/pre-commit" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Source hook not found at $codeqlRelPath/hooks/pre-commit" -ForegroundColor Red
        }

        if ($profilePath) {
            $profileDir = Split-Path $profilePath
            if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
            if ((Test-Path $profilePath) -and -not (Test-Path "$profilePath.pre-codeql")) {
                Copy-Item $profilePath "$profilePath.pre-codeql"
            }
            if (Test-Path $profilePath) {
                $content = Get-Content $profilePath -Raw
                if ($content -match '# --- CodeQL Vibe start ---') {
                    $content = $content -replace '(?ms)# --- CodeQL Vibe start ---.*?# --- CodeQL Vibe end ---\r?\n?', ''
                    Set-Content $profilePath $content -Encoding UTF8
                }
            }
            $snippet = @"

# --- CodeQL Vibe start ---
function git {
    if (`$args.Count -gt 0 -and `$args[0] -eq 'commit') {
        `$repoRoot = & git.exe rev-parse --show-toplevel 2>`$null
        if (`$repoRoot) {
            `$secureScript = '.github/codeql/git-secure.ps1', '.codeql/git-secure.ps1' | ForEach-Object { Join-Path `$repoRoot `$_ } | Where-Object { Test-Path `$_ } | Select-Object -First 1
            if (`$secureScript) {
                & powershell -ExecutionPolicy Bypass -NoProfile -File `$secureScript @args
                return
            }
        }
    }
    & git.exe @args
}
function codeql-scan {
    `$repoRoot = & git.exe rev-parse --show-toplevel 2>`$null
    `$scanScript = `$null
    if (`$repoRoot) {
        `$scanScript = '.github/codeql/scan.ps1', '.codeql/scan.ps1' | ForEach-Object { Join-Path `$repoRoot `$_ } | Where-Object { Test-Path `$_ } | Select-Object -First 1
    }
    if (`$scanScript) {
        & powershell -ExecutionPolicy Bypass -NoProfile -File `$scanScript @args
    } else {
        Write-Host "[FAIL] Not in a CodeQL-enabled repository" -ForegroundColor Red
    }
}
# --- CodeQL Vibe end ---
"@
            Add-Content $profilePath $snippet -Encoding UTF8
            # Auto-reload profile
            if (Test-Path $profilePath) { . $profilePath }
            Write-Host "[PASS] Git wrapper + codeql-scan alias added to profile" -ForegroundColor Green
        }
        $installState['Hooks + profile'] = 'done'
    }

    # ========================================================================
    #  Step 3: Validation
    # ========================================================================

    $installState['Validation'] = 'running'
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Validating installation..." -ForegroundColor Cyan

    # 1. Pre-commit hook in .git/hooks/ -- ensure present and LF line endings
    $destHook = Join-Path $gitHooksDir 'pre-commit'
    $sourceHook = "$codeqlDir/hooks/pre-commit"
    if (Test-Path $destHook) {
        # Ensure LF line endings (MINGW bash fails with CRLF shebang)
        $rawBytes = [System.IO.File]::ReadAllBytes($destHook)
        if ($rawBytes -contains 0x0D) {
            $text = [System.Text.Encoding]::UTF8.GetString($rawBytes) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllBytes($destHook, [System.Text.Encoding]::UTF8.GetBytes($text))
            Write-Host "[AUTO] .git/hooks/pre-commit line endings converted to LF" -ForegroundColor Yellow
        }
        Write-Host "[PASS] Pre-commit hook installed at .git/hooks/pre-commit" -ForegroundColor Green
    } elseif (Test-Path $sourceHook) {
        # Hook missing from .git/hooks/ but source template exists -- auto-repair
        if (-not (Test-Path $gitHooksDir)) { New-Item -ItemType Directory -Path $gitHooksDir -Force | Out-Null }
        Copy-Item $sourceHook $destHook -Force
        # Ensure LF
        $rawBytes = [System.IO.File]::ReadAllBytes($destHook)
        if ($rawBytes -contains 0x0D) {
            $text = [System.Text.Encoding]::UTF8.GetString($rawBytes) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllBytes($destHook, [System.Text.Encoding]::UTF8.GetBytes($text))
        }
        Write-Host "[AUTO] Pre-commit hook restored to .git/hooks/pre-commit" -ForegroundColor Yellow
    } else {
        Write-Host "[FAIL] Pre-commit hook not found (source template missing)" -ForegroundColor Red
    }

    # Also ensure git-secure.sh has LF
    $gitSecure = "$codeqlDir/git-secure.sh"
    if (Test-Path $gitSecure) {
        $rawBytes = [System.IO.File]::ReadAllBytes($gitSecure)
        if ($rawBytes -contains 0x0D) {
            $text = [System.Text.Encoding]::UTF8.GetString($rawBytes) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllBytes($gitSecure, [System.Text.Encoding]::UTF8.GetBytes($text))
            Write-Host "[AUTO] git-secure.sh line endings converted to LF" -ForegroundColor Yellow
        }
    }

    # 3. CodeQL CLI accessible
    $codeqlCmd = Get-Command codeql -ErrorAction SilentlyContinue
    if ($codeqlCmd) {
        Write-Host "[PASS] CodeQL CLI in PATH ($($codeqlCmd.Source))" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] CodeQL CLI not found in PATH" -ForegroundColor Red
    }

    # 4. Convenience alias
    if (Get-Command codeql-scan -ErrorAction SilentlyContinue) {
        Write-Host "[PASS] codeql-scan alias active" -ForegroundColor Green
    } else {
        Write-Host "[INFO] codeql-scan alias will activate in new terminals" -ForegroundColor Yellow
    }

    # 5. Query pack resolution
    $qlpackOut = codeql resolve qlpacks 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[PASS] CodeQL query packs resolve successfully" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] CodeQL query packs failed to resolve -- CLI may be corrupted" -ForegroundColor Red
        Write-Host "  Try reinstalling: https://github.com/github/codeql-cli-binaries/releases/latest" -ForegroundColor Yellow
    }

    $installState['Validation'] = 'done'

    # ========================================================================
    #  Step 4: Completion summary
    # ========================================================================

    $sw.Stop()
    $endTime = Get-Date

    Write-Host "" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  CodeQL Vibe Installation Complete" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Started at:  $($startTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))" -ForegroundColor Cyan
    Write-Host "Finished at: $($endTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))" -ForegroundColor Cyan
    $ts = $sw.Elapsed
    $elapsed = if ($ts.TotalSeconds -lt 60) { "{0:F1}s" -f $ts.TotalSeconds } else { "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds }
    Write-Host "Elapsed:     $elapsed" -ForegroundColor Cyan

    # OS
    $osName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' }
    Write-Host "OS:          $osName" -ForegroundColor Cyan

    # CodeQL version
    $codeqlVer = & codeql version 2>$null | Out-String
    if ($codeqlVer -match '(\d+\.\d+\.\d+)') {
        Write-Host "CodeQL CLI:  v$($Matches[1])" -ForegroundColor Cyan
    }

    # Supported languages
    Write-Host "Supported languages: JavaScript/TypeScript, Python, Java/Kotlin, C#, C/C++, Go, Ruby, Swift" -ForegroundColor Cyan

    # Files created
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Created:" -ForegroundColor White
    Write-Host "  $codeqlRelPath/                    (folder)" -ForegroundColor White
    Write-Host "  $codeqlRelPath/scan.ps1            Scan script" -ForegroundColor White
    Write-Host "  $codeqlRelPath/git-secure.ps1      PowerShell git wrapper" -ForegroundColor White
    Write-Host "  $codeqlRelPath/git-secure.sh       Bash/zsh git wrapper" -ForegroundColor White
    Write-Host "  $codeqlRelPath/install.ps1         Complete bootstrapper" -ForegroundColor White
    Write-Host "  $codeqlRelPath/uninstall.ps1       Uninstaller" -ForegroundColor White
    Write-Host "  $codeqlRelPath/codeql-config.yml   CodeQL configuration" -ForegroundColor White
    Write-Host "Modified:" -ForegroundColor White
    Write-Host "  .gitignore                  Added CodeQL temp-file exclusions" -ForegroundColor White
    Write-Host "  .git/hooks/pre-commit       Pre-commit hook (copied from template)" -ForegroundColor White
    Write-Host "  Shell profile               Added git wrapper + codeql-scan alias" -ForegroundColor White

    # Language dependency checklist
    $extMap = @{
        '.cs' = 'csharp'; '.js' = 'javascript'; '.ts' = 'javascript'; '.jsx' = 'javascript'; '.tsx' = 'javascript'
        '.py' = 'python'; '.java' = 'java'; '.kt' = 'java'; '.go' = 'go'; '.rb' = 'ruby'
        '.c' = 'cpp'; '.h' = 'cpp'; '.cpp' = 'cpp'; '.cc' = 'cpp'; '.swift' = 'swift'
    }
    $repoLangs = git ls-files 2>$null | ForEach-Object {
        $ext = [System.IO.Path]::GetExtension($_)
        if ($extMap.ContainsKey($ext)) { $extMap[$ext] }
    } | Select-Object -Unique

    $actions = @()
    foreach ($lang in $repoLangs) {
        switch ($lang) {
            'csharp' {
                if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                    $actions += "C# -- Install .NET SDK: https://dot.net/download"
                }
                $actions += "C# -- Ensure all NuGet packages are in your .csproj (e.g., dotnet add package Microsoft.Data.SqlClient)"
                $actions += "C# -- Verify: dotnet build (must succeed before scans will pass)"
            }
            'java' {
                if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
                    $actions += "Java -- Install JDK 11+: https://adoptium.net"
                }
                $actions += "Java -- Verify: mvn compile (or gradle build) must succeed"
            }
            'go' {
                if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
                    $actions += "Go -- Install Go: https://go.dev/dl"
                }
                $actions += "Go -- Verify: go build ./... (must succeed before scans will pass)"
            }
            'cpp' {
                $hasCpp = (Get-Command cl -ErrorAction SilentlyContinue) -or
                          (Get-Command gcc -ErrorAction SilentlyContinue) -or
                          (Get-Command clang -ErrorAction SilentlyContinue)
                if (-not $hasCpp) {
                    $actions += "C/C++ -- Install a compiler: Visual Studio Build Tools (Windows) or gcc/clang (Linux/macOS)"
                }
                $actions += "C/C++ -- Verify: your build command (make / cmake --build . / msbuild) must succeed"
            }
            'swift' {
                if (-not (Get-Command xcodebuild -ErrorAction SilentlyContinue)) {
                    $actions += "Swift -- Install Xcode from the App Store (macOS only)"
                }
                $actions += "Swift -- Verify: swift build (SPM) or xcodebuild must succeed"
            }
        }
    }

    if ($actions.Count -gt 0) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Before your first commit, please ensure:" -ForegroundColor Yellow
        foreach ($action in $actions) {
            Write-Host "  - $action" -ForegroundColor Yellow
        }
        Write-Host "" -ForegroundColor Cyan
    }

    # Next steps
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  Teammates: powershell -ExecutionPolicy Bypass -NoProfile -File `"$codeqlRelPath/install.ps1`"" -ForegroundColor White
    Write-Host "  Scan now:  codeql-scan" -ForegroundColor White
    Write-Host "  Full scan: codeql-scan -Full" -ForegroundColor White
    Write-Host "  Pre-commit scans happen automatically on staged files" -ForegroundColor White
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Learn more at https://aka.ms/CELA-CODEQL" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Available guides:" -ForegroundColor Cyan
    Write-Host "  * Introduction        -- What CodeQL Vibe does, blocking policy, supported languages, and design decisions" -ForegroundColor White
    Write-Host "  * Getting Started     -- Step-by-step setup: copying files, running the agent, and verifying installation" -ForegroundColor White
    Write-Host "  * Troubleshooting     -- Common issues: CodeQL not found, slow scans, encoding errors, hook problems" -ForegroundColor White
    Write-Host "  * How It Works        -- Scan flow, severity classification, enforcement architecture, and query suites" -ForegroundColor White
    Write-Host "  * SARIF Guide         -- Understanding SARIF output, using the viewer, filtering results, and comparing scans" -ForegroundColor White
    Write-Host "  * Remediation Guide   -- Fixing vulnerabilities with vibe coding prompts, manual patterns, and false positive handling" -ForegroundColor White
    Write-Host "  * Dependencies Guide  -- Per-language build prerequisites, what the scan auto-resolves, and what you install" -ForegroundColor White
    Write-Host "  * Prompts Guide       -- All available prompts with examples, tips, and when to use each one" -ForegroundColor White

} finally {
    $incomplete = $installState.GetEnumerator() | Where-Object { $_.Value -ne 'done' }
    if ($incomplete) {
        Write-Host "" -ForegroundColor Red
        Write-Host "[PARTIAL] Installation did not complete. Status:" -ForegroundColor Red
        foreach ($step in $installState.GetEnumerator()) {
            $color = switch ($step.Value) { 'done' { 'Green' } 'failed' { 'Red' } default { 'Yellow' } }
            $icon = switch ($step.Value) { 'done' { '[PASS]' } 'failed' { '[FAIL]' } default { '[SKIP]' } }
            Write-Host "  $icon $($step.Key)" -ForegroundColor $color
        }
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Re-run install.ps1 to retry. Completed steps will be detected and skipped." -ForegroundColor Yellow
    }
}
