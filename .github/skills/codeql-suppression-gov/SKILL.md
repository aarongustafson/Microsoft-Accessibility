---
name: codeql-suppression-gov
description: "Manage suppression governance, scan audit trails, and compliance reporting. Use when logging suppressions, reviewing aged suppressions, generating compliance reports, querying scan history, or auditing the suppression policy. Covers suppression-log.json, scan-history.json, and compliance report generation."
argument-hint: "Describe what you need: log a suppression, review old suppressions, generate compliance report, or query scan history"
user-invocable: true
disable-model-invocation: false
---

# Suppression Governance Skill

Manage suppression logging, age-based review, scan audit trails, and compliance reporting. Ensures suppressions follow policy and provides organizational visibility into scanning posture.

## When to Use

- User asks to **suppress** a finding (Prompt 13) -- log the suppression
- User asks to **review suppressions** (Prompt 32) -- age-based review
- User asks to **generate a compliance report** (Prompt 33)
- User asks about **scan history** or audit trail
- User asks about **suppression policy** or justification requirements
- User needs to **export** scan data for external compliance systems

## Core Constraint

The agent WILL NOT suppress findings without written justification. Every suppression MUST include a justification explaining why the finding is a false positive or accepted risk.

## Suppression Logging (Prompt 13)

When a finding is suppressed via code comment, the agent MUST also log it to `.github/codeql/suppression-log.json`.

### Entry Schema

```json
{
  "date": "<ISO 8601 timestamp>",
  "developer": "<from git config user.name>",
  "ruleId": "<CodeQL rule ID>",
  "file": "<relative file path>",
  "line": 42,
  "severity": "High",
  "justification": "False positive: input is validated by sanitizeHtml() on line 38"
}
```

All fields are mandatory. The `justification` field MUST contain meaningful text -- not just "false positive" or "not applicable".

### Logging Procedure

```powershell
# Read or create
$logPath = ".github/codeql/suppression-log.json"
if (Test-Path $logPath) {
    $log = Get-Content -Raw $logPath | ConvertFrom-Json
} else {
    $log = [PSCustomObject]@{ suppressions = @() }
}

# Append using @() array pattern (avoids PSObject op_Addition error)
$entry = [PSCustomObject]@{
    date          = (Get-Date -Format 'o')
    developer     = (git config user.name)
    ruleId        = $ruleId
    file          = $filePath
    line          = $lineNumber
    severity      = $severity
    justification = $justificationText
}
$log.suppressions = @($log.suppressions) + @($entry)

# Cap at 1000 entries (keeps most recent)
if ($log.suppressions.Count -gt 1000) {
    $log.suppressions = $log.suppressions[-1000..-1]
}

# Atomic write
$tmpFile = "$logPath.tmp"
$log | ConvertTo-Json -Depth 10 | Set-Content $tmpFile -Encoding UTF8
Move-Item $tmpFile $logPath -Force
```

### PowerShell Array Gotcha

`ConvertFrom-Json` returns PSObject wrappers. The `+=` operator does NOT work on PSObject arrays (`op_Addition` error). Always use:
```powershell
$log.suppressions = @($log.suppressions) + @($entry)
```
NOT:
```powershell
$log.suppressions += $entry  # BROKEN -- op_Addition error
```

This applies to both `suppression-log.json` and `scan-history.json`.

## Suppression Review (Prompt 32)

### Review Procedure

1. Read `.github/codeql/suppression-log.json`. If missing, report "No suppressions logged."
2. For each entry, calculate age: `(Get-Date) - [datetime]$entry.date`
3. Sort by severity (Critical first), then by age (oldest first).
4. Flag entries older than **90 days** for review.
5. Suggest removing suppressions where the underlying code has changed or the CodeQL rule has been updated.

### Review Output Format

```
Suppression Review
==================
Total suppressions: 12
Flagged for review (>90 days): 3

| Age   | Severity | Rule ID         | File:Line          | Developer   | Justification              |
|-------|----------|-----------------|--------------------|-------------|----------------------------|
| 142d  | High     | js/sql-injection| src/db.js:42       | Alice       | Input validated on line 38 |
| 98d   | Medium   | py/path-inject  | api/files.py:15    | Bob         | Path constrained to /data/ |
| 91d   | Low      | cs/unused-value | util/Helper.cs:8   | Carol       | Required by interface      |
```

