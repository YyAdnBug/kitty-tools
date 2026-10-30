// 长截图拍的时候选区旁边那块面板（PLAN-v9 S11，照 mac ScrollCapture.swift 的 ScrollCaptureHUD）：永远深色，宽 216，
// 上面是拼好的长图预览（跟着最新那头长），下面是尺寸、状态行、「放弃」「标注」「完成」（标注 = 拼完不拷贝，开长图标注窗口，S12）。
// 预览上滚轮 = 往回看长图前面的内容，右边一条细指示条说在整张图的哪里；双击预览或滚回最新那头回到跟随（ScrollPreview 的纯函数）。
// 预览直接从 ScrollCanvas 的条带取样（不另外拷整张图），只在没有正在拼的那一拍时取（ScrollingCapture.Idle），没赶上的下一拍补上。
// 摆在选区右边，放不下放左边，都放不下贴选区里面；不抢焦点、不进 Alt+Tab，设「不进录屏」免得贴在选区里时被拍进去
// （截图自检用 KITTY_HUD_CAPTURE=1 关掉）。
// ponytail: mac 的纸带滑动、接缝闪品牌粉、高度数字滚动没做；预览是最近邻取样。要做先看 mac-whisker §6 长截图。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Graphics.DirectX;

namespace KittyTools;

internal sealed partial class ScrollPreviewPanel
{
    private const double WidthDip = 216;
    private const double HeightDip = 430;
    private const double GapDip = 12;

    /// <summary>真滚轮一格（120）在预览里算挪 16 DIP（同 mac）。</summary>
    private const double DipPerNotch = 16;

    private static ScrollPreviewPanel? _instance;

    private readonly Window _window;
    private readonly CanvasControl _preview;
    private readonly TextBlock _size;
    private readonly TextBlock _status;
    private readonly double _scale;
    private CanvasBitmap? _bitmap;

    /// <summary>取好、还没建成位图的预览像素（下一次 Draw 里建）。</summary>
    private (byte[] Bytes, int Width, int Height)? _pending;
    private ScrollCanvas? _canvas;
    private bool _growingUp;
    private string _statusText = string.Empty;
    private bool _warning;

    /// <summary>往回看时从哪行看起；null = 跟着最新那头。</summary>
    private int? _browseFrom;

    /// <summary>上次画的：看的是哪一段、长图多高、预览里放得下几行。</summary>
    private (int Start, int Count, int Height, int Visible) _shown;

