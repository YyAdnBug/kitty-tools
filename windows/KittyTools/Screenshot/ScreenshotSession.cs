// 一次截图会话：冻结帧 → 每块屏一个遮罩 → 框选 / 吸附 / 放大镜 / 快捷键出图。
// 截图模式出图后停下（标注工具栏在下一轮补）；识字 / 截图翻译模式松手就确认。
// 会话期间暂停全部全局热键，结束再注册回来。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;

namespace KittyTools;

internal enum ScreenshotMode
{
    Capture,
    Ocr,
    Translate,
    Record,
}

internal sealed class ScreenshotSession
{
    private static ScreenshotSession? _current;

    private readonly List<SelectionOverlayWindow> _overlays = new();
    private bool _finished;

    /// <summary>从截图历史打开的那一条（PLAN-v8 第 3 批）和图摆在哪：选区没动过就回写它，不另记一条。</summary>
    private string? _editingId;
    private RectD _editingRect;

    public ScreenshotSession(ScreenshotMode mode, List<FrozenScreen> screens, List<SnapWindow> windows)
    {
        Mode = mode;
        Screens = screens;
        Windows = windows;
    }

    public static bool IsActive => _current is not null;

    /// <summary>结束当前会话（含内存探针这种没有遮罩交互的调用方）。</summary>
    public static void FinishCurrent() => _current?.Finish();

    public static void AuditAccessibility()
    {
        if (_current is not null)
        {
            foreach (var overlay in _current._overlays)
            {
                overlay.AuditAccessibility();
            }
        }
    }

    public ScreenshotMode Mode { get; }

    public List<FrozenScreen> Screens { get; }

    public List<SnapWindow> Windows { get; }

    public FrozenScreen? SelectionScreen { get; private set; }

    public RectD Selection { get; private set; }

    public bool HasSelection => SelectionScreen is not null && Selection.Width >= 1 && Selection.Height >= 1;

    public static void Start(ScreenshotMode mode)
    {
        if (_current is not null || TranslateHost.IsSelectionBusy)
        {
            // 划词还在取词：不要叠一次截图（两边都要拿剪贴板 / 前台）。
            return;
        }

        ShellRuntime.Instance?.HotKeys.UnregisterAll();
        OverlayHost.Hide(restoreForeground: false);
        TranslateHost.Hide(restoreForeground: false);
        List<FrozenScreen> screens;
        try
        {
            screens = ScreenCapture.CaptureAll();
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.capture-failed", ex);
            ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
            return;
        }
        if (screens.Count == 0)
        {
            NoticeHost.Show("没能截图", "抓不到屏幕内容", NoticeTone.Error);
            ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
            return;
        }

        var windows = WindowList.Capture();
        var session = new ScreenshotSession(mode, screens, windows);
        _current = session;
        Log.Info($"screenshot.begin mode={mode} screens={screens.Count}");
        session.ShowOverlays();
    }

    /// <summary>
    /// 截图历史「改标注」（PLAN-v8 第 3 批）：原图 1:1 摆在鼠标所在屏的正中当冻结帧（四周深灰），选区就是这张图，
    /// 当初的标注照原样摆上，用截图遮罩那一套工具接着改；拷贝 / 存储 / 钉图时回写同一条。
    /// ponytail: 比屏幕还大的（长截图）先不支持，要可滚动的长图画布（PLAN-v8 第 3 批下半）。
    /// </summary>
    internal static async void StartEditing(ShotItem item)
    {
        if (_current is not null || TranslateHost.IsSelectionBusy)
        {
            return;
        }

        if (ShotHistory.ReadImage(item.Id) is not { } png || await ImageCodec.PngToBgraAsync(png) is not { } image)
        {
            NoticeHost.Show("原图不在了", "这一条只剩记录", NoticeTone.Warning);
            return;
        }

        if (ScreenCapture.CanvasAtCursor(image.Bgra, image.Width, image.Height, out var placed) is not { } screen)
        {
            NoticeHost.Show("这张比屏幕还大", "长图的标注还没做，可以先拷贝或钉出来看", NoticeTone.Normal);
            return;
        }

        ShellRuntime.Instance?.HotKeys.UnregisterAll();
        OverlayHost.Hide(restoreForeground: false);
        TranslateHost.Hide(restoreForeground: false);
        var session = new ScreenshotSession(ScreenshotMode.Capture, new List<FrozenScreen> { screen }, new List<SnapWindow>())
        {
            _editingId = item.Id,
            _editingRect = placed,
        };
        _current = session;
        session.ShowOverlays();
        session.SetSelection(screen, placed);
        var annotations = item.Annotations
            .Select(data => ShotAnnotations.FromData(data, placed.X, placed.Y))
            .OfType<Annotation>()
            .ToList();
        session._overlays.FirstOrDefault()?.LoadAnnotations(annotations);
        Log.Info($"screenshot.edit-history annotations={annotations.Count}");
    }

