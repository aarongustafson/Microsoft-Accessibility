# CFS Detection -- NuGet

**Config file:** `nuget.config` (project root) | **Format:** XML

## What a Valid CFS Config Looks Like

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="CFS" value="https://pkgs.dev.azure.com/{ORG}/{PROJECT}/_packaging/{FEED}/nuget/v3/index.json" />
  </packageSources>
</configuration>
```

Key requirements:
- `<clear />` must appear **before** the `<add>` — this removes inherited/default public sources
- Exactly **one** `<add>` entry pointing to an internal ADO feed (HTTPS, v3 endpoint)
- The ADO organization in the URL must be in the known-org list

Extra XML sections (credentials, source mappings, `<disabledPackageSources>`) are fine and do not affect validation.

## What the Installer Does

| Existing `nuget.config` | Action |
|--------------------------|--------|
| None exists | **Create** with CFS config |
| Valid: `<clear />` + single internal feed | **Skip** — preserved as-is |
| Internal feed but `<clear />` missing | **Fix**: backup to `.bak`, add `<clear />` before `<add>` |
| Internal feed but `<clear />` after `<add>` | **Fix**: backup to `.bak`, reorder so `<clear />` comes first |
| Multiple `<add>` entries | **Replace**: backup to `.bak`, install CFS config |
| Public feed (nuget.org) | **Replace**: backup to `.bak`, install CFS config |
| Unknown ADO org | **Replace**: backup to `.bak`, install CFS config (warning emitted) |
| Malformed XML | **Replace**: backup to `.bak`, install CFS config |
| HTTP or v2 feed URL | **Replace**: backup to `.bak`, install CFS config |

## Why `<clear />` Matters

Without `<clear />`, NuGet inherits package sources from machine-level configs and defaults — including `nuget.org`. This means packages can be pulled from public sources even when an internal feed is configured, which is a supply-chain risk (dependency confusion). The `<clear />` directive ensures only the explicitly listed feed is used.

## Troubleshooting

### "Package not found" after install

1. **Check authentication.** Run `dotnet restore` — if prompted, sign in with your Microsoft account. The Azure Artifacts Credential Provider handles authentication automatically.
2. **Credential provider missing?** Run the bootstrap installer:
   - Windows: `iex "& { $(irm https://aka.ms/install-artifacts-credprovider.ps1) }"`
   - Linux/macOS: `sh -c "$(curl -fsSL https://aka.ms/install-artifacts-credprovider.sh)"`
3. **Check the feed URL.** Open the URL from your `nuget.config` in a browser — it should return JSON. If it 404s, the project or feed name may be wrong.
4. **Check permissions.** You need at least Reader access on the Azure Artifacts feed.

### "My nuget.config was replaced — builds broke"

1. Restore from `nuget.config.bak` in the same directory.
2. The config was replaced because it didn't meet CFS criteria (public feed, unknown org, malformed XML, or multiple sources). If your org should be recognized, it may need to be added to the known-org list.

### "I have `<clear />` but packages still come from nuget.org"

Check for a `NuGet.Config` (capital-N) in a parent directory or in `%APPDATA%\NuGet\`. NuGet config files merge hierarchically. The project-level `<clear />` only clears sources inherited up to that point — a config in a child directory could re-add public sources.

### "dotnet restore is slow or times out"

- Check network/VPN connectivity to `pkgs.dev.azure.com`
- If behind a proxy, configure it in `nuget.config` under `<config><add key="http_proxy" ... />`
