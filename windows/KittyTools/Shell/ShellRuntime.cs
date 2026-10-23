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
#endif
        if (SettingsService.IsNew)
        {
            ShowSettings(welcome: true);
        }
    }

    public void ShowSettings(bool welcome)
    {
        OverlayHost.Hide(restoreForeground: false);
        if (_settingsWindow is null || _settingsWindow.IsClosed)
        {
            _settingsWindow = new SettingsWindow();
        }

        _settingsWindow.ShowPage(welcome);
    }

    public void ToggleCopyTranslate()
    {
        SettingsService.Current.CopyTranslate = !SettingsService.Current.CopyTranslate;
        SettingsService.Save();
        NoticeHost.Show("复制即译", SettingsService.Current.CopyTranslate ? "已打开" : "已关闭", NoticeTone.Normal);
    }

    public void TogglePauseClipboard()
    {
        SettingsService.Current.PauseClipboard = !SettingsService.Current.PauseClipboard;
        SettingsService.Save();
        NoticeHost.Show("剪贴板记录", SettingsService.Current.PauseClipboard ? "已暂停" : "已恢复", NoticeTone.Normal);
    }

    public void ShowNotice(string title, string detail, NoticeTone tone = NoticeTone.Normal)
        => NoticeHost.Show(title, detail, tone);

    public void Exit()
    {
        Log.Info("app.exit");
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
