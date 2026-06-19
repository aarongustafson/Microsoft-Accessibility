# Maximize-All-Windows

Maximize-All-Windows is a small Windows utility that automatically maximizes newly opened top-level app windows.

By default it runs in the **taskbar** with a settings window. You can switch to **system tray** mode from the settings dialog if you prefer.

## Download

Download the latest self-contained Windows x64 build (no .NET install required):

  https://github.com/microsoft/Microsoft-Accessibility/releases/latest/download/MaximizeAllWindows.exe

Or browse all releases:

  https://github.com/microsoft/Microsoft-Accessibility/releases/latest

After downloading, right-click the file > Properties > check Unblock > OK (only
needed for files downloaded from the internet), then run it. See "Install and
uninstall" below for putting it in Add/Remove Programs.

## How it works

- The app installs Windows event hooks and listens for new top-level windows.
- When a qualifying window appears it is sent a maximize request.
- If you manually **restore** a window (un-maximize it), the app remembers that and will not auto-maximize that window again for the rest of the session.
- Tooltips, menus, popups, owned dialogs, tool windows, and small transient surfaces are ignored.
- Microsoft Teams "caption" windows (live/closed captions) are explicitly excluded so they are not maximized over the meeting window.
- Windows belonging to apps running **as administrator** (elevated) are not auto-maximized. The app runs as the normal user, and Windows User Interface Privilege Isolation (UIPI) prevents a non-elevated app from controlling elevated windows. This is by design.

## The settings window

The settings window is the primary UI. It is **resizable and maximizable** and opens **maximized** by default. It contains:

- **Start with Windows** — toggles a `HKCU` Run registration so the app launches at sign-in.
- **Show in** — a radio group with two choices:
  - **System tray** — the app lives in the notification area; closing the settings window hides it.
  - **Taskbar** *(default)* — the settings window is the app's persistent surface; minimize to send it to the taskbar, close (X) to quit.
- **OK** — applies any changes and dismisses the settings window (hide in tray mode, minimize in taskbar mode).
- **Cancel** — discards changes and dismisses the window.
- **Exit App** — quits the application entirely.
- **Version** label in the bottom-left corner shows the current release (for example `Version RC3`). The detailed build number is recorded in the executable's file properties.

In **system tray** mode you can also right-click the tray icon for:

- `Open` — re-show the settings window.
- `Start with Windows` — same toggle as in the settings window.
- `Exit` — quit the app.

On first run the app prompts once to ask whether `Start with Windows` should be enabled.

## Tray icon visibility (Windows setting)

If you enable tray mode and do not see the app icon in the notification area, Windows may be hiding it.

Enable it here:

1. Open **Settings** > **Personalization** > **Taskbar**.
2. Open **Other system tray icons** (or **Taskbar corner overflow** on some versions).
3. Turn on **MaximizeAllWindows** so its icon is always visible.

The app also attempts to promote its own tray icon to "always visible" via
`HKCU\Control Panel\NotifyIconSettings\<id>\IsPromoted = 1` on startup and after Explorer restarts.

## Install and uninstall

The app supports a per-user install so it can appear in **Add/Remove Programs**.

- Installed location: `%LocalAppData%\Programs\MaximizeAllWindows`
- ARP entry: `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\MaximizeAllWindows`
- Settings: `%LocalAppData%\MaximizeAllWindows\settings.json`
- Startup log: `%LocalAppData%\MaximizeAllWindows\startup.log`

`--install` performs a clean install: if an install already exists, its contents are removed first and then replaced with the current build's files. User settings are preserved across upgrades.

To install:

1. Run `MaximizeAllWindows.exe --install` (shows a confirmation dialog), or
2. Run `MaximizeAllWindows.exe --install-silent` for an unattended install.

To uninstall:

- Run `MaximizeAllWindows.exe --uninstall`, or
- Run `MaximizeAllWindows.exe --uninstall-silent`, or
- Remove it from **Settings** > **Apps** > **Installed apps**.

Command line options:

- `MaximizeAllWindows.exe --install`
- `MaximizeAllWindows.exe --install-silent`
- `MaximizeAllWindows.exe --uninstall`
- `MaximizeAllWindows.exe --uninstall-silent`

