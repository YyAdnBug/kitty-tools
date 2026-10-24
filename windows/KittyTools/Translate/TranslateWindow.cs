// 翻译浮窗：语言胶囊、原文框、每个启用服务一张卡（等待 / 思考中 / 流式 / 完成 / 错误）。
// 宽 460（可拖左右边改宽并记住），高度随内容，最矮 220、最高到工作区的 85%。
// 位置：跟随鼠标（默认）或上次位置；复制即译只露出、不激活。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;
using Color = Windows.UI.Color;

namespace KittyTools;

internal sealed unsafe partial class TranslateWindow : Window
{
    private const int MinHeightDip = 220;
    private const int DefaultWidthDip = 460;

    private readonly Grid _root;
    private readonly Grid _topBar;
    private readonly Button _sourcePill;
    private readonly Button _targetPill;
    private readonly ToggleButton _pinButton;
    private readonly TextBox _source;
    private readonly Button _translateButton;
    private readonly StackPanel _cardsPanel;
    private readonly TextBlock _footer;
    private readonly ScrollViewer _scroll;
    private readonly TranslateCoordinator _coordinator = new();
    private readonly Dictionary<string, CardView> _cardViews = new();

    private HWND _hwnd;
    private HWND _previousForeground;
    private bool _visible;
    private bool _hiding;
    private bool _noActivate;
    private bool _resizing;
    private int _widthDip = DefaultWidthDip;
    private (int X, int Y)? _dragStartCursor;
    private (int X, int Y)? _dragStartWindow;

    public TranslateWindow()
    {
        Title = Paths.ProductName + " 翻译";
        _root = new Grid
        {
            RequestedTheme = Theme.ElementTheme,
            Padding = new Thickness(16, 10, 16, 10),
            RowSpacing = 8,
        };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _topBar = new Grid { ColumnSpacing = 6, Background = new SolidColorBrush(Colors.Transparent) };
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _sourcePill = Pill("自动");
        _sourcePill.Click += (_, _) => ShowLanguageMenu(_sourcePill, target: false);
        _targetPill = Pill("自动");
        _targetPill.Click += (_, _) => ShowLanguageMenu(_targetPill, target: true);
        var swap = IconButton("\uE8AB", "交换源 / 目标语言");
        swap.Click += (_, _) => SwapLanguages();
        var arrow = new FontIcon { Glyph = "\uE72A", FontSize = 11, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center };

        var languages = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        languages.Children.Add(_sourcePill);
        languages.Children.Add(arrow);
        languages.Children.Add(_targetPill);
        Grid.SetColumn(languages, 0);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _pinButton = new ToggleButton
        {
            Content = new FontIcon { Glyph = "\uE840", FontSize = 13 },
            Padding = new Thickness(6, 2, 6, 2),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(_pinButton, "固定（点别处不收起）");
        _pinButton.Click += (_, _) => UpdatePin();
        var more = IconButton("\uE712", "更多");
        var moreMenu = new MenuFlyout();
        var copyTranslate = new ToggleMenuFlyoutItem
        {
            Text = "复制即译",
            IsChecked = SettingsService.Current.CopyTranslate,
        };
        copyTranslate.Click += (_, _) =>
        {
            SettingsService.Current.CopyTranslate = copyTranslate.IsChecked;
            SettingsService.Save();
            TranslateHost.ApplyCopyTranslate();
        };
        var settings = new MenuFlyoutItem { Text = "设置…" };
        settings.Click += (_, _) => TranslateHost.OpenSettings();
        var close = new MenuFlyoutItem { Text = "关闭" };
        close.Click += (_, _) => Hide(restoreForeground: true);
        moreMenu.Items.Add(copyTranslate);
        moreMenu.Items.Add(new MenuFlyoutSeparator());
        moreMenu.Items.Add(settings);
        moreMenu.Items.Add(close);
        more.Flyout = moreMenu;
        var closeButton = IconButton("\uE711", "关闭");
        closeButton.Click += (_, _) => Hide(restoreForeground: true);
        actions.Children.Add(_pinButton);
        actions.Children.Add(more);
        actions.Children.Add(closeButton);
        Grid.SetColumn(actions, 5);

        _topBar.Children.Add(languages);
        _topBar.Children.Add(actions);
        _topBar.PointerPressed += OnTopBarPointerPressed;
        _topBar.PointerMoved += OnTopBarPointerMoved;
        _topBar.PointerReleased += OnTopBarPointerReleased;
        _topBar.PointerCaptureLost += (_, _) => EndDrag();

        _source = new TextBox
        {
            PlaceholderText = "输入要翻译的文字，Enter 翻译，Shift+Enter 换行",
            AcceptsReturn = false,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 64,
            MaxHeight = 150,
            FontSize = 15,
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        _source.TextChanged += (_, _) =>
        {
            _coordinator.SetSource(_source.Text);
            RefreshTranslateButton();
        };
        _source.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnSourceKeyDown), handledEventsToo: true);
        _source.Loaded += (_, _) =>
        {
            if (_visible && !_noActivate)
            {
                FocusSource();
            }
        };

        _translateButton = new Button
        {
            Content = "翻译 ↵",
            HorizontalAlignment = HorizontalAlignment.Right,
            Background = new SolidColorBrush(Theme.BrandPink),
            Foreground = new SolidColorBrush(Colors.White),
            Padding = new Thickness(12, 4, 12, 4),
            Visibility = Visibility.Collapsed,
        };
        _translateButton.Click += (_, _) => TranslateFromSource();

        _cardsPanel = new StackPanel { Spacing = 8 };
        _scroll = new ScrollViewer
        {
            Content = _cardsPanel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Auto,
        };
        _footer = new TextBlock
        {
            FontSize = 11,
            Opacity = 0.6,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };

        Grid.SetRow(_topBar, 0);
        Grid.SetRow(_source, 1);
        Grid.SetRow(_translateButton, 2);
        Grid.SetRow(_scroll, 3);
        Grid.SetRow(_footer, 4);
        _root.Children.Add(_topBar);
        _root.Children.Add(_source);
        _root.Children.Add(_translateButton);
        _root.Children.Add(_scroll);
        _root.Children.Add(_footer);

        Content = _root;
        SystemBackdrop = new AcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = true;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;

        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Activated += OnActivated;
        AppWindow.Changed += OnWindowChanged;
        _coordinator.Changed += OnCoordinatorChanged;
        _coordinator.Notice += message => NoticeHost.Show("翻译", message, NoticeTone.Normal);
        _widthDip = (int)Math.Round(SettingsService.Current.TranslateWindowWidth);
    }

