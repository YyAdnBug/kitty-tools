// 长图标注（PLAN-v9 S12，照 mac AnnotateOverlay.swift / ScrollCanvas.swift）：比屏幕大的长截图在这扇铺满工作区的窗口里标——
// 长图按宽适配（最大 1:1）摆在能滚的框里，工具栏贴在下面。截图历史里「改标注」一条放不进屏幕的、长截图面板的「标注」都开它。
// 画面是 Win2D 的 CanvasVirtualControl，只画看得见的那几块；长图切成 4096 行一条的位图（上限 30000 行，整张一张纹理会撞
// 16384 的上限，PLAN-v8 H7），出图也一条条画、再拼起来编 PNG。标注的模型、画法、命中和手柄全用截图遮罩那一套
// （Annotation / AnnotationRenderer / AnnotationDocument），坐标是长图的像素，所以缩放不影响画好的标注。
// 交互：1–0 选工具（再按收起）、拖动画、点中标注选中 / 拖着挪、拖手柄改大小（Shift 约束）、Delete 删、Ctrl+Z / Ctrl+Y 撤销重做；
// Enter / Ctrl+C 拷贝、Ctrl+S 存到截图文件夹、Ctrl+Shift+S 另存为，画过标注时 Esc 要按两下才放弃（同 mac）。
// 拷贝 / 存储时回写截图历史的那一条（原图不动，标注和成品换新的）。
// 裁剪（PLAN-v11 F11，mac X17；工具栏「裁剪」/ X）：在长图上拖出要留下的那一段，松手原图和标注一起裁（长截图拼完常要裁掉头尾）；
// 回写历史时原图换成裁过的、宽高跟着改。ponytail: 裁剪不进撤销（裁完撤销栈清空），裁错了 Esc 放弃这次重开。
// 缩放（PLAN-v11 C1，照 mac ScrollCanvas）：默认按宽适配（最大 1:1），Ctrl+0 回到适合宽度、Ctrl+1 实际大小、Ctrl+= / Ctrl+- 和
// Ctrl+滚轮一档一档（Core 的 ZoomSteps），换档时画面中间那一点不动；样式弹层同截图遮罩多一排选项（空心 / 实心、像素 / 模糊……）；
// 双击文字重新编辑；拖着画 / 挪的时候碰到窗口上下边自动滚；按住空格拖动平移。
// 样式弹层补齐截图遮罩那几样（PLAN-v20 A1，mac ee303f55 / 43b0248e / 79deab8c）：色点后面吸管（点了再单击长图上一点取色，Esc 不取）
// 和取过的那个颜色；文字是「A− 字号 A+」（点数字选 12–72）；选中序号时「− n +」改编号；打码多一个「自动」——长图比识字能吃的
// 最大边长高，切成 4000 行一条、相邻叠 200 行一条条识字（Core Redaction.Slices），手机号、邮箱、卡号、身份证号各盖一块，一起记一步撤销；
// 识字没完时拷贝 / 保存先等它（号码不跟着图出去）。长图里 Ctrl+= / Ctrl+- 是缩放，所以字号只在弹层里换。
// ponytail: 条带位图看过的都留着（最多和长图一样大，约 170 MB 显存）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Graphics.DirectX;
using Windows.System;
using Windows.UI.Core;
using Windows.Win32;

namespace KittyTools;

internal sealed class LongAnnotateWindow
{
    private const int BandRows = 4096;

    private static readonly CanvasStrokeStyle SelectionDash = new() { CustomDashStyle = new[] { 4f, 3f } };

    private static LongAnnotateWindow? _instance;

    private readonly Window _window;
    private byte[] _bgra;
    private int _width;
    private int _height;

    /// <summary>截图时那块屏的缩放：标注的粗细、字号按它从 DIP 换成长图的像素（同截图遮罩）。</summary>
    private readonly double _scale;

    /// <summary>没画标注时直接用它出图；没有时（刚拼完）现编。</summary>
    private byte[]? _png;
    private readonly string? _historyId;

    /// <summary>马赛克取色用：整张长图当一块「冻结帧」。</summary>
    private FrozenScreen _source;
    private readonly PixelBounds _origin;
    private readonly AnnotationDocument _document = new();
    private readonly ScrollViewer _scroller;
    private readonly Grid _page;
    private readonly CanvasVirtualControl _view;
    private readonly Canvas _editorLayer;
    private readonly TextBlock _hint;
    private readonly Dictionary<int, CanvasBitmap> _bands = new();
    private readonly Dictionary<AnnotationKind, Button> _toolButtons = new();
    private readonly Button _undoButton;
    private readonly Button _redoButton;
    private readonly Button _cropButton;
    private readonly List<PointD> _pen = new();

    /// <summary>画面上 1 个长图像素是几个 DIP。</summary>
    private double _unit = 1;

    /// <summary>缩放档位（实际大小的倍数，C1）；null = 适合宽度（默认，跟着窗口宽）。</summary>
    private double? _zoom;

    /// <summary>双击重新编辑的那条文字（C1）：编辑时画面上不画它，收下时换掉它。</summary>
    private Annotation? _editingText;

    /// <summary>按住空格（平移）、平移开始时的指针位置（相对滚动框）和滚动位置（C1）。</summary>
    private bool _spaceDown;
    private Windows.Foundation.Point _panFrom;
    private (double X, double Y) _panOffset;

    /// <summary>拖到窗口上下边时自动滚（C1）：最近一次指针在长图上的位置（DIP，相对画面）和计时器。</summary>
    private Windows.Foundation.Point _lastViewPoint;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _edgeTimer;
    private AnnotationKind? _tool;
    private AnnotationStyle _style = AnnotationStyle.Default;
    private Annotation? _draft;
    private Drag _drag;
    private PointD _start;
    private Annotation? _grabbed;
    private AnnotationHandle _handle;
    private IReadOnlyList<Annotation> _before = Array.Empty<Annotation>();
    private TextBox? _editor;
    private PointD _editorPoint;
    private long _escapeArmedAt;
    private bool _busy;

    /// <summary>工具栏上的「颜色和粗细」（自检拿它打开样式弹层截图）。</summary>
    private Button? _styleButton;

    /// <summary>吸管取色中：下一次单击取长图上那一点的颜色（A1）。</summary>
    private bool _picking;

    /// <summary>自动打码正在识字（A1）：出图之前等它。</summary>
    private Task? _redaction;

    /// <summary>裁剪开着（F11）、正在拖的裁剪框（长图像素）、这次裁过没有（回写历史时原图跟着换）。</summary>
    private bool _cropping;
    private RectD? _cropDraft;
    private bool _cropped;

    private enum Drag
    {
        None,
        Draw,
        Move,
        Resize,
        Crop,
        Pan,
    }

