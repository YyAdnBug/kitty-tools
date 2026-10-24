// 壳的运行时：隐藏窗口、托盘、热键、浮层、轻提示、设置窗和单实例转发。
// 第 1 批只把壳做齐；各模块的入口先给轻提示，面板内容是占位。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.Win32;

namespace KittyTools;

internal sealed class ShellRuntime
{
    private Window? _keeper;
    private SettingsWindow? _settingsWindow;

    public static ShellRuntime? Instance { get; private set; }

    public HotKeyManager HotKeys { get; } = new();

    public ClipboardService? Clipboard { get; private set; }

    public static ShellRuntime Start()
    {
        var runtime = new ShellRuntime();
        Instance = runtime;
        runtime.Initialize();
        return runtime;
    }

    private void Initialize()
    {
        // WinUI 3 在最后一个 XAML 窗口关闭时会结束进程；常驻托盘要留一个永不关闭的
        // 隐藏窗口。它不激活、不进任务栏和 Alt+Tab，只负责把 XAML 生命周期撑住。
        _keeper = new Window { Title = Paths.ProductName };
        _keeper.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(-32000, -32000, 1, 1));
        _keeper.AppWindow.IsShownInSwitchers = false;

        if (!HiddenWindow.Create())
        {
            Application.Current.Exit();
            return;
        }

        try
        {
            var database = Database.OpenDefault();
            Clipboard = ClipboardService.Start(database, new ImageStore(Paths.ImagesDirectory));
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.start-failed", ex);
            NoticeHost.Show("剪贴板历史用不了", "数据库打不开，其它功能不受影响", NoticeTone.Error);
        }

        TranslateServiceStore.Start(SettingsService.Current);
        TranslateHost.Initialize();
        if (Clipboard is not null)
        {
            LauncherUsageStore.Start(Clipboard.Database);
        }

        AppCatalog.Start();
        LauncherModel.Start();

        HiddenWindow.Message += OnHiddenMessage;
        Tray.Add();
        HotKeys.Pressed += OnHotKey;
        HotKeys.RegisterAll(SettingsService.Current);
        SettingsService.Changed += OnSettingsChanged;
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        UpdateService.Initialize(dispatcher!);
        UpdateService.Configure(SettingsService.Current.AutoCheckUpdates);
        SingleInstance.StartServer(() =>
            dispatcher?.TryEnqueue(() => ShowSettings(welcome: false)));

