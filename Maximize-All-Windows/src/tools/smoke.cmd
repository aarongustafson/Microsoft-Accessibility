@echo off
rem Runs the UI smoke test. Pass -Exe "path\to\MaximizeAllWindows.exe" to override
rem the default (src\bin\publish\MaximizeAllWindows.exe).
setlocal
set "HERE=%~dp0"
taskkill /F /IM MaximizeAllWindows.exe >nul 2>&1
powershell.exe -ExecutionPolicy Bypass -File "%HERE%smoke-test.ps1" %* > "%TEMP%\smoke.log" 2>&1
type "%TEMP%\smoke.log"
