# MaximizeAllWindows Pipeline Run Guide

This guide explains how to run the 1ES build pipeline and download the produced binary.

Pipeline file:
- `.azdo/pipelines/1ES-Unofficial-MaximizeAllWindows.yml`

Pipeline runs URL:
- https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_build?definitionId=6072

## What this pipeline produces

The pipeline builds and publishes a self-contained Windows x64 release.

- Pipeline artifact name: `MaximizeAllWindows-win-x64`
- Output folder inside artifact: `publish`
- Universal Package name: `maximizeallwindows-win-x64`
- Universal Package feed: `CELA_Demos_and_POCs/CElaDemosAndPOCs`
- Package version format: `1.0.<BuildId>`

Azure Artifacts feed URL:
- https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_artifacts/feed/CELADemosAndPOCs

## Refresh submodule with latest code

Before running the pipeline, update the `Microsoft-Accessibility` submodule so the build uses the latest upstream code.

Run from repository root:

```powershell
git submodule sync -- Microsoft-Accessibility
git submodule update --init Microsoft-Accessibility
git submodule update --remote Microsoft-Accessibility
```

Then commit the updated submodule pointer in this repo and push your branch:

```powershell
git add Microsoft-Accessibility
git commit -m "Update Microsoft-Accessibility submodule"
git push
```

Notes:
- `git submodule update --remote Microsoft-Accessibility` pulls the latest commit from the submodule's default branch.
- If no new submodule commit is available, `git commit` will report nothing to commit.

## Run the pipeline in Azure DevOps

1. Open your Azure DevOps project:
  - https://dev.azure.com/oneCELA/CELA_Demos_and_POCs
2. Open pipeline runs directly:
  - https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_build?definitionId=6072
3. Select Run pipeline.
4. Choose the branch (usually `main`).
5. Start the run and wait until the Build stage finishes successfully.

## Download binary from pipeline artifact (recommended)

1. Open the completed pipeline run.
2. In the Summary page, find the Related section.
3. Select Published (for example, "3 published").
4. In Artifacts published, expand MaximizeAllWindows-win-x64.
5. Select MaximizeAllWindows.exe.
6. Download the .exe from that artifact entry.

## Download binary from Azure Artifacts Universal Package

Use this if you want versioned package retrieval instead of run artifacts.

Prerequisites:
- Azure CLI installed.
- Azure DevOps extension for Azure CLI.
- Access to the Azure DevOps organization/project/feed.

Install extension (one-time):

```powershell
az extension add --name azure-devops
```

Set defaults:

```powershell
az devops configure --defaults organization=https://dev.azure.com/oneCELA project=CELA_Demos_and_POCs
```

Download latest known package version (replace `<version>`):

```powershell
az artifacts universal download \
  --feed CElaDemosAndPOCs \
  --name maximizeallwindows-win-x64 \
  --version <version> \
  --path .\downloaded-package
```

After download, open `.\downloaded-package` to get the published binary contents.

## Verify EXE signature

After you download `MaximizeAllWindows.exe`, verify that the Authenticode signature is valid.

### Option 1: File Explorer

1. Right-click `MaximizeAllWindows.exe` and select Properties.
2. Open the Digital Signatures tab.
3. Select the signature and choose Details.
4. Confirm the message shows The digital signature is OK.

### Option 2: PowerShell

Run this command from the folder containing the EXE:

```powershell
$sig = Get-AuthenticodeSignature .\MaximizeAllWindows.exe
$sig | Format-List Status, StatusMessage, SignerCertificate, TimeStamperCertificate
```

Expected result:
- `Status` should be `Valid`.
- `SignerCertificate` should match your expected publisher identity.

## Notes

- This is a build-only pipeline. It does not provision or deploy Azure resources.
- The pipeline triggers on pushes and pull requests targeting `main`.

Next: [README](../README.txt) | Back to: [README](../README.txt)
