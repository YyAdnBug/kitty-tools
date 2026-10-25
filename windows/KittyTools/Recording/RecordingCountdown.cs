// 录屏倒数（第四版）：选区确认后 3 秒开始，轻提示「3 秒后开始录屏…」，期间 Esc 取消。
// Esc 是临时注册的全局热键（只挂这三秒），倒数结束 / 取消立刻注销。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;

namespace KittyTools;

internal static class RecordingCountdown
{
    public const int EscapeId = 930;

    private static DispatcherQueueTimer? _timer;
    private static PixelBounds _region;
    private static int _remaining;

    public static bool Active { get; private set; }

    public static void Start(PixelBounds region)
    {
        if (Active)
        {
            return;
        }

        _region = region;
        _remaining = 3;
        Active = true;
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EscapeId, 0, (uint)Windows.Win32.UI.Input.KeyboardAndMouse.VIRTUAL_KEY.VK_ESCAPE);
        NoticeHost.Show("3 秒后开始录屏", "Esc 取消", NoticeTone.Normal);
        _timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.IsRepeating = true;
        _timer.Tick += OnTick;
        _timer.Start();
    }

    private static void OnTick(DispatcherQueueTimer sender, object args)
    {
        _remaining--;
        if (_remaining > 0)
        {
            NoticeHost.Show($"{_remaining} 秒后开始录屏", "Esc 取消", NoticeTone.Normal);
            return;
        }

        Finish();
        RecordingHost.StartRegion(_region);
    }

    public static void Cancel()
    {
        if (!Active)
        {
            return;
        }

        Finish();
        NoticeHost.Show("已取消录屏", string.Empty, NoticeTone.Normal);
    }

    private static void Finish()
    {
        Active = false;
        _timer?.Stop();
        _timer = null;
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, EscapeId);
        Log.Info("record.countdown-end");
    }
}