## Start with Windows

Toggle **Start with Windows** in the settings window or the tray menu. This writes the current EXE path to:

- `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MaximizeAllWindows`

so the app starts automatically on next sign-in. If the registered path no longer matches the current EXE (for example after a re-install to a new location), the app repairs it on next launch.

## Sharing this build with other users

This build is **not yet code-signed**, so Windows SmartScreen and Edge/Outlook attachment filters will warn the recipient. To run it on a fresh machine:

1. Save `MaximizeAllWindows.exe` to a folder (e.g. `Downloads`).
2. **Right-click** the file → **Properties** → check **Unblock** → **OK**. (This is only needed for files downloaded from the internet.)
3. Double-click `MaximizeAllWindows.exe`. If SmartScreen shows *"Windows protected your PC"*, click **More info** → **Run anyway**.
4. The app opens its settings window. Use the **Install** option (or run `MaximizeAllWindows.exe --install-silent` from a terminal) to put it under `%LocalAppData%\Programs\MaximizeAllWindows` and register it in **Add/Remove Programs**.
5. (Optional) Enable **Start with Windows** so it launches at sign-in.

A signed pipeline build is planned for general distribution.

## Release notes

### RC3

This is the **RC3** release. The user-visible version label reads `RC3`; detailed build metadata (`2.0.2.1`, RC3 build 1) is recorded in the executable's file properties (right-click the EXE → **Properties** → **Details**).

Highlights since RC2:

- **Dark mode support.** The app now detects the Windows app theme and applies matching light/dark palettes throughout the settings window, including the title bar (via DWM) and the tray context menu. The theme updates live when you switch Windows between light and dark.
- **New two-pane settings layout.** The settings window uses a Windows 11-style sidebar with **Settings** and **About** pages. The selected sidebar item is drawn with a rounded accent highlight.
- **Hero illustration.** The settings window's right column now shows a hero illustration that reinforces the "maximize" concept.
- **Improved keyboard navigation and accessibility.** Sidebar selection follows the Windows 11 accessible pattern, the **System tray** / **Taskbar** radios are grouped so Up/Down arrows cycle only between them, and controls expose proper `AccessibleName` values (e.g. "System tray, 1 of 2") for screen readers.

---

### RC2

This is the consolidated **RC2** release. The user-visible version label has been simplified to just `RC2`; detailed build metadata is recorded in the executable's file properties (right-click the EXE → **Properties** → **Details**).

Highlights since RC1:

- **Teams Live Captions are no longer auto-maximized.** Popped-out Live Captions in new Teams are hosted by `msedgewebview2.exe` and appear with an empty title under class `TeamsWebView`. The filter now recognizes the WebView2 host process, title patterns (`captions`, `subtitles`, `transcript`), the `TeamsWebView` class with an empty title at show-time, and additional class-name fallbacks. The main meeting window is unaffected.
- **Restored windows stay restored.** If you restore a window manually, the app remembers and will not re-maximize that window again for the rest of the session — regardless of whether you or the app originally maximized it.
- **Better filtering of transient surfaces.** Tooltips, popups, owned dialogs, tool windows, and small flyouts are excluded, so things like the **New Outlook** right-click context menu open correctly.
- **Settings window is resizable and maximizable** and opens **maximized** by default. Minimize/restore preserves the previous Maximized/Normal state.
- **Clean install behavior.** `--install` performs a true replace: the existing install directory is removed before the new files are copied. User settings are preserved across upgrades.
- **Diagnostics.** Auto-maximize actions log the target process name, window class, and title to `%LocalAppData%\MaximizeAllWindows\startup.log` to make unexpected behavior easier to diagnose.
- **Tray icon promotion.** On startup (and after Explorer restarts) the app attempts to set its tray icon to "always visible" via `HKCU\Control Panel\NotifyIconSettings\<id>\IsPromoted = 1`.

---

### Historical pre-RC2 build notes

The following entries cover the iterative builds (`RC2 0.50` … `RC2 0.56`) that led to this release. They are kept for reference only — all changes are rolled up under **RC2** above.

#### RC2 0.56

