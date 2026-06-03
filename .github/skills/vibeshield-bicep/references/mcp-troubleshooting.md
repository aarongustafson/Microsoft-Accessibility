# MCP Troubleshooting Reference

Load this reference when the Bicep MCP server (`get_bicep_best_practices`, `list_avm_metadata`) or the Azure MCP server (`get_bestpractices`) is unavailable, returns errors, or appears not to be attached. This document walks the agent through diagnosing and restoring MCP connectivity across all supported runtimes so Bicep generation can proceed.

## Why MCP availability is non-negotiable

Without the Bicep MCP server (AVM metadata, Bicep best practices) and the Azure MCP server (WAF guidance), the vibeshield-bicep agent **cannot produce compliant infrastructure**. The templates will drift from AVM-backed defaults, miss WAF pillar alignment, and require many painful validation cycles to claw back compliance — if it is reachable at all.

**Stop-work rule:** Refuse to proceed with Bicep creation until MCP is working. Stand down, tell the user plainly that MCP is required, and help them restore it using the steps below before any code is written.

## Step 1 — Identify the runtime

Ask the user (or infer from the invocation context) which runtime they are in. The fix is runtime-specific:

- **GitHub Copilot CLI** → see Step 2A. **This is the most common cause of missing MCP servers.**
- **VS Code GitHub Copilot Chat** → see Step 2B.
- **Claude Code** → see Step 2C.

## Step 2A — GitHub Copilot CLI: fix the working directory

Copilot CLI loads MCP servers from a `.mcp.json` file in **the current working directory** at the moment the CLI is launched. If the user launched `copilot` from their home directory, a parent folder, or any path that is not the project root, the MCP servers will silently be unavailable — this is almost always the root cause.

Walk the user through this in user-friendly language:

1. **Find out where they are now.** Ask them to run `pwd` in the Copilot CLI session. Read the path back to them.
2. **Find the project root.** The project root is the directory that contains **all** of these markers:
   - `.mcp.json` — the MCP configuration file (authoritative marker; if this file is missing, MCP will not load even from the correct directory — skip to Step 3 below)
   - `.github/` — holds deployed agent specs, skills, and hooks
   - `.vibeshield/` — holds VibeShield package support scripts and agent tests
   - `.git/` — the repository root

   If the user is unsure where they created the project, ask: "When you first set up this project, which folder did you run the installer or `git clone` in?" That folder is the project root. If they still can't locate it, have them run one of the following from any shell to search for `.mcp.json`:
   - PowerShell: `Get-ChildItem -Path $HOME -Filter .mcp.json -Recurse -Depth 6 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Directory`
   - Bash / WSL: `find ~ -maxdepth 6 -name .mcp.json 2>/dev/null`
3. **Exit and re-launch Copilot CLI from the project root.** MCP servers are loaded once at CLI startup — changing directory *inside* an existing session will **not** attach the servers. The user must:
   1. Exit the current Copilot CLI session (`/exit` or Ctrl+C).
   2. `cd` into the project root directory identified in Step 2.
   3. Launch `copilot` again from that directory.
4. **Verify.** Once re-launched, confirm MCP is attached before resuming work — e.g., call `get_bicep_best_practices` and `get_bestpractices` to ensure both the Bicep MCP server and the Azure MCP server are responding correctly. If either call fails, continue to Step 3.
5. **Make it sticky (optional but recommended).** Offer to help the user set the project root as their default working directory for Copilot CLI so this does not recur — either by creating a shell alias/function that `cd`s into the project root before launching `copilot`, or by configuring their terminal profile to start in the project directory. Ask before making any changes to their shell configuration.

## Step 2A.1 — Copilot CLI: tool installed but cannot launch it (PATH gap)

