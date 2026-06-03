---
name: deploy-response-personalization
description: 'Resolve, apply, and persist user response preferences (verbosity, tone, confirmations, emoji, etc.). Use when: preference resolution, personalization, set verbosity, change tone, inline toggle, save preferences, preference profile, beginner mode, developer mode, ci-automation mode, user preferences YAML.'
user-invocable: false
---

# Response Personalization

Manages user response preferences across the deployment session — resolution, application, inline toggles, and persistence.

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Preference profiles** | Supports beginner, developer, and ci-automation mode with preset defaults |
| **Verbosity control** | Adjustable verbosity levels: minimal, normal, detailed |
| **Tone selection** | Friendly, neutral, or technical communication tone |
| **Confirmation toggles** | Controls whether confirmations are required before irreversible actions |
| **Emoji preferences** | Enable/disable emoji in agent responses |
| **Inline toggles** | Users can change preferences mid-session with natural language commands |
| **YAML persistence** | Saves preferences to `.vibeshield/deploy-default-preferences.yaml` for reuse |

## When to Use

- At **session start**: resolve preferences before any output
- When the user issues an **inline toggle** command ("be concise", "use developer mode", etc.)
- When the user says **"save these preferences"**
- When a sub-agent needs to read the current preferences from the state file

## Architecture

### Preference Axes

| Axis | Values | Default | Effect |
|------|--------|---------|--------|
| `verbosity` | `minimal` · `standard` · `detailed` | `standard`* | How much explanation surrounds each action |
| `tone` | `friendly` · `professional` · `terse` | `professional`* | Formality of language |
| `confirmations` | `always` · `irreversible-only` · `auto` | `irreversible-only`* | When to prompt for approval (`auto` only in poc/dev) |
| `progress_format` | `grouped` · `per-check` · `silent` | `grouped`* | How multi-step results are presented |
| `error_detail` | `actionable` · `technical` · `both` | `both`* | How failures are reported |
| `emoji` | `true` · `false` | `true`* | Whether to use status emoji (✅ ❌ ⚠️) |
| `inline_definitions` | `true` · `false` | `false`* | Define jargon in parentheses on first use |
| `profile` | `beginner` · `developer` · `ci-automation` | `developer` | Named bundle that sets multiple axes at once |

*Effective defaults shown above reflect the **developer** profile (the built-in default profile).

### Named Profiles

| Profile | verbosity | tone | confirmations | progress_format | error_detail | emoji | inline_definitions |
|---------|-----------|------|---------------|-----------------|--------------|-------|--------------------|
| **beginner** | detailed | friendly | always | per-check | actionable | true | true |
| **developer** | standard | professional | irreversible-only | grouped | both | true | false |
| **ci-automation** | minimal | terse | auto | silent | technical | false | false |

### Resolution Order (highest priority last)

1. **Built-in defaults** — `Get-DefaultPreferences` (profile: `developer`)
2. **Team preferences** — `.vibeshield/team-preferences.yaml` (checked into repo)
3. **User preferences** — `.vibeshield/user-preferences.yaml` (.gitignored)
4. **Session overrides** — inline commands from the user during the conversation

### Derived Rules

- `verbosity: minimal` forces `inline_definitions: false` regardless of explicit setting
- `confirmations: auto` is only honoured in poc/dev environments; uat/prod always enforce at least `irreversible-only`

## How to Resolve Preferences

The orchestrator calls this **once** at session start. Sub-agents read from the state file — they do NOT re-resolve.

```powershell
# SharedHelpers.ps1 must be dot-sourced
$prefs = Resolve-UserPreferences -WorkspacePath .
```

Store result in state:
```powershell
./.github/skills/deploy-state-management/scripts/Invoke-StateFileManager.ps1 `
  -Action Write -WorkspacePath . -StateJson '{"Preferences": <resolved-json>}'
```

## Inline Toggle Commands

Users adjust preferences mid-session with natural-language phrases. The orchestrator detects these via `Get-InlinePreferenceToggle`.

| Phrase | Effect |
|--------|--------|
| "be concise" / "less detail" / "be brief" | `verbosity: minimal`, definitions off |
| "explain more" / "more detail" | `verbosity: detailed`, definitions on |
| "skip confirmations" / "auto-confirm" | `confirmations: auto` |
| "show raw output" / "raw mode" | `progress_format: per-check`, `error_detail: technical` |
| "use beginner mode" | Activates beginner profile |
| "use developer mode" | Activates developer profile |
| "use ci-automation mode" | Activates ci-automation profile |
| "save these preferences" | Persist session overrides to `user-preferences.yaml` |

## Persistence

When the user says "save these preferences":

1. Call `Save-UserPreferences -WorkspacePath . -Preferences $currentPrefs`
2. Only non-default values are written to `.vibeshield/user-preferences.yaml`
3. If all values match defaults, the file is removed

## Reference File

`.github/config/deploy-config.json` — canonical source of default preferences and profiles (under the `preferences` key). Users create `.vibeshield/user-preferences.yaml` with only the axes they wish to override.

## SharedHelpers.ps1 Functions

| Function | Purpose |
|----------|---------|
| `Get-DeployConfig` | Loads and caches `.github/config/deploy-config.json` |
| `Get-DefaultPreferences` | Returns built-in default preferences hashtable from config |
| `Get-PreferenceProfile` | Returns axis values for a named profile from config |
| `Resolve-UserPreferences` | Merges defaults → team → user → session; validates enums |
| `Save-UserPreferences` | Persists non-default preferences to user YAML |
| `Get-InlinePreferenceToggle` | Detects natural-language toggle phrases |
| `ConvertFrom-SimpleYaml` | Parses flat YAML to hashtable |
| `ConvertTo-SimpleYaml` | Writes hashtable to flat YAML |

## Invariants (never change regardless of preferences)

- **Respectful language** — all output must be courteous and constructive; degrading, disrespectful, or profane language is never permitted, regardless of tone or verbosity setting
- Safety rules are always enforced
- Confirmation prompts for irreversible actions in uat/prod (auto only honoured in poc/dev)
- Error templates always shown for failures
- SARIF output format and content unchanged
- Term definitions always available via "explain [term]" even when `inline_definitions` is off
