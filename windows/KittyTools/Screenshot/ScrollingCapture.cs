// 长截图（第三版 §7）：选区收起后，每 600 ms 抓一帧选区交给 Core 的 ScrollStitcher 拼；
// 用户自己滚，Enter / 「完成」结束，Esc 放弃，高度到 30000 自动结束。
// 遮罩已经收起，所以选区里没有我们的边框（方案里的 WDA_EXCLUDEFROMCAPTURE 那一套就不需要了）；
// 进度用轻提示胶囊显示，Enter / Esc 用临时注册的全局热键（不带修饰键，只在长截图期间有效）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal static class ScrollingCapture
{
    public const int EnterId = 920;

    public const int EscapeId = 921;

    private static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(600);

    private static DispatcherQueueTimer? _timer;
    private static FrozenScreen? _screen;
    private static PixelBounds _rect;
    private static ScrollFrame? _current;
    private static int _frames;
    private static Action<ScrollFrame>? _onComplete;
    private static Action? _onCancel;

    public static bool Active { get; private set; }

    public static void Start(
        FrozenScreen screen, PixelBounds rect, Action<ScrollFrame> onComplete, Action onCancel)
    {
        if (Active || rect.Width < 8 || rect.Height < 8)
        {
            return;
        }

        _screen = screen;
        _rect = rect;
        _current = null;
        _frames = 0;
        _onComplete = onComplete;
        _onCancel = onCancel;
        Active = true;
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EnterId, 0, (uint)VIRTUAL_KEY.VK_RETURN);
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EscapeId, 0, (uint)VIRTUAL_KEY.VK_ESCAPE);
        CaptureFrame();
        _timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _timer.Interval = Interval;
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => CaptureFrame();
        _timer.Start();
        Log.Info($"scroll.begin {rect.Width}x{rect.Height}");
        NoticeHost.Show("长截图", "滚动选区，Enter 完成，Esc 放弃", NoticeTone.Normal);
    }

    public static void Complete()
    {
        if (!Active || _current is null)
        {
            Cancel();
            return;
        }

        var frame = _current;
        var callback = _onComplete;
        Stop();
        Log.Info($"scroll.done frames={_frames} height={frame.Height}");
        callback?.Invoke(frame);
    }

    public static void Cancel()
    {
        if (!Active)
        {
            return;
        }

        var callback = _onCancel;
        Stop();
        Log.Info($"scroll.cancelled frames={_frames}");
        callback?.Invoke();
    }

    private static void Stop()
    {
        Active = false;
        _timer?.Stop();
        _timer = null;
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, EnterId);
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, EscapeId);
        _screen = null;
        _current = null;
        _onComplete = null;
        _onCancel = null;
    }

    private static void CaptureFrame()
    {
        if (!Active || _screen is null || _timer is null && _frames > 0)
        {
            return;
        }

        try
        {
            // 重新抓整屏，再裁出选区（屏幕内容会变，冻结帧不能再用）。
            var screens = ScreenCapture.CaptureAll();
            var screen = screens.FirstOrDefault(item => item.Bounds.Contains(
                             _rect.Left, _rect.Top) &&
                         _rect.Right <= item.Bounds.Right && _rect.Bottom <= item.Bounds.Bottom);
            if (screen is null)
            {
                NoticeHost.Show("长截图", "选区不在屏幕上了", NoticeTone.Warning);
                Cancel();
                return;
            }

            var local = new PixelBounds(
                _rect.Left - screen.Bounds.Left, _rect.Top - screen.Bounds.Top,
                _rect.Right - screen.Bounds.Left, _rect.Bottom - screen.Bounds.Top);
            var bgra = screen.Crop(local);
            var pixels = new int[local.Width * local.Height];
            Buffer.BlockCopy(bgra, 0, pixels, 0, bgra.Length);
            var frame = new ScrollFrame(local.Width, local.Height, pixels);
            if (_current is null)
            {
                _current = frame;
            }
            else
            {
                var next = ScrollStitcher.Append(_current, frame, ScrollDirection.Down);
                if (next is not null)
                {
                    _current = next;
                }
            }

            _frames++;
            if (_current.Height >= ScrollStitcher.MaxOutputHeight)
            {
                Complete();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"scroll.frame-failed {ex.GetType().Name}");
        }
    }
}