This is the single most common post-install failure for **GitHub Copilot CLI** users. It does **not** affect VS Code Copilot Chat — VS Code uses the `ms-azuretools.vscode-bicep` and `ms-azuretools.vscode-azure-mcp-server` extensions, which are independent of the dotnet global-tool shim PATH chain. If the user is in VS Code, skip this section and go to Step 2B.

Symptom: Copilot CLI reports the MCP server failed to start, or `azmcp` / `Azure.Bicep.McpServer` is "not found" even though `Install-McpConfig.ps1` reported the tool as INSTALLED or UPDATED. The tool is on disk; the shell just cannot find it.

Diagnostic flow (run all three in the affected shell):

1. **Confirm the package is installed:**
   ```
   dotnet tool list -g
   ```
   If `azure.mcp` and/or `Azure.Bicep.McpServer` appear in the output, the install succeeded.

2. **Confirm the shim is unreachable:**
   ```
   Get-Command azmcp -ErrorAction SilentlyContinue
   ```
   If this returns `$null`, the shim is on disk but not on PATH.

3. **Confirm the per-user tools directory is missing from PATH:**
   ```
   $env:Path -split [IO.Path]::PathSeparator | Where-Object { $_ -like '*\.dotnet\tools' }
   ```
   If this returns nothing, `%USERPROFILE%\.dotnet\tools` is not on the current-process PATH.

Remediation:

1. Re-run `Install-McpConfig.ps1`. The script now persists the per-user tools directory to the User-scope PATH via `Set-DotNetUserPath` and prepends it to the current-process PATH.
2. **Exit and launch a brand-new terminal.** PATH changes written to the User-scope registry are not visible to already-running shells; you must open a fresh terminal session for them to take effect.
3. Re-test in the new terminal:
   ```
   Get-Command azmcp
   Get-Command Azure.Bicep.McpServer
   ```
   Both should resolve to a path under `%USERPROFILE%\.dotnet\tools`.
4. Re-launch Copilot CLI from the project root (Step 2A) and verify MCP attaches.

## Step 2B — VS Code GitHub Copilot Chat: verify extensions

Verify the user has the VS Code extensions:
- `ms-azuretools.vscode-bicep` (Bicep language server and MCP tools)
- `ms-azuretools.vscode-azure-mcp-server` (Azure MCP Server)

Install via:
```
code --install-extension ms-azuretools.vscode-bicep
code --install-extension ms-azuretools.vscode-azure-mcp-server
```

After installation, reload the VS Code window. Confirm the workspace is opened at the project root (same markers as Step 2A: `.mcp.json`, `.github/`, `.vibeshield/`, `.git/`).

## Step 2C — Claude Code: verify MCP config

Claude Code reads MCP server configuration from `.mcp.json` at the workspace root or from user-scope config. Confirm the user launched Claude Code at the project root (markers from Step 2A) and that `.mcp.json` is present and valid. If the user configured MCP servers globally in `~/.claude/` or similar, verify those entries are correct and the server processes start without error.

## Step 3 — `.mcp.json` is missing or malformed

If the user is in the correct directory but `.mcp.json` does not exist or lacks the `bicep_mcp` / `azure_mcp` entries, re-run the skill installer to restore it:

```
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-McpConfig.ps1
```

**PowerShell requirement:** `Install-McpConfig.ps1` requires PowerShell 7+. Run it with `pwsh`, not Windows PowerShell (`powershell.exe`). If the script fails to load with a parse error mentioning `??`, the shell is too old; install PowerShell 7 and re-run the command with `pwsh`.

This is idempotent — it will create `.mcp.json` if missing, add only the missing server entries if partially configured, and skip if already correct. The script also installs the underlying .NET global tools (`Azure.Bicep.McpServer`, `azure.mcp`), validates that their shims (`azmcp`, `Azure.Bicep.McpServer`) actually resolve on PATH after install, and **exits non-zero** with a `FAILED:` summary block when either the install or the shim resolution fails. **Read the `FAILED:` block at the end of the script's output before re-running** — it names the specific package, exit code where available, remediation path, and (for classified `dotnet tool` failures) the sidecar log path when one is emitted. The raw `dotnet` output is no longer splatted into the warning for sidecar-backed failures; see Step 3.5 for logs. The most common follow-up failures are covered in Steps 3.1–3.5 below.

