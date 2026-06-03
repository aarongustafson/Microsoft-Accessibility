# CFS Detection -- Overview

How the safe-libraries installer handles existing feed config files across NuGet, npm, and pip.

**Full design spec archived at:** `.vibeshield/Documentation/vibeshield-safe-libraries/ExistingFeeds-CFS-Detection-Spec.md`

## What Happens During Install

When the installer finds an existing config file (`nuget.config`, `.npmrc`, or `pip.ini`/`pip.conf`), it does **not** blindly overwrite it. Instead it checks whether the config already points to a known internal CFS-backed Azure Artifacts feed:

| Existing config points to... | Installer action |
|------------------------------|-----------------|
| A known internal ADO feed, correctly structured | **Skip** — config is preserved as-is |
| A known internal ADO feed, partially valid (e.g., NuGet missing `<clear />`, pip with `extra-index-url`) | **Fix in place** — repair the specific issue, backup original to `.bak` |
| A public registry, unknown ADO org, or malformed file | **Backup** original to `.bak`, then **replace** with the CFS config |
| No config file exists | **Create** the CFS config |

Backups are written to `{filename}.bak` in the same directory. Overwritten each run. No backup is created when the config is skipped.

## What "Known Internal ADO Feed" Means

The installer maintains a list of recognized Microsoft ADO organizations in `Install-OrgList.ps1`. A feed URL is considered internal if it matches:

```
https://pkgs.dev.azure.com/{ORG}/{PROJECT}/_packaging/{FEED}/...
https://pkgs.dev.azure.com/{ORG}/_packaging/{FEED}/...
```

...and `{ORG}` is in the known-org list (case-insensitive). Both project-scoped and org-scoped feed URLs are valid. HTTPS is required.

## Reading Installer Output

| Message | Meaning |
|---------|---------|
| **CREATED** (green) | No config existed; new CFS config installed |
| **SKIPPED** (green) | Existing config is valid CFS — left alone |
| **FIXED** (green) | Existing config was partially valid; repaired in place |
| **BACKUP** (cyan) | Original config saved to `.bak` before modification |
| **WARNING** (yellow) | Explains why a config was replaced or fixed |
| **REPLACED** (green) | Invalid config replaced with CFS version |

## Troubleshooting

### "My existing config was replaced and builds broke"

1. Check for `{filename}.bak` in the same directory — restore it if needed.
2. The config was replaced because it didn't point to a recognized internal ADO feed. If your org should be recognized, it may need to be added to `Install-OrgList.ps1`.

### "The installer skipped my config but packages aren't resolving"

The installer only checks that the feed URL points to a known org — it doesn't verify the feed actually exists or that you have permissions. Check:
- Is the feed URL correct? (project name, feed name)
- Do you have permissions on the feed?
- Are you connected to the network/VPN?
- Have you authenticated? (see per-ecosystem auth steps below)

### "I see a WARNING but the install continued"

Warnings are informational — they explain *why* a replacement or fix was needed but the installer proceeds. Read the warning to understand what changed.

## Per-Ecosystem Details

- [cfs-detection-nuget.md](cfs-detection-nuget.md) — NuGet XML config: `<clear />` handling, auth with credential provider
- [cfs-detection-npm.md](cfs-detection-npm.md) — npm `.npmrc`: scoped registries, `vsts-npm-auth` setup
- [cfs-detection-pip.md](cfs-detection-pip.md) — pip config: `extra-index-url` risks, keyring auth
