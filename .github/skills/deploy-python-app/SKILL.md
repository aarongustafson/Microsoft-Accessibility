---
name: deploy-python-app
description: 'Configure Python application deployment to Azure. Use when: Python app, Python version, Python deployment, pip install, requirements.txt, pyproject.toml, Python Functions, Flask, Django, FastAPI, Python build, Python runtime, ubuntu for Python.'
---

# Python App Deployment

## Capabilities & Features

| Capability | Description |
|-----------|-------------|
| **Python version detection** | Resolves the correct Python version from `runtime.txt`, `pyproject.toml`, or `.python-version` |
| **Framework detection** | Identifies Flask, Django, FastAPI, and generic WSGI/ASGI frameworks |
| **Build stage configuration** | Generates `UsePythonVersion@0` + `pip install` + `zip` pipeline tasks |
| **Azure Functions support** | Configures Python Functions deployment with `func azure functionapp publish` |
| **requirements.txt handling** | Auto-detects and installs from `requirements.txt` or `pyproject.toml` dependencies |
| **Ubuntu pool selection** | Ensures Python apps use Ubuntu-based agent pools (not Windows) |

## When to Use

- Deploying a Python application (Flask, Django, FastAPI, or any WSGI/ASGI framework)
- Deploying Azure Functions with Python runtime
- Selecting the correct Python version for the pipeline
- Configuring the build stage for a Python project
- Troubleshooting Python-specific deployment issues

## Hard Constraints

