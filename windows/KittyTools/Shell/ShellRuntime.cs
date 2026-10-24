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

        HiddenWindow.Message += OnHiddenMessage;
        Tray.Add();
        HotKeys.Pressed += OnHotKey;
        HotKeys.RegisterAll(SettingsService.Current);
        SettingsService.Changed += OnSettingsChanged;
        var dispatcher = DispatcherQueue.GetForCurrentThread();
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
                ShowNotice("划词翻译", "第 3 批接上", NoticeTone.Normal);
                break;
            case HotKeyActions.InputTranslate:
                ShowNotice("输入翻译", "第 3 批接上", NoticeTone.Normal);
                break;
            case HotKeyActions.ScreenshotTranslate:
                ShowNotice("截图翻译", "第 5 批接上", NoticeTone.Normal);
                break;
            case HotKeyActions.Screenshot:
                ShowNotice("截图", "第 5 批接上", NoticeTone.Normal);
                break;
            case HotKeyActions.Ocr:
                ShowNotice("识字", "第 5 批接上", NoticeTone.Normal);
                break;
        }
    }

    private void OnSettingsChanged()
    {
        HotKeys.RegisterAll(SettingsService.Current);
        Theme.ApplyAccent();
        _settingsWindow?.RefreshTheme();
    }
}
