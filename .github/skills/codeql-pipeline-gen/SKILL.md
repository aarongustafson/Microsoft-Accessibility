---
name: codeql-pipeline-gen
description: "Generate and validate Azure Pipelines CI/CD definitions for server-side CodeQL scanning. Use when setting up CI/CD, verifying pipeline configuration, troubleshooting pipeline failures, or customizing the scan pipeline template for Azure DevOps."
argument-hint: "Describe what you need: set up CI/CD, verify pipeline, fix pipeline failure, or customize scan configuration"
user-invocable: true
disable-model-invocation: false
---

# Pipeline Generation Skill

Generate and validate Azure Pipelines definitions for server-side CodeQL scanning. This agent targets **Azure DevOps repos only** -- GitHub Actions are not applicable.

## When to Use

- User asks to **set up CI/CD** scanning (Prompt 30)
- User asks to **verify CI/CD** integration (Prompt 31)
- Pipeline **fails** during CodeQL scan
- User asks about **language configuration** in the pipeline
- User asks about **branch policies** for scan enforcement
- User asks to **customize** the pipeline template

## Pipeline Template

The agent ships a template at `azure-pipelines/codeql-scan.yml`. The setup process:

1. Detect languages by scanning workspace files with `git ls-files` and mapping extensions via `$extMap`.
2. Validate detected languages against `codeql resolve languages`.
3. Copy the template into the consuming repo.
4. Replace `AGENT_PLACEHOLDER` language variable with detected languages (comma-separated).

### Template Structure

The template includes:
- **Trigger:** Runs on pushes to `main`/`master` branches
- **PR trigger:** Runs on PRs targeting `main`, `master`, `develop`
- **Pool:** `ubuntu-latest` (CodeQL CLI is downloaded at runtime)
- **Steps:**
  1. Full checkout (`fetchDepth: 0` -- CodeQL needs complete source)
  2. Install CodeQL CLI (download latest release from GitHub)
  3. Create database per language
  4. Run analysis with `security-extended` suite (full suite for CI)
  5. Parse SARIF and check for blocking findings
  6. Publish SARIF as pipeline artifact

### Key Differences from Pre-Commit Scan

| Aspect | Pre-Commit | CI/CD Pipeline |
|---|---|---|
| Query suite | `security-queries` (fast) | `security-extended` (thorough) |
| Scope | Changed files only (incremental) | Full codebase |
| Languages | Only languages with changes | All detected languages |
| Blocking | Blocks commit | Fails pipeline build |
| Runner | Developer machine | Azure Pipelines agent |

## Language Configuration

### Detection

Languages are detected the same way as local scans:

```powershell
$extMap = @{
    '.js'='javascript'; '.jsx'='javascript'; '.ts'='javascript'; '.tsx'='javascript'
    '.mjs'='javascript'; '.cjs'='javascript'
    '.py'='python'; '.pyw'='python'
    '.java'='java'; '.kt'='java'; '.kts'='java'
    '.cs'='csharp'
    '.c'='cpp'; '.h'='cpp'; '.cpp'='cpp'; '.hpp'='cpp'; '.cc'='cpp'; '.cxx'='cpp'
    '.go'='go'
    '.rb'='ruby'; '.erb'='ruby'
    '.swift'='swift'
}
```

### Validation

After detection, validate with `codeql resolve languages` to confirm CodeQL supports them. The pipeline variable `codeqlLanguages` is set to the comma-separated list (e.g., `'javascript,python,csharp'`).

## Verification Checklist (Prompt 31)

When verifying CI/CD integration:

1. **File exists:** Check for `azure-pipelines/codeql-scan.yml`.
2. **Language list matches:** Re-detect workspace languages and compare to the pipeline's `codeqlLanguages` variable. Flag mismatches.
3. **Query suite format:** Validate paths use fully-qualified pack format:
   ```
   codeql/$lang-queries:codeql-suites/$lang-security-extended.qls
   ```
   Bare names like `security-extended` fail with "Query pack cannot be found".
4. **Report status:**
   - `[PASS] CI/CD scanning configured` -- file exists AND languages match
   - `[WARN] Language mismatch` -- pipeline languages differ from workspace
   - `[WARN] No CI/CD pipeline found` -- file does not exist

## Troubleshooting Pipeline Failures

### CodeQL CLI Download Fails

**Symptom:** "Could not download CodeQL CLI" or network timeout in the Install step.

**Cause:** Pipeline agent cannot reach `api.github.com` or `github.com` (corporate proxy, firewall).

**Fix:**
- Configure proxy settings in pipeline agent
- Pre-install CodeQL CLI on a self-hosted agent
- Use an Azure Artifacts feed as a mirror for the CLI binary

### Database Creation Fails

**Symptom:** `codeql database create` exits non-zero.

**Cause:** Build dependencies not available on the pipeline agent.

**Fix:**
- Add prerequisite installation steps before the scan:
  ```yaml
  - task: UseDotNet@2           # For C#
    inputs:
      version: '8.x'
  - task: UseNode@1             # For JavaScript (if needed)
    inputs:
      version: '20.x'
  ```
- For Java: ensure JDK is installed and JAVA_HOME is set
- For Go: ensure Go is installed and go.mod dependencies are available

### Query Pack Resolution Fails

**Symptom:** "Query pack cannot be found" during analysis.

**Cause:** Bare suite name instead of fully-qualified pack path, or CodeQL pack registry unreachable.

**Fix:**
- Use fully-qualified format: `codeql/$lang-queries:codeql-suites/$lang-security-extended.qls`
- Ensure the pipeline agent can reach the CodeQL package registry
- Pre-download packs: `codeql pack download codeql/$lang-queries`

### SARIF Parsing Errors

**Symptom:** Pipeline passes but findings are not reported.

**Cause:** SARIF file not generated, or parsing step failed silently.

**Fix:**
- Verify `.codeql-results-$lang.sarif` files exist after analysis
- Check `$LASTEXITCODE` after each `codeql database analyze` call
- Ensure `ConvertFrom-Json` depth is sufficient (`-Depth 20`)

## Branch Policy Integration

After the pipeline is set up, configure Azure DevOps branch policies for enforcement:

1. **Project Settings** > **Repos** > **Policies** > target branch (e.g., `main`)
2. **Build Validation** > Add the CodeQL pipeline
3. Set to **Required** (blocks PR merge if scan fails)
4. Configure **trigger:** Automatic (runs on every PR update)

This creates server-side enforcement that complements the pre-commit hook. Even if a developer bypasses the local hook (e.g., different machine without the setup), the pipeline blocks the merge.

## Customization

### Adding Languages

Update the `codeqlLanguages` variable in the pipeline YAML:
```yaml
variables:
  codeqlLanguages: 'javascript,python,csharp,java'
```

### Changing Query Suite

To use the lighter security-only suite (not recommended for CI):
```yaml
$suite = "codeql/${lang}-queries:codeql-suites/${lang}-security-extended.qls"
```

### Self-Hosted Agents

For faster builds, pre-install CodeQL CLI on a self-hosted agent:
1. Download from https://github.com/github/codeql-cli-binaries/releases
2. Extract to a known path on the agent
3. Add to agent's PATH
4. Remove the "Install CodeQL CLI" step from the pipeline

## Cross-References

- **Agent spec CI/CD Setup section** -- Pipeline generation procedure (source of truth)
- **azure-pipelines/codeql-scan.yml** -- Template file shipped with this agent
- **codeql-build-prereqs** -- Language-specific build tool requirements for pipeline agents
- **codeql-sarif-analysis** -- SARIF parsing and severity classification used in pipeline
