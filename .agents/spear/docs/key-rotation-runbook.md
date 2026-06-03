# Key Rotation Runbook — PackageSupport Trust Anchors

This runbook describes how to refresh the pinned trust anchors used by
`.vibeshield/PackageSupport/Installers/Install-VibeShieldDotNet.ps1` and
`.vibeshield/PackageSupport/Installers/Install-NodeJS.ps1`.

All pinned anchors live in two files:

| File | Anchors |
|------|---------|
| `.vibeshield/PackageSupport/Private/MicrosoftConstants.ps1` | `$MicrosoftGpgFingerprint`, `$MicrosoftProdDebSha256` map (5 distros) |
| `.vibeshield/PackageSupport/Private/NodeJsConstants.ps1` | `$NodeJsVersion`, `$NodeJsLinuxX64Sha256`, `$NodeJsMacOsX64PkgSha256` |

The installers fail closed: a mismatch between any pinned value and what is
downloaded from upstream halts the install with an explicit MITM / version-drift
diagnostic referring back to this runbook. Refreshing a pin is therefore both a
maintenance task (when upstream rotates) and an incident response task (when an
end user hits a fingerprint or SHA256 mismatch).

---

## Section 1 — Microsoft GPG fingerprint (`$MicrosoftGpgFingerprint`)

**Current value**: `BC528686B50D79E339D3721CEB3E94ADBE1229CF`
**Location**: `.vibeshield/PackageSupport/Private/MicrosoftConstants.ps1` (top of file).
**Source of truth**: `https://packages.microsoft.com/keys/microsoft.asc`
**Consumed by**: `Verify-GpgKey` (legacy / non-`.deb` Microsoft path; reserved for
future callers — the primary `.deb` path is SHA256-pinned via
`$MicrosoftProdDebSha256` and does not invoke `Verify-GpgKey`).

### When to rotate

- Microsoft publishes a new signing key (rare; the current fingerprint has been
  stable since at least 2024).
- An end user reports a `Verify-GpgKey` mismatch error. **Note**: as of PR4 (v0.53),
  `Verify-GpgKey` has no live caller in `Installers/` — the primary `.deb` path
  is SHA256-pinned via `$MicrosoftProdDebSha256` and bypasses GPG verification
  entirely. The helper is reserved for future callers (e.g., GPG verification
  of `SHASUMS256.txt.asc` against `$NodeJsReleaseKeyFingerprints`). Until a
  caller is wired, this trigger is theoretical. See `.vibeshield/Documentation/Phase6-InstallerHardening-Design.md` § "Out of scope for this design" for the future-work note.

### How to verify upstream

From a clean machine (or VM / container — anywhere your local agent is not
configured to MITM TLS):

```bash
# 1. Download the key
curl -fsSLO https://packages.microsoft.com/keys/microsoft.asc

# 2. Extract the fingerprint without importing into your real keyring
gpg --with-colons --import-options show-only --import microsoft.asc \
    | awk -F: '$1 == "fpr" { print $10; exit }'
```

The output must equal the value currently pinned in `MicrosoftConstants.ps1`.
If it does not, cross-check with **at least two** of the following independent
sources before treating the new fingerprint as authoritative:

- Microsoft Learn documentation (`Install .NET on Linux`, `Install PowerShell on
  Linux`), or any other official Microsoft page referencing `microsoft.asc`.
- The Debian / Ubuntu apt key in `packages-microsoft-prod.deb` (download the
  `.deb`, extract `data.tar.xz`, the keyring is under
  `./usr/share/keyrings/microsoft-prod.gpg` — convert with
  `gpg --no-default-keyring --keyring ./microsoft-prod.gpg --list-keys`).
- Microsoft Q&A / a Microsoft engineer / a customer support escalation.

### How to update in the codebase

1. Edit `.vibeshield/PackageSupport/Private/MicrosoftConstants.ps1`.
2. Replace the value of `$script:MicrosoftGpgFingerprint` with the new
   uppercase, no-space fingerprint.