> **Runtime impact note:** Failures from `Install-McpConfig.ps1` impact **GitHub Copilot CLI** users almost exclusively. **VS Code Copilot Chat** continues to work normally because its Bicep and Azure MCP capabilities come from the `ms-azuretools.vscode-bicep` and `ms-azuretools.vscode-azure-mcp-server` extensions, which are installed and resolved by VS Code itself and do not depend on the dotnet global-tools / shim PATH chain.

## Step 3.1 — `Install-McpConfig.ps1` exited non-zero

When the script fails it prints a block like:

```text
  FAILED: Install-McpConfig encountered N unrecoverable failure(s):
    - <message 1>
    - <message 2>
    See skills/vibeshield-bicep/references/mcp-troubleshooting.md for step-by-step remediation.
```

Match each line to its remediation:

- **`Selected .NET SDK is X but Azure MCP and Bicep MCP global tools require .NET SDK N.x because their NuGet packages target netN.0. Install .NET SDK N, ensure no global.json pins an older SDK, open a new terminal, and re-run. Installed SDKs:\n<list>`** — the preflight detected the selected SDK is too old before any install was attempted. Follow **Step 3.1.1**. Do **not** delete tool-store or NuGet cache directories for this case.
- **`NuGet service index unreachable for source <url> while installing '<pkg>'. (exit code N). This is a NuGet configuration issue... Log: <path>`** — a configured NuGet source is stale or unreachable (category: `ServiceIndexUnreachable`). This is a NuGet feed configuration problem, **not** an authentication problem; ignore `[CredentialProvider]` chatter in the sidecar log. Follow **Step 3.1.3**.
- **`TFM mismatch installing '<pkg>': package targets netN.0 but the selected .NET SDK is older. (exit code N). Install .NET SDK N...`** — the classifier captured the required SDK major from the actual `dotnet` error text (category: `TfmMismatch`). See **Step 3.1.1**. Do **not** delete tool-store or NuGet cache directories for this case.
- **`TFM mismatch installing '<pkg>': selected .NET SDK is below required major N (packages target netN.0). Install .NET SDK N, ensure no global.json pins an older SDK, and re-run.`** — the `DotnetToolSettings.xml` disambiguator detected that the selected SDK is too old for the MCP packages. See **Step 3.1.1**.
- **`Orphan-shim repair of '<pkg>' threw during cleanup: <exception>. Original install error: <dotnet output>. Shim path(s) under '<toolsDir>': '<cmd>.exe', '<cmd>.cmd', '<cmd>.ps1'. Manual remediation: ...`** — the conflicts repair helper threw before it could prove ownership (category: `Conflicts`). Follow **Step 3.4**.
- **`Orphan-shim repair of '<pkg>' ABORTED -- 'dotnet tool list -g' could not be queried, so ownership of command(s) <cmd[, cmd...]> cannot be confirmed and we will not delete shim files we may not own. Shim files under '<toolsDir>': <shim-file-list>. Manual remediation: ...`** — the conflicts repair failed closed because ownership was unverifiable (category: `Conflicts`). Follow **Step 3.4**.
- **`Orphan-shim repair of '<pkg>' ABORTED -- command '<cmd>' is owned by registered tool '<owner>' (a real cross-tool conflict, not an orphan). Shim path(s) under '<toolsDir>': '<cmd>.exe', '<cmd>.cmd', '<cmd>.ps1'. Manual remediation: ...`** — another registered tool owns the command (category: `Conflicts`). Follow **Step 3.4**.
- **`Repair of '<pkg>' failed after orphan-shim cleanup (exit code N). <embedded summary> <remediation> ... Log: <path>`** — the orphan cleanup ran, but the retry failed. Match the embedded summary text: if it starts with `NuGet service index unreachable`, follow **Step 3.1.3**; if it starts with `TFM mismatch installing`, follow **Step 3.1.1**; otherwise inspect the sidecar log from **Step 3.5**.
- **`Repair of '<pkg>' failed after deep clean (exit code N). <embedded summary> <remediation> ... Log: <path>`** — the selected SDK was new enough, the script entered the `DotnetToolSettings.xml` deep-clean repair arm, and the retry failed. Follow **Step 3.1.2**, then match the embedded summary text as above and inspect the log from **Step 3.5**.
- **`MCP shim '<shim>' for package '<pkg>' is unresolved on PATH after install. Add '<dir>' to PATH or reinstall.`** — the package installed, but Copilot CLI cannot resolve the shim. Follow **Step 2A.1**.
- **`Unrecognized failure installing '<pkg>':\n<tail diagnostic lines> (exit code N). Inspect the sidecar log... Log: <path>`** — the classifier did not match a known category. Inspect the sidecar log from **Step 3.5** and fix the underlying `dotnet tool` / NuGet error.
- **`Exception during install of '<pkg>': ...`**, **`Exception during update of '<pkg>': ...`**, or **`Unhandled exception in Install-McpConfig: ...`** — the script itself hit an exception outside the classified `dotnet tool` failure path. Read the exception text, re-run with `-Verbose`, and escalate if it is not clearly environmental.

