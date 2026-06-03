# CFS Detection -- pip

**Config file:** `pip.ini` (Windows) or `pip.conf` (Linux/macOS) inside `.venv/` | **Format:** INI-style

## What a Valid CFS Config Looks Like

```ini
[global]
index-url = https://pkgs.dev.azure.com/{ORG}/{PROJECT}/_packaging/{FEED}/pypi/simple/
```

Key requirements:
- `[global]` section with `index-url` pointing to an internal ADO PyPI feed (HTTPS)
- The ADO organization in the URL must be in the known-org list
- **No** `extra-index-url` anywhere (dependency confusion vector)
- **No** `find-links` pointing to external URLs (CFS bypass vector)
- **No** `index-url` in `[install]` that overrides `[global]`

## What the Installer Does

| Existing pip config | Action |
|----------------------|--------|
| None exists | **Create** with CFS config |
| Valid: internal `index-url`, no unsafe directives | **Skip** — preserved as-is |
| Internal `index-url` but has `extra-index-url` | **Fix**: backup to `.bak`, remove `extra-index-url` lines |
| Internal `index-url` but has `find-links` to external URL | **Fix**: backup to `.bak`, remove unsafe `find-links` lines |
| `find-links` to local path (e.g., `/local/wheelhouse/`) | **Skip** — local paths don't introduce external sources |
| Public `index-url` (`pypi.org/simple/`) | **Replace**: backup to `.bak`, install CFS config |
| Unknown ADO org | **Replace**: backup to `.bak`, install CFS config (warning emitted) |
| Missing `[global]` section | **Replace**: backup to `.bak`, install CFS config |
| `index-url` in `[install]` overrides `[global]` | **Replace**: backup to `.bak`, install CFS config |
| HTTP feed URL | **Replace**: backup to `.bak`, install CFS config |

## Why `extra-index-url` Is Dangerous

`extra-index-url` adds supplementary package indexes that pip queries **alongside** `index-url`. If any supplementary index is public PyPI, an attacker can publish a same-named package with a higher version number — pip will prefer the higher version from the public index. This is the classic **dependency confusion** attack. Even if the `extra-index-url` points to another internal feed, it weakens the single-feed guarantee, so the installer removes it.

## Why `find-links` to URLs Is Dangerous

`find-links` pointing to an external URL lets pip fetch packages from a source that bypasses CFS scanning entirely. Local file paths (e.g., `/local/wheelhouse/`) are safe because they don't introduce an external source.

## Authentication

pip uses `keyring` + `artifacts-keyring` for Azure Artifacts authentication:

1. The installer creates a `.venv/` virtualenv and installs `keyring` + `artifacts-keyring` from public PyPI **before** copying the CFS pip config (avoids circular dependency — you need public PyPI access to get the auth packages).
2. On first `pip install` from the internal feed, `artifacts-keyring` opens a browser for Microsoft Entra ID authentication. Subsequent installs use cached tokens.
3. On Linux, `artifacts-keyring` may need additional prerequisites — see the ADO "Connect to feed" dialog for your feed.

## Troubleshooting

### "pip install" fails with 401 or "Could not fetch URL"

1. **Check keyring is installed:** `.venv/Scripts/pip list | findstr keyring` (Windows) or `.venv/bin/pip list | grep keyring` (Linux/macOS). You should see both `keyring` and `artifacts-keyring`.
2. **Reinstall keyring if missing:** Temporarily point pip at public PyPI to install auth packages:
   ```
   .venv/Scripts/pip install --index-url https://pypi.org/simple/ keyring artifacts-keyring
   ```
3. **Check the feed URL** in your pip config — open it in a browser. It should prompt for auth or show a page. A 404 means wrong project/feed name.
4. **Check permissions** on the Azure Artifacts feed.
5. **Linux users:** Ensure `artifacts-keyring` prerequisites are met (see ADO docs).

### "My pip config was replaced — installs broke"

1. Restore from `pip.ini.bak` (or `pip.conf.bak`) in the `.venv/` directory.
2. The config was replaced because it pointed to a public index, unknown org, or had a structural issue. If your org should be recognized, it may need to be added to the known-org list.

### "The installer removed my extra-index-url — I need it"

The `extra-index-url` was removed because it introduces a dependency confusion risk. If you need packages from multiple internal feeds:
- Ask your feed admin to add the other feed as an **upstream source** on the primary CFS feed — this keeps the single-index guarantee while still accessing packages from both feeds.
- Do **not** re-add `extra-index-url` manually.

### "pip is slow or times out"

- Check network/VPN connectivity to `pkgs.dev.azure.com`
- Azure Artifacts PyPI feeds can be slower than public PyPI for the initial package fetch. Subsequent installs use pip's local cache.

### Config file location

The pip config lives **inside the virtualenv** (`.venv/pip.ini` on Windows, `.venv/pip.conf` on Linux/macOS), not in the project root. This scopes the CFS feed to the virtualenv rather than affecting the system-wide pip configuration.
