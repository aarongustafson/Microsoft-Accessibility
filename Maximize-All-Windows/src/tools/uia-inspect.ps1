# Inspects the UI Automation tree of the running MaximizeAllWindows window and
# reports what a screen reader (Narrator) would announce for each focusable
# control. Used to verify accessibility fixes without manual Narrator testing.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$proc = Get-Process -Name MaximizeAllWindows -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Error "MaximizeAllWindows is not running."; exit 1 }

# Find the main settings window by name.
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Maximize All Windows")
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) {
    # Fall back: match by process id.
    $pidCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
    $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $pidCond)
}
if (-not $win) { Write-Error "Settings window not found in UIA tree."; exit 1 }

Write-Host "=== UIA tree (Name | ControlType) ===" -ForegroundColor Cyan

$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
function Show($el, $depth) {
    if (-not $el) { return }
    $name = $el.Current.Name
    $ct = $el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
    $indent = '  ' * $depth
    Write-Host ("{0}{1,-14} {2}" -f $indent, $ct, $name)
    $child = $walker.GetFirstChild($el)
    while ($child) {
        Show $child ($depth + 1)
        $child = $walker.GetNextSibling($child)
    }
}
Show $win 0

Write-Host "`n=== Button announcements (what Narrator reads on focus) ===" -ForegroundColor Cyan
$btnCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
$buttons = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
foreach ($b in $buttons) {
    $name = $b.Current.Name
    # LabeledBy relationship (a non-empty value here is what bleeds extra text in).
    $labeledBy = $null
    try {
        $lb = $b.GetCurrentPropertyValue(
            [System.Windows.Automation.AutomationElement]::LabeledByProperty)
        if ($lb -is [System.Windows.Automation.AutomationElement]) { $labeledBy = $lb.Current.Name }
    } catch {}
    Write-Host ("Button: '{0}'   LabeledBy: '{1}'" -f $name, $labeledBy)
}