3. Add a `## [x.y]` CHANGELOG entry with **Goal / Why / What** lines naming the
   new fingerprint, the date verified, and at least two confirming sources.
4. Bump `version.json` minor version.

### How to validate

```powershell
# Run the Verify-GpgKey Pester tests
pwsh -NoProfile -Command ". .\.vibeshield\AgentTests\Run-Tests.ps1 -Output Minimal `
    -Path .\.vibeshield\PackageSupport\Tests\Verify-GpgKey.Tests.ps1"
```

All `Verify-GpgKey.Tests.ps1` tests must pass. **Important**: these tests
exercise the verification *algorithm* using synthetic fingerprints; they
do **not** import `MicrosoftConstants.ps1` or read `$MicrosoftGpgFingerprint`.
A typo in the constant will therefore pass the test suite but fail at runtime
the next time `Verify-GpgKey` is called with the live constant. The strongest
validation today is the manual `gpg --with-colons` re-verification above; if
you also want a regression check, add a small Pester test that imports
`MicrosoftConstants.ps1` and asserts the constant matches an expected literal
(treat that literal as part of the rotation procedure — it gets updated in
lockstep).

---

## Section 2 — `packages-microsoft-prod.deb` SHA256 map (`$MicrosoftProdDebSha256`)

**Current entries** (5 distros):

| Key | Pinned SHA256 (lowercase) |
|-----|---------------------------|
| `ubuntu/24.04` | `c13f01ac7c3001b51a9281d40dde666db5e037e05512840c319832f7852bfec4` |
| `ubuntu/22.04` | `0d335c06ceb3227e330a36a7135997207843c726e42ec341e34a3825f151213b` |
| `ubuntu/20.04` | `3edd2ff1b9e18ca3bc93f46893b755400d1f22f4fb4c077c9d5882cd60d837b8` |
| `debian/12`    | `8434dcb8c346dc95fbd63dbece056c343704590b58b6a5c323d39acf52bf0b48` |
| `debian/11`    | `5235b2cd796f416905d4a01b6992c482e02abb957576d460a9c0a791e0837723` |

**Location**: `.vibeshield/PackageSupport/Private/MicrosoftConstants.ps1`.
**Source of truth**: `https://packages.microsoft.com/config/{distro}/{version}/packages-microsoft-prod.deb`
**Consumed by**: `Get-MicrosoftProdDebDescriptor` (private function in
`Sync-MicrosoftAptSource.ps1`) → `Sync-MicrosoftAptSource` Step 7b, which
verifies the downloaded `.deb` SHA256 before `dpkg -i`.

### When to rotate

- Microsoft re-publishes `packages-microsoft-prod.deb` for a given (distro,
  version) — this happens when the package itself is updated, not necessarily
  on a fixed schedule.
- An end user reports an `Install-VibeShieldDotNet` failure whose message
  contains `SHA256 mismatch for packages-microsoft-prod.deb`.
