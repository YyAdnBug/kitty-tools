// 长截图拍的时候选区旁边那块面板（PLAN-v9 S11，照 mac ScrollCapture.swift 的 ScrollCaptureHUD）：永远深色，宽 216，
// 上面是拼好的长图预览（跟着最新那头长），下面是长图的高度读数、状态行、自动滚动的一排速度「慢 / 标准 / 快」（照 mac b923b882：放在按钮行
// 上面，记住上次，滚动中换档下一帧生效；REVIEW G2 起手动滚时也在，中途点 ▶ 转自动用它），最下面一排按钮照 mac 的 HUD：
// ▶ / ⏸ 自动滚动 · 标注 ｜ 存储 ▾（存储到「X」/ 另存为…）｜ 取消 · ✓ 拷贝（标注 = 拼完不拷贝，开长图标注窗口，S12）。
// 面板不拿键盘（焦点留在被滚的程序上），mac 面板上的空格 / A / ⌘S 这里没有，Enter、Esc 照旧是全局临时键。
// 预览上滚轮 = 往回看长图前面的内容，右边一条细指示条说在整张图的哪里；双击预览或滚回最新那头回到跟随（ScrollPreview 的纯函数）。
// 预览直接从 ScrollCanvas 的条带取样（不另外拷整张图），只在没有正在拼的那一拍时取（ScrollingCapture.Idle），没赶上的下一拍补上。
// R106 起照 mac（mac-whisker §6 长截图）：取样是按块平均的平滑取样（Core ScrollCanvas.Sample，只缩不放，长图比预览窄时由 Win2D 线性放大）；
// 预览上下 18 DIP 渐隐；每拼上一段，预览撑满了的话像纸带一样把新的一截从长的那头推进来（0.2 s easeOut），长的那头闪一下品牌粉
// （0.25 → 0、0.4 s，从那条边往里 24 DIP 渐隐，跟着纸带一起走）；高度数字变了的那几位滚过去（ScrollHeightReading）。
// 第一帧、往回看的时候、系统关了动画效果（同 mac 减弱动态效果）时不滑不闪。动画只是 Win2D 每帧按时间重画这块预览
// （订 CompositionTarget.Rendering，滑完闪完就退订），截屏、拼接、对账都不动；时长和位移的算法在 Core 的 ScrollPreview。
// 摆在选区右边，放不下放左边，都放不下贴选区里面；不抢焦点、不进 Alt+Tab，设「不进录屏」免得贴在选区里时被拍进去
// （截图自检用 KITTY_HUD_CAPTURE=1 关掉）。
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
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
    private readonly ScrollHeightReading _reading = new() { Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBlock _status;
    private readonly double _scale;
    private readonly ToggleButton[] _speeds;
    private readonly Button _auto;
    private CanvasBitmap? _bitmap;

    /// <summary>取好、还没建成位图的预览像素（下一次 Draw 里建）。</summary>
    private (byte[] Bytes, int Width, int Height)? _pending;

    /// <summary>预览图画出来多高（DIP）：长图比预览窄时位图是按原大小取的，画的时候放大。</summary>
    private double _drawHeight;

    /// <summary>上次预览时长图多高（像素）：算这次新拼上多少；0 = 还没出过预览，第一帧不算新拼上的一段（不滑不闪，同 mac）。</summary>
    private int _previewedHeight;

    /// <summary>纸带：从多远（DIP，往下为正）滑回 0、哪一刻开始滑的（Stopwatch 刻度，0 = 没在滑）。</summary>
    private double _tapeFrom;
    private long _tapeSince;

    /// <summary>接缝闪光哪一刻开始的（Stopwatch 刻度，0 = 没在闪）。</summary>
    private long _seamSince;

    /// <summary>订着 CompositionTarget.Rendering（纸带在滑、接缝在闪时每帧重画预览）。</summary>
    private bool _ticking;
    private ScrollCanvas? _canvas;
    private bool _growingUp;
    private string _statusText = string.Empty;
    private bool _warning;

    /// <summary>往回看时从哪行看起；null = 跟着最新那头。</summary>
    private int? _browseFrom;

    /// <summary>上次画的：看的是哪一段、长图多高、预览里放得下几行。</summary>
    private (int Start, int Count, int Height, int Visible) _shown;

    private static readonly (ScrollSpeed Speed, string Title)[] SpeedChoices =
    {
        (ScrollSpeed.Slow, "慢"), (ScrollSpeed.Normal, "标准"), (ScrollSpeed.Fast, "快"),
    };

    private ScrollPreviewPanel(PixelBounds region, ScrollSpeed? speed)
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

        _status = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            MaxLines = 2,
            Margin = new Thickness(0, 2, 0, 0),
        };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);

        // 按钮行（REVIEW G2，mac ScrollCaptureHUD）：▶ 标注 ｜ 存储 ▾ ｜ ✕ ✓；点了不拿焦点
        _auto = SelectionOverlayWindow.ToolbarButton(Glyphs.Play, "自动滚动", "自动滚动");
        _auto.Click += (_, _) => ScrollingCapture.ToggleAuto();
        var annotate = SelectionOverlayWindow.ToolbarButton(Glyphs.Edit, "标注（拼完先标注再拷贝）", "标注");
        annotate.Click += (_, _) => ScrollingCapture.Complete(ScrollOutput.Annotate);
        var folder = Path.GetFileName(ScreenshotOutput.SaveFolder.TrimEnd(Path.DirectorySeparatorChar));
        var save = SelectionOverlayWindow.ToolbarButton(Glyphs.Save, $"存储到「{folder}」", "存储", width: 30);
        save.Click += (_, _) => ScrollingCapture.Complete(ScrollOutput.Save);
        var saveMenu = SelectionOverlayWindow.ToolbarButton(Glyphs.ChevronDown, $"存储到「{folder}」/ 另存为…", "更多存储选项", width: 14);
        if (saveMenu.Content is FontIcon chevron)
        {
            chevron.FontSize = 9;
        }

        saveMenu.Click += (_, _) =>
        {
            var menu = new MenuFlyout { Placement = FlyoutPlacementMode.Top };
            var quick = new MenuFlyoutItem { Text = $"存储到「{folder}」" };
            quick.Click += (_, _) => ScrollingCapture.Complete(ScrollOutput.Save);
            var saveAs = new MenuFlyoutItem { Text = "另存为…" };
            saveAs.Click += (_, _) => ScrollingCapture.Complete(ScrollOutput.SaveAs);
            menu.Items.Add(quick);
            menu.Items.Add(saveAs);
            menu.ShowAt(saveMenu);
        };
        var cancel = SelectionOverlayWindow.ToolbarButton(Glyphs.Close, "取消（Esc）", "取消");
        cancel.Click += (_, _) => ScrollingCapture.Cancel();
        var done = new Button
        {
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Theme.BrandPink),
            Foreground = new SolidColorBrush(Colors.White),
            AllowFocusOnInteraction = false,
            Content = new FontIcon { Glyph = Glyphs.Check, FontSize = 13 },
            Margin = new Thickness(4, 0, 0, 0),
        };
        ToolTipService.SetToolTip(done, "拷贝（Enter）");
        AutomationProperties.SetName(done, "拷贝");
        done.Click += (_, _) => ScrollingCapture.Complete();
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 10, 0, 0),
            Children = { _auto, annotate, BarSeparator(), save, saveMenu, BarSeparator(), cancel, done },
        };
        foreach (var child in buttons.Children)
        {
            if (child is Button button)
            {
                button.VerticalAlignment = VerticalAlignment.Center;
            }
        }

        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var previewFrame = new Border { CornerRadius = new CornerRadius(6), Child = _preview };
        Grid.SetRow(_reading, 1);
        Grid.SetRow(_status, 2);
        Grid.SetRow(buttons, 4);
        layout.Children.Add(previewFrame);
        layout.Children.Add(_reading);
        layout.Children.Add(_status);
        layout.Children.Add(buttons);

        // 自动滚动的速度（REVIEW G2：一直在，手动滚时点 ▶ 转自动照这个速度）：三个一组的切换钮，点了不放手（总有一个选中）。
        _speeds = Array.Empty<ToggleButton>();
        if (speed is { } current)
        {
            var row = new Grid { ColumnSpacing = 2, Margin = new Thickness(0, 10, 0, 0) };
            ToolTipService.SetToolTip(row, "自动滚动的速度");
            _speeds = new ToggleButton[SpeedChoices.Length];
            for (var index = 0; index < SpeedChoices.Length; index++)
            {
                var (value, title) = SpeedChoices[index];
                row.ColumnDefinitions.Add(new ColumnDefinition());
                var button = new ToggleButton
                {
                    Content = title,
                    FontSize = 12,
                    Padding = new Thickness(0, 3, 0, 4),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    IsChecked = value == current,
                };
                AutomationProperties.SetName(button, $"自动滚动速度：{title}");
                button.Click += (_, _) => SelectSpeed(value);
                Grid.SetColumn(button, index);
                row.Children.Add(button);
                _speeds[index] = button;
            }

            Grid.SetRow(row, 3);
            layout.Children.Add(row);
        }

        // 永远深色（同 mac 的长截图 HUD）：圆角、阴影、发丝线由 DWM 画（HudFrame）。
        _window.Content = new Border
        {
            RequestedTheme = ElementTheme.Dark,
            Background = new SolidColorBrush(Theme.Shot.HudBackground),
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

    /// <summary>开始长截图时出面板；建不出来就没有预览，状态行退回轻提示。speed：自动滚动时的速度（有它才出那一排）。</summary>
    public static void Show(PixelBounds region, string status, ScrollSpeed? speed = null)
    {
        Hide();
        try
        {
            _instance = new ScrollPreviewPanel(region, speed);
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

        panel._reading.Show(canvas.Width, canvas.Height);
        // 新拼上多少（纸带推多远）按两次预览之间长图长了多少算；第一帧不算。
        var fresh = panel._previewedHeight == 0 ? 0 : canvas.Height - panel._previewedHeight;
        panel._previewedHeight = canvas.Height;
        panel.Render(fresh);
    }

    /// <summary>(x, y)（物理像素）落在面板上、或离面板 marginDip 以内（自动滚动时光标在这里先不发滚轮）。</summary>
    public static bool Contains(int x, int y, double marginDip)
    {
        if (_instance is not { } panel)
        {
            return false;
        }

        var position = panel._window.AppWindow.Position;
        var size = panel._window.AppWindow.Size;
        var margin = (int)Math.Round(marginDip * panel._scale);
        return x >= position.X - margin && x < position.X + size.Width + margin &&
            y >= position.Y - margin && y < position.Y + size.Height + margin;
    }

    /// <summary>按钮行里的竖线（同截图工具栏）。</summary>
    private static Border BarSeparator() => new()
    {
        Width = 1,
        Height = 18,
        Margin = new Thickness(3, 0, 3, 0),
        VerticalAlignment = VerticalAlignment.Center,
        Background = new SolidColorBrush(ColorHelper.FromArgb(46, 255, 255, 255)),
    };

    /// <summary>▶ / ⏸ 跟着自动滚动开没开（ScrollingCapture 开关自动滚动时调）。</summary>
    public static void SyncAuto()
    {
        if (_instance is not { } panel)
        {
            return;
        }

        var on = ScrollingCapture.AutoScrolling;
        if (panel._auto.Content is FontIcon icon)
        {
            icon.Glyph = on ? Glyphs.Pause : Glyphs.Play;
            // 自动滚动开着时钮是品牌粉（mac autoButton.contentTintColor = Shot.accent）。
            icon.Foreground = new SolidColorBrush(on ? Theme.Shot.Accent : Theme.Shot.HudTextMuted);
        }

        var text = on ? "停止自动滚动" : "自动滚动";
        ToolTipService.SetToolTip(panel._auto, text);
        AutomationProperties.SetName(panel._auto, text);
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

    /// <summary>
    /// 自检（Debug 的 --long-annotate-probe，要 KITTY_HUD_CAPTURE=1 才抓得到）：出面板、喂三拍造出来的帧（往下滚），
    /// 每拍后 50 ms 抓一次面板那块屏（-moving：纸带在滑、接缝在闪，R106）、滑完再抓一次；再在右下角闪一下「都不要」的白块、
    /// 80 ms 后抓那一角。图都存进 directory。
    /// </summary>
    internal static async Task ProbeAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        const int width = 800;
        const int height = 600;
        var content = new int[width * 2400];
        for (var y = 0; y < 2400; y++)
        {
            var color = unchecked((int)0xFF000000) | (y * 97 % 256 << 16) | (y / 40 * 53 % 256 << 8) | (y * 13 % 256);
            for (var x = 0; x < width; x++)
            {
                content[y * width + x] = x < 40 + y % 300 ? color : unchecked((int)0xFFF0F0F0);
            }
        }

        ScrollFrame FrameAt(int top)
        {
            var pixels = new int[width * height];
            Array.Copy(content, top * width, pixels, 0, pixels.Length);
            return new ScrollFrame(width, height, pixels);
        }

        var region = new PixelBounds(400, 200, 400 + width, 200 + height);
        Show(region, "滚动选区，Enter 完成，Esc 放弃");
        var canvas = new ScrollCanvas(FrameAt(0));
        var shots = 0;
        foreach (var top in new[] { 0, 350, 700, 1200 })
        {
            var before = canvas.Height;
            if (top > 0)
            {
                canvas.Append(FrameAt(top), ScrollDirection.Down);
            }

            Update(canvas, false, canvas.Height - before);
            // R106：拼上后 50 ms 抓一张（纸带还在滑、接缝还在闪），再等滑完闪完抓一张。
            await Task.Delay(50);
            await SavePanel($"scroll-panel-{shots}-moving.png");
            await Task.Delay(550);
            await SavePanel($"scroll-panel-{shots++}.png");
            Log.Info($"scroll.panel-probe top={top} height={canvas.Height}");
        }

        Hide();
        ShotFlash.Show(new PixelBounds(0, 0, 1200, 800));
        await Task.Delay(80);
        var display = Displays.AtPoint(1, 1);
        await SaveScreen(
            new PixelBounds(display.Work.Right - 700, display.Work.Bottom - 500, display.Work.Right, display.Work.Bottom),
            Path.Combine(directory, "shot-flash.png"));

        async Task SavePanel(string name)
        {
            if (_instance?._window is { } window)
            {
                var position = window.AppWindow.Position;
                var size = window.AppWindow.Size;
                await SaveScreen(
                    new PixelBounds(position.X, position.Y, position.X + size.Width, position.Y + size.Height),
                    Path.Combine(directory, name));
            }
        }

        static async Task SaveScreen(PixelBounds bounds, string path)
        {
            if (ScreenCapture.CaptureRegion(bounds) is { } bgra &&
                await ImageCodec.BgraToPngAsync(bounds.Width, bounds.Height, bgra) is { } png)
            {
                await File.WriteAllBytesAsync(path, png);
            }
        }
    }

    public static void Hide()
    {
        if (_instance is not { } panel)
        {
            return;
        }

        _instance = null;
        panel.StopTicking();
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

    /// <summary>点了一个速度：三个钮里只亮它（再点已选中的也不放手），交给 ScrollingCapture 换档、记住。</summary>
    private void SelectSpeed(ScrollSpeed speed)
    {
        for (var index = 0; index < _speeds.Length; index++)
        {
            _speeds[index].IsChecked = SpeedChoices[index].Speed == speed;
        }

        ScrollingCapture.SetSpeed(speed);
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

    /// <summary>
    /// 按现在看的位置重取预览；正在拼的那一拍没完就先不取（拼完 Update 会再来）。
    /// grown：这次比上次预览新拼上了多少行（Update 里给，别的时候 0）：大于 0 时纸带滑、接缝闪（StartMotion）。
    /// </summary>
    private void Render(int grown = 0)
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

        // 画出来多高（物理像素）。Sample 只管缩（按块平均）：长图比预览窄时按原大小取，画的时候 Win2D 线性放大。
        var height = Math.Clamp((int)Math.Round((double)count * width / canvas.Width), 1, box);
        var sampleWidth = Math.Min(width, canvas.Width);
        var sampleHeight = sampleWidth == width ? height : count;
        var pixels = canvas.Sample(start, count, sampleWidth, sampleHeight);
        var bytes = new byte[pixels.Length * 4];
        Buffer.BlockCopy(pixels, 0, bytes, 0, bytes.Length);
        // 位图在 Draw 里建（这时画布的设备一定在了，同 SelectionOverlayWindow）。
        _pending = (bytes, sampleWidth, sampleHeight);
        _drawHeight = height / _scale;
        _bitmap?.Dispose();
        _bitmap = null;
        _shown = (start, count, canvas.Height, visible);
        StartMotion(grown, canvas.Width);
        _preview.Invalidate();
    }

    /// <summary>
    /// 新拼上 grown 行（mac updatePreview）：预览撑满了的话纸带从长的那头滑回来（还没滑完的接着滑，旧内容不跳），长的那头闪一下品牌粉。
    /// 往回看的时候、系统关了动画效果时不滑不闪，往回看时把还在走的停掉。
    /// </summary>
    private void StartMotion(int grown, int canvasWidth)
    {
        if (_browseFrom is not null)
        {
            _tapeSince = 0;
            _seamSince = 0;
            return;
        }

        if (grown <= 0 || Motion.Reduced)
        {
            return;
        }

        var now = Stopwatch.GetTimestamp();
        var box = _preview.ActualHeight;
        if (_drawHeight >= box - 1)
        {
            _tapeFrom = ScrollPreview.TapeStart(grown, _preview.ActualWidth, canvasWidth, box, _growingUp, TapeOffset(now));
            _tapeSince = now;
        }

        _seamSince = now;
        if (!_ticking)
        {
            _ticking = true;
            CompositionTarget.Rendering += OnRendering;
        }
    }

    private void StopTicking()
    {
        if (_ticking)
        {
            _ticking = false;
            CompositionTarget.Rendering -= OnRendering;
        }
    }

    /// <summary>纸带、接缝在走时每帧重画一次预览；都走完了再画最后一帧（位移 0、不闪）就退订。</summary>
    private void OnRendering(object? sender, object e)
    {
        var now = Stopwatch.GetTimestamp();
        if (Seconds(now, _tapeSince) >= ScrollPreview.TapeSeconds)
        {
            _tapeSince = 0;
        }

        if (Seconds(now, _seamSince) >= ScrollPreview.SeamSeconds)
        {
            _seamSince = 0;
        }

        _preview.Invalidate();
        if (_tapeSince == 0 && _seamSince == 0)
        {
            StopTicking();
        }
    }

    /// <summary>纸带此刻的位移（DIP，往下为正）；没在滑是 0。</summary>
    private double TapeOffset(long now)
        => _tapeSince == 0 ? 0 : ScrollPreview.TapeOffset(_tapeFrom, Seconds(now, _tapeSince));

    /// <summary>since 到 now 过了几秒；since 是 0（没开始）时当作早就过完了。</summary>
    private static double Seconds(long now, long since)
        => since == 0 ? double.MaxValue : (double)(now - since) / Stopwatch.Frequency;

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

        var width = (float)sender.ActualWidth;
        var box = (float)sender.ActualHeight;
        if (_bitmap is { } bitmap)
        {
            var now = Stopwatch.GetTimestamp();
            var height = (float)_drawHeight;
            // 往下长贴顶、往上长贴底：新内容总在长的那头。纸带滑的时候整张跟着挪（接缝闪光一起走，同 mac 的 sublayerTransform）。
            var top = (_growingUp ? box - height : 0) + (float)TapeOffset(now);
            ds.DrawImage(
                bitmap, new Windows.Foundation.Rect(0, top, width, height), bitmap.Bounds, 1, CanvasImageInterpolation.Linear);

            // 接缝闪光：长的那头那条边上品牌粉，往里 24 DIP 渐隐到透明（mac 在预览框的那条边上，这里贴着图的那条边：
            // 撑满以后是同一个地方，没撑满时闪在新内容接上的地方）。
            var seam = _seamSince == 0 ? 0 : ScrollPreview.SeamOpacity(Seconds(now, _seamSince));
            if (seam > 0)
            {
                var size = (float)ScrollPreview.SeamHeight;
                var edge = _growingUp ? top : top + height;
                var inward = _growingUp ? edge + size : edge - size;
                using var flash = new CanvasLinearGradientBrush(sender, Theme.Shot.Accent, Transparent(Theme.Shot.Accent))
                {
                    StartPoint = new Vector2(0, edge),
                    EndPoint = new Vector2(0, inward),
                    Opacity = (float)seam,
                };
                ds.FillRectangle(new Windows.Foundation.Rect(0, Math.Min(edge, inward), width, size), flash);
            }
        }

        // 上下渐隐 18 DIP（mac 的渐隐蒙版）：面板底色从边上淡到透明，盖在预览上。
        var fade = (float)ScrollPreview.FadeHeight(box);
        if (fade > 0)
        {
            var panel = Theme.Shot.HudBackground;
            using var upper = new CanvasLinearGradientBrush(sender, panel, Transparent(panel))
            {
                StartPoint = new Vector2(0, 0),
                EndPoint = new Vector2(0, fade),
            };
            ds.FillRectangle(new Windows.Foundation.Rect(0, 0, width, fade), upper);
            using var lower = new CanvasLinearGradientBrush(sender, panel, Transparent(panel))
            {
                StartPoint = new Vector2(0, box),
                EndPoint = new Vector2(0, box - fade),
            };
            ds.FillRectangle(new Windows.Foundation.Rect(0, box - fade, width, fade), lower);
        }

        // 位置指示条在渐隐上面画（mac 画在 HUD 自己的图层上，到头时不跟着淡掉）。
        var (start, count, total, _) = _shown;
        if (_browseFrom is not null &&
            ScrollPreview.Scrubber(sender.ActualHeight - 4, start, count, total) is { } scrubber)
        {
            ds.FillRoundedRectangle(
                new Windows.Foundation.Rect(width - 6, 2 + scrubber.Top, 3, scrubber.Height), 1.5f, 1.5f,
                ColorHelper.FromArgb(166, 255, 255, 255));
        }
    }

    private static Windows.UI.Color Transparent(Windows.UI.Color color) => ColorHelper.FromArgb(0, color.R, color.G, color.B);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
}