The classifier one-line summaries **`Shim conflict installing '<pkg>': command '<cmd>' is already claimed by an existing shim under '~/.dotnet/tools/'...`** (category: `Conflicts`) and **`Corrupt .NET global tool cache for '<pkg>': 'DotnetToolSettings.xml' is missing...`** (category: `DotnetToolSettingsMissing`) can appear inside WARNING / retry text, but they are not emitted as bare top-level `FAILED:` bullets. Use the top-level shapes above to route remediation.

Message verbs to know:

- **`REPAIR`** — the script is about to clean a known recoverable state and retry once.
- **`REPAIRED`** — the retry succeeded; no manual cleanup is needed for that package.
- **`ABORTED`** — the orphan-shim conflicts arm refused to delete shim files because ownership could not be proven or a different registered tool owns the command. This is terminal for that run; follow Step 3.4.
- **`SKIPPED`** — the defensive orphan-shim cleanup inside the `DotnetToolSettings.xml` deep-clean arm refused to delete shim files, but the script still proceeds with reinstall because shim cleanup is advisory in that arm.
- **`SKIPPED: <serverName> (already configured)`** — the `.mcp.json` server entry was already correct. This is informational success, not a defensive-cleanup warning.

### Optional sanity check for `DotnetToolSettings.xml not found`

The script now performs the SDK-major preflight and the `DotnetToolSettings.xml` disambiguation itself, so the WARNING normally tells you directly whether to follow Step 3.1.1 or Step 3.1.2. If the machine state looks surprising, verify manually with `dotnet --version` before deleting anything:

- `dotnet --version` reports `< 10.0` → **TFM mismatch** → see Step 3.1.1 (most common).
- `dotnet --version` reports `>= 10.0` → genuine cache corruption (rare; usually antivirus, disk error, or manual edit) → see Step 3.1.2.

Skipping this check and running the Step 3.1.2 cache-wipe commands when the cause is actually TFM mismatch will not help — the next install attempt will pull the same `net10.0`-only package and fail identically.

## Step 3.1.1 — TFM mismatch (`DotnetToolSettings.xml not found` and your selected SDK is older than .NET 10)

