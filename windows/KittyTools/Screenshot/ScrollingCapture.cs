// 长截图（第三版 §7）：选区收起后，每 600 ms 抓一帧选区交给 Core 的 ScrollStitcher 拼；
// 用户自己滚，Enter / 「完成」结束，Esc 放弃，高度到 30000 自动结束。
// 遮罩收起后选区外一圈品牌粉实线（RecordingFrame.ShowScrolling，同 mac ScrollCapture 的边框；2026-10-29 用户反馈
// 以前开始滚后什么框都没有）：线在选区外、又不进截图，抓的帧里没有它；
// 选区旁边一块预览面板（ScrollPreviewPanel，PLAN-v9 S11）：拼好的长图跟着长、能往回看，下面是尺寸、状态和「放弃」「完成」；
// Enter / Esc 用临时注册的全局热键（不带修饰键，只在长截图期间有效）。
// REVIEW R43：每拍只 BitBlt 选区那一块（以前抓全部屏再裁），转像素、算行哈希、找重叠在线程池上做（一次只拼一拍，
// 上一拍没拼完这一拍就跳过），拼接按条带存（ScrollCanvas）；「完成」等正在拼的那一拍拼完再合成。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal static class ScrollingCapture
{
    public const int EnterId = 920;

    public const int EscapeId = 921;

    public const int ResumeId = 934;

    private static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(600);

    private static DispatcherQueueTimer? _timer;
    private static FrozenScreen? _screen;
    private static PixelBounds _rect;
    /// <summary>拼到一半的那张（条带，REVIEW R43）：每拍只拿找重叠要看的那几行比，完成时才合成一张。</summary>
    private static ScrollCanvas? _canvas;

    /// <summary>正在线程池上拼的那一拍（拼完回 UI 线程换上）；没有在拼时是 null。</summary>
    private static Task<ScrollCanvas>? _work;

    /// <summary>「完成」进行中：等着正在拼的那一拍，这时候不再抓新的、也不再进「完成」。</summary>
    private static bool _completing;
    private static int _frames;
    /// <summary>拼完：整张图、要不要接着标注（面板上点的「标注」）。</summary>
    private static Action<ScrollFrame, bool>? _onComplete;
    private static Action? _onCancel;
    private static ScrollDirection _direction = ScrollDirection.Down;
    private static bool _autoScroll;
    private static bool _paused;
    private static bool _hasRestore;
    private static int _restoreX;
    private static int _restoreY;
    private static bool _messageHooked;

    public static bool Active { get; private set; }

    /// <summary>没有正在拼的那一拍：这时 UI 线程可以从 _canvas 取预览（拼的时候条带在线程池上改）。</summary>
    public static bool Idle => _work is null;

    public static void Start(
        FrozenScreen screen, PixelBounds rect, ScrollDirection direction, bool autoScroll,
        Action<ScrollFrame, bool> onComplete, Action onCancel)
    {
        if (Active || rect.Width < 8 || rect.Height < 8)
        {
            return;
        }

        _screen = screen;
        _rect = rect;
        _canvas = null;
        _work = null;
        _completing = false;
        _frames = 0;
        _direction = direction;
        _autoScroll = autoScroll;
        _paused = false;
        _hasRestore = false;
        _onComplete = onComplete;
        _onCancel = onCancel;
        Active = true;
        if (autoScroll && !_messageHooked)
        {
            _messageHooked = true;
            HiddenWindow.Message += OnHiddenMessage;
        }
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EnterId, 0, (uint)VIRTUAL_KEY.VK_RETURN);
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EscapeId, 0, (uint)VIRTUAL_KEY.VK_ESCAPE);
        RecordingFrame.ShowScrolling(rect);
        CaptureFrame();
        _timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _timer.Interval = Interval;
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => CaptureFrame();
        _timer.Start();
        Log.Info($"scroll.begin {rect.Width}x{rect.Height} direction={direction} auto={autoScroll}");
        ScrollPreviewPanel.Show(
            rect, autoScroll ? "自动滚动中，Enter 完成，Esc 放弃" : "滚动选区，Enter 完成，Esc 放弃");
    }

    /// <summary>结束、合成整张；annotate = 面板上点了「标注」（拼完不拷贝，开长图标注窗口）。</summary>
    public static async void Complete(bool annotate = false)
    {
        if (!Active || _completing)
        {
            return;
        }

        _completing = true;
        var canvas = _canvas;
        if (_work is { } work)
        {
            try
            {
                canvas = await work;
            }
            catch (Exception ex)
            {
                Log.Warn($"scroll.frame-failed {ex.GetType().Name}");
            }
        }

        // 等的这一会儿按了 Esc：照放弃算。
        if (!Active)
        {
            return;
        }

        if (canvas is null)
        {
            Cancel();
            return;
        }

        var frame = canvas.Compose();
        var callback = _onComplete;
        Stop();
        Log.Info($"scroll.done frames={_frames} height={frame.Height}");
        callback?.Invoke(frame, annotate);
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
        RecordingFrame.HideScrolling();
        ScrollPreviewPanel.Hide();
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, EnterId);
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, EscapeId);
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, ResumeId);
        if (_messageHooked)
        {
            HiddenWindow.Message -= OnHiddenMessage;
            _messageHooked = false;
        }

        _paused = false;
        _hasRestore = false;
        _screen = null;
        _canvas = null;
        _work = null;
        _completing = false;
        _onComplete = null;
        _onCancel = null;
    }

    private static async void CaptureFrame()
    {
        if (!Active || _screen is null || _timer is null && _frames > 0 || _work is not null || _completing)
        {
            return;
        }

        try
        {
            // 只抓选区那一块（屏幕内容会变，冻结帧不能再用）；GDI 的屏幕 DC 用的就是全局的物理像素坐标。
            var rect = _rect;
            var bgra = ScreenCapture.CaptureRegion(rect);
            if (bgra is null)
            {
                NoticeHost.Show("长截图", "选区不在屏幕上了", NoticeTone.Warning);
                Cancel();
                return;
            }

            var canvas = _canvas;
            var before = canvas?.Height ?? 0;
            var direction = _direction;
            var work = Task.Run(() =>
            {
                var pixels = new int[rect.Width * rect.Height];
                Buffer.BlockCopy(bgra, 0, pixels, 0, Math.Min(bgra.Length, pixels.Length * 4));
                var frame = new ScrollFrame(rect.Width, rect.Height, pixels);
                if (canvas is null)
                {
                    return new ScrollCanvas(frame);
                }

                canvas.Append(frame, direction);
                return canvas;
            });
            _work = work;
            var result = await work;
            if (!ReferenceEquals(_work, work))
            {
                // 拼的时候长截图已经结束（放弃了、换了一轮）：这一拍不要了。
                return;
            }

            _work = null;
            if (!Active || _completing)
            {
                return;
            }

            _canvas = result;
            _frames++;
            ScrollPreviewPanel.Update(result, direction == ScrollDirection.Up, result.Height - before);
            if (_canvas.Height >= ScrollStitcher.MaxOutputHeight)
            {
                Complete();
                return;
            }

            if (_autoScroll)
            {
                SendWheel();
            }
        }
        catch (Exception ex)
        {
            _work = null;
            Log.Warn($"scroll.frame-failed {ex.GetType().Name}");
        }
    }

    /// <summary>自动滚动：把光标放到选区中间滚一格（滚完放回原处），不点击。</summary>
    private static unsafe void SendWheel()    {
        try
        {
            PInvoke.GetCursorPos(out var cursor);
            if (_hasRestore && (cursor.X != _restoreX || cursor.Y != _restoreY))
            {
                Pause();
                return;
            }

            SetCursorPos(_rect.Left + _rect.Width / 2, _rect.Top + _rect.Height / 2);
            var input = new INPUT { type = INPUT_TYPE.INPUT_MOUSE };
            input.Anonymous.mi = new MOUSEINPUT
            {
                dx = 0,
                dy = 0,
                mouseData = (uint)(_direction == ScrollDirection.Down ? -120 : 120),
                dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_WHEEL,
                time = 0,
                dwExtraInfo = 0,
            };
            PInvoke.SendInput(1, &input, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>());
            SetCursorPos(cursor.X, cursor.Y);
            _restoreX = cursor.X;
            _restoreY = cursor.Y;
            _hasRestore = true;
        }
        catch (Exception ex)
        {
            Log.Warn($"scroll.wheel-failed {ex.GetType().Name}");
        }
    }

    private static void OnHiddenMessage(uint message, WPARAM wParam, LPARAM lParam)
    {
        if (message == PInvoke.WM_HOTKEY && wParam.Value == ResumeId)
        {
            Resume();
        }
    }

    private static void Pause()
    {
        if (_paused || !Active)
        {
            return;
        }

        _paused = true;
        _autoScroll = false;
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, ResumeId, 0, (uint)VIRTUAL_KEY.VK_A);
        ScrollPreviewPanel.SetStatus("自动滚动暂停了（动了鼠标）：按 A 继续，Enter 完成", warning: true);
        Log.Info("scroll.paused");
    }

    private static void Resume()
    {
        if (!_paused || !Active)
        {
            return;
        }

        _paused = false;
        _autoScroll = true;
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, ResumeId);
        ScrollPreviewPanel.SetStatus("自动滚动中，Enter 完成，Esc 放弃");
        Log.Info("scroll.resumed");
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);
}
