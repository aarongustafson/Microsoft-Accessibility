---
name: codeql-sarif-analysis
description: "Parse, filter, and summarize CodeQL SARIF scan results. Use when asked to view findings, compare scans, generate a summary report, filter by severity, show results for a file, or explain a CodeQL rule. Reads .codeql-results.sarif and per-language SARIF files."
argument-hint: "Describe what you want: view all findings, filter by severity, compare two scans, summarize results, or explain a specific rule ID"
user-invocable: true
disable-model-invocation: false
---

# SARIF Analysis Skill

Parse and report on CodeQL SARIF scan results for the current workspace.

## When to Use

- User asks to **view**, **list**, or **show** scan results
- User asks to **filter** findings by severity, language, file, or rule
- User asks to **compare** scan results (before/after fixing)
- User asks to **generate a summary** or **report** of findings
- User asks to **explain** a CodeQL rule or finding
- User asks about finding **counts** or **severity breakdown**
- VS Code can open the SARIF but warns about unusual line terminators and the user wants the file repaired without losing findings

## Prerequisites

- A `.codeql-results.sarif` file (or per-language `.codeql-results-<lang>.sarif` files) must exist in the workspace root
- These files are produced by the CodeQL scan script (`.github/codeql/scan.ps1`)

## Procedure

### 1. Locate SARIF Files

Look for these files in the workspace root:
- `.codeql-results.sarif` — combined results (primary)
- `.codeql-results-<language>.sarif` — per-language results

If no SARIF files exist, tell the user to run a scan first.

### 2. Parse the SARIF

Read the file with `Get-Content -Raw | ConvertFrom-Json` (PowerShell) or the equivalent. The structure is:

```json
{
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": { "driver": { "name": "CodeQL", "rules": [...] } },
      "results": [...]
    }
  ]
}
```

Each `runs[]` entry corresponds to one language scan. The combined file merges all runs.

### 3. Classify Severity

For each result, read `properties.security-severity` (float) and `level`:

| security-severity | Classification |
|---|---|
| >= 9.0 | **Critical** |
| >= 7.0 | **High** |
| >= 4.0 | **Medium** |
| < 4.0 | **Low** |

If `security-severity` is absent, fall back to `level`:

| level | Classification |
|---|---|
| error | **Medium** |
| warning | **Low** |
| note / none | **Informational** |

### 4. Extract Finding Details

For each result, extract:
- `ruleId` — the CodeQL query identifier (e.g. `js/sql-injection`)
- `level` — error, warning, or note
- `message.text` — description of the finding
- `locations[0].physicalLocation.artifactLocation.uri` — file path
- `locations[0].physicalLocation.region.startLine` — line number

Rule metadata is in `runs[].tool.driver.rules[]`:
- `id` — matches `ruleId`
- `shortDescription.text` — one-line summary
- `fullDescription.text` — detailed explanation
- `properties.security-severity` — CVSS score

### 5. Format Output

Present findings sorted by severity (Critical first), then by file path. Use this table format:

```
+----------+----------+-----------+------------------------+------+---------------------------+
| Severity | Language | Rule ID   | File                   | Line | Message                   |
+----------+----------+-----------+------------------------+------+---------------------------+
| CRITICAL | js       | js/sql-in | src/db.js              | 42   | SQL injection from ...    |
+----------+----------+-----------+------------------------+------+---------------------------+
```

Follow with a severity breakdown: `Critical: N | High: N | Medium: N | Low: N | Info: N`

### Filtering

When the user asks to filter:
- **By severity:** Only show results matching the requested levels
- **By file:** Only show results whose `artifactLocation.uri` matches
- **By language:** Only show results from the matching `runs[]` entry
- **By rule:** Only show results with matching `ruleId`

### Comparing Scans

When comparing two SARIF files:
1. Parse both files
2. Build a set of `(ruleId, file, line)` tuples from each
3. Report: findings **fixed** (in old but not new), findings **new** (in new but not old), findings **unchanged**

### Explaining a Rule

When asked about a specific rule ID:
1. Find the rule in `runs[].tool.driver.rules[]` by `id`
2. Show: `shortDescription`, `fullDescription`, `security-severity`, and the `tags` array
3. If the rule has results in the current scan, show those findings as examples

## Constraints

- **Read-only**: This skill only reads and reports SARIF data. It never modifies source files.
- **Blocking policy**: Critical, High, and Medium findings block commits. Low and Informational are reported only.
- If the SARIF itself is unreadable, malformed, or contains unusual line terminators, invoke `codeql-sarif-integrity` before analysis.
- See [SARIF Guide](../../../docs/sarif-guide.md) and [How It Works](../../../docs/how-it-works.md) for full documentation.