This is the dominant case in the wild and the one behind ADO bug #512080. The Azure MCP NuGet package (`azure.mcp`) and the Bicep MCP NuGet package (`Azure.Bicep.McpServer`) ship `tools/net10.0/any/DotnetToolSettings.xml` **only** — they do not include net6/net7/net8/net9 tool assets. .NET SDK 9 (and earlier) cannot extract the `net10.0` tool layout, NuGet writes a partial state, and `dotnet tool install` surfaces the same `DotnetToolSettings.xml not found` error you would see for genuine cache corruption. **It is not corrupt cache. It is a TargetFramework mismatch.** Wiping `~/.dotnet/tools/.store/<pkg>` and `~/.nuget/packages/<pkg>` will not help — the next install attempt will pull the same `net10.0`-only package and fail identically.

Diagnostic:

```
dotnet --version       # the SDK actually selected by global.json + PATH resolution
dotnet --list-sdks     # ALL installed SDKs on this machine
```

If `dotnet --version` reports anything below `10.0`, this step applies. **Both commands matter** — `--version` returns the SDK selected for the current directory (which `global.json` can pin to an older SDK even when SDK 10 is installed), while `--list-sdks` returns every SDK on disk.

Remediation hierarchy (try in order):

1. **Install the SDK major named by the WARNING.** Today the MCP package requirements are .NET SDK 10, but the classifier may tell you to install a later major if the package's actual error text says it targets `net12.0` or another future TFM. Download from https://dot.net/. If `dotnet --list-sdks` already shows that major, skip to step 2.
2. **Check for a `global.json` upstream of your project.** Walk up from the project directory looking for `global.json` files; any of them can pin `sdk.version` to an older SDK even when the required SDK is installed. Update the `version` field to the required major, or remove the file if it is no longer needed.
3. **Open a new terminal.** PATH and SDK selection caches do not refresh inside an already-running shell after a new SDK install.
4. **Re-run the installer:**
   ```
   pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-McpConfig.ps1
   ```

**Do NOT run the cache-wipe commands from Step 3.1.2** (`Remove-Item ...\.store\<pkg>`, `Remove-Item ...\.nuget\packages\<pkg>`) for this case. Those commands are correct for genuine cache corruption on a compatible SDK; on an older SDK they will succeed but the next `dotnet tool install` will fail with the same `DotnetToolSettings.xml not found` message, leaving you exactly where you started. `Install-McpConfig.ps1` itself now performs this SDK-version check before entering the deep-clean repair branch and emits the actionable SDK-install message instead.

## Step 3.1.2 — Corrupt tool cache (rare; `DotnetToolSettings.xml not found` despite SDK meeting required major)

**This step applies only when the selected .NET SDK is at or above the major version required by the MCP packages** (currently .NET SDK 10, because both `Azure.Bicep.McpServer` and `azure.mcp` ship `tools/net10.0/...` only). If `dotnet --version` reports an SDK older than the required major, the symptom is identical but the cause is different — see **Step 3.1.1** instead, and do **not** run the cache-wipe steps below.

This case is **rare** in the wild. When the extracted package state under `~/.dotnet/tools/.store/<pkg>` and/or the local NuGet package cache under `~/.nuget/packages/<pkg>` is genuinely partially written or corrupted, the usual culprits are antivirus quarantining the extracted file mid-write, an underlying disk error, or a manual edit/cleanup gone wrong. A plain `dotnet tool uninstall` + reinstall does **not** fix this — `uninstall` removes only the registration, not the cached files on disk.

As **defense-in-depth**, `Install-McpConfig.ps1`'s repair branch automatically removes both directories (and their lowercase-folded variants) before retrying the install whenever it sees `DotnetToolSettings.xml not found` on an SDK that meets the required major. It prints `REPAIR: Detected corrupt global tool state for <pkg> - attempting deep clean + reinstall.` before doing this work. It also tries to remove orphan shim files defensively so the deep-clean does not manufacture the conflicts failure described in Step 3.4. A `SKIPPED` warning from that defensive shim cleanup is advisory; the reinstall still proceeds. The vast majority of users will never need the manual steps below — they exist for the residual case where the automatic repair still fails (e.g., antivirus is locking the file, the disk is failing, or the retry hits a different category such as an unreachable feed). If the retry is classified as `DotnetToolSettingsMissing` again, the final WARNING / `FAILED:` bullet suppresses the extra manual-remediation sentence because the prior deep-clean hint still applies.

