// 长截图（第三版 §7）：选区收起后，一帧接一帧抓选区交给 Core 的 ScrollStitcher 拼——手动滚时画面在动就拼完立刻抓下一帧、静止 40 ms、
// 连着 5 帧静止 200 ms（PLAN-v18 S2，Core ScrollPacer.ManualDelayMs；原来固定 600 ms，滚快了两帧之间滚过一整屏就再也接不上），
// 对不上时状态行橙字「对不上了：往回滚一点，再慢慢滚」；画面在动时截下一帧和拼这一帧叠着做（PLAN-v20 W2，mac c7756c75：这一帧开拼就先截好
// 下一帧，拼完马上拿它接着拼），静止那一觉被选区里的滚轮叫醒（WheelWake：鼠标的 Raw Input，只在手动长截图期间注册）；
// 用户自己滚，Enter / 「完成」结束，Esc 放弃，高度到 30000 自动结束。
// 遮罩收起后选区外一圈品牌粉实线（RecordingFrame.ShowScrolling，同 mac ScrollCapture 的边框；2026-10-29 用户反馈
// 以前开始滚后什么框都没有）：线在选区外、又不进截图，抓的帧里没有它；
// 选区旁边一块预览面板（ScrollPreviewPanel，PLAN-v9 S11）：拼好的长图跟着长、能往回看，下面是尺寸、状态和「放弃」「完成」；
// Enter 用临时注册的全局热键（不带修饰键，只在长截图期间有效）；Esc 走只看不吞的低级钩子（EscapeKeyWatch，PLAN-v11 M13）。
// 自动滚动（A / Shift+A，照 mac 389289d4）：屏幕每刷新一帧（CompositionTarget.Rendering）按速度发一小段滚轮，匀速顺滑地滚；
// 速度在预览面板按钮行上面那一排「慢 / 标准 / 快」（每秒滚出 0.3 / 0.6 / 1.2 个选区高，记住上次，滚动中换档下一帧生效）。
// 抓帧 160 ms 一帧、边滚边截，每帧拼完按发出去的量和画面实际滚的像素对账校准（Core ScrollPacer）；对不上退回、放慢，
// 连着几帧不动 = 到头，停下、状态行说。滚轮交给光标下的窗口：开始 / 接着滚时光标不在选区里（或停在面板上）就挪到选区中间，
// 之后光标停在面板附近先不发，移出选区 = 暂停（按 A 接着滚）。
// 在动的那一块（PLAN-v20 W1，mac PR #20）：Core ScrollBand 累计真滚过的帧里变过的行 / 列，领先上限（ScrollPacer.Band）、对不上时的退让、
// 光标落点（AimAtBand：开始、接着滚、对不上时光标不在那一块上就挪进去）都按它算；还没量出来时按整个选区。
// REVIEW R43：每拍只 BitBlt 选区那一块（以前抓全部屏再裁），转像素、算行哈希、找重叠在线程池上做（一次只拼一拍，
// 上一拍没拼完这一拍就跳过），拼接按条带存（ScrollCanvas）；「完成」等正在拼的那一拍拼完再合成。
using System.Diagnostics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal static class ScrollingCapture
{
    public const int EnterId = 920;

    public const int ResumeId = 934;

    /// <summary>手动滚时的保底间隔（静止时的 40 / 200 ms 由 ManualDelayMs 定，拼完再排下一帧）。</summary>
    private static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(200);

    /// <summary>手动滚时连着几帧画面没动（定下一帧隔多久抓）；对不上的提示正挂着。</summary>
    private static int _quietFrames;
    private static bool _lostShown;

    /// <summary>自动滚动时抓帧的间隔（同 mac：边滚边截，每帧滚出一两成选区高）。</summary>
    private static readonly TimeSpan AutoInterval = TimeSpan.FromMilliseconds(160);

    private static DispatcherQueueTimer? _timer;
    private static FrozenScreen? _screen;
    private static PixelBounds _rect;
    /// <summary>拼到一半的那张（条带，REVIEW R43）：每拍只拿找重叠要看的那几行比，完成时才合成一张。</summary>
    private static ScrollCanvas? _canvas;

    /// <summary>正在线程池上拼的那一拍（拼完回 UI 线程换上）；没有在拼时是 null。</summary>
    private static Task<Tick>? _work;

    /// <summary>上一次拼上的那帧（行哈希判断这一拍是没动还是对不上，ScrollPacer.Classify；像素给 ScrollBand 比列）。</summary>
    private static ScrollFrame? _reference;

    /// <summary>在动的那一块（第一帧拼上时建）。只在拼的那一拍里改（线程池上，一次只拼一拍），UI 线程在拼完之后读。</summary>
    private static ScrollBand? _band;

    /// <summary>手动滚、画面在动时先截好的下一帧（拼这一帧的同时截）：拼完马上拿它接着拼；没有时是 null。</summary>
    private static byte[]? _prefetched;

    /// <summary>自动滚动的速度和校准；手动滚时是 null。</summary>
    private static ScrollPacer? _pacer;

    /// <summary>上一次屏幕刷新的时刻（Stopwatch 计数；0 = 刚挂上帧回调）。</summary>
    private static long _lastFrame;
    private static bool _framesHooked;

    /// <summary>这一轮来过几次屏幕刷新回调（日志里看帧回调是不是真的每帧都来）。</summary>
    private static int _renderFrames;

    /// <summary>「完成」进行中：等着正在拼的那一拍，这时候不再抓新的、也不再进「完成」。</summary>
    private static bool _completing;
    private static int _frames;
    /// <summary>拼完：整张图、要不要接着标注（面板上点的「标注」）。</summary>
    private static Action<ScrollFrame, bool>? _onComplete;
    private static Action? _onCancel;
    private static ScrollDirection _direction = ScrollDirection.Down;
    private static bool _autoScroll;
    private static bool _paused;
    private static bool _messageHooked;

    public static bool Active { get; private set; }

    /// <summary>自检（ScrollBandProbe）：不注册 Enter、不装 Esc 钩子（自检跑的那几秒不抢用户的键）。</summary>
    public static bool ProbeQuiet { get; set; }

    /// <summary>自检看：在动的那一块、手动滚时叠着截了几帧。</summary>
    public static ScrollBand? BandForProbe => _band;

    public static int PrefetchCountForProbe { get; private set; }

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

        NoteDeck.Suspend(NoteDeck.Suspension.UnlessPinned);
        _screen = screen;
        _rect = rect;
        _canvas = null;
        _work = null;
        _reference = null;
        _band = null;
        _prefetched = null;
        var speed = ScrollPacer.Parse(SettingsService.Current.ScrollCaptureSpeed);
        _pacer = autoScroll
            ? new ScrollPacer(rect.Height, Displays.AtPoint(rect.Left + rect.Width / 2, rect.Top + rect.Height / 2).Scale, speed)
            : null;
        _completing = false;
        _frames = 0;
        _quietFrames = 0;
        _lostShown = false;
        _renderFrames = 0;
        _escapeArmedAt = 0;
        _direction = direction;
        _autoScroll = autoScroll;
        _paused = false;
        _onComplete = onComplete;
        _onCancel = onCancel;
        Active = true;
        if (autoScroll && !_messageHooked)
        {
            _messageHooked = true;
            HiddenWindow.Message += OnHiddenMessage;
        }
        if (!ProbeQuiet)
        {
            PInvoke.RegisterHotKey(HiddenWindow.Hwnd, EnterId, 0, (uint)VIRTUAL_KEY.VK_RETURN);
            EscapeKeyWatch.Start(RequestCancel);
        }

        PrefetchCountForProbe = 0;
        if (!autoScroll)
        {
            WheelWake.Start(OnWheel);
        }
        RecordingFrame.ShowScrolling(rect);
        CaptureFrame();
        _timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _timer.Interval = autoScroll ? AutoInterval : Interval;
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => CaptureFrame();
        _timer.Start();
        Log.Info($"scroll.begin {rect.Width}x{rect.Height} direction={direction} auto={autoScroll} speed={ScrollPacer.Name(speed)}");
        ScrollPreviewPanel.Show(
            rect, autoScroll ? "自动滚动中，Enter 完成，Esc 放弃" : "滚动选区，Enter 完成，Esc 放弃",
            autoScroll ? speed : null);
        if (autoScroll)
        {
            BeginAutoScroll();
        }
    }

    /// <summary>面板上换了速度（慢 / 标准 / 快）：下一帧就按新的速度发，记下来下次照用。</summary>
    public static void SetSpeed(ScrollSpeed speed)
    {
        _pacer?.SetSpeed(speed);
        var name = ScrollPacer.Name(speed);
        if (SettingsService.Current.ScrollCaptureSpeed != name)
        {
            SettingsService.Current.ScrollCaptureSpeed = name;
            SettingsService.Save();
        }

        Log.Info($"scroll.speed {name}");
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
                canvas = (await work).Canvas;
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
        Log.Info($"scroll.done frames={_frames} render-frames={_renderFrames} height={frame.Height}");
        callback?.Invoke(frame, annotate);
    }

    /// <summary>上一次「只上膛」的 Esc 是什么时候（Environment.TickCount64）；3 秒内再按才放弃。</summary>
    private static long _escapeArmedAt;

    /// <summary>
    /// 按了 Esc：拼得比第一帧长时第一下只上膛，提示「再按一次 Esc 放弃这张长图」（第四轮体检 U3：滚了一两分钟按一下就全丢）；
    /// 还没拼出东西、或者 3 秒内又按了一次，才放弃。面板上的「放弃」按钮是明着点的，照旧直接放弃。
    /// </summary>
    public static void RequestCancel()
    {
        if (!Active)
        {
            return;
        }

        var now = Environment.TickCount64;
        if (_canvas is { } canvas && canvas.Height > _rect.Height && now - _escapeArmedAt > 3000)
        {
            _escapeArmedAt = now;
            NoticeHost.Show("再按一次 Esc 放弃这张长图", $"已经拼了 {canvas.Height} 像素高，Enter 完成", NoticeTone.Warning);
            return;
        }

        Cancel();
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
        EscapeKeyWatch.Stop();
        WheelWake.Stop();
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, ResumeId);
        if (_messageHooked)
        {
            HiddenWindow.Message -= OnHiddenMessage;
            _messageHooked = false;
        }

        _paused = false;
        UnhookFrames();
        _screen = null;
        _canvas = null;
        _work = null;
        _reference = null;
        _band = null;
        _prefetched = null;
        _pacer = null;
        _completing = false;
        _onComplete = null;
        _onCancel = null;
    }

    private static async void CaptureFrame()
    {
        if (!Active || _screen is null || _timer is null && _frames > 0 || _completing)
        {
            return;
        }

        if (_work is not null)
        {
            // 正在拼上一帧：手动滚、画面在动时先把下一帧截好（叠着做），拼完马上接着拼；别的时候这一拍跳过。
            Prefetch();
            return;
        }

        try
        {
            // 只抓选区那一块（屏幕内容会变，冻结帧不能再用）；GDI 的屏幕 DC 用的就是全局的物理像素坐标。
            // 开抓前记下一共发了多少滚轮，拼完拿它和画面实际滚的对账（先截好的那一帧只有手动滚时才有，那时不对账）。
            var rect = _rect;
            var bgra = _prefetched;
            _prefetched = null;
            if (bgra is null)
            {
                _pacer?.Captured();
                bgra = ScreenCapture.CaptureRegion(rect);
            }

            if (bgra is null)
            {
                NoticeHost.Show("长截图", "选区不在屏幕上了", NoticeTone.Warning);
                Cancel();
                return;
            }

            var canvas = _canvas;
            var reference = _reference;
            var band = _band;
            var direction = _direction;
            var work = Task.Run(() =>
            {
                var pixels = new int[rect.Width * rect.Height];
                Buffer.BlockCopy(bgra, 0, pixels, 0, Math.Min(bgra.Length, pixels.Length * 4));
                var frame = new ScrollFrame(rect.Width, rect.Height, pixels);
                if (canvas is null || reference is null)
                {
                    return new Tick(new ScrollCanvas(frame), frame, new ScrollBand(rect.Width, rect.Height), ScrollStep.Moved, frame.Height);
                }

                // 和上次拼上的一样：不拿去拼（整片纯色时随便哪个重叠都对得上，会凭空长出空白）。
                if (ScrollPacer.Same(reference.Hashes, frame.Hashes))
                {
                    return new Tick(canvas, reference, band, ScrollStep.Unchanged, 0);
                }

                var before = canvas.Height;
                var appended = canvas.Append(frame, direction);
                var grown = canvas.Height - before;
                var step = ScrollPacer.Classify(reference.Hashes, frame.Hashes, appended, grown);
                if (step == ScrollStep.Moved)
                {
                    // 真滚过了：变过的行 / 列记进「在动的那一块」（换参照帧之前比；没滚时原地变的不算）。
                    band?.NoteMoved(reference, frame);
                }

                return new Tick(canvas, appended ? frame : reference, band, step, grown);
            });
            _work = work;
            if (!_autoScroll && _quietFrames == 0 && _frames > 0)
            {
                // 画面在动：拼这一帧的同时截下一帧。
                DispatcherQueue.GetForCurrentThread()?.TryEnqueue(DispatcherQueuePriority.Low, Prefetch);
            }

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

            _canvas = result.Canvas;
            _reference = result.Reference;
            _band = result.Band;
            _frames++;
            if (_pacer is { } tracked && _band is { } measured)
            {
                tracked.Band = measured.MovingRows.Count;
            }

            ScrollPreviewPanel.Update(result.Canvas, direction == ScrollDirection.Up, result.Grown);
            if (_canvas.Height >= ScrollStitcher.MaxOutputHeight)
            {
                Complete();
                return;
            }

            if (!_autoScroll)
            {
                ScheduleManual(result.Step);
                return;
            }

            // 光标在面板附近（去点暂停、看预览）时这一帧不对账（同 mac）：那时不发滚轮，画面不动不能算到头。
            PInvoke.GetCursorPos(out var cursor);
            if (_autoScroll && _pacer is { } pacer && !ScrollPreviewPanel.Contains(cursor.X, cursor.Y, 16))
            {
                var back = pacer.After(result.Step, result.Grown);
                if (result.Step == ScrollStep.Lost && pacer.Stopped == ScrollStopReason.None)
                {
                    // 也许是滚轮根本没落在在动的那一块上（光标停在选区里的外层页面上）：先把它挪进去。
                    AimAtBand();
                }

                if (back > 0)
                {
                    SendWheel(-back);
                }

                if (pacer.Stopped != ScrollStopReason.None)
                {
                    StopAutoScroll(pacer.Stopped);
                }
            }
        }
        catch (Exception ex)
        {
            _work = null;
            Log.Warn($"scroll.frame-failed {ex.GetType().Name}");
        }
    }

    /// <summary>
    /// 手动滚：这一帧拼完排下一帧（ScrollPacer.ManualDelayMs）——在动就马上接着拼（拼的时候已经截好了下一帧），静止 40 / 200 ms
    /// （那一觉被选区里的滚轮叫醒，OnWheel）；对不上时状态行说一声，接上了换回来。
    /// </summary>
    private static void ScheduleManual(ScrollStep step)
    {
        _quietFrames = step == ScrollStep.Unchanged ? _quietFrames + 1 : 0;
        if (step == ScrollStep.Lost && !_lostShown)
        {
            _lostShown = true;
            ScrollPreviewPanel.SetStatus(ScrollPacer.LostText, warning: true);
        }
        else if (step == ScrollStep.Moved && _lostShown)
        {
            _lostShown = false;
            ScrollPreviewPanel.SetStatus("滚动选区，Enter 完成，Esc 放弃");
        }

        if (_timer is not { } timer || _paused)
        {
            return;
        }

        var delay = _prefetched is not null ? 0 : ScrollPacer.ManualDelayMs(_quietFrames);
        timer.Stop();
        timer.Interval = delay > 0 ? TimeSpan.FromMilliseconds(delay) : Interval;
        timer.Start();
        if (delay == 0)
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(DispatcherQueuePriority.Low, CaptureFrame);
        }
    }

    /// <summary>手动滚、画面在动、正在拼上一帧时：先把下一帧截好（一次只存一帧）。</summary>
    private static void Prefetch()
    {
        if (!Active || _autoScroll || _completing || _work is null || _prefetched is not null || _quietFrames != 0)
        {
            return;
        }

        _prefetched = ScreenCapture.CaptureRegion(_rect);
        PrefetchCountForProbe++;
    }

    /// <summary>
    /// 选区里转了滚轮（WheelWake，只在手动长截图期间收）：静止时睡着的那一觉提前结束——停了一会儿再一甩，第一帧不用等满 200 ms。
    /// 滚轮事件比画面先到，马上截多半还没动，所以只把节奏拨回「刚静止」（40 ms 那档）、15 ms 后截。落在面板上是往回看预览，不管。
    /// </summary>
    private static void OnWheel(int x, int y)
    {
        if (!Active || _autoScroll || _completing || _quietFrames == 0 || !Inside(_rect, x, y) || _timer is not { } timer)
        {
            return;
        }

        _quietFrames = 1;
        if (_work is null)
        {
            timer.Stop();
            timer.Interval = TimeSpan.FromMilliseconds(15);
            timer.Start();
        }
    }

    /// <summary>
    /// 把光标放进在动的那一块（同 mac aimAtBand）：滚轮交给光标下的窗口，光标停在选区里别的地方（外层页面）就滚错了对象，画面不动、
    /// 怎么滚都对不上。光标已经在那一块上就不动；停在自家面板上（或选区外）照样挪进去。还没量出来时那一块就是整个选区。
    /// </summary>
    private static void AimAtBand()
    {
        var rows = _band?.MovingRows ?? default;
        var columns = _band?.MovingColumns ?? default;
        var (left, top, width, height) = ScrollBand.BandRect(_rect.Left, _rect.Top, _rect.Width, _rect.Height, rows, columns);
        PInvoke.GetCursorPos(out var cursor);
        var inside = cursor.X >= left && cursor.X < left + width && cursor.Y >= top && cursor.Y < top + height;
        if (inside && !ScrollPreviewPanel.Contains(cursor.X, cursor.Y, 0))
        {
            return;
        }

        SetCursorPos(left + width / 2, top + height / 2);
    }

    /// <summary>
    /// 开始 / 接着自动滚动：光标不在在动的那一块上（没量出来时是整个选区）、或停在面板上就挪进去（滚轮交给光标下的窗口），挂上帧回调。
    /// 自动滚动时不听滚轮叫醒（自己发的滚轮也收得到）。
    /// </summary>
    private static void BeginAutoScroll()
    {
        if (_pacer is not { } pacer)
        {
            return;
        }

        WheelWake.Stop();
        _prefetched = null;
        if (_band is { } band)
        {
            // 要它的左右边界才能把滚轮落进在动的那一块（手动滚的落点由用户的光标定，不算列）。
            band.TracksColumns = true;
        }

        AimAtBand();
        pacer.Begin();
        _autoScroll = true;
        if (_timer is { } timer)
        {
            timer.Interval = AutoInterval;
        }

        if (!_framesHooked)
        {
            _framesHooked = true;
            _lastFrame = 0;
            CompositionTarget.Rendering += OnRendering;
        }
    }

    /// <summary>停掉帧回调、抓帧回到慢的间隔（手动滚、暂停、叫停之后）。</summary>
    private static void UnhookFrames()
    {
        if (_framesHooked)
        {
            _framesHooked = false;
            CompositionTarget.Rendering -= OnRendering;
        }

        if (_timer is { } timer)
        {
            timer.Interval = Interval;
        }
    }

    /// <summary>
    /// 屏幕每刷新一帧（自动滚动时）：按速度发这一帧的那一小段。光标在面板附近（去点按钮、看预览）先不发（滚轮会落到面板上），
    /// 移出选区 = 暂停（也免得滚到别的窗口）。
    /// </summary>
    private static void OnRendering(object? sender, object args)
    {
        var now = Stopwatch.GetTimestamp();
        var seconds = _lastFrame == 0 ? 1 / 60.0 : (double)(now - _lastFrame) / Stopwatch.Frequency;
        _lastFrame = now;
        _renderFrames++;
        if (!Active || !_autoScroll || _pacer is not { } pacer || _completing)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        if (ScrollPreviewPanel.Contains(cursor.X, cursor.Y, 16))
        {
            return;
        }

        if (!Inside(_rect, cursor.X, cursor.Y))
        {
            Pause();
            return;
        }

        var units = pacer.Frame(seconds);
        if (units != 0)
        {
            SendWheel(units);
        }
    }

    private static bool Inside(PixelBounds rect, int x, int y)
        => x >= rect.Left && x < rect.Right && y >= rect.Top && y < rect.Bottom;

    /// <summary>
    /// 往滚动方向发 units 个滚轮单位（120 = 一格；负数往回退），交给光标下的窗口。不到一格的量支持高精度滚轮的程序按比例滚，
    /// 老程序攒满一格才滚（ScrollPacer 算「到头」时会等发满一格）。
    /// </summary>
    private static unsafe void SendWheel(int units)
    {
        try
        {
            var input = new INPUT { type = INPUT_TYPE.INPUT_MOUSE };
            input.Anonymous.mi = new MOUSEINPUT
            {
                dx = 0,
                dy = 0,
                // 滚轮往下（内容往上走）是负数。
                mouseData = unchecked((uint)(_direction == ScrollDirection.Down ? -units : units)),
                dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_WHEEL,
                time = 0,
                dwExtraInfo = 0,
            };
            PInvoke.SendInput(1, &input, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>());
        }
        catch (Exception ex)
        {
            Log.Warn($"scroll.wheel-failed {ex.GetType().Name}");
        }
    }

    /// <summary>ScrollPacer 叫停：滚到头了、或者连着几帧对不上。手动滚、Enter 完成照常。</summary>
    private static void StopAutoScroll(ScrollStopReason reason)
    {
        _autoScroll = false;
        UnhookFrames();
        StopTrackingColumns();
        var end = _direction == ScrollDirection.Down ? "已经滚到底了" : "已经滚到顶了";
        ScrollPreviewPanel.SetStatus(
            reason == ScrollStopReason.Lost
                ? "对不上，已停止自动滚动：可以自己慢慢滚，Enter 完成"
                : $"{end}，Enter 完成，Esc 放弃",
            warning: reason == ScrollStopReason.Lost);
        Log.Info($"scroll.auto-stopped reason={reason} frames={_frames} render-frames={_renderFrames} gain={_pacer?.Gain:F2}");
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
        UnhookFrames();
        StopTrackingColumns();
        PInvoke.RegisterHotKey(HiddenWindow.Hwnd, ResumeId, 0, (uint)VIRTUAL_KEY.VK_A);
        ScrollPreviewPanel.SetStatus("自动滚动暂停了（光标移出了选区）：按 A 继续，Enter 完成", warning: true);
        Log.Info("scroll.paused");
    }

    private static void Resume()
    {
        if (!_paused || !Active)
        {
            return;
        }

        _paused = false;
        // 停着的时候用户可能自己滚过：Begin 把参照清成现在、计数清零。
        BeginAutoScroll();
        PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, ResumeId);
        ScrollPreviewPanel.SetStatus("自动滚动中，Enter 完成，Esc 放弃");
        Log.Info("scroll.resumed");
    }

    /// <summary>自动滚动停了 / 暂停：不再算列（拼的那一拍在线程池上读它，下一拍起生效）；之后就是手动滚，听滚轮叫醒。</summary>
    private static void StopTrackingColumns()
    {
        if (_band is { } band)
        {
            band.TracksColumns = false;
        }

        if (Active && !_completing)
        {
            WheelWake.Start(OnWheel);
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    /// <summary>拼完的一拍：画布、上一次拼上的那帧（这次拼上了就是这一帧）、在动的那一块、算哪种、长了几行。</summary>
    private readonly record struct Tick(ScrollCanvas Canvas, ScrollFrame Reference, ScrollBand? Band, ScrollStep Step, int Grown);
}
