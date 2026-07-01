# Maximize-All-Windows

Maximize-All-Windows is a small Windows utility that automatically maximizes newly opened top-level app windows.

By default it runs in the **taskbar** with a settings window. You can switch to **system tray** mode from the settings dialog if you prefer.

## Download

Download the latest self-contained Windows x64 build (no .NET install required):

  https://github.com/microsoft/Microsoft-Accessibility/releases/latest/download/MaximizeAllWindows.exe

Or browse Maximize-All-Windows releases:

  https://github.com/microsoft/Microsoft-Accessibility/releases?q=maximize-all-windows-v&expanded=true

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
- **Version** label in the bottom-left corner shows the current release (for example `Version 1.0`). The detailed build number is recorded in the executable's file properties.

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

## Release notes

### 1.0

This is the **1.0** general release. The user-visible version label reads `1.0`; detailed build metadata (`1.0.0.0`) is recorded in the executable's file properties (right-click the EXE → **Properties** → **Details**).

Features:

- **Automatic window maximizing.** Newly opened top-level application windows are maximized automatically. Tooltips, menus, popups, owned dialogs, tool windows, and small transient surfaces are ignored.
- **Sticky manual restore.** If you restore a window manually, the app remembers and will not re-maximize that window again for the rest of the session.
- **Teams captions excluded.** Microsoft Teams "caption" windows (live/closed captions) — including popped-out captions hosted by WebView2 — are explicitly excluded so they are not maximized over the meeting window.
- **Respects elevated apps.** Windows belonging to apps running as administrator are left alone (by design, due to Windows UIPI).
- **Taskbar or system tray.** Runs from the taskbar by default with a settings window, or in the notification area if you prefer. The settings window is resizable, maximizable, and opens maximized.
- **Dark mode support.** The app detects the Windows app theme and applies matching light/dark palettes throughout the settings window, including the title bar (via DWM) and the tray context menu, updating live when you switch Windows between light and dark.
- **Windows 11-style settings layout.** A two-pane sidebar with **Settings** and **About** pages, a hero illustration, and accessible keyboard navigation with proper `AccessibleName` values for screen readers.
- **Install and uninstall.** Per-user install registers the app in **Add/Remove Programs**; `--install` performs a clean replace while preserving user settings.
- **Reliability.** Tray icon promotion and re-registration after Explorer restarts, single-instance detection, first-run **Start with Windows** prompt, and startup diagnostics at `%LocalAppData%\MaximizeAllWindows\startup.log`.

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
