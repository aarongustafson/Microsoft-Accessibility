# CFS Detection -- npm

**Config file:** `.npmrc` (project root) | **Format:** Key-value, line-based

## What a Valid CFS Config Looks Like

```ini
registry=https://pkgs.dev.azure.com/{ORG}/{PROJECT}/_packaging/{FEED}/npm/registry/
always-auth=true
```

Key requirements:
- Exactly **one** global `registry=` line pointing to an internal ADO npm feed (HTTPS)
- The ADO organization in the URL must be in the known-org list
- No `@scope:registry=` lines pointing to public/non-internal feeds

Scoped registries (`@scope:registry=`) pointing to internal ADO feeds are fine. Extra settings like `save-exact`, proxy configs, and `//` auth tokens do not affect validation.

## What the Installer Does

| Existing `.npmrc` | Action |
|--------------------|--------|
| None exists | **Create** with CFS config |
| Valid: single internal registry, no bad scoped registries | **Skip** — preserved as-is |
| Public registry (`registry.npmjs.org`) | **Replace**: backup to `.bak`, install CFS config |
| Multiple global `registry=` lines | **Replace**: backup to `.bak`, install CFS config |
| Scoped registry pointing to public feed | **Replace**: backup to `.bak`, install CFS config |
| Unknown ADO org | **Replace**: backup to `.bak`, install CFS config (warning emitted) |
| HTTP feed URL | **Replace**: backup to `.bak`, install CFS config |
| Empty `.npmrc` | **Replace**: backup to `.bak`, install CFS config |

There is no fix-in-place for npm — configs are either valid or fully replaced.

## Authentication

npm uses `vsts-npm-auth` for Azure Artifacts authentication. After the installer runs:

1. The installer installs `vsts-npm-auth` globally via `npm install -g vsts-npm-auth`
2. **You must run this once per terminal session** before any npm operations:
   ```
   npx vsts-npm-auth -config .npmrc
   ```
   This writes auth tokens into your user-level `.npmrc` (`~/.npmrc`). The tokens expire, so you'll need to re-run this periodically.

## Troubleshooting

### "npm ERR! 401 Unauthorized" or "Unable to authenticate"

1. Run `npx vsts-npm-auth -config .npmrc` — tokens may have expired.
2. If that fails, check that `vsts-npm-auth` is installed: `npm list -g vsts-npm-auth`
3. If not installed: `npm install -g vsts-npm-auth`
4. Check that you have permissions on the Azure Artifacts feed.

### "npm ERR! 404 Not Found" for a package

1. The package may not exist in the internal feed yet. When `always-auth=true` is set, npm only looks at the configured registry — not the public registry.
2. Check if the package is available in the feed via the Azure DevOps Artifacts web UI.
3. If the package is public-only, it needs to be added to the feed's upstream sources (this is an ADO feed admin action, not a config change).

### "My .npmrc was replaced — installs broke"

1. Restore from `.npmrc.bak` in the same directory.
2. The config was replaced because it had a public registry, scoped registry pointing to a public feed, or an unknown ADO org. If your org should be recognized, it may need to be added to the known-org list.

### "npm is not found but I have Node.js installed"

- The installer checks standard PATH locations and also probes `~/.agency/nodejs/node-vX.Y.Z-<platform>/` for Agency-managed Node.js installs.
- If npm is installed somewhere else, add it to PATH and re-run the installer.

### Scoped registries

If your project uses `@scope:registry=` lines to point specific scopes at internal feeds, the installer preserves these when skipping. If any scoped registry points to a public feed (e.g., `registry.npmjs.org`), the entire config is replaced — the scoped public feed is a CFS bypass risk.
