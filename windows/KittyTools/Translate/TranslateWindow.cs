// 翻译浮窗：语言胶囊、原文框、每个启用服务一张卡（等待 / 思考中 / 流式 / 完成 / 错误）。
// 宽 460（可拖左右边改宽并记住），高度随内容，最矮 220、最高到工作区的 85%。
// 位置：跟随鼠标（默认）或上次位置；复制即译只露出、不激活。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;
using Windows.System;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;
using Color = Windows.UI.Color;

namespace KittyTools;

internal sealed unsafe partial class TranslateWindow : Window
{
    private const int MinHeightDip = 220;
    private const int DefaultWidthDip = 420;

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
    private readonly Grid _historyHost;
    private readonly TextBox _historySearch;
    private readonly ScrollViewer _historyList;
    private readonly StackPanel _historyRows;
    private readonly TextBlock _historyHint;
    private readonly List<TranslationEntry> _historyEntries = new();
    private TranslationEntry? _historySelected;
    private bool _historyVisible;
    private bool _historyFavoritesOnly;
    private IntPtr _replaceTarget;
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
            Padding = new Thickness(12),
            RowSpacing = 10,
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
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_pinButton, "固定翻译窗口");
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
        // 朗读原文（第三版 §3.3）。
        var speak = IconButton("\uE767", "朗读原文");
        speak.Click += (_, _) => SpeakSource();
        actions.Children.Add(speak);
        var history = IconButton("\uE81C", "历史（Ctrl+H）");
        history.Click += (_, _) => ToggleHistory();
        actions.Children.Add(history);
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
            // 多行模式才会换行：单行 TextBox 会把长原文横向截掉（Enter 由 OnSourceKeyDown 接管）。
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 64,
            MaxHeight = 150,
            Style = Theme.Style("Kitty.InputStyle"),
            Background = Theme.Brush("Kitty.Input", Theme.Argb(11, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            FontSize = Theme.FontSize("Kitty.FontSize.Reading"),
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
            Background = new SolidColorBrush(Theme.AccentColor),
            Foreground = new SolidColorBrush(Theme.OnAccentColor),
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
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };

        // 历史（Ctrl+H，第三版 §3.1）：原文区不动，结果区换成历史列表。
        _historySearch = new TextBox
        {
            PlaceholderText = "搜索原文或译文…",
            FontSize = 13,
            Height = 32,
            Margin = new Thickness(0, 0, 0, 6),
        };
        _historySearch.TextChanged += (_, _) => RefreshHistory();
        _historySearch.KeyDown += OnHistoryKeyDown;
        _historyRows = new StackPanel { Spacing = 2 };
        _historyList = new ScrollViewer
        {
            Content = _historyRows,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        _historyHint = new TextBlock
        {
            FontSize = 11,
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var historyGrid = new Grid();
        historyGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        historyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        historyGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_historySearch, 0);
        Grid.SetRow(_historyList, 1);
        Grid.SetRow(_historyHint, 2);
        historyGrid.Children.Add(_historySearch);
        historyGrid.Children.Add(_historyList);
        historyGrid.Children.Add(_historyHint);
        _historyHost = historyGrid;
        _historyHost.Visibility = Visibility.Collapsed;

        Grid.SetRow(_topBar, 0);
        Grid.SetRow(_source, 1);
        Grid.SetRow(_translateButton, 2);
        Grid.SetRow(_scroll, 3);
        Grid.SetRow(_historyHost, 3);
        _root.Children.Add(_topBar);
        _root.Children.Add(_source);
        _root.Children.Add(_translateButton);
        _root.Children.Add(_scroll);
        _root.Children.Add(_historyHost);

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

    /// <summary>
    /// 剪贴板里的「翻译」（Ctrl+T）：浮窗只露出、不抢焦点，剪贴板面板留着（PLAN §7.4）。
    /// 面板还在前台，所以这里不能激活；点浮窗外面（包括点回面板）自己收起。
    /// </summary>
    public void ShowTextPassive(string text)
    {
        _noActivate = true;
        ShowCore(activate: false);
        ApplyNoActivateStyle();
        _source.Text = text;
        _coordinator.Translate(text);
        PositionAtPointer(save: false);
        PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)4); // SW_SHOWNOACTIVATE
        OutsideClickHook.Install(_hwnd, () => Hide(restoreForeground: false));
        ResizeToContent();
    }

    /// <summary>
    /// 截图翻译：浮窗贴着选区出现（PLAN-v2 §3.8）。其它行为和输入翻译一样（要拿焦点才能选中原文）。
    /// </summary>
    public void ShowTextNear(string text, PixelRect anchor)
    {
        _noActivate = false;
        ShowCore(activate: true);
        RemoveNoActivateStyle();
        _source.Text = text;
        _coordinator.Translate(text);
        var display = Displays.AtPoint(anchor.X, anchor.Y);
        var rect = MonitorLayout.NearRect(anchor, display.Work, display.Scale, _widthDip, NeededHeightDip());
        AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
        ActivateWindow();
        FocusSource();
        DispatcherQueue.TryEnqueue(ResizeToContent);
    }

    public void ToggleInput()
    {        if (_visible && !_noActivate)
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
            Speech.Stop();
            if (_historyVisible)
            {
                _historyVisible = false;
                _historyHost.Visibility = Visibility.Collapsed;
                _scroll.Visibility = Visibility.Visible;
            }

            SaveGeometry();
            _coordinator.Cancel();
            AppWindow.Hide();
            IdleReclaimer.Schedule();
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
        IdleReclaimer.Cancel();
        _root.RequestedTheme = Theme.ElementTheme;

        var before = Foreground.Get();
        if (before != default && !Foreground.IsOurs(before))
        {
            _previousForeground = before;
        }

        _replaceTarget = (IntPtr)_previousForeground.Value;
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
        // 入场：透明度 0→1 + 下落 6 px（减弱动画时只淡入）。
        Motion.Entrance(_root);
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
            var scale = Displays.AtWindow(_hwnd).Scale;
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
                if (_historyVisible)
                {
                    ToggleHistory();
                }
                else
                {
                    Hide(restoreForeground: true);
                }

                break;
            case VirtualKey.H when control:
                e.Handled = true;
                ToggleHistory();
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

    // ---- 历史（第三版 §3.1）----

    public bool HistoryVisible => _historyVisible;

    /// <summary>Ctrl+H：结果区换成历史列表；再按一次回来。</summary>
    public void AuditAccessibility() => AccessibilityAudit.Run(_root, "translate");

    public void ToggleHistory()
    {
        _historyVisible = !_historyVisible;
        _historyHost.Visibility = _historyVisible ? Visibility.Visible : Visibility.Collapsed;
        _scroll.Visibility = _historyVisible ? Visibility.Collapsed : Visibility.Visible;
        _translateButton.Visibility = Visibility.Collapsed;
        if (_historyVisible)
        {
            RefreshHistory();
            _historySearch.Focus(FocusState.Programmatic);
        }
        else
        {
            _footer.Text = FooterText();
            FocusSource();
        }

        ResizeToContent();
    }

    private string FooterText()
    {
        var detected = _coordinator.Detected is { } lang ? "检测：" + lang.Title() + " · " : string.Empty;
        return detected + "目标：" + _coordinator.Target.Title() + " · Enter 翻译 · Ctrl+H 历史 · Esc 关闭 · Ctrl+P 固定";
    }

    /// <summary>按搜索框重排历史列表（原文 / 译文都搜，新→旧）。</summary>
    private void RefreshHistory()
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return;
        }

        var favorites = IsDown(VirtualKey.Shift) && IsDown(VirtualKey.Tab);
        _historyEntries.Clear();
        _historyEntries.AddRange(history.Search(_historySearch.Text, favorites, limit: 200));
        _historyRows.Children.Clear();
        _historySelected = _historyEntries.FirstOrDefault();
        foreach (var entry in _historyEntries)
        {
            _historyRows.Children.Add(HistoryRow(entry));
        }

        var (total, favoritesCount) = history.Counts();
        _historyHint.Text = _historyEntries.Count == 0
            ? "还没有历史（翻译一段就会记下来）"
            : $"{_historyEntries.Count} 条 · 共 {total} 条、收藏 {favoritesCount} 条 · " +
              "Enter 重新翻译 · Ctrl+D 收藏 · Delete 删除 · Ctrl+Z 撤销 · Esc 回到浮窗";
        UpdateHistorySelection();
    }

    private FrameworkElement HistoryRow(TranslationEntry entry)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock
        {
            Text = OneLine(entry.Source),
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        panel.Children.Add(new TextBlock
        {
            Text = OneLine(entry.Result),
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        meta.Children.Add(new TextBlock
        {
            Text = entry.Favorite ? "★ " + entry.TargetLang : entry.TargetLang,
            FontSize = 10,
            Foreground = Theme.SecondaryText(),
        });
        meta.Children.Add(new TextBlock
        {
            Text = DateTimeOffset.FromUnixTimeMilliseconds(entry.CreatedAt).ToLocalTime()
                .ToString("MM-dd HH:mm"),
            FontSize = 10,
            Foreground = Theme.SecondaryText(),
        });
        panel.Children.Add(meta);

        var border = new Border
        {
            Padding = new Thickness(8, 5, 8, 5),
            CornerRadius = new CornerRadius(6),
            Child = panel,
        };
        border.Tapped += (_, _) =>
        {
            _historySelected = entry;
            UpdateHistorySelection();
        };
        border.DoubleTapped += (_, _) =>
        {
            _historySelected = entry;
            RetranslateSelected();
        };
        border.ContextFlyout = HistoryMenu(entry);
        border.Tag = entry;
        return border;
    }

    private MenuFlyout HistoryMenu(TranslationEntry entry)
    {
        var menu = new MenuFlyout();
        void Add(string text, Action action)
        {
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) =>
            {
                _historySelected = entry;
                action();
            };
            menu.Items.Add(item);
        }

        Add("重新翻译", RetranslateSelected);
        Add("复制译文", CopySelectedResult);
        Add("复制原文", CopySelectedSource);
        Add(entry.Favorite ? "取消收藏" : "收藏", ToggleSelectedFavorite);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("删除", DeleteSelected);
        return menu;
    }

    private void UpdateHistorySelection()
    {
        foreach (var child in _historyRows.Children.OfType<Border>())
        {
            var selected = ReferenceEquals(child.Tag, _historySelected);
            child.Background = selected
                ? Theme.Brush("SubtleFillColorSecondaryBrush", Theme.Argb(30, 128, 128, 128))
                : new SolidColorBrush(Colors.Transparent);
        }
    }

    private void OnHistoryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_historyVisible)
        {
            return;
        }

        var control = IsDown(VirtualKey.Control);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                ToggleHistory();
                break;
            case VirtualKey.Down:
                e.Handled = true;
                MoveHistory(1);
                break;
            case VirtualKey.Up:
                e.Handled = true;
                MoveHistory(-1);
                break;
            case VirtualKey.Enter:
                e.Handled = true;
                RetranslateSelected();
                break;
            case VirtualKey.Delete when _historySearch.SelectionLength == 0 &&
                _historySearch.SelectionStart == _historySearch.Text.Length:
                e.Handled = true;
                DeleteSelected();
                break;
            case VirtualKey.C when control && !IsDown(VirtualKey.Shift):
                e.Handled = true;
                CopySelectedResult();
                break;
            case VirtualKey.C when control && IsDown(VirtualKey.Shift):
                e.Handled = true;
                CopySelectedSource();
                break;
            case VirtualKey.D when control:
                e.Handled = true;
                ToggleSelectedFavorite();
                break;
            case VirtualKey.Z when control:
                e.Handled = true;
                if (TranslationHistory.Instance?.Undo() is not null)
                {
                    RefreshHistory();
                }

                break;
            case VirtualKey.H when control:
                e.Handled = true;
                ToggleHistory();
                break;
            case VirtualKey.W when control:
                e.Handled = true;
                Hide(restoreForeground: true);
                break;
            case VirtualKey.Tab when IsDown(VirtualKey.Shift):
                e.Handled = true;
                _historyFavoritesOnly = !_historyFavoritesOnly;
                RefreshHistory();
                break;
        }
    }

    private void MoveHistory(int delta)
    {
        if (_historyEntries.Count == 0)
        {
            return;
        }

        var index = _historySelected is null ? 0 : _historyEntries.IndexOf(_historySelected);
        index = Math.Clamp(index + delta, 0, _historyEntries.Count - 1);
        _historySelected = _historyEntries[index];
        UpdateHistorySelection();
        if (_historyRows.Children.OfType<Border>().FirstOrDefault(
                border => ReferenceEquals(border.Tag, _historySelected)) is { } row)
        {
            row.StartBringIntoView();
        }
    }

    private void RetranslateSelected()
    {
        if (_historySelected is not { } entry)
        {
            return;
        }

        _source.Text = entry.Source;
        ToggleHistory();
        _coordinator.Translate(entry.Source);
    }

    private void CopySelectedResult()
    {
        if (_historySelected is { } entry)
        {
            CopyText(entry.Result);
        }
    }

    private void CopySelectedSource()
    {
        if (_historySelected is { } entry)
        {
            CopyText(entry.Source);
        }
    }

    private void ToggleSelectedFavorite()
    {
        if (_historySelected is not { } entry || TranslationHistory.Instance is not { } history)
        {
            return;
        }

        history.SetFavorite(entry.Id, !entry.Favorite);
        RefreshHistory();
    }

    private void DeleteSelected()
    {
        if (_historySelected is not { } entry || TranslationHistory.Instance is not { } history)
        {
            return;
        }

        history.Delete(entry.Id);
        RefreshHistory();
        NoticeHost.Show("已删除", "Ctrl+Z 可以撤销", NoticeTone.Normal);
    }

    // ---- 替换原文、朗读（第三版 §3.2 / §3.3）----

    /// <summary>替换原文：先收起浮窗，再写入译文并粘回原窗口；切不回去就只复制。</summary>
    public void ReplaceWith(string text)
    {
        var target = new Windows.Win32.Foundation.HWND(_replaceTarget);
        Hide(restoreForeground: false);
        if (target == default)
        {
            if (ClipboardWriter.WriteText(text))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(text);
            }

            NoticeHost.Show("已复制译文", "没能切回原窗口", NoticeTone.Warning);
            return;
        }

        var ok = Paster.Paste(target, () => ClipboardWriter.WriteText(text), ClipboardService.Instance);
        NoticeHost.Show(
            ok ? "已替换原文" : "已复制译文",
            ok ? string.Empty : "没能切回原窗口",
            ok ? NoticeTone.Normal : NoticeTone.Warning);
    }

    public void SpeakSource()
        => Speech.Speak(_source.Text, _coordinator.Detected?.Code() ?? SettingsService.Current.TranslateSource);

    private static string OneLine(string text)
    {
        var line = text.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return line.Length <= 120 ? line : line[..120] + "…";
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
        var abandoned = _coordinator.AbandonedTarget is { } old
            ? $"（原文已是{old.Title()}，改按自动）"
            : string.Empty;
        _footer.Text = FooterText() + abandoned;
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
        // 按内容重新量一遍（REVIEW R8）：以前拿 ActualHeight，卡片被窗口高度裁住时会越量越小，
        // 最后一张卡被底栏盖住。Measure 用无限高度，拿到的是内容真正想要的高度。
        try
        {
            _root.Measure(new Windows.Foundation.Size(_widthDip, double.PositiveInfinity));
            var measured = _root.DesiredSize.Height;
            if (measured > 0 && !double.IsNaN(measured) && !double.IsInfinity(measured))
            {
                return measured + 8;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"translate.measure-failed {ex.GetType().Name}");
        }

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

        // 窗口已经在这块屏上了：按它所在显示器的缩放比例换算。
        var display = Displays.AtWindow(_hwnd);
        var maxHeightDip = display.Work.Height / display.Scale * 0.85;
        var heightDip = Math.Clamp(NeededHeightDip(), MinHeightDip, maxHeightDip);
        var widthPx = MonitorLayout.Pixels(_widthDip, display.Scale);
        var heightPx = MonitorLayout.Pixels(heightDip, display.Scale);
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
        var settings = SettingsService.Current;
        var useSaved = settings.TranslateWindowPosition == "last" && !save && settings.TranslateWindowX != 0;
        if (useSaved)
        {
            // 上次的位置：按那块屏（存的是像素坐标）的缩放比例换算尺寸。
            var savedX = (int)settings.TranslateWindowX;
            var savedY = (int)settings.TranslateWindowY;
            var display = Displays.AtPoint(savedX, savedY);
            var maxHeightDip = display.Work.Height / display.Scale * 0.85;
            var heightDip = Math.Clamp(NeededHeightDip(), MinHeightDip, maxHeightDip);
            var rect = MonitorLayout.Clamp(
                new PixelRect(
                    savedX, savedY,
                    MonitorLayout.Pixels(_widthDip, display.Scale),
                    MonitorLayout.Pixels(heightDip, display.Scale)),
                display.Work);
            AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
            return;
        }

        // 跟随鼠标：按鼠标所在显示器自己的缩放比例算，放不下就翻到左边 / 上边。
        var pointerDisplay = Displays.AtCursor();
        var height = NeededHeightDip();
        var maxHeight = pointerDisplay.Work.Height / pointerDisplay.Scale * 0.85;
        height = Math.Clamp(height, MinHeightDip, maxHeight);
        PInvoke.GetCursorPos(out var cursor);
        var placed = MonitorLayout.NearPointer(
            cursor.X, cursor.Y, pointerDisplay.Work, pointerDisplay.Scale, _widthDip, height);
        AppWindow.MoveAndResize(new RectInt32(placed.X, placed.Y, placed.Width, placed.Height));
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
        Background = Theme.Brush("SubtleFillColorSecondaryBrush", Theme.Argb(26, 128, 128, 128)),
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
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        return button;
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);

    private sealed class CardView
    {
        /// <summary>正文最多 8 行，超出的在卡片里滚动（PLAN §3.7 / PLAN-v2 §6 第 1 批）。</summary>
        private const int MaxBodyLines = 8;

        private const double BodyLineHeight = 22;

        private readonly TextBlock _name;
        private readonly TextBlock _status;
        private readonly FrameworkElement _badge;
        private readonly TextBlock _body;
        private readonly ScrollViewer _bodyScroll;
        private readonly Border _fade;
        private readonly Border _cursor;
        private readonly StackPanel _skeleton;
        private readonly TextBlock _error;
        private readonly Border _errorCard;
        private readonly Border _glow;
        private readonly Storyboard _glowStoryboard;
        private bool _glowActive;
        private readonly Button _copy;
        private readonly Button _retry;
        private readonly Button _settings;
        private readonly StackPanel _actions;
        private readonly TranslateWindow _owner;
        private bool _blinking;
        private bool _shimmering;

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
                Foreground = Theme.SecondaryText(),
                VerticalAlignment = VerticalAlignment.Center,
            };

            // 服务标识：有官方 logo 用 logo，没有用品牌色首字母（PLAN-v7 §2.1）。
            _badge = ServiceTile.Create(
                ServiceBadge.Vendor(service.Kind, service.Protocol), service.Name, 18);

            _body = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                FontSize = Theme.FontSize("Kitty.FontSize.Reading"),
                LineHeight = 22,
            };
            // 正文不截断、改成卡片里滚动：下面还有内容时能看到自己的滚动条。
            // 光标和正文放在同一层，坐标才对得上（不再单独占正文下面一行）。
            var bodyLayer = new Grid();
            bodyLayer.Children.Add(_body);
            _bodyScroll = new ScrollViewer
            {
                Content = bodyLayer,
                MaxHeight = MaxBodyLines * BodyLineHeight,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollMode = ScrollMode.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalScrollMode = ScrollMode.Disabled,
            };

            // 下面还有内容时底部渐隐（PLAN-v2 §3.7）。
            var cardColor = Theme.CardColor();
            _fade = new Border
            {
                Height = 26,
                VerticalAlignment = VerticalAlignment.Bottom,
                IsHitTestVisible = false,
                Visibility = Visibility.Collapsed,
                Background = new LinearGradientBrush
                {
                    StartPoint = new Windows.Foundation.Point(0, 0),
                    EndPoint = new Windows.Foundation.Point(0, 1),
                    GradientStops =
                    {
                        new GradientStop
                        {
                            Color = Theme.Argb(0, cardColor.R, cardColor.G, cardColor.B),
                            Offset = 0,
                        },
                        new GradientStop { Color = cardColor, Offset = 1 },
                    },
                },
            };
            var bodyHost = new Grid { MaxHeight = MaxBodyLines * BodyLineHeight };
            bodyHost.Children.Add(_bodyScroll);
            bodyHost.Children.Add(_fade);

            // 生成中末尾一根强调色闪烁光标（PLAN-v2 §3.7）。
            _cursor = new Border
            {
                Width = 2,
                Height = 14,
                CornerRadius = new CornerRadius(1),
                Background = new SolidColorBrush(Theme.AccentColor),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0),
                IsHitTestVisible = false,
                Visibility = Visibility.Collapsed,
                Opacity = 0,
            };
            bodyLayer.Children.Add(_cursor);

            // 等待 / 思考中的骨架条（只动透明度，交给合成器，进程 CPU 接近 0）。
            _skeleton = new StackPanel { Spacing = 8, Margin = new Thickness(0, 2, 0, 2) };
            foreach (var width in new[] { 1.0, 0.82, 0.55 })
            {
                _skeleton.Children.Add(new Border
                {
                    Height = 8,
                    CornerRadius = new CornerRadius(4),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Width = 340 * width,
                    Background = Theme.Brush(
                        "ControlFillColorSecondaryBrush", Theme.Argb(40, 128, 128, 128)),
                });
            }

            _error = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Theme.Critical() };
            _errorCard = new Border
            {
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 7, 10, 7),
                BorderThickness = new Thickness(1),
                Visibility = Visibility.Collapsed,
                Child = _error,
            };
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
            title.Children.Add(_badge);
            title.Children.Add(_name);
            title.Children.Add(_status);
            Grid.SetColumn(title, 0);
            Grid.SetColumn(_actions, 1);
            header.Children.Add(title);
            header.Children.Add(_actions);

            var panel = new StackPanel { Spacing = 6 };
            panel.Children.Add(header);
            panel.Children.Add(_skeleton);
            panel.Children.Add(bodyHost);
            panel.Children.Add(_errorCard);
            var card = new Border
            {
                Style = Theme.Style("Kitty.CardStyle"),
                Padding = new Thickness(10, 8, 10, 8),
                Child = panel,
            };
            // 彗星边：三段渐变（透明 → 强调色 → 透明）沿对角线跑；不做几何路径，先保证观感。
            var glowBrush = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0),
                EndPoint = new Windows.Foundation.Point(1, 1),
            };
            var stops = new[]
            {
                new GradientStop { Color = Theme.Argb(0, 255, 77, 126), Offset = 0 },
                new GradientStop { Color = Theme.AccentColor, Offset = 0.5 },
                new GradientStop { Color = Theme.Argb(0, 255, 77, 126), Offset = 1 },
            };
            foreach (var stop in stops)
            {
                glowBrush.GradientStops.Add(stop);
            }

            _glow = new Border
            {
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(1.5),
                BorderBrush = glowBrush,
                Opacity = 0,
                IsHitTestVisible = false,
            };
            _glowStoryboard = new Storyboard { RepeatBehavior = RepeatBehavior.Forever };
            for (var index = 0; index < stops.Length; index++)
            {
                var slide = new DoubleAnimation
                {
                    From = -0.6 + index * 0.5,
                    To = 1.4 + index * 0.5,
                    Duration = new Duration(TimeSpan.FromMilliseconds(1600)),
                    EnableDependentAnimation = true,
                };
                Storyboard.SetTarget(slide, stops[index]);
                Storyboard.SetTargetProperty(slide, "Offset");
                _glowStoryboard.Children.Add(slide);
            }
            var host = new Grid();
            host.Children.Add(card);
            host.Children.Add(_glow);
            Root = host;
            _bodyScroll.ViewChanged += (_, _) => UpdateFade();
            Update(new TranslateCard { Service = service });
        }

        public Grid Root { get; }

        public void Update(TranslateCard card)
        {
            var hasText = card.Text.Length > 0;
            // 生成中自动跟到末尾；用户往上滚过就不再跟（PLAN §3.7）。
            var follow = IsNearBottom();
            if (_body.Text != card.Text)
            {
                _body.Text = card.Text;
                if (follow)
                {
                    _body.UpdateLayout();
                    _bodyScroll.ChangeView(null, _bodyScroll.ScrollableHeight, null, disableAnimation: true);
                }
            }

            var waiting = (card.State is CardState.Waiting or CardState.Running) && !hasText;
            _bodyScroll.Visibility = hasText ? Visibility.Visible : Visibility.Collapsed;
            _skeleton.Visibility = waiting ? Visibility.Visible : Visibility.Collapsed;
            _errorCard.Visibility = Visibility.Collapsed;
            _actions.Children.Clear();

            // 生成中末尾的闪烁光标（PLAN-v2 §3.7）。
            var generating = card.State == CardState.Running && hasText && !card.Thinking;
            _cursor.Visibility = generating ? Visibility.Visible : Visibility.Collapsed;
            if (generating)
            {
                PositionCursor();
            }

            SetBlink(generating, _cursor);
            SetShimmer(waiting);

            var glow = card.State is CardState.Waiting or CardState.Running;
            if (glow && !_glowActive)
            {
                _glowActive = true;
                _glow.Visibility = Visibility.Visible;
                _glowStoryboard.Begin();
            }
            else if (!glow && _glowActive)
            {
                _glowActive = false;
                _glowStoryboard.Stop();
                _glow.Opacity = 0;
                _glow.Visibility = Visibility.Collapsed;
            }

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
                    _error.Foreground = Theme.Caution();
                    _errorCard.Background = Theme.Brush("Kitty.WarningFill", Theme.Argb(13, 157, 93, 0));
                    _errorCard.BorderBrush = Theme.Brush("Kitty.WarningStroke", Theme.Argb(46, 157, 93, 0));
                    _errorCard.Visibility = Visibility.Visible;
                    _actions.Children.Add(_retry);
                    break;
                case CardState.Failed:
                    _status.Text = "失败";
                    _error.Text = card.Error?.Message ?? "翻译失败";
                    // 设置问题是橙色，网络 / 服务问题是红色（PLAN-v2 §3.7）。
                    var config = card.Error?.Kind == TranslateErrorKind.Config;
                    _error.Foreground = config ? Theme.Caution() : Theme.Critical();
                    _errorCard.Background = config
                        ? Theme.Brush("Kitty.WarningFill", Theme.Argb(13, 157, 93, 0))
                        : Theme.Brush("Kitty.ErrorFill", Theme.Argb(13, 196, 43, 28));
                    _errorCard.BorderBrush = config
                        ? Theme.Brush("Kitty.WarningStroke", Theme.Argb(46, 157, 93, 0))
                        : Theme.Brush("Kitty.ErrorStroke", Theme.Argb(46, 196, 43, 28));
                    _errorCard.Visibility = Visibility.Visible;
                    // 设置类错误只给「打开设置」（PLAN §7.2：缺密钥 / 401–404 重试也没用）。
                    _actions.Children.Add(config ? _settings : _retry);
                    break;
            }

            if (hasText)
            {
                _actions.Children.Add(_copy);
                var speak = SmallButton("朗读");
                speak.Click += (_, _) => Speech.Speak(_body.Text, _owner._coordinator.Target.Code());
                _actions.Children.Add(speak);
                // 替换原文（第三版 §3.2）：单词模式的结果是释义、不给替换。
                if (!_owner._coordinator.WordMode && card.State == CardState.Done)
                {
                    var replace = SmallButton("替换原文");
                    replace.Click += (_, _) => _owner.ReplaceWith(_body.Text);
                    _actions.Children.Add(replace);
                }
            }

            UpdateFade();
        }

        /// <summary>下面还有内容时显示底部渐隐。</summary>
        private void UpdateFade()
        {
            var more = _bodyScroll.Visibility == Visibility.Visible &&
                       _bodyScroll.ScrollableHeight - _bodyScroll.VerticalOffset > 8;
            _fade.Visibility = more ? Visibility.Visible : Visibility.Collapsed;
        }

        /// <summary>
        /// 把光标贴到正文最后一个字后面（PLAN-v7 §3.3）：ContentEnd 的字符矩形是相对 TextBlock 的，
        /// 光标和正文在同一个 Grid 里，所以直接当 Margin 用；取不到就留在左上角。
        /// </summary>
        private void PositionCursor()
        {
            try
            {
                var rect = _body.ContentEnd.GetCharacterRect(default);
                if (!rect.IsEmpty)
                {
                    _cursor.Height = Math.Max(10, rect.Height * 0.82);
                    _cursor.Margin = new Thickness(rect.X, rect.Y + (rect.Height - _cursor.Height) / 2, 0, 0);
                }
            }
            catch
            {
                _cursor.Margin = new Thickness(0);
            }
        }

        private void SetShimmer(bool on)
        {
            if (on == _shimmering)
            {
                return;
            }

            _shimmering = on;
            var visual = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(_skeleton);
            if (on)
            {
                var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
                animation.InsertKeyFrame(0f, 0.35f);
                animation.InsertKeyFrame(0.5f, 0.85f);
                animation.InsertKeyFrame(1f, 0.35f);
                animation.Duration = TimeSpan.FromSeconds(1.2);
                animation.IterationBehavior = Microsoft.UI.Composition.AnimationIterationBehavior.Forever;
                visual.StartAnimation("Opacity", animation);
            }
            else
            {
                visual.StopAnimation("Opacity");
                visual.Opacity = 1;
            }
        }

        private void SetBlink(bool on, UIElement element)
        {
            if (on == _blinking)
            {
                return;
            }

            _blinking = on;
            var visual = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(element);
            if (on)
            {
                var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
                animation.InsertKeyFrame(0f, 1f);
                animation.InsertKeyFrame(0.5f, 0f);
                animation.InsertKeyFrame(1f, 1f);
                animation.Duration = TimeSpan.FromSeconds(0.9);
                animation.IterationBehavior = Microsoft.UI.Composition.AnimationIterationBehavior.Forever;
                visual.StartAnimation("Opacity", animation);
            }
            else
            {
                visual.StopAnimation("Opacity");
                visual.Opacity = 0;
            }
        }

        private bool IsNearBottom()
        {
            // 还有 8 px 以内就算在底部：流式输出时跟着走。
            var remaining = _bodyScroll.ScrollableHeight - _bodyScroll.VerticalOffset;
            return remaining <= 8 || double.IsNaN(remaining);
        }

        private static Button SmallButton(string text) => new()
        {
            Content = text,
            Padding = new Thickness(8, 2, 8, 2),
            FontSize = 11,
        };
    }
}
