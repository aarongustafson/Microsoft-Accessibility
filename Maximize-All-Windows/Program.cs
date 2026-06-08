using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Threading;
using Microsoft.Win32;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;

internal static class AppInfo
{
    // User-facing label. Includes a build counter so test builds can be told apart in the Settings window.
    // Keep the build number aligned with FileVersion in the .csproj.
    public const string DisplayVersion = "RC2 build 59 (dark-tray-menu)";
}

internal static class Program
{
    private static readonly Mutex SingleInstanceMutex = new(initiallyOwned: false, name: "Local\\MaximizeAllWindows.SingleInstance");

    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        if (TryHandleCommandLine(args))
        {
            return;
        }

        var hasMutex = false;
        try
        {
            hasMutex = SingleInstanceMutex.WaitOne(0, false);
            if (!hasMutex)
            {
                MessageBox.Show(
                    "Maximize All Windows is already running.",
                    "Maximize All Windows",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                AppLog.Write("Another instance is already running. Exiting duplicate instance.");
                return;
            }

            AppLog.Write("Process starting.");
            AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
            {
                AppLog.Write($"Unhandled AppDomain exception: {eventArgs.ExceptionObject}");
            };
            Application.ThreadException += (_, eventArgs) =>
            {
                AppLog.Write($"Unhandled UI thread exception: {eventArgs.Exception}");
            };

            AppLog.Write("Application configuration initialized.");
            Application.Run(new MaximizeApplicationContext());
            AppLog.Write("Application message loop exited.");
        }
        catch (Exception ex)
        {
            AppLog.Write($"Fatal startup exception: {ex}");
            throw;
        }
        finally
        {
            if (hasMutex)
            {
                SingleInstanceMutex.ReleaseMutex();
            }
        }
    }