    private ScrollPreviewPanel(PixelBounds region)
    {
        _window = new Window { Title = "长截图" };
        HudFrame.Apply(_window);

        _preview = new CanvasControl();
        _preview.Draw += OnDraw;
        _preview.SizeChanged += (_, _) => Render();
        _preview.PointerWheelChanged += (_, e) =>
        {
            var delta = e.GetCurrentPoint(_preview).Properties.MouseWheelDelta;
            Browse(delta * DipPerNotch / 120);
            e.Handled = true;
        };
        _preview.DoubleTapped += (_, _) =>
        {
            if (_browseFrom is not null)
            {
                _browseFrom = null;
                Render();
                ShowStatus();
            }
        };
        AutomationProperties.SetName(_preview, "长截图预览：滚轮往回看，双击回到最新");

        _size = new TextBlock
        {
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Margin = new Thickness(0, 8, 0, 0),
        };
        _status = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            Margin = new Thickness(0, 2, 0, 0),
        };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);

        var cancel = new Button { Content = "放弃", HorizontalAlignment = HorizontalAlignment.Stretch };
        ToolTipService.SetToolTip(cancel, "Esc");
        cancel.Click += (_, _) => ScrollingCapture.Cancel();
        var done = new Button
        {
            Content = "完成",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Theme.BrandPink),
            Foreground = new SolidColorBrush(Colors.White),
        };
        ToolTipService.SetToolTip(done, "Enter");
        done.Click += (_, _) => ScrollingCapture.Complete();
        var annotate = new Button { Content = "标注", HorizontalAlignment = HorizontalAlignment.Stretch };
        ToolTipService.SetToolTip(annotate, "拼完先标注再拷贝");
        annotate.Click += (_, _) => ScrollingCapture.Complete(annotate: true);
        var buttons = new Grid { ColumnSpacing = 6, Margin = new Thickness(0, 10, 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(annotate, 1);
        Grid.SetColumn(done, 2);
        buttons.Children.Add(cancel);
        buttons.Children.Add(annotate);
        buttons.Children.Add(done);

        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var previewFrame = new Border { CornerRadius = new CornerRadius(6), Child = _preview };
        Grid.SetRow(_size, 1);
        Grid.SetRow(_status, 2);
        Grid.SetRow(buttons, 3);
        layout.Children.Add(previewFrame);
        layout.Children.Add(_size);
        layout.Children.Add(_status);
        layout.Children.Add(buttons);

        // 永远深色（同 mac 的长截图 HUD）：圆角、阴影、发丝线由 DWM 画（HudFrame）。
        _window.Content = new Border
        {
            RequestedTheme = ElementTheme.Dark,
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 32, 32, 32)),
            Padding = new Thickness(10),
            Child = layout,
        };

        var display = Displays.AtPoint(region.Left + region.Width / 2, region.Top + region.Height / 2);
        _scale = display.Scale <= 0 ? 1 : display.Scale;
        var gap = MonitorLayout.Pixels(GapDip, _scale);
        var width = MonitorLayout.Pixels(WidthDip, _scale);
        var height = Math.Min(MonitorLayout.Pixels(HeightDip, _scale), display.Work.Bottom - display.Work.Top - 2 * gap);
        var (x, y) = ScrollPreview.PanelOrigin(
            region.Left, region.Top, region.Right,
            display.Work.Left, display.Work.Top, display.Work.Right, display.Work.Bottom,
            width, height, gap);
        _window.AppWindow.MoveAndResize(HudFrame.WithFrame(_window, new RectInt32(x, y, width, height)));
        _window.AppWindow.Show(false);
        if (Environment.GetEnvironmentVariable("KITTY_HUD_CAPTURE") != "1")
        {
            SetWindowDisplayAffinity(WinRT.Interop.WindowNative.GetWindowHandle(_window), 0x11 /* WDA_EXCLUDEFROMCAPTURE */);
        }
    }

    /// <summary>开始长截图时出面板；建不出来就没有预览，状态行退回轻提示。</summary>
    public static void Show(PixelBounds region, string status)
    {
        Hide();
        try
        {
            _instance = new ScrollPreviewPanel(region);
        }
        catch (Exception ex)
        {
            Log.Warn($"scroll.panel-failed {ex.GetType().Name}");
            _instance = null;
        }

        SetStatus(status);
    }

    /// <summary>拼上一拍以后（这时没有正在拼的）：换预览。grown = 这一拍长了几行，往上长时往回看的位置跟着往下挪，看的内容不动。</summary>
    public static void Update(ScrollCanvas canvas, bool growingUp, int grown)
    {
        if (_instance is not { } panel)
        {
            return;
        }

        panel._canvas = canvas;
        panel._growingUp = growingUp;
        if (growingUp && panel._browseFrom is { } from)
        {
            panel._browseFrom = from + grown;
        }

        panel._size.Text = $"{canvas.Width} × {canvas.Height}";
        AutomationProperties.SetName(panel._size, $"已拼 {canvas.Height} 像素高");
        panel.Render();
    }

    /// <summary>状态行；没有面板时退回轻提示。</summary>
    public static void SetStatus(string text, bool warning = false)
    {
        if (_instance is not { } panel)
        {
            NoticeHost.Show("长截图", text, warning ? NoticeTone.Warning : NoticeTone.Normal);
            return;
        }

        panel._statusText = text;
        panel._warning = warning;
        panel.ShowStatus();
    }

    public static void Hide()
    {
        if (_instance is not { } panel)
        {
            return;
        }

        _instance = null;
        panel._canvas = null;
        panel._bitmap?.Dispose();
        panel._bitmap = null;
        panel._pending = null;
        try
        {
            panel._preview.RemoveFromVisualTree();
            panel._window.Close();
        }
        catch
        {
            // 已经关了。
        }
    }

    private void ShowStatus()
    {
        // 往回看时提示怎么回去（优先级最低：暂停这类橙色提示照旧盖过它）。
        var browsing = _browseFrom is not null && !_warning;
        _status.Text = browsing ? "双击预览回到最新" : _statusText;
        _status.Foreground = new SolidColorBrush(_warning
            ? Theme.Argb(255, 255, 159, 10)
            : ColorHelper.FromArgb(166, 255, 255, 255));
    }

    private void Browse(double dips)
    {
        var (_, _, height, visible) = _shown;
        if (_canvas is null || height <= 0 || _preview.ActualWidth <= 0)
        {
            return;
        }

        // 预览里 1 DIP 是长图的几行。
        var rows = dips * _canvas.Width / _preview.ActualWidth;
        var next = ScrollPreview.Browse(_browseFrom, rows, height, visible, _growingUp);
        if (next == _browseFrom)
        {
            return;
        }

        _browseFrom = next;
        Render();
        ShowStatus();
    }

    /// <summary>按现在看的位置重取预览；正在拼的那一拍没完就先不取（拼完 Update 会再来）。</summary>
    private void Render()
    {
        var width = (int)Math.Round(_preview.ActualWidth * _scale);
        var box = (int)Math.Round(_preview.ActualHeight * _scale);
        if (_canvas is not { } canvas || !ScrollingCapture.Idle || width <= 0 || box <= 0 || canvas.Width <= 0)
        {
            return;
        }

        var visible = (int)((long)box * canvas.Width / width);
        var (start, count) = ScrollPreview.Range(canvas.Height, visible, _browseFrom, _growingUp);
        // 看到了最新那头（或整张都放得下）= 回到跟随。
        if (_browseFrom is not null && (_growingUp ? start <= 0 : start + count >= canvas.Height))
        {
            _browseFrom = null;
            ShowStatus();
        }

        if (count <= 0)
        {
            return;
        }

        var height = Math.Clamp((int)Math.Round((double)count * width / canvas.Width), 1, box);
        var pixels = canvas.Sample(start, count, width, height);
        var bytes = new byte[pixels.Length * 4];
        Buffer.BlockCopy(pixels, 0, bytes, 0, bytes.Length);
        // 位图在 Draw 里建（这时画布的设备一定在了，同 SelectionOverlayWindow）。
        _pending = (bytes, width, height);
        _bitmap?.Dispose();
        _bitmap = null;
        _shown = (start, count, canvas.Height, visible);
        _preview.Invalidate();
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        ds.Clear(ColorHelper.FromArgb(255, 44, 44, 44));
        if (_bitmap is null && _pending is { } pending)
        {
            // 屏幕 DC 拷出来的 alpha 不可靠：不看 alpha。
            _bitmap = CanvasBitmap.CreateFromBytes(
                sender, pending.Bytes, pending.Width, pending.Height,
                DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Ignore);
            _pending = null;
        }

        if (_bitmap is not { } bitmap)
        {
            return;
        }

        var width = (float)sender.ActualWidth;
        var height = (float)(bitmap.SizeInPixels.Height / _scale);
        // 往下长贴顶、往上长贴底：新内容总在长的那头。
        var top = _growingUp ? (float)sender.ActualHeight - height : 0;
        ds.DrawImage(bitmap, new Windows.Foundation.Rect(0, top, width, height));

        var (start, count, total, _) = _shown;
        if (_browseFrom is not null &&
            ScrollPreview.Scrubber(sender.ActualHeight - 4, start, count, total) is { } scrubber)
        {
            ds.FillRoundedRectangle(
                new Windows.Foundation.Rect(width - 6, 2 + scrubber.Top, 3, scrubber.Height), 1.5f, 1.5f,
                ColorHelper.FromArgb(166, 255, 255, 255));
        }
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
}
