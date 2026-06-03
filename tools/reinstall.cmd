@echo off
taskkill /F /IM MaximizeAllWindows.exe >nul 2>&1
timeout /t 1 /nobreak >nul
"C:\Users\jecurry\OneDrive - Microsoft\Documents\GitHub\Maximize-All-Windows\artifacts\MaximizeAllWindows-2.0.0-rc2-win-x64\MaximizeAllWindows.exe" --uninstall-silent
timeout /t 1 /nobreak >nul
"C:\Users\jecurry\OneDrive - Microsoft\Documents\GitHub\Maximize-All-Windows\artifacts\MaximizeAllWindows-2.0.0-rc2-win-x64\MaximizeAllWindows.exe" --install-silent
echo Done