    private static bool TryHandleCommandLine(string[] args)
    {
        if (args.Length == 0)
        {
            return false;
        }

        if (args.Length == 1 && string.Equals(args[0], "--install", StringComparison.OrdinalIgnoreCase))
        {
            var ok = InstallManager.TryInstall(out var message);
            MessageBox.Show(
                message,
                "Maximize All Windows",
                MessageBoxButtons.OK,
                ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            return true;
        }

        if (args.Length == 1 && string.Equals(args[0], "--install-silent", StringComparison.OrdinalIgnoreCase))
        {
            var ok = InstallManager.TryInstall(out var message);
            AppLog.Write($"Silent install result: ok={ok}. {message}");
            Environment.ExitCode = ok ? 0 : 1;
            return true;
        }

        if (args.Length == 1 && string.Equals(args[0], "--uninstall", StringComparison.OrdinalIgnoreCase))
        {
            var ok = InstallManager.TryUninstall(out var message);
            MessageBox.Show(
                message,
                "Maximize All Windows",
                MessageBoxButtons.OK,
                ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            return true;
        }

        if (args.Length == 1 && string.Equals(args[0], "--uninstall-silent", StringComparison.OrdinalIgnoreCase))
        {
            var ok = InstallManager.TryUninstall(out var message);
            AppLog.Write($"Silent uninstall result: ok={ok}. {message}");
            Environment.ExitCode = ok ? 0 : 1;
            return true;
        }

        return false;
    }
}

internal sealed class MaximizeApplicationContext : ApplicationContext
{
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint EVENT_OBJECT_SHOW = 0x8002;

    private const int OBJID_WINDOW = 0;
    private const int CHILDID_SELF = 0;

    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    private const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

    private const int SW_MAXIMIZE = 3;
    private const int SW_RESTORE = 9;
    private const int GWL_STYLE = -16;
    private const int GWL_EXSTYLE = -20;
    private const int CLASS_NAME_BUFFER = 256;

    private const long WS_CHILD = 0x40000000L;
    private const long WS_POPUP = unchecked((long)0x80000000L);
    private const long WS_CAPTION = 0x00C00000L;
    private const long WS_THICKFRAME = 0x00040000L;
    private const long WS_MAXIMIZEBOX = 0x00010000L;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;

    private const uint GA_ROOT = 2;
    private const uint GW_OWNER = 4;
    private const uint DWMWA_CLOAKED = 14;

    private readonly ConcurrentDictionary<nint, long> _recentWindows = new();
    private readonly ConcurrentDictionary<nint, byte> _userRestoredWindows = new();
    private readonly ConcurrentDictionary<nint, byte> _autoMaximizedWindows = new();
    private readonly ConcurrentDictionary<nint, bool> _lastZoomState = new();
    private readonly NotifyIcon _trayIcon;
    private readonly Icon? _customIcon;
    private readonly AppSettings _settings;
    private readonly TaskbarCreatedWatcher _taskbarWatcher;
    private readonly Form _controlWindow;
    private readonly System.Windows.Forms.Timer _trayPromoteTimer;
    private readonly ContextMenuStrip _trayMenu;
    private readonly UserPreferenceChangedEventHandler _trayThemeHandler;

    private bool _isExiting;

    private WinEventDelegate? _callback;
    private nint _showHook;
    private nint _foregroundHook;

    public MaximizeApplicationContext()
    {
        AppLog.Write("Creating application context.");
        _settings = SettingsService.Load();
        var startupEnabled = _settings.StartWithWindows || StartupRegistration.IsEnabled();
        var isCurrentExecutableRegistered = StartupRegistration.IsCurrentExecutableRegistered();
        if (startupEnabled && !isCurrentExecutableRegistered)
        {
            if (StartupRegistration.TrySetEnabled(true, out var startupRepairError))
            {
                AppLog.Write("Startup registration path repaired to current executable.");
                isCurrentExecutableRegistered = true;
            }
            else
            {
                AppLog.Write($"Failed to repair startup registration path: {startupRepairError}");
            }
        }

        _settings.StartWithWindows = isCurrentExecutableRegistered;
        SettingsService.Save(_settings);
        AppLog.Write($"Settings loaded. StartWithWindows={_settings.StartWithWindows}, FirstRunCompleted={_settings.HasCompletedFirstRunPrompt}");

        _customIcon = LoadTrayIcon();

        _trayMenu = new ContextMenuStrip();
        var menu = _trayMenu;

        var suppressStartWithWindowsChanged = false;
        var startWithWindowsItem = new ToolStripMenuItem("Start with Windows")
        {
            CheckOnClick = true,
            Checked = _settings.StartWithWindows
        };
        startWithWindowsItem.CheckedChanged += (_, _) =>
        {
            if (suppressStartWithWindowsChanged)
            {
                return;
            }

            if (StartupRegistration.TrySetEnabled(startWithWindowsItem.Checked, out var startupError))
            {
                _settings.StartWithWindows = startWithWindowsItem.Checked;
                SettingsService.Save(_settings);
                return;
            }

            suppressStartWithWindowsChanged = true;
            startWithWindowsItem.Checked = _settings.StartWithWindows;
            suppressStartWithWindowsChanged = false;
            MessageBox.Show(
                $"Could not update startup setting. {startupError}",
                "Maximize All Windows",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        };

        _controlWindow = CreateControlWindow(startWithWindowsItem);

        menu.Items.Add("Open", null, (_, _) => ShowControlWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(startWithWindowsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => ExitThread());

        // Theme the tray context menu to match the system theme, and refresh it
        // every time the menu opens (cheap, and handles edge cases like the user
        // changing themes while the menu has never been shown).
        ThemeHelper.ApplyToContextMenuStrip(menu, ThemeHelper.GetPalette(ThemeHelper.IsSystemInDarkMode()));
        menu.Opening += (_, _) =>
            ThemeHelper.ApplyToContextMenuStrip(menu, ThemeHelper.GetPalette(ThemeHelper.IsSystemInDarkMode()));

        _trayThemeHandler = (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General || e.Category == UserPreferenceCategory.VisualStyle)
            {
                ThemeHelper.ApplyToContextMenuStrip(menu, ThemeHelper.GetPalette(ThemeHelper.IsSystemInDarkMode()));
            }
        };
        SystemEvents.UserPreferenceChanged += _trayThemeHandler;

        _taskbarWatcher = new TaskbarCreatedWatcher(() =>
        {
            AppLog.Write("TaskbarCreated detected; re-registering tray icon.");
            if (_settings.RunInSystemTray)
            {
                ReshowTrayIcon();
                SchedulePromoteAndVerify(delayMs: 250, reason: "taskbar restart");
            }
        });

        _trayIcon = new NotifyIcon
        {
            Icon = _customIcon ?? SystemIcons.Application,
            Text = "Maximize All Windows",
            Visible = false,
            ContextMenuStrip = menu
        };
        _trayIcon.DoubleClick += (_, _) => ShowControlWindow();
        AppLog.Write("Tray icon created.");

        _trayPromoteTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _trayPromoteTimer.Tick += (_, _) =>
        {
            _trayPromoteTimer.Stop();
            PromoteAndVerify(reason: _pendingPromoteReason);
            _pendingPromoteReason = string.Empty;
        };

        HandleFirstRunPrompt(startWithWindowsItem);

        if (_settings.RunInSystemTray)
        {
            // Fast path: don't touch _controlWindow (avoids handle creation cost).
            EnsureTrayIconVisible();
            SchedulePromoteAndVerify(delayMs: 50, reason: "startup");
        }
        else
        {
            ShowControlWindow();
        }

        _callback = OnWindowEvent;

        _showHook = SetWinEventHook(
            EVENT_OBJECT_SHOW,
            EVENT_OBJECT_SHOW,
            nint.Zero,
            _callback,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);

        _foregroundHook = SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND,
            EVENT_SYSTEM_FOREGROUND,
            nint.Zero,
            _callback,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);

        if (_showHook == nint.Zero || _foregroundHook == nint.Zero)
        {
            AppLog.Write($"Failed to install hooks. showHook={_showHook}, foregroundHook={_foregroundHook}");
            MessageBox.Show(
                "Failed to install one or more window event hooks.",
                "Maximize All Windows",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            ExitThread();
            return;
        }

        AppLog.Write("Window event hooks installed successfully.");
    }

    protected override void ExitThreadCore()
    {
        AppLog.Write("ExitThreadCore called. Cleaning up resources.");
        _isExiting = true;

        if (_showHook != nint.Zero)
        {
            UnhookWinEvent(_showHook);
            _showHook = nint.Zero;
        }

        if (_foregroundHook != nint.Zero)
        {
            UnhookWinEvent(_foregroundHook);
            _foregroundHook = nint.Zero;
        }

        _taskbarWatcher.Dispose();
        _trayPromoteTimer.Stop();
        _trayPromoteTimer.Dispose();

        SystemEvents.UserPreferenceChanged -= _trayThemeHandler;

        if (!_controlWindow.IsDisposed)
        {
            _controlWindow.Close();
            _controlWindow.Dispose();
        }

        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        _trayMenu.Dispose();
        _customIcon?.Dispose();
        _callback = null;

        base.ExitThreadCore();
        AppLog.Write("ExitThreadCore complete.");
    }

    private void OnWindowEvent(
        nint hWinEventHook,
        uint eventType,
        nint hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        if (hwnd == nint.Zero || idObject != OBJID_WINDOW || idChild != CHILDID_SELF)
        {
            return;
        }

        if (GetAncestor(hwnd, GA_ROOT) != hwnd)
        {
            return;
        }

        if (!IsWindowVisible(hwnd) || IsIconic(hwnd))
        {
            return;
        }

        var isZoomed = IsZoomed(hwnd);
        TrackWindowZoomState(hwnd, isZoomed);
        if (isZoomed)
        {
            return;
        }

        if (_userRestoredWindows.ContainsKey(hwnd))
        {
            return;
        }

        if (IsCloaked(hwnd))
        {
            return;
        }

        if (IsTeamsCaptionWindow(hwnd))
        {
            return;
        }

        var style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
        var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();

        if ((style & WS_CHILD) != 0 || (exStyle & WS_EX_TOOLWINDOW) != 0)
        {
            return;
        }

        // Skip owned/popup utility surfaces (menus, flyouts, in-app context popups).
        if (GetWindow(hwnd, GW_OWNER) != nint.Zero || ((style & WS_POPUP) != 0 && (style & WS_CAPTION) == 0))
        {
            return;
        }

        if (IsLikelyTransientSurface(hwnd))
        {
            return;
        }

        // Ignore popup/menu surfaces and windows that cannot be meaningfully maximized.
        if (IsPopupMenuWindow(hwnd) || (style & WS_THICKFRAME) == 0 || (style & WS_MAXIMIZEBOX) == 0)
        {
            return;
        }

        var now = Environment.TickCount64;
        var last = _recentWindows.GetOrAdd(hwnd, 0);
        if (now - last < 600)
        {
            return;
        }

        _recentWindows[hwnd] = now;
        _autoMaximizedWindows[hwnd] = 0;

        // Diagnostic: capture identity for any window we auto-maximize so suppressions
        // (Teams captions etc.) can be debugged from startup.log if they slip through.
        if (TryGetProcessName(hwnd, out var amProcess))
        {
            var amTitle = GetWindowTitle(hwnd);
            var amClass = GetClassNameSafe(hwnd);
            AppLog.Write($"Auto-maximize: hwnd=0x{hwnd:X} process='{amProcess}' class='{amClass}' title='{amTitle}'");
        }

        ShowWindowAsync(hwnd, SW_MAXIMIZE);
    }

    private void TrackWindowZoomState(nint hwnd, bool isZoomed)
    {
        // Any maximized -> restored transition is treated as a user-initiated restore.
        // Once a user restores a window we leave it alone for the rest of the session.
        if (_lastZoomState.TryGetValue(hwnd, out var previousZoomed)
            && previousZoomed
            && !isZoomed)
        {
            _userRestoredWindows[hwnd] = 0;
            AppLog.Write($"Window restore detected; suppressing future auto-maximize for hwnd {hwnd}.");
        }

        _lastZoomState[hwnd] = isZoomed;
    }

    private static bool IsTeamsCaptionWindow(nint hwnd)
    {
        if (!TryGetProcessName(hwnd, out var processName))
        {
            return false;
        }

        // New Teams hosts many popped-out windows (including Live Captions) in
        // msedgewebview2.exe rather than ms-teams.exe, so accept either host.
        var isTeamsHost =
            processName.Equals("ms-teams", StringComparison.OrdinalIgnoreCase)
            || processName.Equals("teams", StringComparison.OrdinalIgnoreCase)
            || processName.Equals("msedgewebview2", StringComparison.OrdinalIgnoreCase);

        if (!isTeamsHost)
        {
            return false;
        }

        var title = GetWindowTitle(hwnd);
        if (!string.IsNullOrWhiteSpace(title))
        {
            if (title.Contains("caption", StringComparison.OrdinalIgnoreCase)
                || title.Contains("subtitle", StringComparison.OrdinalIgnoreCase)
                || title.Contains("transcript", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        // When EVENT_OBJECT_SHOW fires the title may not be set yet, so also accept
        // a Teams-hosted window whose class name is a known caption surface.
        var className = GetClassNameSafe(hwnd);
        if (!string.IsNullOrEmpty(className)
            && className.Contains("caption", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // Popped-out Live Captions in new Teams use class 'TeamsWebView' with an
        // empty title when EVENT_OBJECT_SHOW fires. The main meeting window uses
        // the same class but always has a non-empty title ('Microsoft Teams' or
        // the meeting name) at SHOW time, so an empty title on a TeamsWebView is
        // a reliable signal of an auxiliary surface (captions/notes/popout). Skip
        // it now; the FOREGROUND hook will re-evaluate after the title is set.
        if (string.IsNullOrWhiteSpace(title)
            && string.Equals(className, "TeamsWebView", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return false;
    }

    private static string GetClassNameSafe(nint hwnd)
    {
        var buffer = new char[CLASS_NAME_BUFFER];
        var length = GetClassName(hwnd, buffer, buffer.Length);
        return length > 0 ? new string(buffer, 0, length) : string.Empty;
    }

    private static bool TryGetProcessName(nint hwnd, out string processName)
    {
        processName = string.Empty;
        GetWindowThreadProcessId(hwnd, out var processId);
        if (processId == 0)
        {
            return false;
        }

        try
        {
            using var process = Process.GetProcessById((int)processId);
            processName = process.ProcessName;
            return !string.IsNullOrWhiteSpace(processName);
        }
        catch
        {
            return false;
        }
    }

    private static string GetWindowTitle(nint hwnd)
    {
        var length = GetWindowTextLength(hwnd);
        if (length <= 0)
        {
            return string.Empty;
        }

        var buffer = new StringBuilder(length + 1);
        _ = GetWindowText(hwnd, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    private static bool IsCloaked(nint hwnd)
    {
        var result = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int));
        return result == 0 && cloaked != 0;
    }

    private static bool IsPopupMenuWindow(nint hwnd)
    {
        var className = GetClassNameSafe(hwnd);
        return string.Equals(className, "#32768", StringComparison.Ordinal);
    }

    private static bool IsLikelyTransientSurface(nint hwnd)
    {
        if (!GetWindowRect(hwnd, out var rect))
        {
            return false;
        }

        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;

        // Most context/flyout surfaces are small; avoid touching them.
        return width < 320 || height < 200;
    }

    private static Icon? LoadTrayIcon()
    {
        const string resourceName = "MaximizeAllWindows.Assets.tray-icon.ico";
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName);
        if (stream is null)
        {
            return null;
        }

        return new Icon(stream);
    }

    private string _pendingPromoteReason = string.Empty;

    private void EnsureTrayIconVisible()
    {
        if (_trayIcon.Visible)
        {
            return;
        }

        try
        {
            _trayIcon.Visible = true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"EnsureTrayIconVisible failed: {ex.Message}");
        }
    }

    private void ReshowTrayIcon()
    {
        try
        {
            _trayIcon.Visible = false;
            _trayIcon.Visible = true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"ReshowTrayIcon failed: {ex.Message}");
        }
    }

    private void SchedulePromoteAndVerify(int delayMs, string reason)
    {
        _pendingPromoteReason = reason;
        _trayPromoteTimer.Stop();
        _trayPromoteTimer.Interval = Math.Max(1, delayMs);
        _trayPromoteTimer.Start();
    }

    private void PromoteAndVerify(string reason)
    {
        var exePath = Application.ExecutablePath;
        var promoteResult = TrayIconPromoter.TryPromote(exePath);
        AppLog.Write($"Promote ({reason}): {promoteResult}");

        if (promoteResult == TrayIconPromoter.Result.Promoted)
        {
            ReshowTrayIcon();
        }

        QueueVisibilityCheck(reason, attemptsRemaining: 4, delayMs: 250);
    }

    private void QueueVisibilityCheck(string reason, int attemptsRemaining, int delayMs)
    {
        if (attemptsRemaining <= 0) return;

        var probe = new System.Windows.Forms.Timer { Interval = Math.Max(50, delayMs) };
        probe.Tick += (_, _) =>
        {
            probe.Stop();
            probe.Dispose();

            var (hwnd, uid) = TrayIconReflection.GetIdentity(_trayIcon);
            var visibility = TrayIconLocator.Query(hwnd, uid);
            AppLog.Write($"Visibility ({reason}) hwnd=0x{hwnd:X} uid={uid}: {visibility}");

            if (visibility == TrayIconLocator.Visibility.NotFound || visibility == TrayIconLocator.Visibility.Unknown)
            {
                QueueVisibilityCheck(reason, attemptsRemaining - 1, delayMs);
            }
        };
        probe.Start();
    }

    private Form CreateControlWindow(
        ToolStripMenuItem startWithWindowsItem)
    {
        var form = new Form
        {
            Text = "Maximize All Windows",
            Width = 820,
            Height = 540,
            MinimumSize = new Size(720, 480),
            MinimizeBox = true,
            MaximizeBox = true,
            StartPosition = FormStartPosition.CenterScreen,
            FormBorderStyle = FormBorderStyle.Sizable,
            WindowState = FormWindowState.Maximized,
            ShowIcon = true,
            ShowInTaskbar = true,
            Icon = _customIcon ?? SystemIcons.Application,
            BackColor = SystemColors.Window
        };

        // --- Settings page controls -------------------------------------------------
        var settingsTitle = new Label
        {
            AutoSize = true,
            Text = "Settings",
            Font = new Font(form.Font.FontFamily, form.Font.Size + 8f, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 4)
        };

        var settingsSubtitle = new Label
        {
            AutoSize = true,
            Text = "Configure how Maximize All Windows behaves.",
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 24)
        };

        var generalHeader = new Label
        {
            AutoSize = true,
            Text = "GENERAL",
            Font = new Font(form.Font, FontStyle.Bold),
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 8)
        };

        var startWithWindowsCheck = new CheckBox
        {
            AutoSize = true,
            Text = "Start with Windows",
            Checked = _settings.StartWithWindows,
            Margin = new Padding(0, 0, 0, 24)
        };

        var appearanceHeader = new Label
        {
            AutoSize = true,
            Text = "APPEARANCE",
            Font = new Font(form.Font, FontStyle.Bold),
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 8)
        };

        var showInLabel = new Label
        {
            AutoSize = true,
            Text = "Show in",
            Margin = new Padding(0, 0, 0, 6)
        };

        var trayRadio = new RadioButton
        {
            AutoSize = true,
            Text = "System tray",
            Checked = _settings.RunInSystemTray,
            Margin = new Padding(0, 0, 0, 4)
        };

        var taskbarRadio = new RadioButton
        {
            AutoSize = true,
            Text = "Taskbar",
            Checked = !_settings.RunInSystemTray,
            Margin = new Padding(0, 0, 0, 4)
        };

        var settingsPage = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            BackColor = SystemColors.Window,
            Padding = new Padding(32, 28, 32, 28)
        };
        settingsPage.Controls.Add(settingsTitle);
        settingsPage.Controls.Add(settingsSubtitle);
        settingsPage.Controls.Add(generalHeader);
        settingsPage.Controls.Add(startWithWindowsCheck);
        settingsPage.Controls.Add(appearanceHeader);
        settingsPage.Controls.Add(showInLabel);
        settingsPage.Controls.Add(trayRadio);
        settingsPage.Controls.Add(taskbarRadio);

        // --- About page controls ----------------------------------------------------
        var aboutTitle = new Label
        {
            AutoSize = true,
            Text = "About",
            Font = new Font(form.Font.FontFamily, form.Font.Size + 8f, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 4)
        };

        var aboutSubtitle = new Label
        {
            AutoSize = true,
            Text = "Maximize All Windows",
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 24)
        };

        var aboutVersionHeader = new Label
        {
            AutoSize = true,
            Text = "VERSION",
            Font = new Font(form.Font, FontStyle.Bold),
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 8)
        };

        var aboutVersionValue = new Label
        {
            AutoSize = true,
            Text = AppInfo.DisplayVersion,
            Margin = new Padding(0, 0, 0, 24)
        };

        var aboutDescriptionHeader = new Label
        {
            AutoSize = true,
            Text = "WHAT IT DOES",
            Font = new Font(form.Font, FontStyle.Bold),
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 8)
        };

        var aboutDescription = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(620, 0),
            Text = "Automatically maximizes new windows as they open, so every app fills the screen by default. Useful for accessibility and for keeping focus on one task at a time.",
            Margin = new Padding(0)
        };