- A new Ubuntu LTS or Debian point release is added to the support whitelist
  (see [Section 4](#section-4--adding-a-new-supported-distro)).

### How to verify upstream

For each (distro, version) entry, run from a clean machine:

```powershell
$base = 'https://packages.microsoft.com/config'
$distros = @(
    @{Key='ubuntu/24.04'; Url="$base/ubuntu/24.04/packages-microsoft-prod.deb"}
    @{Key='ubuntu/22.04'; Url="$base/ubuntu/22.04/packages-microsoft-prod.deb"}
    @{Key='ubuntu/20.04'; Url="$base/ubuntu/20.04/packages-microsoft-prod.deb"}
    @{Key='debian/12';    Url="$base/debian/12/packages-microsoft-prod.deb"}
    @{Key='debian/11';    Url="$base/debian/11/packages-microsoft-prod.deb"}
)
foreach ($d in $distros) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.deb')
    try {
        Invoke-WebRequest -Uri $d.Url -OutFile $tmp -UseBasicParsing
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
        '{0} = {1}' -f $d.Key, $hash
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}
```

Each printed `key = hash` line must match the corresponding entry in
`$script:MicrosoftProdDebSha256`.

Cross-checks before treating new hashes as authoritative:

- Re-run the verification script from **a different network** (e.g., a personal
  laptop on a non-corporate connection) and confirm the hashes match. A
  divergence between corporate-network and external-network values is a strong
  signal of TLS interception or transparent caching, not legitimate rotation.
- Extract the keyring shipped inside the `.deb` and confirm its fingerprint
  matches `$MicrosoftGpgFingerprint`:
  ```bash
  # Linux / WSL
  dpkg-deb -x packages-microsoft-prod.deb extracted/
  gpg --no-default-keyring \
      --keyring extracted/usr/share/keyrings/microsoft-prod.gpg \
      --with-colons --list-keys \
      | awk -F: '$1 == "fpr" { print $10; exit }'
  ```
  The output must equal `$MicrosoftGpgFingerprint`. (Note: Debian binary
  `.deb` files are not themselves PGP-signed at the file level — the trust
  anchor is the SHA256 pin plus the embedded keyring fingerprint match.)
- If only one or two `.deb` SHA256 values changed: that is normal — Microsoft
  refreshes per (distro, version) independently. If all five changed at once:
  treat with suspicion and confirm via a Microsoft support channel.

### How to update in the codebase

1. Edit `.vibeshield/PackageSupport/Private/MicrosoftConstants.ps1`.
2. Replace the changed values in the `$script:MicrosoftProdDebSha256` hashtable.
   Use lowercase. One hash per line, aligned for readability — match the
   existing formatting.
3. Add a `## [x.y]` CHANGELOG entry naming each changed key, the old value, the
   new value, and the date verified.
4. Bump `version.json` minor version.

### How to validate

```powershell
# Run the Sync-MicrosoftAptSource Pester tests
pwsh -NoProfile -Command ". .\.vibeshield\AgentTests\Run-Tests.ps1 -Output Minimal `
    -Path .\.vibeshield\PackageSupport\Tests\Sync-MicrosoftAptSource.Tests.ps1"
```

The unit tests use synthetic hashes (not the pinned values), so changing
`MicrosoftConstants.ps1` does not affect test results — they verify the
*algorithm*. For end-to-end validation, run `Install-VibeShieldDotNet` on a
representative Ubuntu / Debian WSL distro and confirm the install completes
without `SHA256 mismatch` errors. Document the smoke test in the CHANGELOG
entry.

---

## Section 3 — Node.js pinned binary distribution (`$NodeJsVersion`, `$NodeJsLinuxX64Sha256`, `$NodeJsMacOsX64PkgSha256`)

**Current values**:

| Constant | Value |
|----------|-------|
| `$NodeJsVersion` | `22.11.0` |
| `$NodeJsLinuxX64Sha256` | `83bf07dd343002a26211cf1fcd46a9d9534219aad42ee02847816940bf610a72` |
| `$NodeJsMacOsX64PkgSha256` | `8d658eda7699d580ccc268ca8a40ced5aeecef5bb4d19c4187e92eebac5d68ec` |

**Location**: `.vibeshield/PackageSupport/Private/NodeJsConstants.ps1`.
**Sources of truth**:

- `https://nodejs.org/dist/v$NodeJsVersion/SHASUMS256.txt`
- `https://nodejs.org/dist/v$NodeJsVersion/node-v$NodeJsVersion-linux-x64.tar.xz`
- `https://nodejs.org/dist/v$NodeJsVersion/node-v$NodeJsVersion.pkg`

**Consumed by**: `Install-NodeJS.ps1` Linux branch (tarball + double SHA256
check) and macOS branch (`.pkg` + double SHA256 check + `pkgutil`
signature verification).

### When to rotate

Bump `$NodeJsVersion` to keep up with Node.js LTS releases. The LTS line follows
even major numbers. Authoritative schedule: the [`schedule.json`](https://github.com/nodejs/Release/blob/main/schedule.json)
file in the `nodejs/Release` repository, also rendered at
<https://nodejs.org/en/about/previous-releases>.

As of 2026-05 the relevant LTS lines are:

| Version | LTS start | Maintenance start | End-of-life |
|---------|-----------|-------------------|-------------|
| v22 (Jod)     | 2024-10-29 | 2025-10-21 | 2027-04-30 |
| v24 (Krypton) | 2025-10-28 | 2026-10-20 | 2028-04-30 |
| v26 (TBD)     | ~2026-10-27 (planned) | ~2027-10 | ~2029-04 |

**Today's pin** is v22.11.0 — in **maintenance LTS** since 2025-10-21. Active
LTS for new installs is v24. Plan a bump to v24.x when:

- An active-LTS security fix becomes available that the current maintenance
  line will not backport.
- The current pin approaches end-of-life (v22 ends 2027-04-30; we should be
  pinned to v24 or v26 well before then).
- An end user reports `SHA256 mismatch` (rare — would indicate either a forced
  upstream republish, which Node.js does not do, or a MITM event).

Do not bump to non-LTS (odd-major) versions in `main` — keep LTS-only for
production installers. When moving across major versions (e.g., v22 → v24),
also re-test the macOS `.pkg` path on representative hardware before merging,
since the `.pkg` packaging scripts can change between majors.

### How to verify upstream

From a clean machine:

```powershell
$ver = '22.11.0'   # the new version you intend to pin
$base = "https://nodejs.org/dist/v$ver"

# 1. Fetch and inspect the SHASUMS256.txt
$sums = (Invoke-WebRequest -Uri "$base/SHASUMS256.txt" -UseBasicParsing).Content
$sums -split "`n" | Where-Object { $_ -match '(linux-x64\.tar\.xz|^[^ ]+ {2}node-v.*\.pkg)' }
```

You should see two relevant lines, for example:

```
83bf07dd343002a26211cf1fcd46a9d9534219aad42ee02847816940bf610a72  node-v22.11.0-linux-x64.tar.xz
8d658eda7699d580ccc268ca8a40ced5aeecef5bb4d19c4187e92eebac5d68ec  node-v22.11.0.pkg
```

The two hashes are the values you will pin.

### Cross-checks before pinning

- Confirm the version exists at `https://nodejs.org/en/download/releases/` and
  is marked as LTS (or you are intentionally moving off LTS — document why).
- Optional belt-and-suspenders: verify `SHASUMS256.txt.asc` against the active
  Node.js release-team keys tracked at
  `https://github.com/nodejs/release-keys/tree/main/keys`. The
  `$NodeJsReleaseKeyFingerprints` array is commented out in
  `NodeJsConstants.ps1` for this purpose; an enabling implementer should match
  Verify-GpgKey's flow.

### How to update in the codebase

1. Edit `.vibeshield/PackageSupport/Private/NodeJsConstants.ps1`.
2. Replace `$script:NodeJsVersion`, `$script:NodeJsLinuxX64Sha256`, and
   `$script:NodeJsMacOsX64PkgSha256` with the new triple. All three MUST be
   updated together — the version constant gates both SHA256 values, and the
   installer's double-check (pinned == SHASUMS-published) will fail if you bump
   the version but forget either hash.
3. Add a `## [x.y]` CHANGELOG entry naming the old and new version, both SHA256
   values, the date verified, and (if applicable) the security fix(es) the
   bump pulls in.
4. Bump `version.json` minor version.

### How to validate

```powershell
# Run the Install-NodeJS Pester tests (Linux + macOS contexts skip on Windows)
pwsh -NoProfile -Command ". .\.vibeshield\AgentTests\Run-Tests.ps1 -Output Minimal `
    -Path .\.vibeshield\PackageSupport\Tests\Install-NodeJS.Tests.ps1"
```

Tests use synthetic SHASUMS content, not real downloads, so the test pass/fail
status is unaffected by the pin values. For end-to-end validation:

1. On WSL Ubuntu 22.04+ or 24.04: run `Install-NodeJS` and confirm it
   downloads, verifies, and extracts without errors. Confirm `node --version`
   reports the new pinned version.
2. On macOS: run `Install-NodeJS` and confirm `.pkg` install completes.

Document both smoke results in the CHANGELOG entry.

---

## Section 4 — Adding a new supported distro

When a new Ubuntu LTS or Debian point release is published and you want to add
it to the apt whitelist:

1. Confirm Microsoft publishes a `packages-microsoft-prod.deb` for the new
   (distro, version) by visiting
   `https://packages.microsoft.com/config/{distro}/{version}/packages-microsoft-prod.deb`
   in a browser. A 404 means the distro is not yet supported by Microsoft —
   wait until it is. Do not guess by reusing the previous version's `.deb`.
2. Follow [Section 2](#section-2--packages-microsoft-proddeb-sha256-map-microsoftproddebsha256)
   to fetch the SHA256 for the new `.deb`.
3. Add the new entry to `$script:MicrosoftProdDebSha256` in
   `MicrosoftConstants.ps1` — the key format is `<distro>/<version_id>` to
   match `Get-MicrosoftProdDebDescriptor`'s lookup pattern.
4. No changes needed to `Sync-MicrosoftAptSource.ps1` itself — the descriptor
   lookup automatically picks up the new map entry.
5. Add a CHANGELOG entry naming the new distro and the SHA256.
6. Bump `version.json` minor version.
7. End-to-end smoke test on the new distro before merging.

To **remove** a distro from the whitelist (e.g., it goes end-of-life): delete
its entry from `$script:MicrosoftProdDebSha256`. Users on that distro will then
fall through to `Install-DotNetViaInstallScript` automatically — no exception,
no broken install. Document in the CHANGELOG.

---

## Section 5 — Mismatch incident playbook

If an end user reports any of the following errors from a production install:

| Error | What it indicates |
|-------|-------------------|
| `GPG fingerprint mismatch for Microsoft key` | Section 1 (theoretical — `Verify-GpgKey` has no live caller as of v0.53; this row covers any future wire-up) |
| `SHA256 mismatch for packages-microsoft-prod.deb` | Section 2 |
| `SHA256 from SHASUMS256.txt ... does not match pinned NodeJsLinuxX64Sha256` | Section 3 |
| `SHA256 from SHASUMS256.txt ... does not match pinned NodeJsMacOsX64PkgSha256` | Section 3 |
| `SHA256 checksum mismatch for node-v...-linux-x64.tar.xz` | Section 3 |
| `SHA256 checksum mismatch for node-v....pkg` | Section 3 |

Diagnostic steps:

1. **Determine attribution**: legitimate upstream rotation vs. MITM. Re-run the
   "How to verify upstream" steps in the relevant section above **from a
   different network** than the user's. If your independent network also sees
   the new value, it is most likely an upstream rotation. If your independent
   network sees the *old* value, the user's network or device is compromised
   or behind a TLS-intercepting proxy.
2. If upstream rotation: refresh the pin per the relevant section's instructions,
   open a CHANGELOG entry, ship a new minor version.
3. If suspected MITM: hold the pin, advise the user to switch networks or
   inspect their corporate proxy / device certificate chain. Do **not** update
   the pin to satisfy a single user's network until you can independently
   reproduce.

---

## Section 6 — Quick reference

| Task | File(s) to edit | Tests to re-run | CHANGELOG section |
|------|-----------------|-----------------|-------------------|
| Microsoft GPG fingerprint rotation | `Private/MicrosoftConstants.ps1` | `Verify-GpgKey.Tests.ps1` | Section 1 |
| `packages-microsoft-prod.deb` SHA refresh | `Private/MicrosoftConstants.ps1` | `Sync-MicrosoftAptSource.Tests.ps1` + WSL smoke | Section 2 |
| Node.js version bump | `Private/NodeJsConstants.ps1` | `Install-NodeJS.Tests.ps1` + WSL + macOS smoke | Section 3 |
| Add supported distro | `Private/MicrosoftConstants.ps1` | `Sync-MicrosoftAptSource.Tests.ps1` + distro smoke | Section 4 |

Every change in this runbook is a `version.json` minor bump and a CHANGELOG
entry under the `Goal / Why / What` pattern documented in
`.specify/memory/constitution.md`.
