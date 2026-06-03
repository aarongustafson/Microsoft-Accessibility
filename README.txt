# Maximize-All-Windows

Maximize-All-Windows is a small Windows utility that automatically maximizes newly opened top-level app windows.

It runs quietly in the background (no console window).

By default it runs in the **taskbar** with a settings window. You can switch to **system tray** mode from the settings dialog if you prefer.

Tray icon assets are in `Assets\tray-icon.ico` and `Assets\tray-icon.png`.

## How it works

- The app installs Windows event hooks and listens for new top-level windows.
- When a qualifying window appears it is sent a maximize request.
- If you manually **restore** a window (un-maximize it), the app remembers that and will not auto-maximize that window again for the rest of the session.
- Tooltips, menus, popups, owned dialogs, tool windows, and small transient surfaces are ignored.
- Microsoft Teams "caption" windows (live/closed captions) are explicitly excluded so they are not maximized over the meeting window.

## The settings window

The settings window is the primary UI. It is **resizable and maximizable** and opens **maximized** by default. It contains:

- **Start with Windows** — toggles a `HKCU` Run registration so the app launches at sign-in.
- **Show in** — a radio group with two choices:
  - **System tray** — the app lives in the notification area; closing the settings window hides it.
  - **Taskbar** *(default)* — the settings window is the app's persistent surface; minimize to send it to the taskbar, close (X) to quit.
- **OK** — applies any changes and dismisses the settings window (hide in tray mode, minimize in taskbar mode).
- **Cancel** — discards changes and dismisses the window.
- **Exit App** — quits the application entirely.
- **Version** label in the bottom-left corner shows the current build (for example `Version RC2 0.54`).

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

### RC2 0.54

- Settings window is now **resizable and maximizable** and opens **maximized** by default. Restoring from a minimized state returns to the previous Maximized/Normal state instead of forcing Normal.
- **User-restore is sticky for any window**: if you restore a window manually — regardless of whether the app or you maximized it — the app will not re-maximize it again for the rest of the session.
- Confirmed Microsoft Teams "caption" windows are excluded from auto-maximize.

### RC2 0.53

- Fixed Taskbar radio button focus rectangle being clipped at the bottom of the `Show in` group box.

### RC2 0.52

- Fixed a bug where clicking **OK** in taskbar mode required two clicks to dismiss the window.
- Fixed the `Show in` group box caption not rendering (caused by `AutoSize=true` collapsing the group).

### RC2 0.51

- Mode-aware dismiss: **OK** / **Cancel** now hide the window in system-tray mode and minimize it in taskbar mode (so a taskbar entry remains).
- Closing the settings window in taskbar mode exits the app (it is the only window); in tray mode it hides.

### RC2 0.50

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