        var aboutPage = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            BackColor = SystemColors.Window,
            Padding = new Padding(32, 28, 32, 28),
            Visible = false
        };
        aboutPage.Controls.Add(aboutTitle);
        aboutPage.Controls.Add(aboutSubtitle);
        aboutPage.Controls.Add(aboutVersionHeader);
        aboutPage.Controls.Add(aboutVersionValue);
        aboutPage.Controls.Add(aboutDescriptionHeader);
        aboutPage.Controls.Add(aboutDescription);

        // --- Sidebar nav ------------------------------------------------------------
        var sidebar = new ListBox
        {
            Dock = DockStyle.Fill,
            BackColor = Color.FromArgb(243, 243, 243),
            BorderStyle = BorderStyle.None,
            Font = new Font(form.Font.FontFamily, form.Font.Size + 1f),
            IntegralHeight = false,
            ItemHeight = 36,
            DrawMode = DrawMode.OwnerDrawFixed
        };
        sidebar.Items.Add("  Settings");
        sidebar.Items.Add("  About");
        sidebar.SelectedIndex = 0;
        sidebar.SelectedIndexChanged += (_, _) =>
        {
            var showAbout = sidebar.SelectedIndex == 1;
            settingsPage.Visible = !showAbout;
            aboutPage.Visible = showAbout;
        };

        var sidebarHost = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.FromArgb(243, 243, 243),
            Padding = new Padding(0, 16, 0, 16)
        };
        sidebarHost.Controls.Add(sidebar);

        // --- Content host (holds both pages, only one visible at a time) ------------
        var contentHost = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = SystemColors.Window
        };
        contentHost.Controls.Add(settingsPage);
        contentHost.Controls.Add(aboutPage);

        // --- Footer (buttons + version) --------------------------------------------
        var okButton = new Button
        {
            AutoSize = true,
            Text = "OK",
            Margin = new Padding(0, 0, 8, 0),
            MinimumSize = new Size(88, 30),
            FlatStyle = FlatStyle.Flat,
            UseVisualStyleBackColor = false
        };

        var cancelButton = new Button
        {
            AutoSize = true,
            Text = "Cancel",
            Margin = new Padding(0, 0, 8, 0),
            MinimumSize = new Size(88, 30),
            FlatStyle = FlatStyle.Flat,
            UseVisualStyleBackColor = false
        };

        var exitButton = new Button
        {
            AutoSize = true,
            Text = "Exit App",
            Margin = new Padding(0),
            MinimumSize = new Size(88, 30),
            FlatStyle = FlatStyle.Flat,
            UseVisualStyleBackColor = false
        };

        var buttonRow = new FlowLayoutPanel
        {
            AutoSize = true,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(0)
        };
        // RightToLeft flow: add in reverse visual order.
        buttonRow.Controls.Add(exitButton);
        buttonRow.Controls.Add(cancelButton);
        buttonRow.Controls.Add(okButton);

        var versionLabel = new Label
        {
            AutoSize = true,
            Text = $"Version {AppInfo.DisplayVersion}",
            ForeColor = SystemColors.GrayText,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0)
        };

        var footer = new TableLayoutPanel
        {
            Dock = DockStyle.Bottom,
            ColumnCount = 2,
            RowCount = 1,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Color.FromArgb(249, 249, 249),
            Padding = new Padding(20, 12, 20, 12)
        };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        footer.Controls.Add(versionLabel, 0, 0);
        footer.Controls.Add(buttonRow, 1, 0);

        // --- Root layout: sidebar | content, with footer pinned below --------------
        var body = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
            BackColor = SystemColors.Window
        };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 220));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.Controls.Add(sidebarHost, 0, 0);
        body.Controls.Add(contentHost, 1, 0);

        // Add footer FIRST so the body's Dock=Fill flows around it (docked controls
        // honor reverse z-order: last-added gets the remaining space).
        form.Controls.Add(footer);
        form.Controls.Add(body);

        form.AcceptButton = okButton;
        form.CancelButton = cancelButton;

        // --- Theming ----------------------------------------------------------------
        // Track palette in a closure-shared variable so the sidebar's owner-draw
        // handler always sees the current theme.
        ThemePalette palette = ThemeHelper.GetPalette(ThemeHelper.IsSystemInDarkMode());

        sidebar.DrawItem += (sender, e) =>
        {
            if (e.Index < 0 || sender is not ListBox lb)
            {
                return;
            }

            var isSelected = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
            var backColor = isSelected ? palette.SidebarSelected : palette.Sidebar;
            using (var bg = new SolidBrush(backColor))
            {
                e.Graphics.FillRectangle(bg, e.Bounds);
            }

            // Accent stripe on the selected item (Windows 11 Settings style).
            if (isSelected)
            {
                using var accent = new SolidBrush(palette.Accent);
                var stripe = new Rectangle(e.Bounds.Left, e.Bounds.Top + 6, 3, e.Bounds.Height - 12);
                e.Graphics.FillRectangle(accent, stripe);
            }

            var text = lb.Items[e.Index]?.ToString() ?? string.Empty;
            using var fg = new SolidBrush(palette.Text);
            var textBounds = new RectangleF(
                e.Bounds.Left + 12,
                e.Bounds.Top + (e.Bounds.Height - lb.Font.Height) / 2f,
                e.Bounds.Width - 12,
                lb.Font.Height);
            e.Graphics.DrawString(text, lb.Font, fg, textBounds);
        };

        void ApplyTheme(ThemePalette p)
        {
            palette = p;

            form.BackColor = p.Background;

            sidebarHost.BackColor = p.Sidebar;
            sidebar.BackColor = p.Sidebar;
            sidebar.ForeColor = p.Text;

            contentHost.BackColor = p.Surface;
            settingsPage.BackColor = p.Surface;
            aboutPage.BackColor = p.Surface;

            settingsTitle.ForeColor = p.Text;
            settingsSubtitle.ForeColor = p.MutedText;
            generalHeader.ForeColor = p.MutedText;
            startWithWindowsCheck.ForeColor = p.Text;
            appearanceHeader.ForeColor = p.MutedText;
            showInLabel.ForeColor = p.Text;
            trayRadio.ForeColor = p.Text;
            taskbarRadio.ForeColor = p.Text;

            aboutTitle.ForeColor = p.Text;
            aboutSubtitle.ForeColor = p.MutedText;
            aboutVersionHeader.ForeColor = p.MutedText;
            aboutVersionValue.ForeColor = p.Text;
            aboutDescriptionHeader.ForeColor = p.MutedText;
            aboutDescription.ForeColor = p.Text;

            footer.BackColor = p.Footer;
            versionLabel.ForeColor = p.MutedText;

            foreach (var btn in new[] { okButton, cancelButton, exitButton })
            {
                btn.BackColor = p.ButtonBack;
                btn.ForeColor = p.Text;
                btn.FlatAppearance.BorderColor = p.Border;
                btn.FlatAppearance.MouseOverBackColor = p.ButtonHover;
                btn.FlatAppearance.MouseDownBackColor = p.SidebarSelected;
            }

            // Theme the title bar via DWM (Win10 2004+ / Win11). Silently no-op on older versions.
            TrySetTitleBarTheme(form, p.IsDark);

            sidebar.Invalidate();
        }

        ApplyTheme(palette);

        // Re-apply when the user toggles system light/dark mode while the app is running.
        UserPreferenceChangedEventHandler themeChanged = (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General || e.Category == UserPreferenceCategory.VisualStyle)
            {
                if (form.IsDisposed)
                {
                    return;
                }
                form.BeginInvoke(new Action(() =>
                {
                    ApplyTheme(ThemeHelper.GetPalette(ThemeHelper.IsSystemInDarkMode()));
                }));
            }
        };
        SystemEvents.UserPreferenceChanged += themeChanged;
        form.FormClosed += (_, _) => SystemEvents.UserPreferenceChanged -= themeChanged;

        void ResetControlsFromSettings()
        {
            startWithWindowsCheck.Checked = _settings.StartWithWindows;
            trayRadio.Checked = _settings.RunInSystemTray;
            taskbarRadio.Checked = !_settings.RunInSystemTray;
            // Always show the Settings page when the window reopens.
            sidebar.SelectedIndex = 0;
        }

        form.VisibleChanged += (_, _) =>
        {
            if (form.Visible)
            {
                ResetControlsFromSettings();
            }
        };

        // In tray mode the settings window is hidden when dismissed (tray icon is the persistent surface).
        // In taskbar mode the window IS the persistent surface, so dismissing means minimize (stay in taskbar).
        void DismissForm()
        {
            if (_settings.RunInSystemTray)
            {
                form.Hide();
            }
            else
            {
                form.WindowState = FormWindowState.Minimized;
            }
        }

        okButton.Click += (_, _) =>
        {
            if (startWithWindowsCheck.Checked != _settings.StartWithWindows)
            {
                if (StartupRegistration.TrySetEnabled(startWithWindowsCheck.Checked, out var startupError))
                {
                    _settings.StartWithWindows = startWithWindowsCheck.Checked;
                    startWithWindowsItem.Checked = startWithWindowsCheck.Checked;
                    SettingsService.Save(_settings);
                }
                else
                {
                    MessageBox.Show(
                        $"Could not update startup setting. {startupError}",
                        "Maximize All Windows",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    startWithWindowsCheck.Checked = _settings.StartWithWindows;
                    return;
                }
            }

            var newRunInTray = trayRadio.Checked;
            if (newRunInTray != _settings.RunInSystemTray)
            {
                // Switch modes first (this updates window visibility for the new mode), then dismiss.
                ApplyRunInSystemTraySetting(newRunInTray);
            }

            DismissForm();
        };

        cancelButton.Click += (_, _) =>
        {
            ResetControlsFromSettings();
            DismissForm();
        };

        exitButton.Click += (_, _) => ExitThread();

        form.FormClosing += (_, e) =>
        {
            if (_isExiting)
            {
                return;
            }

            if (_settings.RunInSystemTray)
            {
                e.Cancel = true;
                ResetControlsFromSettings();
                form.Hide();
                return;
            }

            // Taskbar mode: closing the only window means quitting the app.
            ExitThread();
        };

        return form;
    }

    // DWMWA_USE_IMMERSIVE_DARK_MODE: 20 on Win10 build 19041+ / Win11; 19 on earlier Win10 2004 builds.
    private const uint DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const uint DWMWA_USE_IMMERSIVE_DARK_MODE_LEGACY = 19;

    private static void TrySetTitleBarTheme(Form form, bool dark)
    {
        if (!form.IsHandleCreated)
        {
            // Force handle creation so DWM has something to attach to.
            _ = form.Handle;
        }

        int value = dark ? 1 : 0;
        var hr = DwmSetWindowAttribute(form.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, sizeof(int));
        if (hr != 0)
        {
            // Fall back to the legacy attribute id used on early Win10 2004 builds.
            DwmSetWindowAttribute(form.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_LEGACY, ref value, sizeof(int));
        }
    }

    private void ShowControlWindow()
    {
        _controlWindow.Show();
        if (_controlWindow.WindowState == FormWindowState.Minimized && _controlWindow.IsHandleCreated)
        {
            // Restore to the previous state (Maximized or Normal), not unconditionally Normal.
            ShowWindow(_controlWindow.Handle, SW_RESTORE);
        }

        _controlWindow.BringToFront();
        _controlWindow.Activate();
    }

    private void ApplyRunInSystemTraySetting(bool enabled, bool showBalloon = true)
    {
        _settings.RunInSystemTray = enabled;
        SettingsService.Save(_settings);

        if (!enabled)
        {
            _trayIcon.Visible = false;
            _trayPromoteTimer.Stop();
            ShowControlWindow();
            return;
        }

        EnsureTrayIconVisible();
        SchedulePromoteAndVerify(delayMs: 250, reason: "tray mode enabled");

        if (_controlWindow.IsHandleCreated && _controlWindow.Visible)
        {
            _controlWindow.Hide();
        }

        if (showBalloon)
        {
            _trayIcon.ShowBalloonTip(
                2000,
                "Maximize All Windows",
                "Running in system tray mode.",
                ToolTipIcon.Info);
        }
    }

    private void HandleFirstRunPrompt(ToolStripMenuItem startWithWindowsItem)
    {
        if (_settings.HasCompletedFirstRunPrompt)
        {
            AppLog.Write("First-run prompt already completed; skipping.");
            return;
        }

        var result = MessageBox.Show(
            "Start Maximize All Windows automatically when you sign in to Windows?",
            "Maximize All Windows",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question,
            MessageBoxDefaultButton.Button1);

        if (result == DialogResult.Yes)
        {
            if (StartupRegistration.TrySetEnabled(true, out var startupError))
            {
                _settings.StartWithWindows = true;
                startWithWindowsItem.Checked = true;
                AppLog.Write("First-run prompt accepted; startup enabled.");
            }
            else
            {
                AppLog.Write($"First-run prompt accepted but enabling startup failed: {startupError}");
                MessageBox.Show(
                    $"Could not enable startup. {startupError}",
                    "Maximize All Windows",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
            }
        }
        else
        {
            AppLog.Write("First-run prompt declined.");
        }

        _settings.HasCompletedFirstRunPrompt = true;
        SettingsService.Save(_settings);
        AppLog.Write("First-run prompt marked complete.");
    }

    private delegate void WinEventDelegate(
        nint hWinEventHook,
        uint eventType,
        nint hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime);

    [DllImport("user32.dll")]
    private static extern nint SetWinEventHook(
        uint eventMin,
        uint eventMax,
        nint hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc,
        uint idProcess,
        uint idThread,
        uint dwFlags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWinEvent(nint hWinEventHook);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(nint hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsZoomed(nint hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(nint hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(nint hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern nint GetWindowLongPtr(nint hWnd, int nIndex);

    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint hWnd, uint gaFlags);

    [DllImport("user32.dll")]
    private static extern nint GetWindow(nint hWnd, uint uCmd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(nint hWnd, [Out] char[] lpClassName, int nMaxCount);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(nint hwnd, uint dwAttribute, out int pvAttribute, int cbAttribute);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, uint dwAttribute, ref int pvAttribute, int cbAttribute);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}

internal sealed class AppSettings
{
    public bool StartWithWindows { get; set; }
    public bool RunInSystemTray { get; set; } = true;
    public bool HasCompletedFirstRunPrompt { get; set; }
}

internal static class SettingsService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private static string SettingsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MaximizeAllWindows");

    private static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new AppSettings();
            }

            var json = File.ReadAllText(SettingsPath);
            return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public static void Save(AppSettings settings)
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            var json = JsonSerializer.Serialize(settings, JsonOptions);
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // Ignore settings write failures; app functionality should continue.
        }
    }
}