    private LongAnnotateWindow(
        byte[] bgra, int width, int height, double scale, IEnumerable<Annotation> annotations, string? historyId, byte[]? png)
    {
        _bgra = bgra;
        _width = width;
        _height = height;
        _scale = scale <= 0 ? 1 : scale;
        _historyId = historyId;
        _png = png;
        _source = new FrozenScreen { Index = 0, Bounds = new PixelBounds(0, 0, width, height), Scale = _scale, Bgra = bgra };
        _document.Load(annotations);

        _window = new Window { Title = Paths.ProductName + " 长图标注" };
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(false, false);
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        _window.AppWindow.SetPresenter(presenter);

        _view = new CanvasVirtualControl();
        _view.RegionsInvalidated += OnRegions;
        _view.PointerPressed += OnPressed;
        _view.DoubleTapped += OnDoubleTapped;
        _view.PointerWheelChanged += OnWheel;
        _view.PointerMoved += OnMoved;
        _view.PointerReleased += (_, _) => EndDrag();
        _view.PointerCaptureLost += (_, _) => EndDrag();
        AutomationProperties.SetName(_view, "长图");
        _editorLayer = new Canvas();
        _page = new Grid { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
        _page.Children.Add(_view);
        _page.Children.Add(_editorLayer);
        _scroller = new ScrollViewer
        {
            Content = _page,
            IsTabStop = true,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            ZoomMode = ZoomMode.Disabled,
        };
        _scroller.SizeChanged += (_, _) => Fit();

        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var kind in AnnotationKinds.All)
        {
            var button = SelectionOverlayWindow.ToolbarButton(
                SelectionOverlayWindow.ToolGlyph(kind),
                ShotKeys.Tip(AnnotationKinds.Title(kind), ShotKeys.IdFor(kind), SettingsService.Current.ScreenshotKeys),
                AnnotationKinds.Title(kind));
            button.Click += (_, _) => SelectTool(kind);
            _toolButtons[kind] = button;
            bar.Children.Add(button);
        }

        bar.Children.Add(Separator());
        var styleButton = SelectionOverlayWindow.ToolbarButton(string.Empty, "颜色和粗细", "颜色和粗细");
        _styleButton = styleButton;
        var flyout = new Flyout();
        flyout.Opening += (_, _) => flyout.Content = StylePicker(flyout);
        styleButton.Flyout = flyout;
        bar.Children.Add(styleButton);
        _cropButton = SelectionOverlayWindow.ToolbarButton(Glyphs.Crop, ShotKeys.Tip("裁剪", "crop", SettingsService.Current.ScreenshotKeys), "裁剪");
        _cropButton.Click += (_, _) => SetCropping(!_cropping);
        bar.Children.Add(_cropButton);
        _undoButton = SelectionOverlayWindow.ToolbarButton(Glyphs.Undo, ShotKeys.Tip("撤销", "undo", SettingsService.Current.ScreenshotKeys), "撤销");
        _undoButton.Click += (_, _) => Step(redo: false);
        _redoButton = SelectionOverlayWindow.ToolbarButton(Glyphs.Redo, ShotKeys.Tip("重做", "redo", SettingsService.Current.ScreenshotKeys), "重做");
        _redoButton.Click += (_, _) => Step(redo: true);
        bar.Children.Add(_undoButton);
        bar.Children.Add(_redoButton);
        bar.Children.Add(Separator());
        var close = SelectionOverlayWindow.ToolbarButton(Glyphs.Close, "关闭（Esc）", "关闭");
        close.Click += (_, _) => Escape();
        var save = SelectionOverlayWindow.ToolbarButton(Glyphs.Save, ShotKeys.Tip("保存到截图文件夹", "save", SettingsService.Current.ScreenshotKeys), "保存");
        save.Click += (_, _) => Save(saveAs: false);
        var copy = new Button
        {
            Content = "拷贝",
            Height = 32,
            Padding = new Thickness(14, 0, 14, 0),
            CornerRadius = new CornerRadius(16),
            Background = new SolidColorBrush(Theme.BrandPink),
            Foreground = new SolidColorBrush(Colors.White),
            AllowFocusOnInteraction = false,
        };
        ToolTipService.SetToolTip(copy, "拷贝（Enter）");
        copy.Click += (_, _) => Copy();
        bar.Children.Add(close);
        bar.Children.Add(save);
        bar.Children.Add(copy);

        _hint = new TextBlock
        {
            FontSize = 12,
            Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 8, 0, 0),
        };
        AutomationProperties.SetLiveSetting(_hint, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        ShowHint();

        var toolbar = new Border
        {
            Background = new SolidColorBrush(Theme.Shot.HudBackground),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6),
            Margin = new Thickness(0, 12, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = bar,
        };
        var root = new Grid
        {
            // 永远深色：长图后面是暗底（同 mac 的标注遮罩；不用透明窗口，透明那层在用户机器上是白的）。
            RequestedTheme = ElementTheme.Dark,
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 24, 24, 24)),
            Padding = new Thickness(24, 24, 24, 16),
        };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(toolbar, 1);
        Grid.SetRow(_hint, 2);
        root.Children.Add(_scroller);
        root.Children.Add(toolbar);
        root.Children.Add(_hint);
        root.KeyDown += OnKeyDown;
        // 空格在滚动框里是翻页：先在这里拦下当「按住平移」（打字时照常进输入框）
        root.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Space && _editor is null && !IsDown(VirtualKey.Control))
            {
                _spaceDown = true;
                e.Handled = true;
            }
        };
        root.KeyUp += (_, e) =>
        {
            if (e.Key == VirtualKey.Space)
            {
                _spaceDown = false;
            }
        };
        _window.Content = root;
        _window.Closed += (_, _) => Release();

        PInvoke.GetCursorPos(out var cursor);
        var display = Displays.AtPoint(cursor.X, cursor.Y);
        var work = display.Work;
        _origin = new PixelBounds(work.Left, work.Top, work.Left + Math.Min(width, work.Right - work.Left), work.Top + Math.Min(height, work.Bottom - work.Top));
        _window.AppWindow.MoveAndResize(new RectInt32(work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top));
        UpdateToolbar();
    }

    /// <summary>
    /// 开一扇长图标注。bgra / 宽高是没画标注的原图，annotations 是当初画的（长图像素坐标），historyId 是截图历史里那一条
    /// （出图时回写；没记历史时 null），png 是原图编好的（没画标注时直接用）。
    /// </summary>
    public static void Open(
        byte[] bgra, int width, int height, double scale, IEnumerable<Annotation> annotations, string? historyId, byte[]? png)
    {
        if (_instance is { } open)
        {
            open._window.Activate();
            return;
        }

        try
        {
            _instance = new LongAnnotateWindow(bgra, width, height, scale, annotations, historyId, png);
            _instance._window.Activate();
            _instance._scroller.Focus(FocusState.Programmatic);
            Log.Info($"screenshot.long-annotate {width}x{height}");
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.long-annotate-failed", ex);
            _instance = null;
            NoticeHost.Show("长图标注打不开", "可以先拷贝或钉出来看", NoticeTone.Warning);
        }
    }

    private static Border Separator() => new()
    {
        Width = 1,
        Height = 18,
        Margin = new Thickness(4, 0, 4, 0),
        Background = new SolidColorBrush(Theme.Shot.HudTextFaint),
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static bool IsDown(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>按框的宽适配（最大 1:1，同 mac 的默认缩放）：改页面大小，整个重画。</summary>
    private void Fit()
    {
        var available = _scroller.ActualWidth - 20; // 留出竖滚动条
        if (available <= 0)
        {
            return;
        }

        CommitText();
        _unit = _zoom is { } zoom ? zoom / _scale : Math.Min(1 / _scale, available / _width);
        _page.Width = _width * _unit;
        _page.Height = _height * _unit;
        _view.Width = _page.Width;
        _view.Height = _page.Height;
        _view.Invalidate();
    }

    private PointD ToImage(Windows.Foundation.Point point) => new(point.X / _unit, point.Y / _unit);

    private void OnRegions(CanvasVirtualControl sender, CanvasRegionsInvalidatedEventArgs args)
    {
        IReadOnlyList<Annotation> items = _draft is { } draft ? _document.Items.Append(draft).ToList() : _document.Items;
        if (_editingText is { } editing)
        {
            items = items.Where(annotation => annotation.Id != editing.Id).ToList();
        }
        foreach (var region in args.InvalidatedRegions)
        {
            using var ds = sender.CreateDrawingSession(region);
            var top = Math.Max(0, (int)Math.Floor(region.Y / _unit));
            var bottom = Math.Min(_height, (int)Math.Ceiling((region.Y + region.Height) / _unit));
            for (var index = top / BandRows; index * BandRows < bottom; index++)
            {
                DrawBand(ds, Band(sender, index, cache: true), index * BandRows, items, new PointD(0, 0), _unit, _scale * _unit);
            }

            DrawChrome(ds);
            DrawCrop(ds);
        }
    }

    /// <summary>
    /// 画一条：这一条的原图 + 裁在这一条里的标注（荧光笔垫的就是这一条的位图）。一条一条拼起来就是整张。
    /// origin / unit / strokeScale 同 AnnotationRenderer.Draw。
    /// </summary>
    private void DrawBand(
        CanvasDrawingSession ds, CanvasBitmap band, int bandTop, IReadOnlyList<Annotation> items,
        PointD origin, double unit, double strokeScale)
    {
        var rows = (int)band.SizeInPixels.Height;
        var destination = new Windows.Foundation.Rect(
            -origin.X * unit, (bandTop - origin.Y) * unit, _width * unit, rows * unit);
        using (ds.CreateLayer(1, destination))
        {
            ds.DrawImage(band, destination);
            AnnotationRenderer.Draw(
                ds, items, _source, band, origin, unit, strokeScale, new RectD(0, 0, _width, _height), new PointD(0, bandTop));
        }
    }

    /// <summary>第 index 条的位图；cache 时留着下次用（画面），不留时调用方用完放掉（出图）。</summary>
    private CanvasBitmap Band(ICanvasResourceCreator creator, int index, bool cache)
    {
        if (cache && _bands.TryGetValue(index, out var cached))
        {
            return cached;
        }

        var top = index * BandRows;
        var rows = Math.Min(BandRows, _height - top);
        var bytes = new byte[_width * rows * 4];
        Buffer.BlockCopy(_bgra, top * _width * 4, bytes, 0, bytes.Length);
        var bitmap = CanvasBitmap.CreateFromBytes(
            creator, bytes, _width, rows, DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Ignore);
        if (cache)
        {
            _bands[index] = bitmap;
        }

        return bitmap;
    }

    /// <summary>裁剪框（F11）：框外压暗，框是强调色的虚线（同截图遮罩）。</summary>
    private void DrawCrop(CanvasDrawingSession ds)
    {
        if (!_cropping || _cropDraft is not { } crop)
        {
            return;
        }

        var shade = Theme.Argb(150, 0, 0, 0);
        var (width, height) = ((float)(_width * _unit), (float)(_height * _unit));
        var (left, top) = ((float)(crop.X * _unit), (float)(crop.Y * _unit));
        var (right, bottom) = ((float)(crop.Right * _unit), (float)(crop.Bottom * _unit));
        ds.FillRectangle(0, 0, width, top, shade);
        ds.FillRectangle(0, bottom, width, height - bottom, shade);
        ds.FillRectangle(0, top, left, bottom - top, shade);
        ds.FillRectangle(right, top, width - right, bottom - top, shade);
        ds.DrawRectangle(left, top, right - left, bottom - top, Theme.Shot.Accent, 1.5f, SelectionDash);
    }

    /// <summary>工具栏「裁剪」/ X：开着时收起工具、取消选中；再按一次或 Esc 关掉。</summary>
    private void SetCropping(bool on)
    {
        CommitText();
        _cropping = on;
        _cropDraft = null;
        if (on)
        {
            _tool = null;
            _document.SelectedId = null;
        }

        _cropButton.Background = new SolidColorBrush(on
            ? Theme.Argb(64, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B)
            : Colors.Transparent);
        ShowHint(on ? "在长图上拖出要留下的那一段，松手就裁；Esc 取消" : null);
        UpdateToolbar();
        _view.Invalidate();
    }

    /// <summary>
    /// 裁成 area（长图像素）：原图换成那一块，标注跟着挪（裁到外面的照样留着、出图时画不到），条带位图重切，回到顶上。
    /// 撤销栈清空（ponytail，见文件头）。
    /// </summary>
    private void ApplyCrop(RectD area)
    {
        var rect = ImageCrop.Clamp(area, _width, _height);
        if (rect.Width == _width && rect.Height == _height)
        {
            SetCropping(false);
            return;
        }

        var shifted = _document.Items.Select(annotation => annotation.Offset(-rect.Left, -rect.Top)).ToList();
        _bgra = ImageCrop.Crop(_bgra, _width, _height, rect);
        _width = rect.Width;
        _height = rect.Height;
        _source = new FrozenScreen { Index = 0, Bounds = new PixelBounds(0, 0, _width, _height), Scale = _scale, Bgra = _bgra };
        _png = null;
        _cropped = true;
        _document.Load(shifted);
        foreach (var band in _bands.Values)
        {
            band.Dispose();
        }

        _bands.Clear();
        Log.Info($"screenshot.long-crop {_width}x{_height}");
        SetCropping(false);
        Fit();
        _scroller.ChangeView(0, 0, null, true);
    }

    /// <summary>选中那条的虚线框和手柄（同截图遮罩 DrawAnnotationChrome）。</summary>
    private void DrawChrome(CanvasDrawingSession ds)
    {
        if (_editor is not null || _document.Selected is not { } annotation)
        {
            return;
        }

        var accent = Theme.Shot.Accent;
        if (annotation.Kind is not (AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter))
        {
            var bounds = annotation.Bounds(_scale);
            ds.DrawRectangle(
                new Windows.Foundation.Rect(
                    bounds.X * _unit - 3, bounds.Y * _unit - 3, bounds.Width * _unit + 6, bounds.Height * _unit + 6),
                accent, 1, SelectionDash);
        }

        foreach (var (handle, point) in annotation.Handles(_scale))
        {
            var center = new System.Numerics.Vector2((float)(point.X * _unit), (float)(point.Y * _unit));
            var radius = handle == AnnotationHandle.Bend ? 3.5f : 4.5f;
            ds.FillCircle(center, radius, Theme.Shot.HandleFill);
            ds.DrawCircle(center, radius, accent, 1.5f);
        }
    }

    private AnnotationHandle? HandleAt(PointD point)
    {
        if (_document.Selected is not { } selected)
        {
            return null;
        }

        AnnotationHandle? best = null;
        var bestDistance = 7 / _unit;
        foreach (var (handle, at) in selected.Handles(_scale))
        {
            var distance = Math.Sqrt(Math.Pow(at.X - point.X, 2) + Math.Pow(at.Y - point.Y, 2));
            if (distance <= bestDistance)
            {
                bestDistance = distance;
                best = handle;
            }
        }

        return best;
    }

    // ---- 鼠标：按下时谁优先同截图遮罩（选中标注的手柄 → 标注本体 → 工具作画 → 取消选中）

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var current = e.GetCurrentPoint(_view);
        if (!current.Properties.IsLeftButtonPressed || _busy)
        {
            return;
        }

        e.Handled = true;
        if (_editor is not null)
        {
            CommitText();
            return;
        }

        _scroller.Focus(FocusState.Pointer);
        var point = ToImage(current.Position);
        if (_picking)
        {
            // 吸管（A1）：这一下只取色
            PickColor(point);
            return;
        }

        _start = point;
        _before = _document.Items;
        _lastViewPoint = current.Position;
        if (_spaceDown)
        {
            // 按住空格拖：平移（C1）
            _drag = Drag.Pan;
            _panFrom = e.GetCurrentPoint(_scroller).Position;
            _panOffset = (_scroller.HorizontalOffset, _scroller.VerticalOffset);
        }
        else if (_cropping)
        {
            _drag = Drag.Crop;
            _cropDraft = new RectD(point.X, point.Y, 0, 0);
        }
        else if (HandleAt(point) is { } handle && _document.Selected is { } selected)
        {
            _drag = Drag.Resize;
            _grabbed = selected;
            _handle = handle;
        }
        else if (Annotation.Topmost(_document.Items, point, _scale) is { } hit)
        {
            _document.SelectedId = hit.Id;
            _drag = Drag.Move;
            _grabbed = hit;
        }
        else if (_tool is AnnotationKind.Text)
        {
            _document.SelectedId = null;
            ShowEditor(point);
        }
        else if (_tool is AnnotationKind.Counter)
        {
            // 单击放序号，接着就能拖（松手时一共记一步撤销，同截图遮罩）。
            var counter = new Annotation
            {
                Kind = AnnotationKind.Counter, From = point, Number = Annotation.NextCounter(_document.Items), Style = _style,
            };
            _document.AppendLive(counter);
            _document.SelectedId = counter.Id;
            _drag = Drag.Move;
            _grabbed = counter;
        }
        else if (_tool is { } tool)
        {
            _document.SelectedId = null;
            _pen.Clear();
            _pen.Add(point);
            _draft = Annotation.Drawn(tool, point, point, false, _style);
            _drag = _draft is null ? Drag.None : Drag.Draw;
        }
        else
        {
            _document.SelectedId = null;
        }

        if (_drag != Drag.None)
        {
            _view.CapturePointer(e.Pointer);
        }

        UpdateToolbar();
        _view.Invalidate();
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag == Drag.None)
        {
            return;
        }

        if (_drag == Drag.Pan)
        {
            var now = e.GetCurrentPoint(_scroller).Position;
            _scroller.ChangeView(_panOffset.X - (now.X - _panFrom.X), _panOffset.Y - (now.Y - _panFrom.Y), null, true);
            return;
        }

        _lastViewPoint = e.GetCurrentPoint(_view).Position;
        UpdateEdgeScroll(e.GetCurrentPoint(_scroller).Position.Y);
        DragTo(ToImage(_lastViewPoint));
    }

    /// <summary>拖着的时候指针挪到了长图上的 point（OnMoved、自动滚每一拍都走这里）。</summary>
    private void DragTo(PointD point)
    {
        var shift = IsDown(VirtualKey.Shift);
        switch (_drag)
        {
            case Drag.Crop:
                _cropDraft = RectD.FromLtrb(
                    Math.Clamp(Math.Min(_start.X, point.X), 0, _width), Math.Clamp(Math.Min(_start.Y, point.Y), 0, _height),
                    Math.Clamp(Math.Max(_start.X, point.X), 0, _width), Math.Clamp(Math.Max(_start.Y, point.Y), 0, _height));
                break;
            case Drag.Draw when _draft is { Kind: AnnotationKind.Pen } pen:
                _pen.Add(point);
                _draft = pen with { Points = _pen.ToArray() };
                break;
            case Drag.Draw when _draft is { } draft:
                if (Annotation.Drawn(draft.Kind, _start, point, shift, _style, fromCenter: IsDown(VirtualKey.Menu)) is { } next)
                {
                    _draft = next with { Id = draft.Id };
                }

                break;
            case Drag.Move when _grabbed is { } grabbed:
                _document.Replace(grabbed.Offset(point.X - _start.X, point.Y - _start.Y));
                break;
            case Drag.Resize when _grabbed is { } grabbed:
                _document.Replace(grabbed.Resized(_handle, point, shift, _scale, fromCenter: IsDown(VirtualKey.Menu)));
                break;
        }

        _view.Invalidate();
    }

    private void EndDrag()
    {
        _edgeTimer?.Stop();
        var drag = _drag;
        _drag = Drag.None;
        _grabbed = null;
        if (drag == Drag.None)
        {
            return;
        }

        _view.ReleasePointerCaptures();
        if (drag == Drag.Pan)
        {
            return;
        }

        if (drag == Drag.Crop)
        {
            var crop = _cropDraft;
            _cropDraft = null;
            if (crop is { } area && area.Width >= RegionMath.MinimumSide && area.Height >= RegionMath.MinimumSide)
            {
                ApplyCrop(area);
            }

            _view.Invalidate();
            return;
        }

        if (drag == Drag.Draw && _draft is { } draft)
        {
            _draft = null;
            if (draft.IsMeaningful(_scale))
            {
                // 画完自动选中（同截图遮罩）。
                _document.Commit(_document.Items.Append(draft));
                _document.SelectedId = draft.Id;
            }
        }
        else
        {
            _document.RecordUndo(_before);
        }

        UpdateToolbar();
        _view.Invalidate();
    }

    // ---- 文字：点下的位置叠一个输入框，Esc / Ctrl+Enter / 点到外面收下（Enter 换行）

    private void ShowEditor(PointD point, Annotation? existing = null)
    {
        _editorPoint = point;
        _editingText = existing;
        var style = existing?.Style ?? _style;
        var editor = new TextBox
        {
            Text = existing?.Text ?? string.Empty,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            IsSpellCheckEnabled = false,
            MinWidth = 120,
            MinHeight = 0,
            Padding = new Thickness(0),
            FontSize = Math.Max(1, style.FontSize * _scale * _unit),
            FontFamily = new FontFamily(AnnotationRenderer.TextFontFamily),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(AnnotationRenderer.FromArgb(style.PaintArgb)),
        };
        if (existing is not null)
        {
            editor.Loaded += (_, _) => editor.SelectAll();
        }
        editor.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape || (e.Key == VirtualKey.Enter && IsDown(VirtualKey.Control)))
            {
                e.Handled = true;
                CommitText();
            }
        };
        editor.LostFocus += (_, _) => CommitText();
        editor.Loaded += (_, _) => editor.Focus(FocusState.Programmatic);
        // 输入框的边框是 1 DIP：字的左上角对到点下的位置。
        Canvas.SetLeft(editor, point.X * _unit - 1);
        Canvas.SetTop(editor, point.Y * _unit - 1);
        _editorLayer.Children.Add(editor);
        _editor = editor;
        ShowHint();
    }

    private void CommitText()
    {
        if (_editor is not { } editor)
        {
            return;
        }

        _editor = null;
        _editorLayer.Children.Remove(editor);
        var text = editor.Text.Replace("\r\n", "\n").Replace('\r', '\n');
        var existing = _editingText;
        _editingText = null;
        if (existing is not null)
        {
            // 双击重新编辑的（C1）：换掉原来那条（记一步撤销）；改成空的就删掉；没改什么不记
            if (string.IsNullOrWhiteSpace(text))
            {
                _document.Commit(_document.Items.Where(annotation => annotation.Id != existing.Id));
            }
            else if (text != existing.Text)
            {
                var changed = AnnotationRenderer.Measured(existing with { Text = text }, _scale);
                _document.Commit(_document.Items.Select(annotation => annotation.Id == existing.Id ? changed : annotation));
                _document.SelectedId = changed.Id;
            }
        }
        else if (!string.IsNullOrWhiteSpace(text))
        {
            var annotation = AnnotationRenderer.Measured(
                new Annotation
                {
                    Kind = AnnotationKind.Text,
                    Rect = new RectD(_editorPoint.X, _editorPoint.Y, 0, 0),
                    Text = text,
                    Style = _style,
                },
                _scale);
            _document.Commit(_document.Items.Append(annotation));
            _document.SelectedId = annotation.Id;
        }

        ShowHint();
        UpdateToolbar();
        _view.Invalidate();
        _scroller.Focus(FocusState.Programmatic);
    }

    // ---- 工具、样式、撤销

    /// <summary>换工具：先收下打着的字、取消选中，读这个工具上次的样式；再按一次同一个工具就收起。</summary>
    private void SelectTool(AnnotationKind? tool)
    {
        CommitText();
        _picking = false;
        _tool = tool == _tool ? null : tool;
        _document.SelectedId = null;
        if (_tool is { } kind)
        {
            _style = AnnotationStyle.Remembered(SettingsService.Current.ScreenshotToolStyles, kind);
        }

        UpdateToolbar();
        _view.Invalidate();
    }

    /// <summary>颜色和粗细：改选中的那条，没选中就改当前工具的（都记住，下次这个工具接着用）。</summary>
    private void Restyle(Func<AnnotationStyle, AnnotationStyle> change)
    {
        AnnotationKind kind;
        AnnotationStyle changed;
        if (_document.Selected is { } selected)
        {
            if (_document.RestyleSelected(
                    change,
                    annotation => annotation.Kind == AnnotationKind.Text ? AnnotationRenderer.Measured(annotation, _scale) : annotation)
                is not { } style)
            {
                return;
            }

            kind = selected.Kind;
            changed = style;
        }
        else if (_tool is { } tool)
        {
            kind = tool;
            changed = change(_style);
        }
        else
        {
            return;
        }

        var saved = SettingsService.Current.ScreenshotToolStyles ??= new Dictionary<string, string>();
        AnnotationStyle.Remember(saved, kind, changed);
        SettingsService.Save();
        if (kind == _tool)
        {
            _style = changed;
        }

        UpdateToolbar();
        _view.Invalidate();
    }

    /// <summary>样式弹层：一排 8 色、一排三档粗细（每次打开按选中的那条 / 当前工具现画）。</summary>
    private StackPanel StylePicker(Flyout flyout)
    {
        var kind = _document.Selected?.Kind ?? _tool ?? AnnotationKind.Rectangle;
        var shown = _document.Selected?.Style ?? _style;
        var panel = new StackPanel { Spacing = 10 };
        if (AnnotationKinds.HasColor(kind))
        {
            var colors = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            for (var index = 0; index < AnnotationPalette.Argb.Length; index++)
            {
                var color = index;
                var swatch = new Button
                {
                    Width = 24,
                    Height = 24,
                    MinWidth = 0,
                    MinHeight = 0,
                    Padding = new Thickness(0),
                    CornerRadius = new CornerRadius(12),
                    Background = new SolidColorBrush(AnnotationRenderer.ColorOf(index)),
                    BorderBrush = new SolidColorBrush(Colors.White),
                    BorderThickness = new Thickness(shown.Color == index && shown.Custom is null ? 2 : 0.5),
                };
                AutomationProperties.SetName(swatch, AnnotationPalette.Titles[index]);
                swatch.Click += (_, _) =>
                {
                    Restyle(style => style with { Color = color, Custom = null });
                    flyout.Hide();
                };
                colors.Children.Add(swatch);
            }

            // 取过色时那个颜色的点 + 吸管（A1）
            if (shown.Custom is { } rgb)
            {
                var custom = new Button
                {
                    Width = 24,
                    Height = 24,
                    MinWidth = 0,
                    MinHeight = 0,
                    Padding = new Thickness(0),
                    CornerRadius = new CornerRadius(12),
                    Background = new SolidColorBrush(AnnotationRenderer.FromArgb(0xFF000000u | (uint)rgb)),
                    BorderBrush = new SolidColorBrush(Colors.White),
                    BorderThickness = new Thickness(2),
                };
                AutomationProperties.SetName(custom, "取的颜色");
                ToolTipService.SetToolTip(custom, $"取的颜色 #{rgb:X6}");
                colors.Children.Add(custom);
            }

            var picker = new Button
            {
                Content = new FontIcon { Glyph = Glyphs.Eyedropper, FontSize = 14 },
                Width = 32,
                Height = 24,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(0),
            };
            AutomationProperties.SetName(picker, "从长图里取色");
            ToolTipService.SetToolTip(picker, "从长图里取色");
            picker.Click += (_, _) =>
            {
                flyout.Hide();
                _picking = true;
                ShowHint("单击长图上一点取它的颜色，Esc 不取");
            };
            colors.Children.Add(picker);
            panel.Children.Add(colors);
        }

        if (kind == AnnotationKind.Text)
        {
            // 文字：A− 字号 A+，点数字选 12–72（A1，同截图遮罩 S15）
            var sizes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var smaller = new Button { Content = "A−" };
            AutomationProperties.SetName(smaller, "字号小一档");
            smaller.Click += (_, _) =>
            {
                Restyle(style => style.Stepped(-1, AnnotationKind.Text));
                flyout.Content = StylePicker(flyout);
            };
            var number = new Button
            {
                Content = shown.FontSize.ToString("0", System.Globalization.CultureInfo.InvariantCulture),
                MinWidth = 48,
            };
            AutomationProperties.SetName(number, "字号");
            var menu = new MenuFlyout();
            foreach (var value in AnnotationStyle.FontSizes)
            {
                var item = new ToggleMenuFlyoutItem
                {
                    Text = value.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    IsChecked = Math.Abs(shown.FontSize - value) < 0.01,
                };
                item.Click += (_, _) =>
                {
                    Restyle(style => style with { TextSize = value });
                    flyout.Hide();
                };
                menu.Items.Add(item);
            }

            number.Flyout = menu;
            var larger = new Button { Content = "A+" };
            AutomationProperties.SetName(larger, "字号大一档");
            larger.Click += (_, _) =>
            {
                Restyle(style => style.Stepped(1, AnnotationKind.Text));
                flyout.Content = StylePicker(flyout);
            };
            sizes.Children.Add(smaller);
            sizes.Children.Add(number);
            sizes.Children.Add(larger);
            panel.Children.Add(sizes);
        }
        else
        {
            var weights = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var titles = AnnotationKinds.WeightTitles(kind);
            for (var index = 0; index < titles.Length; index++)
            {
                var weight = index;
                var button = new Button
                {
                    Content = titles[index],
                    FontWeight = shown.Weight == index ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                };
                button.Click += (_, _) =>
                {
                    // 点三档清掉拖角改过的序号直径（同截图遮罩 S19）
                    Restyle(style => style with { Weight = weight, Diameter = null });
                    flyout.Hide();
                };
                weights.Children.Add(button);
            }

            panel.Children.Add(weights);
        }

        if (_document.Selected is { Kind: AnnotationKind.Counter } counter)
        {
            // 选中序号：改编号（1–99，A1，同截图遮罩 S15）
            var numbers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var minus = new Button { Content = "−" };
            AutomationProperties.SetName(minus, "编号减一");
            minus.Click += (_, _) =>
            {
                Renumber(-1);
                flyout.Content = StylePicker(flyout);
            };
            var plus = new Button { Content = "+" };
            AutomationProperties.SetName(plus, "编号加一");
            plus.Click += (_, _) =>
            {
                Renumber(1);
                flyout.Content = StylePicker(flyout);
            };
            numbers.Children.Add(new TextBlock { Text = "编号", VerticalAlignment = VerticalAlignment.Center });
            numbers.Children.Add(minus);
            numbers.Children.Add(new TextBlock
            {
                Text = counter.Number.ToString(System.Globalization.CultureInfo.InvariantCulture),
                MinWidth = 22,
                TextAlignment = TextAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
            numbers.Children.Add(plus);
            panel.Children.Add(numbers);
        }

        // 选项（C1，同截图遮罩的样式托盘）：空心 / 实心、无底 / 描边 / 底色、像素 / 模糊……没有的工具不出这一排
        var optionTitles = AnnotationKinds.OptionTitles(kind);
        if (optionTitles.Length > 0)
        {
            var options = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            foreach (var index in AnnotationKinds.OptionOrder(kind))
            {
                var option = index;
                var button = new Button
                {
                    Content = optionTitles[index],
                    FontWeight = shown.Option == index ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                };
                AutomationProperties.SetName(button, optionTitles[index]);
                button.Click += (_, _) =>
                {
                    Restyle(style => style with { Option = option });
                    flyout.Hide();
                };
                options.Children.Add(button);
            }

            if (kind == AnnotationKind.Mosaic)
            {
                // 打码最后一个「自动」（A1，同截图遮罩 S17）
                var auto = new Button { Content = "自动" };
                AutomationProperties.SetName(auto, "自动打码：手机号、邮箱、卡号、身份证号");
                ToolTipService.SetToolTip(auto, "自动打码：手机号、邮箱、卡号、身份证号");
                auto.Click += (_, _) =>
                {
                    flyout.Hide();
                    AutoRedact();
                };
                options.Children.Add(auto);
            }

            panel.Children.Add(options);
        }

        return panel;
    }

    /// <summary>选中的序号改编号（1–99），记一步撤销（A1）。</summary>
    private void Renumber(int delta)
    {
        if (_document.Selected is not { Kind: AnnotationKind.Counter } counter || _drag != Drag.None)
        {
            return;
        }

        var next = Math.Clamp(counter.Number + delta, 1, 99);
        if (next == counter.Number)
        {
            return;
        }

        _document.Commit(_document.Items.Select(item => item.Id == counter.Id ? item with { Number = next } : item));
        UpdateToolbar();
        _view.Invalidate();
    }

    /// <summary>吸管：取长图上 point（长图像素）的颜色给样式（取的是原图，不含标注；A1）。</summary>
    private void PickColor(PointD point)
    {
        _picking = false;
        var x = Math.Clamp((int)point.X, 0, _width - 1);
        var y = Math.Clamp((int)point.Y, 0, _height - 1);
        var index = (y * _width + x) * 4;
        var rgb = (_bgra[index + 2] << 16) | (_bgra[index + 1] << 8) | _bgra[index];
        FlashHint($"取了颜色 #{rgb:X6}");
        Restyle(style => style with { Custom = rgb });
    }

    private void AutoRedact()
    {
        if (_busy || _cropping || _redaction is { IsCompleted: false })
        {
            return;
        }

        _redaction = RedactAsync();
    }

    /// <summary>
    /// 自动打码（A1）：长图切成几条一条条识字（Redaction.Slices：每条 4000 行、叠 200 行，各认自己管的那一段），
    /// 手机号、邮箱、卡号、身份证号各加一块打码，一起记一步撤销。识字途中长图被裁过就作废；拖着标注就等松手再落。
    /// </summary>
    private async Task RedactAsync()
    {
        CommitText();
        var bgra = _bgra;
        var width = _width;
        var height = _height;
        ShowHint("正在找手机号、邮箱、卡号、身份证号…");
        string message;
        try
        {
            var found = new List<RectD>();
            foreach (var (top, rows, ownTop, ownBottom) in Redaction.Slices(height, 4000, 200))
            {
                var slice = new byte[width * rows * 4];
                Buffer.BlockCopy(bgra, top * width * 4, slice, 0, slice.Length);
                var (_, lines) = await OcrService.RecognizeAsync(slice, width, rows, joined: false);
                foreach (var box in Redaction.Boxes(lines))
                {
                    var moved = box.Offset(0, top);
                    var middle = moved.Y + moved.Height / 2;
                    if (middle >= ownTop && middle < ownBottom)
                    {
                        found.Add(moved);
                    }
                }
            }

            if (!ReferenceEquals(bgra, _bgra))
            {
                message = "长图裁过了，这次没打码";
            }
            else
            {
                var existing = _document.Items.Where(item => item.Kind == AnnotationKind.Mosaic).Select(item => item.Rect);
                var areas = Redaction.Areas(found, new RectD(0, 0, width, height), existing, 3 * _scale, 2 * _scale);
                while (_drag != Drag.None)
                {
                    await Task.Delay(50);
                }

                if (areas.Count == 0)
                {
                    message = "没找到手机号、邮箱、卡号、身份证号";
                }
                else
                {
                    var style = _tool == AnnotationKind.Mosaic ? _style : AnnotationStyle.DefaultFor(AnnotationKind.Mosaic);
                    var added = areas.Select(box => new Annotation { Kind = AnnotationKind.Mosaic, Rect = box, Style = style }).ToList();
                    _document.Commit(_document.Items.Concat(added));
                    UpdateToolbar();
                    _view.Invalidate();
                    message = $"打码了 {added.Count} 处";
                }

                Log.Info($"screenshot.long-auto-redact count={areas.Count} slices={Redaction.Slices(height, 4000, 200).Count}");
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.long-auto-redact-failed {ex.GetType().Name}");
            message = "识字没成，这次没打码";
        }

        FlashHint(message);
    }

    /// <summary>底下那行先说一句，2.5 秒后（没被别的话换掉的话）换回按键提示。</summary>
    private void FlashHint(string text)
    {
        ShowHint(text);
        var timer = _window.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(2500);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_hint.Text == text)
            {
                ShowHint();
            }
        };
        timer.Start();
    }

    // ---- 缩放、双击文字、平移、自动滚（C1）

    /// <summary>换缩放档位：null = 适合宽度。画面中间那一点换档后还在中间。</summary>
    private void SetZoom(double? zoom)
    {
        CommitText();
        var viewport = (_scroller.ViewportWidth, _scroller.ViewportHeight);
        var center = ((_scroller.HorizontalOffset + viewport.ViewportWidth / 2) / _unit,
            (_scroller.VerticalOffset + viewport.ViewportHeight / 2) / _unit);
        _zoom = zoom;
        Fit();
        _scroller.UpdateLayout();
        _scroller.ChangeView(
            Math.Max(0, center.Item1 * _unit - viewport.ViewportWidth / 2),
            Math.Max(0, center.Item2 * _unit - viewport.ViewportHeight / 2), null, true);
        ShowHint($"缩放 {ZoomSteps.Percent(_unit * _scale)} · Ctrl+0 适合宽度 · Ctrl+1 实际大小");
    }

    private void Zoom(bool up) => SetZoom(ZoomSteps.Next(_unit * _scale, up));

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!IsDown(VirtualKey.Control))
        {
            return;
        }

        e.Handled = true;
        Zoom(up: e.GetCurrentPoint(_view).Properties.MouseWheelDelta > 0);
    }

    /// <summary>双击文字：重新编辑（同截图遮罩 E12）。第一下已经把它选中、开始拖了，这里收掉那一下再开输入框。</summary>
    private void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (_busy || _cropping || _editor is not null)
        {
            return;
        }

        var point = ToImage(e.GetPosition(_view));
        if (Annotation.Topmost(_document.Items, point, _scale) is { Kind: AnnotationKind.Text } text)
        {
            e.Handled = true;
            EndDrag();
            _document.SelectedId = null;
            ShowEditor(new PointD(text.Rect.X, text.Rect.Y), text);
            _view.Invalidate();
        }
    }

    /// <summary>拖着画 / 挪 / 裁的时候指针到了滚动框上下边 32 DIP 以内：开始自动滚，越靠边越快；离开边停。</summary>
    private void UpdateEdgeScroll(double pointerY)
    {
        if (_drag is Drag.None or Drag.Pan)
        {
            _edgeTimer?.Stop();
            return;
        }

        const double band = 32;
        var height = _scroller.ViewportHeight;
        var speed = pointerY < band ? -(band - Math.Max(0, pointerY)) : pointerY > height - band
            ? band - Math.Max(0, height - pointerY)
            : 0;
        if (speed == 0)
        {
            _edgeTimer?.Stop();
            return;
        }

        _edgeSpeed = speed;
        if (_edgeTimer is null)
        {
            _edgeTimer = _window.DispatcherQueue.CreateTimer();
            _edgeTimer.Interval = TimeSpan.FromMilliseconds(16);
            _edgeTimer.Tick += (_, _) => EdgeTick();
        }

        if (!_edgeTimer.IsRunning)
        {
            _edgeTimer.Start();
        }
    }

    private double _edgeSpeed;

    /// <summary>自动滚一拍：滚多少，指针在长图上的位置就跟着往下 / 往上挪多少，接着当成一次拖动。</summary>
    private void EdgeTick()
    {
        if (_drag is Drag.None or Drag.Pan)
        {
            _edgeTimer?.Stop();
            return;
        }

        var before = _scroller.VerticalOffset;
        var target = Math.Clamp(before + _edgeSpeed, 0, _scroller.ScrollableHeight);
        if (Math.Abs(target - before) < 0.5)
        {
            return;
        }

        _scroller.ChangeView(null, target, null, true);
        _lastViewPoint = new Windows.Foundation.Point(_lastViewPoint.X, _lastViewPoint.Y + (target - before));
        DragTo(ToImage(_lastViewPoint));
        _view.Invalidate();
    }

    private void Step(bool redo)
    {
        CommitText();
        if (_drag != Drag.None)
        {
            return;
        }

        _draft = null;
        if (redo ? _document.Redo() : _document.Undo())
        {
            UpdateToolbar();
            _view.Invalidate();
        }
    }

    private void UpdateToolbar()
    {
        if (_cropping && _tool is not null)
        {
            SetCropping(false);
        }

        foreach (var (kind, button) in _toolButtons)
        {
            button.Background = new SolidColorBrush(kind == _tool
                ? Theme.Argb(64, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B)
                : Colors.Transparent);
        }

        _undoButton.IsEnabled = _document.CanUndo;
        _redoButton.IsEnabled = _document.CanRedo;
    }

    private void ShowHint(string? text = null)
        => _hint.Text = text ?? (_editor is not null
            ? "Esc 或 Ctrl+Enter 收下文字，Enter 换行"
            : string.Join(" · ", new[]
            {
                "Enter 拷贝",
                ShotKeys.Current("save", SettingsService.Current.ScreenshotKeys) is { } save ? $"{save.Display} 保存" : null,
                ShotKeys.ToolsAreDefault(SettingsService.Current.ScreenshotKeys) ? "1–0 标注" : null,
                ShotKeys.Current("crop", SettingsService.Current.ScreenshotKeys) is { } crop ? $"{crop.Display} 裁剪" : null,
                "Ctrl+= / Ctrl+- 缩放", "空格拖动平移", "Esc 关闭",
            }.OfType<string>()));

    // ---- 键盘

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_editor is not null || _busy)
        {
            return;
        }

        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        // 截图时的键（PLAN-v18 S3，和截图框选同一份）：十种工具、拷贝、保存、另存为、撤销、重做、裁剪
        var modifiers = (control ? HotKeyModifiers.Control : 0) | (IsDown(VirtualKey.Menu) ? HotKeyModifiers.Alt : 0) |
                        (shift ? HotKeyModifiers.Shift : 0);
        if (!ShotKeys.IsReserved(new ShotKeyBinding((uint)e.Key, modifiers)) &&
            ShotKeys.Matching((uint)e.Key, modifiers, SettingsService.Current.ScreenshotKeys) is { Up: false } shot)
        {
            switch (shot.Id)
            {
                case var id when AnnotationKinds.Parse(id) is { } tool:
                    SelectTool(tool);
                    break;
                case "copy":
                    Copy();
                    break;
                case "save" or "saveAs":
                    Save(saveAs: shot.Id == "saveAs");
                    break;
                case "undo" or "redo":
                    Step(redo: shot.Id == "redo");
                    break;
                case "crop":
                    SetCropping(!_cropping);
                    break;
                default:
                    return;
            }

            e.Handled = true;
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Number0 or VirtualKey.NumberPad0 when control:
                SetZoom(null);
                break;
            case VirtualKey.Number1 or VirtualKey.NumberPad1 when control:
                SetZoom(1);
                break;
            case (VirtualKey)187 or VirtualKey.Add when control: // VK_OEM_PLUS（= / + 那个键）
                Zoom(up: true);
                break;
            case (VirtualKey)189 or VirtualKey.Subtract when control: // VK_OEM_MINUS
                Zoom(up: false);
                break;
            case VirtualKey.Escape:
                Escape();
                break;
            case VirtualKey.Enter:
                Copy();
                break;
            case VirtualKey.Z when control && shift:
                // 重做的另一个键（固定）
                Step(redo: true);
                break;
            case VirtualKey.Delete or VirtualKey.Back when _drag == Drag.None:
                if (_document.DeleteSelected())
                {
                    UpdateToolbar();
                    _view.Invalidate();
                }

                break;
            default:
                return;
        }

        e.Handled = true;
    }

    /// <summary>Esc：选着工具先收起工具；画过标注时第一下只提示，2 秒内再按一次才关（同 mac 的「再按一次放弃」）。</summary>
    private void Escape()
    {
        if (_picking)
        {
            _picking = false;
            ShowHint();
            return;
        }

        if (_cropping)
        {
            SetCropping(false);
            return;
        }

        if (_tool is not null)
        {
            SelectTool(null);
            return;
        }

        var now = Environment.TickCount64;
        if (_document.CanUndo && now - _escapeArmedAt > 2000)
        {
            _escapeArmedAt = now;
            ShowHint("再按一次 Esc 放弃这次的标注");
            return;
        }

        _window.Close();
    }

    // ---- 出图

    /// <summary>拼成 PNG：一条条画（原图 + 标注）再拼起来；没画标注、手里有原图时直接用原图。</summary>
    private async Task<byte[]?> ComposeAsync()
    {
        CommitText();
        if (_redaction is { IsCompleted: false } redaction)
        {
            // 自动打码还在识字：等它落下再出图（A1）
            await redaction;
        }

        if (_document.Items.Count == 0 && _png is not null)
        {
            return _png;
        }

        try
        {
            var device = CanvasDevice.GetSharedDevice();
            var output = new byte[_width * _height * 4];
            for (var top = 0; top < _height; top += BandRows)
            {
                using var band = Band(device, top / BandRows, cache: false);
                var rows = (int)band.SizeInPixels.Height;
                using var target = new CanvasRenderTarget(device, _width, rows, 96);
                using (var ds = target.CreateDrawingSession())
                {
                    DrawBand(ds, band, top, _document.Items, new PointD(0, top), 1, _scale);
                }

                var pixels = target.GetPixelBytes();
                Buffer.BlockCopy(pixels, 0, output, top * _width * 4, Math.Min(pixels.Length, output.Length - top * _width * 4));
            }

            return await ImageCodec.BgraToPngAsync(_width, _height, output);
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.long-export-failed", ex);
            return null;
        }
    }

    private async void Copy()
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        ShowHint("正在出图…");
        var png = await ComposeAsync();
        if (png is not null && await ScreenshotOutput.CopyPngAsync(png, _width, _height))
        {
            WriteBack(png, null);
            _window.Close();
            ShotFeedback.Delivered(png, _origin);
            return;
        }

        _busy = false;
        ShowHint();
        NoticeHost.Show("没能拷贝", "再试一次，或者先保存", NoticeTone.Warning);
    }

    private async void Save(bool saveAs)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        ShowHint("正在出图…");
        var png = await ComposeAsync();
        var path = png is null
            ? null
            : saveAs
                ? await ScreenshotOutput.SavePngAsAsync(_window.AppWindow, png)
                : await ScreenshotOutput.QuickSavePngAsync(png);
        if (png is not null && path is not null)
        {
            WriteBack(png, path);
            _window.Close();
            ShotFeedback.Delivered(png, _origin, path);
            return;
        }

        // 另存为点了取消、或者没存成（QuickSavePngAsync 自己报了原因）：留在这里接着标。
        _busy = false;
        ShowHint();
    }

    /// <summary>
    /// 回写截图历史的那一条：标注和成品换新的（同截图遮罩改标注）。画了马赛克时原图换成打过码的、标注里不带马赛克
    /// （第四轮体检 E6）。两个调用的地方回写完都关窗口，所以直接打在 _bgra 上，不另拷一份几百 MB 的长图。
    /// </summary>
    private void WriteBack(byte[] png, string? savedPath)
    {
        if (_historyId is not { } id || ShotHistory.Instance is not { } history)
        {
            return;
        }

        var annotations = _document.Items.Where(annotation => annotation.Kind != AnnotationKind.Mosaic)
            .Select(annotation => ShotAnnotations.ToData(annotation, 0, 0)).ToList();
        // 画了马赛克、或者裁过（F11）：原图换成手里这份（打过码 / 裁过的），裁过时宽高跟着改。
        if (_cropped || _document.Items.Any(annotation => annotation.Kind == AnnotationKind.Mosaic))
        {
            var bgra = _bgra;
            AnnotationRenderer.BurnMosaics(_document.Items, _source, _scale, bgra, _width, _height, 0, 0);
            var (width, height) = (_width, _height);
            var size = _cropped ? (width, height) : ((int, int)?)null;
            _ = WriteMaskedAsync();

            async Task WriteMaskedAsync()
            {
                if (await ImageCodec.BgraToPngAsync(width, height, bgra) is { } masked)
                {
                    history.UpdateAnnotations(id, annotations, png, masked, size);
                }
            }
        }
        else
        {
            history.UpdateAnnotations(id, annotations, png);
        }

        if (savedPath is not null)
        {
            history.MarkSaved(id, savedPath);
        }
    }

    /// <summary>
    /// 自检（Debug 的 --long-annotate-probe=行数）：造一张条纹长图、带几条跨 4096 行接缝的标注打开，
    /// 开头、接缝、滚到底各拍一张窗口（WGC），再出一次图量耗时；不写剪贴板、不碰截图历史，拍完关掉。
    /// </summary>
    internal static async Task ProbeAsync(int rows, string directory)
    {
        const int width = 1200;
        var bgra = new byte[width * rows * 4];
        for (var y = 0; y < rows; y++)
        {
            var shade = (byte)(y / 64 % 2 == 0 ? 240 : 200);
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                bgra[offset] = shade;
                bgra[offset + 1] = (byte)(y * 255 / rows);
                bgra[offset + 2] = (byte)(x * 255 / width);
                bgra[offset + 3] = 255;
            }
        }

        var seam = Math.Min(BandRows, rows / 2);
        var items = new[]
        {
            Annotation.Drawn(AnnotationKind.Rectangle, new PointD(100, seam - 200), new PointD(500, seam + 200), false,
                AnnotationStyle.DefaultFor(AnnotationKind.Rectangle)),
            Annotation.Drawn(AnnotationKind.Highlighter, new PointD(600, seam - 150), new PointD(1100, seam + 150), false,
                AnnotationStyle.DefaultFor(AnnotationKind.Highlighter)),
            Annotation.Drawn(AnnotationKind.Mosaic, new PointD(100, seam - 100), new PointD(500, seam + 100), false,
                AnnotationStyle.DefaultFor(AnnotationKind.Mosaic)),
            AnnotationRenderer.Measured(
                new Annotation
                {
                    Kind = AnnotationKind.Text, Rect = new RectD(120, 120, 0, 0), Text = "原来的字",
                    Style = AnnotationStyle.DefaultFor(AnnotationKind.Text),
                },
                1),
        }.OfType<Annotation>().ToList();
        Directory.CreateDirectory(directory);
        Open(bgra, width, rows, 1, items, null, null);
        if (_instance is not { } window)
        {
            Log.Warn("long-annotate.probe not-open");
            return;
        }

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window._window);
        await Task.Delay(1500);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-top.png"));
        window._scroller.ChangeView(null, seam * window._unit - 300, null, true);
        await Task.Delay(1200);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-seam.png"));
        window._scroller.ChangeView(null, window._scroller.ScrollableHeight, null, true);
        await Task.Delay(1200);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-bottom.png"));
        var started = System.Diagnostics.Stopwatch.StartNew();
        var png = await window.ComposeAsync();
        Log.Info($"long-annotate.probe rows={rows} export-ms={started.ElapsedMilliseconds} png={png?.Length ?? 0} bands={window._bands.Count}");
        if (png is not null)
        {
            await File.WriteAllBytesAsync(Path.Combine(directory, "long-annotate-export.png"), png);
        }

        // C1：缩放档位（实际大小、往下两档、回到适合宽度）、双击文字重新编辑、拖到窗口下边自动滚。
        window._scroller.ChangeView(null, 0, null, true);
        await Task.Delay(300);
        var fit = window._unit;
        window.SetZoom(1);
        await Task.Delay(500);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-zoom-100.png"));
        var actual = window._unit;
        window.Zoom(up: false);
        window.Zoom(up: false);
        await Task.Delay(300);
        var smaller = window._unit;
        window.SetZoom(null);
        Log.Info($"long-annotate.probe zoom fit={fit:F3} actual={actual:F3} twoDown={smaller:F3} back={window._unit:F3}");

        var text = window._document.Items.First(item => item.Kind == AnnotationKind.Text);
        window.ShowEditor(new PointD(text.Rect.X, text.Rect.Y), text);
        await Task.Delay(300);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-text-reedit.png"));
        window._editor!.Text = "改过的字";
        window.CommitText();
        var texts = window._document.Items.Where(item => item.Kind == AnnotationKind.Text).ToList();
        Log.Info($"long-annotate.probe reedit texts={texts.Count} same-id={texts[0].Id == text.Id} changed={texts[0].Text == "改过的字"} undo={window._document.CanUndo}");

        window._drag = Drag.Draw;
        window._start = new PointD(200, 300);
        window._draft = Annotation.Drawn(AnnotationKind.Rectangle, window._start, window._start, false, window._style);
        window._lastViewPoint = new Windows.Foundation.Point(400, window._scroller.ViewportHeight - 8);
        window.UpdateEdgeScroll(window._scroller.ViewportHeight - 8);
        await Task.Delay(1000);
        var scrolled = window._scroller.VerticalOffset;
        var draftBottom = window._draft?.Rect.Bottom ?? 0;
        window.EndDrag();
        Log.Info($"long-annotate.probe edge-scroll offset={scrolled:F0} draftBottom={draftBottom:F0} items={window._document.Items.Count}");

        // PLAN-v20 A1：自动打码（号码画在第一条、两条相叠的那一截、最后一条里）、吸管、改编号、样式弹层。
        await window.ProbeStyleExtrasAsync(hwnd, directory);

        // 裁剪（F11）：裁掉头尾各 500 行、左右各 100 列，接缝处的标注跟着挪，出图量尺寸。
        window.SetCropping(true);
        window._cropDraft = new RectD(100, 500, width - 200, rows - 1000);
        await Task.Delay(400);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-crop-drag.png"));
        window.ApplyCrop(window._cropDraft.Value);
        await Task.Delay(800);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-cropped.png"));
        var croppedPng = await window.ComposeAsync();
        var first = window._document.Items.FirstOrDefault();
        Log.Info($"long-annotate.probe cropped={window._width}x{window._height} png={croppedPng?.Length ?? 0} " +
                 $"firstAnnotation={first?.Rect.X:F0},{first?.Rect.Y:F0} cropped-flag={window._cropped}");
        if (croppedPng is not null)
        {
            await File.WriteAllBytesAsync(Path.Combine(directory, "long-annotate-cropped-export.png"), croppedPng);
        }

        window._window.Close();
    }

    /// <summary>
    /// 自检（PLAN-v20 A1）：在长图上画三段号码（手机号、邮箱、身份证号；第二段压在第一、二条识字相叠的那一截上），点「自动」，
    /// 看盖了几块（每段一块、不重复）；吸管取一个已知颜色的点；放一个序号改编号；打开样式弹层（文字 / 序号 / 打码）各截一张。
    /// </summary>
    private async Task ProbeStyleExtrasAsync(IntPtr hwnd, string directory)
    {
        var samples = new (int Row, string Text)[]
        {
            (300, "电话 138 0013 8000"),
            (Math.Min(3870, _height - 200), "邮箱 zhang.xm@example.com"),
            (Math.Max(_height - 1000, 400), "身份证 11010519491231002X"),
        };
        var device = CanvasDevice.GetSharedDevice();
        foreach (var (row, text) in samples)
        {
            using var target = new CanvasRenderTarget(device, 700, 64, 96);
            using (var ds = target.CreateDrawingSession())
            {
                ds.Clear(Colors.White);
                ds.DrawText(text, 12, 10, Colors.Black, new Microsoft.Graphics.Canvas.Text.CanvasTextFormat { FontSize = 30, FontFamily = "Segoe UI" });
            }

            var pixels = target.GetPixelBytes();
            for (var y = 0; y < 64 && row + y < _height; y++)
            {
                Buffer.BlockCopy(pixels, y * 700 * 4, _bgra, ((row + y) * _width + 40) * 4, 700 * 4);
            }
        }

        _bands.Clear();
        _view.Invalidate();
        var before = _document.Items.Count(item => item.Kind == AnnotationKind.Mosaic);
        AutoRedact();
        if (_redaction is { } redaction)
        {
            await redaction;
        }

        var masks = _document.Items.Where(item => item.Kind == AnnotationKind.Mosaic).Skip(before).ToList();
        // 每段号码：拿一条 64 行的窄条单独识字得到号码的框（窄条不会被判成斜的），打码要把它整个盖住
        var hits = 0;
        foreach (var (row, _) in samples)
        {
            var strip = new byte[_width * 64 * 4];
            Buffer.BlockCopy(_bgra, row * _width * 4, strip, 0, strip.Length);
            var (_, seen) = await OcrService.RecognizeAsync(strip, _width, 64, joined: false);
            var boxes = Redaction.Boxes(seen).Select(box => box.Offset(0, row)).ToList();
            if (boxes.Count > 0 && boxes.All(box => masks.Any(mask =>
                    mask.Rect.X <= box.X && mask.Rect.Y <= box.Y && mask.Rect.Right >= box.Right && mask.Rect.Bottom >= box.Bottom)))
            {
                hits++;
            }
        }

        Log.Info($"long-annotate.probe auto-redact added={masks.Count} samples={samples.Length} covered={hits} " +
                 $"slices={Redaction.Slices(_height, 4000, 200).Count} hint={_hint.Text}");
        var redacted = await ComposeAsync();
        if (redacted is not null)
        {
            await File.WriteAllBytesAsync(Path.Combine(directory, "long-annotate-redacted-export.png"), redacted);
        }

        _scroller.ChangeView(null, Math.Max(0, samples[1].Row * _unit - 200), null, true);
        await Task.Delay(800);
        await WindowShot.SaveAsync(hwnd, Path.Combine(directory, "long-annotate-auto-redact.png"));

        // 吸管：取长图上 (60, 10) 那一点（渐变底，颜色已知）
        SelectTool(AnnotationKind.Rectangle);
        var index = (10 * _width + 60) * 4;
        var expected = (_bgra[index + 2] << 16) | (_bgra[index + 1] << 8) | _bgra[index];
        _picking = true;
        PickColor(new PointD(60, 10));
        Log.Info($"long-annotate.probe eyedropper custom={_style.Custom:X6} expected={expected:X6} ok={_style.Custom == expected}");

        // 序号：放一个、选中、编号加二减一
        var counter = new Annotation
        {
            Kind = AnnotationKind.Counter, From = new PointD(600, 200), Number = 1,
            Style = AnnotationStyle.DefaultFor(AnnotationKind.Counter),
        };
        {
            _document.Commit(_document.Items.Append(counter));
            _document.SelectedId = counter.Id;
            Renumber(1);
            Renumber(1);
            Renumber(-1);
            var number = _document.Items.First(item => item.Id == counter.Id).Number;
            Log.Info($"long-annotate.probe renumber number={number} ok={number == 2}");
        }

        // 样式弹层：选中序号（多「编号」一行）、文字工具（A− 字号 A+）、打码工具（多「自动」）
        _scroller.ChangeView(null, 0, null, true);
        await Task.Delay(400);
        foreach (var (name, tool) in new[] { ("counter", (AnnotationKind?)null), ("text", AnnotationKind.Text), ("mosaic", AnnotationKind.Mosaic) })
        {
            if (tool is { } kind)
            {
                SelectTool(kind);
            }

            if (_styleButton?.Flyout is Flyout flyout)
            {
                flyout.ShowAt(_styleButton);
                await Task.Delay(700);
                await WindowShot.SaveAsync(hwnd, Path.Combine(directory, $"long-annotate-style-{name}.png"));
                flyout.Hide();
                await Task.Delay(300);
            }
        }

        SelectTool(null);
    }

    private void Release()
    {
        if (ReferenceEquals(_instance, this))
        {
            _instance = null;
        }

        foreach (var band in _bands.Values)
        {
            band.Dispose();
        }

        _bands.Clear();
        try
        {
            _view.RemoveFromVisualTree();
        }
        catch
        {
            // 已经拆了。
        }
    }
}
