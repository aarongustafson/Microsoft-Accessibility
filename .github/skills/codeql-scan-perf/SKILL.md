---
name: codeql-scan-perf
description: "Tune CodeQL scan performance: parallel vs sequential analysis, RAM budgeting, timeout diagnosis, incremental scoping, database caching, and query suite selection. Use when scans are slow, timing out, running out of memory, or when optimizing scan speed for large codebases."
argument-hint: "Describe the performance issue: slow scan, timeout, out of memory, or what you want to optimize"
user-invocable: true
disable-model-invocation: false
---

# Scan Performance Skill

Optimize CodeQL scan speed, memory usage, and parallelism. Covers resource budgeting, query suite selection, incremental scoping, and timeout diagnosis.

## When to Use

- Scan is **slow** or **timing out** (30-minute limit)
- User reports **out of memory** errors during analysis
- User asks how to **speed up** scans
- User asks about **parallel vs sequential** analysis
- User asks about **incremental** vs **full** scanning
- User asks about **query suite** differences (security-queries vs security-extended)
- Agent needs to decide analysis strategy for a multi-language workspace

## Resource Budgeting

### RAM Detection

```powershell
# Windows
$totalRamMB = [math]::Round((Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1MB)
# Linux
# $totalRamMB = [math]::Round((Get-Content /proc/meminfo | Select-String 'MemTotal' | ForEach-Object { ($_ -split '\s+')[1] }) / 1024)
# macOS
# $totalRamMB = [math]::Round((sysctl -n hw.memsize) / 1MB)
```

### Budget Allocation

The scan uses 70% of total RAM (`$budgetMB = $totalRamMB * 0.7`), leaving 30% for the OS, IDE, and other processes.

| Phase | Budget | Concurrency |
|---|---|---|
| Database creation | Full `$budgetMB` | Always single process (`--db-cluster` for multi-language) |
| Analysis (sequential) | Full `$budgetMB` per language | One language at a time |
| Analysis (parallel) | `$budgetMB / $jobCount` per language | All languages simultaneously |

### Parallel vs Sequential Decision

```
IF any of these conditions are true --> SEQUENTIAL:
  - Only 1 active language
  - Total RAM < 8 GB
  - Per-job RAM < 2 GB (i.e., too many languages for available RAM)
  - User passed -Parallel:$false
OTHERWISE --> PARALLEL
```

| Total RAM | 1 Language | 2 Languages | 3 Languages | 4+ Languages |
|---|---|---|---|---|
| 4 GB | Sequential | Sequential | Sequential | Sequential |
| 8 GB | Sequential | Parallel (2.8 GB each) | Sequential (1.9 GB each < 2 GB) | Sequential |
| 16 GB | Sequential | Parallel (5.6 GB each) | Parallel (3.7 GB each) | Parallel (2.8 GB each) |
| 32 GB | Sequential | Parallel (11.2 GB each) | Parallel (7.5 GB each) | Parallel (5.6 GB each) |

## Two-Phase Architecture

### Phase 1: Database Creation

- Always a single process (even for multi-language)
- Uses `--db-cluster` for 2+ languages: one JVM boot, one source traversal
- Saves ~10 seconds JVM startup for 3+ languages vs separate `database create` per language
- Gets the full RAM budget (`--ram=$budgetMB`)
- Uses all CPU cores (`--threads=0`)

### Phase 2: Query Analysis

- **Sequential** (`Start-Job` not used): each language analyzed one at a time, full budget per language
- **Parallel** (`Start-Job`): one background job per language, budget split across jobs
- 30-minute timeout via `Wait-Job -Timeout 1800`
- Timed-out jobs are stopped and reported as `[FAIL]`
- Completed jobs are always collected with `Receive-Job` (prevents orphaned output)

### Why Parallel Analysis Is Safe

Database creation is complete before analysis begins. Each language's `database analyze`:
- Reads from its own database directory (`.codeql-db/<language>`)
- Writes to its own SARIF file (`.codeql-results-<language>.sarif`)
- No shared resources or write conflicts between jobs

Cross-instance safety (two terminals running `scan.ps1` simultaneously) is guaranteed by the process-level file lock (`.github/codeql/.scan-lock`).

## Incremental Scoping

Scans are incremental by default -- only languages with changed files are scanned.

### File Detection Strategy