internal static class AppLog
{
    private static readonly object Sync = new();
    private static string LogDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MaximizeAllWindows");

    private static string LogPath => Path.Combine(LogDirectory, "startup.log");

    public static void Write(string message)
    {
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(LogDirectory);
                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} | PID {Environment.ProcessId} | {message}{Environment.NewLine}";
                File.AppendAllText(LogPath, line);
            }
        }
        catch
        {
            // Never let logging interfere with app startup.
        }
    }
}

internal static class StartupRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "MaximizeAllWindows";

    public static bool IsCurrentExecutableRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        if (key?.GetValue(ValueName) is not string command || string.IsNullOrWhiteSpace(command))
        {
            return false;
        }

        return IsCommandForCurrentExecutable(command);
    }

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(ValueName) is string command && !string.IsNullOrWhiteSpace(command);
    }

    public static bool TrySetEnabled(bool enabled, out string error)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            if (key is null)
            {
                error = "Startup registry key is unavailable.";
                return false;
            }

            if (enabled)
            {
                var command = string.Format(CultureInfo.InvariantCulture, "\"{0}\"", Application.ExecutablePath);
                key.SetValue(ValueName, command, RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }

            error = string.Empty;
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static bool IsCommandForCurrentExecutable(string command)
    {
        var configuredPath = ExtractExecutablePath(command);
        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            return false;
        }

        try
        {
            var configuredFullPath = Path.GetFullPath(configuredPath);
            var currentFullPath = Path.GetFullPath(Application.ExecutablePath);
            return string.Equals(configuredFullPath, currentFullPath, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static string ExtractExecutablePath(string command)
    {
        var trimmed = command.Trim();
        if (trimmed.Length == 0)
        {
            return string.Empty;
        }

        if (trimmed[0] == '"')
        {
            var closingQuote = trimmed.IndexOf('"', 1);
            return closingQuote > 1 ? trimmed.Substring(1, closingQuote - 1) : string.Empty;
        }

        var firstSpace = trimmed.IndexOf(' ');
        return firstSpace > 0 ? trimmed[..firstSpace] : trimmed;
    }
}

internal sealed class ThemePalette
{
    public bool IsDark { get; init; }
    public Color Background { get; init; }
    public Color Surface { get; init; }
    public Color Sidebar { get; init; }
    public Color SidebarSelected { get; init; }
    public Color SidebarHover { get; init; }
    public Color Footer { get; init; }
    public Color Text { get; init; }
    public Color MutedText { get; init; }
    public Color Border { get; init; }
    public Color Accent { get; init; }
    public Color ButtonBack { get; init; }
    public Color ButtonHover { get; init; }
}

internal static class ThemeHelper
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public static bool IsSystemInDarkMode()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            // AppsUseLightTheme: 1 = light, 0 = dark. Default to light when missing.
            var value = key?.GetValue("AppsUseLightTheme");
            if (value is int i)
            {
                return i == 0;
            }
        }
        catch
        {
            // Fall through to light default.
        }
        return false;
    }

    public static ThemePalette GetPalette(bool dark)
    {
        if (dark)
        {
            return new ThemePalette
            {
                IsDark = true,
                Background = Color.FromArgb(32, 32, 32),
                Surface = Color.FromArgb(40, 40, 40),
                Sidebar = Color.FromArgb(24, 24, 24),
                SidebarSelected = Color.FromArgb(55, 55, 55),
                SidebarHover = Color.FromArgb(45, 45, 45),
                Footer = Color.FromArgb(28, 28, 28),
                Text = Color.FromArgb(240, 240, 240),
                MutedText = Color.FromArgb(170, 170, 170),
                Border = Color.FromArgb(60, 60, 60),
                Accent = Color.FromArgb(0, 120, 212),
                ButtonBack = Color.FromArgb(55, 55, 55),
                ButtonHover = Color.FromArgb(70, 70, 70)
            };
        }

        return new ThemePalette
        {
            IsDark = false,
            Background = SystemColors.Window,
            Surface = SystemColors.Window,
            Sidebar = Color.FromArgb(243, 243, 243),
            SidebarSelected = Color.FromArgb(225, 225, 225),
            SidebarHover = Color.FromArgb(235, 235, 235),
            Footer = Color.FromArgb(249, 249, 249),
            Text = SystemColors.ControlText,
            MutedText = SystemColors.GrayText,
            Border = Color.FromArgb(220, 220, 220),
            Accent = Color.FromArgb(0, 120, 212),
            ButtonBack = SystemColors.Control,
            ButtonHover = Color.FromArgb(229, 241, 251)
        };
    }

    public static void ApplyToContextMenuStrip(ContextMenuStrip menu, ThemePalette palette)
    {
        if (palette.IsDark)
        {
            menu.Renderer = new ToolStripProfessionalRenderer(new DarkMenuColors(palette))
            {
                RoundedEdges = false
            };
            menu.BackColor = palette.Surface;
            menu.ForeColor = palette.Text;
            foreach (ToolStripItem item in menu.Items)
            {
                item.BackColor = palette.Surface;
                item.ForeColor = palette.Text;
            }
        }
        else
        {
            // Reset to the OS default professional renderer (system colors).
            menu.RenderMode = ToolStripRenderMode.ManagerRenderMode;
            menu.BackColor = SystemColors.Menu;
            menu.ForeColor = SystemColors.MenuText;
            foreach (ToolStripItem item in menu.Items)
            {
                item.BackColor = SystemColors.Menu;
                item.ForeColor = SystemColors.MenuText;
            }
        }
    }

    private sealed class DarkMenuColors : ProfessionalColorTable
    {
        private readonly ThemePalette _p;
        public DarkMenuColors(ThemePalette palette) { _p = palette; UseSystemColors = false; }

        public override Color MenuItemSelected => _p.SidebarSelected;
        public override Color MenuItemSelectedGradientBegin => _p.SidebarSelected;
        public override Color MenuItemSelectedGradientEnd => _p.SidebarSelected;
        public override Color MenuItemBorder => _p.Accent;
        public override Color MenuItemPressedGradientBegin => _p.SidebarSelected;
        public override Color MenuItemPressedGradientEnd => _p.SidebarSelected;
        public override Color MenuBorder => _p.Border;
        public override Color ToolStripDropDownBackground => _p.Surface;
        public override Color ImageMarginGradientBegin => _p.Surface;
        public override Color ImageMarginGradientMiddle => _p.Surface;
        public override Color ImageMarginGradientEnd => _p.Surface;
        public override Color SeparatorDark => _p.Border;
        public override Color SeparatorLight => _p.Border;
        public override Color CheckBackground => _p.SidebarSelected;
        public override Color CheckSelectedBackground => _p.SidebarSelected;
        public override Color CheckPressedBackground => _p.SidebarSelected;
    }
}