### Justification Quality

Suppressions with vague justifications should be flagged regardless of age:
- "false positive" -- WHY is it a false positive?
- "not applicable" -- WHY is it not applicable?
- "will fix later" -- NOT a valid suppression justification

Good justifications reference specific code context: "Input is sanitized by `escapeHtml()` on line 38 before reaching this sink."

## Scan Audit Trail

Every scan (pre-commit or manual) appends an entry to `.github/codeql/scan-history.json`.

### Scan History Entry Schema

```json
{
  "timestamp": "2026-03-24T10:30:00.000Z",
  "durationMs": 12345,
  "developer": "Alice",
  "trigger": "pre-commit",
  "languages": ["javascript", "python"],
  "findings": {
    "critical": 0,
    "high": 1,
    "medium": 3,
    "low": 5,
    "informational": 2
  },
  "blocked": true,
  "agentVersion": "1.0.0"
}
```

| Field | Source |
|---|---|
| `timestamp` | `Get-Date -Format 'o'` |
| `durationMs` | `$scanStopwatch.ElapsedMilliseconds` |
| `developer` | `git config user.name` |
| `trigger` | `pre-commit`, `manual`, or `ci` |
| `languages` | `$activeLanguages` array |
| `findings` | Parsed from SARIF severity counts |
| `blocked` | `$true` if commit was blocked |
| `agentVersion` | From `speckit.agent.yml` `agent.version` or `"unknown"` |

### Size Cap

Both `scan-history.json` and `suppression-log.json` are pruned to **1000 entries** on every write. At 5-minute scan intervals, this is ~3.5 days of continuous use. For long-term compliance, export history to an external system before it rotates out.

## Compliance Report (Prompt 33)

### Report Generation

1. Read `.github/codeql/scan-history.json`. If missing, report "No scan history found. Run a scan first."
2. Aggregate the data:

| Metric | Calculation |
|---|---|
| Total scans (all time) | Count of all entries |
| Total scans (30 days) | Entries where `timestamp` is within last 30 days |
| Total scans (7 days) | Entries where `timestamp` is within last 7 days |
| Block rate | `blocked == true` count / total count * 100 |
| Findings trend | Sum of each severity level across time periods |
| Languages scanned | Unique values across all `languages` arrays |
| Top blocking rules | Most common `ruleId` values in blocked scans |

3. Generate a markdown report and write to `docs/compliance-report.md`.
4. Open in VS Code.

### Report Template

```markdown
# CodeQL Compliance Report

Generated: <timestamp>
Agent version: <version>

## Summary

| Metric | All Time | 30 Days | 7 Days |
|---|---|---|---|
| Total scans | X | Y | Z |
| Blocked commits | X | Y | Z |
| Block rate | X% | Y% | Z% |

## Findings by Severity

| Severity | Total Found | Trend (30d) |
|---|---|---|
| Critical | X | +/- N |
| High | X | +/- N |
| Medium | X | +/- N |
| Low | X | +/- N |
| Informational | X | +/- N |

## Languages Scanned

<list of unique languages>

## Top Blocking Rules

| Rule ID | Occurrences | Severity |
|---|---|---|
| js/sql-injection | N | Critical |
| ... | ... | ... |

## Suppression Status

| Total | >90 Days (Review Needed) | By Severity |
|---|---|---|
| X | Y | Critical: A, High: B, Medium: C |
```

## Severity-Based Justification Requirements

Different severities may require different levels of justification:

| Severity | Required Justification | Approval |
|---|---|---|
| Critical | Detailed technical explanation + alternative mitigation | Security team review recommended |
| High | Technical explanation with code reference | Team lead review recommended |
| Medium | Explanation with context | Developer self-approval acceptable |
| Low | Brief explanation | Developer self-approval acceptable |
| Informational | Minimal | No approval needed |

These are recommendations following the [suppression policy](../../../docs/suppression-policy.md). The agent enforces that a justification exists but does not enforce approval workflows.

## Cross-References

- **Agent spec Suppression Logging section** -- Logging procedure (source of truth)
- **Agent spec Scan Audit Trail section** -- Scan history logging (source of truth)
- **docs/suppression-policy.md** -- Organizational suppression governance policy
- **codeql-sarif-analysis** -- SARIF parsing and severity classification used for findings counts
- **codeql-vulnerability-remediation** -- Fix findings instead of suppressing them
