// 录屏倒数（第四版）：选区确认后按 设置 › 录制「开始前倒数」（0 / 3 / 5 秒，默认 3，PLAN-v9 R2）开始；
// 倒数就在录制条上（R6，同 mac：[3 秒后开始] ｜ [✕ 取消]，点数字马上开始），期间 Esc 也能取消；不倒数时直接开录。
// Esc 是临时注册的全局热键（只挂这三秒），倒数结束 / 取消立刻注销。选区边框（RecordingFrame）从倒数开始就出。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;

namespace KittyTools;

internal static class RecordingCountdown
{
    public const int EscapeId = 930;

    private static DispatcherQueueTimer? _timer;
    private static PixelBounds _region;
    private static IntPtr _window;
    private static int _remaining;

    public static bool Active { get; private set; }

    public static void Start(PixelBounds region, IntPtr window = default)
    {
        if (Active)
        {
            return;
        }

        _region = region;
        _window = window;
        _remaining = SettingsService.Current.RecordCountdown is var seconds and (0 or 5) ? seconds : 3;
        // 倒数时就把选区框出来（mac 倒数时边框已经在了），录屏开始后接着用这一份。
        RecordingFrame.Show(region, window);
        if (_remaining == 0)
        {
            Begin();
            return;
        }

        Active = true;
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EscapeId, 0, (uint)Windows.Win32.UI.Input.KeyboardAndMouse.VIRTUAL_KEY.VK_ESCAPE);
        RecordingHud.ShowCountdown(region, _remaining);
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
            RecordingHud.Countdown(_remaining);
            return;
        }

        Finish();
        Begin();
    }

    /// <summary>录制条上点倒数的数字：不等了，马上开始。</summary>
    public static void StartNow()
    {
        if (!Active)
        {
            return;
        }

        Finish();
        Begin();
    }

    private static void Begin()
    {
        if (_window != IntPtr.Zero)
        {
            RecordingHost.StartWindow(_window);
        }
        else
        {
            RecordingHost.StartRegion(_region);
        }
    }

    public static void Cancel()
    {
        if (!Active)
        {
            return;
        }

        Finish();
        RecordingFrame.Hide();
        RecordingHud.Hide();
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