internal static class InstallManager
{
    private const string UninstallKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\MaximizeAllWindows";

    public static string GetInstallDirectory()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            "MaximizeAllWindows");
    }

    public static string GetInstalledExecutablePath()
    {
        return Path.Combine(GetInstallDirectory(), "MaximizeAllWindows.exe");
    }

    public static bool IsRunningFromInstallLocation()
    {
        try
        {
            var current = Path.GetFullPath(AppContext.BaseDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var installed = Path.GetFullPath(GetInstallDirectory())
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return string.Equals(current, installed, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    public static bool TryInstall(out string message)
    {
        try
        {
            var sourceDir = Path.GetFullPath(AppContext.BaseDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var installDir = GetInstallDirectory();
            var preservedSettings = SettingsService.Load();

            if (!string.Equals(sourceDir, installDir, StringComparison.OrdinalIgnoreCase))
            {
                if (IsInstalledInstanceRunning(out var runningPid))
                {
                    message = $"Install cannot continue because the installed app is currently running (PID {runningPid}). Exit Maximize All Windows and try again.";
                    return false;
                }

                if (Directory.Exists(installDir))
                {
                    Directory.Delete(installDir, recursive: true);
                }

                Directory.CreateDirectory(installDir);
                CopyDirectoryContents(sourceDir, installDir);
            }

            RegisterUninstallEntry();
            SettingsService.Save(preservedSettings);
            message = $"Installed for current user at {installDir}. Existing install contents were replaced and user settings were preserved. You can remove it from Add/Remove Programs.";
            return true;
        }
        catch (Exception ex)
        {
            message = $"Install failed. {ex.Message} If the app is running from the install location, exit it and try again.";
            return false;
        }
    }

    public static bool TryUninstall(out string message)
    {
        try
        {
            StartupRegistration.TrySetEnabled(false, out _);
            RemoveUninstallEntry();

            var installDir = GetInstallDirectory();
            if (!Directory.Exists(installDir))
            {
                message = "Uninstall complete.";
                return true;
            }

            if (IsRunningFromInstallLocation())
            {
                var cleanupCommand = $"/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"{installDir}\"";
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = cleanupCommand,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                });
                message = "Uninstall started. The app folder will be removed after exit.";
                return true;
            }

            Directory.Delete(installDir, recursive: true);
            message = "Uninstall complete.";
            return true;
        }
        catch (Exception ex)
        {
            message = $"Uninstall failed. {ex.Message}";
            return false;
        }
    }

    private static void RegisterUninstallEntry()
    {
        var installDir = GetInstallDirectory();
        var installedExe = GetInstalledExecutablePath();
        var version = FileVersionInfo.GetVersionInfo(installedExe).FileVersion ?? "1.0.0";
        using var key = Registry.CurrentUser.CreateSubKey(UninstallKeyPath, writable: true);
        if (key is null)
        {
            throw new InvalidOperationException("Unable to create uninstall registry key.");
        }

        key.SetValue("DisplayName", "Maximize All Windows", RegistryValueKind.String);
        key.SetValue("Publisher", "Maximize-All-Windows", RegistryValueKind.String);
        key.SetValue("DisplayVersion", version, RegistryValueKind.String);
        key.SetValue("InstallLocation", installDir, RegistryValueKind.String);
        key.SetValue("DisplayIcon", installedExe, RegistryValueKind.String);
        key.SetValue("UninstallString", $"\"{installedExe}\" --uninstall", RegistryValueKind.String);
        key.SetValue("QuietUninstallString", $"\"{installedExe}\" --uninstall", RegistryValueKind.String);
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
    }

    private static void RemoveUninstallEntry()
    {
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKeyPath, throwOnMissingSubKey: false);
    }

    private static bool IsInstalledInstanceRunning(out int pid)
    {
        pid = 0;
        string installedExe;
        try
        {
            installedExe = Path.GetFullPath(GetInstalledExecutablePath());
        }
        catch
        {
            return false;
        }

        foreach (var process in Process.GetProcessesByName("MaximizeAllWindows"))
        {
            try
            {
                var processPath = process.MainModule?.FileName;
                if (string.IsNullOrWhiteSpace(processPath))
                {
                    continue;
                }

                var fullProcessPath = Path.GetFullPath(processPath);
                if (!string.Equals(fullProcessPath, installedExe, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                pid = process.Id;
                return true;
            }
            catch
            {
                // Ignore processes we cannot inspect.
            }
            finally
            {
                process.Dispose();
            }
        }

        return false;
    }

    private static void CopyDirectoryContents(string sourceDir, string destinationDir)
    {
        Directory.CreateDirectory(destinationDir);

        foreach (var filePath in Directory.GetFiles(sourceDir))
        {
            var fileName = Path.GetFileName(filePath);
            var destinationPath = Path.Combine(destinationDir, fileName);
            File.Copy(filePath, destinationPath, overwrite: true);
        }

        foreach (var sourceSubDir in Directory.GetDirectories(sourceDir))
        {
            var dirName = Path.GetFileName(sourceSubDir);
            var destinationSubDir = Path.Combine(destinationDir, dirName);
            CopyDirectoryContents(sourceSubDir, destinationSubDir);
        }
    }
}

internal sealed class TaskbarCreatedWatcher : NativeWindow, IDisposable
{
    private readonly Action _onTaskbarCreated;
    private readonly uint _taskbarCreatedMessage;

    public TaskbarCreatedWatcher(Action onTaskbarCreated)
    {
        _onTaskbarCreated = onTaskbarCreated;
        _taskbarCreatedMessage = RegisterWindowMessage("TaskbarCreated");
        CreateHandle(new CreateParams());
    }

    protected override void WndProc(ref Message m)
    {
        if ((uint)m.Msg == _taskbarCreatedMessage)
        {
            _onTaskbarCreated();
        }

        base.WndProc(ref m);
    }

    public void Dispose()
    {
        DestroyHandle();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string lpString);
}

internal static class TrayIconPromoter
{
    private const string SettingsKeyPath = @"Control Panel\NotifyIconSettings";

    public enum Result
    {
        NoEntryFound,
        AlreadyPromoted,
        Promoted,
        Error
    }

    public static Result TryPromote(string exePath)
    {
        try
        {
            using var root = Registry.CurrentUser.OpenSubKey(SettingsKeyPath, writable: true);
            if (root is null)
            {
                return Result.NoEntryFound;
            }

            var promotedAny = false;
            var foundAny = false;

            foreach (var subkeyName in root.GetSubKeyNames())
            {
                using var sub = root.OpenSubKey(subkeyName, writable: true);
                if (sub is null) continue;

                var path = sub.GetValue("ExecutablePath") as string;
                if (string.IsNullOrWhiteSpace(path)) continue;
                if (!string.Equals(path, exePath, StringComparison.OrdinalIgnoreCase)) continue;

                foundAny = true;
                var raw = sub.GetValue("IsPromoted");
                var current = raw is int i ? i : Convert.ToInt32(raw ?? 0);
                if (current == 1)
                {
                    continue;
                }

                sub.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
                promotedAny = true;
            }

            if (!foundAny) return Result.NoEntryFound;
            return promotedAny ? Result.Promoted : Result.AlreadyPromoted;
        }
        catch (Exception ex)
        {
            AppLog.Write($"TrayIconPromoter error: {ex.Message}");
            return Result.Error;
        }
    }
}

internal static class TrayIconReflection
{
    public static (nint Hwnd, uint Uid) GetIdentity(NotifyIcon icon)
    {
        try
        {
            var type = icon.GetType();

            uint id = 0;
            nint hwnd = nint.Zero;

            foreach (var name in new[] { "_id", "id" })
            {
                var f = type.GetField(name, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                if (f is null) continue;
                var raw = f.GetValue(icon);
                if (raw is null) continue;
                try { id = Convert.ToUInt32(raw); } catch { }
                if (id != 0) break;
            }

            foreach (var name in new[] { "_window", "window" })
            {
                var f = type.GetField(name, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                if (f is null) continue;
                var raw = f.GetValue(icon);
                if (raw is NativeWindow nw)
                {
                    hwnd = nw.Handle;
                    break;
                }
            }

            return (hwnd, id);
        }
        catch (Exception ex)
        {
            AppLog.Write($"TrayIconReflection.GetIdentity failed: {ex.Message}");
            return (nint.Zero, 0u);
        }
    }
}

internal static class TrayIconLocator
{
    public enum Visibility
    {
        Unknown,
        NotFound,
        Visible,
        Overflow
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONIDENTIFIER
    {
        public int cbSize;
        public nint hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint FindWindow(string? lpClassName, string? lpWindowName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint hWnd, out RECT lpRect);

    public static Visibility Query(nint hwnd, uint uid)
    {
        if (hwnd == nint.Zero || uid == 0)
        {
            return Visibility.Unknown;
        }

        var ident = new NOTIFYICONIDENTIFIER
        {
            cbSize = Marshal.SizeOf<NOTIFYICONIDENTIFIER>(),
            hWnd = hwnd,
            uID = uid,
            guidItem = Guid.Empty
        };

        var hr = Shell_NotifyIconGetRect(ref ident, out var iconRect);
        // S_OK (0) = rect returned; S_FALSE (1) = exists, in overflow; E_FAIL (~0x80004005) = not registered.
        if (hr == 0)
        {
            var onTaskbar = IsOnPrimaryTaskbar(iconRect, out var tb);
            AppLog.Write($"  IconRect=({iconRect.Left},{iconRect.Top},{iconRect.Right},{iconRect.Bottom}) Shell_TrayWnd=({tb.Left},{tb.Top},{tb.Right},{tb.Bottom}) onTaskbar={onTaskbar}");
            return onTaskbar ? Visibility.Visible : Visibility.Overflow;
        }

        if (hr == 1)
        {
            AppLog.Write("  Shell_NotifyIconGetRect returned S_FALSE (icon in overflow flyout).");
            return Visibility.Overflow;
        }

        AppLog.Write($"  Shell_NotifyIconGetRect hr=0x{hr:X8}");
        return Visibility.NotFound;
    }

    private static bool IsOnPrimaryTaskbar(RECT iconRect, out RECT tb)
    {
        tb = default;
        var taskbar = FindWindow("Shell_TrayWnd", null);
        if (taskbar == nint.Zero) return false;
        if (!GetWindowRect(taskbar, out tb)) return false;

        var cx = (iconRect.Left + iconRect.Right) / 2;
        var cy = (iconRect.Top + iconRect.Bottom) / 2;
        return cx >= tb.Left && cx <= tb.Right && cy >= tb.Top && cy <= tb.Bottom;
    }
}
