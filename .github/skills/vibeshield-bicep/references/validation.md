# Two-Tier Validation

Both tiers are required. Tier 1 does not replace Tier 2.

## Tier 1 — Lint-on-Edit (automatic, fast)

A PostToolUse hook (`.github/hooks/validate-bicep.json`) runs after every `.bicep` edit in Copilot agent sessions.

**Chain**: Hook → `Invoke-BicepLintHook.ps1` → `Invoke-BicepLint.ps1` → SARIF to stdout

**What it catches**: Syntax errors, lint warnings, missing parameters, invalid expressions.

**What it misses**: WAF alignment, SFI compliance, cross-module composition issues — these require PSRule expansion.

**Think of it as**: Your spellchecker. Fast and automatic.

## Tier 2 — Checkpoint Validation (manual, comprehensive)

Run at checkpoints during a session and always before committing:

```powershell
pwsh -NoProfile -File .github/skills/vibeshield-bicep/scripts/Invoke-BicepValidation.ps1 -Environment dev
```

**Chain**: `Invoke-BicepValidation.ps1` → `az bicep lint` + PSRule with file expansion → SARIF to `./output/`

**What it catches that lint misses**:
- **WAF alignment**: missing availability zones, no diagnostic settings, missing redundancy
- **SFI compliance**: public network access, missing managed identity, deprecated API versions
- **Module composition**: parameter mismatches visible only when modules expand from `main.bicep`

**Think of it as**: Your code review. Thorough and required.

### When to trigger Tier 2

- After completing each Bicep module
- After wiring module references in `main.bicep`
- After fixing PSRule violations (confirm fixes, catch regressions)
- When switching infrastructure layers (e.g., networking → compute)
- After significant refactors (monolith → modules, custom → AVM)
- Always before declaring work complete or committing

## SARIF Output

| Tier | Output location |
|------|-----------------|
| Tier 1 | stdout (native SARIF from `az bicep lint`) |
| Tier 2 | `./output/bicep-lint-results.sarif` and `./output/psrule-results.sarif` |

Agents should read SARIF files directly. Do not pipe, filter, or post-process console output.

## Exit Codes

- `0` = pass (no violations)
- `1` = violations found
- `2` = invalid arguments (wrong extension, excluded path, file not found)

## Validation Loop

Run → review output → fix all violations → re-run → repeat until exit 0.
