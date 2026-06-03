---
name: codeql-sdk-install
description: "Install missing language SDKs required for CodeQL scanning. Detects which build tools are absent, selects CodeQL-compatible versions, and installs them with user consent. Supports .NET SDK, JDK, Go toolchain, and C/C++ compilers on Windows, macOS, and Linux."
argument-hint: "Describe the issue: missing SDK, dotnet not found, javac not found, go not found, no compiler, or which language SDK to install"
user-invocable: true
disable-model-invocation: false
---

# Language SDK Install Skill

Install missing language SDKs that CodeQL requires for compiled-language scanning. Detects absent build tools, selects CodeQL-compatible versions, obtains user consent, and performs the installation.

## When to Use

- Pre-build validation prints `[FAIL] dotnet CLI not found`, `[FAIL] JDK not found`, `[FAIL] Go toolchain not found`, or `[WARN] No C/C++ compiler found` — the language is removed from the scan
- Pre-flight (step 4) warns that a build tool is missing for detected source files
- User asks "install the SDK for me" or "fix missing build tools"
- User asks why a compiled-language scan failed and the root cause is a missing SDK
- User runs Prompt 36 ("Install Missing SDKs")
- Agent detects missing SDKs during setup (step 4 pre-flight) and offers to install

## Consent Requirement

**Always ask the user before installing.** SDK installation is a system-level change that modifies PATH, downloads binaries, and may require elevated privileges. Present what will be installed, which version, and the install method before proceeding.

Example consent prompt:

```
The following SDKs are missing for CodeQL scanning:

  1. .NET SDK 9.0 (via dotnet-install.ps1)
  2. JDK 21 (via winget install EclipseAdoptium.Temurin.21.JDK)

Install these now? [Y/N]
```

If the user declines, print the manual install URLs and stop.

## Version Selection

Install the **highest version known to be compatible with CodeQL's extractors**. CodeQL's C# extractor lags behind the latest .NET SDK, so install the newest *supported* SDK, not necessarily the newest *available* SDK.

### Compatible Versions

| Language | Recommended Version | Rationale |
|---|---|---|
| C# (.NET) | .NET SDK 9.x (latest patch) | CodeQL's C# extractor reliably supports SDK 8.x and 9.x. SDK 10+ may require the SDK-pinning workaround from `codeql-csharp-sdk-compat`. Install 9.x as the safe default; install 8.x as fallback if 9.x is unavailable. |
| Java | JDK 21 LTS (Adoptium Temurin) | CodeQL supports JDK 11+. JDK 21 is the current LTS with broad ecosystem compatibility. |
| Go | Latest stable release | CodeQL's Go extractor tracks Go releases closely. Install the latest stable version. |
| C/C++ | Platform default compiler | Too varied for a single recommendation -- see platform-specific section below. |

## Install Methods by Platform

### Windows

| Language | Primary Method | Fallback |
|---|---|---|
| C# (.NET) | `dotnet-install.ps1` (official Microsoft script) | `winget install Microsoft.DotNet.SDK.9` |
| Java (JDK) | `winget install EclipseAdoptium.Temurin.21.JDK` | Direct download from https://adoptium.net |
| Go | `winget install GoLang.Go` | Direct download from https://go.dev/dl |
| C/C++ | `winget install Microsoft.VisualStudio.2022.BuildTools` (with C++ workload) | Direct download from https://visualstudio.microsoft.com/downloads/ |

### macOS

| Language | Primary Method | Fallback |
|---|---|---|
| C# (.NET) | `dotnet-install.sh` (official Microsoft script) | `brew install dotnet-sdk` |
| Java (JDK) | `brew install --cask temurin@21` | Direct download from https://adoptium.net |
| Go | `brew install go` | Direct download from https://go.dev/dl |
| C/C++ | `xcode-select --install` (Xcode Command Line Tools) | Full Xcode from App Store |

### Linux