        Log.Info("shell.ready");
#if DEBUG
        if (Environment.GetCommandLineArgs().Contains("--tray-menu", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(Tray.ShowMenu);
        }

        // 调试用：跳过热键直接打开剪贴板面板（热键被别的实例占着时也能看界面）。
        if (Environment.GetCommandLineArgs().Contains("--clipboard-panel", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(OpenClipboard);
        }

        // 调试用：直接打开设置里的某一页，比如 --settings=clipboard。
        var settingsArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--settings=", StringComparison.OrdinalIgnoreCase));
        if (settingsArg is not null)
        {
            var page = settingsArg["--settings=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ShowSettings(welcome: false, page));
        }

        // 调试用：直接打开翻译浮窗，带文字时自动翻。
        if (Environment.GetCommandLineArgs().Contains("--translate", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => TranslateHost.ShowInput());
        }

        var translateArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--translate-text=", StringComparison.OrdinalIgnoreCase));
        if (translateArg is not null)
        {
            var text = translateArg["--translate-text=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => TranslateHost.ShowText(text));
        }

        if (Environment.GetCommandLineArgs().Contains("--selection", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => TranslateHost.ShowSelection());
        }

        if (Environment.GetCommandLineArgs().Contains("--ocr", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ScreenshotSession.Start(ScreenshotMode.Ocr));
        }

        if (Environment.GetCommandLineArgs().Contains("--screenshot-translate", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ScreenshotSession.Start(ScreenshotMode.Translate));
        }

        if (Environment.GetCommandLineArgs().Contains("--update-check", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => _ = UpdateService.CheckAsync(userInitiated: true));
        }
        if (Environment.GetCommandLineArgs().Contains("--screenshot", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ScreenshotSession.Start(ScreenshotMode.Capture));
        }

        if (Environment.GetCommandLineArgs().Contains("--launcher", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => OverlayHost.Show(OverlayKind.Launcher));
        }

        if (Environment.GetCommandLineArgs().Contains("--dump-icon", StringComparer.OrdinalIgnoreCase))
        {
            _ = Task.Run(async () =>
            {
                await Task.Delay(6000);
                var app = AppCatalog.Instance?.Apps.FirstOrDefault(
                              item => item.Title.Contains("Chrome", StringComparison.OrdinalIgnoreCase))
                          ?? AppCatalog.Instance?.Apps.FirstOrDefault(item => item.IconData is { Length: > 0 });
                if (app?.IconData is { } bytes)
                {
                    var path = Path.Combine(Paths.DataDirectory, "icon-dump.png");
                    await File.WriteAllBytesAsync(path, bytes);
                    Log.Info($"launcher.icon-dump {path} {bytes.Length}");
                }
            });
        }

        if (Environment.GetCommandLineArgs().Contains("--cred-smoke", StringComparer.OrdinalIgnoreCase))
        {
            var written = Credentials.Set("smoke-test", "credential-value");
            var read = Credentials.Get("smoke-test") == "credential-value";
            var deleted = Credentials.Delete("smoke-test");
            Log.Info($"cred.smoke write={written} read={read} delete={deleted}");
        }
#endif
        if (SettingsService.IsNew)
        {
            ShowSettings(welcome: true);
        }
    }

    public void ShowSettings(bool welcome, string page = "general")
    {
        OverlayHost.Hide(restoreForeground: false);
        if (_settingsWindow is null || _settingsWindow.IsClosed)
        {
            _settingsWindow = new SettingsWindow();
        }

        _settingsWindow.ShowPage(welcome, page);
    }

    public void ToggleCopyTranslate()
    {
        SettingsService.Current.CopyTranslate = !SettingsService.Current.CopyTranslate;
        SettingsService.Save();
        NoticeHost.Show("复制即译", SettingsService.Current.CopyTranslate ? "已打开" : "已关闭", NoticeTone.Normal);
    }

    public void TogglePauseClipboard()
    {
        if (Clipboard is null)
        {
            return;
        }

        Clipboard.Paused = !Clipboard.Paused;
        NoticeHost.Show("剪贴板记录", Clipboard.Paused ? "已暂停" : "已恢复", NoticeTone.Normal);
    }

    public void OpenClipboard() => OverlayHost.Show(OverlayKind.Clipboard);

    public void ShowNotice(string title, string detail, NoticeTone tone = NoticeTone.Normal)
        => NoticeHost.Show(title, detail, tone);

    public void Exit()
    {
        Log.Info("app.exit");
        Clipboard?.CommitDeletion();
        HotKeys.UnregisterAll();
        Tray.Remove();
        Application.Current.Exit();
    }

    private void OnHiddenMessage(uint msg, Windows.Win32.Foundation.WPARAM wParam, Windows.Win32.Foundation.LPARAM lParam)
    {
        if (msg == PInvoke.WM_HOTKEY)
        {
            HotKeys.OnHotKey((int)wParam.Value);
        }
        else if (msg == PInvoke.WM_CLIPBOARDUPDATE)
        {
            Clipboard?.OnClipboardUpdate();
        }
        else if (msg == Tray.CallbackMessage)
        {
            Tray.OnCallback(msg, wParam, lParam);
        }
    }

    private void OnHotKey(string action)
    {
        switch (action)
        {
            case HotKeyActions.Clipboard:
                OverlayHost.Toggle(OverlayKind.Clipboard);
                break;
            case HotKeyActions.Launcher:
                OverlayHost.Toggle(OverlayKind.Launcher);
                break;
            case HotKeyActions.SelectionTranslate:
                TranslateHost.ShowSelection();
                break;
            case HotKeyActions.InputTranslate:
                TranslateHost.ToggleInput();
                break;
            case HotKeyActions.ScreenshotTranslate:
                ScreenshotSession.Start(ScreenshotMode.Translate);
                break;
            case HotKeyActions.Screenshot:
                ScreenshotSession.Start(ScreenshotMode.Capture);
                break;
            case HotKeyActions.Ocr:
                ScreenshotSession.Start(ScreenshotMode.Ocr);
                break;
        }
    }

    private void OnSettingsChanged()
    {
        HotKeys.RegisterAll(SettingsService.Current);
        UpdateService.Configure(SettingsService.Current.AutoCheckUpdates);
        Theme.ApplyAccent();
        TranslateHost.ApplyCopyTranslate();
        _settingsWindow?.RefreshTheme();
    }
}
