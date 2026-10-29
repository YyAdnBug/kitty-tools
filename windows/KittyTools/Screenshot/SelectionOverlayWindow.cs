// 每块显示器一个全屏遮罩：画冻结帧、窗口高亮、框选、8 个手柄、尺寸胶囊和放大镜。
// 只让鼠标所在屏那个窗口拿键盘焦点；其它屏只负责显示同一份选区。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Graphics.DirectX;
using Windows.Storage.Streams;
using Windows.UI;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow : Window
{
    private static readonly Color Accent = Theme.Shot.Accent;
    private static readonly Color Dim = Theme.Shot.Dim;
    private static readonly Color HandleFill = Theme.Shot.HandleFill;

    private readonly FrozenScreen _screen;
    private ScreenshotSession _session;
    private readonly CanvasControl _canvas;
    private readonly Canvas _root;
    /// <summary>包着画布、只管光标（CanvasControl 是 sealed，设不了 ProtectedCursor）；工具栏不在它里面，按钮上照旧是箭头。</summary>
    private readonly CursorHost _cursorHost = new();
    private InputSystemCursorShape? _cursorShape;
    private Border _toolbar;
    private readonly Border _styleTray;
    private readonly List<(AnnotationKind? Tool, Button Button)> _toolButtons = new();
    private readonly List<PixelBounds> _windows = new();
    private readonly AnnotationDocument _document = new();
    private readonly CanvasTextFormat _small = new() { FontFamily = "Segoe UI", FontSize = 11 };

    private CanvasBitmap? _bitmap;
    /// <summary>画好的标注缓存（DrawAnnotations）和它是按哪份标注、哪个选区画的。</summary>
    private CanvasRenderTarget? _layer;
    private IReadOnlyList<Annotation>? _layerItems;
    private RectD _layerSelection;
    private Guid? _layerHidden;
    private HWND _hwnd;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer;
    private double _scale = 1;
    private PointD _cursor;
    private PixelBounds? _hover;
    private DragKind _drag;
    private PointD _anchor;
    private PointD _pressed;
    private RectD _original;
    private SelectionHandle _handle;
    private bool _key;
    /// <summary>当前工具；null = 选择（点标注选中、拖动，点空白平移选区）。</summary>
    private AnnotationKind? _tool;
    /// <summary>新标注用的样式。第 5b 批起按工具记住（PLAN-v9-annotate Y8）。</summary>
    private AnnotationStyle _style = AnnotationStyle.Default;
    /// <summary>正在拖出来的那条（还不在 _document 里，松手够大才收下）。</summary>
    private Annotation? _draft;
    private PointD _annotationStart;
    /// <summary>拖着挪的那条按下时的样子，和按下前整份标注（松手时记一步撤销，B1）。</summary>
    private Annotation? _dragOriginal;
    private IReadOnlyList<Annotation> _dragBefore = Array.Empty<Annotation>();
    /// <summary>调整中在选区外拖开重新框：太小作废时退回原来的选区（mac draw(restore:)）。</summary>
    private RectD? _restore;
    /// <summary>挡下会清掉标注的操作时，顶部提示临时换成这几句（mac refuseWipe / flashHint）。</summary>
    private string? _flash;
    private long _flashUntil;
    private TextBox? _textEditor;
    private PointD _textPoint;
    /// <summary>双击重新编辑的那条文字（编辑时画面上先不画它）；新写的是 null。</summary>
    private Annotation? _editingText;
    /// <summary>拖着的手柄、按下时手柄离光标多远（线类两端和弯曲手柄按偏了也不跳）。</summary>
    private AnnotationHandle _dragHandle;
    private VectorD _dragOffset;
    /// <summary>Alt 拖动复制时原来那条的 Id（单击没拖开就不留副本）。</summary>
    private Guid? _copyOf;
    /// <summary>上一下按在哪条的弯曲手柄上（双击拉直要两下都按在它上面）、上一下按下的时间和位置（认双击）。</summary>
    private Guid? _bendPressed;
    private long _lastPressAt;
    private PointD _lastPressPoint;
    private bool _cloaked;
    private int _framesUntilUncloak;
    private long _firstDrawAt;

    public SelectionOverlayWindow(FrozenScreen screen, ScreenshotSession session)
    {
        _screen = screen;
        _session = session;
        Title = Paths.ProductName + " 截图";
        _canvas = new CanvasControl
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Colors.Transparent),
        };
        _canvas.Draw += OnDraw;
        _canvas.PointerPressed += OnPointerPressed;
        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerReleased += OnPointerReleased;
        _canvas.PointerExited += (_, _) =>
        {
            _hover = null;
            _canvas.Invalidate();
        };
        _canvas.PointerWheelChanged += OnPointerWheel;
        _canvas.IsTabStop = true;
        _canvas.KeyDown += OnKeyDown;
        _canvas.KeyUp += OnKeyUp;
        _root = new Canvas
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Colors.Transparent),
        };
        _cursorHost.Children.Add(_canvas);
        _root.Children.Add(_cursorHost);
        _toolbar = BuildToolbar();
        _root.Children.Add(_toolbar);
        _styleTray = BuildStyleTray();
        _root.Children.Add(_styleTray);
        _sizeCapsule = BuildSizeCapsule();
        _root.Children.Add(_sizeCapsule);
        Content = _root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        ExtendsContentIntoTitleBar = true;
        // REVIEW R64 A：Alt+F4 当成 Esc：走 Finish 收掉每块屏的遮罩、把截图期间注销的热键注册回来。
        // 以前只 Release 了这一块，会话不结束，热键全部失灵，多屏时别的屏上的遮罩还盖着。
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            _session.Finish();
        };

        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        // 直接用冻结帧里这块屏自己的缩放比例：构造时窗口还没挪到那块屏上，GetDpiForWindow 拿到的是错的
        // （第二版 §2 第 5 条）。
        _scale = Math.Max(1, screen.Scale);
        _canvas.Width = screen.Bounds.Width / _scale;
        _canvas.Height = screen.Bounds.Height / _scale;

        var left = screen.Bounds.Left;
        var top = screen.Bounds.Top;
        foreach (var window in session.Windows)
        {
            var l = Math.Max(window.Bounds.Left, screen.Bounds.Left);
            var t = Math.Max(window.Bounds.Top, screen.Bounds.Top);
            var r = Math.Min(window.Bounds.Right, screen.Bounds.Right);
            var b = Math.Min(window.Bounds.Bottom, screen.Bounds.Bottom);
            if (r - l >= 2 && b - t >= 2)
            {
                _windows.Add(new PixelBounds(l - left, t - top, r - left, b - top));
            }
        }

        Activated += OnActivated;
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(20);
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => PollCursor();
        Closed += (_, _) => Release();
        UpdateToolbarChrome();
    }

    /// <summary>
    /// 关闭时把资源和事件都放掉：冻结帧的 CanvasBitmap 不 Dispose、Bgra 字节数组还在大对象堆里，
    /// 就是「截一次图多 32 MB、关掉不还」（第二版 §2 第 6 条）。
    /// </summary>
    public void Release()
    {
        CompositionTarget.Rendering -= OnRenderingWhileCloaked;
        _timer?.Stop();
        _timer = null;
        _canvas.Draw -= OnDraw;
        _canvas.PointerPressed -= OnPointerPressed;
        _canvas.PointerMoved -= OnPointerMoved;
        _canvas.PointerReleased -= OnPointerReleased;
        _canvas.PointerWheelChanged -= OnPointerWheel;
        _canvas.KeyDown -= OnKeyDown;
        _canvas.KeyUp -= OnKeyUp;
        _toolbarTimer?.Stop();
        _bitmap?.Dispose();
        _bitmap = null;
        _layer?.Dispose();
        _layer = null;
        _layerItems = null;
        _windows.Clear();
        _document.Reset();
        _draft = null;
        _canvas.RemoveFromVisualTree();
        Content = null;
        Log.Info("screenshot.overlay-released");
    }

    public PixelBounds ScreenBounds => _screen.Bounds;

    /// <summary>R33 截图自检用。</summary>
    internal IntPtr Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    /// <summary>截图历史「改标注」（PLAN-v8 第 3 批）：摆上当初的标注接着改。</summary>
    internal void LoadAnnotations(IEnumerable<Annotation> annotations)
    {
        _document.Load(annotations);
        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>截图历史（PLAN-v8）：现在画着的标注，坐标换成选区里的像素。</summary>
    internal List<ShotAnnotationData> AnnotationsForHistory()
    {
        var origin = _session.Selection;
        return _document.Items.Select(annotation => ShotAnnotations.ToData(annotation, origin.X, origin.Y)).ToList();
    }

    /// <summary>
    /// --ui-snapshots（PLAN-v9 第 5b 批）：在选区里摆十种标注（弯箭头、实心椭圆、两个序号、聚光灯压暗、荧光笔、模糊马赛克），
    /// 选中 selected 那一种、托盘跟着它，顶部提示一句「有标注时右键不清空」。只在合成的冻结帧上用。
    /// </summary>
    internal void ShowProbeAnnotations(AnnotationKind selected)
    {
        var area = _session.Selection;
        PointD At(double x, double y) => new(area.X + area.Width * x, area.Y + area.Height * y);
        RectD Box(double x, double y, double width, double height)
            => new(At(x, y).X, At(x, y).Y, area.Width * width, area.Height * height);
        var annotations = new[]
        {
            new Annotation { Kind = AnnotationKind.Mosaic, Rect = Box(0.72, 0.4, 0.24, 0.35), Style = new(1, 1, 1) },
            new Annotation { Kind = AnnotationKind.Spotlight, Rect = Box(0.4, 0.04, 0.27, 0.4), Style = new(1, 1, 0) },
            new Annotation { Kind = AnnotationKind.Rectangle, Rect = Box(0.04, 0.08, 0.22, 0.3), Style = new(AnnotationPalette.Pink, 1, 0) },
            new Annotation { Kind = AnnotationKind.Ellipse, Rect = Box(0.27, 0.55, 0.14, 0.3), Style = new(4, 1, 1) },
            new Annotation
            {
                Kind = AnnotationKind.Arrow, From = At(0.45, 0.62), To = At(0.68, 0.9), Bend = new VectorD(0, 0.3),
                Style = new(AnnotationPalette.Red, 1, 0),
            },
            new Annotation { Kind = AnnotationKind.Line, From = At(0.05, 0.5), To = At(0.22, 0.9), Style = new(5, 0, 0) },
            new Annotation
            {
                Kind = AnnotationKind.Pen, Style = new(2, 2, 0),
                Points = Enumerable.Range(0, 30).Select(step => At(0.04 + step * 0.012, 0.95 - Math.Abs(Math.Sin(step / 4.0)) * 0.05)).ToArray(),
            },
            new Annotation { Kind = AnnotationKind.Highlighter, From = At(0.43, 0.52), To = At(0.68, 0.52), Style = new(AnnotationPalette.Yellow, 1, 0) },
            AnnotationRenderer.Measured(
                new Annotation { Kind = AnnotationKind.Text, Rect = Box(0.44, 0.12, 0, 0), Text = "标注 5b" }, _scale) with
            {
                Style = new(AnnotationPalette.White, 1, 0),
            },
            new Annotation { Kind = AnnotationKind.Counter, From = At(0.3, 0.15), Number = 1, Style = new(AnnotationPalette.Red, 1, 0) },
            new Annotation { Kind = AnnotationKind.Counter, From = At(0.92, 0.18), Number = 12, Style = new(AnnotationPalette.Yellow, 2, 0) },
        };
        _document.Load(annotations);
        _document.SelectedId = annotations.First(annotation => annotation.Kind == selected).Id;
        PositionToolbar();
        UpdateToolbarChrome();
        _canvas.Invalidate();
        RefuseWipe("有标注时右键不清空");
    }

    /// <summary>
    /// --ui-snapshots（第 5d 批）：选区里摆 3 × 3 条两行的文字（行 = 无底 / 描边 / 底色，列 = 小 / 中 / 大，中英文混排，
    /// 有白字黑描边、黄底黑字）。editing 是在第几条上打开输入框（不全选）：和收下后的那张逐像素比，只该差一圈焦点环和光标。
    /// </summary>
    internal void ShowProbeTexts(int? editing)
    {
        CommitText();
        var area = _session.Selection;
        var colors = new[,]
        {
            { AnnotationPalette.Red, AnnotationPalette.White, AnnotationPalette.Pink },
            { AnnotationPalette.Red, 5, AnnotationPalette.White },
            { AnnotationPalette.Yellow, AnnotationPalette.Red, AnnotationPalette.White },
        };
        var texts = new List<Annotation>();
        for (var option = 0; option < 3; option++)
        {
            for (var weight = 0; weight < 3; weight++)
            {
                var origin = new RectD(
                    area.X + area.Width * (0.04 + weight * 0.3), area.Y + area.Height * (0.06 + option * 0.32), 0, 0);
                texts.Add(AnnotationRenderer.Measured(
                    new Annotation
                    {
                        Kind = AnnotationKind.Text, Rect = origin, Text = "标注 Kitty\n第二行 gy",
                        Style = new AnnotationStyle(colors[option, weight], weight, option),
                    },
                    _scale));
            }
        }

        _document.Load(texts);
        PositionToolbar();
        UpdateToolbarChrome();
        if (editing is { } index)
        {
            _ = ShowTextAsync(default, texts[index], selectAll: false);
        }

        _canvas.Invalidate();
    }

    /// <summary>画了标注，或正在输入还没收下的字：会把它们清掉的操作都不做（mac hasAnnotations）。</summary>
    internal bool HasAnnotations
        => _document.Items.Count > 0 || !string.IsNullOrWhiteSpace(_textEditor?.Text);

    public FrozenScreen Screen => _screen;

    /// <summary>选区 + 标注合成成 PNG（像素和冻结帧 1:1）。</summary>
    public async Task<byte[]?> ExportPngAsync()
    {
        if (_bitmap is null || _session.SelectionScreen != _screen || !_session.HasSelection)
        {
            return null;
        }

        // 打着字就点了拷贝 / 保存 / 钉图：先把字收下（mac output 先 endEditing）
        CommitText();
        var selection = _session.Selection;
        var width = Math.Max(1, (int)Math.Ceiling(selection.Width));
        var height = Math.Max(1, (int)Math.Ceiling(selection.Height));
        using var target = new CanvasRenderTarget(_canvas, width, height, 96);
        using (var ds = target.CreateDrawingSession())
        {
            ds.DrawImage(
                _bitmap,
                new Windows.Foundation.Rect(0, 0, width, height),
                new Windows.Foundation.Rect(selection.X, selection.Y, width, height));
            AnnotationRenderer.Draw(
                ds, _document.Items, _screen, _bitmap,
                new PointD(selection.X, selection.Y), 1, _scale, selection);
        }

        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await target.SaveAsync(stream, CanvasBitmapFileFormat.Png);
            stream.Seek(0);
            var size = (uint)stream.Size;
            using var reader = new DataReader(stream.GetInputStreamAt(0));
            await reader.LoadAsync(size);
            var bytes = new byte[size];
            reader.ReadBytes(bytes);
            return bytes;
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.export-failed", ex);
            return null;
        }
    }

    /// <summary>
    /// 文字原位输入（PLAN-v9-annotate T6–T8，mac beginEditing）：在点下的位置（文字左上角）叠一个没有底和边的 TextBox，字体、
    /// 字号、颜色和收下后一样，阴影 / 外描边 / 色块和焦点环由画布垫在它下面（DrawTextEditor），改样式立刻变。Enter 换行，
    /// Esc、Ctrl+Enter、点到外面、换工具、出图都收下（D6）。existing 是双击的已有文字（E12）：照它的位置、样式、原文打开、全选，
    /// 编辑时画面上先不画它，收下时换掉同一条。
    /// </summary>
    private async Task ShowTextAsync(PointD point, Annotation? existing = null, bool selectAll = true)
    {
        if (_session.SelectionScreen != _screen || !_session.HasSelection ||
            (existing is null && !_session.Selection.Contains(point)))
        {
            return;
        }

        CommitText();
        _textPoint = existing is null ? point : new PointD(existing.Rect.X, existing.Rect.Y);
        _editingText = existing;
        if (existing is not null)
        {
            _style = existing.Style;
        }

        var editor = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            MinWidth = 0,
            MinHeight = 0,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            Foreground = _editorInk,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily(AnnotationRenderer.TextFontFamily),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            // 全选时选中底是品牌粉 0.4（截图家族不用系统强调色）
            SelectionHighlightColor = new SolidColorBrush(Theme.Argb(102, Accent.R, Accent.G, Accent.B)),
        };
        // TextBox 的模板在悬停 / 有焦点时换自己的底、边和字色：都换成透明 / 这段字的颜色（要在模板套上之前放进 Resources）
        var clear = new SolidColorBrush(Colors.Transparent);
        foreach (var key in new[]
                 {
                     "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                     "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused",
                 })
        {
            editor.Resources[key] = clear;
        }

        foreach (var key in new[] { "TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused" })
        {
            editor.Resources[key] = _editorInk;
        }

        editor.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        // 原文在 AcceptsReturn 之后再放：单行时赋的 Text 会在第一个换行处截断
        editor.Text = existing?.Text ?? string.Empty;
        ScrollViewer.SetHorizontalScrollBarVisibility(editor, ScrollBarVisibility.Hidden);
        ScrollViewer.SetVerticalScrollBarVisibility(editor, ScrollBarVisibility.Hidden);
        editor.PreviewKeyDown += (_, e) =>
        {
            // 组字时 Esc 先给输入法取消组字（T11）；Enter 换行（AcceptsReturn），Ctrl+Enter 收下
            if ((e.Key == Windows.System.VirtualKey.Escape && !_composing) ||
                (e.Key == Windows.System.VirtualKey.Enter && IsDown(Windows.System.VirtualKey.Control)))
            {
                e.Handled = true;
                CommitText();
            }
        };
        editor.TextChanged += (_, _) => LayoutEditor();
        editor.Loaded += (_, _) => LayoutEditor(); // 套上模板、排好之后才量得到输入框的行距
        editor.TextCompositionStarted += (_, _) => _composing = true;
        editor.TextCompositionChanged += (_, _) => LayoutEditor();
        editor.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            LayoutEditor();
        };
        editor.LostFocus += (_, _) =>
        {
            // 拿掉的旧输入框的失焦是之后才到的：那时 _textEditor 已经是新开的那个，不能把它收下
            if (ReferenceEquals(_textEditor, editor))
            {
                CommitText();
            }
        };
        _textEditor = editor;
        _composing = false;
        ApplyEditorStyle();
        _root.Children.Add(editor);
        editor.Focus(FocusState.Programmatic);
        if (existing is not null && selectAll)
        {
            editor.SelectAll();
        }
        else
        {
            editor.Select(editor.Text.Length, 0);
        }

        UpdateToolbarChrome();
        _canvas.Invalidate();
        await Task.CompletedTask;
    }

    /// <summary>输入框的字色（底色样式是压在色块上的黑 / 白字）。同一个画刷，换样式时只改颜色：模板的状态里引用的也是它。</summary>
    private readonly SolidColorBrush _editorInk = new(Colors.White);

    /// <summary>输入法正在组字（这时 Esc 归输入法）。</summary>
    private bool _composing;

    /// <summary>打着的字现在的样子（框按现在的字量），画布照它垫阴影 / 描边 / 色块。</summary>
    private Annotation? _editingLive;

    /// <summary>输入框实际的行距（DIP），按字号记住：垫的那层照它排（AnnotationRenderer.DrawTextBacking）。</summary>
    private readonly Dictionary<double, double> _editorPitch = new();
    private double? _editingPitch;

    /// <summary>输入框的字体、字号、颜色跟上 _style，再重排。</summary>
    private void ApplyEditorStyle()
    {
        if (_textEditor is not { } editor)
        {
            return;
        }

        editor.FontSize = _style.FontSize;
        _editorInk.Color = _style.Option == 2 ? AnnotationRenderer.InkOf(_style.Color) : AnnotationRenderer.ColorOf(_style.Color);
        LayoutEditor();
    }

    /// <summary>
    /// 输入框比文字框大一圈、字的位置不变（左上角不动，往右往下长，mac layoutEditor）：底色时这一圈是色块的留边（6 / 2），
    /// 其余留 3 给阴影和外描边。另外右边、下边多留一个字号的余量，输入框自己排出来的比量的宽一点也不会滚动。
    /// </summary>
    private void LayoutEditor()
    {
        if (_textEditor is not { } editor)
        {
            return;
        }

        _editingPitch = EditorPitch(editor);
        _editingLive = AnnotationRenderer.Measured(
            (_editingText ?? new Annotation { Kind = AnnotationKind.Text }) with
            {
                Rect = new RectD(_textPoint.X, _textPoint.Y, 0, 0),
                Text = EditorText(editor),
                Style = _style,
            },
            _scale,
            _editingPitch);
        var (padX, padY) = EditorPadding(_style);
        var frame = ToDip(_editingLive.Rect);
        editor.Padding = new Thickness(padX, padY, padX, padY);
        Canvas.SetLeft(editor, frame.X - padX);
        Canvas.SetTop(editor, frame.Y - padY);
        editor.Width = frame.Width + padX * 2 + _style.FontSize;
        editor.Height = frame.Height + padY * 2 + _style.FontSize * 1.5;
        _canvas.Invalidate();
    }

    /// <summary>输入框第二行比第一行低多少（有第二行时量一次，按字号记住）；还没量到时 null，按 DirectWrite 自己的行距。</summary>
    private double? EditorPitch(TextBox editor)
    {
        var size = _style.FontSize;
        var lineBreak = editor.Text.IndexOf('\r');
        if (lineBreak >= 0 && lineBreak + 1 < editor.Text.Length)
        {
            try
            {
                var pitch = editor.GetRectFromCharacterIndex(lineBreak + 1, false).Y - editor.GetRectFromCharacterIndex(0, false).Y;
                if (pitch > size && pitch < size * 2)
                {
                    _editorPitch[size] = pitch;
                }
            }
            catch (Exception ex) when (ex is ArgumentException or COMException)
            {
                // 还没排好（刚放进去、模板还没套上）：等 Loaded 再量
            }
        }

        return _editorPitch.TryGetValue(size, out var known) ? known : null;
    }

    private static (double X, double Y) EditorPadding(AnnotationStyle style)
        => style.Option == 2 ? (Annotation.PlatePaddingX, Annotation.PlatePaddingY) : (3, 3);

    /// <summary>TextBox 的换行是 \r：存和量都按 \n。</summary>
    private static string EditorText(TextBox editor) => editor.Text.Replace("\r\n", "\n").Replace('\r', '\n');

    /// <summary>
    /// 打着的字垫在输入框下面的那层（AnnotationRenderer.DrawTextBacking）和焦点环（Whisker §3：1 DIP 粉 0.55 + 粉 0.18 的 4 外发光，
    /// 圆角同色块：底色 6，否则 3）。环贴着文字框外一圈（和收下后的选中框不是一回事）。
    /// </summary>
    private void DrawTextEditor(Microsoft.Graphics.Canvas.CanvasDrawingSession ds)
    {
        if (_textEditor is null || _editingLive is not { } live)
        {
            return;
        }

        AnnotationRenderer.DrawTextBacking(ds, live, new PointD(0, 0), 1 / _scale, 1, _editingPitch);
        var (padX, padY) = EditorPadding(live.Style);
        var frame = ToDip(live.Rect);
        var ring = new Windows.Foundation.Rect(
            Math.Round(frame.X - padX) + 0.5, Math.Round(frame.Y - padY) + 0.5,
            Math.Round(frame.Width + padX * 2) - 1, Math.Round(frame.Height + padY * 2) - 1);
        var radius = live.Style.Option == 2 ? 6f : 3f;
        using (var list = new Microsoft.Graphics.Canvas.CanvasCommandList(ds))
        {
            using (var inner = list.CreateDrawingSession())
            {
                inner.DrawRoundedRectangle(ring, radius, radius, Accent, 1);
            }

            using var glow = new Microsoft.Graphics.Canvas.Effects.ShadowEffect
            {
                Source = list,
                BlurAmount = 2,
                ShadowColor = Theme.Argb(46, Accent.R, Accent.G, Accent.B),
            };
            ds.DrawImage(glow);
        }

        ds.DrawRoundedRectangle(ring, radius, radius, Theme.Argb(140, Accent.R, Accent.G, Accent.B), 1);
    }

    /// <summary>收下输入的文字：新的加在最上面并选中；重新编辑的换掉原来那条，清空了就删掉（都记一步撤销，没变不记）。</summary>
    private void CommitText()
    {
        if (_textEditor is not { } editor)
        {
            return;
        }

        _textEditor = null;
        _editingLive = null;
        _composing = false;
        var existing = _editingText;
        _editingText = null;
        // 照 mac：原样收下（多行、行首空格都留着），只是全是空白的不要
        var text = EditorText(editor);
        _root.Children.Remove(editor);
        var edited = AnnotationRenderer.Measured(
            (existing ?? new Annotation { Kind = AnnotationKind.Text }) with
            {
                Rect = new RectD(_textPoint.X, _textPoint.Y, 0, 0),
                Text = text,
                Style = _style,
            },
            _scale);
        var keep = edited.IsMeaningful(_scale);
        var next = existing is null
            ? keep ? _document.Items.Append(edited) : _document.Items
            : _document.Items.Where(item => keep || item.Id != existing.Id)
                .Select(item => item.Id == edited.Id ? edited : item);
        _document.Commit(next);
        // 收下后选中这条（同画完自动选中）；清空后那条已经删了
        _document.SelectedId = keep ? edited.Id : null;
        if (existing is not null && _tool is { } tool)
        {
            _style = AnnotationStyle.Remembered(SettingsService.Current.ScreenshotToolStyles, tool);
        }

        UpdateToolbarChrome();
        _canvas.Invalidate();
        _canvas.Focus(FocusState.Programmatic);
    }

    /// <summary>点中的最上面那条（按画的层次，规则见 Core 的 Annotation.Topmost / Contains）。</summary>
    private Annotation? HitAnnotation(PointD point) => Annotation.Topmost(_document.Items, point, _scale);

    /// <summary>按在选中标注的哪个手柄上（半径 7 DIP 内最近的）：按下时比选区的边优先，两者叠在一起时拖的是标注（mac）。</summary>
    private (Annotation Annotation, AnnotationHandle Handle, PointD Point)? AnnotationHandleAt(PointD point)
    {
        if (_textEditor is not null || _document.Selected is not { } selected)
        {
            return null;
        }

        (AnnotationHandle Handle, PointD Point)? best = null;
        var bestDistance = 7 * _scale;
        foreach (var grip in selected.Handles(_scale))
        {
            var distance = Math.Sqrt(Math.Pow(grip.Point.X - point.X, 2) + Math.Pow(grip.Point.Y - point.Y, 2));
            if (distance <= bestDistance)
            {
                bestDistance = distance;
                best = grip;
            }
        }

        return best is { } found ? (selected, found.Handle, found.Point) : null;
    }

    /// <summary>正拖着标注（画、挪、改大小）：撤销 / 重做 / 删除 / 复制 / 方向键都不响应，不然松手时记的那一步和栈对不上（B8）。</summary>
    private bool IsDraggingAnnotation => _drag is DragKind.Annotate or DragKind.MoveAnnotation or DragKind.ResizeAnnotation;

    private void DeleteSelectedAnnotation()
    {
        if (IsDraggingAnnotation || !_document.DeleteSelected())
        {
            return;
        }

        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>拖本体挪动：Shift 锁在移动多的那个方向上（E7）。</summary>
    private void MoveSelectedAnnotation()
    {
        if (_dragOriginal is not { } original)
        {
            return;
        }

        var dx = _cursor.X - _annotationStart.X;
        var dy = _cursor.Y - _annotationStart.Y;
        if (IsDown(Windows.System.VirtualKey.Shift))
        {
            if (Math.Abs(dx) > Math.Abs(dy))
            {
                dy = 0;
            }
            else
            {
                dx = 0;
            }
        }

        _document.Replace(original.Offset(dx, dy));
        _canvas.Invalidate();
    }

    /// <summary>拖手柄（E4–E6）：手柄和光标保持按下时的距离；Shift 正方形 / 45° / 对称的弧（规则在 Core 的 Resized）。</summary>
    private void ResizeSelectedAnnotation()
    {
        if (_dragOriginal is not { } original)
        {
            return;
        }

        var target = new PointD(_cursor.X + _dragOffset.X, _cursor.Y + _dragOffset.Y);
        _document.Replace(original.Resized(_dragHandle, target, IsDown(Windows.System.VirtualKey.Shift), _scale));
        _canvas.Invalidate();
    }

    /// <summary>Ctrl+D：选中的标注复制一份，往右下偏 12 DIP、放在最上面并选中（序号换成下一个号，E9）。</summary>
    private void DuplicateSelectedAnnotation()
    {
        if (IsDraggingAnnotation || _textEditor is not null || _document.Selected is not { } selected)
        {
            return;
        }

        var copy = Duplicate(selected, 12 * _scale);
        _document.Commit(_document.Items.Append(copy));
        _document.SelectedId = copy.Id;
        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>复制一份（新 Id），序号换成下一个号。</summary>
    private Annotation Duplicate(Annotation original, double offset)
    {
        var copy = original.Duplicated(offset, offset);
        return copy.Kind == AnnotationKind.Counter ? copy with { Number = Annotation.NextCounter(_document.Items) } : copy;
    }

    /// <summary>方向键：选中了标注就挪标注（每下记一步撤销），否则挪选区；1 DIP、Shift 10 DIP（E10，mac nudge）。</summary>
    private void Nudge(double dx, double dy)
    {
        if (IsDraggingAnnotation || _drag != DragKind.None || _session.SelectionScreen != _screen || !_session.HasSelection)
        {
            return;
        }

        var step = (IsDown(Windows.System.VirtualKey.Shift) ? 10 : 1) * _scale;
        if (_session.Mode == ScreenshotMode.Capture && _document.Selected is { } selected)
        {
            _document.Commit(_document.Items.Select(item => item.Id == selected.Id ? item.Offset(dx * step, dy * step) : item));
            UpdateToolbarChrome();
            _canvas.Invalidate();
            return;
        }

        _session.SetSelection(
            _screen, RegionMath.Moved(_session.Selection, dx * step, dy * step, new RectD(0, 0, _screen.Width, _screen.Height)));
    }

    private static readonly Microsoft.Graphics.Canvas.Geometry.CanvasStrokeStyle SelectionDash = new() { CustomDashStyle = new[] { 4f, 3f } };

    /// <summary>
    /// 选中标注的样子（E2，mac updateAnnotationChrome）：1 DIP 粉色虚线框 [4, 3]，离外框 3、取整到整点，线类（箭头、直线、
    /// 荧光笔）不画框；手柄是白色 9 圆 + 1.5 粉环，弯曲手柄小一号 7。
    /// </summary>
    private void DrawAnnotationSelection(Microsoft.Graphics.Canvas.CanvasDrawingSession ds)
    {
        if (_textEditor is not null || _document.Selected is not { } annotation)
        {
            return;
        }

        if (annotation.Kind is not (AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter))
        {
            var bounds = ToDip(annotation.Bounds(_scale));
            var frame = new Windows.Foundation.Rect(
                Math.Floor(bounds.X - 3) + 0.5, Math.Floor(bounds.Y - 3) + 0.5,
                Math.Ceiling(bounds.Width + 6), Math.Ceiling(bounds.Height + 6));
            ds.DrawRectangle(frame, Accent, 1, SelectionDash);
        }

        foreach (var (handle, point) in annotation.Handles(_scale))
        {
            var center = new System.Numerics.Vector2((float)(point.X / _scale), (float)(point.Y / _scale));
            var radius = handle == AnnotationHandle.Bend ? 3.5f : 4.5f;
            ds.FillCircle(center, radius, HandleFill);
            ds.DrawCircle(center, radius, Accent, 1.5f);
        }
    }

    private void ResetAnnotations()
    {
        _document.Reset();
        _draft = null;
    }

    /// <summary>撤销 / 重做：先收下打着的字；拖着标注时不响应；栈空时提示音（mac NSSound.beep）。</summary>
    private void Undo() => StepHistory(redo: false);

    private void Redo() => StepHistory(redo: true);

    private void StepHistory(bool redo)
    {
        if (IsDraggingAnnotation)
        {
            return;
        }

        CommitText();
        if (!(redo ? _document.Redo() : _document.Undo()))
        {
            Beep();
            return;
        }

        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>挡下会清掉标注的操作：提示音 + 顶部提示 2 秒说怎么退出（mac refuseWipe）。</summary>
    private void RefuseWipe(string what)
    {
        Beep();
        _flash = what + " · Esc 退出";
        _flashUntil = Environment.TickCount64 + 2000;
        _canvas.Invalidate();
    }

    private static void Beep() => MessageBeep(0xFFFFFFFF);


    public void ShowOverlay(bool key)
    {
        _key = key;
        // 先隐身（DWM cloak）再露出来，冻结帧画上第一帧才去掉：窗口每次新建，Win2D 还没画时 WinUI 先合成
        // 一帧白底，整块屏闪一下白（0.1.0 用户反馈）。隐身的窗口照样能激活、照样合成，只是不上屏。
        SetCloaked(true);
        AppWindow.MoveAndResize(new RectInt32(
            _screen.Bounds.Left, _screen.Bounds.Top, _screen.Bounds.Width, _screen.Bounds.Height));
        DisableRoundCorners();
        FixClientArea();
        AppWindow.Show();
        if (key)
        {
            Activate();
            DispatcherQueue.TryEnqueue(() =>
            {
                _canvas.Focus(FocusState.Programmatic);
            });
        }
        else
        {
            ShowWindow(_hwnd, 4); // SW_SHOWNOACTIVATE
        }

        PInvoke.GetCursorPos(out var cursor);
        _cursor = new PointD(cursor.X - _screen.Bounds.Left, cursor.Y - _screen.Bounds.Top);
        UpdateHover();
        _canvas.Invalidate();
        _timer?.Start();
    }

    public void AuditAccessibility() => AccessibilityAudit.Run(_root, "screenshot");

    public void Invalidate()
    {
        PositionToolbar();
        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        // REVIEW R64 D：按键只挂在画布上。以前只有起始那块屏的遮罩在代码激活时给画布焦点；
        // 多屏时到另一块屏上框选（点一下就激活了那扇窗），焦点没落到画布上，Enter / Esc / 1–5 都没反应。
        if (args.WindowActivationState != WindowActivationState.Deactivated)
        {
            DispatcherQueue.TryEnqueue(() => _canvas.Focus(FocusState.Programmatic));
        }
    }

    /// <summary>
    /// 工具栏（mac EditorToolbar，PLAN-v9-annotate U1 / U2）：左段 10 个工具 ｜ 撤销、重做；右段识字、翻译、长截图、录屏、钉图 ｜
    /// 存储 + ▾ ｜ 取消、拷贝（粉色实心圆钮）。翻译、录屏功能关着时没有它们的按钮。当前工具是一块在工具间滑动的底块（U3）。
    /// 录屏模式只有录制条：四个开关 ｜ 取消、开始（粉色实心圆钮 + 圆点）。
    /// </summary>
    private Border BuildToolbar()
    {
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var kind in AnnotationKinds.All)
        {
            var name = AnnotationKinds.Title(kind);
            var button = ToolbarButton(ToolGlyph(kind), $"{name}（{AnnotationKinds.Key(kind)}）", name);
            if (kind == AnnotationKind.Line && button.Content is FontIcon line)
            {
                // Fluent 没有斜线：横线转 −45°
                line.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
                line.RenderTransform = new RotateTransform { Angle = -45 };
            }
            else if (kind == AnnotationKind.Counter && button.Content is TextBlock number)
            {
                number.FontSize = 17;
            }

            var chosen = kind;
            button.Click += (_, _) => SelectTool(chosen);
            _toolButtons.Add((kind, button));
            tools.Children.Add(button);
        }

        _toolChip = new Border
        {
            Width = 32,
            Height = 32,
            CornerRadius = new CornerRadius(4),
            Background = new SolidColorBrush(Theme.AccentColor),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        _chipTool = null;
        var toolLayer = new Grid();
        toolLayer.Children.Add(_toolChip);
        toolLayer.Children.Add(tools);

        var extras = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        _undoButton = ToolbarButton(Glyphs.Undo, "撤销（Ctrl+Z）", "撤销");
        _undoButton.Click += (_, _) => Undo();
        extras.Children.Add(_undoButton);
        _redoButton = ToolbarButton(Glyphs.Redo, "重做（Ctrl+Y）", "重做");
        _redoButton.Click += (_, _) => Redo();
        extras.Children.Add(_redoButton);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        var actionItems = new List<(string, string, string, Action)>();
        if (_session.Mode != ScreenshotMode.Record)
        {
            actionItems.Add((Glyphs.Ocr, "识字（O）", "识别文字", () => _ = _session.RecognizedSelectionAsync()));
            if (Features.IsOn(Feature.Translate))
            {
                actionItems.Add((Glyphs.Translate, "翻译（T）", "截图翻译", () => _ = _session.TranslateSelectionAsync()));
            }

            actionItems.Add((Glyphs.LongScreenshot, "长截图（S 向下 · Shift+S 向上 · A 自动滚）", "长截图", () => _session.BeginScrolling()));
            if (Features.IsOn(Feature.Recording))
            {
                actionItems.Add((Glyphs.Record, "录屏（R）", "切到录屏", SwitchToRecording));
            }

            actionItems.Add((Glyphs.Pin, "钉在屏幕上（P）", "钉图", () => _ = PinSelectionAsync()));
        }

        foreach (var (glyph, tip, name, action) in actionItems)
        {
            var button = ToolbarButton(glyph, tip, name);
            button.Click += (_, _) => action();
            actions.Children.Add(button);
        }

        // 和 mac 一样（EditorToolbar）：保存 + 旁边的 ▾（保存到文件夹 / 另存为…），最右是 ✕ 取消、✓ 复制。
        // 以前只有一个快速保存、复制是两张纸的图标，用户找不到「保存」和「完成」（0.1.0 反馈）。
        if (_session.Mode != ScreenshotMode.Record)
        {
            actions.Children.Add(Separator());
            var save = ToolbarButton(Glyphs.Save, "快速保存（Ctrl+S）", "保存截图");
            save.Click += (_, _) => _ = _session.SaveSelectionAsync(saveAs: false);
            actions.Children.Add(save);
            var saveMenu = ToolbarButton(Glyphs.ChevronDown, "更多保存选项", "更多保存选项", width: 18);
            if (saveMenu.Content is FontIcon chevron)
            {
                chevron.FontSize = 10;
            }

            saveMenu.Click += (_, _) => ShowSaveMenu(saveMenu);
            actions.Children.Add(saveMenu);
            actions.Children.Add(Separator());
        }

        var close = ToolbarButton(Glyphs.Close, _session.Mode == ScreenshotMode.Record ? "取消录屏（Esc）" : "取消（Esc）",
            "取消截图");
        close.Click += (_, _) => _session.Finish();
        actions.Children.Add(close);
        if (_session.Mode != ScreenshotMode.Record)
        {
            var done = AccentCircleButton(
                new FontIcon { Glyph = Glyphs.Check, FontSize = 14, Foreground = new SolidColorBrush(Colors.White) },
                "复制（Enter · 双击选区）", "复制截图");
            done.Click += (_, _) => _ = _session.CopySelectionAsync();
            actions.Children.Add(done);
        }
        else
        {
            var start = AccentCircleButton(
                new Microsoft.UI.Xaml.Shapes.Ellipse
                {
                    Width = 10, Height = 10, Fill = new SolidColorBrush(Colors.White),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                },
                "开始录制（Enter · 双击选区，倒数 3 秒）", "开始录制");
            start.Click += (_, _) => _session.BeginRecordingSelection();
            actions.Children.Add(start);
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (_session.Mode == ScreenshotMode.Record)
        {
            // 录屏时不需要标注工具，只留录制条。
            toolLayer.Visibility = Visibility.Collapsed;
            extras.Visibility = Visibility.Collapsed;
            // mac RecordBar：一段胶囊 [四个开关] ｜ [取消][● 开始]
            var record = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            record.Children.Add(BuildRecordBar());
            record.Children.Add(Separator());
            record.Children.Add(actions);
            row.Children.Add(Capsule(record));
        }
        else
        {
            var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            left.Children.Add(toolLayer);
            left.Children.Add(Separator());
            left.Children.Add(extras);
            row.Children.Add(Capsule(left));
        }

        if (_session.Mode != ScreenshotMode.Record)
        {
            row.Children.Add(Capsule(actions));
        }

        var toolbar = new Border
        {
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            Child = row,
            Visibility = Visibility.Collapsed,
        };
        Canvas.SetZIndex(toolbar, 10);
        return toolbar;
    }

    private void ShowSaveMenu(FrameworkElement anchor)
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.Bottom };
        var quick = new MenuFlyoutItem { Text = "快速保存到文件夹", KeyboardAcceleratorTextOverride = "Ctrl+S" };
        quick.Click += (_, _) => _ = _session.SaveSelectionAsync(saveAs: false);
        menu.Items.Add(quick);
        var saveAs = new MenuFlyoutItem { Text = "另存为…", KeyboardAcceleratorTextOverride = "Ctrl+Shift+S" };
        saveAs.Click += (_, _) => _ = _session.SaveSelectionAsync(saveAs: true);
        menu.Items.Add(saveAs);
        menu.ShowAt(anchor);
    }

    private static Border Capsule(UIElement child) => new()
    {
        Height = 40,
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(4),
        Background = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(0, 1),
            GradientStops =
            {
                new GradientStop { Color = Theme.Argb(242, 38, 38, 38), Offset = 0 },
                new GradientStop { Color = Theme.Shot.HudBackgroundStrong, Offset = 1 },
            },
        },
        BorderBrush = new SolidColorBrush(Theme.Argb(36, 255, 255, 255)),
        BorderThickness = new Thickness(0.5),
        Child = child,
    };

    private static Border Separator() => new()
    {
        Width = 1,
        Height = 18,
        Background = new SolidColorBrush(Theme.Shot.ToolbarSeparator),
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(2, 0, 2, 0),
    };

    /// <summary>
    /// 样式托盘（mac StyleBar，PLAN-v9-annotate §4）：高 34、圆角 10，内容跟着工具换——有颜色的工具出 8 个色点 ｜ 三档
    /// （细 / 中 / 粗，文字小 / 中 / 大，聚光灯浅 / 中 / 深）｜ 选项分段（空心 / 实心、无底 / 描边 / 底色、像素 / 模糊）。
    /// 选了工具或选中了标注时锚在那个工具按钮下方 6（栏在选区上方时在栏上方）。
    /// ponytail: mac 换工具时位置和宽度 settle 滑过去、色点选中 pop，这里直接换（动效在 5e 和工具栏一起做）。
    /// </summary>
    private Border BuildStyleTray()
    {
        var tray = new Border
        {
            Height = 34,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(6, 0, 6, 0),
            Background = new SolidColorBrush(Theme.Shot.HudBackgroundStrong),
            BorderBrush = new SolidColorBrush(Theme.Shot.HudStroke),
            BorderThickness = new Thickness(0.5),
            Child = _trayRow,
            Visibility = Visibility.Collapsed,
        };
        Canvas.SetZIndex(tray, 11);
        return tray;
    }

    private readonly StackPanel _trayRow = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 2,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly List<(Border Ring, Border Dot, int Index)> _trayColors = new();
    private readonly List<(Border Ring, Border Dot, int Index)> _trayWeights = new();
    private readonly List<(Button Button, int Index)> _trayOptions = new();
    private AnnotationKind? _trayKind;

    /// <summary>换了工具就重排托盘的内容（mac StyleBar.rebuild）。</summary>
    private void RebuildTray(AnnotationKind kind)
    {
        _trayKind = kind;
        _trayRow.Children.Clear();
        _trayColors.Clear();
        _trayWeights.Clear();
        _trayOptions.Clear();
        if (AnnotationKinds.HasColor(kind))
        {
            for (var palette = 0; palette < AnnotationPalette.Argb.Length; palette++)
            {
                var index = palette;
                var title = AnnotationPalette.Titles[index] + "色";
                var (button, ring, dot) = Swatch(14, AnnotationRenderer.ColorOf(index), outlined: true, title);
                button.Click += (_, _) => Restyle(style => style with { Color = index });
                _trayColors.Add((ring, dot, index));
                _trayRow.Children.Add(button);
            }

            _trayRow.Children.Add(Separator());
        }

        var weightTitles = AnnotationKinds.WeightTitles(kind);
        for (var weight = 0; weight < 3; weight++)
        {
            var index = weight;
            var (button, ring, dot) = Swatch(new[] { 4.0, 7, 10 }[index], Theme.Shot.HudText, outlined: false, weightTitles[index]);
            button.Click += (_, _) => Restyle(style => style with { Weight = index });
            _trayWeights.Add((ring, dot, index));
            _trayRow.Children.Add(button);
        }

        var options = AnnotationKinds.OptionTitles(kind);
        if (options.Length == 0)
        {
            return;
        }

        _trayRow.Children.Add(Separator());
        var segment = new StackPanel { Orientation = Orientation.Horizontal };
        for (var option = 0; option < options.Length; option++)
        {
            var index = option;
            var button = new Button
            {
                Content = new TextBlock { Text = options[index], FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium },
                Height = 22,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(8, 0, 8, 0),
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                AllowFocusOnInteraction = false,
            };
            AutomationProperties.SetName(button, options[index]);
            button.Click += (_, _) => Restyle(style => style with { Option = index });
            _trayOptions.Add((button, index));
            segment.Children.Add(button);
        }

        _trayRow.Children.Add(new Border
        {
            Background = new SolidColorBrush(Theme.Shot.ChipFill),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = segment,
        });
    }

    /// <summary>托盘里的色点 / 粗细点：选中时外圈 2 的品牌粉环（离点 2）、整体放大 1.1（mac Swatch）。</summary>
    private static (Button Button, Border Ring, Border Dot) Swatch(double diameter, Color fill, bool outlined, string name)
    {
        var dot = new Border
        {
            Width = diameter,
            Height = diameter,
            CornerRadius = new CornerRadius(diameter / 2),
            Background = new SolidColorBrush(fill),
            BorderBrush = new SolidColorBrush(Theme.Shot.HudStroke),
            BorderThickness = new Thickness(outlined ? 1 : 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
        };
        var ring = new Border
        {
            Width = diameter + 8,
            Height = diameter + 8,
            CornerRadius = new CornerRadius(diameter / 2 + 4),
            BorderBrush = new SolidColorBrush(Accent),
            BorderThickness = new Thickness(2),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        var grid = new Grid { Width = 26, Height = 26 };
        grid.Children.Add(ring);
        grid.Children.Add(dot);
        var button = new Button
        {
            Content = grid,
            Width = 26,
            Height = 26,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(13),
            // 不抢焦点：打着字时点托盘改样式，输入框接着打（点了就失焦会把字收下）
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        return (button, ring, dot);
    }

    private static void MarkSwatch(Border ring, Border dot, bool chosen)
    {
        ring.Visibility = chosen ? Visibility.Visible : Visibility.Collapsed;
        dot.RenderTransform = chosen ? new ScaleTransform { ScaleX = 1.1, ScaleY = 1.1 } : null;
    }

    /// <summary>托盘跟上：该给谁看（打着的字 → 选中的标注 → 当前工具）、选中状态、位置。</summary>
    private void UpdateStyleTray()
    {
        AnnotationKind? kind = _textEditor is not null ? AnnotationKind.Text : _document.Selected?.Kind ?? _tool;
        if (kind is not { } owner || _toolbar.Visibility != Visibility.Visible || _session.Mode != ScreenshotMode.Capture)
        {
            _styleTray.Visibility = Visibility.Collapsed;
            return;
        }

        if (owner != _trayKind)
        {
            RebuildTray(owner);
        }

        var style = ShownStyle;
        foreach (var (ring, dot, index) in _trayColors)
        {
            MarkSwatch(ring, dot, index == style.Color);
        }

        foreach (var (ring, dot, index) in _trayWeights)
        {
            MarkSwatch(ring, dot, index == style.Weight);
        }

        foreach (var (button, index) in _trayOptions)
        {
            var on = index == style.Option;
            button.Background = new SolidColorBrush(on ? Theme.Shot.SelectedFill : Colors.Transparent);
            if (button.Content is TextBlock text)
            {
                text.Foreground = new SolidColorBrush(on ? Theme.Shot.HudText : Theme.Shot.HudTextMuted);
            }
        }

        _styleTray.Visibility = Visibility.Visible;
        _toolbar.UpdateLayout();
        _styleTray.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var anchor = _toolButtons.FirstOrDefault(entry => entry.Tool == owner).Button;
        var toolbarLeft = Canvas.GetLeft(_toolbar) is var left && double.IsNaN(left) ? 0 : left;
        var toolbarTop = Canvas.GetTop(_toolbar) is var top && double.IsNaN(top) ? 0 : top;
        var center = toolbarLeft + 16;
        if (anchor is not null)
        {
            var at = anchor.TransformToVisual(_toolbar).TransformPoint(new Windows.Foundation.Point(0, 0));
            center = toolbarLeft + at.X + anchor.ActualWidth / 2;
        }

        var size = _styleTray.DesiredSize;
        // 托盘在栏外侧（选区下方的栏往下、上方的栏往上）；栏放进了选区时翻到栏上方（选区里面）
        var above = _toolbarSide != ToolbarSide.Below;
        var y = above ? toolbarTop - size.Height - 6 : toolbarTop + _toolbar.DesiredSize.Height + 6;
        var x = Math.Clamp(center - size.Width / 2, 4, Math.Max(4, _screen.Width / _scale - size.Width - 4));
        Canvas.SetLeft(_styleTray, x);
        Canvas.SetTop(_styleTray, Math.Clamp(y, 0, Math.Max(0, _screen.Height / _scale - size.Height)));
    }

    /// <summary>工具栏上的图标：Fluent 字形；序号没有合适的，写带圈的 1。</summary>
    private static string ToolGlyph(AnnotationKind kind) => kind switch
    {
        AnnotationKind.Rectangle => Glyphs.ToolRectangle,
        AnnotationKind.Ellipse => Glyphs.ToolEllipse,
        AnnotationKind.Arrow => Glyphs.ToolArrow,
        AnnotationKind.Line => Glyphs.ToolLine,
        AnnotationKind.Pen => Glyphs.ToolPen,
        AnnotationKind.Highlighter => Glyphs.ToolHighlighter,
        AnnotationKind.Text => Glyphs.ToolText,
        AnnotationKind.Counter => "①",
        AnnotationKind.Mosaic => Glyphs.ToolMosaic,
        _ => Glyphs.ToolSpotlight,
    };

    private static Button ToolbarButton(string label, string tooltip, string automationName, double width = 32)
    {
        var glyph = label.Length >= 1 && label[0] >= '\uE000' && label[0] <= '\uF8FF';
        var button = new Button
        {
            Content = glyph
                ? new FontIcon
                {
                    Glyph = label,
                    FontSize = 16,
                    Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
                }
                : label.Length == 0
                    ? new FontIcon { Glyph = "\uE790", FontSize = 14 }
                    : new TextBlock
                    {
                        Text = label,
                        FontSize = 12,
                        Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
                    },
            Width = width,
            Height = 32,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(4),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            // 不抢焦点：按键都挂在画布上，按钮拿了焦点数字键、Esc 就没反应了，空格 / Enter 还会再点一下它
            AllowFocusOnInteraction = false,
        };
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, automationName);
        return button;
    }

    private Button? _undoButton;
    private Button? _redoButton;

    /// <summary>
    /// 换工具：先收下打着的字、取消选中，读这个工具上次的样式；再按一次同一个工具就收起（mac choose，D1）。null = 收起。
    /// </summary>
    private void SelectTool(AnnotationKind? tool)
    {
        CommitText();
        var chosen = tool is not null && tool == _tool ? null : tool;
        if (chosen is { } kind)
        {
            _style = AnnotationStyle.Remembered(SettingsService.Current.ScreenshotToolStyles, kind);
        }

        _tool = chosen;
        _document.SelectedId = null;
        UpdateToolbarChrome();
        _canvas.Invalidate();
        Announce(chosen is { } picked ? AnnotationKinds.Title(picked) + "工具" : "已收起工具");
    }

    /// <summary>
    /// 改颜色 / 粗细 / 选项：作用于打着的字、选中的标注（记一步撤销，B6）或当前工具的新标注，并记成那个工具的样式
    /// （Y8，mac restyle / remember：是当前工具的话新标注也用它）。
    /// </summary>
    private void Restyle(Func<AnnotationStyle, AnnotationStyle> change)
    {
        AnnotationKind? owner;
        AnnotationStyle changed;
        if (_textEditor is null && !IsDraggingAnnotation && _document.Selected is { } selected &&
            _document.RestyleSelected(change, annotation => AnnotationRenderer.Measured(annotation, _scale)) is { } restyled)
        {
            owner = selected.Kind;
            changed = restyled;
        }
        else
        {
            owner = _textEditor is not null ? AnnotationKind.Text : _tool;
            changed = change(_style);
            if (owner is null)
            {
                return;
            }
        }

        var saved = SettingsService.Current.ScreenshotToolStyles ??= new Dictionary<string, string>();
        AnnotationStyle.Remember(saved, owner.Value, changed);
        SettingsService.Save();
        if (owner == _tool || _textEditor is not null)
        {
            _style = changed;
            ApplyEditorStyle(); // 打着字时改样式立刻变（T7）
        }

        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>样式托盘显示的：打着字时是这段字的，否则选中的标注的，否则新标注用的。</summary>
    private AnnotationStyle ShownStyle
        => _textEditor is null && _document.Selected is { } selected ? selected.Style : _style;

    /// <summary>当前工具（品牌粉实心底）、样式托盘、撤销 / 重做可用状态。</summary>
    private void UpdateToolbarChrome()
    {
        foreach (var (tool, button) in _toolButtons)
        {
            var selected = tool == _tool;
            var foreground = new SolidColorBrush(selected ? Theme.OnAccentColor : Theme.Shot.HudTextMuted);
            if (button.Content is TextBlock text)
            {
                text.Foreground = foreground;
            }
            else if (button.Content is FontIcon icon)
            {
                icon.Foreground = foreground;
            }
        }

        UpdateToolChip();
        if (_undoButton is not null)
        {
            _undoButton.IsEnabled = _document.CanUndo;
        }

        if (_redoButton is not null)
        {
            _redoButton.IsEnabled = _document.CanRedo;
        }

        UpdateStyleTray();
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var width = (float)sender.ActualWidth;
        var height = (float)sender.ActualHeight;
        if (width <= 0 || height <= 0)
        {
            return;
        }

        _bitmap ??= CanvasBitmap.CreateFromBytes(
            sender, _screen.Bgra, _screen.Width, _screen.Height,
            DirectXPixelFormat.B8G8R8A8UIntNormalized);
        var ds = args.DrawingSession;
        ds.DrawImage(_bitmap, new Windows.Foundation.Rect(0, 0, width, height));
        if (_cloaked && _firstDrawAt == 0)
        {
            // 画完这一帧还要等它真的上屏：至少再过 4 次合成、且至少 50 ms 才露出来。
            // 实测（0.1.0 用户反馈「还会闪一下白」）：只等 2 次合成，3 次里 3 次整屏闪白；4 次 3 次里 0 次。
            // 加上 50 ms 是给高刷新率屏留的（144 Hz 下 4 帧不到 30 ms）。
            _framesUntilUncloak = 4;
            _firstDrawAt = Environment.TickCount64;
            CompositionTarget.Rendering += OnRenderingWhileCloaked;
        }

        var selection = _session.SelectionScreen == _screen ? _session.Selection : (RectD?)null;
        var hoverHole = _hover is { } h ? new RectD(h.Left, h.Top, h.Width, h.Height) : (RectD?)null;
        var hole = selection ?? hoverHole;
        if (hole is { } area)
        {
            var top = Math.Max(0, area.Y) / _scale;
            var bottom = Math.Min(_screen.Height, area.Bottom) / _scale;
            var left = Math.Max(0, area.X) / _scale;
            var right = Math.Min(_screen.Width, area.Right) / _scale;
            ds.FillRectangle(0, 0, width, (float)top, Dim);
            ds.FillRectangle(0, (float)bottom, width, height - (float)bottom, Dim);
            ds.FillRectangle(0, (float)top, (float)left, (float)(bottom - top), Dim);
            ds.FillRectangle((float)right, (float)top, width - (float)right, (float)(bottom - top), Dim);
            var outline = new Windows.Foundation.Rect(
                left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
            if (selection is null)
            {
                ds.DrawRectangle(outline, Theme.Shot.Outline, 1.5f);
            }
        }
        else
        {
            ds.FillRectangle(0, 0, width, height, Dim);
        }

        if (selection is { } own)
        {
            DrawAnnotations(sender, ds, own, width, height);
            DrawTextEditor(ds);
            DrawSelection(ds, own);
            DrawAnnotationSelection(ds);
        }

        if (_key)
        {
            DrawHint(ds, width, height);
            if (ShowsCrosshair)
            {
                DrawCrosshair(ds, width, height);
            }

            DrawMagnifier(ds, width, height);
        }
    }

    /// <summary>
    /// 画好的标注缓存成一张透明位图（PLAN-v9-annotate §3 末尾）：阴影、聚光灯、马赛克每帧重算太贵，光标一动就整屏重画。
    /// 标注列表（不可变，换了就是新的数组）、选区、画布大小都没变就直接贴；拖着的那条（_draft）画在上面。
    /// 拖着的是聚光灯时整份连它一起现画：洞要和别的聚光灯合成一层压暗，分开画会压暗两遍。
    /// </summary>
    private void DrawAnnotations(CanvasControl sender, CanvasDrawingSession ds, RectD selection, float width, float height)
    {
        var items = _document.Items;
        // 双击重新编辑的那条文字由输入框显示，画面上先不画它（mac syncAnnotations）
        var hidden = _editingText?.Id;
        IReadOnlyList<Annotation> shown = hidden is { } id ? items.Where(item => item.Id != id).ToList() : items;
        if (_draft is { Kind: AnnotationKind.Spotlight } spotlight)
        {
            AnnotationRenderer.Draw(ds, shown.Append(spotlight).ToList(), _screen, _bitmap, new PointD(0, 0), 1 / _scale, 1, selection);
            return;
        }

        if (_layer is null || !ReferenceEquals(_layerItems, items) || _layerHidden != hidden || _layerSelection != selection ||
            _layer.Size.Width != width || _layer.Size.Height != height)
        {
            if (_layer is null || _layer.Size.Width != width || _layer.Size.Height != height)
            {
                _layer?.Dispose();
                _layer = new CanvasRenderTarget(sender, width, height);
            }

            using (var layer = _layer.CreateDrawingSession())
            {
                layer.Clear(Colors.Transparent);
                AnnotationRenderer.Draw(layer, shown, _screen, _bitmap, new PointD(0, 0), 1 / _scale, 1, selection);
            }

            _layerItems = items;
            _layerHidden = hidden;
            _layerSelection = selection;
        }

        ds.DrawImage(_layer);
        if (_draft is { } draft)
        {
            AnnotationRenderer.Draw(ds, new[] { draft }, _screen, _bitmap, new PointD(0, 0), 1 / _scale, 1, selection);
        }
    }

    private void DrawSelection(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, RectD selection)
    {
        var rect = ToDip(selection);
        ds.DrawRectangle(rect, Accent, 2);
        foreach (SelectionHandle handle in Enum.GetValues<SelectionHandle>())
        {
            var point = handle.PointIn(selection);
            var dip = new Windows.Foundation.Point(point.X / _scale, point.Y / _scale);
            ds.FillRectangle(
                new Windows.Foundation.Rect(dip.X - 4, dip.Y - 4, 8, 8), HandleFill);
            ds.DrawRectangle(
                new Windows.Foundation.Rect(dip.X - 4, dip.Y - 4, 8, 8), Accent, 1);
        }
    }

    private void DrawHint(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, float width, float height)
    {
        var flashing = _flash is not null && Environment.TickCount64 < _flashUntil;
        var hint = flashing ? _flash! : _session.Mode switch
        {
            ScreenshotMode.Ocr => "拖动框选要识别的区域 · Esc 取消",
            ScreenshotMode.Translate => "拖动框选要翻译的区域 · Esc 取消",
            ScreenshotMode.Record when _session.HasSelection => "Enter / 双击选区开始录制 · D 上次区域 · Esc 取消",
            ScreenshotMode.Record => "拖动框选要录的区域 · 单击窗口录这个窗口 · D 上次区域 · Esc 取消",
            _ when _session.HasSelection =>
                "Enter 复制 · Ctrl+S 保存 · 1–0 标注 · S 长截图" + (Features.IsOn(Feature.Recording) ? " · R 录屏" : "") + " · Esc 取消",
            _ => "拖动框选（按住空格平移）· 单击窗口截整窗 · D 上次区域 · Esc 取消",
        };
        var textWidth = Math.Min(width - 32, 640);
        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect((width - textWidth) / 2, 14, textWidth, 26),
            6, 6, Theme.Shot.LabelBackground);
        ds.DrawText(
            hint,
            new Windows.Foundation.Rect((width - textWidth) / 2 + 10, 19, textWidth - 20, 20),
            Theme.Shot.HudText, _small);
    }

    private void DrawMagnifier(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, float width, float height)
    {
        const int radius = 5;
        const float cell = 10;
        const float size = (radius * 2 + 1) * cell;
        var x = (float)(_cursor.X / _scale + 18);
        var y = (float)(_cursor.Y / _scale + 18);
        if (x + size + 8 > width)
        {
            x = (float)(_cursor.X / _scale - size - 18);
        }

        if (y + size + 30 > height)
        {
            y = (float)(_cursor.Y / _scale - size - 30);
        }

        ds.FillRectangle(new Windows.Foundation.Rect(x - 1, y - 1, size + 2, size + 2), Accent);
        for (var row = -radius; row <= radius; row++)
        {
            for (var column = -radius; column <= radius; column++)
            {
                var pixelX = (int)Math.Clamp(_cursor.X + column, 0, _screen.Width - 1);
                var pixelY = (int)Math.Clamp(_cursor.Y + row, 0, _screen.Height - 1);
                var index = (pixelY * _screen.Width + pixelX) * 4;
                var color = Theme.Argb(
                    255, _screen.Bgra[index + 2], _screen.Bgra[index + 1], _screen.Bgra[index]);
                ds.FillRectangle(
                    new Windows.Foundation.Rect(
                        x + (column + radius) * cell, y + (row + radius) * cell, cell, cell),
                    color);
            }
        }

        ds.DrawRectangle(
            new Windows.Foundation.Rect(x + radius * cell, y + radius * cell, cell, cell),
            Theme.Shot.Outline, 1.5f);
        var globalX = (int)(_screen.Bounds.Left + _cursor.X);
        var globalY = (int)(_screen.Bounds.Top + _cursor.Y);
        var text = $"{globalX}, {globalY}   {_screen.HexAt((int)_cursor.X, (int)_cursor.Y)}";
        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect(x, y + size + 4, size, 22), 4, 4,
            Theme.Shot.LabelBackground);
        ds.DrawText(text, x + 6, y + size + 7, Theme.Shot.HudText, _small);
    }
    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        // 打着字点了输入框外面：这一下只把字收下，不做别的（mac mouseDown；以前会接着开一个新输入框或开始画）
        if (_textEditor is not null)
        {
            CommitText();
            e.Handled = true;
            return;
        }

        // 输着宽高点了别处：按输入的提交（mac：点别处提交），这一下照常处理
        EndSizeEditing(commit: true);
        _canvas.Focus(FocusState.Pointer);
        ReadCursor();
        var point = _cursor;
        _pressed = point;
        _anchor = point;
        _cursor = point;
        _lastDrag = point;
        // 按下鼠标前就按着的空格不算平移（不然按着空格从选区外拖，会去平移旧选区而不是框新的）
        _spaceDown = false;

        if (e.GetCurrentPoint(_canvas).Properties.IsRightButtonPressed)
        {
            e.Handled = true;
            OnRightClick();
            return;
        }

        _canvas.CapturePointer(e.Pointer);
        // 双击：系统的双击间隔内、离上一下不到 4 DIP（WinUI 的按下事件不带点击次数）
        var now = Environment.TickCount64;
        var doubleClick = now - _lastPressAt <= GetDoubleClickTime() &&
                          Math.Abs(point.X - _lastPressPoint.X) + Math.Abs(point.Y - _lastPressPoint.Y) <= 4 * _scale;
        _lastPressAt = doubleClick ? 0 : now;
        _lastPressPoint = point;
        var pressedBend = _bendPressed;
        _bendPressed = null;
        var own = _session.SelectionScreen == _screen && _session.HasSelection;
        var annotates = own && _session.Mode == ScreenshotMode.Capture;
        // 按下时谁优先（mac mouseDown）：选中标注的手柄 → 选区的边 / 角 → 标注本体 → 工具作画 → 平移选区 → 选区外。
        var handle = annotates ? AnnotationHandleAt(point) : null;
        if (handle is { } bend && bend.Handle == AnnotationHandle.Bend && doubleClick && bend.Annotation.Id == pressedBend)
        {
            // 双击弯曲手柄：拉直（记一步撤销，本来就直的不记）。第一下也得按在它上面（E6）
            var straight = bend.Annotation.Straightened;
            _document.Commit(_document.Items.Select(item => item.Id == straight.Id ? straight : item));
            _canvas.ReleasePointerCaptures();
            UpdateToolbarChrome();
            _canvas.Invalidate();
            e.Handled = true;
            return;
        }

        if (handle is { } grip)
        {
            // 线类两端、弯曲手柄记住按下时离手柄多远（直箭头的弯曲手柄压在杆上，按偏几点一拖就弯出几点）；矩形类的角对到光标上
            if (grip.Handle == AnnotationHandle.Bend)
            {
                _bendPressed = grip.Annotation.Id;
            }

            var segment = grip.Handle is AnnotationHandle.Start or AnnotationHandle.End or AnnotationHandle.Bend;
            _dragOffset = segment ? new VectorD(grip.Point.X - point.X, grip.Point.Y - point.Y) : VectorD.Zero;
            _dragHandle = grip.Handle;
            _dragOriginal = grip.Annotation;
            _dragBefore = _document.Items;
            _drag = DragKind.ResizeAnnotation;
            e.Handled = true;
            return;
        }

        if (own && RegionMath.HandleAt(point, _session.Selection, 8 * _scale, 8 * _scale) is { } edge)
        {
            _drag = DragKind.Resize;
            _handle = edge;
            _original = _session.Selection;
            e.Handled = true;
            return;
        }

        var inside = own && _session.Selection.Contains(point);
        if (annotates && inside)
        {
            var hit = HitAnnotation(point);
            if (doubleClick && hit is { Kind: AnnotationKind.Text } text)
            {
                // 双击文字：重新编辑（E12）
                _canvas.ReleasePointerCaptures();
                _ = ShowTextAsync(point, text);
                e.Handled = true;
                return;
            }

            // 点中已画好的标注 → 选中、拖动，选着工具时也是（D1，不再有单独的「选择」工具）。撤销在松手时按按下前的样子记（B1）。
            // Alt：先复制一份（序号换下一个号）放在最上面，拖的是副本（E8）
            if (hit is not null)
            {
                var before = _document.Items;
                var target = hit;
                _copyOf = null;
                if (IsDown(Windows.System.VirtualKey.Menu))
                {
                    target = Duplicate(hit, 0);
                    _document.AppendLive(target);
                    _copyOf = hit.Id;
                }

                BeginMoveAnnotation(target, point, before);
                e.Handled = true;
                return;
            }

            if (_tool is { } tool)
            {
                _document.SelectedId = null;
                switch (tool)
                {
                    case AnnotationKind.Text:
                        _ = ShowTextAsync(point);
                        break;
                    case AnnotationKind.Counter:
                    {
                        // 单击放一个序号（编号 = 现有最大 + 1）并选中；按着拖就是挪它，松手一共记一步撤销
                        var before = _document.Items;
                        var counter = new Annotation
                        {
                            Kind = AnnotationKind.Counter, From = point, Number = Annotation.NextCounter(before), Style = _style,
                        };
                        _document.AppendLive(counter);
                        BeginMoveAnnotation(counter, point, before);
                        break;
                    }
                    default:
                        // 拖出来的那条先放在 _draft，松手够大才收进 _document（记一步撤销）
                        _annotationStart = point;
                        _draft = Annotation.Drawn(tool, point, point, false, _style);
                        _drag = DragKind.Annotate;
                        UpdateToolbarChrome();
                        _canvas.Invalidate();
                        break;
                }

                e.Handled = true;
                return;
            }
        }

        // U11：没选工具时双击选区里的空白 = 拷贝（录屏是开始录制）
        if (inside && doubleClick && _tool is null && _session.Mode is ScreenshotMode.Capture or ScreenshotMode.Record)
        {
            _canvas.ReleasePointerCaptures();
            e.Handled = true;
            if (_session.Mode == ScreenshotMode.Record)
            {
                _session.BeginRecordingSelection();
            }
            else
            {
                _ = _session.CopySelectionAsync();
            }

            return;
        }

        if (inside)
        {
            _document.SelectedId = null;
            _drag = DragKind.Move;
            _original = _session.Selection;
            UpdateToolbarChrome();
            _canvas.Invalidate();
            e.Handled = true;
            return;
        }

        // B3：已经有选区（这块屏或别的屏）时，在选区外按下先记着，拖开 3 DIP 才算重新框；单击什么都不做
        // （以前按一下就清掉了全部标注和选区）。
        if (_session.HasSelection)
        {
            _drag = DragKind.Pending;
            e.Handled = true;
            return;
        }

        _drag = DragKind.Draw;
        _restore = null;
        ResetAnnotations();
        _session.SetSelection(_screen, new RectD(point.X, point.Y, 0, 0));
        e.Handled = true;
    }

    /// <summary>开始拖一条标注：选中它，记下它按下时的样子和按下前整份标注（松手时 RecordUndo）。</summary>
    private void BeginMoveAnnotation(Annotation annotation, PointD point, IReadOnlyList<Annotation> before)
    {
        _document.SelectedId = annotation.Id;
        _dragOriginal = annotation;
        _dragBefore = before;
        _annotationStart = point;
        _drag = DragKind.MoveAnnotation;
        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    /// <summary>
    /// 右键：截图翻译 / 识字、还没有选区时退出；有选区时回到待选重新框，但画了标注（含正在输入的字，不管在哪块屏）
    /// 就不清，只提示（B3，mac rightMouseDown）。
    /// </summary>
    private void OnRightClick()
    {
        if (!_session.HasSelection || _session.Mode is ScreenshotMode.Ocr or ScreenshotMode.Translate)
        {
            _session.Finish();
            return;
        }

        if (HasAnnotations || _session.HasAnnotations(besides: this))
        {
            RefuseWipe("有标注时右键不清空");
            return;
        }

        ResetAnnotations();
        _session.ClearSelection();
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        ReadCursor();
        if (_drag == DragKind.None)
        {
            UpdateHover();
            UpdateCursor();
            _canvas.Invalidate();
            return;
        }

        UpdateDrag();
        UpdateCursor();
        e.Handled = true;
    }

    private void PollCursor()
    {
        var previousCursor = _cursor;
        var previousHover = _hover;
        ReadCursor();
        var crosshair = ShowsCrosshair;
        var crosshairChanged = crosshair != _crosshair;
        _crosshair = crosshair;
        if (_flash is not null && Environment.TickCount64 >= _flashUntil)
        {
            _flash = null;
            _canvas.Invalidate();
        }

        // 松手、按键换了状态（选中、换工具）光标也要跟上；形状没变时什么都不做
        UpdateCursor();

        if (_drag == DragKind.None)
        {
            UpdateHover();
            // 鼠标、悬停目标都没变就不重画：不动鼠标也按 50 帧 / 秒整屏重画是白烧 CPU（第二版 §2 第 6 条）。
            if (previousCursor == _cursor && Nullable.Equals(previousHover, _hover) && !crosshairChanged)
            {
                return;
            }
        }
        else
        {
            UpdateDrag();
        }

        _canvas.Invalidate();
    }

    private void OnPointerWheel(object sender, PointerRoutedEventArgs e) => e.Handled = true;

    private void ReadCursor()
    {
        PInvoke.GetCursorPos(out var cursor);
        _cursor = new PointD(cursor.X - _screen.Bounds.Left, cursor.Y - _screen.Bounds.Top);
    }

    private void UpdateDrag()
    {
        var point = _cursor;
        if (_drag == DragKind.Pending)
        {
            if (Math.Sqrt(Math.Pow(point.X - _pressed.X, 2) + Math.Pow(point.Y - _pressed.Y, 2)) < 3 * _scale)
            {
                return;
            }

            // 别的屏上画了标注：不在这块屏重新框（框出来那边的就没了），只提示（mac refuseWipe）
            if (_session.HasAnnotations(besides: this))
            {
                _drag = DragKind.None;
                _canvas.ReleasePointerCaptures();
                RefuseWipe("有标注时不能换屏重新框选");
                return;
            }

            // 这块屏上重新框：标注存的是整屏坐标，换个选区照样在；太小作废时退回原来的选区
            _restore = _session.SelectionScreen == _screen ? _session.Selection : null;
            _document.SelectedId = null;
            _drag = DragKind.Draw;
        }

        if (_drag == DragKind.MoveAnnotation)
        {
            MoveSelectedAnnotation();
            return;
        }

        if (_drag == DragKind.ResizeAnnotation)
        {
            ResizeSelectedAnnotation();
            return;
        }

        if (_drag == DragKind.Annotate && _draft is { } draft)
        {
            if (draft.Kind == AnnotationKind.Pen)
            {
                // 画笔一路累点，离上一个点不到 1.5 DIP 的不要（mac）
                var last = draft.Points[^1];
                if (Math.Sqrt(Math.Pow(last.X - point.X, 2) + Math.Pow(last.Y - point.Y, 2)) >= 1.5 * _scale)
                {
                    _draft = draft with { Points = draft.Points.Append(point).ToArray() };
                }
            }
            else if (Annotation.Drawn(draft.Kind, _annotationStart, point, IsDown(Windows.System.VirtualKey.Shift),
                         draft.Style) is { } shaped)
            {
                // B7：Shift = 正方形 / 正圆 / 45° 线；拖动中按下、松开都立刻重算（PollCursor 20 ms 一次）
                _draft = shaped with { Id = draft.Id };
            }

            _canvas.Invalidate();
            return;
        }

        var snapped = Snap(point);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        var fromCenter = IsDown(Windows.System.VirtualKey.Menu);
        var bounds = new RectD(0, 0, _screen.Width, _screen.Height);
        if (_drag == DragKind.Draw && _spaceDown && _session.SelectionScreen == _screen)
        {
            // 拖动框选途中按着空格：整块平移，锚点跟着走（PLAN-v9 S4，mac extend(pans:)）
            var current = _session.Selection;
            var panned = RegionMath.Moved(current, point.X - _lastDrag.X, point.Y - _lastDrag.Y, bounds);
            _anchor = new PointD(_anchor.X + panned.X - current.X, _anchor.Y + panned.Y - current.Y);
            _lastDrag = point;
            _session.SetSelection(_screen, panned);
            return;
        }

        _lastDrag = point;
        // 尺寸胶囊锁了比例就按它，否则 Shift 正方形
        var ratio = _session.LockedRatio ?? (shift ? 1 : (double?)null);
        var rect = _drag switch
        {
            DragKind.Draw => RegionMath.Drawn(
                _anchor, snapped, bounds, ratio, fromCenter),
            DragKind.Resize => RegionMath.Resized(
                _original, _handle, snapped, bounds, ratio, fromCenter),
            _ => RegionMath.Moved(_original, point.X - _pressed.X, point.Y - _pressed.Y, bounds),
        };
        _session.SetSelection(_screen, rect);
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_drag == DragKind.None)
        {
            return;
        }

        if (_drag == DragKind.Pending)
        {
            // 单击选区外：什么都不做，免得误点丢掉选区和标注（mac mouseUp .pending）
            _drag = DragKind.None;
            _canvas.ReleasePointerCaptures();
            e.Handled = true;
            return;
        }

        if (_drag is DragKind.MoveAnnotation or DragKind.ResizeAnnotation)
        {
            var resizing = _drag == DragKind.ResizeAnnotation;
            _drag = DragKind.None;
            _canvas.ReleasePointerCaptures();
            var original = _dragOriginal;
            _dragOriginal = null;
            if (_copyOf is { } source && original is not null && _document.Find(original.Id) == original)
            {
                // Alt 单击没拖开：不留一份叠在原处、看不出来的副本
                _document.Restore(_dragBefore);
                _document.SelectedId = source;
            }
            else
            {
                // 对角 / 两端拖到叠在一起、看不出来了：算误操作，恢复原样（不然留下一条看不见却点得中的标注，B9）
                if (resizing && original is not null && _document.Find(original.Id) is { } current && !current.IsMeaningful(_scale))
                {
                    _document.Replace(original);
                }

                _document.RecordUndo(_dragBefore);
            }

            _copyOf = null;
            UpdateToolbarChrome();
            _canvas.Invalidate();
            e.Handled = true;
            return;
        }

        if (_drag == DragKind.Annotate)
        {
            _drag = DragKind.None;
            _canvas.ReleasePointerCaptures();
            var drawn = _draft;
            _draft = null;
            // B9：小到看不出来的（误点）不留；画完自动选中，工具保持
            if (drawn is not null && drawn.IsMeaningful(_scale) && _document.Commit(_document.Items.Append(drawn)))
            {
                _document.SelectedId = drawn.Id;
            }

            UpdateToolbarChrome();
            _canvas.Invalidate();
            e.Handled = true;
            return;
        }

        var wasDraw = _drag == DragKind.Draw;
        var restore = _restore;
        _restore = null;
        ReadCursor();
        var moved = Math.Abs(_cursor.X - _pressed.X) + Math.Abs(_cursor.Y - _pressed.Y);
        _canvas.ReleasePointerCaptures();
        _drag = DragKind.None;
        // 松手：工具栏从选区那条边长回来、尺寸胶囊能点了（下面改了选区的话 SetSelection 也会排一次）
        DispatcherQueue.TryEnqueue(Invalidate);
        if (wasDraw && moved < 3 && restore is null && _hover is { } hover)
        {
            ResetAnnotations();
            _session.SetSelection(
                _screen, new RectD(hover.Left, hover.Top, hover.Width, hover.Height));
        }
        else if (wasDraw &&
                 (!_session.HasSelection ||
                  _session.Selection.Width < RegionMath.MinimumSide * _scale ||
                  _session.Selection.Height < RegionMath.MinimumSide * _scale))
        {
            // 太小算误触：调整时退回原来的选区（想拖边差了几点不该把选区弄丢），否则回到待选
            if (restore is { } previous)
            {
                _session.SetSelection(_screen, previous);
            }
            else
            {
                _session.ClearSelection();
            }

            e.Handled = true;
            return;
        }

        if (_session.Mode is ScreenshotMode.Ocr or ScreenshotMode.Translate)
        {
            _session.ConfirmQuick();
        }

        e.Handled = true;
    }

    /// <summary>
    /// 录制条的四个开关（mac RecordBar，顺序同 mac）：系统声音、麦克风、显示点按、显示按键。图标钮 32 × 32：开 = 品牌粉，
    /// 关 = 白色且换成关着的图形（声音 / 麦克风带斜杠、点按是普通鼠标、按键是线框键盘），不只靠颜色分开；悬停提示和读屏
    /// 名字带当前状态，点了播报新状态。记在设置里，开录那一刻才读。
    /// </summary>
    private StackPanel BuildRecordBar()
    {
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var settings = SettingsService.Current;
        Button Toggle(string name, Func<bool> read, Action<bool> write, string onGlyph, string offGlyph, string detail)
        {
            var icon = new FontIcon { FontSize = 16 };
            var button = new Button
            {
                Content = icon,
                Width = 32,
                Height = 32,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(4),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                AllowFocusOnInteraction = false,
            };
            string State() => $"{name}：{(read() ? "开" : "关")}";
            void Apply()
            {
                var on = read();
                icon.Glyph = on ? onGlyph : offGlyph;
                icon.Foreground = new SolidColorBrush(on ? Accent : Theme.Shot.HudTextMuted);
                ToolTipService.SetToolTip(button, State() + "\n" + detail);
                AutomationProperties.SetName(button, State());
            }

            button.Click += (_, _) =>
            {
                write(!read());
                SettingsService.Save();
                Apply();
                Announce(State());
            };
            Apply();
            return button;
        }

        bar.Children.Add(Toggle(
            "系统声音", () => settings.RecordSystemSound, value => settings.RecordSystemSound = value,
            Glyphs.Volume, Glyphs.VolumeOff, "把系统声音录进 MP4"));
        bar.Children.Add(Toggle(
            "麦克风", () => settings.RecordMicrophone, value => settings.RecordMicrophone = value,
            Glyphs.Microphone, Glyphs.MicrophoneOff, "把麦克风声音混进 MP4"));
        bar.Children.Add(Toggle(
            "显示点按", () => settings.RecordClicks, value => settings.RecordClicks = value,
            Glyphs.TouchPointer, Glyphs.Mouse, "在录出的画面里显示点按圈"));
        bar.Children.Add(Toggle(
            "显示按键", () => settings.RecordKeys, value => settings.RecordKeys = value,
            Glyphs.Keyboard, Glyphs.KeyboardOutline, "只显示快捷键，打字不进画面"));
        return bar;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(Windows.System.VirtualKey.Control);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        var alt = IsDown(Windows.System.VirtualKey.Menu);
        switch (e.Key)
        {
            // PLAN-v9 S4：Ctrl + 方向键把那条边往外推、Alt + 方向键往里收（Shift 10 DIP；mac ⌘ / ⌥）
            case Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Up
                or Windows.System.VirtualKey.Down when control != alt:
                e.Handled = true;
                PushEdge(e.Key, outward: control);
                break;
            case Windows.System.VirtualKey.Space:
                // 拖动框选途中按着空格整块平移；按住不放的自动重复不算新按下
                e.Handled = true;
                if (!e.KeyStatus.WasKeyDown)
                {
                    _spaceDown = true;
                }

                break;
            // 数字键 1–9、0 依次是十种工具（mac toolKeys），再按一次收起；A 留给长截图自动滚动、T 留给截图翻译。
            // 录屏没有标注（mac：数字键是截图的）。
            case >= Windows.System.VirtualKey.Number0 and <= Windows.System.VirtualKey.Number9
                when !control && _session.Mode == ScreenshotMode.Capture && _session.HasSelection:
                SelectTool(AnnotationKinds.All[((int)e.Key - (int)Windows.System.VirtualKey.Number0 + 9) % 10]);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Escape:
                // 照 mac：打字中的文字 → 选中的标注 → 选中的工具 → 退出截图（免得一下把画好的标注全丢了）。
                // 有选区、没选工具时按一下就退出，不先清选区（0.1.0 用户反馈：以前要按两下）。
                e.Handled = true;
                if (_textEditor is not null)
                {
                    CommitText();
                }
                else if (_document.SelectedId is not null)
                {
                    _document.SelectedId = null;
                    UpdateToolbarChrome();
                    _canvas.Invalidate();
                }
                else if (_tool is not null)
                {
                    SelectTool(null);
                }
                else
                {
                    _session.Finish();
                }

                break;
            case Windows.System.VirtualKey.Delete:
            case Windows.System.VirtualKey.Back:
                e.Handled = true;
                DeleteSelectedAnnotation();
                break;
            case Windows.System.VirtualKey.D when control:
                // E9：复制选中的标注
                e.Handled = true;
                DuplicateSelectedAnnotation();
                break;
            case Windows.System.VirtualKey.D:
                // S5：跳到上次截的区域（录屏、识字、翻译也认）
                e.Handled = true;
                SelectLastRegion();
                break;
            case Windows.System.VirtualKey.R when !control && _session.Mode == ScreenshotMode.Capture &&
                                                  _session.SelectionScreen == _screen && _session.HasSelection:
                // S5：截图调整时切到录屏（工具栏原地换成录制条）
                e.Handled = true;
                SwitchToRecording();
                break;
            case Windows.System.VirtualKey.Left when !control:
                e.Handled = true;
                Nudge(-1, 0);
                break;
            case Windows.System.VirtualKey.Right when !control:
                e.Handled = true;
                Nudge(1, 0);
                break;
            case Windows.System.VirtualKey.Up when !control:
                e.Handled = true;
                Nudge(0, -1);
                break;
            case Windows.System.VirtualKey.Down when !control:
                e.Handled = true;
                Nudge(0, 1);
                break;
            case Windows.System.VirtualKey.Z when control && shift:
                // D5：重做 Ctrl+Y 和 Ctrl+Shift+Z 都认
                e.Handled = true;
                Redo();
                break;
            case Windows.System.VirtualKey.Z when control:
                e.Handled = true;
                Undo();
                break;
            case Windows.System.VirtualKey.Y when control:
                e.Handled = true;
                Redo();
                break;
            case Windows.System.VirtualKey.Enter:
                e.Handled = true;
                if (_session.Mode is ScreenshotMode.Ocr or ScreenshotMode.Translate)
                {
                    _session.ConfirmQuick();
                }
                else if (_session.Mode == ScreenshotMode.Record)
                {
                    _session.BeginRecordingSelection();
                }
                else
                {
                    _ = _session.CopySelectionAsync();
                }

                break;
            case Windows.System.VirtualKey.C when control:
                e.Handled = true;
                _ = _session.CopySelectionAsync();
                break;
            case Windows.System.VirtualKey.C:
                e.Handled = true;
                _session.CopyColor(_screen.HexAt((int)_cursor.X, (int)_cursor.Y));
                break;
            case Windows.System.VirtualKey.S when control:
                e.Handled = true;
                _ = _session.SaveSelectionAsync(saveAs: shift);
                break;
            case Windows.System.VirtualKey.S when !control && _session.HasSelection:
                // 长截图（第三版 §7）：S 向下、Shift+S 向上。
                e.Handled = true;
                _session.BeginScrolling(up: shift);
                break;
            case Windows.System.VirtualKey.A when !control && _session.HasSelection:
                // 自动滚动长截图：A 向下、Shift+A 向上。
                e.Handled = true;
                _session.BeginScrolling(up: shift, autoScroll: true);
                break;
            case Windows.System.VirtualKey.O when !control:
                e.Handled = true;
                _ = _session.RecognizedSelectionAsync();
                break;
            case Windows.System.VirtualKey.T when !control:
                e.Handled = true;
                _ = _session.TranslateSelectionAsync();
                break;
            case Windows.System.VirtualKey.P:
                e.Handled = true;
                _ = PinSelectionAsync();
                break;
            case Windows.System.VirtualKey.W when control:
                e.Handled = true;
                _session.Finish();
                break;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Space)
        {
            _spaceDown = false;
            e.Handled = true;
        }
    }

    private async Task PinSelectionAsync()
    {
        if (!_session.HasSelection || _session.SelectionScreen is not { } screen)
        {
            return;
        }

        var selection = _session.Selection;
        var png = await ExportPngAsync();
        if (png is null)
        {
            return;
        }

        var global = new PixelBounds(
            screen.Bounds.Left + (int)Math.Round(selection.X),
            screen.Bounds.Top + (int)Math.Round(selection.Y),
            screen.Bounds.Left + (int)Math.Round(selection.Right),
            screen.Bounds.Top + (int)Math.Round(selection.Bottom));
        _session.RecordHistory(screen, selection, png, pinned: true);
        _session.Finish();
        PinHost.Show(png, global);
    }

    /// <summary>鼠标下面的窗口（挖洞用）。在窗口之间移动时洞直接跳过去，不滑（0.1.0 用户定：不学 mac S5）。</summary>
    private void UpdateHover()
    {
        _hover = _windows.FirstOrDefault(window => window.Contains((int)_cursor.X, (int)_cursor.Y));
        if (_hover is { Width: > 0, Height: > 0 } && _session.HasSelection)
        {
            _hover = null;
        }
    }

    private PointD Snap(PointD point)
    {
        var edges = new List<double> { 0, _screen.Width, 0, _screen.Height };
        foreach (var window in _windows)
        {
            edges.Add(window.Left);
            edges.Add(window.Right);
            edges.Add(window.Top);
            edges.Add(window.Bottom);
        }

        var xEdges = edges.Where((_, index) => index % 2 == 0).ToList();
        var yEdges = edges.Where((_, index) => index % 2 == 1).ToList();
        var (x, _) = RegionMath.Snap(point.X, xEdges, 6 * _scale);
        var (y, _) = RegionMath.Snap(point.Y, yEdges, 6 * _scale);
        return new PointD(x, y);
    }

    private PointD ToPhysical(Windows.Foundation.Point point)
        => new(point.X * _scale, point.Y * _scale);

    private Windows.Foundation.Rect ToDip(RectD rect)
        => new(
            rect.X / _scale, rect.Y / _scale,
            Math.Max(0, rect.Width) / _scale, Math.Max(0, rect.Height) / _scale);

    private void OnRenderingWhileCloaked(object? sender, object args)
    {
        if (--_framesUntilUncloak > 0 || Environment.TickCount64 - _firstDrawAt < 50)
        {
            return;
        }

        CompositionTarget.Rendering -= OnRenderingWhileCloaked;
        SetCloaked(false);
    }

    /// <summary>
    /// 收起：先隐身（DWM cloak）再关。关窗口时 Closed 里的 Release 先把内容拆掉（Content = null），HWND 销毁前合成出来的那一帧
    /// 是空白底，在用户机器上是白的，整块屏闪一下白（2026-10-29 用户反馈「录屏开始时整个屏幕闪一下白屏」；
    /// 出现时的同一个坑见 ShowOverlay）。隐身的窗口不上屏，拆内容那一帧就看不见了。
    /// </summary>
    public unsafe void CloseCloaked()
    {
        CompositionTarget.Rendering -= OnRenderingWhileCloaked;
        _cloaked = true;
        var value = 1;
        DwmSetWindowAttribute(_hwnd, 13 /* DWMWA_CLOAK */, &value, sizeof(int));
        Close();
    }

    private unsafe void SetCloaked(bool cloaked)
    {
        if (_cloaked == cloaked)
        {
            return;
        }

        _cloaked = cloaked;
        var value = cloaked ? 1 : 0;
        DwmSetWindowAttribute(_hwnd, 13 /* DWMWA_CLOAK */, &value, sizeof(int));
        if (cloaked)
        {
            // 万一第一帧一直不来（设备丢失之类），最多藏 300 ms，不能让遮罩隐身着吞掉输入。
            var fallback = DispatcherQueue.CreateTimer();
            fallback.Interval = TimeSpan.FromMilliseconds(300);
            fallback.IsRepeating = false;
            fallback.Tick += (_, _) =>
            {
                CompositionTarget.Rendering -= OnRenderingWhileCloaked;
                SetCloaked(false);
            };
            fallback.Start();
        }
    }

    private unsafe void DisableRoundCorners()
    {
        var preference = 1; // DWMWCP_DONOTROUND
        DwmSetWindowAttribute(_hwnd, 33, &preference, sizeof(int));
    }

    private unsafe void FixClientArea()
    {
        if (!GetWindowRect(_hwnd, out var window) || !GetClientRect(_hwnd, out var client))
        {
            return;
        }

        var origin = new POINT();
        ClientToScreen(_hwnd, &origin);
        var left = _screen.Bounds.Left;
        var top = _screen.Bounds.Top;
        var dx = origin.X - window.Left;
        var dy = origin.Y - window.Top;
        var extraWidth = (window.Right - window.Left) - client.Right;
        var extraHeight = (window.Bottom - window.Top) - client.Bottom;
        SetWindowPos(
            _hwnd, new IntPtr(-1), left - dx, top - dy,
            _screen.Bounds.Width + extraWidth, _screen.Bounds.Height + extraHeight,
            0x0010 | 0x0040); // SWP_NOACTIVATE | SWP_SHOWWINDOW
    }

    /// <summary>光标跟上（mac refreshCursor，E15）：顺序同按下的优先级；状态没变不换。</summary>
    private void UpdateCursor()
    {
        var shape = CursorShape();
        if (shape == _cursorShape)
        {
            return;
        }

        _cursorShape = shape;
        _cursorHost.SetCursor(InputSystemCursor.Create(shape));
    }

    private InputSystemCursorShape CursorShape()
    {
        switch (_drag)
        {
            case DragKind.Move or DragKind.MoveAnnotation:
                return InputSystemCursorShape.SizeAll;
            case DragKind.ResizeAnnotation:
                return HandleCursor(_dragHandle);
            case DragKind.Resize:
                return EdgeCursor(_handle);
            case DragKind.Draw or DragKind.Pending or DragKind.Annotate:
                return _tool == AnnotationKind.Text ? InputSystemCursorShape.IBeam : InputSystemCursorShape.Cross;
        }

        if (_session.SelectionScreen != _screen || !_session.HasSelection || _textEditor is not null)
        {
            return _textEditor is not null ? InputSystemCursorShape.Arrow : InputSystemCursorShape.Cross;
        }

        var point = _cursor;
        if (_session.Mode == ScreenshotMode.Capture && AnnotationHandleAt(point) is { } grip)
        {
            return HandleCursor(grip.Handle);
        }

        if (RegionMath.HandleAt(point, _session.Selection, 8 * _scale, 8 * _scale) is { } edge)
        {
            return EdgeCursor(edge);
        }

        var inside = _session.Selection.Contains(point);
        if (inside && _session.Mode == ScreenshotMode.Capture && HitAnnotation(point) is not null)
        {
            return InputSystemCursorShape.SizeAll;
        }

        if (inside && _session.Mode == ScreenshotMode.Capture && _tool is { } tool)
        {
            return tool == AnnotationKind.Text ? InputSystemCursorShape.IBeam : InputSystemCursorShape.Cross;
        }

        return inside ? InputSystemCursorShape.SizeAll : InputSystemCursorShape.Cross;
    }

    /// <summary>标注手柄：矩形类的角是斜向缩放，线类两端和弯曲手柄是手指（往哪儿拖都行）。</summary>
    private static InputSystemCursorShape HandleCursor(AnnotationHandle handle) => handle switch
    {
        AnnotationHandle.TopLeft or AnnotationHandle.BottomRight => InputSystemCursorShape.SizeNorthwestSoutheast,
        AnnotationHandle.TopRight or AnnotationHandle.BottomLeft => InputSystemCursorShape.SizeNortheastSouthwest,
        _ => InputSystemCursorShape.Hand,
    };

    private static InputSystemCursorShape EdgeCursor(SelectionHandle handle) => handle switch
    {
        SelectionHandle.TopLeft or SelectionHandle.BottomRight => InputSystemCursorShape.SizeNorthwestSoutheast,
        SelectionHandle.TopRight or SelectionHandle.BottomLeft => InputSystemCursorShape.SizeNortheastSouthwest,
        SelectionHandle.Top or SelectionHandle.Bottom => InputSystemCursorShape.SizeNorthSouth,
        _ => InputSystemCursorShape.SizeWestEast,
    };

    private static bool IsDown(Windows.System.VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private enum DragKind
    {
        None,
        /// <summary>有选区时在选区外按下：拖开 3 DIP 才变成 Draw（B3）。</summary>
        Pending,
        Draw,
        Resize,
        Move,
        Annotate,
        MoveAnnotation,
        ResizeAnnotation,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [LibraryImport("dwmapi.dll")]
    private static unsafe partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, int* value, int size);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetClientRect(IntPtr hwnd, out RECT rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool ClientToScreen(IntPtr hwnd, POINT* point);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(
        IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int command);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MessageBeep(uint type);

    [LibraryImport("user32.dll")]
    private static partial uint GetDoubleClickTime();
}

/// <summary>只为了能设光标的面板：UIElement.ProtectedCursor 是 protected，CanvasControl 又是 sealed。</summary>
internal sealed partial class CursorHost : Grid
{
    public void SetCursor(InputCursor cursor) => ProtectedCursor = cursor;
}