    /// <summary>
    /// R33 截图自检：用合成的冻结帧开一次遮罩（不抓桌面、不列窗口），在主屏中间选好一块，工具栏就出来了。
    /// 返回那扇遮罩；用完调 FinishCurrent。
    /// </summary>
    internal static SelectionOverlayWindow? StartSynthetic()
    {
        if (_current is not null)
        {
            return null;
        }

        ShellRuntime.Instance?.HotKeys.UnregisterAll();
        var screen = ScreenCapture.Synthetic();
        var session = new ScreenshotSession(ScreenshotMode.Capture, new List<FrozenScreen> { screen }, new List<SnapWindow>());
        _current = session;
        session.ShowOverlays();
        session.SetSelection(screen, new RectD(screen.Width * 0.3, screen.Height * 0.25, screen.Width * 0.4, screen.Height * 0.35));
        return session._overlays.FirstOrDefault();
    }

    private void ShowOverlays()
    {
        try
        {
            foreach (var screen in Screens)
            {
                var overlay = new SelectionOverlayWindow(screen, this);
                _overlays.Add(overlay);
            }

            PInvoke.GetCursorPos(out var cursor);
            var key = _overlays.FirstOrDefault(overlay => overlay.ScreenBounds.Contains(cursor.X, cursor.Y))
                      ?? _overlays[0];
            foreach (var overlay in _overlays)
            {
                overlay.ShowOverlay(overlay == key);
            }
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.overlay-failed", ex);
            Finish();
        }
    }

    public void SetSelection(FrozenScreen screen, RectD rect)
    {
        SelectionScreen = screen;
        Selection = rect;
        InvalidateAll();
    }

    public void ClearSelection()
    {
        SelectionScreen = null;
        Selection = default;
        InvalidateAll();
    }

    public void InvalidateAll()
    {
        foreach (var overlay in _overlays)
        {
            overlay.Invalidate();
        }
    }

