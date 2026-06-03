---
name: spear.codeql
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

13. **Suppress False Positive** — Ask me which finding is a false positive, then add the appropriate CodeQL suppression comment (`// lgtm` or `// codeql[rule-id]`) with a justification. Update the suppression config if one exists.

## View Scan Reports

14. **View Latest Results** — Open the most recent `.codeql-results.sarif` in the SARIF Viewer extension. If the extension isn't installed, install it first.

15. **View Results by Severity** — Parse the latest SARIF file and show a breakdown: count of Critical, High, Medium, Low, and Informational findings with file locations for each.

16. **View Results for a Specific Language** — Ask me which language to filter on, then open the corresponding per-language SARIF file (e.g., `.codeql-results-javascript.sarif`) in the viewer.

17. **Compare Scan Results** — Compare two SARIF files (e.g., before and after a fix) and show which findings were resolved, which are new, and which remain unchanged.

18. **Generate Vulnerability Summary** — Parse the latest SARIF results and generate a markdown summary table with columns for Rule ID, Severity, File, Line, and Description. Save it to `docs/scan-report.md`.

## Status & Reporting

19. **Status Report** — Show a summary of the current CodeQL setup: installed version, hook status, bypass prevention layers, detected languages, last scan results, and count of open findings by severity.

## Help

23. **Help** — List every supported prompt with its number, name, and a one-line description, grouped by section (Guided Workflows, Setup & Maintenance, Scan, Fix, View Reports, Status). Include example usage with `/speckit.codeql` for each section.

## Testing

24. **Test Setup** — Run a comprehensive test of the CodeQL setup in the current workspace. Validate all generated files for syntax errors and non-ASCII characters, check that the pre-commit hook fires correctly, verify the git wrapper intercepts --no-verify, run a scan and confirm SARIF output is valid, then report a pass/fail summary for each check.

## Guides

25. **Guides** — Show the user the documentation guides available at https://aka.ms/CELA-CODEQL with a brief description of each guide: Introduction, Getting Started, Troubleshooting, How It Works, SARIF Guide, Remediation Guide, and Prompts Guide. Include the direct link so the user can open it immediately.
