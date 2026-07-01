# Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Building from source

### Maximize-All-Windows

**Prerequisites**

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (the app targets `net8.0-windows`)
- Windows 10 or later (the project uses Windows Forms and Win32 APIs)

The project has no external NuGet package dependencies, so a default `nuget.org`
restore is all that is required.

**Build**

```powershell
# From the Maximize-All-Windows folder
dotnet build MaximizeAllWindows.sln -c Release
```

**Run (debug)**

```powershell
dotnet run --project src/MaximizeAllWindows.csproj
```

**Produce a self-contained, single-file executable** (the shareable build; no .NET
install required on the target machine):

```powershell
dotnet publish src/MaximizeAllWindows.csproj -c Release -r win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -o artifacts/MaximizeAllWindows-win-x64
```

The app version is defined in [src/MaximizeAllWindows.csproj](Maximize-All-Windows/src/MaximizeAllWindows.csproj)
(`Version` / `FileVersion`) and the user-facing label in
[src/Program.cs](Maximize-All-Windows/src/Program.cs) (`AppInfo.DisplayVersion`); keep the two in sync.
