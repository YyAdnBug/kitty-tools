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
}

internal sealed class ScreenshotSession
{
    private static ScreenshotSession? _current;

    private readonly List<SelectionOverlayWindow> _overlays = new();
    private bool _finished;

    public ScreenshotSession(ScreenshotMode mode, List<FrozenScreen> screens, List<SnapWindow> windows)
    {
        Mode = mode;
        Screens = screens;
        Windows = windows;
    }

    public static bool IsActive => _current is not null;

    public ScreenshotMode Mode { get; }

    public List<FrozenScreen> Screens { get; }

    public List<SnapWindow> Windows { get; }

    public FrozenScreen? SelectionScreen { get; private set; }

    public RectD Selection { get; private set; }

    public bool HasSelection => SelectionScreen is not null && Selection.Width >= 1 && Selection.Height >= 1;

    public static void Start(ScreenshotMode mode)
    {
        if (_current is not null)
        {
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
        session.ShowOverlays();
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

        var png = await SelectionPngAsync();
        if (png is not null)
        {
            await ScreenshotOutput.CopyPngAsync(png, screen, Selection);
        }

        Finish();
    }

    public async Task SaveSelectionAsync(bool saveAs)
    {
        if (!HasSelection || SelectionScreen is not { } screen)
        {
            return;
        }

        var png = await SelectionPngAsync();
        if (png is null)
        {
            Finish();
            return;
        }

        if (saveAs && _overlays.FirstOrDefault() is { } overlay)
        {
            await ScreenshotOutput.SavePngAsAsync(overlay.AppWindow, png);
        }
        else
        {
            await ScreenshotOutput.QuickSavePngAsync(png);
        }

        Finish();
    }

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
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
    }

    private async Task CopyRecognizedTextAsync(FrozenScreen screen, RectD selection)
    {
        if (!OcrService.HasEngine)
        {
            NoticeHost.Show(
                "没装中文识字组件",
                "设置 › 时间和语言 › 语言和区域 › 中文 › 语言选项 › 光学字符识别",
                NoticeTone.Warning);
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:regionlanguage")
                {
                    UseShellExecute = true,
                });
            }
            catch
            {
                // 打不开设置就算了。
            }

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
                NoticeTone.Warning);
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
            Finish();
            TranslateHost.ShowText(text);
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.translate-failed", ex);
            NoticeHost.Show("截图翻译失败", ex.Message, NoticeTone.Error);
            Finish();
        }
    }
}
