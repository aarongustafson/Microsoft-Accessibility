---
description: Instructions for editing documentation files
globs: docs/*.md
# Namespace: codeql -- source-repo only, not deployed to consuming repos
---

# Documentation Editing

When editing files in `docs/`:

- All guides are part of the **CodeQL Vibe documentation set** published at https://aka.ms/CELA-CODEQL.
- Each guide has a specific scope. Do not duplicate content across guides — cross-reference with links instead.
- Every guide ends with a navigation line: `Next: [Guide](guide.md) | Back to: [README](../README.md)`.
- Use tables for structured comparisons (severity levels, language support, prerequisites).
- Code examples should be copy-pasteable. Use `powershell` or `json` fenced code blocks with correct syntax.
- When documenting scan behavior, the **agent spec** (`.github/agents/speckit.codeql.agent.md`) is authoritative. Docs describe the behavior — the spec defines it.

## Guide Purposes

| Guide | Scope |
|---|---|
| `introduction.md` | What CodeQL Vibe is, blocking policy, supported languages, platform support, design decisions |
| `getting-started.md` | Prerequisites, setup steps, verification |
| `troubleshooting.md` | Problem → symptom → fix format. Each section has symptoms, root cause, and resolution. |
| `how-it-works.md` | Architecture, scan flow, enforcement layers, query suites |
| `sarif-guide.md` | SARIF file format, viewer usage, filtering |
| `remediation-guide.md` | Fixing findings — agent-driven and manual approaches |
| `suppression-policy.md` | Governance, justification requirements, audit trail |
| `dependencies-guide.md` | Per-language build prerequisites, auto-resolution, manual setup |
| `prompts-guide.md` | All 36 prompts with examples and usage tips |
| `update-guide.md` | Versioning, checking for updates, pulling latest files |
| `agent-manifest-guide.md` | `speckit.agent.yml` schema and bootstrapper workflow |
| `bootstrapper-guide.md` | Setting up the SpecKit bootstrapper, first-time install, fleet management |
| `speckit-checklist.md` | Framework compliance checklist |