| Language | Primary Method | Fallback |
|---|---|---|
| C# (.NET) | `dotnet-install.sh` (official Microsoft script) | Package manager (`apt`, `dnf`, `zypper`) |
| Java (JDK) | `apt install temurin-21-jdk` (Adoptium APT repo) | Direct download from https://adoptium.net |
| Go | Direct download from https://go.dev/dl + extract to `/usr/local` | `snap install go --classic` |
| C/C++ | `apt install build-essential` or `dnf groupinstall "Development Tools"` | Manual gcc/clang install |

## Install Workflows

### .NET SDK (C#)

The official `dotnet-install` script is preferred because it works without admin rights, does not require `winget`, and allows version targeting.

**Windows:**

```powershell
# Download the official installer script
$installScript = Join-Path $env:TEMP 'dotnet-install.ps1'
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript

# Verify the integrity of the downloaded script
$expectedHash = '<expected-hash-value>'
$actualHash = Get-FileHash -Path $installScript -Algorithm SHA256 | Select-Object -ExpandProperty Hash

if ($actualHash -ne $expectedHash) {
    Write-Host "[FAIL] Integrity check failed for dotnet-install.ps1" -ForegroundColor Red
    Write-Host "  Please download the script manually from: https://dot.net/v1/dotnet-install.ps1" -ForegroundColor Yellow
    exit 1
}

# Install .NET SDK 9.x (latest patch) to user-local directory
& $installScript -Channel 9.0 -InstallDir (Join-Path $env:LOCALAPPDATA 'dotnet')

# Add to current session PATH
$dotnetDir = Join-Path $env:LOCALAPPDATA 'dotnet'
if ($env:PATH -notmatch [regex]::Escape($dotnetDir)) {
    $env:PATH = "$dotnetDir;$env:PATH"
}

# Verify
dotnet --version
```

**macOS/Linux:**

```bash
curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 9.0
```

**Post-install verification:**

```powershell
$ver = & dotnet --version 2>$null
if ($ver) {
    Write-Host "[PASS] .NET SDK $ver installed" -ForegroundColor Green
} else {
    Write-Host "[FAIL] .NET SDK installation failed" -ForegroundColor Red
    Write-Host "  Install manually from: https://dot.net/download" -ForegroundColor Yellow
}
```

### JDK (Java/Kotlin)

**Windows (winget):**

```powershell
winget install --id EclipseAdoptium.Temurin.21.JDK --accept-source-agreements --accept-package-agreements
```

**Windows (no winget -- direct download):**

```powershell
# Download Adoptium JDK 21 MSI
$jdkUrl = 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse'
$jdkInstaller = Join-Path $env:TEMP 'temurin-21-jdk.msi'
Invoke-WebRequest -Uri $jdkUrl -OutFile $jdkInstaller
Start-Process msiexec.exe -ArgumentList "/i `"$jdkInstaller`" /quiet /norestart" -Wait
```

**Post-install verification:**

```powershell
$javacVer = & javac -version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[PASS] JDK installed: $javacVer" -ForegroundColor Green
} else {
    Write-Host "[FAIL] JDK installation failed" -ForegroundColor Red
    Write-Host "  Install manually from: https://adoptium.net" -ForegroundColor Yellow
}
```

**JAVA_HOME:** After installation, verify `JAVA_HOME` is set. If not, set it to the JDK installation directory.

### Go

**Windows (winget):**

```powershell
winget install --id GoLang.Go --accept-source-agreements --accept-package-agreements
```

**Post-install verification:**

```powershell
$goVer = & go version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[PASS] Go installed: $goVer" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Go installation failed" -ForegroundColor Red
    Write-Host "  Install manually from: https://go.dev/dl" -ForegroundColor Yellow
}
```

### C/C++ (Windows)

C++ build tools on Windows require Visual Studio Build Tools with the C++ workload. This is a large install (~2-5 GB) and typically requires admin rights.

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --wait" --accept-source-agreements --accept-package-agreements
```

