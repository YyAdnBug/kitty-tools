// 钉图：截完的图钉在屏幕上（无边框、置顶、可拖、滚轮 10%–500%、双击 / Esc 关闭）。
// Ctrl+C 拷贝、Ctrl+S 存储、Ctrl+Shift+S 另存为、O 识字并拷贝、Ctrl+0 原始大小、Ctrl+W 关闭；右键菜单同这些（同 mac PinPanel，REVIEW R97）。
// 钉图上的字能直接拖选（PLAN-v26 S8，设置 › 截图「钉图上的字可以直接选」）：指针第一次进来时在后台识字，字上按下拖选、Ctrl+C 拷选中的、
// Ctrl+A 全选、右键翻译 / 搜索 / 查词；空白处照旧拖着挪，按住 Alt 在哪都能挪。
using KitTools = KittyTools;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed partial class PinWindow : Window
{
    private readonly byte[] _png;
    private readonly PixelBounds _origin;
    private readonly CursorHost _root;
    private readonly Image _image;
    /// <summary>选中的字的高亮（一行一块，PinTextSelection.Boxes）。</summary>
    private readonly Canvas _marks = new() { IsHitTestVisible = false };
    /// <summary>识字给的词（原图像素）；null = 还没认（或认不了）。</summary>
    private List<(int Line, OcrWord Word)>? _words;
    private bool _reading;
    private int? _anchor;
    private int? _focus;
    private bool _selecting;
    private bool _onText;
    private readonly Border _hover;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer _hoverTimer = null!;
    /// <summary>图的不透明度 0.1–1（PLAN-v9 S10：滑块 10–100%，同 mac PinPanel；以前四档循环）。</summary>
    private double _opacity = 1;
    private readonly HWND _hwnd;
    private double _scale = 1;
    private bool _dragging;
    private int _dragX;
    private int _dragY;
    private int _windowX;
    private int _windowY;
    private (int Left, int Top, int Width, int Height) _inset;

    public PinWindow(byte[] png, PixelBounds origin)
    {
        _png = png;
        _origin = origin;
        _root = new CursorHost
        {
            Background = new SolidColorBrush(Colors.Black),
            IsTabStop = true,
            RequestedTheme = Theme.ElementTheme,
        };
        _image = new Image { IsHitTestVisible = false, Stretch = Stretch.Fill };
        _root.Children.Add(_image);
        _root.Children.Add(_marks);
        _root.SizeChanged += (_, _) => DrawSelection();
        _hover = BuildHoverBar();
        _root.Children.Add(_hover);
        Content = _root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        // 保留系统的细边框：有边框 DWM 才给阴影（PLAN-v2 §3.8「钉图保留边框、拿到圆角和阴影」）。
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        Title = Paths.ProductName + " 钉图";
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);

        _root.PointerPressed += OnPressed;
        _root.PointerMoved += OnMoved;
        _root.PointerReleased += OnReleased;
        _root.PointerWheelChanged += OnWheel;
        _root.PointerEntered += (_, _) => _ = ReadWordsAsync();
        _root.DoubleTapped += (_, _) => Close();
        _root.KeyDown += OnKeyDown;
        _root.RightTapped += OnRightTapped;

        _ = LoadImageAsync();
        // 窗口留着系统的细边框（阴影靠它），客户区比窗口小一圈：先摆一次量出边框，再把它加回窗口，
        // 让客户区（图）正好落在 origin、一像素对一像素。以前图被压进小一圈的客户区：普通钉图糊一点、偏几个像素，
        // 细长的长截图钉图横向压了约 8%（左右的边框比上下多，PLAN-v11 M1 真屏上量的）。
        AppWindow.MoveAndResize(new RectInt32(origin.Left, origin.Top, origin.Width, origin.Height));
        _inset = ClientInset();
        AppWindow.MoveAndResize(new RectInt32(
            origin.Left - _inset.Left, origin.Top - _inset.Top, origin.Width + _inset.Width, origin.Height + _inset.Height));
    }

    /// <summary>客户区相对窗口的左上偏移，和窗口比客户区多出的宽高（物理像素）。</summary>
    private unsafe (int Left, int Top, int Width, int Height) ClientInset()
    {
        if (!PInvoke.GetWindowRect(_hwnd, out var window) || !PInvoke.GetClientRect(_hwnd, out var client))
        {
            return default;
        }

        var corner = new System.Drawing.Point(0, 0);
        PInvoke.ClientToScreen(_hwnd, &corner);
        return (corner.X - window.left, corner.Y - window.top,
            Math.Max(0, window.right - window.left - client.right), Math.Max(0, window.bottom - window.top - client.bottom));
    }

    public void ShowPin()
    {
        AppWindow.Show();
        Activate();
        _root.Focus(FocusState.Programmatic);
        unsafe
        {
            var pref = 1;
            DwmSetWindowAttribute(_hwnd, 33, &pref, sizeof(int));
        }

        // 钉上时从 1.04 倍弹回原大小、淡入（pop，PLAN-v2 §3.8）。
        Motion.Appear(_root);
    }

    private async Task LoadImageAsync()
    {
        try
        {
            _image.Source = await ImageCodec.ToBitmapAsync(_png);
        }
        catch (Exception ex)
        {
            Log.Error("pin.image-failed", ex);
        }
    }

    /// <summary>PLAN-v7 §3.6：钉图右上角悬停出现复制 / 保存 / 关闭三个圆钮。</summary>
    private Border BuildHoverBar()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        Button Action(string glyph, string name, Action click)
        {
            var button = new Button
            {
                Content = new FontIcon
                {
                    Glyph = glyph,
                    FontSize = 12,
                    Foreground = new SolidColorBrush(Colors.White),
                },
                Width = 28,
                Height = 28,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(14),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
            button.Click += (_, _) => click();
            row.Children.Add(button);
            return button;
        }

        Button? opacityButton = null;
        opacityButton = Action("\uE7B3", "透明度", () => ShowOpacityFlyout(opacityButton!));
        Action(Glyphs.Close, "关闭钉图", Close);
        var bar = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(8),
            Padding = new Thickness(2),
            CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Theme.Argb(210, 0, 0, 0)),
            Child = row,
            Opacity = 0,
            IsHitTestVisible = false,
        };
        _hoverTimer = _root.DispatcherQueue.CreateTimer();
        _hoverTimer.Interval = TimeSpan.FromMilliseconds(300);
        _hoverTimer.IsRepeating = false;
        _hoverTimer.Tick += (_, _) =>
        {
            bar.Opacity = 1;
            bar.IsHitTestVisible = true;
        };
        _root.PointerEntered += (_, _) =>
        {
            if (!_hoverTimer.IsRunning && bar.Opacity == 0)
            {
                _hoverTimer.Start();
            }
        };
        _root.PointerExited += (_, _) =>
        {
            _hoverTimer.Stop();
            bar.Opacity = 0;
            bar.IsHitTestVisible = false;
        };
        bar.PointerEntered += (_, _) =>
        {
            _hoverTimer.Stop();
            bar.Opacity = 1;
            bar.IsHitTestVisible = true;
        };
        return bar;
    }

    /// <summary>
    /// 在后台认一次钉图里的字、留下词框（S8）。设置关着、没装识字组件、图比识字引擎的上限还大（框的坐标要换算，ponytail：
    /// 长截图钉图常常超过，那时只能整张挪；要支持就让 OcrService 把缩放比例一起返回）都不认。认码不在这里：选字不拷码。
    /// </summary>
    private async Task ReadWordsAsync()
    {
        if (_words is not null || _reading || !SettingsService.Current.PinSelectsText || !OcrService.HasEngine)
        {
            return;
        }

        _reading = true;
        try
        {
            var decoded = await ImageCodec.PngToBgraAsync(_png);
            if (decoded is not { } image || Math.Max(image.Width, image.Height) > (int)Windows.Media.Ocr.OcrEngine.MaxImageDimension)
            {
                return;
            }

            var (_, lines) = await OcrService.RecognizeAsync(image.Bgra, image.Width, image.Height, joined: false);
            _imageWidth = image.Width;
            _imageHeight = image.Height;
            _words = PinTextSelection.Flatten(lines);
            Log.Info($"pin.words count={_words.Count}");
        }
        catch (Exception ex)
        {
            Log.Error("pin.words-failed", ex);
        }
        finally
        {
            _reading = false;
        }
    }

    private int _imageWidth = 1;
    private int _imageHeight = 1;

    /// <summary>指针在钉图上的位置换成原图的像素。</summary>
    private (double X, double Y) ImagePoint(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_root).Position;
        var width = Math.Max(1, _root.ActualWidth);
        var height = Math.Max(1, _root.ActualHeight);
        return (point.X * _imageWidth / width, point.Y * _imageHeight / height);
    }

    /// <summary>词框外扩多少原图像素也算点在字上（屏幕上约 3 DIP）。</summary>
    private double Slack => 3 * _imageWidth / Math.Max(1, _root.ActualWidth);

    private bool HasSelection => _words is { Count: > 0 } && _anchor is not null && _focus is not null;

    private string SelectedText => HasSelection ? PinTextSelection.Text(_words!, _anchor!.Value, _focus!.Value) : string.Empty;

    private void ClearSelection()
    {
        _anchor = _focus = null;
        DrawSelection();
    }

    private void SelectAll()
    {
        if (_words is { Count: > 0 } words)
        {
            _anchor = 0;
            _focus = words.Count - 1;
            DrawSelection();
        }
    }

    private void DrawSelection()
    {
        _marks.Children.Clear();
        if (!HasSelection)
        {
            return;
        }

        var scaleX = _root.ActualWidth / _imageWidth;
        var scaleY = _root.ActualHeight / _imageHeight;
        var brush = new SolidColorBrush(Theme.AccentColor) { Opacity = 0.35 };
        foreach (var box in PinTextSelection.Boxes(_words!, _anchor!.Value, _focus!.Value))
        {
            var mark = new Microsoft.UI.Xaml.Shapes.Rectangle
            {
                Width = Math.Max(1, (box.Width + 2) * scaleX),
                Height = Math.Max(1, (box.Height + 2) * scaleY),
                Fill = brush,
                RadiusX = 2,
                RadiusY = 2,
            };
            Canvas.SetLeft(mark, (box.X - 1) * scaleX);
            Canvas.SetTop(mark, (box.Y - 1) * scaleY);
            _marks.Children.Add(mark);
        }
    }

    private static bool AltDown() => Microsoft.UI.Input.InputKeyboardSource
        .GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.GetCurrentPoint(_root).Properties.IsRightButtonPressed)
        {
            return;
        }

        // 字上按下：开始选（按住 Alt 照旧挪）；空白处按下：清掉选区、挪钉图
        var (x, y) = ImagePoint(e);
        if (!AltDown() && _words is { } words && PinTextSelection.Hit(words, x, y, Slack) is { } hit)
        {
            _selecting = true;
            _anchor = _focus = hit;
            _root.CapturePointer(e.Pointer);
            DrawSelection();
            e.Handled = true;
            return;
        }

        if (HasSelection)
        {
            ClearSelection();
        }

        _dragging = true;
        _root.CapturePointer(e.Pointer);
        PInvoke.GetCursorPos(out var cursor);
        _dragX = cursor.X;
        _dragY = cursor.Y;
        var position = AppWindow.Position;
        _windowX = position.X;
        _windowY = position.Y;
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_selecting && _words is { } selecting)
        {
            var (x, y) = ImagePoint(e);
            if (PinTextSelection.Nearest(selecting, x, y) is { } focus && focus != _focus)
            {
                _focus = focus;
                DrawSelection();
            }

            e.Handled = true;
            return;
        }

        if (!_dragging)
        {
            // 停在字上是 I 形光标、按住 Alt 或在空白处是箭头（按下就挪）
            var (x, y) = ImagePoint(e);
            var onText = !AltDown() && _words is { } words && PinTextSelection.Hit(words, x, y, Slack) is not null;
            if (onText != _onText)
            {
                _onText = onText;
                _root.SetCursor(Microsoft.UI.Input.InputSystemCursor.Create(
                    onText ? Microsoft.UI.Input.InputSystemCursorShape.IBeam : Microsoft.UI.Input.InputSystemCursorShape.Arrow));
            }

            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        AppWindow.Move(new PointInt32(
            _windowX + cursor.X - _dragX,
            _windowY + cursor.Y - _dragY));
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_selecting)
        {
            _selecting = false;
            _root.ReleasePointerCaptures();
            e.Handled = true;
            return;
        }

        if (_dragging)
        {
            _dragging = false;
            _root.ReleasePointerCaptures();
            e.Handled = true;
        }
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(_root).Properties.MouseWheelDelta;
        Zoom(delta > 0 ? 1.1 : 0.9);
        e.Handled = true;
    }

    private void Zoom(double factor)
    {
        _scale = Math.Clamp(_scale * factor, 0.1, 5);
        var width = Math.Max(1, (int)Math.Round(_origin.Width * _scale));
        var height = Math.Max(1, (int)Math.Round(_origin.Height * _scale));
        var centerX = AppWindow.Position.X + AppWindow.Size.Width / 2;
        var centerY = AppWindow.Position.Y + AppWindow.Size.Height / 2;
        width += _inset.Width;
        height += _inset.Height;
        AppWindow.MoveAndResize(new RectInt32(centerX - width / 2, centerY - height / 2, width, height));
    }

    private async void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                if (HasSelection)
                {
                    ClearSelection();
                }
                else
                {
                    Close();
                }

                break;
            case VirtualKey.C when control:
                e.Handled = true;
                if (HasSelection)
                {
                    CopySelected();
                }
                else
                {
                    _ = CopyAsync();
                }

                break;
            case VirtualKey.A when control && SettingsService.Current.PinSelectsText:
                e.Handled = true;
                await ReadWordsAsync();
                SelectAll();
                break;
            case VirtualKey.S when control:
                e.Handled = true;
                if (shift)
                {
                    await ScreenshotOutput.SavePngAsAsync(AppWindow, _png);
                }
                else
                {
                    // 走截图的存储（「截图 日期 时间.png」、重名加序号，同 mac ScreenshotOutput，REVIEW R97）
                    await ScreenshotOutput.QuickSavePngAsync(_png);
                }

                break;
            case VirtualKey.O when !control:
                e.Handled = true;
                await RecognizeAsync();
                break;
            // 原始大小 Ctrl+0、关闭 Ctrl+W（同 mac ⌘0、⌘W，REVIEW R97：原来是不带修饰键的 0）
            case VirtualKey.Number0 when control:
                e.Handled = true;
                Zoom(1 / _scale);
                break;
            case VirtualKey.W when control:
                e.Handled = true;
                Close();
                break;
        }
    }

    private void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        // 同 mac PinPanel.commands 的叫法和先后（REVIEW R97）：拷贝 / 识字并拷贝 / 翻译 / 存储到「X」/ 另存为… ｜ 透明度 / 原始大小 ｜ 关闭
        var menu = new MenuFlyout();
        if (HasSelection && SelectedText is { Length: > 0 } selected)
        {
            // 选着字：先是对这段字的几样（S8，同 mac 19180341）
            Add(menu, "拷贝选中的文字", CopySelected, "Ctrl+C");
            if (Features.IsOn(Feature.Translate))
            {
                Add(menu, "翻译选中的文字", () => TranslateHost.ShowRecognized(selected));
                if (WordLookup.IsWord(selected))
                {
                    Add(menu, "查词", () => TranslateHost.ShowText(selected));
                }
            }

            if (Features.IsOn(Feature.Launcher) &&
                WebSearch.Primary(SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults()) is { } engine)
            {
                var title = selected.Length > 12 ? selected[..12] + "…" : selected;
                Add(menu, $"用{WebSearch.Title(engine)}搜索「{title.Replace('\n', ' ')}」",
                    () => LauncherOpeners.Start(WebSearch.OpenUrl(WebSearch.Url(engine, selected))));
            }

            menu.Items.Add(new MenuFlyoutSeparator());
        }

        Add(menu, "拷贝", () => _ = CopyAsync(), HasSelection ? null : "Ctrl+C");
        Add(menu, "识字并拷贝", () => _ = RecognizeAsync(), "O");
        if (Features.IsOn(Feature.Translate))
        {
            Add(menu, "翻译", () => _ = TranslateAsync());
        }

        var folder = Path.GetFileName(ScreenshotOutput.SaveFolder.TrimEnd(Path.DirectorySeparatorChar));
        Add(menu, $"存储到「{folder}」", () => _ = ScreenshotOutput.QuickSavePngAsync(_png), "Ctrl+S");
        Add(menu, "另存为…", () => _ = ScreenshotOutput.SavePngAsAsync(AppWindow, _png), "Ctrl+Shift+S");
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(menu, $"透明度 {Math.Round(_opacity * 100)}%…", () => ShowOpacityFlyout(_root));
        Add(menu, "原始大小", () => Zoom(1 / _scale), "Ctrl+0");
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(menu, "关闭", Close, "Ctrl+W");
        menu.ShowAt(_root, new FlyoutShowOptions { Position = e.GetPosition(_root) });
        e.Handled = true;
    }

    /// <summary>透明度滑块（S10，10–100%，一格 10%）：拖的时候图跟着变；MenuFlyout 放不了滑块，另开一个小浮层。</summary>
    private void ShowOpacityFlyout(FrameworkElement anchor)
    {
        var slider = new Slider
        {
            Header = "透明度",
            Minimum = 10,
            Maximum = 100,
            StepFrequency = 10,
            SmallChange = 10,
            LargeChange = 10,
            Value = Math.Round(_opacity * 100),
            Width = 200,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(slider, "钉图透明度");
        slider.ValueChanged += (_, args) =>
        {
            _opacity = Math.Clamp(args.NewValue / 100, 0.1, 1);
            _image.Opacity = _opacity;
        };
        new Flyout { Content = slider }.ShowAt(anchor);
    }

    private static void Add(MenuFlyout menu, string text, Action action, string? key = null)
    {
        var item = new MenuFlyoutItem { Text = text, KeyboardAcceleratorTextOverride = key ?? string.Empty };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    /// <summary>自检用（PinTextProbe）：认过的词有几个。</summary>
    public int ProbeWordCount => _words?.Count ?? -1;

    /// <summary>自检用：认字后全选（line 为 null）或只选那一行，返回选中的字。</summary>
    public async Task<string> ProbeSelectAsync(int? line)
    {
        await ReadWordsAsync();
        if (_words is not { Count: > 0 } words)
        {
            return string.Empty;
        }

        if (line is { } only && words.FindIndex(word => word.Line == only) is var first and >= 0)
        {
            _anchor = first;
            _focus = words.FindLastIndex(word => word.Line == only);
            DrawSelection();
        }
        else
        {
            SelectAll();
        }

        return SelectedText;
    }

    /// <summary>拷贝选中的字（识出来的新文字，记进剪贴板历史）。</summary>
    private void CopySelected()
    {
        var text = SelectedText;
        if (text.Length == 0 || !ClipboardWriter.WriteText(text))
        {
            return;
        }

        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(text);
        var preview = text.Replace('\n', ' ').Trim();
        NoticeHost.Show("已复制选中的文字", preview.Length > 30 ? preview[..30] + "…" : preview, NoticeTone.Normal);
    }

    private async Task CopyAsync()
    {
        // 同框选后的拷贝（PLAN-v15）：设置里选了 PNG 文件时剪贴板里是文件；DIB 在那边后台转好再写（REVIEW R48）。
        // 尺寸按图本身的像素：长截图钉出来比选区长（同角落卡，PLAN-v11 M16）。
        var (width, height) = KittyTools.Core.PngInfo.Size(_png) ?? (_origin.Width, _origin.Height);
        await ScreenshotOutput.CopyPngAsync(_png, width, height, "已复制钉图", "钉图", showSize: false);
    }

    /// <summary>
    /// 认出钉图里的字：没有识字组件、一个字都没认出来时提示并返回 null。decoded 是已经解好的钉图像素（识字前先认过码的那一份），没有就现解。
    /// </summary>
    private async Task<string?> RecognizedTextAsync((byte[] Bgra, int Width, int Height)? decoded = null)
    {
        if (!OcrService.HasEngine)
        {
            NoticeHost.Show("没装中文识字组件", string.Empty, NoticeTone.Warning,
                NoticeActions.SystemSettings("ms-settings:regionlanguage"));
            return null;
        }

        decoded ??= await ImageCodec.PngToBgraAsync(_png);
        if (decoded is not { } image)
        {
            return null;
        }

        var (text, _) = await OcrService.RecognizeAsync(
            image.Bgra, image.Width, image.Height, joined: SettingsService.Current.OcrJoinLines);
        if (string.IsNullOrWhiteSpace(text))
        {
            NoticeHost.Show("没有识别到文字", string.Empty, NoticeTone.Warning);
            return null;
        }

        return text;
    }

    /// <summary>右键「翻译」：识字后照截图翻译那样开浮窗（原文按设置记进剪贴板历史）。</summary>
    private async Task TranslateAsync()
    {
        try
        {
            if (await RecognizedTextAsync() is { } text)
            {
                TranslateHost.ShowRecognized(text);
            }
        }
        catch (Exception ex)
        {
            Log.Error("pin.translate-failed", ex);
            NoticeHost.Show("识字失败", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private async Task RecognizeAsync()
    {
        try
        {
            // 钉图里有二维码 / 条码就拷码的内容，不再识字（REVIEW R105，同 mac 钉图的识字）；右键「翻译」不认码，同 mac。
            // 解好的像素接着交给识字，不再解一遍
            var decoded = await ImageCodec.PngToBgraAsync(_png);
            if (decoded is { } image && await OcrService.CopyBarcodesAsync(image.Bgra, image.Width, image.Height))
            {
                return;
            }

            if (await RecognizedTextAsync(decoded) is not { } text)
            {
                return;
            }

            if (ClipboardWriter.WriteText(text))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(text);
            }

            var preview = text.Replace('\n', ' ').Trim();
            NoticeHost.Show("已复制识别的文字", preview.Length > 30 ? preview[..30] + "…" : preview,
                NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("pin.ocr-failed", ex);
            NoticeHost.Show("识字失败", ex.Message, NoticeTone.Error);
        }
    }

    [System.Runtime.InteropServices.LibraryImport("dwmapi.dll")]
    private static unsafe partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, int* value, int size);
}

internal static class PinHost
{
    private static readonly List<PinWindow> Windows = new();

    /// <summary>最后钉上的那张（自检用）。</summary>
    public static PinWindow? Last => Windows.Count > 0 ? Windows[^1] : null;

    /// <summary>屏幕上有几张钉图（托盘、启动器里「隐藏 / 关闭全部钉图」只在有钉图时列出来）。</summary>
    public static int Count => Windows.Count;

    /// <summary>钉了一张、关了一张、全部藏起 / 显示回来（主界面开着时那两格跟着换，PLAN-v20 M1）。在界面线程上发。</summary>
    public static event Action? Changed;

    /// <summary>托盘「隐藏全部钉图」之后（PLAN-v9 G1、S10，同 mac 菜单栏）：再钉新的一张时先全部显示回来。</summary>
    public static bool AllHidden { get; private set; }

    /// <summary>长截图时让开的那几张（StepAside 藏起来的，StepBack 放回）。</summary>
    private static readonly List<PinWindow> SteppedAside = new();

    /// <summary>
    /// 长截图开始（REVIEW G3，mac PinPanel 体检 B40）：和选区（物理像素、全局坐标）相交的钉图让开，不然会被拍进长图、压在选区上还吃掉滚轮。
    /// mac 淡到 0.3、不接鼠标；Windows 直接藏起来：点穿要分层窗口，分层窗口再设「不进截图」在用户机器上整个看不见（2026-10-29 实测）。
    /// </summary>
    public static void StepAside(PixelBounds rect)
    {
        StepBack();
        foreach (var window in Windows.ToList())
        {
            try
            {
                var position = window.AppWindow.Position;
                var size = window.AppWindow.Size;
                if (window.AppWindow.IsVisible && position.X < rect.Right && rect.Left < position.X + size.Width &&
                    position.Y < rect.Bottom && rect.Top < position.Y + size.Height)
                {
                    window.AppWindow.Hide();
                    SteppedAside.Add(window);
                }
            }
            catch
            {
                // 已经关掉的跳过。
            }
        }
    }

    /// <summary>长截图结束（拼完、放弃）：让开的放回原处；这中间关掉的、「隐藏全部钉图」藏着的不管。</summary>
    public static void StepBack()
    {
        foreach (var window in SteppedAside)
        {
            try
            {
                if (Windows.Contains(window) && !AllHidden)
                {
                    window.AppWindow.Show(false);
                }
            }
            catch
            {
                // 已经关掉的跳过。
            }
        }

        SteppedAside.Clear();
    }

    /// <summary>显示 / 隐藏全部钉图（不关掉，位置、缩放、透明度都留着）。</summary>
    public static void ToggleHidden()
    {
        AllHidden = !AllHidden && Windows.Count > 0;
        Changed?.Invoke();
        foreach (var window in Windows.ToList())
        {
            try
            {
                if (AllHidden)
                {
                    window.AppWindow.Hide();
                }
                else
                {
                    window.AppWindow.Show(false);
                }
            }
            catch
            {
                // 已经关掉的跳过。
            }
        }
    }

    public static void Show(byte[] png, PixelBounds bounds)
    {
        if (AllHidden)
        {
            ToggleHidden();
        }

        var window = new PinWindow(png, bounds);
        Windows.Add(window);
        window.Closed += (_, _) =>
        {
            Windows.Remove(window);
            Changed?.Invoke();
        };
        Changed?.Invoke();
        window.ShowPin();
    }

    /// <summary>
    /// 钉到鼠标所在屏、以鼠标为中心（剪贴板面板的钉图、「钉住剪贴板内容」共用）：最大占可见区 80%，夹在可见区里。
    /// offset 是连钉几张时往右下错开的量；那个位置已经有一张钉图时再错开 24（连按几下快捷键不叠成一张，同 mac clipboardFrame）。
    /// </summary>
    public static void ShowNearCursor(byte[] png, int imageWidth, int imageHeight, int offset = 0)
    {
        PInvoke.GetCursorPos(out var cursor);
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromPoint(
            new PointInt32(cursor.X, cursor.Y), Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var scale = Math.Min(1, Math.Min(area.Width * 0.8 / imageWidth, area.Height * 0.8 / imageHeight));
        var width = Math.Max(1, (int)(imageWidth * scale));
        var height = Math.Max(1, (int)(imageHeight * scale));
        for (var tries = 0; ; tries++)
        {
            var left = Math.Clamp(cursor.X - width / 2 + offset, area.X, area.X + area.Width - width);
            var top = Math.Clamp(cursor.Y - height / 2 + offset, area.Y, area.Y + area.Height - height);
            if (tries < 20 && Windows.Any(window =>
                    Math.Abs(window.AppWindow.Position.X - left) <= 2 && Math.Abs(window.AppWindow.Position.Y - top) <= 2))
            {
                offset += 24;
                continue;
            }

            Show(png, new PixelBounds(left, top, left + width, top + height));
            return;
        }
    }

    /// <summary>
    /// 「钉住剪贴板内容」（PLAN-v9 F3，同 mac AppDelegate.pinClipboard）：剪贴板里是图（或复制的是图片文件）就钉到鼠标旁边；
    /// 没有图、是文字时把文字排成卡片钉上去（PLAN-v16 S3，issue #4）；都没有就提示。剪贴板只读、不记历史。
    /// </summary>
    public static async Task PinClipboardAsync()
    {
        if (ClipboardFormats.ReadImageForPin() is not { } source)
        {
            if (ClipboardFormats.ReadTextForPin() is { } text)
            {
                await PinTextAsync(text);
                return;
            }

            NoticeHost.Show("剪贴板里没有图片或文字", string.Empty, NoticeTone.Warning);
            return;
        }

        try
        {
            var data = source.File is { } file ? await File.ReadAllBytesAsync(file) : source.Image!;
            var decoded = source.IsDib ? await ImageCodec.DibToPngAsync(data) : await ImageCodec.AnyToPngAsync(data);
            if (decoded is not { } image)
            {
                NoticeHost.Show("没能钉到屏幕",
                    source.File is { } name ? $"读不出「{Path.GetFileName(name)}」" : "读不出这张图片", NoticeTone.Error);
                return;
            }

            ShowNearCursor(image.Png, image.Width, image.Height);
            Log.Info("pin.clipboard");
        }
        catch (Exception ex)
        {
            Log.Error("pin.clipboard-failed", ex);
            NoticeHost.Show("没能钉到屏幕", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>
    /// 把一段文字排成卡片钉到鼠标旁边（「钉住剪贴板内容」、剪贴板历史里文字条目的「钉到屏幕」）：卡片最大宽 560、不超过可见区六成，
    /// 高到可见区八成；按鼠标所在屏的缩放出像素。offset 同 ShowNearCursor（连钉几条依次错开）。
    /// </summary>
    public static async Task PinTextAsync(string text, int offset = 0)
    {
        try
        {
            PInvoke.GetCursorPos(out var cursor);
            var display = Displays.AtPoint(cursor.X, cursor.Y);
            var scale = display.Scale <= 0 ? 1 : display.Scale;
            var (limitWidth, limitHeight) = PinText.CardLimit(
                (display.Work.Right - display.Work.Left) / scale, (display.Work.Bottom - display.Work.Top) / scale);
            var card = await PinTextCard.RenderAsync(text, scale, limitWidth, limitHeight, Theme.EffectiveTheme == ElementTheme.Dark);
            if (card is not { } image)
            {
                NoticeHost.Show("没能钉到屏幕", "排不出这段文字", NoticeTone.Error);
                return;
            }

            ShowNearCursor(image.Png, image.Width, image.Height, offset);
            Log.Info("pin.text");
        }
        catch (Exception ex)
        {
            Log.Error("pin.text-failed", ex);
            NoticeHost.Show("没能钉到屏幕", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>全部关掉（内存探针、退出时用）。</summary>
    public static void CloseAll()
    {
        foreach (var window in Windows.ToList())
        {
            try
            {
                window.Close();
            }
            catch
            {
                // 已经关掉的跳过。
            }
        }

        Windows.Clear();
        AllHidden = false;
    }
}