    /// <summary>截图翻译 / 识字：松手立即确认。</summary>
    /// <summary>录屏模式：选区确认后收起遮罩，倒数 3 秒开始录这块区域（第四版）。</summary>
    public void BeginRecordingSelection()
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        var global = GlobalRect(screen, Selection);
        var window = Windows.FirstOrDefault(item =>
            Math.Abs(item.Bounds.Left - global.Left) <= 2 &&
            Math.Abs(item.Bounds.Top - global.Top) <= 2 &&
            Math.Abs(item.Bounds.Right - global.Right) <= 2 &&
            Math.Abs(item.Bounds.Bottom - global.Bottom) <= 2);
        Finish();
        RecordingCountdown.Start(global, window.Hwnd);
    }

    public async void ConfirmQuick()
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        var rect = Selection;
        if (Mode == ScreenshotMode.Ocr)
        {
            await CopyRecognizedTextAsync(screen, rect);
        }
        else
        {
            await TranslateSelectionAsync(screen, rect);
        }
    }

    public async Task CopySelectionAsync()
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        var selection = Selection;
        var png = await SelectionPngAsync();
        var copied = false;
        if (png is not null)
        {
            copied = await ScreenshotOutput.CopyPngAsync(png, screen, selection);
        }

        if (copied && png is not null)
        {
            RecordHistory(screen, selection, png);
        }

        var origin = GlobalRect(screen, selection);
        if (_editingId is null)
        {
            // 从历史里打开改的那张不算「上次截的区域」。
            SaveLast(origin);
        }
        Finish();
        // 飞入 + 角落缩略图（PLAN-v2 §3.8 / D5）。
        if (copied && png is not null)
        {
            ScreenshotCard.Show(png, origin);
        }
    }

    public async Task SaveSelectionAsync(bool saveAs)
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        var selection = Selection;
        var png = await SelectionPngAsync();
        if (png is null)
        {
            Finish();
            return;
        }

        string? saved = null;
        string? savedAs = null;
        if (saveAs && _overlays.FirstOrDefault() is { } overlay)
        {
            savedAs = await ScreenshotOutput.SavePngAsAsync(overlay.AppWindow, png);
        }
        else
        {
            saved = await ScreenshotOutput.QuickSavePngAsync(png);
        }

        if ((saved ?? savedAs) is { } path)
        {
            RecordHistory(screen, selection, png, path);
        }

        var origin = GlobalRect(screen, selection);
        if (_editingId is null)
        {
            // 从历史里打开改的那张不算「上次截的区域」。
            SaveLast(origin);
        }
        Finish();
        if (saved is not null)
        {
            ScreenshotCard.Show(png, origin, saved);
        }
    }

    /// <summary>截取上次区域（第三版 §7）：不再弹遮罩，直接裁出来复制 + 飞入。</summary>
    public static async void StartLast()
    {
        if (_current is not null)
        {
            return;
        }

        var settings = SettingsService.Current;
        var width = settings.ScreenshotLastWidth;
        var height = settings.ScreenshotLastHeight;
        if (width < 8 || height < 8)
        {
            NoticeHost.Show("还没有上次区域", "先截一次图，再按这个热键", NoticeTone.Normal);
            Start(ScreenshotMode.Capture);
            return;
        }

        var global = new PixelBounds(
            settings.ScreenshotLastX, settings.ScreenshotLastY,
            settings.ScreenshotLastX + width, settings.ScreenshotLastY + height);
        List<FrozenScreen> screens;
        try
        {
            screens = ScreenCapture.CaptureAll();
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.last-failed", ex);
            return;
        }

        var screen = screens.FirstOrDefault(item =>
            global.Left >= item.Bounds.Left && global.Top >= item.Bounds.Top &&
            global.Right <= item.Bounds.Right && global.Bottom <= item.Bounds.Bottom);
        if (screen is null)
        {
            NoticeHost.Show("上次的区域不在屏幕上了", "改成普通截图", NoticeTone.Warning);
            Start(ScreenshotMode.Capture);
            return;
        }

        var local = new RectD(
            global.Left - screen.Bounds.Left, global.Top - screen.Bounds.Top,
            global.Width, global.Height);
        // REVIEW R54：Crop 吃的是这块屏里的像素坐标，不是全局的，也不能从 (0, 0) 起。
        var pixels = new PixelBounds(
            (int)local.X, (int)local.Y, (int)local.X + global.Width, (int)local.Y + global.Height);
        try
        {
            var bgra = screen.Crop(pixels);
            var png = await ImageCodec.BgraToPngAsync(global.Width, global.Height, bgra);
            if (png is not null && await ScreenshotOutput.CopyPngAsync(png, screen, local))
            {
                _ = ShotHistory.RecordAsync(png, global.Width, global.Height, screen.Scale, ShotKind.Shot, frame: global);
                ScreenshotCard.Show(png, global);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.last-copy-failed {ex.GetType().Name}");
        }
        finally
        {
            foreach (var item in screens)
            {
                item.ReleasePixels();
            }
        }
    }

    /// <summary>选区收起，开始长截图（S 键或工具栏）：自己滚，Enter 完成、Esc 放弃。</summary>
    public void BeginScrolling(bool up = false, bool autoScroll = false)
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        var global = GlobalRect(screen, Selection);
        foreach (var overlay in _overlays)
        {
            overlay.Close();
        }

        _overlays.Clear();
        ScrollingCapture.Start(
            screen,
            global,
            up ? ScrollDirection.Up : ScrollDirection.Down,
            autoScroll,
            frame => _ = CompleteScrollingAsync(frame, global),
            () =>
            {
                NoticeHost.Show("已取消长截图", string.Empty, NoticeTone.Normal);
                Finish();
            });
    }

    private async Task CompleteScrollingAsync(ScrollFrame frame, PixelBounds global)
    {
        var bgra = new byte[frame.Width * frame.Height * 4];
        for (var index = 0; index < frame.Pixels.Length; index++)
        {
            var value = frame.Pixels[index];
            bgra[index * 4] = (byte)(value & 0xFF);
            bgra[index * 4 + 1] = (byte)((value >> 8) & 0xFF);
            bgra[index * 4 + 2] = (byte)((value >> 16) & 0xFF);
            bgra[index * 4 + 3] = (byte)((value >> 24) & 0xFF);
        }

        var png = await ImageCodec.BgraToPngAsync(frame.Width, frame.Height, bgra);
        var screen = SelectionScreen;
        var selection = Selection;
        var copied = false;
        if (png is not null && screen is not null)
        {
            copied = await ScreenshotOutput.CopyPngAsync(png, screen, selection);
        }

        Finish();
        if (copied && png is not null)
        {
            _ = ShotHistory.RecordAsync(png, frame.Width, frame.Height, screen?.Scale ?? 1, ShotKind.Scroll);
            ScreenshotCard.Show(png, global);
        }
    }

    /// <summary>
    /// 截图历史（PLAN-v8）：在 Finish 放掉冻结帧之前，取出没画标注的原图和标注坐标，后台写盘入库、不用等。
    /// 没有标注时成品就是原图，直接拿 <paramref name="composed"/> 存，不再编一遍。
    /// </summary>
    internal void RecordHistory(FrozenScreen screen, RectD selection, byte[] composed, string? savedPath = null, bool pinned = false)
    {
        // 「保留截图历史」关着时不记新的；从历史里打开改的那一条照样回写。
        if (!ShotHistory.IsOn && _editingId is null)
        {
            return;
        }

        var overlay = _overlays.FirstOrDefault(item => item.Screen == screen);
        var annotations = overlay?.AnnotationsForHistory() ?? new List<ShotAnnotationData>();
        if (_editingId is { } editing && selection == _editingRect && ShotHistory.Instance is { } history)
        {
            // 从历史里打开、选区没动：回写同一条（原图不动，标注和成品换新的）。框了别的范围就当新截的一张。
            history.UpdateAnnotations(editing, annotations, composed);
            if (savedPath is not null)
            {
                history.MarkSaved(editing, savedPath);
            }

            if (pinned)
            {
                history.MarkPinned(editing);
            }

            return;
        }

        if (!ShotHistory.IsOn)
        {
            return;
        }

        var rect = ScreenshotOutput.SelectionPixels(screen, selection);
        var original = annotations.Count == 0 ? null : screen.Crop(rect);
        var frame = GlobalRect(screen, selection);
        var scale = screen.Scale;
        _ = RecordAsync();

        async Task RecordAsync()
        {
            var png = original is null ? composed : await ImageCodec.BgraToPngAsync(rect.Width, rect.Height, original);
            if (png is not null)
            {
                await ShotHistory.RecordAsync(
                    png, rect.Width, rect.Height, scale, ShotKind.Shot, annotations,
                    original is null ? null : composed, savedPath, pinned, frame);
            }
        }
    }

    /// <summary>记住这次截图的区域（物理像素，进 settings 但不进导出文件）。</summary>
    private static void SaveLast(PixelBounds origin)
    {
        var settings = SettingsService.Current;
        settings.ScreenshotLastX = origin.Left;
        settings.ScreenshotLastY = origin.Top;
        settings.ScreenshotLastWidth = origin.Width;
        settings.ScreenshotLastHeight = origin.Height;
        SettingsService.Save();
    }

    private static PixelBounds GlobalRect(FrozenScreen screen, RectD selection)        => new(
            screen.Bounds.Left + (int)Math.Round(selection.X),
            screen.Bounds.Top + (int)Math.Round(selection.Y),
            screen.Bounds.Left + (int)Math.Round(selection.Right),
            screen.Bounds.Top + (int)Math.Round(selection.Bottom));

    private async Task<byte[]?> SelectionPngAsync()
    {
        var overlay = _overlays.FirstOrDefault(item => item.Screen == SelectionScreen);
        return overlay is null ? null : await overlay.ExportPngAsync();
    }

    public async Task RecognizedSelectionAsync()
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        await CopyRecognizedTextAsync(screen, Selection);
    }

    public async Task TranslateSelectionAsync()
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        await TranslateSelectionAsync(screen, Selection);
    }

    public void CopyColor(string hex)
    {
        if (ClipboardWriter.WriteText(hex))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            ClipboardService.Instance?.Store.RecordOwnText(hex);
            NoticeHost.Show("已复制颜色", hex, NoticeTone.Normal);
        }

        Finish();
    }

    public void Finish()
    {
        if (_finished)
        {
            return;
        }

        _finished = true;
        _current = null;
        foreach (var overlay in _overlays)
        {
            overlay.Close();
        }

        _overlays.Clear();
        // 冻结帧（每块屏「宽 × 高 × 4」字节）和遮罩上的 CanvasBitmap 都在大对象堆里：
        // 会话结束就把像素放掉、引用清空，再延后一拍做一次带大对象堆压缩的 GC
        // （Close 之后 WinUI 还要把窗口从内部列表里放掉，紧接着 GC 收不到）。
        foreach (var screen in Screens)
        {
            screen.ReleasePixels();
        }

        Screens.Clear();
        Windows.Clear();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        ReleaseCapturedMemory();
        // 两分钟后空闲回收：放掉遮罩的 Win2D 设备等（REVIEW R27，之前截图之后从不回收）。
        IdleReclaimer.Schedule();
    }

    private static void ReleaseCapturedMemory()
    {
        _ = Task.Run(async () =>
        {
            await Task.Delay(400);
            System.Runtime.GCSettings.LargeObjectHeapCompactionMode =
                System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
            Log.Info("screenshot.memory-released");
        });
    }

    private async Task CopyRecognizedTextAsync(FrozenScreen screen, RectD selection)
    {
        if (!OcrService.HasEngine)
        {
            // 不再自己弹系统设置（PLAN-v8 H14）：提示上给「打开设置」。
            NoticeHost.Show(
                "没装中文识字组件",
                "设置 › 时间和语言 › 语言和区域 › 中文 › 语言选项 › 光学字符识别",
                NoticeTone.Warning,
                NoticeActions.SystemSettings("ms-settings:regionlanguage"));

            Finish();
            return;
        }

        try
        {
            var png = await SelectionPngAsync();
            var decoded = png is null ? null : await ImageCodec.PngToBgraAsync(png);
            if (decoded is not { } image)
            {
                Finish();
                return;
            }

            var (text, _) = await OcrService.RecognizeAsync(image.Bgra, image.Width, image.Height);
            if (string.IsNullOrWhiteSpace(text))
            {
                NoticeHost.Show("没有识别到文字", string.Empty, NoticeTone.Warning);
                Finish();
                return;
            }

            if (ClipboardWriter.WriteText(text))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(text);
            }

            var preview = text.Replace('\n', ' ').Trim();
            if (preview.Length > 30)
            {
                preview = preview[..30] + "…";
            }

            NoticeHost.Show("已复制识别的文字", preview, NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.ocr-failed", ex);
            NoticeHost.Show("识字失败", ex.Message, NoticeTone.Error);
        }

        Finish();
    }

    private async Task TranslateSelectionAsync(FrozenScreen screen, RectD selection)
    {
        if (!OcrService.HasEngine)
        {
            NoticeHost.Show(
                "没装中文识字组件",
                "设置 › 时间和语言 › 语言和区域 › 中文 › 语言选项 › 光学字符识别",
                NoticeTone.Warning,
                NoticeActions.SystemSettings("ms-settings:regionlanguage"));
            Finish();
            return;
        }

        try
        {
            var png = await SelectionPngAsync();
            var decoded = png is null ? null : await ImageCodec.PngToBgraAsync(png);
            if (decoded is not { } image)
            {
                Finish();
                return;
            }

            var (text, _) = await OcrService.RecognizeAsync(
                image.Bgra, image.Width, image.Height, separator: "\n\n");
            if (string.IsNullOrWhiteSpace(text))
            {
                NoticeHost.Show("没有识别到文字", "换个区域再试", NoticeTone.Warning);
                Finish();
                return;
            }

            // 原文记进剪贴板历史，但不覆盖剪贴板（PLAN §9.4）。
            ClipboardService.Instance?.Store.RecordOwnText(text);
            var anchor = new PixelRect(
                screen.Bounds.Left + (int)Math.Round(selection.X),
                screen.Bounds.Top + (int)Math.Round(selection.Y),
                Math.Max(1, (int)Math.Round(selection.Width)),
                Math.Max(1, (int)Math.Round(selection.Height)));
            Finish();
            // 浮窗贴着选区出现（PLAN-v2 §3.8）。
            TranslateHost.ShowTextNear(text, anchor);
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.translate-failed", ex);
            NoticeHost.Show("截图翻译失败", ex.Message, NoticeTone.Error);
            Finish();
        }
    }
}