- Fixed: popped-out **Live Captions** in new Teams were still getting auto-maximized. The caption window uses class `TeamsWebView` (same as the main meeting window) but appears with an **empty title** when first shown, so neither the title-based nor the class-based filter caught it. The check now treats any `TeamsWebView` window with an empty title at show-time as an auxiliary Teams surface and skips it. The main meeting window is unaffected because it always has a title (`Microsoft Teams` or the meeting name) set by the time it appears.

#### RC2 0.55

- Improved Microsoft Teams **Live Captions** suppression: popped-out caption windows in **new Teams** are hosted by `msedgewebview2.exe` (not `ms-teams.exe`), so the previous filter let them through and they got auto-maximized. The check now recognizes the WebView2 host process, additional title patterns (`captions`, `subtitles`, `transcript`), and class-name fallbacks for the case where the title is not set yet when the window first appears.
- Auto-maximize actions now log the target process name, window class, and title to `%LocalAppData%\MaximizeAllWindows\startup.log` to make it easier to diagnose unexpected maximize behavior.

#### RC2 0.54

- Settings window is now **resizable and maximizable** and opens **maximized** by default. Restoring from a minimized state returns to the previous Maximized/Normal state instead of forcing Normal.
- **User-restore is sticky for any window**: if you restore a window manually — regardless of whether the app or you maximized it — the app will not re-maximize it again for the rest of the session.
- Confirmed Microsoft Teams "caption" windows are excluded from auto-maximize.

#### RC2 0.53

- Fixed Taskbar radio button focus rectangle being clipped at the bottom of the `Show in` group box.

#### RC2 0.52

- Fixed a bug where clicking **OK** in taskbar mode required two clicks to dismiss the window.
- Fixed the `Show in` group box caption not rendering (caused by `AutoSize=true` collapsing the group).

#### RC2 0.51

- Mode-aware dismiss: **OK** / **Cancel** now hide the window in system-tray mode and minimize it in taskbar mode (so a taskbar entry remains).
- Closing the settings window in taskbar mode exits the app (it is the only window); in tray mode it hides.

#### RC2 0.50

- Renamed `Run in` group to **Show in**.
- Replaced the **Run in system tray** checkbox with the **System tray** / **Taskbar** radio group.
- Added **OK**, **Cancel**, and **Exit App** buttons.
- Added a **Version** label in the corner of the settings window.
- Fixed slow startup in tray mode (no longer forces settings-window handle creation on the critical path).
- Fixed taskbar mode "OK closes but nothing in taskbar" by not hiding the only window in taskbar mode.

### RC2 (initial)

- New Outlook link right-click context menu no longer fails to open (popup/owned/transient surfaces are excluded from maximize handling).
- Improved tray icon reliability: longer re-registration attempts, plus Explorer `TaskbarCreated` watcher that re-registers the icon after shell restarts.
- First-run prompt for **Start with Windows**.
- Startup diagnostics log at `%LocalAppData%\MaximizeAllWindows\startup.log`.
- Single-instance detection: launching the EXE while it is already running shows an "already running" dialog.
- Install/uninstall flow with **Add/Remove Programs** entry.

### RC1

- File Explorer context menu no longer fails to open while app is running (popup/menu windows are filtered from maximize handling).

## Troubleshooting

### App is running, but I do not see the tray icon

1. Click the notification area overflow arrow (`^`) and look for the icon there.
2. Enable the icon in Windows settings:
	- **Settings** > **Personalization** > **Taskbar** > **Other system tray icons**
	- Turn on **MaximizeAllWindows**
3. If needed, exit and restart the app.
4. Restart Windows Explorer from Task Manager; the app will try to re-register the icon automatically after Explorer restarts.

### I cannot open the tray icon context menu

1. Confirm the icon is visible in the system tray (not hidden).
2. Try right-clicking the icon once and waiting a moment.
3. If the menu still does not appear, restart the app from Task Manager or launch it again.

### A window keeps getting maximized when I don't want it to

Restore the window once (click the **Restore** button in the title bar, or drag it off the maximize state). The app will remember that for the rest of the session and leave it alone.

### File Explorer context menu does not open while app is running

Fixed in RC1.

### New Outlook link right-click context menu does not open

Fixed in RC2.