If the script's automatic repair already ran and the second attempt still failed, complete the cleanup manually.

On Windows:

```
Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\.store\<pkg>" -Recurse -Force
Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\.store\<pkg-lowercase>" -Recurse -Force
Remove-Item -LiteralPath "$env:USERPROFILE\.nuget\packages\<pkg>" -Recurse -Force
Remove-Item -LiteralPath "$env:USERPROFILE\.nuget\packages\<pkg-lowercase>" -Recurse -Force
```

On Linux/macOS (PowerShell 7 reads `$env:HOME`, which is what these paths
resolve against; `$HOME` is ReadOnly so the script uses `$env:HOME`):

```
Remove-Item -LiteralPath "$env:HOME/.dotnet/tools/.store/<pkg>" -Recurse -Force
Remove-Item -LiteralPath "$env:HOME/.dotnet/tools/.store/<pkg-lowercase>" -Recurse -Force
Remove-Item -LiteralPath "$env:HOME/.nuget/packages/<pkg>" -Recurse -Force
Remove-Item -LiteralPath "$env:HOME/.nuget/packages/<pkg-lowercase>" -Recurse -Force
```

Then:

1. Optionally clear the NuGet HTTP cache (slower, but rules out a poisoned download):
   ```
   dotnet nuget locals http-cache --clear
   ```
2. Re-run the install directly to confirm it works in isolation:
   ```
   dotnet tool install -g <pkg>
   ```
3. Re-run `Install-McpConfig.ps1` to restore the full configuration and re-validate the shims.

## Step 3.1.3 — NuGet service index unreachable (`ServiceIndexUnreachable`)

This is the ADO bug #525806 surface. The actionable line is:

```
NuGet service index unreachable for source <url> while installing '<pkg>'.
```

Treat this as a stale or unreachable NuGet feed entry, **not** an auth problem. On real machines the raw `dotnet` output may include many `[NuGet Manager] [Info] [CredentialProvider]...` lines; those lines are deliberately moved to the sidecar log and should not send you down an authentication rabbit hole. Fix the feed that owns `<url>`.

Diagnostics:

```
dotnet nuget list source
```

Then find the `nuget.config` file that contributes the stale source. NuGet layers sources from multiple scopes:

1. Project / repo configs found by walking up from the current directory (`nuget.config`, `NuGet.config`, or `.nuget\NuGet.Config`).
2. User-scope config under the profile (for example `%APPDATA%\NuGet\NuGet.Config` on Windows, `~/.nuget/NuGet/NuGet.Config` on Linux/macOS).
3. Machine-scope config from the .NET / NuGet installation.

Remediation:

1. If the source is no longer needed, remove it from the config that declares it:
   ```
   dotnet nuget remove source <source-name>
   ```
   If there are duplicate source names in different scopes, edit the specific `nuget.config` file directly.
2. If the source is still needed, fix the URL or network access so the service index is reachable.
3. Re-run:
   ```
   pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-McpConfig.ps1
   ```

## Step 3.2 — Architecture mismatch on pre-existing .NET

If the user has a pre-existing .NET SDK whose architecture does not match the OS (most commonly an x64 SDK on an Arm64 Windows host), `dotnet tool install` will fail in confusing ways — bad RIDs, missing native assets, or shims that crash on launch.

Diagnostic:

```
dotnet --info | Select-String 'Architecture|RID'
[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
```

If the SDK's `Architecture` / RID does not match the OS architecture (e.g., SDK reports `x64` on an `Arm64` host), you have a mismatch.

