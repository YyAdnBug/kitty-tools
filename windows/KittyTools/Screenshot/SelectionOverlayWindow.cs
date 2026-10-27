// 每块显示器一个全屏遮罩：画冻结帧、窗口高亮、框选、8 个手柄、尺寸胶囊和放大镜。
// 只让鼠标所在屏那个窗口拿键盘焦点；其它屏只负责显示同一份选区。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
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
    private readonly Border _toolbar;
    private readonly Border _styleTray;
    private readonly Dictionary<AnnotationTool, Button> _toolButtons = new();
    private readonly List<PixelBounds> _windows = new();
    private readonly List<Annotation> _annotations = new();
    private readonly List<List<Annotation>> _undoStack = new();
    private readonly List<List<Annotation>> _redoStack = new();
    private readonly CanvasTextFormat _text = new() { FontFamily = "Segoe UI", FontSize = 12 };
    private readonly CanvasTextFormat _small = new() { FontFamily = "Segoe UI", FontSize = 11 };

    private CanvasBitmap? _bitmap;
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
    private AnnotationTool _tool = AnnotationTool.Select;
    private Color _color = Accent;
    private double _width = 3;
    private Annotation? _activeAnnotation;
    private PointD _annotationStart;
    private Annotation? _selectedAnnotation;
    private PointD _annotationDragStart;
    private RectD _annotationDragRect;
    private List<PointD>? _annotationDragPoints;
    private TextBox? _textEditor;
    private PointD _textPoint;
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
        _root = new Canvas
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Colors.Transparent),
        };
        _root.Children.Add(_canvas);
        _toolbar = BuildToolbar();
        _root.Children.Add(_toolbar);
        _styleTray = BuildStyleTray();
        _root.Children.Add(_styleTray);
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
        _bitmap?.Dispose();
        _bitmap = null;
        _windows.Clear();
        _annotations.Clear();
        _undoStack.Clear();
        _redoStack.Clear();
        _activeAnnotation = null;
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
        _annotations.Clear();
        _annotations.AddRange(annotations);
        _canvas.Invalidate();
    }

    /// <summary>截图历史（PLAN-v8）：现在画着的标注，坐标换成选区里的像素。</summary>
    internal List<ShotAnnotationData> AnnotationsForHistory()
    {
        var origin = _session.Selection;
        return _annotations.Select(annotation => ShotAnnotations.ToData(annotation, origin.X, origin.Y)).ToList();
    }

    public FrozenScreen Screen => _screen;

    /// <summary>选区 + 标注合成成 PNG（像素和冻结帧 1:1）。</summary>
    public async Task<byte[]?> ExportPngAsync()
    {
        if (_bitmap is null || _session.SelectionScreen != _screen || !_session.HasSelection)
        {
            return null;
        }

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
                ds, _annotations, _screen,
                new PointD(selection.X, selection.Y), 1, _scale);
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

    private async Task ShowTextAsync(PointD point)
    {
        // 文字改成原位输入（PLAN-v2 §3.8）：在点下的位置叠一个 TextBox，Esc / 点到外面收下。
        if (_session.SelectionScreen != _screen || !_session.HasSelection ||
            !_session.Selection.Contains(point))
        {
            return;
        }

        CommitText();
        _textPoint = point;
        var editor = new TextBox
        {
            Text = string.Empty,
            FontSize = 15,
            MinWidth = 200,
            AcceptsReturn = false,
            PlaceholderText = "输入文字，Enter 确认",
        };
        Canvas.SetLeft(editor, point.X / _scale);
        Canvas.SetTop(editor, point.Y / _scale);
        editor.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                CommitText();
            }
            else if (e.Key == Windows.System.VirtualKey.Escape)
            {
                e.Handled = true;
                CancelText();
            }
        };
        editor.LostFocus += (_, _) => CommitText();
        _root.Children.Add(editor);
        _textEditor = editor;
        editor.Focus(FocusState.Programmatic);
        await Task.CompletedTask;
    }

    private void CommitText()
    {
        if (_textEditor is not { } editor)
        {
            return;
        }

        _textEditor = null;
        var text = editor.Text.Trim();
        _root.Children.Remove(editor);
        if (text.Length > 0)
        {
            PushUndo();
            _annotations.Add(new Annotation
            {
                Tool = AnnotationTool.Text,
                Rect = new RectD(_textPoint.X, _textPoint.Y, 0, 0),
                Text = text,
                Color = _color,
                Width = _width,
            });
        }

        _canvas.Invalidate();
        _canvas.Focus(FocusState.Programmatic);
    }

    private void CancelText()
    {
        if (_textEditor is { } editor)
        {
            _textEditor = null;
            _root.Children.Remove(editor);
        }

        _canvas.Focus(FocusState.Programmatic);
    }

    /// <summary>点中的标注（后画的在上层，所以倒着找）。</summary>
    private Annotation? HitAnnotation(PointD point)
    {
        for (var index = _annotations.Count - 1; index >= 0; index--)
        {
            var annotation = _annotations[index];
            var hit = annotation.Tool switch
            {
                AnnotationTool.Text => new RectD(annotation.Rect.X, annotation.Rect.Y,
                    Math.Max(40, annotation.Text.Length * 8.0), 22).Contains(point),
                AnnotationTool.Pen or AnnotationTool.Arrow => NearPolyline(annotation.Points, point),
                AnnotationTool.Rectangle or AnnotationTool.Mosaic => annotation.Rect.Contains(point),
                _ => false,
            };
            if (hit)
            {
                return annotation;
            }
        }

        return null;
    }

    private bool NearPolyline(List<PointD> points, PointD point)
    {
        var tolerance = 10 * _scale;
        for (var index = 1; index < points.Count; index++)
        {
            if (RegionMath.DistanceToSegment(point, points[index - 1], points[index]) <= tolerance)
            {
                return true;
            }
        }

        return points.Count == 1 &&
               Math.Abs(points[0].X - point.X) + Math.Abs(points[0].Y - point.Y) <= tolerance;
    }

    private void DeleteSelectedAnnotation()
    {
        if (_selectedAnnotation is not { } annotation)
        {
            return;
        }

        PushUndo();
        _annotations.Remove(annotation);
        _selectedAnnotation = null;
        _canvas.Invalidate();
    }

    private void MoveSelectedAnnotation()
    {
        if (_selectedAnnotation is not { } annotation)
        {
            return;
        }

        var dx = _cursor.X - _annotationDragStart.X;
        var dy = _cursor.Y - _annotationDragStart.Y;
        annotation.Rect = new RectD(
            _annotationDragRect.X + dx, _annotationDragRect.Y + dy,
            _annotationDragRect.Width, _annotationDragRect.Height);
        if (_annotationDragPoints is { } original)
        {
            annotation.Points.Clear();
            annotation.Points.AddRange(original.Select(point => new PointD(point.X + dx, point.Y + dy)));
        }

        _canvas.Invalidate();
    }

    /// <summary>选中标注的框 / 手柄（矩形四角、箭头两端）。</summary>
    private void DrawAnnotationSelection(Microsoft.Graphics.Canvas.CanvasDrawingSession ds)
    {
        if (_selectedAnnotation is not { } annotation)
        {
            return;
        }

        if (annotation.Points.Count >= 2)
        {
            foreach (var point in new[] { annotation.Points[0], annotation.Points[^1] })
            {
                var dip = new Windows.Foundation.Point(point.X / _scale, point.Y / _scale);
                ds.FillRectangle(new Windows.Foundation.Rect(dip.X - 4, dip.Y - 4, 8, 8), HandleFill);
                ds.DrawRectangle(new Windows.Foundation.Rect(dip.X - 4, dip.Y - 4, 8, 8), Accent, 1);
            }

            return;
        }

        var rect = ToDip(annotation.Rect);
        ds.DrawRectangle(rect, Accent, 1);
        foreach (var corner in new[]
                 {
                     new Windows.Foundation.Point(rect.X, rect.Y),
                     new Windows.Foundation.Point(rect.X + rect.Width, rect.Y),
                     new Windows.Foundation.Point(rect.X, rect.Y + rect.Height),
                     new Windows.Foundation.Point(rect.X + rect.Width, rect.Y + rect.Height),
                 })
        {
            ds.FillRectangle(new Windows.Foundation.Rect(corner.X - 3, corner.Y - 3, 6, 6), HandleFill);
            ds.DrawRectangle(new Windows.Foundation.Rect(corner.X - 3, corner.Y - 3, 6, 6), Accent, 1);
        }
    }
    private void PushUndo()
    {
        _undoStack.Add(_annotations.Select(annotation => annotation.Clone()).ToList());
        _redoStack.Clear();
    }

    private void ResetAnnotations()
    {
        _annotations.Clear();
        _undoStack.Clear();
        _redoStack.Clear();
        _activeAnnotation = null;
    }

    private void Undo()
    {
        if (_undoStack.Count == 0)
        {
            return;
        }

        _redoStack.Add(_annotations.Select(annotation => annotation.Clone()).ToList());
        var previous = _undoStack[^1];
        _undoStack.RemoveAt(_undoStack.Count - 1);
        _annotations.Clear();
        _annotations.AddRange(previous.Select(annotation => annotation.Clone()));
        _canvas.Invalidate();
    }

    private void Redo()
    {
        if (_redoStack.Count == 0)
        {
            return;
        }

        _undoStack.Add(_annotations.Select(annotation => annotation.Clone()).ToList());
        var next = _redoStack[^1];
        _redoStack.RemoveAt(_redoStack.Count - 1);
        _annotations.Clear();
        _annotations.AddRange(next.Select(annotation => annotation.Clone()));
        _canvas.Invalidate();
    }


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
    /// 工具栏改成 XAML 控件（PLAN-v2 §3.8）：两段「工具」和「动作」，悬停提示里带快捷键，
    /// 每个按钮都有读屏名字，当前工具用品牌粉实心底。尺寸胶囊和放大镜还画在 Win2D 上。
    /// </summary>
    private Border BuildToolbar()
    {
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var (tool, label, name, shortcut) in new[]
                 {
                     (AnnotationTool.Select, Glyphs.ToolSelect, "选择", "V"),
                     (AnnotationTool.Rectangle, Glyphs.ToolRectangle, "矩形", "1"),
                     (AnnotationTool.Arrow, Glyphs.ToolArrow, "箭头", "2"),
                     (AnnotationTool.Pen, Glyphs.ToolPen, "画笔", "3"),
                     (AnnotationTool.Text, Glyphs.ToolText, "文字", "4"),
                     (AnnotationTool.Mosaic, Glyphs.ToolMosaic, "马赛克", "5"),
                 })
        {
            var button = ToolbarButton(label, $"{name}（{shortcut}）", name);
            button.Click += (_, _) =>
            {
                _tool = tool;
                UpdateToolbarChrome();
                _canvas.Invalidate();
            };
            _toolButtons[tool] = button;
            tools.Children.Add(button);
        }

        var extras = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        _colorButton = ToolbarButton(string.Empty, "颜色 / 线宽", "颜色");
        _colorButton.Click += (_, _) => ToggleStyleTray();
        extras.Children.Add(_colorButton);

        _widthButton = ToolbarButton("3", "线宽", "线宽");
        _widthButton.Click += (_, _) => ToggleStyleTray();
        extras.Children.Add(_widthButton);

        _undoButton = ToolbarButton(Glyphs.Undo, "撤销（Ctrl+Z）", "撤销");
        _undoButton.Click += (_, _) => Undo();
        extras.Children.Add(_undoButton);
        _redoButton = ToolbarButton(Glyphs.Redo, "重做（Ctrl+Y）", "重做");
        _redoButton.Click += (_, _) => Redo();
        extras.Children.Add(_redoButton);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        var actionItems = _session.Mode == ScreenshotMode.Record
            ? new (string, string, string, Action)[]
            {
                (Glyphs.Record, "开始录屏（Enter，倒数 3 秒）", "开始录屏",
                    () => _session.BeginRecordingSelection()),
            }
            : new (string, string, string, Action)[]
            {
                (Glyphs.Ocr, "识字（O）", "识别文字", () => _ = _session.RecognizedSelectionAsync()),
                (Glyphs.Translate, "翻译（T）", "截图翻译", () => _ = _session.TranslateSelectionAsync()),
                (Glyphs.Pin, "钉在屏幕上（P）", "钉图", () => _ = PinSelectionAsync()),
            };
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
            var done = ToolbarButton(Glyphs.Check, "复制（Enter）", "复制截图");
            done.Click += (_, _) => _ = _session.CopySelectionAsync();
            actions.Children.Add(done);
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (_session.Mode == ScreenshotMode.Record)
        {
            // 录屏时不需要标注工具，只留录制条。
            tools.Visibility = Visibility.Collapsed;
            extras.Visibility = Visibility.Collapsed;
            var record = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            record.Children.Add(BuildRecordBar());
            row.Children.Add(Capsule(record));
        }
        else
        {
            var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            left.Children.Add(tools);
            left.Children.Add(Separator());
            left.Children.Add(extras);
            row.Children.Add(Capsule(left));
        }

        row.Children.Add(Capsule(actions));

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

    /// <summary>样式托盘（PLAN-v7 §3.6）：8 个色点 + 三档线宽，从当前工具按钮下方长出来。</summary>
    private Border BuildStyleTray()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var color in Theme.Shot.AnnotationPalette)
        {
            var swatch = new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(11),
                Background = new SolidColorBrush(color),
                BorderBrush = new SolidColorBrush(Theme.Argb(80, 255, 255, 255)),
                BorderThickness = new Thickness(1),
            };
            var button = new Button
            {
                Content = swatch,
                Width = 30,
                Height = 30,
                Padding = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(4),
            };
            AutomationProperties.SetName(button, "标注颜色");
            button.Click += (_, _) =>
            {
                _color = color;
                UpdateToolbarChrome();
                _canvas.Invalidate();
                _styleTray.Visibility = Visibility.Collapsed;
            };
            row.Children.Add(button);
        }

        row.Children.Add(new Border
        {
            Width = 1,
            Height = 18,
            Background = new SolidColorBrush(Theme.Shot.ToolbarSeparator),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(3, 0, 3, 0),
        });
        foreach (var width in new[] { 2.0, 3, 5, 8 })
        {
            var button = ToolbarButton(width.ToString("F0"), $"线宽 {width:F0}", "线宽 " + width.ToString("F0"), 30);
            button.Height = 30;
            button.Click += (_, _) =>
            {
                _width = width;
                UpdateToolbarChrome();
                _canvas.Invalidate();
                _styleTray.Visibility = Visibility.Collapsed;
            };
            row.Children.Add(button);
        }

        var tray = new Border
        {
            Height = 38,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(4),
            Background = new SolidColorBrush(Theme.Shot.HudBackgroundStrong),
            BorderBrush = new SolidColorBrush(Theme.Argb(36, 255, 255, 255)),
            BorderThickness = new Thickness(0.5),
            Child = row,
            Visibility = Visibility.Collapsed,
        };
        Canvas.SetZIndex(tray, 11);
        return tray;
    }

    private void ToggleStyleTray()
    {
        if (_styleTray.Visibility == Visibility.Visible)
        {
            _styleTray.Visibility = Visibility.Collapsed;
            return;
        }

        PositionStyleTray();
        _styleTray.Visibility = Visibility.Visible;
    }

    private void PositionStyleTray()
    {
        _toolbar.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        _styleTray.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var left = Canvas.GetLeft(_toolbar);
        var top = Canvas.GetTop(_toolbar);
        if (double.IsNaN(left))
        {
            left = 0;
        }

        if (double.IsNaN(top))
        {
            top = 0;
        }

        var x = Math.Max(0, left);
        var y = top + _toolbar.DesiredSize.Height + 6;
        var maxX = _screen.Bounds.Width / _scale - _styleTray.DesiredSize.Width - 4;
        Canvas.SetLeft(_styleTray, Math.Min(x, Math.Max(0, maxX)));
        Canvas.SetTop(_styleTray, y);
    }

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
        };
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, automationName);
        return button;
    }

    private Button? _colorButton;
    private Button? _widthButton;
    private Button? _undoButton;
    private Button? _redoButton;

    /// <summary>当前工具（品牌粉实心底）、颜色块、线宽、撤销 / 重做可用状态。</summary>
    private void SelectTool(AnnotationTool tool)
    {
        _tool = tool;
        UpdateToolbarChrome();
        _canvas.Invalidate();
    }

    private void UpdateToolbarChrome()
    {
        foreach (var (tool, button) in _toolButtons)
        {
            var selected = tool == _tool;
            button.Background = new SolidColorBrush(
                selected ? Theme.AccentColor : Colors.Transparent);
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

        if (_colorButton is not null)
        {
            _colorButton.Background = new SolidColorBrush(_color);
        }

        if (_widthButton?.Content is TextBlock width)
        {
            width.Text = _width.ToString("F0");
        }

        if (_undoButton is not null)
        {
            _undoButton.IsEnabled = _undoStack.Count > 0;
        }

        if (_redoButton is not null)
        {
            _redoButton.IsEnabled = _redoStack.Count > 0;
        }
    }

    /// <summary>工具栏贴着选区下方；下面放不下就放上方，再夹进这块屏。</summary>
    private void PositionToolbar()
    {
        if (_session.Mode != ScreenshotMode.Capture || _session.SelectionScreen != _screen ||
            !_session.HasSelection)
        {
            _toolbar.Visibility = Visibility.Collapsed;
            return;
        }

        _toolbar.Visibility = Visibility.Visible;
        _toolbar.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = _toolbar.DesiredSize;
        var selection = ToDip(_session.Selection);
        var screenWidth = _screen.Width / _scale;
        var screenHeight = _screen.Height / _scale;
        var x = selection.X;
        var y = selection.Bottom + 8;
        if (y + size.Height > screenHeight)
        {
            y = selection.Y - size.Height - 8;
        }

        x = Math.Clamp(x, 0, Math.Max(0, screenWidth - size.Width));
        y = Math.Clamp(y, 0, Math.Max(0, screenHeight - size.Height));
        Canvas.SetLeft(_toolbar, x);
        Canvas.SetTop(_toolbar, y);
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {        var width = (float)sender.ActualWidth;
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
            AnnotationRenderer.Draw(
                ds, _annotations, _screen, new PointD(0, 0), 1 / _scale, 1);
            DrawSelection(ds, own);
            DrawAnnotationSelection(ds);
        }

        if (_key)
        {
            DrawHint(ds, width, height);
            DrawMagnifier(ds, width, height);
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

        var label = $"{Math.Round(selection.Width)} × {Math.Round(selection.Height)}";
        var labelWidth = 92f;
        var x = (float)(rect.X);
        var y = (float)(rect.Y - 30);
        if (y < 4)
        {
            y = (float)(rect.Y + 6);
        }

        var pill = new Windows.Foundation.Rect(x, y, labelWidth, 24);
        ds.FillRoundedRectangle(pill, 6, 6, Theme.Shot.LabelBackground);
        ds.DrawRoundedRectangle(pill, 6, 6, Theme.Argb(40, 255, 255, 255), 1);
        ds.DrawText(label, x + 9, y + 5, Theme.Shot.HudText, _text);
    }

    private void DrawHint(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, float width, float height)
    {
        var hint = _session.Mode switch
        {
            ScreenshotMode.Ocr => "拖动框选要识别的区域 · Esc 取消",
            ScreenshotMode.Translate => "拖动框选要翻译的区域 · Esc 取消",
            _ when _session.HasSelection => "Enter 复制 · Ctrl+S 保存 · P 钉图 · O 识字 · T 翻译 · Esc 取消",
            _ => "拖动框选 · 单击窗口截整窗 · Esc 取消",
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
        _canvas.Focus(FocusState.Pointer);
        ReadCursor();
        var point = _cursor;
        _pressed = point;
        _anchor = point;
        _cursor = point;

        if (e.GetCurrentPoint(_canvas).Properties.IsRightButtonPressed)
        {
            e.Handled = true;
            if (_session.HasSelection)
            {
                _session.ClearSelection();
            }
            else
            {
                _session.Finish();
            }

            return;
        }

        _canvas.CapturePointer(e.Pointer);
        if (_session.Mode == ScreenshotMode.Capture &&
            _session.SelectionScreen == _screen && _session.HasSelection)
        {
            // 选中工具：点已画好的标注 → 选中、拖动（PLAN-v2 §3.8）。
            if (_tool == AnnotationTool.Select && _session.Selection.Contains(point) &&
                HitAnnotation(point) is { } hit)
            {
                PushUndo();
                _selectedAnnotation = hit;
                _annotationDragStart = point;
                _annotationDragRect = hit.Rect;
                _annotationDragPoints = hit.Points.Count > 0 ? new List<PointD>(hit.Points) : null;
                _drag = DragKind.MoveAnnotation;
                _canvas.Invalidate();
                e.Handled = true;
                return;
            }

            if (_tool != AnnotationTool.Select && _session.Selection.Contains(point))
            {
                if (_tool == AnnotationTool.Text)
                {
                    _ = ShowTextAsync(point);
                    e.Handled = true;
                    return;
                }

                _annotationStart = point;
                // REVIEW R55：按下就把「还没有这一条」的状态压进撤销栈，松手时不再压，
                // 不然撤销出来的永远带着刚画的那一条、永远差一步。太小被丢掉的，松手时弹回这一份。
                PushUndo();
                _activeAnnotation = new Annotation
                {
                    Tool = _tool,
                    Color = _color,
                    Width = _width,
                    Rect = new RectD(point.X, point.Y, 0, 0),
                };
                if (_tool is AnnotationTool.Pen or AnnotationTool.Arrow)
                {
                    _activeAnnotation.Points.Add(point);
                    if (_tool == AnnotationTool.Arrow)
                    {
                        _activeAnnotation.Points.Add(point);
                    }
                }

                _annotations.Add(_activeAnnotation);
                _selectedAnnotation = _activeAnnotation;
                _drag = DragKind.Annotate;
                _canvas.Invalidate();
                e.Handled = true;
                return;
            }
        }

        if (_session.SelectionScreen == _screen && _session.HasSelection)
        {
            var handle = RegionMath.HandleAt(point, _session.Selection, 8 * _scale, 8 * _scale);
            if (handle is { } hit)
            {
                _drag = DragKind.Resize;
                _handle = hit;
                _original = _session.Selection;
                e.Handled = true;
                return;
            }

            if (_session.Selection.Contains(point))
            {
                _drag = DragKind.Move;
                _original = _session.Selection;
                e.Handled = true;
                return;
            }
        }

        _drag = DragKind.Draw;
        ResetAnnotations();
        _canvas.CapturePointer(e.Pointer);
        _session.SetSelection(_screen, new RectD(point.X, point.Y, 0, 0));
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        ReadCursor();
        if (_drag == DragKind.None)
        {
            UpdateHover();
            _canvas.Invalidate();
            return;
        }

        UpdateDrag();
        e.Handled = true;
    }

    private void PollCursor()
    {
        var previousCursor = _cursor;
        var previousHover = _hover;
        ReadCursor();
        if (_drag == DragKind.None)
        {
            UpdateHover();
            // 鼠标、悬停目标都没变就不重画：不动鼠标也按 50 帧 / 秒整屏重画是白烧 CPU（第二版 §2 第 6 条）。
            if (previousCursor == _cursor && Nullable.Equals(previousHover, _hover))
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
        if (_drag == DragKind.MoveAnnotation)
        {
            MoveSelectedAnnotation();
            return;
        }

        if (_drag == DragKind.Annotate && _activeAnnotation is { } annotation)
        {
            if (annotation.Tool == AnnotationTool.Pen)
            {
                var last = annotation.Points[^1];
                if (Math.Abs(last.X - point.X) + Math.Abs(last.Y - point.Y) >= 2)
                {
                    annotation.Points.Add(point);
                }
            }
            else if (annotation.Tool == AnnotationTool.Arrow)
            {
                annotation.Points[0] = _annotationStart;
                annotation.Points[^1] = point;
            }
            else
            {
                annotation.Rect = RectD.FromLtrb(
                    Math.Min(_annotationStart.X, point.X),
                    Math.Min(_annotationStart.Y, point.Y),
                    Math.Max(_annotationStart.X, point.X),
                    Math.Max(_annotationStart.Y, point.Y));
            }

            _canvas.Invalidate();
            return;
        }

        var snapped = Snap(point);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        var fromCenter = IsDown(Windows.System.VirtualKey.Menu);
        var bounds = new RectD(0, 0, _screen.Width, _screen.Height);
        var rect = _drag switch
        {
            DragKind.Draw => RegionMath.Drawn(
                _anchor, snapped, bounds, shift ? 1 : null, fromCenter),
            DragKind.Resize => RegionMath.Resized(
                _original, _handle, snapped, bounds, shift ? 1 : null, fromCenter),
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

        if (_drag == DragKind.MoveAnnotation)
        {
            _drag = DragKind.None;
            _canvas.ReleasePointerCaptures();
            _annotationDragPoints = null;
            e.Handled = true;
            return;
        }

        if (_drag == DragKind.Annotate)
        {
            _drag = DragKind.None;
            _canvas.ReleasePointerCaptures();
            if (_activeAnnotation is { } annotation)
            {
                var small = annotation.Tool switch
                {
                    AnnotationTool.Pen => annotation.Points.Count < 2,
                    AnnotationTool.Arrow => annotation.Points.Count < 2 ||
                                            (Math.Abs(annotation.Points[^1].X - annotation.Points[0].X) +
                                             Math.Abs(annotation.Points[^1].Y - annotation.Points[0].Y) < 3),
                    _ => annotation.Rect.Width < 3 || annotation.Rect.Height < 3,
                };
                if (small)
                {
                    _annotations.Remove(annotation);
                    // 按下时压进去的那份是「没有这一条」的状态，丢掉的话会空撤一步。
                    if (_undoStack.Count > 0)
                    {
                        _undoStack.RemoveAt(_undoStack.Count - 1);
                    }
                }
            }

            _activeAnnotation = null;
            _canvas.Invalidate();
            e.Handled = true;
            return;
        }

        var wasDraw = _drag == DragKind.Draw;
        ReadCursor();
        var moved = Math.Abs(_cursor.X - _pressed.X) + Math.Abs(_cursor.Y - _pressed.Y);
        _canvas.ReleasePointerCaptures();
        _drag = DragKind.None;
        if (wasDraw && moved < 3 && _hover is { } hover)
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
            _session.ClearSelection();
            e.Handled = true;
            return;
        }

        if (_session.Mode is ScreenshotMode.Ocr or ScreenshotMode.Translate)
        {
            _session.ConfirmQuick();
        }

        e.Handled = true;
    }

    /// <summary>录屏条：点按 / 按键 / 系统声音 / 麦克风四个开关（记在设置里，开录那一刻才读）。</summary>
    private StackPanel BuildRecordBar()
    {
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToggleButton Toggle(string text, bool value, string tip, Action<bool> changed)
        {
            var toggle = new ToggleButton
            {
                Content = text,
                IsChecked = value,
                FontSize = 12,
                Padding = new Thickness(8, 3, 8, 3),
                MinWidth = 0,
            };
            ToolTipService.SetToolTip(toggle, tip);
            toggle.Click += (_, _) => changed(toggle.IsChecked == true);
            return toggle;
        }

        bar.Children.Add(Toggle(
            "点按", SettingsService.Current.RecordClicks, "在录出的画面里显示点按圈",
            value =>
            {
                SettingsService.Current.RecordClicks = value;
                SettingsService.Save();
            }));
        bar.Children.Add(Toggle(
            "按键", SettingsService.Current.RecordKeys, "在录出的画面里显示快捷键",
            value =>
            {
                SettingsService.Current.RecordKeys = value;
                SettingsService.Save();
            }));

        bar.Children.Add(Toggle(
            "声音", SettingsService.Current.RecordSystemSound, "把系统声音录进 MP4",
            value =>
            {
                SettingsService.Current.RecordSystemSound = value;
                SettingsService.Save();
            }));
        bar.Children.Add(Toggle(
            "麦克风", SettingsService.Current.RecordMicrophone, "把麦克风声音混进 MP4",
            value =>
            {
                SettingsService.Current.RecordMicrophone = value;
                SettingsService.Save();
            }));

        return bar;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(Windows.System.VirtualKey.Control);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        switch (e.Key)
        {
            // R39：工具键改成数字（1 矩形 / 2 箭头 / 3 画笔 / 4 文字 / 5 马赛克），
            // A 留给长截图自动滚动、T 留给截图翻译；换工具和点按钮走同一个 SelectTool。
            case Windows.System.VirtualKey.Number1 when !control:
                SelectTool(AnnotationTool.Rectangle);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Number2 when !control:
                SelectTool(AnnotationTool.Arrow);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Number3 when !control:
                SelectTool(AnnotationTool.Pen);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Number4 when !control:
                SelectTool(AnnotationTool.Text);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Number5 when !control:
                SelectTool(AnnotationTool.Mosaic);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.V when !control:
                SelectTool(AnnotationTool.Select);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Escape:
                // 按一下就退出截图（0.1.0 用户反馈：以前有选区时第一下只清选区、要按两下）。
                // 只有正在打字时 Esc 是取消这段字（文字框自己先收到）。
                e.Handled = true;
                if (_textEditor is not null)
                {
                    CancelText();
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

    private static bool IsDown(Windows.System.VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private enum DragKind
    {
        None,
        Draw,
        Resize,
        Move,
        Annotate,
        MoveAnnotation,
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
}
