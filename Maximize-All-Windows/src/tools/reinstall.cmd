@echo off
rem Publishes a fresh self-contained build and reinstalls it (uninstall then install).
setlocal
set "ROOT=%~dp0.."
set "EXE=%ROOT%\bin\publish\MaximizeAllWindows.exe"

taskkill /F /IM MaximizeAllWindows.exe >nul 2>&1
timeout /t 1 /nobreak >nul

dotnet publish "%ROOT%\MaximizeAllWindows.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o "%ROOT%\bin\publish" || exit /b 1

"%EXE%" --uninstall-silent
timeout /t 1 /nobreak >nul
"%EXE%" --install-silent
echo Done