Remediation: `Install-VibeShieldDotNet.ps1` now detects this automatically and forces a per-user reinstall of the correct-architecture SDK under `%LOCALAPPDATA%\Microsoft\dotnet`. If the script did not catch your case:

1. Re-run the installer with `-Verbose` and inspect the architecture detection output.
2. If it still picks the wrong arch, uninstall the wrong-arch SDK from **Settings > Apps > Installed apps** (or `appwiz.cpl`) first, then re-run the installer.

## Step 3.3 — Wrong dotnet wins on PATH (Machine-scope shadowing)

After `Install-VibeShieldDotNet.ps1` installs the per-user SDK, a Machine-scope `C:\Program Files\dotnet` entry that comes earlier on PATH can still win — `dotnet` then resolves to the wrong (often older or wrong-arch) installation, and global tool installs land in the wrong store.

Diagnostic:

```
(Get-Command dotnet).Source
```

If this returns `C:\Program Files\dotnet\dotnet.exe` rather than `%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe` after the installer ran, the orchestrator's PATH precedence did not take effect (or was overridden in the user's PowerShell `$PROFILE` or shell rc file).

Remediation (try in order):

1. Prepend the per-user SDK directory to the current-process PATH and retry:
   ```
   $env:Path = "$env:LOCALAPPDATA\Microsoft\dotnet;$env:Path"
   (Get-Command dotnet).Source   # verify
   ```
2. Open a **fresh** terminal after `Install-McpConfig.ps1` runs (registry-scope PATH changes are not visible to existing shells).
3. If a user `$PROFILE` is re-prepending the Machine-scope dotnet path, edit the profile to remove that line.
4. As a last resort, remove the Machine-scope `C:\Program Files\dotnet` entry from System PATH (requires admin) and reboot.

## Step 3.4 — Orphan-shim conflicts (`Conflicts`)

Most users will not need this section. When `dotnet tool install/update` fails with:

```text
conflicts with an existing command from another tool
```

`Install-McpConfig.ps1` now treats it as an orphan-shim repair case. It verifies shim ownership with `dotnet tool list -g`, deletes only canonical shim filenames under `~/.dotnet/tools/`, removes the matching `.store` and NuGet package cache directories, and retries once. A normal self-heal looks like:

```text
REPAIR: Detected orphan shim conflict for <pkg> (command '<cmd>') - attempting shim cleanup + cache deep clean + reinstall.
REPAIRED: <pkg>
```

If you see `REPAIRED`, stop; do not manually delete anything.

If the retry is classified as `Conflicts` again, the final WARNING / `FAILED:` bullet suppresses the extra manual-remediation sentence because the prior conflict hint still applies.

Manual action is only needed for these residual cases:

- **`Orphan-shim repair of '<pkg>' ABORTED -- command '<cmd>' is owned by registered tool '<owner>'`** — this is a real cross-tool conflict, not an orphan. Do not delete another tool's shim. Choose one:
  1. Remove the other tool:
     ```
     dotnet tool uninstall -g <owner>
     ```
  2. Or keep both tools but rename / reconfigure one of them if the tool supports a different command name.
  3. Re-run `Install-McpConfig.ps1`.
- **`Orphan-shim repair of '<pkg>' ABORTED -- 'dotnet tool list -g' could not be queried, so ownership of command(s) <cmd[, cmd...]> cannot be confirmed... Shim files under '<toolsDir>': <shim-file-list>. Manual remediation: ...`** — the script could not prove ownership, so it failed closed (internally this is the `<unverifiable>` owner sentinel). The trailing shim-file list names every candidate shim filename the script refused to delete. Run the ownership check yourself:
  ```
  dotnet tool list -g
  ```
  If the command is listed under a different package, resolve it as a real cross-tool conflict. If no registered tool owns the command, the shim is orphaned and you may delete only the specific shim files named by the WARNING.