| Context | Command | Scope |
|---|---|---|
| Pre-commit hook | `git diff --cached --name-only --diff-filter=ACMR` | Staged files only |
| Manual invocation | `git diff HEAD --name-only --diff-filter=ACMR` | Staged + unstaged |
| Initial commit | Staged + `git ls-files --others --exclude-standard` | Staged + untracked |
| Full scan (`-Full`) | `git ls-files` | All tracked files |

### Language-Level Optimization

File extensions are mapped to CodeQL language IDs via `$extMap`. Only languages with changed files enter `$activeLanguages`. Languages with no changes are skipped entirely (e.g., if only Python files changed, JavaScript is not scanned).

### Post-Scan Filtering

`codeql database analyze` scans the full database for each active language, so raw SARIF may include findings beyond the changed set. Step 10 post-filters SARIF results to retain only findings in changed files (unless `-Full`). Uses `[System.Collections.Generic.HashSet[string]]` for O(1) lookups -- not `$changedFiles -contains $file` which is O(n) per result.

## Query Suite Selection

| Context | Suite | Focus |
|---|---|---|
| Pre-commit (default) | `security-queries` | Core security queries only (fastest) |
| Full scan / CI/CD | `security-extended` | Extended security queries (thorough) |

**Fully-qualified format required:** `codeql/$lang-queries:codeql-suites/$lang-security-extended.qls`

Bare names like `security-extended` fail with "Query pack cannot be found".

### Performance Comparison

`security-queries` typically runs 30-50% faster than `security-extended` because it includes only core security queries, skipping extended detection rules. For pre-commit hooks where developer feedback latency matters, this is the right tradeoff.

## Database Caching

- The database is **rebuilt on every scan** (`--overwrite`). This ensures the latest source code is always scanned.
- `--no-rerun` skips re-evaluating queries cached from a previous `database analyze` on the same database. Since the database is rebuilt each scan, this cache starts empty -- the flag only helps manual re-runs without code changes.
- Database files live in `.codeql-db/<language>/` and are excluded via `.gitignore`.

## Timeout Diagnosis

If a language analysis times out (exceeds 30 minutes):

### Diagnostic Steps

1. **Identify which language timed out** -- the parallel job name is `codeql-<language>`.
2. **Check database size** -- large codebases produce large databases:
   ```powershell
   Get-ChildItem -Recurse ".codeql-db" | Measure-Object -Property Length -Sum |
       ForEach-Object { "{0:N0} MB" -f ($_.Sum / 1MB) }
   ```
3. **Check available RAM** -- if per-job budget is near the 2 GB minimum, analysis may page to disk.
4. **Try sequential analysis** -- run with `-Parallel:$false` so the timed-out language gets the full RAM budget.
5. **Check for large generated files** -- build tools that generate thousands of source files (e.g., code generators, T4 templates) inflate the database.

### Common Timeout Causes

| Cause | Diagnosis | Fix |
|---|---|---|
| Low per-job RAM | `$ramPerAnalyzeMB` near 2048 | Run with `-Parallel:$false` |
| Very large codebase | Database > 2 GB | Consider `paths-ignore` in `codeql-config.yml` |
| Generated code | Thousands of auto-generated files | Add generated directories to `paths-ignore` |
| Complex queries | `security-extended` suite on large codebase | Use `security-queries` for pre-commit |
| Disk I/O bottleneck | HDD instead of SSD | Move workspace to SSD |

## Performance Tips

1. **Use incremental scans for pre-commit** (default) -- only scan languages with changed files.
2. **Reserve `-Full` for CI/CD and on-demand** -- full scans are slower but more thorough.
3. **Ensure sufficient RAM** -- 8 GB minimum for single-language, 16+ GB recommended for multi-language parallel.
4. **Use SSD storage** -- CodeQL database creation is I/O intensive.
5. **Exclude generated code** -- add build output and generated directories to `codeql-config.yml` `paths-ignore`.
6. **Single-language fast path** -- when only one language is scanned, SARIF merge is skipped (file copy instead of JSON parse/serialize).

## Cross-References

- **Agent spec Step 7b** -- RAM detection and budget calculation (source of truth)
- **Agent spec Step 8** -- Two-phase database creation and analysis
- **codeql-troubleshoot** -- For scan timeout and general failure diagnosis
- **codeql-sarif-analysis** -- For SARIF post-filtering and result presentation
