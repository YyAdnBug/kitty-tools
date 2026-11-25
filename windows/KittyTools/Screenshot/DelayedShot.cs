// 延时截图（PLAN-v26 S2，照 mac 0.10.1 10875af2）：全局动作「延时截图」（delayedScreenshot，不设默认键；托盘、主界面、启动器里都有）。
// 按下后倒数 设置 › 截图「延时截图等几秒」（5 / 10，默认 5，mac screenshotDelay）再冻结屏幕、进框选——用来截只在悬停时出现的提示、展开的菜单。
// 倒数在屏幕底部那条进度提示上（mac 在刘海岛，MAC-DIFF 的长期例外）：「现在截」马上截、「取消」/ Esc / 再按一次快捷键取消。
// Esc 是临时注册的全局热键（同录屏倒数），只挂倒数那几秒。到点先收起提示、等它退场再冻结，提示不会进截图。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;

namespace KittyTools;

internal static class DelayedShot
{
    public const int EscapeId = 931;
    private const string Title = "延时截图";

    private static DispatcherQueueTimer? _timer;
    private static int _total;
    private static int _remaining;

    public static bool Active { get; private set; }

    /// <summary>快捷键 / 托盘 / 主界面 / 启动器：没在倒数就开始，在倒数就取消（再按一次取消，同 mac）。</summary>
    public static void Toggle()
    {
        if (Active)
        {
            Cancel();
            return;
        }

        _total = SettingsService.Current.ScreenshotDelay is 10 ? 10 : 5;
        _remaining = _total;
        Active = true;
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EscapeId, 0, (uint)Windows.Win32.UI.Input.KeyboardAndMouse.VIRTUAL_KEY.VK_ESCAPE);
        Show();
        _timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) =>
        {
            _remaining--;
            if (_remaining > 0)
            {
                Show();
                return;
            }

            _ = CaptureAsync();
        };
        _timer.Start();
        Log.Info($"screenshot.delayed start={_total}");
    }

    /// <summary>不等了：马上截。</summary>
    public static void Now()
    {
        if (Active)
        {
            _ = CaptureAsync();
        }
    }

    public static void Cancel()
    {
        if (!Active)
        {
            return;
        }

        Finish();
        NoticeHost.Show("已取消延时截图", string.Empty, NoticeTone.Normal);
        Log.Info("screenshot.delayed cancelled");
    }

    private static void Show()
        => NoticeHost.ShowProgress(Title, $"{_remaining} 秒后截图 · Esc 取消", (_total - _remaining) / (double)_total,
            new NoticeAction("现在截", Now), new NoticeAction("取消", Cancel));

    private static async Task CaptureAsync()
    {
        Finish();
        NoticeHost.HideNow();
        // 等提示退场（它是自己的窗口，冻结帧不该拍到它）
        await Task.Delay(250);
        ScreenshotSession.Start(ScreenshotMode.Capture);
    }

    private static void Finish()
    {
        Active = false;
        _timer?.Stop();
        _timer = null;
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, EscapeId);
    }
}
