---
name: codeql-prereq-ruby
description: "Ensure prerequisites for Ruby CodeQL scanning. Detects Ruby runtime, restores Bundler dependencies, and validates the environment. Use when Ruby scan fails, when bundle install is needed, or when setting up Ruby scanning for the first time."
argument-hint: "Describe the issue: bundle install failed, missing gems, Gemfile errors, or Ruby scan question"
user-invocable: true
disable-model-invocation: false
---

# Ruby Prerequisites Skill

Ensure all prerequisites for CodeQL Ruby scanning are met before the scan runs.

## Language Classification

**Interpreted** -- CodeQL's Ruby extractor parses source files directly without compiling or executing. No Ruby runtime is strictly required for the scan to succeed. However, dependency restoration can improve analysis quality for Rails and gem-heavy projects.

## CodeQL Language ID

`ruby` -- covers `.rb` and `.erb` files.

## Prerequisites

### Required

None. CodeQL's Ruby extractor works directly on source files without a runtime.

### Recommended

| Tool | Purpose | Detection | Install |
|---|---|---|---|
| Ruby | Run `bundle install` to resolve gems | `Get-Command ruby` | https://www.ruby-lang.org |
| Bundler | Manage gem dependencies | `Get-Command bundle` | `gem install bundler` |

### Why Dependency Restoration Helps

- **Rails applications**: Without gems installed, CodeQL cannot trace data flow through ActiveRecord queries, controller actions, or middleware. This reduces precision for SQL injection and XSS detection.
- **Gem source analysis**: Some gems contain Ruby source that CodeQL can analyze for transitive vulnerabilities.
- **ERB templates**: Template rendering may reference helpers from gems.

## Dependency Restoration Flow

The scan script performs dependency restoration in step 7c:

```powershell
'ruby' {
    if ((Get-Command bundle -ErrorAction SilentlyContinue) -and (Test-Path 'Gemfile')) {
        Write-Host "Restoring Ruby dependencies (bundler)..." -ForegroundColor Cyan
        & bundle install --quiet 2>$null
    }
}
```

Only runs if both `bundle` and `Gemfile` are present.

## Pre-Build Validation

Ruby is an interpreted language -- no build validation is performed. The scan script emits a pass-through status:

```powershell
'ruby' {
    Write-Host "[PASS] Ruby -- interpreted language, no build required" -ForegroundColor Green
}
```

## Common Issues

| Issue | Cause | Resolution |
|---|---|---|
| Missing gem warnings | Dependencies not installed | Run `bundle install` before committing |
| `bundle` not found | Bundler not installed | Run `gem install bundler` (requires Ruby) |
| Native extension build fails | C compiler or headers missing | Install build tools for your platform |
| `.erb` files not scanned | ERB is mapped to `ruby` | `.erb` IS included -- check file extensions |
| Gemfile.lock conflict | Version mismatches | Run `bundle update` to regenerate lockfile |

## Interaction with Other Skills

- **codeql-build-prereqs**: Covers Ruby at a high level. This skill provides the detailed per-language flow.
- **codeql-scan-perf**: Ruby scans are typically fast since no compilation is needed.
