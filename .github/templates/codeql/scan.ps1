# CodeQL Pre-Commit Scan Script (Multi-Language)
# Scans uncommitted changes by default; use -Full for entire codebase
param(
    [switch]$Full,
    [switch]$DetailedOutput,
    [switch]$Parallel = $true
)

$ErrorActionPreference = 'Continue'

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

# --- Step 1: Stopwatch, timestamp functions, SARIF normalization ---

$startTime = Get-Date
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Format-Timestamp([datetime]$dt) {
    return $dt.ToString("yyyy-MM-dd HH:mm:ss zzz")
}

function Format-Elapsed([System.Diagnostics.Stopwatch]$sw) {
    $ts = $sw.Elapsed
    if ($ts.TotalSeconds -lt 60) { return "{0:F1}s" -f $ts.TotalSeconds }
    return "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds
}

function Normalize-SarifFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }

    $raw = Get-Content $path -Raw -Encoding UTF8
    $normalized = $raw.Replace([string][char]0x2028, "`n").Replace([string][char]0x2029, "`n`n")
    $normalized = [regex]::Replace($normalized, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')

    if ($normalized -ne $raw) {
        Set-Content $path $normalized -Encoding UTF8
        Write-Host "[AUTO] Normalized SARIF text in $path" -ForegroundColor Cyan
    }

    try {
        return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Host "[FAIL] Generated SARIF is invalid: $path" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Install-MissingSdk([string]$Language) {
    # Attempts to auto-install a missing language SDK for CodeQL scanning.
    # Returns $true if the SDK was successfully installed and is now available.
    # Uses user-local installs where possible (no admin required for .NET).
    $isWin = ($env:OS -eq 'Windows_NT')

    switch ($Language) {
        'csharp' {
            Write-Host "[AUTO] .NET SDK not found -- attempting installation..." -ForegroundColor Cyan
            try {
                $installScript = Join-Path $env:TEMP 'dotnet-install.ps1'
                Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript -UseBasicParsing

                # Validate the script's integrity/authenticity
                $signature = Get-AuthenticodeSignature $installScript
                if ($signature.Status -ne 'Valid') {
                    Write-Host "[FAIL] The downloaded dotnet-install.ps1 script is not validly signed." -ForegroundColor Red
                    return $false
                }

                $dotnetDir = if ($isWin) { Join-Path $env:LOCALAPPDATA 'dotnet' } else { Join-Path $HOME '.dotnet' }
                & $installScript -Channel 9.0 -InstallDir $dotnetDir 2>$null
                $dotnetExe = if ($isWin) { 'dotnet.exe' } else { 'dotnet' }
                if (Test-Path (Join-Path $dotnetDir $dotnetExe)) {
                    if ($env:PATH -notmatch [regex]::Escape($dotnetDir)) {
                        $env:PATH = "$dotnetDir$([IO.Path]::PathSeparator)$env:PATH"
                    }
                    $ver = & dotnet --version 2>$null
                    Write-Host "[PASS] .NET SDK $ver installed to $dotnetDir" -ForegroundColor Green
                    return $true
                }
            } catch {
                Write-Host "[WARN] .NET SDK auto-install failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        'java' {
            Write-Host "[AUTO] JDK not found -- attempting installation..." -ForegroundColor Cyan
            if ($isWin -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                & winget install --id EclipseAdoptium.Temurin.21.JDK --accept-source-agreements --accept-package-agreements --silent 2>$null
                # Refresh PATH from registry (winget modifies system PATH)
                $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
                if (Get-Command javac -ErrorAction SilentlyContinue) {
                    $ver = & javac -version 2>&1 | Select-Object -First 1
                    Write-Host "[PASS] JDK installed: $ver" -ForegroundColor Green
                    return $true
                }
            }
        }
        'go' {
            Write-Host "[AUTO] Go toolchain not found -- attempting installation..." -ForegroundColor Cyan
            if ($isWin -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                & winget install --id GoLang.Go --accept-source-agreements --accept-package-agreements --silent 2>$null
                $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
                if (Get-Command go -ErrorAction SilentlyContinue) {
                    $ver = & go version 2>$null
                    Write-Host "[PASS] Go installed: $ver" -ForegroundColor Green
                    return $true
                }
            }
        }
        'cpp' {
            Write-Host "[AUTO] No C/C++ compiler found -- searching for installed compilers..." -ForegroundColor Cyan
            if ($isWin) {
                # Check if MSYS2/MinGW gcc exists but is not on PATH
                $msysDirs = @('C:\msys64\ucrt64\bin', 'C:\msys64\mingw64\bin')
                foreach ($dir in $msysDirs) {
                    if (Test-Path (Join-Path $dir 'gcc.exe')) {
                        $env:PATH = "$dir;$env:PATH"
                        Write-Host "[PASS] Found gcc at $dir (added to PATH)" -ForegroundColor Green
                        return $true
                    }
                }
                # Check if Visual Studio cl.exe exists via vswhere
                $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
                if (Test-Path $vsWhere) {
                    $vsPath = & $vsWhere -latest -property installationPath 2>$null
                    if ($vsPath) {
                        $clExe = Get-ChildItem "$vsPath\VC\Tools\MSVC" -Recurse -Filter 'cl.exe' -ErrorAction SilentlyContinue |
                                 Where-Object { $_.FullName -match 'Hostx64\\x64' } |
                                 Select-Object -First 1
                        if ($clExe) {
                            $clDir = Split-Path $clExe.FullName
                            $env:PATH = "$clDir;$env:PATH"
                            Write-Host "[PASS] Found cl.exe via Visual Studio (added to PATH)" -ForegroundColor Green
                            return $true
                        }
                    }
                }
                # Attempt winget install of MinGW
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    Write-Host "  Installing MinGW via winget..." -ForegroundColor Cyan
                    & winget install --id MSYS2.MSYS2 --accept-source-agreements --accept-package-agreements --silent 2>$null
                    # After MSYS2 install, gcc requires pacman setup
                    if (Test-Path 'C:\msys64\usr\bin\bash.exe') {
                        & C:\msys64\usr\bin\bash.exe -lc 'pacman -S --noconfirm mingw-w64-ucrt-x86_64-gcc 2>/dev/null' 2>$null
                        if (Test-Path 'C:\msys64\ucrt64\bin\gcc.exe') {
                            $env:PATH = "C:\msys64\ucrt64\bin;$env:PATH"
                            Write-Host "[PASS] gcc installed via MSYS2 (added to PATH)" -ForegroundColor Green
                            return $true
                        }
                    }
                }
            }
        }
    }
    return $false
}

Write-Host "Scan started at $(Format-Timestamp $startTime)" -ForegroundColor Cyan

# --- Step 1b: Extension-to-language mapping ---

$extMap = @{
    '.js' = 'javascript'; '.jsx' = 'javascript'; '.ts' = 'javascript'; '.tsx' = 'javascript'; '.mjs' = 'javascript'; '.cjs' = 'javascript'
    '.py' = 'python'; '.pyw' = 'python'
    '.java' = 'java'; '.kt' = 'java'; '.kts' = 'java'
    '.cs' = 'csharp'
    '.c' = 'cpp'; '.h' = 'cpp'; '.cpp' = 'cpp'; '.hpp' = 'cpp'; '.cc' = 'cpp'; '.cxx' = 'cpp'
    '.go' = 'go'
    '.rb' = 'ruby'; '.erb' = 'ruby'
    '.swift' = 'swift'
}

# --- Step 2: Acquire scan lock ---

$lockFile = Join-Path (Get-Location) "$codeqlRelPath/.scan-lock"
if (-not (Test-Path $codeqlDir)) { New-Item -ItemType Directory -Path $codeqlDir -Force | Out-Null }
try {
    $script:lockStream = [System.IO.File]::Open(
        $lockFile,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
} catch {
    Write-Host "[FAIL] Another CodeQL scan is already running. Wait for it to finish." -ForegroundColor Red
    exit 1
}

try {
    # --- Step 3: Determine which files to scan ---

    $changedFiles = @()
    if ($Full) {
        $changedFiles = git ls-files 2>$null | Where-Object { $_ }
    } elseif ($env:GIT_INDEX_FILE) {
        # Running as pre-commit hook -- scan staged files only
        $changedFiles = git diff --cached --name-only --diff-filter=ACMR 2>$null | Where-Object { $_ }
    } else {
        # Manual invocation -- scan all uncommitted changes
        $headExists = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            $changedFiles = git diff HEAD --name-only --diff-filter=ACMR 2>$null | Where-Object { $_ }
        } else {
            # Initial commit -- no HEAD yet
            $staged = git diff --cached --name-only --diff-filter=ACMR 2>$null | Where-Object { $_ }
            $untracked = git ls-files --others --exclude-standard 2>$null | Where-Object { $_ }
            $changedFiles = @($staged) + @($untracked) | Select-Object -Unique
        }
    }

    # --- Step 4: Detect active languages from changed files ---

    $activeLanguages = @()
    foreach ($file in $changedFiles) {
        $ext = [System.IO.Path]::GetExtension($file)
        if ($ext -and $extMap.ContainsKey($ext)) {
            $lang = $extMap[$ext]
            if ($lang -notin $activeLanguages) {
                $activeLanguages += $lang
            }
        }
    }

    # --- Step 5: Exit if no scannable files ---

    if ($activeLanguages.Count -eq 0) {
        Write-Host "[PASS] No scannable files changed. Skipping CodeQL scan." -ForegroundColor Green
        exit 0
    }

    Write-Host "Languages detected: $($activeLanguages -join ', ')" -ForegroundColor Cyan
    Write-Host "Files to scan: $($changedFiles.Count)" -ForegroundColor Cyan

    # --- Step 7: Ensure database directory exists ---

    if (-not (Test-Path ".codeql-db")) { New-Item -ItemType Directory -Path ".codeql-db" -Force | Out-Null }

    # --- Step 7b: Detect available resources ---

    $totalRamMB = [math]::Round((Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1MB)
    $budgetMB = [math]::Round($totalRamMB * 0.7)
    $ramCreateMB = $budgetMB
    $jobCount = $activeLanguages.Count
    $ramPerAnalyzeMB = [math]::Round($budgetMB / $jobCount)
    $parallelAnalyze = $true
    if ($jobCount -eq 1 -or $totalRamMB -lt 8192 -or $ramPerAnalyzeMB -lt 2048 -or -not $Parallel) {
        $parallelAnalyze = $false
        $ramPerAnalyzeMB = $budgetMB
    }

    $scanFailed = $false
    $tempGlobalJson = $false
    $tempCsproj = $null
    $tempCppBuild = $null

    # --- Step 7c: Pre-build dependency restoration ---

    # Build tool detection -- early warning for languages without pre-build validation
    # All languages now have pre-build validation below.
    # This block is kept for any future language additions that may need early warnings.
    $buildToolWarnings = @()
    if ($buildToolWarnings) {
        $buildToolWarnings | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    }

    # Dependency restoration
    foreach ($lang in $activeLanguages) {
        switch ($lang) {
            'javascript' {
                $pkgJson = Test-Path 'package.json'
                if ($pkgJson) {
                    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                        Write-Host "Restoring JavaScript dependencies (pnpm)..." -ForegroundColor Cyan
                        & pnpm install --frozen-lockfile 2>$null
                        if ($LASTEXITCODE -ne 0) { & pnpm install 2>$null }
                    } elseif ((Test-Path 'yarn.lock') -and (Get-Command yarn -ErrorAction SilentlyContinue)) {
                        Write-Host "Restoring JavaScript dependencies (yarn)..." -ForegroundColor Cyan
                        & yarn install --frozen-lockfile 2>$null
                        if ($LASTEXITCODE -ne 0) { & yarn install 2>$null }
                    } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
                        Write-Host "Restoring JavaScript dependencies (npm)..." -ForegroundColor Cyan
                        & npm ci 2>$null
                        if ($LASTEXITCODE -ne 0) { & npm install 2>$null }
                    }
                }
            }
            'python' {
                $pipCmd = if (Get-Command pip3 -ErrorAction SilentlyContinue) { 'pip3' }
                          elseif (Get-Command pip -ErrorAction SilentlyContinue) { 'pip' }
                          else { $null }
                if ($pipCmd) {
                    if (Test-Path 'requirements.txt') {
                        Write-Host "Restoring Python dependencies (requirements.txt)..." -ForegroundColor Cyan
                        & $pipCmd install -r requirements.txt --quiet 2>$null
                    } elseif (Test-Path 'setup.py') {
                        Write-Host "Restoring Python dependencies (setup.py)..." -ForegroundColor Cyan
                        & $pipCmd install -e . --quiet 2>$null
                    } elseif (Test-Path 'pyproject.toml') {
                        Write-Host "Restoring Python dependencies (pyproject.toml)..." -ForegroundColor Cyan
                        & $pipCmd install -e . --quiet 2>$null
                    }
                }
            }
            'ruby' {
                if ((Get-Command bundle -ErrorAction SilentlyContinue) -and (Test-Path 'Gemfile')) {
                    Write-Host "Restoring Ruby dependencies (bundler)..." -ForegroundColor Cyan
                    & bundle install --quiet 2>$null
                }
            }
            'csharp' {
                if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                    $sln = Get-ChildItem -Path . -Filter '*.sln' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($sln) {
                        Write-Host "Restoring NuGet packages ($($sln.Name))..." -ForegroundColor Cyan
                        & dotnet restore $sln.FullName --verbosity quiet 2>$null
                    } else {
                        $projs = Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue
                        if ($projs) {
                            Write-Host "Restoring NuGet packages ($($projs.Count) project(s))..." -ForegroundColor Cyan
                            foreach ($p in $projs) { & dotnet restore $p.FullName --verbosity quiet 2>$null }
                        }
                    }
                }
            }
            'java' {
                if (Test-Path 'pom.xml') {
                    Write-Host "Resolving Maven dependencies..." -ForegroundColor Cyan
                    & mvn dependency:resolve -q 2>$null
                } elseif ((Test-Path 'build.gradle') -or (Test-Path 'build.gradle.kts')) {
                    $gradleCmd = if (Test-Path './gradlew.bat') { '.\gradlew.bat' } elseif (Test-Path './gradlew') { './gradlew' } else { 'gradle' }
                    Write-Host "Resolving Gradle dependencies..." -ForegroundColor Cyan
                    & $gradleCmd dependencies --quiet 2>$null
                }
            }
            'go' {
                if ((Get-Command go -ErrorAction SilentlyContinue) -and (Test-Path 'go.mod')) {
                    Write-Host "Downloading Go modules..." -ForegroundColor Cyan
                    & go mod download 2>$null
                }
            }
            'swift' {
                if ((Get-Command swift -ErrorAction SilentlyContinue) -and (Test-Path 'Package.swift')) {
                    Write-Host "Resolving Swift packages..." -ForegroundColor Cyan
                    & swift package resolve 2>$null
                }
                if ((Get-Command pod -ErrorAction SilentlyContinue) -and (Test-Path 'Podfile')) {
                    Write-Host "Installing CocoaPods..." -ForegroundColor Cyan
                    & pod install 2>$null
                }
            }
        }
    }

    # Pre-build validation
    $preBuildFailed = @()
    foreach ($lang in @($activeLanguages)) {
        switch ($lang) {
            'csharp' {
                if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                    Install-MissingSdk 'csharp'
                }
                if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                    $sln = Get-ChildItem -Path . -Filter '*.sln' -Depth 0 -ErrorAction SilentlyContinue | Select-Object -First 1
                    $buildTarget = if ($sln) { $sln.FullName } else {
                        $p = Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($p) { $p.FullName } else { $null }
                    }
                    if (-not $buildTarget) {
                        # Buildless fallback -- check for loose .cs files
                        $csFiles = Get-ChildItem -Path . -Filter '*.cs' -Recurse -Depth 5 -ErrorAction SilentlyContinue
                        if ($csFiles) {
                            Write-Host "[AUTO] No .sln or .csproj found -- generating temporary project for C# scan" -ForegroundColor Cyan
                            # Auto-detect TargetFramework from installed .NET SDK
                            $tfm = 'net8.0'
                            $sdkList = & dotnet --list-sdks 2>$null
                            if ($sdkList) {
                                $sdkVersions = $sdkList | ForEach-Object {
                                    if ($_ -match '^(\d+)\.') { [int]$Matches[1] }
                                } | Sort-Object -Descending
                                if ($sdkVersions) { $tfm = "net$($sdkVersions[0]).0" }
                            }
                            $tempCsprojPath = Join-Path (Get-Location) '.codeql-temp-scan.csproj'
                            $csprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$tfm</TargetFramework>
    <OutputType>Library</OutputType>
    <EnableDefaultCompileItems>true</EnableDefaultCompileItems>
    <NoWarn>CS8021;CS0246;CS8019;CS0168;CS0219</NoWarn>
  </PropertyGroup>
</Project>
"@
                            Set-Content -Path $tempCsprojPath -Value $csprojContent -Encoding UTF8
                            $tempCsproj = $tempCsprojPath
                            $buildTarget = $tempCsprojPath
                            Write-Host "  Generated .codeql-temp-scan.csproj (TargetFramework=$tfm)" -ForegroundColor DarkCyan
                        } else {
                            Write-Host "[FAIL] No .sln, .csproj, or .cs files found -- skipping C# CodeQL scan" -ForegroundColor Red
                            $preBuildFailed += $lang
                        }
                    } else {
                        Write-Host "Validating C# build..." -ForegroundColor Cyan
                        $buildOutput = & dotnet build $buildTarget --no-restore --verbosity quiet 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host "[FAIL] C# project does not build -- skipping C# CodeQL scan" -ForegroundColor Red
                            $cs1069Matches = [regex]::Matches($buildOutput, "CS1069.*?forwarded to assembly '([^,]+)")
                            if ($cs1069Matches.Count -gt 0) {
                                $missingPkgs = $cs1069Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
                                $deprecatedMap = @{
                                    'System.Data.SqlClient'         = 'Microsoft.Data.SqlClient'
                                    'Microsoft.Azure.Storage.Blob'  = 'Azure.Storage.Blobs'
                                    'Microsoft.Azure.Storage.Queue' = 'Azure.Storage.Queues'
                                    'Microsoft.Azure.ServiceBus'    = 'Azure.Messaging.ServiceBus'
                                    'Microsoft.Azure.EventHubs'     = 'Azure.Messaging.EventHubs'
                                    'Microsoft.Azure.KeyVault'      = 'Azure.Security.KeyVault.Secrets'
                                }
                                Write-Host "" -ForegroundColor Yellow
                                Write-Host "Missing package reference(s) detected:" -ForegroundColor Yellow
                                foreach ($pkg in $missingPkgs) {
                                    if ($deprecatedMap.ContainsKey($pkg)) {
                                        $rec = $deprecatedMap[$pkg]
                                        Write-Host "  dotnet add package $rec" -ForegroundColor Yellow
                                        Write-Host "    (replaces deprecated $pkg)" -ForegroundColor DarkYellow
                                    } else {
                                        Write-Host "  dotnet add package $pkg" -ForegroundColor Yellow
                                    }
                                }
                                Write-Host "" -ForegroundColor Yellow
                                Write-Host "Run the command(s) above, then retry the commit." -ForegroundColor Yellow
                            } else {
                                Write-Host "" -ForegroundColor Yellow
                                Write-Host "C# requires a successful build for CodeQL analysis." -ForegroundColor Yellow
                                Write-Host "  1. Verify the project builds:  dotnet build" -ForegroundColor Yellow
                                Write-Host "  2. Fix any compilation errors, then retry the commit." -ForegroundColor Yellow
                            }
                            $preBuildFailed += $lang
                        } else {
                            Write-Host "[PASS] C# build validation OK" -ForegroundColor Green
                            # .NET SDK compatibility -- auto-pin to older SDK if needed
                            $sdkVer = (& dotnet --version 2>$null)
                            $sdkMajor = if ($sdkVer -match '^(\d+)\.') { [int]$Matches[1] } else { 0 }
                            if ($sdkMajor -ge 10 -and -not (Test-Path 'global.json')) {
                                $tfmMajor = 0
                                Get-ChildItem -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
                                    Select-Object -ExpandProperty FullName |
                                    ForEach-Object {
                                        $content = Get-Content $_ -Raw -ErrorAction SilentlyContinue
                                        if ($content -match '<TargetFramework[s]?>[^<]*net(\d+)\.\d[^<]*</TargetFramework[s]?>') {
                                            $m = [int]$Matches[1]
                                            if ($m -gt $tfmMajor) { $tfmMajor = $m }
                                        }
                                    }
                                if ($tfmMajor -ge $sdkMajor) {
                                    Write-Host "[WARN] .NET SDK $sdkVer detected -- CodeQL may not support this version yet" -ForegroundColor Yellow
                                    Write-Host "  Project targets net$tfmMajor.0, which requires SDK $sdkMajor.x -- cannot pin to an older SDK." -ForegroundColor Yellow
                                    $activeCodeql = (Get-Command codeql -ErrorAction SilentlyContinue).Source
                                    $managedCodeql = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                                        Join-Path $env:LOCALAPPDATA 'CodeQL\codeql\codeql.exe'
                                    } else {
                                        $null
                                    }
                                    if ($managedCodeql -and $activeCodeql -and (Test-Path $managedCodeql) -and ($activeCodeql -ne $managedCodeql)) {
                                        $activeVerText = (& $activeCodeql version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).ToString().Trim()
                                        $managedVerText = (& $managedCodeql version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).ToString().Trim()
                                        $activeMatch = [regex]::Match($activeVerText, '(\d+\.\d+\.\d+)')
                                        $managedMatch = [regex]::Match($managedVerText, '(\d+\.\d+\.\d+)')
                                        if ($activeMatch.Success -and $managedMatch.Success) {
                                            $activeVer = [version]$activeMatch.Groups[1].Value
                                            $managedVer = [version]$managedMatch.Groups[1].Value
                                            if ($managedVer -and $managedVer -gt $activeVer) {
                                                Write-Host "[WARN] CodeQL Vibe already installed newer CodeQL at $managedCodeql, but this session is still using older CodeQL at $activeCodeql" -ForegroundColor Yellow
                                                Write-Host "  Restart VS Code, open a new terminal, run 'codeql version', then retry the commit." -ForegroundColor Yellow
                                            }
                                        }
                                    }
                                    Write-Host "  Re-run CodeQL Vibe setup in VS Code to refresh CodeQL CLI to the latest supported release:" -ForegroundColor Yellow
                                    Write-Host "    Copilot: /speckit.codeql --> Full Setup" -ForegroundColor Cyan
                                    Write-Host "    Claude:  Set up CodeQL" -ForegroundColor Cyan
                                    Write-Host "  If you need to update manually, use:" -ForegroundColor Yellow
                                    Write-Host "    https://github.com/github/codeql-cli-binaries/releases" -ForegroundColor Cyan
                                    Write-Host "  Or install a compatible SDK and retarget the project to net$($sdkMajor - 1).0 for scanning." -ForegroundColor Yellow
                                } else {
                                    $installed = & dotnet --list-sdks 2>$null
                                    $compatSdk = $installed |
                                        Where-Object { $_ -match '^(8|9)\.\d+\.\d+' } |
                                        ForEach-Object { ($_ -split '\s')[0] } |
                                        Sort-Object { [version]$_ } -Descending |
                                        Select-Object -First 1
                                    if ($compatSdk) {
                                        $compatMajor = ($compatSdk -split '\.')[0]
                                        $pinVersion = "$compatMajor.0.100"
                                        Write-Host "[AUTO] .NET SDK $sdkVer is too new for CodeQL -- pinning to $compatSdk via temporary global.json" -ForegroundColor Cyan
                                        @{ sdk = @{ version = $pinVersion; rollForward = 'latestFeature' } } | ConvertTo-Json | Set-Content 'global.json' -Encoding UTF8
                                        $tempGlobalJson = $true
                                        $pinnedVer = (& dotnet --version 2>$null)
                                        Write-Host "  Pinned SDK: $pinnedVer (will be removed after scan)" -ForegroundColor Cyan
                                    } else {
                                        Write-Host "[WARN] .NET SDK $sdkVer detected -- CodeQL may not support this version yet" -ForegroundColor Yellow
                                        Write-Host "  No compatible SDK (8.x or 9.x) found. Install one from: https://dot.net/download" -ForegroundColor Yellow
                                        Write-Host "  Or re-run CodeQL Vibe setup in VS Code to refresh the CLI first:" -ForegroundColor Yellow
                                        Write-Host "    Copilot: /speckit.codeql --> Full Setup" -ForegroundColor Cyan
                                        Write-Host "    Claude:  Set up CodeQL" -ForegroundColor Cyan
                                        Write-Host "  Or add a global.json manually:" -ForegroundColor Yellow
                                        Write-Host '    { "sdk": { "version": "8.0.100", "rollForward": "latestFeature" } }' -ForegroundColor Cyan
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Write-Host "[FAIL] dotnet CLI not found -- skipping C# CodeQL scan" -ForegroundColor Red
                    Write-Host "  Install the .NET SDK: https://dot.net/download" -ForegroundColor Yellow
                    $preBuildFailed += $lang
                }
            }
            'java' {
                if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
                    Install-MissingSdk 'java'
                }
                if (-not (Get-Command javac -ErrorAction SilentlyContinue)) {
                    Write-Host "[FAIL] JDK not found -- skipping Java CodeQL scan" -ForegroundColor Red
                    Write-Host "  Install a JDK: https://adoptium.net" -ForegroundColor Yellow
                    $preBuildFailed += $lang
                } else {
                    $buildCmd = $null
                    if (Test-Path 'pom.xml') {
                        $buildCmd = 'mvn compile -q'
                    } elseif ((Test-Path 'build.gradle') -or (Test-Path 'build.gradle.kts')) {
                        $gc = if (Test-Path './gradlew.bat') { '.\gradlew.bat' } elseif (Test-Path './gradlew') { './gradlew' } else { 'gradle' }
                        $buildCmd = "$gc compileJava --quiet"
                    }
                    if ($buildCmd) {
                        Write-Host "Validating Java build..." -ForegroundColor Cyan
                        Invoke-Expression $buildCmd 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host "[FAIL] Java project does not build -- skipping Java CodeQL scan" -ForegroundColor Red
                            Write-Host "  Fix build errors and retry the commit." -ForegroundColor Yellow
                            $preBuildFailed += $lang
                        } else {
                            Write-Host "[PASS] Java build validation OK" -ForegroundColor Green
                        }
                    }
                }
            }
            'go' {
                if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
                    Install-MissingSdk 'go'
                }
                if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
                    Write-Host "[FAIL] Go toolchain not found -- skipping Go CodeQL scan" -ForegroundColor Red
                    Write-Host "  Install Go: https://go.dev/dl" -ForegroundColor Yellow
                    $preBuildFailed += $lang
                } elseif (Test-Path 'go.mod') {
                    Write-Host "Validating Go build..." -ForegroundColor Cyan
                    & go build ./... 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[FAIL] Go project does not build -- skipping Go CodeQL scan" -ForegroundColor Red
                        Write-Host "  Fix build errors and retry the commit." -ForegroundColor Yellow
                        $preBuildFailed += $lang
                    } else {
                        Write-Host "[PASS] Go build validation OK" -ForegroundColor Green
                    }
                }
            }
            'cpp' {
                $hasCppCompiler = (Get-Command gcc -ErrorAction SilentlyContinue) -or
                                  (Get-Command clang -ErrorAction SilentlyContinue) -or
                                  (Get-Command cl -ErrorAction SilentlyContinue)
                if (-not $hasCppCompiler) {
                    if (Install-MissingSdk 'cpp') {
                        $hasCppCompiler = $true
                    }
                }
                $hasBuildSystem = (Test-Path 'Makefile') -or (Test-Path 'GNUmakefile') -or
                                  (Test-Path 'CMakeLists.txt') -or (Test-Path 'build.ninja') -or
                                  (Get-ChildItem -Path . -Filter '*.vcxproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue)
                if ($hasBuildSystem) {
                    if (-not $hasCppCompiler) {
                        Write-Host "[FAIL] C/C++ build system found but no compiler (cl, gcc, clang) on PATH" -ForegroundColor Red
                        Write-Host "  Install a C/C++ compiler and retry." -ForegroundColor Yellow
                        $preBuildFailed += $lang
                    } else {
                        Write-Host "[PASS] C/C++ build system and compiler detected" -ForegroundColor Green
                    }
                } else {
                    # No build system -- check for loose C/C++ source files
                    $cppFiles = Get-ChildItem -Path . -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                                Where-Object { $_.Extension -in @('.c', '.cpp', '.cc', '.cxx') }
                    if ($cppFiles -and $hasCppCompiler) {
                        Write-Host "[AUTO] No build system found -- generating temporary build command for C/C++ scan" -ForegroundColor Cyan
                        # Pick the best available compiler
                        $cppCompiler = if (Get-Command gcc -ErrorAction SilentlyContinue) { 'gcc' }
                                       elseif (Get-Command clang -ErrorAction SilentlyContinue) { 'clang' }
                                       else { 'cl' }
                        $compileFlag = if ($cppCompiler -eq 'cl') { '/c' } else { '-c' }
                        # Generate temp build script
                        $tempBuildPath = Join-Path (Get-Location) '.codeql-temp-build.ps1'
                        $lines = @('$ErrorActionPreference = "Continue"')
                        foreach ($cf in $cppFiles) {
                            $escaped = $cf.FullName -replace "'", "''"
                            $lines += "& $cppCompiler $compileFlag '$escaped' 2>`$null"
                        }
                        Set-Content -Path $tempBuildPath -Value ($lines -join "`n") -Encoding UTF8
                        $tempCppBuild = $tempBuildPath
                        Write-Host "  Generated build command using $cppCompiler for $($cppFiles.Count) file(s)" -ForegroundColor DarkCyan
                    } elseif ($cppFiles) {
                        Write-Host "[FAIL] No C/C++ compiler found (cl, gcc, clang) -- skipping C/C++ scan" -ForegroundColor Red
                        Write-Host "  Install a compiler and retry." -ForegroundColor Yellow
                        $preBuildFailed += $lang
                    } else {
                        Write-Host "[FAIL] No build system or C/C++ source files found -- skipping C/C++ scan" -ForegroundColor Red
                        $preBuildFailed += $lang
                    }
                }
            }
            'javascript' {
                Write-Host "[PASS] JavaScript/TypeScript -- interpreted language, no build required" -ForegroundColor Green
            }
            'python' {
                Write-Host "[PASS] Python -- interpreted language, no build required" -ForegroundColor Green
            }
            'ruby' {
                Write-Host "[PASS] Ruby -- interpreted language, no build required" -ForegroundColor Green
            }
            'swift' {
                if (-not $IsMacOS -and -not ($PSVersionTable.OS -match 'Darwin')) {
                    Write-Host "[FAIL] Swift scanning requires macOS -- skipping on this platform" -ForegroundColor Red
                    $preBuildFailed += $lang
                } elseif (-not (Get-Command xcodebuild -ErrorAction SilentlyContinue)) {
                    Write-Host "[FAIL] Xcode not found -- Swift scanning requires xcodebuild" -ForegroundColor Red
                    Write-Host "  Install Xcode from the Mac App Store" -ForegroundColor Yellow
                    $preBuildFailed += $lang
                } else {
                    Write-Host "[PASS] Swift -- Xcode and compiler detected" -ForegroundColor Green
                }
            }
        }
    }
    # Remove languages that failed pre-build validation
    if ($preBuildFailed) {
        $activeLanguages = $activeLanguages | Where-Object { $_ -notin $preBuildFailed }
        if ($activeLanguages.Count -eq 0) {
            Write-Host "" -ForegroundColor Red
            Write-Host "[FAIL] All detected languages failed pre-build validation." -ForegroundColor Red
            Write-Host "Fix the build errors above, then retry the commit." -ForegroundColor Red
            $scanFailed = $true
        }
    }

    # Recalculate resource budgeting if languages were removed
    if (-not $scanFailed -and $preBuildFailed) {
        $jobCount = $activeLanguages.Count
        $ramPerAnalyzeMB = [math]::Round($budgetMB / $jobCount)
        if ($jobCount -eq 1 -or $totalRamMB -lt 8192 -or $ramPerAnalyzeMB -lt 2048 -or -not $Parallel) {
            $parallelAnalyze = $false
            $ramPerAnalyzeMB = $budgetMB
        }
    }

    # --- Step 8: Run language scans ---

    # Phase 1 -- Database creation
    if (-not $scanFailed) {
        $createSw = [System.Diagnostics.Stopwatch]::StartNew()
        $createExitCode = 0

        # Build the --command argument if any language needs a custom build command
        $buildCommandArgs = @()
        if ($tempCppBuild) {
            $buildCommandArgs += "--command=pwsh -NoProfile -File `"$tempCppBuild`""
        }

        if ($activeLanguages.Count -eq 1) {
            $language = $activeLanguages[0]
            if ($buildCommandArgs) {
                & codeql database create ".codeql-db/$language" --overwrite --language=$language --source-root=. --codescanning-config=$codeqlRelPath/codeql-config.yml --threads=0 --ram=$ramCreateMB $buildCommandArgs[0]
            } else {
                & codeql database create ".codeql-db/$language" --overwrite --language=$language --source-root=. --codescanning-config=$codeqlRelPath/codeql-config.yml --threads=0 --ram=$ramCreateMB
            }
            $createExitCode = $LASTEXITCODE
            if ($createExitCode -ne 0) {
                Write-Host "[FAIL] database create for $language exited with $createExitCode" -ForegroundColor Red
                $scanFailed = $true
            }
        } else {
            $langList = $activeLanguages -join ','
            if ($buildCommandArgs) {
                & codeql database create .codeql-db --db-cluster --overwrite --language=$langList --source-root=. --codescanning-config=$codeqlRelPath/codeql-config.yml --threads=0 --ram=$ramCreateMB $buildCommandArgs[0]
            } else {
                & codeql database create .codeql-db --db-cluster --overwrite --language=$langList --source-root=. --codescanning-config=$codeqlRelPath/codeql-config.yml --threads=0 --ram=$ramCreateMB
            }
            $createExitCode = $LASTEXITCODE
            if ($createExitCode -ne 0) {
                Write-Host "[FAIL] database create (cluster) exited with $createExitCode" -ForegroundColor Red
                $scanFailed = $true
            }
        }
        $createSw.Stop()
        if (-not $scanFailed) {
            Write-Host "[PASS] Database creation complete ($(Format-Elapsed $createSw))" -ForegroundColor Green
        }
    }

    # Phase 2 -- Query analysis

    # Sequential analysis
    if (-not $scanFailed -and -not $parallelAnalyze) {
        foreach ($language in $activeLanguages) {
            $langSw = [System.Diagnostics.Stopwatch]::StartNew()
            $dbPath = ".codeql-db/$language"
            $sarifFile = ".codeql-results-$language.sarif"

            $suiteLevel = if ($Full) { 'security-and-quality' } else { 'security-extended' }
            $suite = "codeql/${language}-queries:codeql-suites/${language}-${suiteLevel}.qls"
            & codeql database analyze $dbPath --format=sarifv2.1.0 --output=$sarifFile --no-rerun --threads=0 --ram=$ramPerAnalyzeMB $suite
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[FAIL] database analyze for $language exited with $LASTEXITCODE" -ForegroundColor Red
                $scanFailed = $true
                break
            }

            $langSw.Stop()
            Write-Host "[PASS] $language analyze complete ($(Format-Elapsed $langSw))" -ForegroundColor Green
        }
    }

    # Parallel analysis
    if (-not $scanFailed -and $parallelAnalyze) {
        $jobs = @()
        foreach ($language in $activeLanguages) {
            $sarifFile = ".codeql-results-$language.sarif"
            $dbPath = ".codeql-db/$language"
            $jobs += Start-Job -Name "codeql-$language" -ScriptBlock {
                param($lang, $db, $sarif, $workDir, $ramMB, $isFull)
                Set-Location $workDir
                $ErrorActionPreference = 'Continue'
                $jobSw = [System.Diagnostics.Stopwatch]::StartNew()

                $suiteLevel = if ($isFull) { 'security-and-quality' } else { 'security-extended' }
                $suite = "codeql/${lang}-queries:codeql-suites/${lang}-${suiteLevel}.qls"
                & codeql database analyze $db --format=sarifv2.1.0 --output=$sarif --no-rerun --threads=0 --ram=$ramMB $suite
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "[FAIL] database analyze for $lang exited with $LASTEXITCODE"
                    exit 1
                }

                $jobSw.Stop()
                $ts = $jobSw.Elapsed
                $elapsed = if ($ts.TotalSeconds -lt 60) { "{0:F1}s" -f $ts.TotalSeconds } else { "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds }
                Write-Output "[PASS] $lang analyze complete ($elapsed)"
            } -ArgumentList $language, $dbPath, $sarifFile, (Get-Location).Path, $ramPerAnalyzeMB, $Full
        }

        # Wait for all jobs (30-minute timeout)
        $jobs | Wait-Job -Timeout 1800 | Out-Null

        $timedOut = $jobs | Where-Object { $_.State -eq 'Running' }
        $completedJobs = $jobs | Where-Object { $_.State -ne 'Running' }

        if ($timedOut) {
            $timedOut | ForEach-Object {
                $lang = $_.Name -replace '^codeql-', ''
                Write-Host "[FAIL] CodeQL analyze for $lang timed out after 30 minutes" -ForegroundColor Red
                Stop-Job -Job $_ -ErrorAction SilentlyContinue
                Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue
            }
            $scanFailed = $true
        }

        foreach ($job in $completedJobs) {
            $output = Receive-Job -Job $job
            $output | ForEach-Object { Write-Host $_ }
            if ($job.State -eq 'Failed' -or ($output -match '\[FAIL\]')) {
                $lang = $job.Name -replace '^codeql-', ''
                Write-Host "[FAIL] CodeQL analyze failed for $lang" -ForegroundColor Red
                $scanFailed = $true
            }
            Remove-Job -Job $job
        }
    }

    # --- Step 19: Error guidance for database creation failures ---

    if ($scanFailed -and $createExitCode -ne 0) {
        # Determine the language for guidance (single-language has $language already set)
        $guidanceLang = if ($activeLanguages.Count -eq 1) { $activeLanguages[0] } else { $null }
        $guidanceLangs = @('csharp', 'java', 'cpp', 'go', 'swift')
        if ($guidanceLang -and $guidanceLang -in $guidanceLangs) {
            Write-Host "" -ForegroundColor Yellow
            switch ($guidanceLang) {
                'csharp' {
                    $hasDotnet = Get-Command dotnet -ErrorAction SilentlyContinue
                    $hasProject = (Get-ChildItem -Path . -Filter '*.sln' -Depth 0 -ErrorAction SilentlyContinue) -or
                                  (Get-ChildItem -Path . -Filter '*.csproj' -Recurse -Depth 3 -ErrorAction SilentlyContinue)
                    if (-not $hasDotnet) {
                        Write-Host "The .NET SDK (dotnet CLI) was not found on PATH." -ForegroundColor Yellow
                        Write-Host "  Install it from: https://dot.net/download" -ForegroundColor Yellow
                    } elseif (-not $hasProject) {
                        Write-Host "No .sln or .csproj found in the repo (searched depth 3)." -ForegroundColor Yellow
                        Write-Host "  CodeQL needs a project file to build C# code." -ForegroundColor Yellow
                        Write-Host "  If the project file is deeper, run the scan from that directory." -ForegroundColor Yellow
                    } elseif ($createExitCode -eq 32) {
                        $sdkVer = (& dotnet --version 2>$null)
                        Write-Host "The C# project builds successfully, but CodeQL could not process the compiler output." -ForegroundColor Yellow
                        Write-Host "  .NET SDK $sdkVer is newer than CodeQL's C# extractor supports." -ForegroundColor Yellow
                        Write-Host "" -ForegroundColor Yellow
                        if ($tempGlobalJson) {
                            Write-Host "  The scan pinned to an older SDK via temporary global.json, but the" -ForegroundColor Yellow
                            Write-Host "  extractor still failed. Update CodeQL CLI to a version that supports" -ForegroundColor Yellow
                            Write-Host "  .NET SDK $sdkVer :" -ForegroundColor Yellow
                        } else {
                            Write-Host "  The scan could not auto-pin to an older SDK (the project's target" -ForegroundColor Yellow
                            Write-Host "  framework requires SDK $sdkVer). Update CodeQL CLI to a version" -ForegroundColor Yellow
                            Write-Host "  that supports this SDK:" -ForegroundColor Yellow
                        }
                        Write-Host "    https://github.com/github/codeql-cli-binaries/releases" -ForegroundColor Cyan
                        Write-Host "" -ForegroundColor Yellow
                        Write-Host "  Or install a compatible .NET SDK alongside your current one:" -ForegroundColor Yellow
                        Write-Host "    winget install Microsoft.DotNet.SDK.9" -ForegroundColor Cyan
                        Write-Host "  and retarget the project to net9.0 if possible." -ForegroundColor Yellow
                    } else {
                        Write-Host "C# requires a successful dotnet build for CodeQL analysis." -ForegroundColor Yellow
                        Write-Host "  1. Verify the project builds:  dotnet build" -ForegroundColor Yellow
                        Write-Host "  2. If packages are missing:    dotnet add package <PackageName>" -ForegroundColor Yellow
                        Write-Host "     (Check build output for CS1069 -- the assembly name is the package)" -ForegroundColor Yellow
                        Write-Host "  3. If the SDK is missing:      https://dot.net/download" -ForegroundColor Yellow
                    }
                }
                'java' {
                    Write-Host "Java requires a successful build for CodeQL analysis." -ForegroundColor Yellow
                    Write-Host "  Maven:   mvn compile" -ForegroundColor Yellow
                    Write-Host "  Gradle:  gradle build" -ForegroundColor Yellow
                    Write-Host "  If the JDK is missing: https://adoptium.net" -ForegroundColor Yellow
                }
                'cpp' {
                    Write-Host "C/C++ requires a successful build for CodeQL analysis." -ForegroundColor Yellow
                    Write-Host "  Verify your build command works: make / cmake --build . / msbuild" -ForegroundColor Yellow
                }
                'go' {
                    Write-Host "Go requires module resolution for CodeQL analysis." -ForegroundColor Yellow
                    Write-Host "  1. Verify modules resolve:  go mod download" -ForegroundColor Yellow
                    Write-Host "  2. Verify the code builds:  go build ./..." -ForegroundColor Yellow
                    Write-Host "  3. If Go is missing:        https://go.dev/dl" -ForegroundColor Yellow
                }
                'swift' {
                    Write-Host "Swift requires macOS with Xcode for CodeQL analysis." -ForegroundColor Yellow
                    Write-Host "  1. Verify the project builds:  xcodebuild -scheme <Scheme>" -ForegroundColor Yellow
                    Write-Host "  2. For SPM projects:           swift build" -ForegroundColor Yellow
                    Write-Host "  3. If Xcode is missing:        Install from the App Store" -ForegroundColor Yellow
                }
            }
            Write-Host "Fix any build errors, then retry the commit." -ForegroundColor Yellow
        }
    }

    # --- Steps 9-14: SARIF merge, parse, filter, display, open ---

    $totalFindings = @{ Critical = 0; High = 0; Medium = 0; Low = 0; Informational = 0 }

    if (-not $scanFailed) {
        # Step 9: Normalize per-language SARIF and merge
        $sarifDocs = @{}
        foreach ($language in $activeLanguages) {
            $sarifPath = ".codeql-results-$language.sarif"
            $sarifDoc = Normalize-SarifFile $sarifPath
            if (-not $sarifDoc) {
                $scanFailed = $true
                break
            }
            $sarifDocs[$language] = $sarifDoc
        }

        if (-not $scanFailed -and $activeLanguages.Count -eq 1) {
            Copy-Item ".codeql-results-$($activeLanguages[0]).sarif" ".codeql-results.sarif" -Force
            if (-not (Normalize-SarifFile ".codeql-results.sarif")) {
                $scanFailed = $true
            }
        }

        if (-not $scanFailed -and $activeLanguages.Count -gt 1) {
            $allRuns = @()
            foreach ($language in $activeLanguages) {
                $allRuns += @($sarifDocs[$language].runs)
            }

            @{
                '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
                version = '2.1.0'
                runs = $allRuns
            } | ConvertTo-Json -Depth 20 | Set-Content '.codeql-results.sarif' -Encoding UTF8

            if (-not (Normalize-SarifFile '.codeql-results.sarif')) {
                $scanFailed = $true
            }
        }
    }

    if (-not $scanFailed) {
        # Step 10: Parse and filter combined SARIF
        $combinedSarif = Get-Content '.codeql-results.sarif' -Raw -Encoding UTF8 | ConvertFrom-Json

        # Build HashSet of changed files for O(1) lookups
        $changedFileSet = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $changedFiles) {
            $changedFileSet.Add(($f -replace '\\', '/')) | Out-Null
        }

        $findings = @()
        $langBreakdown = @{}

        foreach ($run in @($combinedSarif.runs)) {
            # Determine language from the run's tool name
            $toolName = $run.tool.driver.name
            $runLang = if ($toolName -match '(javascript|python|java|csharp|cpp|go|ruby|swift)') { $Matches[1] } else { 'unknown' }

            # Build a quick-lookup rule map for this run
            $ruleMap = @{}
            if ($run.tool.driver.rules) {
                foreach ($rule in $run.tool.driver.rules) {
                    $ruleMap[$rule.id] = $rule
                }
            }

            foreach ($result in @($run.results)) {
                # Get file path from the result
                $filePath = $null
                $lineNum = $null
                if ($result.locations -and $result.locations.Count -gt 0) {
                    $loc = $result.locations[0]
                    if ($loc.physicalLocation -and $loc.physicalLocation.artifactLocation) {
                        $filePath = $loc.physicalLocation.artifactLocation.uri
                    }
                    if ($loc.physicalLocation -and $loc.physicalLocation.region) {
                        $lineNum = $loc.physicalLocation.region.startLine
                    }
                }

                # Incremental filter: skip findings not in changed files (unless -Full)
                if (-not $Full -and $filePath) {
                    $normalizedPath = $filePath -replace '\\', '/'
                    if (-not $changedFileSet.Contains($normalizedPath)) { continue }
                }

                # Classify severity
                $secSev = $null
                if ($result.properties -and $result.properties.'security-severity') {
                    $secSev = [double]$result.properties.'security-severity'
                } elseif ($ruleMap.ContainsKey($result.ruleId)) {
                    $ruleObj = $ruleMap[$result.ruleId]
                    if ($ruleObj.properties -and $ruleObj.properties.'security-severity') {
                        $secSev = [double]$ruleObj.properties.'security-severity'
                    }
                }

                $severity = 'Informational'
                if ($secSev -ne $null) {
                    if ($secSev -ge 9.0) { $severity = 'Critical' }
                    elseif ($secSev -ge 7.0) { $severity = 'High' }
                    elseif ($secSev -ge 4.0) { $severity = 'Medium' }
                    else { $severity = 'Low' }
                } else {
                    $level = $result.level
                    switch ($level) {
                        'error' { $severity = 'Medium' }
                        'warning' { $severity = 'Low' }
                        default { $severity = 'Informational' }
                    }
                }

                $totalFindings[$severity]++
                if (-not $langBreakdown.ContainsKey($runLang)) { $langBreakdown[$runLang] = 0 }
                $langBreakdown[$runLang]++

                $message = if ($result.message -and $result.message.text) { $result.message.text } else { '' }
                if ($message.Length -gt 60) { $message = $message.Substring(0, 57) + '...' }

                $findings += [PSCustomObject]@{
                    Severity = $severity
                    Language = $runLang
                    RuleId   = $result.ruleId
                    File     = if ($filePath) { $filePath } else { '(unknown)' }
                    Line     = if ($lineNum) { $lineNum } else { '-' }
                    Message  = $message
                }
            }
        }

        # Step 11: Print summary
        if ($langBreakdown.Count -gt 0) {
            Write-Host "" -ForegroundColor Cyan
            foreach ($lang in $langBreakdown.Keys | Sort-Object) {
                $count = $langBreakdown[$lang]
                $noun = if ($count -eq 1) { 'finding' } else { 'findings' }
                Write-Host "-- ${lang}: $count $noun --" -ForegroundColor Cyan
            }
            Write-Host ""

            # Sort findings: Critical first, then High, Medium, Low, Informational
            $severityOrder = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Informational = 4 }
            $sortedFindings = $findings | Sort-Object { $severityOrder[$_.Severity] }

            # Print table
            $fmt = "| {0,-12} | {1,-10} | {2,-20} | {3,-30} | {4,-5} | {5,-40} |"
            $sep = "+" + ("-" * 14) + "+" + ("-" * 12) + "+" + ("-" * 22) + "+" + ("-" * 32) + "+" + ("-" * 7) + "+" + ("-" * 42) + "+"
            Write-Host $sep
            Write-Host ($fmt -f 'Severity', 'Language', 'Rule ID', 'File', 'Line', 'Message')
            Write-Host $sep
            foreach ($f in $sortedFindings) {
                $color = switch ($f.Severity) {
                    'Critical' { 'Red' }
                    'High' { 'Red' }
                    'Medium' { 'Yellow' }
                    'Low' { 'DarkYellow' }
                    default { 'Gray' }
                }
                $truncFile = $f.File
                if ($truncFile.Length -gt 30) { $truncFile = '...' + $truncFile.Substring($truncFile.Length - 27) }
                $truncRule = $f.RuleId
                if ($truncRule.Length -gt 20) { $truncRule = $truncRule.Substring(0, 17) + '...' }
                Write-Host ($fmt -f $f.Severity, $f.Language, $truncRule, $truncFile, $f.Line, $f.Message) -ForegroundColor $color
            }
            Write-Host $sep
        }

        # Step 12: Severity breakdown
        Write-Host ""
        Write-Host ("Critical: {0} | High: {1} | Medium: {2} | Low: {3} | Info: {4}" -f $totalFindings.Critical, $totalFindings.High, $totalFindings.Medium, $totalFindings.Low, $totalFindings.Informational) -ForegroundColor Cyan

        # Step 13: File locations
        Write-Host ""
        Write-Host "Per-language results:" -ForegroundColor Cyan
        foreach ($language in $activeLanguages) {
            Write-Host "   .codeql-results-$language.sarif" -ForegroundColor White
        }
        Write-Host "Combined results: .codeql-results.sarif" -ForegroundColor Cyan

        # Step 14: Open in VS Code
        $codeCmd = Get-Command code -ErrorAction SilentlyContinue
        if ($codeCmd) {
            code .codeql-results.sarif
        }
    }

    # --- Steps 15-18: Cleanup, elapsed time, scan history, verdict ---

    # Step 16: Print elapsed time
    $scanStopwatch.Stop()
    $endTime = Get-Date
    Write-Host ""
    Write-Host "Started at:  $(Format-Timestamp $startTime)" -ForegroundColor Cyan
    Write-Host "Finished at: $(Format-Timestamp $endTime)" -ForegroundColor Cyan
    Write-Host "Elapsed:     $(Format-Elapsed $scanStopwatch)" -ForegroundColor Cyan

    # Scan audit trail
    $trigger = if ($env:GIT_INDEX_FILE) { 'pre-commit' } elseif ($env:BUILD_BUILDID) { 'ci' } else { 'manual' }
    $developer = git config user.name 2>$null
    if (-not $developer) { $developer = $env:USERNAME }
    $agentVersion = 'unknown'
    if (Test-Path 'speckit.agent.yml') {
        $manifestContent = Get-Content 'speckit.agent.yml' -Raw -ErrorAction SilentlyContinue
        if ($manifestContent -match 'version:\s*[''"]?(\d+\.\d+\.\d+)') {
            $agentVersion = $Matches[1]
        }
    }
    $scanEntry = [PSCustomObject]@{
        timestamp = $startTime.ToString('o')
        durationMs = $scanStopwatch.ElapsedMilliseconds
        developer = $developer
        trigger = $trigger
        languages = $activeLanguages
        findings = [PSCustomObject]@{
            critical = $totalFindings.Critical
            high = $totalFindings.High
            medium = $totalFindings.Medium
            low = $totalFindings.Low
            informational = $totalFindings.Informational
        }
        blocked = $false
        agentVersion = $agentVersion
    }

    # Step 17-18: Verdict
    if ($scanFailed) {
        $scanEntry.blocked = $true
        # Write scan history
        $historyFile = "$codeqlDir/scan-history.json"
        if (Test-Path $historyFile) {
            $history = Get-Content -Raw $historyFile | ConvertFrom-Json
        } else {
            $history = [PSCustomObject]@{ scans = @() }
        }
        $history.scans = @($history.scans) + @($scanEntry)
        if ($history.scans.Count -gt 1000) { $history.scans = $history.scans[-1000..-1] }
        $tmpFile = "$historyFile.tmp"
        $history | ConvertTo-Json -Depth 10 | Set-Content $tmpFile -Encoding UTF8
        Move-Item $tmpFile $historyFile -Force

        Write-Host ""
        Write-Host "[FAIL] CodeQL scan failed (see errors above)" -ForegroundColor Red
        exit 1
    }

    $blockingCount = $totalFindings.Critical + $totalFindings.High + $totalFindings.Medium
    if ($blockingCount -gt 0) {
        $scanEntry.blocked = $true
        # Write scan history
        $historyFile = "$codeqlDir/scan-history.json"
        if (Test-Path $historyFile) {
            $history = Get-Content -Raw $historyFile | ConvertFrom-Json
        } else {
            $history = [PSCustomObject]@{ scans = @() }
        }
        $history.scans = @($history.scans) + @($scanEntry)
        if ($history.scans.Count -gt 1000) { $history.scans = $history.scans[-1000..-1] }
        $tmpFile = "$historyFile.tmp"
        $history | ConvertTo-Json -Depth 10 | Set-Content $tmpFile -Encoding UTF8
        Move-Item $tmpFile $historyFile -Force

        Write-Host ""
        Write-Host "[FAIL] COMMIT BLOCKED -- $blockingCount blocking finding(s) (Critical/High/Medium)" -ForegroundColor Red
        Write-Host "Fix the issues above, then retry the commit." -ForegroundColor Red
        exit 1
    }

    # No blocking findings
    $scanEntry.blocked = $false
    $historyFile = "$codeqlDir/scan-history.json"
    if (Test-Path $historyFile) {
        $history = Get-Content -Raw $historyFile | ConvertFrom-Json
    } else {
        $history = [PSCustomObject]@{ scans = @() }
    }
    $history.scans = @($history.scans) + @($scanEntry)
    if ($history.scans.Count -gt 1000) { $history.scans = $history.scans[-1000..-1] }
    $tmpFile = "$historyFile.tmp"
    $history | ConvertTo-Json -Depth 10 | Set-Content $tmpFile -Encoding UTF8
    Move-Item $tmpFile $historyFile -Force

    Write-Host ""
    Write-Host "[PASS] CodeQL scan passed" -ForegroundColor Green
    exit 0

} finally {
    # Clean up orphaned parallel analysis jobs
    Get-Job -Name "codeql-*" -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
    Get-Job -Name "codeql-*" -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    # Remove temporary global.json created for SDK compatibility
    if ($tempGlobalJson -and (Test-Path 'global.json')) {
        Remove-Item 'global.json' -Force -ErrorAction SilentlyContinue
    }
    # Remove temporary .csproj created for buildless C# scanning
    if ($tempCsproj -and (Test-Path $tempCsproj)) {
        Remove-Item $tempCsproj -Force -ErrorAction SilentlyContinue
    }
    # Remove temporary build script created for buildless C++ scanning
    if ($tempCppBuild -and (Test-Path $tempCppBuild)) {
        Remove-Item $tempCppBuild -Force -ErrorAction SilentlyContinue
    }
    $script:lockStream.Close()
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
