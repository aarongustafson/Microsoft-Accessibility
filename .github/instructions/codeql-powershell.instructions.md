---
description: Instructions for editing PowerShell scripts and code blocks
globs: ".github/codeql/**/*.ps1"
# Namespace: codeql — only applies to CodeQL-generated PowerShell scripts
---

# PowerShell Script Standards

When writing or editing PowerShell code (in `.ps1` files or code blocks in the agent spec):

- **ASCII-only** (0x00–0x7F). No Unicode symbols. PowerShell on Windows may use ANSI/Windows-1252 encoding, corrupting multi-byte characters.
- Use `[PASS]`, `[FAIL]`, `[WARN]`, `[AUTO]` prefixes for status messages.
- Use `-->` instead of `→`, `--` instead of `──`.
- Use `Write-Host` with `-ForegroundColor` for colored output: Green for pass, Red for fail, Yellow for warnings, Cyan for auto/info.
- Always use `-ErrorAction SilentlyContinue` on operations that may fail in some environments (e.g., `Remove-Item`, `Get-Job`).
- Use `powershell -ExecutionPolicy Bypass -NoProfile -File` (Windows) or `pwsh -ExecutionPolicy Bypass -NoProfile -File` (macOS/Linux) for script invocation.
- Save files with `-Encoding UTF8` explicitly.
- **Wrap `-replace` in parentheses inside .NET method calls.** PowerShell parses commas as argument separators in method syntax: `.Add($x -replace '\\', '/')` passes two arguments. Write `.Add(($x -replace '\\', '/'))` instead.
- Guard `$PROFILE` access — it can be null in embedded hosts, CI agents, and `Start-Job` blocks. Use `[Environment]::GetFolderPath('MyDocuments')` as fallback.