- **`Repair of '<pkg>' failed after orphan-shim cleanup (exit code N)... Log: <path>`** — the orphan cleanup ran, but the retry hit another failure. Match the embedded summary text: if it starts with `NuGet service index unreachable`, follow Step 3.1.3; if it starts with `TFM mismatch installing`, follow Step 3.1.1; otherwise inspect the sidecar log from Step 3.5.

Manual orphan-shim cleanup, when ownership is confirmed safe:

1. Identify the command from the WARNING, usually `azmcp` for `azure.mcp` or `Azure.Bicep.McpServer` for `Azure.Bicep.McpServer`.
2. Confirm no other registered package owns it:
   ```
   dotnet tool list -g
   ```
3. Delete only the canonical shim filenames under the per-user tools directory. On Windows:
   ```
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\<cmd>.exe" -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\<cmd>.cmd" -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\<cmd>.ps1" -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\<cmd-lowercase>.exe" -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\<cmd-lowercase>.cmd" -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\<cmd-lowercase>.ps1" -Force
   ```
   On Linux/macOS, delete `~/.dotnet/tools/<cmd>` and, on case-sensitive file systems, `~/.dotnet/tools/<cmd-lowercase>` if present. Do not glob the tools directory and do not delete unrelated files.
4. Also clear the package cache state if the retry message names it.

   On Windows:
   ```
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\.store\<pkg>" -Recurse -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.dotnet\tools\.store\<pkg-lowercase>" -Recurse -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.nuget\packages\<pkg>" -Recurse -Force
   Remove-Item -LiteralPath "$env:USERPROFILE\.nuget\packages\<pkg-lowercase>" -Recurse -Force
   ```

   On Linux/macOS, substitute `~/.dotnet/...` and `~/.nuget/...` (or in
   PowerShell 7, `$env:HOME/.dotnet/...` and `$env:HOME/.nuget/...` --
   `$HOME` is ReadOnly so the script and these examples use `$env:HOME`).
5. Re-run the installer:
   ```
   pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Install-McpConfig.ps1
   ```

## Step 3.5 — Sidecar logs for classified install failures

For sidecar-backed `dotnet tool install/update` failures, including retry failures from the deep-clean and orphan-shim repair arms, `Install-McpConfig.ps1` writes the full raw `dotnet` output to a log under the project `output/` directory:

```text
output/mcp-install-<sanitized-pkg-id>-<yyyyMMdd-HHmmss-fff>-<4-char-hex>.log
```

Example:

```text
output/mcp-install-azure.mcp-20260517-143012-123-a1b2.log
```

The log contains the full chatter-included output from `dotnet`, including lines like:

```text
[NuGet Manager] [Info] [CredentialProvider]VstsCredentialProvider ...
```

Those credential-provider lines are deliberately suppressed from sidecar-backed user-facing WARNINGs and the `FAILED:` summary so the terminal points at the actionable category instead of an auth red herring. If you need the raw details, open the `Log: <path>` named in the `FAILED:` entry.

The `output/` directory is created lazily only when a failure path needs a log. If the sidecar write fails, the installer still emits the one-line category summary and says the on-disk log is unavailable. Re-run with `-Verbose` to get the full raw output on stdout, or fix write access to `output/` and retry. Early/terminal paths whose remediation is already explicit — SDK preflight, the TFM short-circuit, `ABORTED` orphan-shim safety refusals, and PATH validation — may not emit a sidecar log.

## Step 4 — Still broken?

If MCP servers remain unavailable after Steps 1–3, ask the user to share: (a) the runtime (CLI / VS Code / Claude Code), (b) the output of `pwd` (or the workspace path), (c) the relevant `bicep_mcp` / `azure_mcp` sections of `.mcp.json` with sensitive values redacted, and (d) any error messages from the MCP server startup. Do not proceed with Bicep generation until MCP is restored.