- Python apps MUST use `1ES-BuildPool` with `os: windows`. The Linux build image (`1ES-BuildPool-Ubuntu`) is not yet ready.
- If the project specifies a Python version constraint, **honor it** — that constraint takes absolute priority.
- If the project does NOT specify a version, attempt the **latest stable Python version first**. If that version is not compatible (with the project's libraries, Azure App Service runtime, or Azure Functions runtime), fall back to the next best compatible version.
- Version selection must account for three compatibility dimensions: **Python version**, **Python library compatibility**, and **Azure App Service / Azure Functions runtime supportability**.
- The build template is `build-python.yml` (`.github/templates/build-python.yml`).
- Python Functions apps use the same build pipeline as regular Python apps, with the addition of `host.json` packaging.

## Python Version Selection

> **Scripted implementation:** The version resolution algorithm below is implemented in `.github/skills/deploy-python-app/scripts/Resolve-PythonVersion.ps1`. Agents SHOULD run the script and use its output (`@{ Version; Source; Constraint }`) rather than re-implementing the logic inline.

### Priority Order

The agent MUST honor any Python version the project already specifies. If no version is specified, default to the latest stable version available.

Use the **first matching rule** to determine the Python version:

1. **`pyproject.toml` — `requires-python`**: If the project has a `pyproject.toml` with a `requires-python` field, **honor that constraint**. Use the latest stable version that satisfies it.
   ```toml
   [project]
   requires-python = ">=3.10"
   ```
   → Use the latest stable 3.x that is ≥3.10 (check the Version Compatibility Table below for current versions).

2. **`pyproject.toml` — `tool.poetry.dependencies.python`**: Poetry projects may specify the Python version here. **Honor the specified constraint.**
   ```toml
   [tool.poetry.dependencies]
   python = "^3.11"
   ```
   → Use 3.11.x or later compatible version.

3. **`runtime.txt`**: Some projects (e.g., Azure App Service) specify `python-3.x.y` in a `runtime.txt` file.
   → **Use the exact version specified.**

4. **`.python-version`**: If a `.python-version` file exists (used by pyenv), **use the version specified.**

5. **`setup.py` — `python_requires`**: Legacy projects may specify version constraints in `setup.py`. **Honor the constraint.**

6. **No version specified**: Attempt the **latest stable Python 3.x** first. If not compatible, fall back using the Version Resolution Algorithm below.

### Version Compatibility Table

| Python Version | Status | Azure App Service Support | Azure Functions Support | Library Ecosystem | Notes |
|----------------|--------|---------------------------|------------------------|-------------------|-------|
| 3.13 | Latest stable | Yes | Check runtime stack | Most libs supported; some C-extension libs may lag | Try first if no constraints |
| 3.12 | Stable | Yes | Yes (v4 runtime) | Broadly supported | Excellent fallback |
| 3.11 | Stable | Yes | Yes (v4 runtime) | Broadly supported | Safe default |
| 3.10 | Stable | Yes | Yes (v4 runtime) | Broadly supported | Minimum for many modern libs |
| 3.9 | Maintenance | Yes | Yes (v4 runtime) | Supported | End-of-life Dec 2025 |
| 3.8 | End of life | Limited | Limited | Declining | Avoid — upgrade project |
| 2.x | Unsupported | No | No | N/A | Reject — not supported |

### Version Resolution Algorithm

```
1. Read version constraint from project files (priority order above)
2. If constraint found:
   a. HONOR the project's specified version — do not override it
   b. Parse the constraint (e.g., ">=3.10,<3.13")
   c. Select the LATEST stable version satisfying the constraint
   d. Verify the selected version is supported by Azure App Service / Functions runtime
   e. If no stable version satisfies it, WARN and suggest updating the constraint
3. If NO constraint found:
   a. Start with the latest stable 3.x
   b. Check compatibility against these three dimensions:
      i.   Azure App Service / Functions runtime support (see table above)
      ii.  Python library compatibility — scan requirements.txt / pyproject.toml
           for known version-sensitive libraries (e.g., numpy, scipy, tensorflow,
           torch, pandas) and check their supported Python version ranges
      iii. 1ES-BuildPool availability
   c. If the latest version fails any compatibility check, step down to the
      next version in the table and repeat checks
   d. Select the HIGHEST version that passes all three checks
4. Verify the final selected version is available on 1ES-BuildPool
5. If not available, fall back to the nearest available version
6. Report the selected version and the reason to the user:
   - If latest was selected: "Using Python X.Y (latest stable)"
   - If a fallback was needed: "Using Python X.Y instead of X.Z because [reason]"
```

## Build Stage Configuration

The Python build template (`build-python.yml`) uses `UsePythonVersion@0`. Set `versionSpec` to the resolved version:

```yaml
- task: UsePythonVersion@0
  displayName: 'Set Python version'
  inputs:
    versionSpec: '3.12'  # Replace with resolved version
```

### Dependency Installation

Python dependencies are installed via pip using the project's configured Azure Artifacts feed for authenticated package access. The `PipAuthenticate@1` task MUST appear **before** any `pip install` step.

1. Authenticate with the feed:
   ```yaml
   - task: PipAuthenticate@1
     displayName: 'Authenticate with package feed'
     inputs:
       artifactFeeds: '<org/feed-name from pip.conf>'
   ```
2. Upgrade pip itself: `python -m pip install --upgrade pip`
3. Install project dependencies: `pip install -r requirements.txt`
4. If `pyproject.toml` exists with `[build-system]`: `pip install .`

The `PipAuthenticate@1` task sets the `PIP_INDEX_URL` environment variable so that subsequent `pip install` commands automatically use the configured feed. No manual `--index-url` flag is needed.

### Test Execution

- Default test runner: `pytest`
- Install pytest if not in requirements: `pip install pytest`
- Output JUnit XML for pipeline reporting: `pytest --junitxml=junit-results.xml`
- Always use `|| true` to prevent test failures from blocking the build artifact

#### Copilot-Authored App — Test Scaffolding Checklist

Copilot-generated Python projects often ship without the minimum test infrastructure that pytest requires. Before running build verification or the pipeline, ensure all of the following are in place:

1. **`pytest` is listed as a dependency** — add it to `requirements.txt` (or `[project.optional-dependencies.test]` in `pyproject.toml`). Without this, `pip install -r requirements.txt` won't install pytest and the test step will fail with "command not found".
2. **A `conftest.py` exists in the project root** — even an empty file. This anchors pytest's test collection and prevents path-resolution errors.
3. **At least one test file follows naming conventions** — files must match `test_*.py` or `*_test.py`. If the project genuinely has no tests, pass `-NoTests` to the BV script rather than leaving broken stubs.
4. **Test files import the correct modules** — Copilot may generate import paths that don't match the actual package structure. Verify imports resolve before running pytest.

### Artifact Packaging

Python apps are archived as a zip from the working directory:

```yaml
- task: ArchiveFiles@2
  inputs:
    rootFolderOrFile: '$(System.DefaultWorkingDirectory)'
    includeRootFolder: false
    archiveType: 'zip'
    archiveFile: '$(Build.ArtifactStagingDirectory)/$(Build.BuildId).zip'
```

## Deploy Configuration

### App Service

Python on App Service requires the Linux runtime stack. The deploy task (`AzureWebApp@1`) should specify:

```yaml
- task: AzureWebApp@1
  inputs:
    azureSubscription: '$(serviceConnection)'
    appType: 'webAppLinux'
    appName: '$(appName)'
    package: '$(System.ArtifactsDirectory)/drop/$(Build.BuildId).zip'
    runtimeStack: 'PYTHON|3.12'  # Match the build version
```

The `runtimeStack` value MUST match the Python version used in the build stage.

### Azure Functions

Python Functions require the Functions v4 runtime with Python worker:

```yaml
- task: AzureFunctionApp@2
  inputs:
    azureSubscription: '$(serviceConnection)'
    appType: 'functionAppLinux'
    appName: '$(appName)'
    package: '$(System.ArtifactsDirectory)/drop/$(Build.BuildId).zip'
    runtimeStack: 'PYTHON|3.12'
```

### Startup Command

For WSGI/ASGI frameworks, the startup command varies:

| Framework | Startup Command |
|-----------|----------------|
| Flask | `gunicorn --bind=0.0.0.0 --timeout 600 app:app` |
| Django | `gunicorn --bind=0.0.0.0 --timeout 600 <project>.wsgi` |
| FastAPI | `gunicorn --bind=0.0.0.0 --timeout 600 -k uvicorn.workers.UvicornWorker main:app` |

If a startup command is needed, set it via the `startUpCommand` input on `AzureWebApp@1` or configure it in the Bicep template's `siteConfig.appCommandLine`.

## Bicep Considerations

Python apps deployed to App Service require:

- `kind: 'app,linux'` on the `Microsoft.Web/sites` resource
- `siteConfig.linuxFxVersion: 'PYTHON|3.12'` matching the build/deploy version
- App Service Plan with `reserved: true` (required for Linux)

## Common Mistakes

| Mistake | Correction |
|---------|------------|
| Using `1ES-BuildPool-Ubuntu` for Python | Use `1ES-BuildPool` with `os: windows` — Linux image not yet ready |
| Hardcoding Python 3.8 or 3.9 | Use latest stable unless project constrains it |
| Using `python3` command instead of `python` | `UsePythonVersion@0` aliases `python` correctly |
| Missing `--upgrade pip` before install | Always upgrade pip first |
| Forgetting `runtimeStack` on deploy task | Must specify `PYTHON|<version>` for Linux App Service |
| Using `appType: 'webApp'` (Windows) | Must use `appType: 'webAppLinux'` for Python |
| Mismatched Python version between build and deploy | Build `versionSpec` and deploy `runtimeStack` must match |
| Using Python 2.x | Reject — Python 2 is not supported |
| Skipping `requirements.txt` check | Verify it exists before build (see Required Files in `deploy-app-type-select` skill) |
| Copilot-generated app missing `pytest` in `requirements.txt` | Add `pytest` to `requirements.txt` before running build verification |
| No `conftest.py` in project root | Create an empty `conftest.py` — pytest needs it to anchor test collection |
| Test files don't follow `test_*.py` / `*_test.py` naming | Rename to match pytest conventions or pass `-NoTests` if no tests exist |
