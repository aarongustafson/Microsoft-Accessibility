---
name: codeql-sarif-integrity
description: "Detect and repair SARIF files that appear damaged or unreadable in editors while preserving the vulnerability data. Use when VS Code reports unusual line terminators, U+2028 or U+2029 characters, malformed or unreadable SARIF, SARIF Viewer parse failures, invalid control characters, corrupted encoding, or when the user wants a clean readable SARIF file without losing findings."
argument-hint: "Describe the SARIF issue: unusual line terminators, unreadable SARIF, malformed JSON, SARIF Viewer won't open, sanitize without losing findings"
user-invocable: true
disable-model-invocation: false
---

# SARIF Integrity Skill

Detect and repair SARIF files that are technically present but difficult to open, read, or parse in VS Code, and harden the generation flow so future SARIF files are written cleanly.

## When to Use

- VS Code shows **Detected unusual line terminators** when opening a `.sarif` file
- The SARIF contains **U+2028** (Line Separator) or **U+2029** (Paragraph Separator)
- The user says the SARIF file looks **damaged**, **corrupted**, or **unreadable**
- The SARIF Viewer fails to open the file or shows parse errors
- `ConvertFrom-Json` fails because of invalid control characters or malformed text content
- The user wants the SARIF cleaned up **without losing vulnerability findings**
- The user wants future SARIF files to be created in a clean readable format automatically

## Goal

Preserve the vulnerability data and SARIF structure while removing text artifacts that make the file hard to open or parse, and prevent the same issue from being written into newly generated SARIF files.

The priority order is:
1. Keep all `runs`, `results`, rule metadata, file paths, and line numbers intact.
2. Apply the smallest safe normalization needed for readability.
3. Verify the repaired SARIF still parses and still contains the same finding counts.

## Default Behavior

When invoked for a real SARIF problem, the agent should default to **prevention plus safe repair**, not only explanation.

Use this order:
1. If the issue is in generated CodeQL output, update the SARIF creation flow so new files are normalized at write time.
2. Locate the affected `.sarif` file.
3. Confirm whether the issue is editor readability, JSON integrity, or both.
4. Create a backup before modifying the file in place.
5. Normalize only the problematic characters.
6. Verify the repaired file parses and still exposes the same findings.

## Prevention Workflow

When the user wants the problem solved permanently, modify the generated scan flow so it:

1. Normalizes each per-language SARIF immediately after `codeql database analyze`
2. Validates that each per-language SARIF parses before merge or copy
3. Normalizes the combined `.codeql-results.sarif` after it is written
4. Refuses to auto-open the combined SARIF if validation fails

This is the preferred fix for new setups and agent updates.

## Diagnostic Procedure

### 1. Locate SARIF Files

Look for:
- `.codeql-results.sarif`
- `.codeql-results-<language>.sarif`

If no SARIF files exist, tell the user to run a scan first.

### 2. Detect the Integrity Issue

Inspect the raw text for:
- `U+2028` Line Separator
- `U+2029` Paragraph Separator
- NUL bytes or other invalid control characters
- Truncated JSON or invalid UTF-8/UTF-16 content

If the file parses successfully but VS Code still warns, treat it as a **readability normalization** problem.

If the file does not parse, treat it as a **repair and validation** problem.

### 3. Capture the Original State

Before modifying the file, record:
- File path
- File size
- Whether it parses as JSON
- Number of `runs`
- Total number of `results`

If the file parses before repair, use those counts as the integrity baseline.

## Repair Workflow

### Repair Path A: Unusual Line Terminators Only

If the file is valid JSON and the only issue is `U+2028` or `U+2029`, replace those characters with standard escaped newlines or plain spaces, then write the file back as UTF-8.

Preferred normalization:
- Replace `U+2028` with `\n`
- Replace `U+2029` with `\n\n`

This preserves readability without changing the SARIF structure.

### Repair Path B: Invalid Control Characters

If the file fails to parse because it contains invalid C0 control characters, remove only the disallowed control bytes while preserving tab, carriage return, and line feed where valid.

Do not remove printable text, rule identifiers, file paths, or region information.

### Repair Path C: Safe Rewrite After Parse

If the SARIF parses into an object graph, a safe fallback is:
1. Parse the SARIF
2. Normalize only problematic string values
3. Re-serialize the JSON
4. Save with explicit UTF-8 encoding

Use this path when raw text replacement is not enough.

## Verification Requirements

After repair:
1. Re-parse the SARIF successfully
2. Compare `runs` count before and after
3. Compare total `results` count before and after
4. Confirm the repaired file opens without the original editor warning when possible

If counts change unexpectedly, stop and restore from backup instead of silently accepting data loss.

## Safe Repair Principles

- Prefer a **backup plus in-place repair** for generated SARIF files
- Never delete findings just to make the file open cleanly
- Never drop entire `runs[]` entries, `results[]`, or rule definitions
- Do not change severity, rule IDs, file URIs, or line numbers during normalization

## Suggested PowerShell Pattern

```powershell
$path = '.codeql-results-javascript.sarif'
$backup = "$path.bak"
Copy-Item $path $backup -Force

$raw = Get-Content $path -Raw -Encoding UTF8
$before = $raw | ConvertFrom-Json
$beforeRuns = @($before.runs).Count
$beforeResults = @($before.runs | ForEach-Object { @($_.results).Count } | Measure-Object -Sum).Sum

$clean = $raw.Replace([string][char]0x2028, "`n").Replace([string][char]0x2029, "`n`n")
$clean = [regex]::Replace($clean, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')

Set-Content -Path $path -Value $clean -Encoding UTF8

$after = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
$afterRuns = @($after.runs).Count
$afterResults = @($after.runs | ForEach-Object { @($_.results).Count } | Measure-Object -Sum).Sum

if ($beforeRuns -ne $afterRuns -or $beforeResults -ne $afterResults) {
    Copy-Item $backup $path -Force
    throw 'SARIF repair changed finding counts. Original file restored.'
}
```

## Constraints

- This skill may modify generated `.sarif` files, but only to preserve readability and parseability
- Prefer repairing generated artifacts over source files that contributed the text
- If the user wants a permanent fix, update the SARIF generation flow so normalization happens during file creation, not only after the artifact is already broken
- For finding summaries and severity filtering, use `codeql-sarif-analysis`

## Outcome

The user should end up with a SARIF file that:
- Opens cleanly in VS Code or the SARIF Viewer
- Still contains the same vulnerabilities
- Is safe to inspect without wondering whether findings were lost during repair