# Maximize-All-Windows

Maximize-All-Windows is a small Windows utility that automatically maximizes newly opened top-level app windows.

It runs quietly in the background (no console window).

By default, it starts with a normal control window in the taskbar so you can confirm the app is running.
You can enable tray-only behavior from settings.

Tray icon assets are in `Assets\\tray-icon.ico` and `Assets\\tray-icon.png`.

After launch, use the taskbar control window for settings.

- The app runs in the background and maximizes new windows automatically.
- In the control window, you can configure:
	- `Start with Windows` (adds/removes startup registration)
	- `Force tray icon visible` (enabled by default)
	- `Run in system tray` (optional, off by default)
	- `Set Recovery Hotkey...` (default: `Alt+Shift+F12`)

When tray mode is enabled, you can right-click the tray icon and choose `Exit` to stop it.

On first run, the app prompts once to ask whether `Start with Windows` should be enabled.

## Release Candidate 2 (RC2) bug fixes

RC2 includes these fixes and reliability improvements:

- Fixed New Outlook link right-click context menu not opening.
	- Added stricter filtering so popup/owned/transient menu surfaces are ignored by maximize logic.
- Improved tray icon reliability on startup.
	- Added longer tray icon re-registration attempts.
	- Added Explorer taskbar restart detection (`TaskbarCreated`) to re-register the icon after shell restarts.
- Added first-run prompts:
	- One-time prompt for `Start with Windows`.
	- One-time tray visibility help prompt that can open Taskbar settings.
- Added startup diagnostics log for troubleshooting at:
	- `%LocalAppData%\\MaximizeAllWindows\\startup.log`
- Added single-instance detection:
	- Launching the EXE while already running shows an "already running" dialog.
- Added install/uninstall flow:
	- `Install for current user` copies the app to `%LocalAppData%\\Programs\\MaximizeAllWindows`
	- Registers an uninstall entry in **Add/Remove Programs**
	- `Uninstall` removes startup registration, uninstall entry, and app files

## Tray icon visibility (Windows setting)

If you enable tray mode and do not see the app icon in the notification area, Windows may be hiding it.

Enable it here:

1. Open **Settings** > **Personalization** > **Taskbar**.
2. Open **Other system tray icons** (or **Taskbar corner overflow** on some versions).
3. Turn on **MaximizeAllWindows** so its icon is always visible.

Without this setting, the app can still be running, but the icon may only appear in the hidden overflow menu.

## Troubleshooting

### App is running, but I do not see the tray icon

1. Click the notification area overflow arrow (`^`) and look for the icon there.
2. Enable the icon in Windows settings:
	- **Settings** > **Personalization** > **Taskbar** > **Other system tray icons**
	- Turn on **MaximizeAllWindows**
3. If needed, exit and restart the app.
4. Restart Windows Explorer from Task Manager; RC2 will try to re-register the icon automatically after Explorer restarts.

### I cannot open the tray icon context menu

1. Confirm the icon is visible in the system tray (not hidden).
2. Try right-clicking the icon once and waiting a moment.
3. If the menu still does not appear, restart the app from Task Manager or launch it again.

### File Explorer context menu does not open while app is running

This was a bug fixed in RC1 by filtering popup/menu windows from maximize handling. Use RC1 or newer.

### New Outlook link right-click context menu does not open

This was fixed in RC2 by excluding owned/popup/transient surfaces from maximize handling. Use RC2 or newer.

## Start with Windows

Use the tray icon menu and enable `Start with Windows`.

This writes the current EXE path to:

- `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MaximizeAllWindows`

So the app starts automatically on next sign-in.

## Install and Uninstall

The app supports a per-user install so it can appear in **Add/Remove Programs**.

1. Launch the app and use tray menu: `Install for current user`.
2. Installed location:
	- `%LocalAppData%\\Programs\\MaximizeAllWindows`
3. Uninstall options:
	- Use tray menu `Uninstall` (when running installed copy), or
	- Remove it from **Settings** > **Apps** > **Installed apps**.

Command line options:

- `MaximizeAllWindows.exe --install`
- `MaximizeAllWindows.exe --uninstall`

## Recovery Hotkey

Default recovery hotkey is `Alt+Shift+F12`.

Use tray menu `Set Recovery Hotkey...` to set your own combination.

When pressed, the hotkey forces tray icon re-registration.

## Force tray icon visible

`Force tray icon visible` is enabled by default.

When enabled, the app briefly re-registers its tray icon during startup to reduce cases where Explorer does not immediately show the icon. If you prefer Windows' normal tray behavior, disable this option from the tray menu.
