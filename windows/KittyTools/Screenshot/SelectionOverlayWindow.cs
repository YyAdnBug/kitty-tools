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
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using Windows.Graphics.DirectX;
using Windows.Storage.Streams;
using Windows.UI;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow : Window
{
    private static readonly Color Accent = Color.FromArgb(255, 255, 77, 126);
    private static readonly Color Dim = Color.FromArgb(115, 0, 0, 0);
    private static readonly Color HandleFill = Color.FromArgb(255, 255, 255, 255);

    private readonly FrozenScreen _screen;
    private readonly ScreenshotSession _session;
    private readonly CanvasControl _canvas;
    private readonly Canvas _root;
    private readonly Dictionary<AnnotationTool, Button> _toolButtons = new();
    private readonly List<PixelBounds> _windows = new();
    private readonly List<Annotation> _annotations = new();
    private readonly List<List<Annotation>> _undoStack = new();
    private readonly List<List<Annotation>> _redoStack = new();
    private readonly List<(RectD Rect, Action Action)> _toolbarHits = new();
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
        _canvas.PointerWheelChanged += (_, e) => e.Handled = true;
        _canvas.IsTabStop = true;
        _canvas.KeyDown += OnKeyDown;
        _root = new Canvas
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Colors.Transparent),
        };
        _root.Children.Add(_canvas);
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

        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        _scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        _scale = Math.Max(1, _scale);
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
        Closed += (_, _) =>
        {
            _timer?.Stop();
            _canvas.RemoveFromVisualTree();
        };
    }

    public PixelBounds ScreenBounds => _screen.Bounds;

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
        if (_session.SelectionScreen != _screen || !_session.HasSelection ||
            !_session.Selection.Contains(point))
        {
            return;
        }
        var input = new TextBox
        {
            Text = string.Empty,
            FontSize = 15,
            MinWidth = 260,
            AcceptsReturn = false,
        };
        ContentDialog? dialog = null;
        var confirmed = false;
        dialog = new ContentDialog
        {
            Title = "文字",
            Content = input,
            PrimaryButtonText = "确定",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _canvas.XamlRoot,
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Color.FromArgb(255, 32, 32, 32)),
        };
        input.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                confirmed = true;
                dialog.Hide();
            }
            else if (e.Key == Windows.System.VirtualKey.Escape)
            {
                e.Handled = true;
                dialog.Hide();
            }
        };
        var result = await dialog.ShowAsync();
        if ((result == ContentDialogResult.Primary || confirmed) && input.Text.Trim().Length > 0)
        {
            PushUndo();
            _annotations.Add(new Annotation
            {
                Tool = AnnotationTool.Text,
                Rect = new RectD(point.X, point.Y, 0, 0),
                Text = input.Text.Trim(),
                Color = _color,
                Width = _width,
            });
            _canvas.Invalidate();
        }
        _canvas.Focus(FocusState.Programmatic);
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

    public void Invalidate() => _canvas.Invalidate();

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.CodeActivated && _key)
        {
            DispatcherQueue.TryEnqueue(() => _canvas.Focus(FocusState.Programmatic));
        }
    }

    private void DrawToolbar(Microsoft.Graphics.Canvas.CanvasDrawingSession ds)
    {
        _toolbarHits.Clear();
        if (_session.Mode != ScreenshotMode.Capture || _session.SelectionScreen != _screen ||
            !_session.HasSelection)
        {
            return;
        }

        const double panelWidth = 510;
        const double panelHeight = 34;
        var screenWidth = _screen.Width / _scale;
        var screenHeight = _screen.Height / _scale;
        var selection = _session.Selection;
        var x = selection.X / _scale;
        var y = selection.Bottom / _scale + 8;
        if (y + panelHeight > screenHeight)
        {
            y = selection.Y / _scale - panelHeight - 8;
        }

        x = Math.Clamp(x, 0, Math.Max(0, screenWidth - panelWidth));
        y = Math.Clamp(y, 0, Math.Max(0, screenHeight - panelHeight));
        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect(x, y, panelWidth, panelHeight), 8, 8,
            Color.FromArgb(235, 24, 24, 24));

        var offset = x + 4;
        void Add(double width, string label, Action action, bool selected = false, bool enabled = true,
            Color? color = null)
        {
            var rect = new RectD(offset, y + 4, width, 26);
            _toolbarHits.Add((rect, action));
            if (selected)
            {
                ds.FillRoundedRectangle(
                    new Windows.Foundation.Rect(offset, y + 4, width, 26), 5, 5, Accent);
            }

            if (label.Length > 0)
            {
                var textColor = !enabled
                    ? Color.FromArgb(90, 255, 255, 255)
                    : selected ? Colors.White : Color.FromArgb(230, 255, 255, 255);
                var format = new CanvasTextFormat
                {
                    FontFamily = "Segoe UI",
                    FontSize = label.Length <= 2 ? 12 : 11,
                    HorizontalAlignment = CanvasHorizontalAlignment.Center,
                    VerticalAlignment = CanvasVerticalAlignment.Center,
                };
                ds.DrawText(label, new Windows.Foundation.Rect(offset, y + 4, width, 26), textColor, format);
            }

            if (color is { } dot)
            {
                ds.FillCircle((float)(offset + width / 2), (float)(y + 17), 5, dot);
            }

            offset += width + 2;
        }

        foreach (var (tool, label) in new[]
                 {
                     (AnnotationTool.Select, "↖"), (AnnotationTool.Rectangle, "▭"),
                     (AnnotationTool.Arrow, "↗"), (AnnotationTool.Pen, "✎"),
                     (AnnotationTool.Text, "T"), (AnnotationTool.Mosaic, "▦"),
                 })
        {
            Add(26, label, () =>
            {
                _tool = tool;
                _canvas.Invalidate();
            }, selected: _tool == tool);
        }

        offset += 4;
        Add(24, string.Empty, () =>
        {
            var palette = new[]
            {
                Accent, Color.FromArgb(255, 235, 60, 60), Color.FromArgb(255, 240, 150, 30),
                Color.FromArgb(255, 245, 205, 40), Color.FromArgb(255, 60, 180, 90),
                Color.FromArgb(255, 60, 130, 240), Color.FromArgb(255, 150, 80, 220),
                Color.FromArgb(255, 255, 255, 255), Color.FromArgb(255, 0, 0, 0),
            };
            var index = Array.IndexOf(palette, _color);
            _color = palette[(index + 1) % palette.Length];
            _canvas.Invalidate();
        }, color: _color);
        Add(24, _width.ToString("F0"), () =>
        {
            var widths = new[] { 2.0, 3, 5, 8 };
            var index = Array.IndexOf(widths, _width);
            _width = widths[(index + 1) % widths.Length];
            _canvas.Invalidate();
        });
        Add(24, "↶", Undo, enabled: _undoStack.Count > 0);
        Add(24, "↷", Redo, enabled: _redoStack.Count > 0);
        offset += 4;
        Add(42, "复制", () => _ = _session.CopySelectionAsync());
        Add(42, "保存", () => _ = _session.SaveSelectionAsync(saveAs: false));
        Add(42, "钉图", () => _ = PinSelectionAsync());
        Add(42, "识字", () => _ = _session.RecognizedSelectionAsync());
        Add(42, "翻译", () => _ = _session.TranslateSelectionAsync());
        Add(24, "✕", () => _session.Finish());
    }

    private bool HandleToolbarClick(PointD physical)
    {
        var point = new PointD(physical.X / _scale, physical.Y / _scale);
        foreach (var (rect, action) in _toolbarHits)
        {
            if (rect.Contains(point))
            {
                action();
                return true;
            }
        }

        return false;
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

        var selection = _session.SelectionScreen == _screen ? _session.Selection : (RectD?)null;
        var hole = selection ?? (_hover is { } hover
            ? new RectD(hover.Left, hover.Top, hover.Width, hover.Height)
            : (RectD?)null);
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
                ds.DrawRectangle(outline, Color.FromArgb(255, 255, 255, 255), 1.5f);
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
        }

        if (_key)
        {
            DrawHint(ds, width, height);
            DrawMagnifier(ds, width, height);
        }
        DrawToolbar(ds);
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
        var labelWidth = 84f;
        var x = (float)(rect.X);
        var y = (float)(rect.Y - 26);
        if (y < 4)
        {
            y = (float)(rect.Y + 6);
        }

        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect(x, y, labelWidth, 22), 5, 5, Color.FromArgb(225, 20, 20, 20));
        ds.DrawText(label, x + 8, y + 4, Colors.White, _text);
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
            6, 6, Color.FromArgb(200, 20, 20, 20));
        ds.DrawText(
            hint,
            new Windows.Foundation.Rect((width - textWidth) / 2 + 10, 19, textWidth - 20, 20),
            Colors.White, _small);
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
                var color = Color.FromArgb(
                    255, _screen.Bgra[index + 2], _screen.Bgra[index + 1], _screen.Bgra[index]);
                ds.FillRectangle(
                    new Windows.Foundation.Rect(
                        x + (column + radius) * cell, y + (row + radius) * cell, cell, cell),
                    color);
            }
        }

        ds.DrawRectangle(
            new Windows.Foundation.Rect(x + radius * cell, y + radius * cell, cell, cell),
            Colors.White, 1.5f);
        var globalX = (int)(_screen.Bounds.Left + _cursor.X);
        var globalY = (int)(_screen.Bounds.Top + _cursor.Y);
        var text = $"{globalX}, {globalY}   {_screen.HexAt((int)_cursor.X, (int)_cursor.Y)}";
        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect(x, y + size + 4, size, 22), 4, 4,
            Color.FromArgb(225, 20, 20, 20));
        ds.DrawText(text, x + 6, y + size + 7, Colors.White, _small);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        ReadCursor();
        var point = _cursor;
        _pressed = point;
        _anchor = point;
        _cursor = point;
        if (HandleToolbarClick(point))
        {
            e.Handled = true;
            return;
        }

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
            _session.SelectionScreen == _screen && _session.HasSelection &&
            _tool != AnnotationTool.Select && _session.Selection.Contains(point))
        {
            if (_tool == AnnotationTool.Text)
            {
                _ = ShowTextAsync(point);
                e.Handled = true;
                return;
            }

            _annotationStart = point;
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
            _drag = DragKind.Annotate;
            _canvas.Invalidate();
            e.Handled = true;
            return;
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
        ReadCursor();
        if (_drag == DragKind.None)
        {
            UpdateHover();
        }
        else
        {
            UpdateDrag();
        }

        _canvas.Invalidate();
    }

    private void ReadCursor()
    {
        PInvoke.GetCursorPos(out var cursor);
        _cursor = new PointD(cursor.X - _screen.Bounds.Left, cursor.Y - _screen.Bounds.Top);
    }

    private void UpdateDrag()
    {
        var point = _cursor;
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
                }
                else
                {
                    PushUndo();
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

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(Windows.System.VirtualKey.Control);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        switch (e.Key)
        {
            case Windows.System.VirtualKey.R when !control:
                _tool = AnnotationTool.Rectangle;
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.A when !control:
                _tool = AnnotationTool.Arrow;
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.B when !control:
                _tool = AnnotationTool.Pen;
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.M when !control:
                _tool = AnnotationTool.Mosaic;
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.V when !control:
                _tool = AnnotationTool.Select;
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Escape:
                e.Handled = true;
                if (_session.HasSelection)
                {
                    ResetAnnotations();
                    _session.ClearSelection();
                }
                else
                {
                    _session.Finish();
                }

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
        _session.Finish();
        PinHost.Show(png, global);
    }

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