    public bool IsVisible => _visible;

    public void ShowInput(bool missedSelection)
    {
        ShowCore(activate: true);
        _noActivate = false;
        RemoveNoActivateStyle();
        _source.PlaceholderText = missedSelection
            ? "没取到选中的文字，可以直接输入或粘贴"
            : "输入要翻译的文字，Enter 翻译，Shift+Enter 换行";
        if (missedSelection)
        {
            _source.Text = string.Empty;
        }

        PositionAtPointer(save: false);
        ActivateWindow();
        FocusSource();
        _source.SelectAll();
        UpdateHeader();
    }
    public void ShowSelection(string text)
    {
        ShowCore(activate: true);
        _noActivate = false;
        RemoveNoActivateStyle();
        _source.Text = text;
        _coordinator.Translate(text);
        PositionAtPointer(save: false);
        ActivateWindow();
        FocusSource();
    }

    public void ShowText(string text, bool fromCopy)
    {
        _noActivate = fromCopy;
        ShowCore(activate: !fromCopy);
        if (fromCopy)
        {
            ApplyNoActivateStyle();
            _source.Text = text;
            _coordinator.Translate(text, fromCopy);
            PositionAtPointer(save: false);
            PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)4); // SW_SHOWNOACTIVATE
            OutsideClickHook.Install(_hwnd, () => Hide(restoreForeground: false));
            ResizeToContent();
        }
        else
        {
            RemoveNoActivateStyle();
            _source.Text = text;
            _coordinator.Translate(text, fromCopy);
            PositionAtPointer(save: false);
            ActivateWindow();
            FocusSource();
        }
    }

    public void ToggleInput()
    {
        if (_visible && !_noActivate)
        {
            Hide(restoreForeground: true);
            return;
        }

        ShowInput(missedSelection: false);
    }

    public void Hide(bool restoreForeground)
    {
        if (!_visible)
        {
            return;
        }

        _hiding = true;
        try
        {
            _visible = false;
            OutsideClickHook.Uninstall();
            SaveGeometry();
            _coordinator.Cancel();
            AppWindow.Hide();
            Log.Info($"translate.hide restore={restoreForeground}");
            if (restoreForeground && _previousForeground != default && !_noActivate)
            {
                Foreground.Restore(_previousForeground);
            }
        }
        finally
        {
            _hiding = false;
        }
    }

    public void SaveGeometry()
    {
        var settings = SettingsService.Current;
        var changed = Math.Abs(settings.TranslateWindowWidth - _widthDip) >= 1;
        settings.TranslateWindowWidth = _widthDip;
        if (settings.TranslateWindowPosition == "last")
        {
            var position = AppWindow.Position;
            if ((int)settings.TranslateWindowX != position.X || (int)settings.TranslateWindowY != position.Y)
            {
                settings.TranslateWindowX = position.X;
                settings.TranslateWindowY = position.Y;
                changed = true;
            }
        }

        if (changed)
        {
            SettingsService.Save();
        }
    }

    private void ShowCore(bool activate)
    {
        _root.RequestedTheme = Theme.ElementTheme;

        var before = Foreground.Get();
        if (before != default && !Foreground.IsOurs(before))
        {
            _previousForeground = before;
        }

        if (!_visible)
        {
            _visible = true;
            if (activate)
            {
                AppWindow.Show();
            }
            else
            {
                ApplyNoActivateStyle();
                PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)4);
            }
        }

        _pinButton.IsChecked = SettingsService.Current.TranslatePinned;
        UpdateHeader();
        RebuildFooter();
        Log.Info($"translate.show activate={activate}");
    }

    private void ActivateWindow()
    {
        Activate();
        Foreground.Restore(_hwnd);
        DispatcherQueue.TryEnqueue(FocusSource);
    }

    private void FocusSource()
    {
        var focused = _source.Focus(FocusState.Programmatic);
        Log.Info($"translate.focus ok={focused}");
        if (!focused)
        {
            _ = FocusManager.TryFocusAsync(_source, FocusState.Programmatic);
        }
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding &&
            SettingsService.Current.TranslatePinned is false && !_noActivate)
        {
            Hide(restoreForeground: false);
            return;
        }

        if (args.WindowActivationState == WindowActivationState.CodeActivated && _visible && !_noActivate)
        {
            DispatcherQueue.TryEnqueue(FocusSource);
        }
    }

    private void OnWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidSizeChange && !_resizing && sender.Size.Width > 0)
        {
            var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
            _widthDip = (int)Math.Round(sender.Size.Width / scale);
        }
    }

    private void OnSourceKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(VirtualKey.Control);
        switch (e.Key)
        {
            case VirtualKey.Enter when !IsDown(VirtualKey.Shift):
                e.Handled = true;
                TranslateFromSource();
                break;
            case VirtualKey.Enter:
                e.Handled = true;
                InsertNewline();
                break;
            case VirtualKey.Escape:
                e.Handled = true;
                Hide(restoreForeground: true);
                break;
            case VirtualKey.W when control:
                e.Handled = true;
                Hide(restoreForeground: true);
                break;
            case VirtualKey.P when control:
                e.Handled = true;
                _pinButton.IsChecked = !(_pinButton.IsChecked == true);
                UpdatePin();
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number9 when control:
                e.Handled = true;
                CopyCard((int)e.Key - (int)VirtualKey.Number1);
                break;
        }
    }

    private void TranslateFromSource()
    {
        var text = _source.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        _coordinator.Translate(text);
    }

    private void InsertNewline()
    {
        var caret = _source.SelectionStart;
        var length = _source.SelectionLength;
        var text = _source.Text;
        _source.Text = text.Remove(caret, length).Insert(caret, "\n");
        _source.SelectionStart = caret + 1;
    }

    private void UpdatePin()
    {
        SettingsService.Current.TranslatePinned = _pinButton.IsChecked == true;
        SettingsService.Save();
        ToolTipService.SetToolTip(_pinButton, SettingsService.Current.TranslatePinned ? "已固定（Esc 仍可关闭）" : "固定（点别处不收起）");
    }

    private void UpdateHeader()
    {
        var settings = SettingsService.Current;
        _sourcePill.Content = Langs.FromCode(settings.TranslateSource) is { } source ? source.Title() : "自动";
        _targetPill.Content = Langs.FromCode(settings.TranslateTarget) is { } target ? target.Title() : "自动";
        RefreshTranslateButton();
    }

    private void RefreshTranslateButton()
        => _translateButton.Visibility = _coordinator.NeedsTranslate ? Visibility.Visible : Visibility.Collapsed;

    private void RebuildFooter()
    {
        var target = _coordinator.Target.Title();
        var detected = _coordinator.Detected is { } lang ? "检测：" + lang.Title() + " · " : string.Empty;
        var abandoned = _coordinator.AbandonedTarget is { } old
            ? $"（原文已是{old.Title()}，改按自动）"
            : string.Empty;
        _footer.Text = detected + "目标：" + target + abandoned + " · Enter 翻译 · Esc 关闭 · Ctrl+P 固定";
    }

    private void OnCoordinatorChanged()
    {
        var ids = _coordinator.Cards.Select(card => card.Service.Id).ToList();
        if (ids.Count != _cardViews.Count || ids.Any(id => !_cardViews.ContainsKey(id)))
        {
            _cardsPanel.Children.Clear();
            _cardViews.Clear();
            foreach (var card in _coordinator.Cards)
            {
                var view = new CardView(card.Service, this);
                _cardViews[card.Service.Id] = view;
                _cardsPanel.Children.Add(view.Root);
            }
        }

        foreach (var card in _coordinator.Cards)
        {
            if (_cardViews.TryGetValue(card.Service.Id, out var view))
            {
                view.Update(card);
            }
        }

        RebuildFooter();
        RefreshTranslateButton();
        ResizeToContent();
        DispatcherQueue.TryEnqueue(ResizeToContent);
    }

    private double NeededHeightDip()
    {
        var needed = _topBar.ActualHeight + _source.ActualHeight + _translateButton.ActualHeight +
                     _cardsPanel.ActualHeight + _footer.ActualHeight + 20 + 32;
        return needed > 0 && !double.IsNaN(needed) ? needed : MinHeightDip;
    }

    private void ResizeToContent()
    {
        if (!_visible)
        {
            return;
        }

        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        var work = WorkArea();
        var workHeightDip = work.bottom - work.top;
        var heightDip = Math.Clamp(NeededHeightDip(), MinHeightDip, workHeightDip * 0.85);
        var widthPx = (int)Math.Round(_widthDip * scale);
        var heightPx = (int)Math.Round(heightDip * scale);
        if (Math.Abs(AppWindow.Size.Height - heightPx) < 2 && Math.Abs(AppWindow.Size.Width - widthPx) < 2)
        {
            return;
        }

        _resizing = true;
        try
        {
            var position = AppWindow.Position;
            AppWindow.MoveAndResize(new RectInt32(position.X, position.Y, widthPx, heightPx));
        }
        finally
        {
            _resizing = false;
        }
    }

    private void PositionAtPointer(bool save)
    {
        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        var work = WorkArea();
        var widthPx = (int)Math.Round(_widthDip * scale);
        var heightDip = Math.Clamp(NeededHeightDip(), MinHeightDip, (work.bottom - work.top) * 0.85);
        var heightPx = (int)Math.Round(heightDip * scale);

        int x;
        int y;
        if (SettingsService.Current.TranslateWindowPosition == "last" && save is false &&
            SettingsService.Current.TranslateWindowX != 0)
        {
            x = (int)SettingsService.Current.TranslateWindowX;
            y = (int)SettingsService.Current.TranslateWindowY;
        }
        else
        {
            PInvoke.GetCursorPos(out var cursor);
            x = cursor.X + (int)Math.Round(12 * scale);
            y = cursor.Y + (int)Math.Round(12 * scale);
            if (x + widthPx > work.right)
            {
                x = cursor.X - widthPx - (int)Math.Round(12 * scale);
            }

            if (y + heightPx > work.bottom)
            {
                y = cursor.Y - heightPx - (int)Math.Round(12 * scale);
            }
        }

        x = Math.Clamp(x, work.left, Math.Max(work.left, work.right - widthPx));
        y = Math.Clamp(y, work.top, Math.Max(work.top, work.bottom - heightPx));
        AppWindow.MoveAndResize(new RectInt32(x, y, widthPx, heightPx));
    }

    private static (int left, int top, int right, int bottom) WorkArea()
    {
        PInvoke.GetCursorPos(out var cursor);
        var monitor = PInvoke.MonitorFromPoint(cursor, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        PInvoke.GetMonitorInfo(monitor, ref info);
        return (info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom);
    }

    private void ShowLanguageMenu(Button anchor, bool target)
    {
        var menu = new MenuFlyout();
        var auto = new MenuFlyoutItem { Text = "自动" };
        auto.Click += (_, _) =>
        {
            if (target)
            {
                SettingsService.Current.TranslateTarget = null;
            }
            else
            {
                SettingsService.Current.TranslateSource = null;
            }

            SettingsService.Save();
            UpdateHeader();
            if (!string.IsNullOrWhiteSpace(_source.Text))
            {
                _coordinator.Translate(_source.Text);
            }
        };
        menu.Items.Add(auto);
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var lang in Enum.GetValues<Lang>())
        {
            var item = new MenuFlyoutItem { Text = lang.Title() };
            item.Click += (_, _) =>
            {
                if (target)
                {
                    SettingsService.Current.TranslateTarget = lang.Code();
                }
                else
                {
                    SettingsService.Current.TranslateSource = lang.Code();
                }

                SettingsService.Save();
                UpdateHeader();
                if (!string.IsNullOrWhiteSpace(_source.Text))
                {
                    _coordinator.Translate(_source.Text);
                }
            };
            menu.Items.Add(item);
        }

        menu.ShowAt(anchor);
    }

    private void SwapLanguages()
    {
        var source = Langs.FromCode(SettingsService.Current.TranslateSource);
        var target = Langs.FromCode(SettingsService.Current.TranslateTarget);
        SettingsService.Current.TranslateSource = target?.Code() ?? Lang.En.Code();
        SettingsService.Current.TranslateTarget = source?.Code() ?? Lang.ZhHans.Code();
        SettingsService.Save();
        UpdateHeader();
        if (!string.IsNullOrWhiteSpace(_source.Text))
        {
            _coordinator.Translate(_source.Text);
        }
    }

    private void CopyCard(int index)
    {
        if (index < 0 || index >= _coordinator.Cards.Count)
        {
            return;
        }

        CopyText(_coordinator.Cards[index].Text);
    }

    public void CopyText(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        if (!ClipboardWriter.WriteText(text))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
            return;
        }

        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(text);
        NoticeHost.Show("已复制译文", string.Empty, NoticeTone.Normal);
    }

    private void OnTopBarPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (InsideButton(e.OriginalSource as DependencyObject))
        {
            return;
        }

        _topBar.CapturePointer(e.Pointer);
        PInvoke.GetCursorPos(out var cursor);
        _dragStartCursor = (cursor.X, cursor.Y);
        var position = AppWindow.Position;
        _dragStartWindow = (position.X, position.Y);
    }

    private static bool InsideButton(DependencyObject? element)
    {
        while (element is not null)
        {
            if (element is ButtonBase)
            {
                return true;
            }

            element = VisualTreeHelper.GetParent(element);
        }

        return false;
    }

    private void OnTopBarPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragStartCursor is not { } start || _dragStartWindow is not { } origin)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        AppWindow.Move(new PointInt32(
            origin.X + cursor.X - start.X,
            origin.Y + cursor.Y - start.Y));
    }

    private void OnTopBarPointerReleased(object sender, PointerRoutedEventArgs e) => EndDrag();

    private void EndDrag()
    {
        if (_dragStartCursor is null)
        {
            return;
        }

        _dragStartCursor = null;
        _dragStartWindow = null;
        _topBar.ReleasePointerCaptures();
        if (SettingsService.Current.TranslateWindowPosition == "last")
        {
            var position = AppWindow.Position;
            SettingsService.Current.TranslateWindowX = position.X;
            SettingsService.Current.TranslateWindowY = position.Y;
            SettingsService.Save();
        }
    }

    private void ApplyNoActivateStyle()
    {
        var style = GetWindowLong((IntPtr)_hwnd.Value, -20);
        SetWindowLong((IntPtr)_hwnd.Value, -20, style | 0x08000000); // WS_EX_NOACTIVATE
    }

    private void RemoveNoActivateStyle()
    {
        var style = GetWindowLong((IntPtr)_hwnd.Value, -20);
        SetWindowLong((IntPtr)_hwnd.Value, -20, style & ~0x08000000);
    }

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private static Button Pill(string text) => new()
    {
        Content = text,
        Padding = new Thickness(10, 3, 10, 3),
        CornerRadius = new CornerRadius(14),
        Background = new SolidColorBrush(Color.FromArgb(26, 128, 128, 128)),
        BorderThickness = new Thickness(0),
        FontSize = 12,
    };

    private static Button IconButton(string glyph, string tooltip)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 13 },
            Padding = new Thickness(6, 2, 6, 2),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);

    private sealed class CardView
    {
        private readonly TextBlock _name;
        private readonly TextBlock _status;
        private readonly TextBlock _body;
        private readonly TextBlock _error;
        private readonly ProgressRing _spinner;
        private readonly Button _copy;
        private readonly Button _retry;
        private readonly Button _settings;
        private readonly StackPanel _actions;
        private readonly TranslateWindow _owner;

        public CardView(TranslateServiceConfig service, TranslateWindow owner)
        {
            _owner = owner;
            _name = new TextBlock
            {
                Text = service.Name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _status = new TextBlock
            {
                Text = "等待中…",
                FontSize = 11,
                Opacity = 0.65,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _spinner = new ProgressRing { IsActive = true, Width = 14, Height = 14 };
            _body = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                FontSize = 14,
                LineHeight = 21,
                MaxLines = 8,
                TextTrimming = TextTrimming.WordEllipsis,
            };
            _error = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(255, 200, 60, 60)) };
            _copy = SmallButton("复制");
            _copy.Click += (_, _) => _owner.CopyText(_body.Text);
            _retry = SmallButton("重试");
            _retry.Click += (_, _) => _owner._coordinator.Retry(service.Id);
            _settings = SmallButton("打开设置");
            _settings.Click += (_, _) => TranslateHost.OpenSettings();
            _actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };

            var header = new Grid { ColumnSpacing = 6 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            title.Children.Add(new FontIcon
            {
                Glyph = "\uE8C8",
                FontSize = 13,
                Foreground = new SolidColorBrush(Color.FromArgb(255, 76, 175, 120)),
                VerticalAlignment = VerticalAlignment.Center,
            });
            title.Children.Add(_name);
            title.Children.Add(_spinner);
            title.Children.Add(_status);
            Grid.SetColumn(title, 0);
            Grid.SetColumn(_actions, 1);
            header.Children.Add(title);
            header.Children.Add(_actions);

            var panel = new StackPanel { Spacing = 6 };
            panel.Children.Add(header);
            panel.Children.Add(_body);
            panel.Children.Add(_error);
            Root = new Border
            {
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 8, 10, 8),
                Background = new SolidColorBrush(Theme.ElementTheme == ElementTheme.Dark
                    ? Color.FromArgb(26, 255, 255, 255)
                    : Color.FromArgb(14, 0, 0, 0)),
                Child = panel,
            };
            Update(new TranslateCard { Service = service });
        }

        public Border Root { get; }

        public void Update(TranslateCard card)
        {
            var hasText = card.Text.Length > 0;
            _body.Text = card.Text;
            _body.Visibility = hasText ? Visibility.Visible : Visibility.Collapsed;
            _error.Visibility = Visibility.Collapsed;
            _spinner.IsActive = card.State is CardState.Waiting or CardState.Running;
            _spinner.Visibility = _spinner.IsActive ? Visibility.Visible : Visibility.Collapsed;
            _actions.Children.Clear();

            switch (card.State)
            {
                case CardState.Waiting:
                    _status.Text = "等待中…";
                    break;
                case CardState.Running when card.Thinking || !hasText:
                    _status.Text = "思考中…";
                    break;
                case CardState.Running:
                    _status.Text = "翻译中…";
                    break;
                case CardState.Done:
                    _status.Text = "完成";
                    break;
                case CardState.Truncated:
                    _status.Text = "只翻了前一部分";
                    _error.Text = card.Error?.Message ?? "超出单次输出上限";
                    _error.Visibility = Visibility.Visible;
                    _actions.Children.Add(_retry);
                    break;
                case CardState.Failed:
                    _status.Text = "失败";
                    _error.Text = card.Error?.Message ?? "翻译失败";
                    _error.Visibility = Visibility.Visible;
                    if (card.Error?.Kind == TranslateErrorKind.Config)
                    {
                        _actions.Children.Add(_settings);
                    }

                    _actions.Children.Add(_retry);
                    break;
            }

            if (hasText)
            {
                _actions.Children.Add(_copy);
            }
        }

        private static Button SmallButton(string text) => new()
        {
            Content = text,
            Padding = new Thickness(8, 2, 8, 2),
            FontSize = 11,
        };
    }
}
