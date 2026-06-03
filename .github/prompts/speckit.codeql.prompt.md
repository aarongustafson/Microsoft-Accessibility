---
agent: speckit.codeql
description: Set up and manage CodeQL static analysis as a non-bypassable pre-commit hook
---

If the user doesn't provide specific instructions, ask which task they'd like to perform from the list below. If they do provide instructions, execute those directly.

## Guided Workflows

20. **Guided Installation** — Walk me through the full CodeQL setup step by step. Before each step, explain what you're about to do and why, then ask me to confirm before proceeding. Cover: prerequisites check, CodeQL CLI installation, language detection, file creation, hook installation, and validation scan. Pause after each step so I can review the output.

21. **Guided Validation** — Walk me through verifying my CodeQL setup step by step. Check each component one at a time — CodeQL CLI, hook status, bypass prevention, language detection, scan script, SARIF Viewer extension — and explain the result of each check before moving to the next. If anything fails, explain the issue and offer to fix it before continuing.

22. **Guided Remediation** — Walk me through fixing vulnerabilities step by step. First show me the latest scan results grouped by severity. Then for each finding starting with the most critical, explain what the vulnerability is, why it's dangerous, show the affected code, propose a fix, and ask me to approve before applying it. After each fix, re-scan to confirm it's resolved before moving to the next finding.

## Setup & Maintenance

1. **Full Setup** — Detect all languages in my workspace and set up CodeQL as a non-bypassable pre-commit hook with per-language SARIF output, combined SARIF merge, and SARIF Viewer extension.

2. **Verify Installation** — Check that CodeQL CLI is installed, the pre-commit hook is active, bypass prevention is working, and all supported languages are detected. Report any issues found.

3. **Update Query Suites** — Check for CodeQL CLI updates, refresh the query suites to the latest version, and re-validate that all detected languages still have working databases.

4. **Uninstall** — Completely remove the CodeQL pre-commit hook, bypass prevention wrapper, scan scripts, and configuration files. Restore the original git workflow.

26. **Check for Agent Updates** — Compare the local agent and prompt files against the latest versions in the source repository (https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/CodeQL-Vibe). Report whether updates are available and what changed.

27. **Update Agent Files** — Pull the latest versions of `speckit.codeql.agent.md` and `speckit.codeql.prompt.md` from the source repository (https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/CodeQL-Vibe) and replace the local copies. Also update the CLAUDE.md CodeQL snippet if present. Show a summary of what changed.

28. **Upgrade CodeQL CLI** — Ensure the latest supported CodeQL CLI is installed. If an older version is active, upgrade it, verify the managed install directly, detect stale VS Code or terminal sessions that still resolve the old binary, and tell me if I need to restart before scanning again.

29. **Fix Azure DevOps Git Auth** — Configure Azure DevOps git authentication using Git Credential Manager, set the correct git credential helper options, sign in with browser-based `az login` without device code, and verify access to the source repository with `git ls-remote`.

35. **Scan C# Without Project File** — Enable CodeQL C# scanning for repositories that have loose `.cs` files but no `.sln` or `.csproj`. The scan auto-generates a temporary `.csproj` file targeting the highest installed .NET SDK, builds against it, runs the CodeQL analysis, and removes the temporary file after the scan. This is automatic during normal scans — use this prompt to understand the behavior, troubleshoot buildless scanning issues, or verify it works for your repository.

36. **Install Missing SDKs** — Detect which language SDKs are missing for CodeQL scanning (e.g., .NET SDK, JDK, Go toolchain, C/C++ compiler), show what needs to be installed and which version, then install with your consent. Selects CodeQL-compatible versions and handles corporate environment restrictions gracefully.

## Scan for Vulnerabilities

5. **Scan Staged Changes** — Run a CodeQL scan against my currently staged files only. Show a summary of findings grouped by severity (Critical, High, Medium, Low) and open the SARIF output in the viewer.

6. **Scan Entire Workspace** — Run a full CodeQL scan across the entire codebase, not just staged changes. Generate per-language SARIF files and a combined SARIF report. Open results in the SARIF Viewer.

7. **Scan Specific Files** — Ask me which files or folders to scan, then run a targeted CodeQL analysis on just those paths. Show findings with file locations and severity levels.

8. **Scan for a Specific Vulnerability Type** — Ask me which vulnerability category to check (e.g., SQL injection, XSS, path traversal, hardcoded credentials, insecure deserialization) and run a focused query suite for that category. Report all matches.

## Fix Vulnerabilities

