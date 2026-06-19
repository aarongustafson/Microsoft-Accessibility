# Smoke test for Maximize All Windows settings UI.
# Pre-seeds settings so the window opens immediately in taskbar mode, then drives
# the UI via System.Windows.Automation to verify controls and click behavior.
#
# Usage:
#   pwsh -File tools/smoke-test.ps1 -Exe "path\to\MaximizeAllWindows.exe"
# Defaults to the locally published build (src\bin\publish\MaximizeAllWindows.exe);
# produce it with tools\reinstall.cmd or a `dotnet publish` to that folder.

[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\publish\MaximizeAllWindows.exe')
)

$ErrorActionPreference = 'Stop'
$script:failures = @()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "PASS  $Message" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $Message" -ForegroundColor Red
        $script:failures += $Message
    }
}

# 1. Kill any running instance.
Get-Process -Name MaximizeAllWindows -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# 2. Pre-seed settings (taskbar mode, first-run done, startup off so registry isn't touched).
$settingsDir = Join-Path $env:LocalAppData 'MaximizeAllWindows'
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
@{
    StartWithWindows           = $false
    RunInSystemTray            = $false
    HasCompletedFirstRunPrompt = $true
} | ConvertTo-Json | Set-Content (Join-Path $settingsDir 'settings.json')

if (-not (Test-Path $Exe)) { throw "Exe not found: $Exe" }
Write-Host "Launching $Exe"
$proc = Start-Process -FilePath $Exe -PassThru

try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase

    $AE   = [System.Windows.Automation.AutomationElement]
    $TS   = [System.Windows.Automation.TreeScope]
    $AEP  = [System.Windows.Automation.AutomationElement]::NameProperty
    $CTP  = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
    $CT   = [System.Windows.Automation.ControlType]
    $INV  = [System.Windows.Automation.InvokePattern]::Pattern
    $SEL  = [System.Windows.Automation.SelectionItemPattern]::Pattern
    $WIN  = [System.Windows.Automation.WindowPattern]::Pattern

    function Wait-Window {
        param([string]$Name, [int]$TimeoutMs = 8000)
        $deadline = [Environment]::TickCount + $TimeoutMs
        do {
            $cond = New-Object System.Windows.Automation.PropertyCondition($AEP, $Name)
            $w = $AE::RootElement.FindFirst($TS::Children, $cond)
            if ($w) { return $w }
            Start-Sleep -Milliseconds 200
        } while ([Environment]::TickCount -lt $deadline)
        return $null
    }

    function Find-Descendant {
        param($Root, $ControlType, [string]$Name)
        $c1 = New-Object System.Windows.Automation.PropertyCondition($CTP, $ControlType)
        $c2 = New-Object System.Windows.Automation.PropertyCondition($AEP, $Name)
        $and = New-Object System.Windows.Automation.AndCondition($c1, $c2)
        return $Root.FindFirst($TS::Descendants, $and)
    }

    $window = Wait-Window 'Maximize All Windows'
    Assert-True ($null -ne $window) 'Settings window appears in taskbar mode startup'
    if (-not $window) { throw 'window not found' }

    # 3. Verify the "Show in" group is present and visible.
    $group = Find-Descendant $window $CT::Group 'Show in'
    Assert-True ($null -ne $group) 'GroupBox "Show in" is present with caption rendered'

    # 4. Verify radios.
    $trayRadio    = Find-Descendant $window $CT::RadioButton 'System tray, 1 of 2'
    $taskbarRadio = Find-Descendant $window $CT::RadioButton 'Taskbar, 2 of 2'
    Assert-True ($null -ne $trayRadio)    'Radio "System tray" is present'
    Assert-True ($null -ne $taskbarRadio) 'Radio "Taskbar" is present'

    $taskbarSel = $taskbarRadio.GetCurrentPattern($SEL)
    Assert-True ($taskbarSel.Current.IsSelected) 'Taskbar radio is initially selected (matches settings.json)'

    # 5. Verify version label.
    $versionLabel = $window.FindFirst($TS::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($AEP, 'Version RC3')))
    Assert-True ($null -ne $versionLabel) 'Version label shows RC3'

    # 6. Click OK with no changes -> taskbar mode dismisses by minimizing (window still exists).
    $ok = Find-Descendant $window $CT::Button 'OK'
    Assert-True ($null -ne $ok) 'OK button present'
    $ok.GetCurrentPattern($INV).Invoke()
    Start-Sleep -Milliseconds 600
    $winPattern = $window.GetCurrentPattern($WIN)
    Assert-True ($winPattern.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Minimized) 'OK in taskbar mode minimizes the window'

    # 7. Restore for next test.
    $winPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
    Start-Sleep -Milliseconds 400

    # 8. Switch to System tray + click OK once -> window should hide (no longer findable from root).
    $traySel = $trayRadio.GetCurrentPattern($SEL)
    $traySel.Select()
    Start-Sleep -Milliseconds 200
    $ok.GetCurrentPattern($INV).Invoke()
    Start-Sleep -Milliseconds 800

    $stillThere = Wait-Window 'Maximize All Windows' 1500
    Assert-True ($null -eq $stillThere) 'OK after selecting System tray hides the window in a single click'

    # 9. Process should still be running (tray mode keeps it alive).
    $alive = -not $proc.HasExited
    Assert-True $alive 'Process still running in tray mode after window hidden'
}
finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($script:failures.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED:" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
