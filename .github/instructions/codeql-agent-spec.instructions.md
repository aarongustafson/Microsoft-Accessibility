---
description: Instructions for editing the CodeQL agent specification file
globs: .github/agents/speckit.codeql.agent.md
# Namespace: codeql — this instruction deploys with the CodeQL agent
---

# Agent Spec Editing

When editing `speckit.codeql.agent.md`:

- This file is the **single source of truth** for all CodeQL scanning logic — setup, scanning, fixing, validation, and guided workflows.
- All PowerShell code blocks in this file are **specifications**, not runnable scripts. They describe what the agent should generate when invoked by a user.
- **ASCII-only** in all `.ps1` code blocks. Never use Unicode symbols (`→`, `✓`, `✗`, `⚠`, box-drawing characters). Use `[PASS]`, `[FAIL]`, `[WARN]`, `-->`, `--` instead.
- **Do not duplicate logic** across sections. If a constraint or behavior is defined once, reference it — don't copy it.
- **Step numbering matters.** Steps are referenced by number throughout the spec (e.g., "step 7c", "step 19"). If you add or move steps, update all cross-references.
- The file uses markdown tables for structured data (language mappings, severity levels, error codes). Keep tables aligned and consistent.
- **No Infinite Loops table** (in Phase 0) defines retry limits. If adding logic that could loop, add an entry to that table.
