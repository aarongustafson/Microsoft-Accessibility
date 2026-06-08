@echo off
taskkill /F /IM MaximizeAllWindows.exe >nul 2>&1
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "C:\Users\jecurry\OneDrive - Microsoft\Documents\GitHub\Maximize-All-Windows\tools\smoke-test.ps1" -Exe "C:\Users\jecurry\OneDrive - Microsoft\Documents\GitHub\Maximize-All-Windows\artifacts\MaximizeAllWindows-2.0.0-rc2-win-x64\MaximizeAllWindows.exe" > "%TEMP%\smoke.log" 2>&1
type "%TEMP%\smoke.log"