After installation, the user must open "Developer Command Prompt" or configure the VS environment to make `cl.exe` available on PATH. Alternatively, install MinGW for `gcc`:

```powershell
winget install --id MSYS2.MSYS2 --accept-source-agreements --accept-package-agreements
# Then from MSYS2: pacman -S mingw-w64-x86_64-gcc
```

**Note:** C++ build tool installation is complex and environment-specific. If the primary method fails, provide the manual URL and stop rather than attempting multiple strategies.

## Corporate Environment Handling

Corporate machines may restrict software installation. The skill must handle these gracefully:

1. **No admin rights:** `dotnet-install.ps1` and `dotnet-install.sh` install to user-local directories by default (no admin needed). JDK and Go `winget` installs may require admin.
2. **No winget:** Fall back to direct download methods. Check `Get-Command winget -ErrorAction SilentlyContinue` before using it.
3. **Proxy/firewall:** If downloads fail, print the direct URL so the user can download manually or request IT approval.
4. **Package manager restrictions:** If `winget` or `brew` is blocked, print manual install instructions with URLs.

**Fallback pattern for all languages:**

```powershell
Write-Host "[FAIL] Automated installation failed" -ForegroundColor Red
Write-Host "  This may be due to restricted permissions or network policy." -ForegroundColor Yellow
Write-Host "  Install manually:" -ForegroundColor Yellow
Write-Host "    <manual-install-url>" -ForegroundColor Cyan
Write-Host "  Or contact your IT team to request installation of <tool-name>." -ForegroundColor Yellow
```

## Detection After Install

After any SDK install, re-run detection to verify:

```powershell
$results = @()
if (Get-Command dotnet -ErrorAction SilentlyContinue) { $results += "[PASS] dotnet: $(& dotnet --version 2>$null)" }
if (Get-Command javac -ErrorAction SilentlyContinue)  { $results += "[PASS] javac: $(& javac -version 2>&1)" }
if (Get-Command go -ErrorAction SilentlyContinue)     { $results += "[PASS] go: $(& go version 2>$null)" }
$hasCpp = (Get-Command cl -ErrorAction SilentlyContinue) -or (Get-Command gcc -ErrorAction SilentlyContinue) -or (Get-Command clang -ErrorAction SilentlyContinue)
if ($hasCpp) { $results += "[PASS] C/C++ compiler found" }
$results | ForEach-Object { Write-Host $_ -ForegroundColor Green }
```

**Session restart caveat:** Some installers (especially `winget` and MSI) update the system PATH but the current terminal session may not reflect the change. If verification fails immediately after install, advise:

```
[WARN] <tool> was installed but is not yet available in this session.
  Restart VS Code or open a new terminal, then retry the scan.
```

## Interaction with Other Skills

- **codeql-build-prereqs**: The prereqs skill *detects* missing tools and prints warnings. This skill *installs* them. After installation, the prereqs flow continues normally.
- **codeql-csharp-sdk-compat**: If .NET SDK 9.x is installed but the project requires SDK pinning for CodeQL compatibility, the SDK compat skill handles that separately.
- **codeql-cli-upgrade**: Similar pattern (detect, download, install, verify) but for CodeQL CLI, not language SDKs.
- **codeql-troubleshoot**: If a scan fails due to missing SDK after the user declined installation, troubleshooting points back to this skill.

## Constraints

- **Never install without user consent.** Always present what will be installed and ask first.
- **Never modify project files** (`.csproj`, `pom.xml`, `go.mod`, etc.) -- this skill installs system-level tools only.
- **Prefer user-local installs** over system-wide when possible (e.g., `dotnet-install.ps1` to `%LOCALAPPDATA%\dotnet`).
- **One language at a time.** If multiple SDKs are missing, install sequentially and verify each before proceeding to the next.
- **Fail gracefully.** If an install fails, print the manual URL and continue to the next language. Do not abort the entire workflow.
- **Do not retry failed installs.** If a method fails, print the fallback URL and move on.
