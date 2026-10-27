// 截图遮罩里贴着选区的控件（PLAN-v9-annotate §7、PLAN-v9 S4 / S5，第 5e 批；主体在 SelectionOverlayWindow.cs）：
// - 尺寸胶囊（U7，mac SizeField）：像素宽高，调整选区时点数字就地变成两个输入框（Tab 切、Enter 生效、Esc 放弃、点别处提交），
//   右边「自由 ▾」比例菜单（自由 / 1:1 / 4:3 / 3:2 / 16:9 / 9:16），选了立刻套用并锁住；
// - 工具栏放哪（U5）、松手 40 ms 后长出来 / 拖动选区时淡出让位（U4）；当前工具的底块在工具间滑动（U3）；
// - 读屏播报（U10）、切到录屏（S5）。
// Windows 版全 App 不做「从小放大」（Motion.cs 文件头）：mac 的 pop 在这里是淡入 + 6 px 位移，底块收起是淡出。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow
{
    /// <summary>尺寸胶囊和输入框的字（等宽，数字不跳）。</summary>
    private static readonly FontFamily SizeFont = new("Cascadia Mono, Consolas");

    private Border _sizeCapsule = null!;
    private readonly TextBlock _widthText = SizeText();
    private readonly TextBlock _heightText = SizeText();
    private Button _widthLabel = null!;
    private Button _heightLabel = null!;
    private TextBox _widthBox = null!;
    private TextBox _heightBox = null!;
    private Button _ratioButton = null!;
    private readonly TextBlock _ratioText = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private bool _sizeEditing;
    private bool _sizeInteractive;

    /// <summary>工具栏在选区哪一侧（样式托盘跟着翻）、是不是正在让位（拖动 / 缩放 / 平移选区时淡出）。</summary>
    private ToolbarSide _toolbarSide;
    private bool _toolbarYielding;
    /// <summary>松手后等那 40 ms 的工具栏：藏着的就先别露出来（不然整亮一下再淡入）。</summary>
    private bool _toolbarPending;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _toolbarTimer;

    /// <summary>当前工具的粉色底块和它现在停在哪个工具上（null = 收着）。</summary>
    private Border? _toolChip;
    private AnnotationKind? _chipTool;

    /// <summary>拖动框选途中按着空格：整块平移（按下鼠标前就按着的不算）；上一次拖到哪（平移按增量走）。</summary>
    private bool _spaceDown;
    private PointD _lastDrag;

    /// <summary>按着 Ctrl 时的十字准线（PLAN-v9 S4，mac 是 ⌘）。</summary>
    private bool _crosshair;

    private static TextBlock SizeText() => new()
    {
        FontFamily = SizeFont,
        FontSize = 12,
        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        Foreground = new SolidColorBrush(Theme.Shot.HudText),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>尺寸胶囊：HUD 底、圆角 6、高 26；[宽] × [高] | 比例 ▾。</summary>
    private Border BuildSizeCapsule()
    {
        _widthLabel = SizeLabel(_widthText, "宽度（像素），点一下输入", height: false);
        _heightLabel = SizeLabel(_heightText, "高度（像素），点一下输入", height: true);
        _widthBox = SizeBox("宽度（像素）");
        _heightBox = SizeBox("高度（像素）");
        var widthCell = new Grid { VerticalAlignment = VerticalAlignment.Center };
        widthCell.Children.Add(_widthLabel);
        widthCell.Children.Add(_widthBox);
        var heightCell = new Grid { VerticalAlignment = VerticalAlignment.Center };
        heightCell.Children.Add(_heightLabel);
        heightCell.Children.Add(_heightBox);
        var times = new TextBlock
        {
            Text = "×",
            FontFamily = SizeFont,
            FontSize = 12,
            Foreground = new SolidColorBrush(Theme.Argb(153, 255, 255, 255)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(2, 0, 2, 0),
        };
        AutomationProperties.SetAccessibilityView(times, AccessibilityView.Raw);

        _ratioText.Foreground = new SolidColorBrush(Theme.Shot.HudText);
        var ratioContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        ratioContent.Children.Add(_ratioText);
        ratioContent.Children.Add(new FontIcon
        {
            Glyph = Glyphs.ChevronDown,
            FontSize = 8,
            Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
            VerticalAlignment = VerticalAlignment.Center,
        });
        _ratioButton = new Button
        {
            Content = ratioContent,
            Height = 20,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(6, 0, 6, 0),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 0, 0),
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(_ratioButton, "选区比例");
        ToolTipService.SetToolTip(_ratioButton, "锁住选区比例");
        _ratioButton.Click += (_, _) => ShowRatioMenu();

        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(widthCell);
        row.Children.Add(times);
        row.Children.Add(heightCell);
        row.Children.Add(_ratioButton);
        var capsule = new Border
        {
            Height = 26,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(4, 0, 3, 0),
            Background = new SolidColorBrush(Theme.Shot.LabelBackground),
            BorderBrush = new SolidColorBrush(Theme.Shot.HudStroke),
            BorderThickness = new Thickness(0.5),
            Child = row,
            Visibility = Visibility.Collapsed,
        };
        Canvas.SetZIndex(capsule, 10);
        return capsule;
    }

    private Button SizeLabel(TextBlock text, string name, bool height)
    {
        var button = new Button
        {
            Content = text,
            Height = 20,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(3, 0, 3, 0),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(button, name);
        button.Click += (_, _) => BeginSizeEditing(height);
        return button;
    }

    /// <summary>就地输入的框：等宽 12、白 0.10 底，有焦点时 1 DIP 粉 0.75 的边（mac 焦点环）。</summary>
    private TextBox SizeBox(string name)
    {
        var box = new TextBox
        {
            Width = 54,
            Height = 20,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(4, 1, 4, 0),
            FontFamily = SizeFont,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1),
            Visibility = Visibility.Collapsed,
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            MaxLength = 5,
            SelectionHighlightColor = new SolidColorBrush(Theme.Argb(102, Accent.R, Accent.G, Accent.B)),
        };
        var fill = new SolidColorBrush(Theme.Argb(26, 255, 255, 255));
        var white = new SolidColorBrush(Theme.Shot.HudText);
        foreach (var key in new[] { "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused" })
        {
            box.Resources[key] = fill;
        }

        foreach (var key in new[] { "TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused" })
        {
            box.Resources[key] = white;
        }

        box.Resources["TextControlBorderBrush"] = new SolidColorBrush(Colors.Transparent);
        box.Resources["TextControlBorderBrushPointerOver"] = new SolidColorBrush(Colors.Transparent);
        box.Resources["TextControlBorderBrushFocused"] = new SolidColorBrush(Theme.Argb(191, Accent.R, Accent.G, Accent.B));
        box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(1);
        AutomationProperties.SetName(box, name);
        box.PreviewKeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case Windows.System.VirtualKey.Enter:
                    e.Handled = true;
                    EndSizeEditing(commit: true);
                    break;
                case Windows.System.VirtualKey.Escape:
                    // 尺寸输入在 Esc 的顺序里排最前（U8）：放弃输入，不退截图
                    e.Handled = true;
                    EndSizeEditing(commit: false);
                    break;
                case Windows.System.VirtualKey.Tab:
                    // Tab / Shift+Tab 只在宽、高之间切
                    e.Handled = true;
                    var other = ReferenceEquals(box, _widthBox) ? _heightBox : _widthBox;
                    other.Focus(FocusState.Keyboard);
                    other.SelectAll();
                    break;
            }
        };
        box.LostFocus += (_, _) =>
            DispatcherQueue.TryEnqueue(() =>
            {
                // 焦点在宽、高之间切不算；点到别处就按输入的提交（mac：点别处提交）
                var focused = FocusManager.GetFocusedElement(_root.XamlRoot);
                if (_sizeEditing && !ReferenceEquals(focused, _widthBox) && !ReferenceEquals(focused, _heightBox))
                {
                    EndSizeEditing(commit: true);
                }
            });
        return box;
    }

    /// <summary>点了宽 / 高的数字：两个都变成输入框，点的那个全选（先收下打着的字）。</summary>
    private void BeginSizeEditing(bool height)
    {
        if (!_sizeInteractive || _drag != DragKind.None || !_session.HasSelection || _session.SelectionScreen != _screen)
        {
            return;
        }

        CommitText();
        _sizeEditing = true;
        _widthBox.Text = Math.Round(_session.Selection.Width).ToString(System.Globalization.CultureInfo.InvariantCulture);
        _heightBox.Text = Math.Round(_session.Selection.Height).ToString(System.Globalization.CultureInfo.InvariantCulture);
        _widthLabel.Visibility = Visibility.Collapsed;
        _heightLabel.Visibility = Visibility.Collapsed;
        _widthBox.Visibility = Visibility.Visible;
        _heightBox.Visibility = Visibility.Visible;
        var target = height ? _heightBox : _widthBox;
        target.Focus(FocusState.Keyboard);
        target.SelectAll();
        UpdateSizeCapsule();
    }

    /// <summary>收起输入框：commit 时按输入的像素改选区（左上角不动，SelectionChrome.Sized），读不懂的那一项不改。</summary>
    private void EndSizeEditing(bool commit)
    {
        if (!_sizeEditing)
        {
            return;
        }

        _sizeEditing = false;
        _widthBox.Visibility = Visibility.Collapsed;
        _heightBox.Visibility = Visibility.Collapsed;
        _widthLabel.Visibility = Visibility.Visible;
        _heightLabel.Visibility = Visibility.Visible;
        if (commit && _session.HasSelection && _session.SelectionScreen == _screen)
        {
            var selection = _session.Selection;
            var width = int.TryParse(_widthBox.Text, out var w) && w > 0 ? w : selection.Width;
            var height = int.TryParse(_heightBox.Text, out var h) && h > 0 ? h : selection.Height;
            var sized = SelectionChrome.Sized(selection, width, height, new RectD(0, 0, _screen.Width, _screen.Height));
            if (sized != selection)
            {
                _session.SetSelection(_screen, sized);
                Announce($"选区 {Math.Round(sized.Width)} × {Math.Round(sized.Height)}");
            }
        }

        UpdateSizeCapsule();
        _canvas.Focus(FocusState.Programmatic);
    }

    /// <summary>比例菜单：选了立刻套用（宽不变、高按比例，顶边和水平中心不动）并锁住，之后框选、拖手柄都按它；「自由」解锁。</summary>
    private void ShowRatioMenu()
    {
        EndSizeEditing(commit: true);
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.Bottom };
        foreach (var (title, value) in SelectionChrome.Ratios)
        {
            var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = _session.LockedRatio == value };
            var ratio = value;
            item.Click += (_, _) =>
            {
                _session.LockedRatio = ratio;
                if (ratio is { } locked && _session.HasSelection && _session.SelectionScreen == _screen)
                {
                    _session.SetSelection(
                        _screen, RegionMath.ApplyingRatio(locked, _session.Selection, new RectD(0, 0, _screen.Width, _screen.Height)));
                }
                else
                {
                    _session.InvalidateAll();
                }

                Announce(ratio is null ? "比例自由" : $"比例锁定 {title}");
            };
            menu.Items.Add(item);
        }

        menu.ShowAt(_ratioButton);
    }

    /// <summary>尺寸胶囊跟上选区：数字、比例按钮（锁着时粉底）、位置（SelectionChrome.SizeCapsule 避开工具栏和顶部提示）。</summary>
    private void UpdateSizeCapsule()
    {
        if (_session.SelectionScreen != _screen || !_session.HasSelection)
        {
            EndSizeEditing(commit: false);
            _sizeCapsule.Visibility = Visibility.Collapsed;
            return;
        }

        var selection = _session.Selection;
        _widthText.Text = Math.Round(selection.Width).ToString(System.Globalization.CultureInfo.InvariantCulture);
        _heightText.Text = Math.Round(selection.Height).ToString(System.Globalization.CultureInfo.InvariantCulture);
        _ratioText.Text = SelectionChrome.RatioTitle(_session.LockedRatio);
        var locked = _session.LockedRatio is not null;
        _ratioButton.Background = new SolidColorBrush(locked ? Accent : Colors.Transparent);
        _ratioButton.Visibility = _session.Mode is ScreenshotMode.Ocr or ScreenshotMode.Translate
            ? Visibility.Collapsed
            : Visibility.Visible;
        _sizeCapsule.Visibility = Visibility.Visible;
        _sizeCapsule.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = _sizeCapsule.DesiredSize;
        var screenWidth = _screen.Width / _scale;
        var screenHeight = _screen.Height / _scale;
        var avoid = new List<RectD>();
        if (_key)
        {
            var hintWidth = Math.Min(screenWidth - 32, 640);
            avoid.Add(new RectD((screenWidth - hintWidth) / 2, 10, hintWidth, 34));
        }

        if (_toolbar.Visibility == Visibility.Visible)
        {
            avoid.Add(new RectD(Canvas.GetLeft(_toolbar), Canvas.GetTop(_toolbar), _toolbar.DesiredSize.Width, _toolbar.DesiredSize.Height));
        }

        var dip = ToDip(selection);
        var (x, y, interactive) = SelectionChrome.SizeCapsule(
            new RectD(dip.X, dip.Y, dip.Width, dip.Height), size.Width, size.Height, screenWidth, screenHeight, avoid);
        Canvas.SetLeft(_sizeCapsule, x);
        Canvas.SetTop(_sizeCapsule, y);
        // 框选、拖边时只读、不接点（不挡拖动）；放不下只能压在选区里时也只读
        _sizeInteractive = interactive && _drag == DragKind.None;
        _sizeCapsule.IsHitTestVisible = _sizeInteractive || _sizeEditing;
    }

    /// <summary>
    /// 工具栏放哪（U5）：选区下方 10、水平居中，下面连样式托盘放不下放上方，都放不下放进选区底部（SelectionChrome.Toolbar）。
    /// 拖动 / 缩放 / 平移选区时 0.10 s 淡出让位，松手 40 ms 后从靠选区那条边长出来（U4；画标注、拖标注时不动）。
    /// 截图和录屏（录制条）都有；识字、截图翻译没有。
    /// </summary>
    private void PositionToolbar()
    {
        if (_session.Mode is not (ScreenshotMode.Capture or ScreenshotMode.Record) || _session.SelectionScreen != _screen ||
            !_session.HasSelection)
        {
            _toolbar.Visibility = Visibility.Collapsed;
            _toolbarYielding = false;
            _toolbarPending = false;
            UpdateSizeCapsule();
            return;
        }

        var yielding = _drag is DragKind.Draw or DragKind.Resize or DragKind.Move;
        // 本来藏着的（第一次框选、刚切过来）在让位和等长出来期间接着藏：先露出来再淡出会闪一下
        if (_toolbar.Visibility == Visibility.Visible || !(yielding || _toolbarYielding || _toolbarPending))
        {
            _toolbar.Visibility = Visibility.Visible;
        }

        _toolbar.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = _toolbar.DesiredSize;
        var dip = ToDip(_session.Selection);
        var tray = _session.Mode == ScreenshotMode.Capture ? 6 + 34 : 0;
        var (x, y, side) = SelectionChrome.Toolbar(
            new RectD(dip.X, dip.Y, dip.Width, dip.Height), size.Width, size.Height, tray, _screen.Width / _scale, _screen.Height / _scale);
        _toolbarSide = side;
        Canvas.SetLeft(_toolbar, x);
        Canvas.SetTop(_toolbar, y);

        if (yielding && !_toolbarYielding)
        {
            _toolbarYielding = true;
            _toolbarPending = false;
            _toolbarTimer?.Stop();
            _toolbar.IsHitTestVisible = false;
            _styleTray.IsHitTestVisible = false;
            Motion.Fade(_toolbar, 0f, 0.10);
            Motion.Fade(_styleTray, 0f, 0.10);
        }
        else if (!yielding && _toolbarYielding)
        {
            _toolbarYielding = false;
            _toolbarPending = true;
            _toolbarTimer ??= DispatcherQueue.CreateTimer();
            _toolbarTimer.Interval = TimeSpan.FromMilliseconds(40);
            _toolbarTimer.IsRepeating = false;
            _toolbarTimer.Tick -= OnToolbarTimer;
            _toolbarTimer.Tick += OnToolbarTimer;
            _toolbarTimer.Start();
        }

        UpdateSizeCapsule();
    }

    /// <summary>松手 40 ms 后：工具栏从靠选区那条边长出来（在选区下方往下落，上方 / 选区里往上升），托盘淡入。</summary>
    private void OnToolbarTimer(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        _toolbarPending = false;
        if (_toolbarYielding)
        {
            return;
        }

        PositionToolbar();
        UpdateToolbarChrome();
        if (_toolbar.Visibility != Visibility.Visible)
        {
            return;
        }

        _toolbar.IsHitTestVisible = true;
        _styleTray.IsHitTestVisible = true;
        Motion.Entrance(_toolbar, MotionCurve.Pop, rise: _toolbarSide == ToolbarSide.Below ? -6 : 6);
        Motion.FadeIn(_styleTray, MotionCurves.FadeInSeconds);
    }

    /// <summary>
    /// 当前工具的底块（U3）：在工具间 glide 滑过去；从无到有在那个工具上淡入，收起淡出（不放大缩小，Motion.cs 文件头）。
    /// 工具按钮 32 宽、间距 2。
    /// </summary>
    private void UpdateToolChip()
    {
        if (_toolChip is null || _chipTool == _tool)
        {
            return;
        }

        var previous = _chipTool;
        _chipTool = _tool;
        if (_tool is not { } tool)
        {
            Motion.Fade(_toolChip, 0f, 0.10);
            return;
        }

        var x = Array.IndexOf(AnnotationKinds.All, tool) * 34.0;
        if (previous is null)
        {
            _toolChip.Visibility = Visibility.Visible;
            Motion.SlideTo(_toolChip, x, 0, MotionCurve.Instant);
            Motion.Appear(_toolChip);
        }
        else
        {
            Motion.SlideTo(_toolChip, x, 0);
        }
    }

    /// <summary>粉色实心圆钮（拷贝、开始录制，mac 28 pt Shot.accent）：32 的按钮里一个 28 的圆。</summary>
    private static Button AccentCircleButton(UIElement mark, string tooltip, string name)
    {
        var circle = new Border
        {
            Width = 28,
            Height = 28,
            CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Accent),
            Child = mark,
        };
        var button = new Button
        {
            Content = circle,
            Width = 32,
            Height = 32,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(16),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            AllowFocusOnInteraction = false,
        };
        ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties.SetName(button, name);
        return button;
    }

    /// <summary>
    /// 会话切成录屏之后（ScreenshotSession.SwitchToRecording，mac becomeRecorder）：收下打着的字、收起尺寸输入和工具，
    /// 工具栏换成录制条（选区、尺寸胶囊、比例照旧），从选区那条边长出来。
    /// </summary>
    internal void BecomeRecorder()
    {
        CommitText();
        EndSizeEditing(commit: false);
        _tool = null;
        _chipTool = null;
        _document.SelectedId = null;
        _root.Children.Remove(_toolbar);
        _toolButtons.Clear();
        _undoButton = null;
        _redoButton = null;
        _toolChip = null;
        _trayKind = null;
        _styleTray.Visibility = Visibility.Collapsed;
        _toolbar = BuildToolbar();
        _root.Children.Add(_toolbar);
        PositionToolbar();
        UpdateToolbarChrome();
        if (_toolbar.Visibility == Visibility.Visible)
        {
            Motion.Entrance(_toolbar, MotionCurve.Pop, rise: _toolbarSide == ToolbarSide.Below ? -6 : 6);
            Announce("已切到录屏，Enter 开始录制");
        }

        _canvas.Invalidate();
    }

    /// <summary>R 键 / 工具栏「录屏」：切不了时提示音 + 顶部提示 + 播报原因。</summary>
    private void SwitchToRecording()
    {
        if (_session.SwitchToRecording() is { } reason)
        {
            RefuseWipe(reason);
            Announce(reason);
        }
    }

    /// <summary>D 键：选中上次截的区域（PLAN-v9 S5）。</summary>
    private void SelectLastRegion()
    {
        switch (_session.SelectLastRegion())
        {
            case null:
                Beep();
                break;
            case false:
                RefuseWipe("有标注时不跳到别的屏");
                break;
            default:
                Announce("已选中上次的区域");
                break;
        }
    }

    /// <summary>上次区域落在这块屏：这扇遮罩拿键盘（提示、放大镜跟过来）。</summary>
    internal void TakeKeyboard()
    {
        _key = true;
        Activate();
        DispatcherQueue.TryEnqueue(() => _canvas.Focus(FocusState.Programmatic));
        _canvas.Invalidate();
    }

    /// <summary>Ctrl + 方向键把那条边往外推、Alt + 方向键往里收（Shift 10 DIP，短边不小于 8 DIP；mac ⌘ / ⌥ + 方向键）。</summary>
    private void PushEdge(Windows.System.VirtualKey key, bool outward)
    {
        if (_drag != DragKind.None || _session.SelectionScreen != _screen || !_session.HasSelection)
        {
            return;
        }

        var edge = key switch
        {
            Windows.System.VirtualKey.Left => SelectionHandle.Left,
            Windows.System.VirtualKey.Right => SelectionHandle.Right,
            Windows.System.VirtualKey.Up => SelectionHandle.Top,
            _ => SelectionHandle.Bottom,
        };
        var step = (IsDown(Windows.System.VirtualKey.Shift) ? 10 : 1) * _scale;
        _session.SetSelection(_screen, SelectionChrome.Pushed(
            _session.Selection, edge, outward ? step : -step, new RectD(0, 0, _screen.Width, _screen.Height),
            RegionMath.MinimumSide * _scale));
    }

    /// <summary>十字准线：按着 Ctrl、在拿键盘的这块屏上，待选 / 框选 / 拖边时（跟放大镜同时出现，mac updateCrosshair）。</summary>
    private bool ShowsCrosshair
        => _key && IsDown(Windows.System.VirtualKey.Control) &&
           (!_session.HasSelection || _drag is DragKind.Draw or DragKind.Resize or DragKind.Pending);

    /// <summary>横竖两条贯穿整屏的线，对齐到整 DIP：白线压在光标那一点上，旁边一条深色的（白底上也看得见）。</summary>
    private void DrawCrosshair(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, float width, float height)
    {
        var x = (float)Math.Floor(_cursor.X / _scale);
        var y = (float)Math.Floor(_cursor.Y / _scale);
        var light = Theme.Argb(217, 255, 255, 255);
        var dark = Theme.Argb(115, 0, 0, 0);
        ds.DrawLine(x + 1.5f, 0, x + 1.5f, height, dark, 1);
        ds.DrawLine(0, y + 1.5f, width, y + 1.5f, dark, 1);
        ds.DrawLine(x + 0.5f, 0, x + 0.5f, height, light, 1);
        ds.DrawLine(0, y + 0.5f, width, y + 0.5f, light, 1);
    }

    /// <summary>
    /// --ui-snapshots（第 5e 批）。step 0：清掉标注、选矩形工具（底块停在它上面）、比例锁 16:9、点开宽度输入；
    /// step 1：收起输入、切到录屏（录屏功能默认关着也切，看录制条）。只在合成的冻结帧上用。
    /// </summary>
    internal void ShowProbeChrome(int step)
    {
        if (step == 0)
        {
            CommitText();
            _document.Reset();
            SelectTool(AnnotationKind.Rectangle);
            _session.LockedRatio = 16.0 / 9;
            _session.SetSelection(
                _screen, RegionMath.ApplyingRatio(16.0 / 9, _session.Selection, new RectD(0, 0, _screen.Width, _screen.Height)));
            BeginSizeEditing(height: false);
            return;
        }

        EndSizeEditing(commit: false);
        SelectTool(null);
        _session.LockedRatio = null;
        _session.SwitchToRecording(force: true);
    }

    /// <summary>读屏播报（U10）：换工具、切到录屏、比例、尺寸。</summary>
    private void Announce(string text)
    {
        try
        {
            var peer = FrameworkElementAutomationPeer.FromElement(_root) ??
                       FrameworkElementAutomationPeer.CreatePeerForElement(_root);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.ImportantMostRecent,
                text,
                "kitty-screenshot");
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.announce-failed {ex.GetType().Name}");
        }
    }
}