9. **Fix All Vulnerabilities** — Read the latest `.codeql-results.sarif`, identify every Critical, High, and Medium finding, and fix each one directly in the source code. Explain each fix.

10. **Fix Critical Only** — Read the latest SARIF results and fix only Critical-severity vulnerabilities. Leave High, Medium, and Low findings untouched. Show what was changed and why.

11. **Fix by Vulnerability Type** — Ask me which type of vulnerability to fix (e.g., injection, XSS, insecure crypto), then find and fix all instances of that specific category across the codebase.

12. **Fix a Specific Finding** — Ask me to point to a specific SARIF finding (by file and line number or rule ID), then fix just that one issue. Explain the root cause and the applied remediation.

13. **Suppress False Positive** — Ask me which finding is a false positive, then add the appropriate CodeQL suppression comment (`// lgtm` or `// codeql[rule-id]`) with a justification. Log the suppression to `.github/codeql/suppression-log.json` with the date, developer, rule, severity, and justification. Update the suppression config if one exists.

## View Scan Reports

14. **View Latest Results** — Open the most recent `.codeql-results.sarif` in the SARIF Viewer extension. If the extension isn't installed, install it first.

15. **View Results by Severity** — Parse the latest SARIF file and show a breakdown: count of Critical, High, Medium, Low, and Informational findings with file locations for each.

16. **View Results for a Specific Language** — Ask me which language to filter on, then open the corresponding per-language SARIF file (e.g., `.codeql-results-javascript.sarif`) in the viewer.

17. **Compare Scan Results** — Compare two SARIF files (e.g., before and after a fix) and show which findings were resolved, which are new, and which remain unchanged.

18. **Generate Vulnerability Summary** — Parse the latest SARIF results and generate a markdown summary table with columns for Rule ID, Severity, File, Line, and Description. Save it to `docs/scan-report.md`.

## Status & Reporting

19. **Status Report** — Show a summary of the current CodeQL setup: installed version, hook status, bypass prevention layers, detected languages, last scan results, and count of open findings by severity. Also write a structured health beacon to `.github/codeql/status.json` for fleet-level observability.

## Help

23. **Help** — List exactly the 36 supported numbered prompts defined in this file, with each prompt's number, name, and a one-line description, grouped by section (Guided Workflows, Setup & Maintenance, Scan, Fix, View Reports, Status, Testing, Guides, CI/CD Integration, Governance & Compliance, Migration). Do not imply support for prompts outside this catalog. Include example usage with `/speckit.codeql` for each section.

## Testing

24. **Test Setup** — Run a comprehensive test of the CodeQL setup in the current workspace. Validate all generated files for syntax errors and non-ASCII characters, check that the pre-commit hook fires correctly, verify the git wrapper intercepts --no-verify, run a scan and confirm SARIF output is valid, then report a pass/fail summary for each check.

## Guides

25. **Guides** — Show the user the documentation guides available at https://aka.ms/CELA-CODEQL with a brief description of each guide: Introduction, Getting Started, Troubleshooting, How It Works, SARIF Guide, Remediation Guide, Suppression Policy, and Prompts Guide. Include the direct link so the user can open it immediately.

## CI/CD Integration

30. **Set up CI/CD Scanning** — Create an Azure Pipelines definition (`azure-pipelines/codeql-scan.yml`) that runs CodeQL analysis on pull requests and pushes to protected branches. The pipeline uses the same severity policy as the pre-commit hook — Critical, High, and Medium findings fail the build. Customize the language list based on detected languages.

31. **Verify CI/CD Integration** — Check that the Azure Pipelines workflow file (`azure-pipelines/codeql-scan.yml`) exists and is valid, the language list matches the detected languages, and `codeql-config.yml` is referenced. Report any mismatches or missing configuration.

## Governance & Compliance

32. **Review Suppressions** — List all suppressions from `.github/codeql/suppression-log.json`, sorted by severity then age. Flag any suppressions older than 90 days for review. Show date, developer, rule, severity, file:line, and justification for each.

33. **Generate Compliance Report** — Read `.github/codeql/scan-history.json` and produce a compliance summary: total scans, block rate, findings trend by severity, most common blocking rules, and languages scanned. Save the report to `docs/compliance-report.md`.

## Migration

34. **Migrate Legacy Installation** — Detect and migrate an older `.codeql/` installation (at the project root) to the current `.github/codeql/` layout. Removes the legacy hooks, profile entries, and folder, then runs a fresh install with the new path structure. Safe for early adopters upgrading to the latest version.
