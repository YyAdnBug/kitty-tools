// 翻译浮窗（照 mac TranslatePanelView，PLAN-v9-translate 8b–8d）：三层、没有分割线（内边距 12、层间距 10）——
// 顶栏：两个 28 高的语言胶囊（显示实际语言，自动时带「自动」标签）+ 圆形互换钮（转半圈、两个胶囊滑着换位），右边是复制即译开着时的
// 状态胶囊（点一下关掉）、图钉、「⋯」菜单（翻译历史 Ctrl+H、清空历史…、导出、条数、复制即译、设置… Ctrl+,）；
// 原文框（高 76，Enter 翻译，Shift+Enter / Ctrl+Enter 换行；只在出乎所选时写一行方向说明）+ 框内一行操作（朗读原文、复制原文、清空 ｜
// 收藏 Ctrl+D、划词来的「替换原文」），原文改过还没重译时右下角才出「翻译 ↩」；下面是各服务的结果卡（TranslateCardView，折叠按服务记住）。
// 翻译历史（TranslateHistoryView）整块替换结果区，原文区不动。宽 420 起（只能往宽里拖，记住），高度随内容（TranslateSession.PanelHeight：
// 最矮 220，结果卡不超过三张时全放下、多于三张时至少放下前三张）。字号可调（Ctrl+= / Ctrl+- / Ctrl+0）。
// 位置：输入翻译总在上次的位置；划词、复制即译、截图翻译照「浮窗位置」（跟随鼠标 / 上次位置）。复制即译只露出、不激活。
// 按键在根上统一分发（PreviewKeyDown，焦点在卡片正文、按钮上也灵；历史开着时先给它）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;
using Color = Windows.UI.Color;

namespace KittyTools;

internal sealed partial class TranslateWindow : Window
{
    private const int MinWidthDip = 420;
    private const double EmptyHeight = 200;

    /// <summary>窗口边框（量出来的内容高再加它才是外框）。</summary>
    private const double FrameDip = 8;

    /// <summary>主键盘上的 , = -（VirtualKey 里没有名字）。</summary>
    private const VirtualKey OemComma = (VirtualKey)188;
    private const VirtualKey OemPlus = (VirtualKey)187;
    private const VirtualKey OemMinus = (VirtualKey)189;

    private const string SourcePlaceholder = "输入或粘贴文字，Enter 翻译，Shift+Enter 换行";
    private const string MissedPlaceholder = "没取到选中的文字，可以直接输入或粘贴";

    private readonly TranslateCoordinator _coordinator = new();
    private readonly Dictionary<string, TranslateCardView> _cardViews = new();

    private readonly Grid _root;
    private readonly StackPanel _chrome;
    private readonly Grid _topBar;
    private readonly StackPanel _languages;
    private readonly Button _sourcePill;
    private readonly Button _targetPill;
    private readonly Button _swap;
    private readonly FontIcon _swapIcon;
    private readonly Button _copyBadge;
    private readonly Button _pin;
    private readonly FontIcon _pinIcon;
    private readonly Border _sourceBox;
    private readonly TextBox _source;
    private readonly TextBlock _note;
    private readonly Button _speakSource;
    private readonly FontIcon _speakIcon;
    private readonly Button _copySource;
    private readonly Button _clearSource;
    private readonly Button _star;
    private readonly FontIcon _starIcon;
    private readonly Button _replace;
    private readonly Button _translateCapsule;
    private readonly ScrollViewer _cardsScroll;
    private readonly StackPanel _cardsPanel;
    private readonly Grid _emptyHost;
    private readonly TranslateHistoryView _history;

    private HWND _hwnd;
    private HWND _previousForeground;
    private bool _visible;
    private bool _hiding;
    private bool _noActivate;
    private bool _resizing;
    private bool _quietSource;
    private bool _composing;
    private bool _historyVisible;
    private int _holdOpen;
    private int _swaps;
    private string _emptyKey = string.Empty;
    private int _widthDip = MinWidthDip;
    private (int X, int Y)? _dragStartCursor;
    private (int X, int Y)? _dragStartWindow;

    public TranslateWindow()
    {
        Title = Paths.ProductName + " 翻译";
        _root = new Grid { RequestedTheme = Theme.ElementTheme };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // ---- 顶栏
        _sourcePill = LanguagePill("源语言");
        _sourcePill.Click += (_, _) => ShowLanguageMenu(_sourcePill, target: false);
        _targetPill = LanguagePill("目标语言");
        _targetPill.Click += (_, _) => ShowLanguageMenu(_targetPill, target: true);
        _swapIcon = new FontIcon { Glyph = Glyphs.Swap, FontSize = 11, FontWeight = FontWeights.SemiBold };
        _swap = new Button
        {
            Content = _swapIcon,
            Width = 24,
            Height = 24,
            Padding = new Thickness(0),
            MinWidth = 0,
            MinHeight = 0,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(0),
            Background = Theme.Brush("Kitty.Fill.Control", Theme.Argb(15, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _swap.Click += (_, _) => SwapLanguages();
        ToolTipService.SetToolTip(_swap, "交换语言");
        AutomationProperties.SetName(_swap, "交换语言");
        _languages = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        _languages.Children.Add(_sourcePill);
        _languages.Children.Add(_swap);
        _languages.Children.Add(_targetPill);

        _copyBadge = new Button
        {
            Content = "复制即译",
            Height = 22,
            MinHeight = 0,
            MinWidth = 0,
            Padding = new Thickness(10, 0, 10, 0),
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            CornerRadius = new CornerRadius(11),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _copyBadge.Click += (_, _) => SetCopyTranslate(false);
        ToolTipService.SetToolTip(_copyBadge, "复制即译已开启：复制文字后自动翻译。点一下关闭");
        AutomationProperties.SetName(_copyBadge, "复制即译已开启，点一下关闭");

        _pinIcon = new FontIcon { Glyph = Glyphs.Pin, FontSize = 13 };
        _pin = IconButton(_pinIcon, "固定浮窗");
        _pin.Click += (_, _) => TogglePin();
        var more = IconButton(new FontIcon { Glyph = Glyphs.More, FontSize = 13 }, "更多：翻译历史、导出、复制即译、设置");
        var moreMenu = new MenuFlyout();
        moreMenu.Opening += (_, _) => BuildMoreMenu(moreMenu);
        more.Flyout = moreMenu;
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        tools.Children.Add(_pin);
        tools.Children.Add(more);

        _topBar = new Grid { ColumnSpacing = 8, Height = 28, Background = new SolidColorBrush(Colors.Transparent) };
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_copyBadge, 1);
        Grid.SetColumn(tools, 2);
        _topBar.Children.Add(_languages);
        _topBar.Children.Add(_copyBadge);
        _topBar.Children.Add(tools);
        _topBar.PointerPressed += OnTopBarPointerPressed;
        _topBar.PointerMoved += OnTopBarPointerMoved;
        _topBar.PointerReleased += (_, _) => EndDrag();
        _topBar.PointerCaptureLost += (_, _) => EndDrag();

        // ---- 原文框：输入框 + 方向说明 + 一行操作，外面一层画底和焦点环
        _source = new TextBox
        {
            PlaceholderText = SourcePlaceholder,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 76,
            Padding = new Thickness(12, 0, 12, 0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        SearchLine.MakePlain(_source);
        ScrollViewer.SetVerticalScrollBarVisibility(_source, ScrollBarVisibility.Auto);
        AutomationProperties.SetName(_source, "原文");
        _source.TextChanged += (_, _) =>
        {
            if (!_quietSource)
            {
                _coordinator.SetSource(_source.Text);
            }
        };
        _source.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnSourceKeyDown), handledEventsToo: true);
        _source.TextCompositionStarted += (_, _) => _composing = true;
        _source.TextCompositionEnded += (_, _) => _composing = false;
        _source.GotFocus += (_, _) => _sourceBox!.BorderBrush = new SolidColorBrush(Theme.AccentColor);
        _source.LostFocus += (_, _) => _sourceBox!.BorderBrush = new SolidColorBrush(Colors.Transparent);
        _source.Loaded += (_, _) =>
        {
            if (_visible && !_noActivate)
            {
                FocusSource();
            }
        };

        _note = new TextBlock
        {
            FontSize = 11,
            Foreground = Theme.SecondaryText(),
            Margin = new Thickness(12, 0, 12, 0),
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };

        _speakIcon = new FontIcon { Glyph = Glyphs.Volume, FontSize = 13 };
        _speakSource = IconButton(_speakIcon, "朗读原文");
        _speakSource.Click += (_, _) => Speech.Toggle(
            _coordinator.SourceText, (_coordinator.FixedSource ?? _coordinator.Detected)?.Code() ?? SettingsService.Current.TranslateSource);
        _copySource = IconButton(new FontIcon { Glyph = Glyphs.Copy, FontSize = 13 }, "复制原文");
        _copySource.Click += (_, _) => CopySource();
        _clearSource = IconButton(new FontIcon { Glyph = Glyphs.ClearInput, FontSize = 13 }, "清空");
        _clearSource.Click += (_, _) =>
        {
            _coordinator.BeginInput();
            SetSourceQuietly(string.Empty);
            FocusSource();
        };
        _starIcon = new FontIcon { Glyph = Glyphs.Star, FontSize = 13 };
        _star = IconButton(_starIcon, "收藏这次翻译（Ctrl+D），在历史里可以只看收藏");
        _star.Click += (_, _) => _coordinator.ToggleFavorite();
        var replaceContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        replaceContent.Children.Add(new FontIcon { Glyph = Glyphs.ReplaceBack, FontSize = 12 });
        replaceContent.Children.Add(new TextBlock { Text = "替换原文", FontSize = 12 });
        _replace = new Button
        {
            Content = replaceContent,
            Height = 24,
            MinHeight = 0,
            Padding = new Thickness(6, 0, 6, 0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Foreground = Theme.SecondaryText(),
            Visibility = Visibility.Collapsed,
        };
        _replace.Click += (_, _) => ReplaceOriginal();
        ToolTipService.SetToolTip(_replace, "用第一个翻译成功的服务的译文替换原文");
        AutomationProperties.SetName(_replace, "替换原文");
        _translateCapsule = TranslateCapsule();
        _translateCapsule.Click += (_, _) => _coordinator.Start();

        var leftActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        leftActions.Children.Add(_speakSource);
        leftActions.Children.Add(_copySource);
        leftActions.Children.Add(_clearSource);
        var rightActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        rightActions.Children.Add(_star);
        rightActions.Children.Add(_replace);
        rightActions.Children.Add(_translateCapsule);
        var actionRow = new Grid { Height = 24, Margin = new Thickness(10, 0, 8, 0) };
        actionRow.Children.Add(leftActions);
        actionRow.Children.Add(rightActions);

        var sourceStack = new StackPanel { Spacing = 6 };
        sourceStack.Children.Add(_source);
        sourceStack.Children.Add(_note);
        sourceStack.Children.Add(actionRow);
        _sourceBox = new Border
        {
            Background = Theme.Brush("Kitty.Input", Theme.Argb(11, 0, 0, 0)),
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Colors.Transparent),
            Padding = new Thickness(0, 8, 0, 8),
            Child = sourceStack,
        };

        _chrome = new StackPanel { Spacing = 10, Padding = new Thickness(12, 12, 12, 0) };
        _chrome.Children.Add(_topBar);
        _chrome.Children.Add(_sourceBox);
        _root.Children.Add(_chrome);

        // ---- 结果区：卡片 / 空状态 / 历史
        _cardsPanel = new StackPanel { Spacing = 10, Padding = new Thickness(12, 0, 12, 10) };
        _cardsScroll = new ScrollViewer
        {
            Content = _cardsPanel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            IsTabStop = false,
        };
        _emptyHost = new Grid { Height = EmptyHeight, Padding = new Thickness(20) };
        _history = new TranslateHistoryView(
            entry =>
            {
                SetSourceQuietly(entry.Source);
                ShowHistory(false);
                _coordinator.Translate(entry.Source);
            },
            () => ShowHistory(false),
            () => AppWindow.Id,
            hold => _holdOpen += hold ? 1 : -1)
        {
            Visibility = Visibility.Collapsed,
        };
        var results = new Grid { Margin = new Thickness(0, 10, 0, 2) };
        results.Children.Add(_cardsScroll);
        results.Children.Add(_emptyHost);
        results.Children.Add(_history);
        Grid.SetRow(results, 1);
        _root.Children.Add(results);
        _root.AddHandler(UIElement.PreviewKeyDownEvent, new KeyEventHandler(OnRootPreviewKeyDown), handledEventsToo: true);

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
        // REVIEW R64 A：Alt+F4 当成收起（真关了 TranslateHost 还指着这扇窗，之后的翻译热键都失灵到重启）。
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            Hide(restoreForeground: true);
        };

        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Activated += OnActivated;
        AppWindow.Changed += OnWindowChanged;
        _coordinator.Changed += OnCoordinatorChanged;
        _coordinator.Copied += id =>
        {
            if (_cardViews.TryGetValue(id, out var view))
            {
                view.FlashCopy();
            }
        };
        _coordinator.Announce += Announce;
        Speech.Changed += OnSpeechChanged;
        _widthDip = Math.Max(MinWidthDip, (int)Math.Round(SettingsService.Current.TranslateWindowWidth));
        ApplyFontScale();
        RefreshAll();
    }

    public bool IsVisible => _visible;

    /// <summary>最近一次翻译的原文（复制即译拿它去重）。</summary>
    public string? TranslatedSource => _coordinator.TranslatedSource;

    public void MarkLanguagesChanged()
    {
        if (_visible)
        {
            if (_coordinator.SourceText.Trim().Length > 0)
            {
                _coordinator.Start();
            }
        }
        else
        {
            _coordinator.LanguageChanged = true;
        }
    }

    public void AuditAccessibility() => AccessibilityAudit.Run(_root, "translate");

    // ---- 入口

    /// <summary>输入翻译：保留上次的原文和结果、原文全选（直接打字就替换），上次收起时中断的卡重跑；总在上次的位置。划词没取到字时清空。</summary>
    public void ShowInput(bool missedSelection)
    {
        _noActivate = false;
        RemoveNoActivateStyle();
        if (missedSelection)
        {
            _coordinator.BeginInput(missedSelection: true);
        }
        else
        {
            _coordinator.ResumeInput();
        }

        SetSourceQuietly(_coordinator.SourceText);
        ShowCore(activate: true, followMouse: false);
        ActivateWindow();
        FocusSource();
        _source.SelectAll();
    }

    public void ShowSelection(string text, ReplaceTarget? replace)
    {
        _noActivate = false;
        RemoveNoActivateStyle();
        SetSourceQuietly(text);
        _coordinator.Translate(text, replace);
        ShowCore(activate: true, followMouse: FollowsMouse);
        ActivateWindow();
        FocusSource();
    }

    public void ShowText(string text, bool fromCopy)
    {
        _noActivate = fromCopy;
        SetSourceQuietly(text);
        _coordinator.Translate(text, fromCopy: fromCopy);
        if (fromCopy)
        {
            ApplyNoActivateStyle();
            ShowCore(activate: false, followMouse: FollowsMouse);
            PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)4); // SW_SHOWNOACTIVATE
            OutsideClickHook.Install(_hwnd, OnOutsideClick);
            ResizeToContent();
            return;
        }

        RemoveNoActivateStyle();
        ShowCore(activate: true, followMouse: FollowsMouse);
        ActivateWindow();
        FocusSource();
    }

    /// <summary>剪贴板里的「翻译」（Ctrl+T）：浮窗只露出、不抢焦点，剪贴板面板留着（PLAN §7.4）；点浮窗外面自己收起。</summary>
    public void ShowTextPassive(string text)
    {
        _noActivate = true;
        ApplyNoActivateStyle();
        SetSourceQuietly(text);
        _coordinator.Translate(text);
        ShowCore(activate: false, followMouse: FollowsMouse);
        PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)4); // SW_SHOWNOACTIVATE
        OutsideClickHook.Install(_hwnd, OnOutsideClick);
        ResizeToContent();
    }

    /// <summary>不激活露出的浮窗（复制即译、剪贴板里的翻译）点到外面：固定着就不收（同 mac OverlayPanel.clickedOutside）。</summary>
    private void OnOutsideClick()
    {
        if (!SettingsService.Current.TranslatePinned)
        {
            Hide(restoreForeground: false);
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
            Speech.Stop();
            if (_historyVisible)
            {
                ShowHistory(false);
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

    /// <summary>宽和位置不管哪种「浮窗位置」都记（输入翻译总在上次的位置）。</summary>
    public void SaveGeometry()
    {
        var settings = SettingsService.Current;
        var position = AppWindow.Position;
        if (Math.Abs(settings.TranslateWindowWidth - _widthDip) < 1 &&
            (int)settings.TranslateWindowX == position.X && (int)settings.TranslateWindowY == position.Y)
        {
            return;
        }

        settings.TranslateWindowWidth = _widthDip;
        settings.TranslateWindowX = position.X;
        settings.TranslateWindowY = position.Y;
        SettingsService.Save();
    }

    private static bool FollowsMouse => SettingsService.Current.TranslateWindowPosition != "last";

    private void ShowCore(bool activate, bool followMouse)
    {
        IdleReclaimer.Cancel();
        _root.RequestedTheme = Theme.ElementTheme;
        var before = Foreground.Get();
        _previousForeground = before != default && !Foreground.IsOurs(before) ? before : default;
        ApplyFontScale();
        RefreshAll();
        Place(followMouse);
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
        if (_historyVisible)
        {
            _history.FocusSearch();
            return;
        }

        if (!_source.Focus(FocusState.Programmatic))
        {
            _ = FocusManager.TryFocusAsync(_source, FocusState.Programmatic);
        }
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding &&
            !SettingsService.Current.TranslatePinned && !_noActivate && _holdOpen <= 0)
        {
            Hide(restoreForeground: false);
            return;
        }

        if (args.WindowActivationState == WindowActivationState.CodeActivated && _visible && !_noActivate)
        {
            DispatcherQueue.TryEnqueue(FocusSource);
        }
    }

    /// <summary>拖边改宽：记住；比 420 窄就弹回 420（B16）。</summary>
    private void OnWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidSizeChange || _resizing || sender.Size.Width <= 0)
        {
            return;
        }

        var scale = Displays.AtWindow(_hwnd).Scale;
        var width = (int)Math.Round(sender.Size.Width / scale);
        _widthDip = Math.Max(MinWidthDip, width);
        if (width < MinWidthDip)
        {
            DispatcherQueue.TryEnqueue(ResizeToContent);
        }
    }

    // ---- 按键

    private void OnRootPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Handled || _composing || e.Key == (VirtualKey)0xE5)
        {
            return;
        }

        var control = IsDown(VirtualKey.Control) && !IsDown(VirtualKey.Menu);
        var shift = IsDown(VirtualKey.Shift);
        if (_historyVisible && _history.HandleKey(e, control, shift))
        {
            e.Handled = true;
            return;
        }

        var handled = true;
        switch (e.Key)
        {
            case VirtualKey.Escape:
                Hide(restoreForeground: true);
                break;
            case VirtualKey.H when control:
                ShowHistory(!_historyVisible);
                break;
            case OemComma when control:
                TranslateHost.OpenSettings();
                break;
            case VirtualKey.R when control:
                if (_coordinator.SourceText.Trim().Length == 0)
                {
                    SystemSound.Beep();
                }
                else
                {
                    _coordinator.Start();
                }

                break;
            case VirtualKey.D when control && !_historyVisible:
                if (!_coordinator.ToggleFavorite())
                {
                    SystemSound.Beep();
                }

                break;
            case VirtualKey.P when control:
                TogglePin();
                break;
            case VirtualKey.W when control:
                Hide(restoreForeground: true);
                break;
            case OemPlus or VirtualKey.Add when control: // Ctrl+= / 小键盘 +
                SetFontScale(SettingsService.Current.TranslateFontScale + 0.1);
                break;
            case OemMinus or VirtualKey.Subtract when control: // Ctrl+- / 小键盘 -
                SetFontScale(SettingsService.Current.TranslateFontScale - 0.1);
                break;
            case VirtualKey.Number0 or VirtualKey.NumberPad0 when control:
                SetFontScale(1.0);
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number9 when control:
                var index = (int)e.Key - (int)VirtualKey.Number1;
                if (index >= _coordinator.Cards.Count || !_coordinator.CopyCard(_coordinator.Cards[index].Service.Id))
                {
                    SystemSound.Beep();
                }

                break;
            default:
                handled = false;
                break;
        }

        e.Handled = handled;
    }

    /// <summary>原文框：Enter 翻译，Shift+Enter / Ctrl+Enter 换行（组字时的 Enter 是上屏，不管）。</summary>
    private void OnSourceKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || _composing || IsDown(VirtualKey.Menu))
        {
            return;
        }

        e.Handled = true;
        if (IsDown(VirtualKey.Shift) || IsDown(VirtualKey.Control))
        {
            InsertNewline();
        }
        else if (_source.Text.Trim().Length > 0)
        {
            _coordinator.Start();
        }
    }

    private void InsertNewline()
    {
        var caret = _source.SelectionStart;
        var text = _source.Text;
        _source.Text = text.Remove(caret, _source.SelectionLength).Insert(caret, "\r");
        _source.SelectionStart = caret + 1;
    }

    // ---- 顶栏

    private void TogglePin()
    {
        SettingsService.Current.TranslatePinned = !SettingsService.Current.TranslatePinned;
        SettingsService.Save();
        UpdatePin();
    }

    private void UpdatePin()
    {
        var pinned = SettingsService.Current.TranslatePinned;
        _pinIcon.Glyph = pinned ? Glyphs.Pinned : Glyphs.Pin;
        _pinIcon.Foreground = pinned ? new SolidColorBrush(Theme.AccentColor) : Theme.SecondaryText();
        ToolTipService.SetToolTip(_pin, pinned ? "已固定：点别处不收起（Ctrl+P）" : "固定浮窗（Ctrl+P）");
        AutomationProperties.SetItemStatus(_pin, pinned ? "已固定" : "未固定");
    }

    private void SetCopyTranslate(bool on)
    {
        SettingsService.Current.CopyTranslate = on;
        SettingsService.Save();
        TranslateHost.ApplyCopyTranslate();
        UpdateCopyBadge();
    }

    private void UpdateCopyBadge()
    {
        var on = SettingsService.Current.CopyTranslate;
        _copyBadge.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        var accent = Theme.AccentColor;
        _copyBadge.Background = new SolidColorBrush(Theme.Argb(41, accent.R, accent.G, accent.B));
        _copyBadge.Foreground = new SolidColorBrush(Theme.AccentTextColor);
    }

    /// <summary>「⋯」菜单（F8）：翻译历史、清空历史…、导出（4 种）、条数、复制即译、设置…；键位写在菜单项右边（按键在根上已经处理）。</summary>
    private void BuildMoreMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        var (total, favorites) = TranslationHistory.Instance?.Counts() ?? (0, 0);
        var history = new ToggleMenuFlyoutItem { Text = "翻译历史", IsChecked = _historyVisible, KeyboardAcceleratorTextOverride = "Ctrl+H" };
        history.Click += (_, _) => ShowHistory(!_historyVisible);
        var clear = new MenuFlyoutItem { Text = "清空历史…", IsEnabled = total > favorites, Foreground = Theme.Critical() };
        clear.Click += (_, _) => _ = HistoryMenu.ConfirmClearAsync(_root.XamlRoot);
        var export = new MenuFlyoutSubItem { Text = "导出", IsEnabled = total > 0 };
        foreach (var (favoritesOnly, anki, title) in HistoryMenu.Exports)
        {
            var item = new MenuFlyoutItem { Text = title };
            item.Click += (_, _) => _ = ExportAsync(favoritesOnly, anki);
            export.Items.Add(item);
        }

        var counts = new MenuFlyoutItem { Text = $"共 {total} 条 · 收藏 {favorites}", IsEnabled = false };
        var copyTranslate = new ToggleMenuFlyoutItem { Text = "复制即译", IsChecked = SettingsService.Current.CopyTranslate };
        copyTranslate.Click += (_, _) => SetCopyTranslate(copyTranslate.IsChecked);
        var settings = new MenuFlyoutItem { Text = "设置…", KeyboardAcceleratorTextOverride = "Ctrl+," };
        settings.Click += (_, _) => TranslateHost.OpenSettings();
        menu.Items.Add(history);
        menu.Items.Add(clear);
        menu.Items.Add(export);
        menu.Items.Add(counts);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(copyTranslate);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(settings);
    }

    private async Task ExportAsync(bool favoritesOnly, bool anki)
    {
        // 文件对话框是另一扇窗：开着时浮窗别因为失去激活收起来。
        _holdOpen++;
        try
        {
            await HistoryMenu.ExportAsync(AppWindow.Id, favoritesOnly, anki);
        }
        finally
        {
            _holdOpen--;
        }
    }

    // ---- 语言

    /// <summary>源胶囊：固定的写语言名；自动时写检测到的（还没翻译时「自动检测」）。目标同理（还没翻译时「自动」）。</summary>
    private void UpdateHeader()
    {
        var settings = SettingsService.Current;
        var source = Langs.FromCode(settings.TranslateSource);
        var target = Langs.FromCode(settings.TranslateTarget);
        var sourceTitle = source?.Title() ?? (_coordinator.FixedSource ?? _coordinator.Detected)?.Title() ?? "自动检测";
        var targetTitle = target?.Title() ?? _coordinator.Target?.Title() ?? "自动";
        SetPill(_sourcePill, sourceTitle, source is null && sourceTitle != "自动检测");
        SetPill(_targetPill, targetTitle, target is null && targetTitle != "自动");
        var bothAuto = source is null && target is null;
        _swap.IsEnabled = !bothAuto;
        _swap.Opacity = bothAuto ? 0.35 : 1;
    }

    private void ShowLanguageMenu(Button anchor, bool target)
    {
        var settings = SettingsService.Current;
        var current = target ? settings.TranslateTarget : settings.TranslateSource;
        var menu = new MenuFlyout();
        var (first, second) = Langs.Pair(settings.TranslateFirstLanguage, settings.TranslateSecondLanguage);
        var auto = new ToggleMenuFlyoutItem
        {
            Text = target ? $"自动（{first.Title()} ⇄ {second.Title()}）" : "自动检测",
            IsChecked = current is null,
        };
        auto.Click += (_, _) => Choose(target, null);
        menu.Items.Add(auto);
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var lang in Enum.GetValues<Lang>())
        {
            var code = lang.Code();
            var item = new ToggleMenuFlyoutItem { Text = lang.Title(), IsChecked = current == code };
            item.Click += (_, _) => Choose(target, code);
            menu.Items.Add(item);
        }

        menu.ShowAt(anchor);
    }

    /// <summary>选成和另一边相同的固定语言时，另一边换成这边原来的值（像交换一样），不会出现「英 → 英」（B3）。</summary>
    private void Choose(bool target, string? code)
    {
        var settings = SettingsService.Current;
        var mine = target ? settings.TranslateTarget : settings.TranslateSource;
        var other = target ? settings.TranslateSource : settings.TranslateTarget;
        if (code is not null && code == other)
        {
            other = mine;
        }

        (settings.TranslateSource, settings.TranslateTarget) = target ? (other, code) : (code, other);
        SettingsService.Save();
        Retranslate();
    }

    /// <summary>原样互换，「自动」也照换（B2）；箭头转半圈、两个胶囊滑着换位（Glide）。</summary>
    private void SwapLanguages()
    {
        var settings = SettingsService.Current;
        if (settings.TranslateSource is null && settings.TranslateTarget is null)
        {
            return;
        }

        var oldTargetX = _targetPill.TransformToVisual(_languages).TransformPoint(default).X;
        (settings.TranslateSource, settings.TranslateTarget) = (settings.TranslateTarget, settings.TranslateSource);
        SettingsService.Save();
        _swaps++;
        UpdateHeader();
        if (!Motion.Reduced)
        {
            var icon = ElementCompositionPreview.GetElementVisual(_swapIcon);
            icon.CenterPoint = new System.Numerics.Vector3((float)_swapIcon.ActualWidth / 2, (float)_swapIcon.ActualHeight / 2, 0);
            var turn = icon.Compositor.CreateScalarKeyFrameAnimation();
            turn.InsertKeyFrame(1f, _swaps * 180f);
            turn.Duration = TimeSpan.FromSeconds(0.3);
            icon.StartAnimation("RotationAngleInDegrees", turn);

            // 新的源胶囊是原来右边那个、新的目标胶囊是原来左边那个：各从原来的位置滑过来。
            _languages.UpdateLayout();
            var newTargetX = _targetPill.TransformToVisual(_languages).TransformPoint(default).X;
            Motion.SlideTo(_sourcePill, oldTargetX, 0, MotionCurve.Instant);
            Motion.SlideTo(_sourcePill, 0, 0, MotionCurve.Glide);
            Motion.SlideTo(_targetPill, -newTargetX, 0, MotionCurve.Instant);
            Motion.SlideTo(_targetPill, 0, 0, MotionCurve.Glide);
        }

        Retranslate();
    }

    /// <summary>换了源 / 目标：浮窗开着、有原文才重译。</summary>
    private void Retranslate()
    {
        UpdateHeader();
        if (_coordinator.SourceText.Trim().Length > 0)
        {
            _coordinator.Start();
        }
    }

    // ---- 原文区

    private void SetSourceQuietly(string text)
    {
        _quietSource = true;
        _source.Text = text;
        _source.SelectionStart = text.Length;
        _quietSource = false;
    }

    private void RefreshSourceArea()
    {
        _source.PlaceholderText = _coordinator.MissedSelection ? MissedPlaceholder : SourcePlaceholder;
        var note = DirectionNote();
        _note.Text = note ?? string.Empty;
        _note.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
        var hasSource = _coordinator.SourceText.Length > 0;
        _speakSource.IsEnabled = _copySource.IsEnabled = _clearSource.IsEnabled = hasSource;
        var speaking = hasSource && Speech.Speaking == _coordinator.SourceText;
        _speakIcon.Glyph = speaking ? Glyphs.VolumeOn : Glyphs.Volume;
        _speakIcon.Foreground = speaking ? new SolidColorBrush(Theme.AccentColor) : Theme.SecondaryText();
        var favorite = _coordinator.IsFavorite;
        _star.IsEnabled = _coordinator.Primary is not null;
        _starIcon.Glyph = favorite ? Glyphs.StarFilled : Glyphs.Star;
        _starIcon.Foreground = favorite ? Theme.Brush("Kitty.Favorite", Theme.Argb(255, 0xFF, 0xCC, 0x00)) : Theme.SecondaryText();
        AutomationProperties.SetName(_star, favorite ? "取消收藏" : "收藏");
        // 查单个词时结果是一段释义，不能拿去替换。
        _replace.Visibility = _coordinator.Replace is not null && !_coordinator.IsWordLookup ? Visibility.Visible : Visibility.Collapsed;
        _replace.IsEnabled = _coordinator.CanReplace;
        var needs = _coordinator.NeedsTranslate;
        if (needs != (_translateCapsule.Visibility == Visibility.Visible))
        {
            _translateCapsule.Visibility = needs ? Visibility.Visible : Visibility.Collapsed;
            if (needs)
            {
                Motion.Appear(_translateCapsule);
            }
        }
    }

    /// <summary>只在出乎所选时写一行：固定目标正好是原文语言而改译了另一端；固定源和检测结果对不上（照所选发出，只提示）。</summary>
    private string? DirectionNote()
    {
        if (_coordinator.AbandonedTarget is { } abandoned && _coordinator.Target is { } to)
        {
            return $"原文已是{abandoned.Title()}，改译成{to.Title()}";
        }

        if (_coordinator.FixedSource is { } fixedSource && _coordinator.Detected is { } detected && !detected.SameLanguage(fixedSource))
        {
            return $"检测到{detected.Title()}，仍按{fixedSource.Title()}翻译";
        }

        return null;
    }

    private void CopySource()
    {
        var text = _coordinator.SourceText;
        if (text.Length == 0 || !ClipboardWriter.WriteText(text))
        {
            return;
        }

        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(text);
        NoticeHost.Show("已复制原文", TranslateSession.Excerpt(text), NoticeTone.Normal);
    }

    /// <summary>
    /// 替换原文（B7）：用主结果、照原选区补回首尾的空白；先收起浮窗再粘回取词时的窗口。那扇窗已经不是取词的那个程序了就只复制。
    /// </summary>
    private void ReplaceOriginal()
    {
        if (_coordinator.Replace is not { } target || _coordinator.Primary is not { } primary || _coordinator.IsWordLookup)
        {
            return;
        }

        var result = TranslateSession.Rewrap(primary.Text, target.Text);
        Hide(restoreForeground: false);
        if (target.Window == default || Foreground.PidOf(target.Window) != target.ProcessId)
        {
            if (ClipboardWriter.WriteText(result))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(result);
            }

            NoticeHost.Show("已复制译文", "取词的窗口已经关了，没有替换", NoticeTone.Normal);
            return;
        }

        // REVIEW R60：失败时 Paster 已经弹了具体原因（没能切回原窗口 / 管理员窗口 / 剪贴板被占），这里不再另报。
        if (Paster.Paste(target.Window, () => ClipboardWriter.WriteText(result), ClipboardService.Instance))
        {
            ClipboardService.Instance?.Store.RecordOwnText(result);
            NoticeHost.Show("已替换原文", TranslateSession.Excerpt(result), NoticeTone.Normal);
        }
    }

    // ---- 字号

    private void SetFontScale(double scale)
    {
        var clamped = Math.Round(Math.Clamp(scale, 0.8, 1.6), 1);
        if (Math.Abs(clamped - SettingsService.Current.TranslateFontScale) < 0.001)
        {
            return;
        }

        SettingsService.Current.TranslateFontScale = clamped;
        SettingsService.Save();
        ApplyFontScale();
        RefreshResults();
        ResizeToContent();
    }

    private void ApplyFontScale() => _source.FontSize = 15 * SettingsService.Current.TranslateFontScale;

    // ---- 结果区

    private void OnCoordinatorChanged()
    {
        RefreshSourceArea();
        UpdateHeader();
        RefreshResults();
        ResizeToContent();
    }

    private void RefreshAll()
    {
        UpdatePin();
        UpdateCopyBadge();
        UpdateHeader();
        RefreshSourceArea();
        RefreshResults();
    }

    /// <summary>结果区：有提示 → 提示；没有启用的服务 → 去设置；还没翻译 → 三个入口和它们的快捷键；否则是卡片。历史开着时整块是历史。</summary>
    private void RefreshResults()
    {
        var mode = _coordinator.Notice is { } notice
            ? "notice:" + notice
            : TranslateServiceStore.Instance?.Enabled.Any() != true
                ? "none"
                : _coordinator.Cards.Count == 0 ? "empty" : "cards";
        var showsCards = mode == "cards";
        _cardsScroll.Visibility = showsCards && !_historyVisible ? Visibility.Visible : Visibility.Collapsed;
        _emptyHost.Visibility = !showsCards && !_historyVisible ? Visibility.Visible : Visibility.Collapsed;
        if (!showsCards && mode != _emptyKey)
        {
            _emptyKey = mode;
            _emptyHost.Children.Clear();
            _emptyHost.Children.Add(EmptyContent(mode));
        }

        if (showsCards)
        {
            _emptyKey = string.Empty;
            SyncCards();
        }
    }

    private FrameworkElement EmptyContent(string mode)
    {
        if (mode.StartsWith("notice:", StringComparison.Ordinal))
        {
            return EmptyState.Create(Glyphs.Info, mode["notice:".Length..], string.Empty);
        }

        if (mode == "none")
        {
            var panel = EmptyState.Create(Glyphs.Translate, "没有启用的翻译服务", string.Empty);
            var open = new Button
            {
                Content = "打开翻译设置",
                HorizontalAlignment = HorizontalAlignment.Center,
                Style = Theme.Style("AccentButtonStyle"),
            };
            open.Click += (_, _) => TranslateHost.OpenSettings();
            panel.Children.Add(open);
            return panel;
        }

        var empty = EmptyState.Create(Glyphs.Translate, "划词、截图或输入后开始翻译", string.Empty);
        foreach (var action in new[] { HotKeyActions.SelectionTranslate, HotKeyActions.ScreenshotTranslate, HotKeyActions.InputTranslate })
        {
            var row = new Grid { Width = 200 };
            row.Children.Add(new TextBlock
            {
                Text = SettingsDefaults.Find(action)?.DisplayName ?? action,
                FontSize = 12,
                Foreground = Theme.SecondaryText(),
                VerticalAlignment = VerticalAlignment.Center,
            });
            var shortcut = HotKeyManager.FormatFor(action);
            FrameworkElement keys = shortcut == "未设置"
                ? new TextBlock { Text = "未设置", FontSize = 12, Foreground = Theme.TertiaryText() }
                : (FrameworkElement)KeyCap.Combo(shortcut.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));
            keys.HorizontalAlignment = HorizontalAlignment.Right;
            row.Children.Add(keys);
            empty.Children.Add(row);
        }

        return empty;
    }

    /// <summary>卡片和会话里的卡对上（按服务 id；没变就原地更新，不重建）。</summary>
    private void SyncCards()
    {
        var cards = _coordinator.Cards;
        var ids = cards.Select(card => card.Service.Id).ToList();
        if (ids.Count != _cardViews.Count ||
            !ids.SequenceEqual(_cardsPanel.Children.Select(child => (child as FrameworkElement)?.Tag as string ?? string.Empty)))
        {
            var keep = _cardViews.Where(pair => ids.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value);
            _cardViews.Clear();
            _cardsPanel.Children.Clear();
            foreach (var card in cards)
            {
                var id = card.Service.Id;
                if (!keep.TryGetValue(id, out var view))
                {
                    view = new TranslateCardView(
                        card.Service,
                        () => _coordinator.Retry(id),
                        () =>
                        {
                            if (!_coordinator.CopyCard(id))
                            {
                                SystemSound.Beep();
                            }
                        },
                        () => ToggleCollapse(id),
                        () => TranslateHost.OpenSettings(id));
                    view.Root.Tag = id;
                }

                _cardViews[id] = view;
                _cardsPanel.Children.Add(view.Root);
            }
        }

        var collapsed = SettingsService.Current.TranslateCollapsedServices ?? new List<string>();
        for (var index = 0; index < cards.Count; index++)
        {
            var card = cards[index];
            if (_cardViews.TryGetValue(card.Service.Id, out var view))
            {
                view.Update(card, index, SettingsService.Current.TranslateFontScale, collapsed.Contains(card.Service.Id),
                    _coordinator.CopiedCard == card.Service.Id, _coordinator.Target);
            }
        }
    }

    /// <summary>折叠按服务记住（跨重启），不再因为出结果自动展开（F3）。</summary>
    private void ToggleCollapse(string id)
    {
        var collapsed = SettingsService.Current.TranslateCollapsedServices ?? new List<string>();
        if (!collapsed.Remove(id))
        {
            collapsed.Add(id);
        }

        SettingsService.Current.TranslateCollapsedServices = collapsed;
        SettingsService.Save();
        RefreshResults();
        ResizeToContent();
    }

    private void OnSpeechChanged()
    {
        RefreshSourceArea();
        foreach (var view in _cardViews.Values)
        {
            view.RefreshSpeaking();
        }
    }

    // ---- 历史

    private void ShowHistory(bool show)
    {
        if (show == _historyVisible)
        {
            return;
        }

        _historyVisible = show;
        _history.Reset();
        _history.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        RefreshResults();
        if (show)
        {
            Motion.FadeIn(_history, MotionCurves.FadeInSeconds);
            _history.FocusSearch();
        }
        else
        {
            // 关上时焦点立刻还给原文框（不等淡出：淡出期间按的键会落进看不见的搜索框）。
            FocusSource();
        }

        ResizeToContent();
    }

    // ---- 截图自检

    /// <summary>
    /// UI 截图自检（--ui-snapshots）：摆出一种状态，不激活地露在左上角 (8, 8)（RenderTargetBitmap 只画它自己的内容）。
    /// translate-empty / -running / -done / -truncated / -history / -history-menu。卡片是摆出来的，不发请求。正常入口不碰。
    /// </summary>
    internal void ShowProbe(string state)
    {
        const string source = "The quick brown fox jumps over the lazy dog. It was the best of times, it was the worst of times.";
        var zhipu = new TranslateServiceConfig { Id = "probe-zhipu", Kind = TranslateKinds.Zhipu, Name = "智谱 GLM（免费）", Model = "glm-4-flash" };
        var deepseek = new TranslateServiceConfig
        {
            Id = "probe-deepseek",
            Kind = TranslateKinds.Ai,
            Name = "DeepSeek",
            BaseUrl = "https://api.deepseek.com/v1",
            Model = "deepseek-chat",
        };
        const string done = "敏捷的棕色狐狸跳过了那只懒狗。那是最好的时代，也是最坏的时代。";
        ShowHistory(false);
        SetSourceQuietly(state == "translate-empty" ? string.Empty : source);
        switch (state)
        {
            case "translate-empty":
                _coordinator.BeginInput();
                break;
            case "translate-running":
                _coordinator.ShowProbe(source, Lang.En, Lang.ZhHans, new[]
                {
                    new TranslateCard { Service = zhipu, State = CardState.Running },
                    new TranslateCard { Service = deepseek, State = CardState.Running, Text = "敏捷的棕色狐狸跳过了那只懒狗。那是最好的时代，" },
                });
                break;
            case "translate-done":
                _coordinator.ShowProbe(source, Lang.En, Lang.ZhHans, new[]
                {
                    new TranslateCard { Service = zhipu, State = CardState.Done, Text = "敏捷的**棕色狐狸**跳过了那只懒狗。那是最好的时代，也是最坏的时代（`best of times`）。" },
                    new TranslateCard
                    {
                        Service = deepseek,
                        State = CardState.Failed,
                        Error = TranslateError.Config("请先在设置里填写服务地址和模型"),
                    },
                });
                break;
            case "translate-truncated":
                _coordinator.ShowProbe(source, Lang.En, Lang.ZhHans, new[]
                {
                    new TranslateCard
                    {
                        Service = deepseek,
                        State = CardState.Truncated,
                        Text = string.Join("\n", Enumerable.Repeat(done, 6)),
                        Error = TranslateError.Truncated,
                    },
                });
                break;
            default:
                _coordinator.ShowProbe(source, Lang.En, Lang.ZhHans, new[]
                {
                    new TranslateCard { Service = zhipu, State = CardState.Done, Text = done },
                });
                break;
        }

        if (!_visible)
        {
            _noActivate = true;
            ShowCore(activate: false, followMouse: false);
        }

        if (state.StartsWith("translate-history", StringComparison.Ordinal))
        {
            ShowHistory(true);
            _history.ApplyProbeState(menu: state == "translate-history-menu");
        }

        AppWindow.Move(new PointInt32(8, 8));
        ResizeToContent();
    }

    // ---- 尺寸和位置

    /// <summary>内容要的高、至少要放得下的高（结果卡多于三张时到第三张的下沿）。都是 DIP，含窗口边框。</summary>
    private (double Desired, double MustFit) MeasureHeights()
    {
        var width = _widthDip;
        _chrome.Measure(new Windows.Foundation.Size(width, double.PositiveInfinity));
        var chrome = _chrome.DesiredSize.Height;
        double body;
        double? third = null;
        if (_historyVisible)
        {
            body = TranslateHistoryView.PanelHeight;
        }
        else if (_cardsScroll.Visibility == Visibility.Visible)
        {
            _cardsPanel.Measure(new Windows.Foundation.Size(width, double.PositiveInfinity));
            body = _cardsPanel.DesiredSize.Height;
            if (_cardsPanel.Children.Count > 3)
            {
                third = _cardsPanel.Children.Take(3).Sum(child => child.DesiredSize.Height) + 2 * _cardsPanel.Spacing + _cardsPanel.Padding.Bottom;
            }
        }
        else
        {
            body = EmptyHeight;
        }

        var desired = chrome + 10 + body + 2 + FrameDip;
        var mustFit = third is { } bottom ? chrome + 10 + bottom + 2 + FrameDip : desired;
        return (desired, mustFit);
    }

    private void ResizeToContent()
    {
        if (!_visible)
        {
            return;
        }

        try
        {
            var display = Displays.AtWindow(_hwnd);
            var (desired, mustFit) = MeasureHeights();
            var heightDip = TranslateSession.PanelHeight(desired, mustFit, display.Work.Height / display.Scale);
            var widthPx = MonitorLayout.Pixels(_widthDip, display.Scale);
            var heightPx = MonitorLayout.Pixels(heightDip, display.Scale);
            if (Math.Abs(AppWindow.Size.Height - heightPx) < 2 && Math.Abs(AppWindow.Size.Width - widthPx) < 2)
            {
                return;
            }

            _resizing = true;
            var position = AppWindow.Position;
            AppWindow.MoveAndResize(new RectInt32(position.X, position.Y, widthPx, heightPx));
        }
        catch (Exception ex)
        {
            Log.Warn($"translate.resize-failed {ex.GetType().Name}");
        }
        finally
        {
            _resizing = false;
        }
    }

    /// <summary>followMouse：放在光标右下 12（放不下翻到左边 / 上边）；否则上次的位置（第一次没有记过时也跟着鼠标）。</summary>
    private void Place(bool followMouse)
    {
        var settings = SettingsService.Current;
        var (desired, mustFit) = MeasureHeights();
        if (!followMouse && (settings.TranslateWindowX != 0 || settings.TranslateWindowY != 0))
        {
            // 上次的位置：按那块屏（存的是像素坐标）的缩放比例换算尺寸。
            var x = (int)settings.TranslateWindowX;
            var y = (int)settings.TranslateWindowY;
            var display = Displays.AtPoint(x, y);
            var height = TranslateSession.PanelHeight(desired, mustFit, display.Work.Height / display.Scale);
            var rect = MonitorLayout.Clamp(
                new PixelRect(x, y, MonitorLayout.Pixels(_widthDip, display.Scale), MonitorLayout.Pixels(height, display.Scale)),
                display.Work);
            AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
            return;
        }

        var pointer = Displays.AtCursor();
        var pointerHeight = TranslateSession.PanelHeight(desired, mustFit, pointer.Work.Height / pointer.Scale);
        PInvoke.GetCursorPos(out var cursor);
        var placed = MonitorLayout.NearPointer(cursor.X, cursor.Y, pointer.Work, pointer.Scale, _widthDip, pointerHeight);
        AppWindow.MoveAndResize(new RectInt32(placed.X, placed.Y, placed.Width, placed.Height));
    }

    // ---- 拖动顶栏挪窗口

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
        AppWindow.Move(new PointInt32(origin.X + cursor.X - start.X, origin.Y + cursor.Y - start.Y));
    }

    private void EndDrag()
    {
        if (_dragStartCursor is null)
        {
            return;
        }

        _dragStartCursor = null;
        _dragStartWindow = null;
        _topBar.ReleasePointerCaptures();
        SaveGeometry();
    }

    // ---- 小零件

    private void Announce(string text)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(_source) ?? FrameworkElementAutomationPeer.CreatePeerForElement(_source);
        peer?.RaiseNotificationEvent(
            AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, text, "translate");
    }

    /// <summary>28 高的语言胶囊：语言名 13 medium +（自动且已知实际语言时）「自动」标签 + 10 的下拉箭头，左 12 右 10。</summary>
    private static Button LanguagePill(string name)
    {
        var button = new Button
        {
            Height = 28,
            MinHeight = 0,
            Padding = new Thickness(12, 0, 10, 0),
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(0),
            Background = Theme.Brush("Kitty.Fill.Control", Theme.Argb(15, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, name);
        AutomationProperties.SetName(button, name);
        return button;
    }

    private static void SetPill(Button pill, string title, bool autoTag)
    {
        // 流式时每个字都会走到这里：没变就不重建。
        var key = title + (autoTag ? "|auto" : string.Empty);
        if (pill.Tag as string == key)
        {
            return;
        }

        pill.Tag = key;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (autoTag)
        {
            var accent = Theme.AccentColor;
            row.Children.Add(new Border
            {
                Padding = new Thickness(4, 1, 4, 1),
                CornerRadius = new CornerRadius(7),
                Background = new SolidColorBrush(Theme.Argb(41, accent.R, accent.G, accent.B)),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock
                {
                    Text = "自动",
                    FontSize = 10,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(Theme.AccentTextColor),
                },
            });
        }

        row.Children.Add(new FontIcon
        {
            Glyph = Glyphs.ChevronDown,
            FontSize = 10,
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        });
        pill.Content = row;
        AutomationProperties.SetItemStatus(pill, title);
    }

    private static Button IconButton(FontIcon icon, string name)
    {
        icon.Foreground ??= Theme.SecondaryText();
        var button = new Button
        {
            Content = icon,
            Width = 24,
            Height = 24,
            Padding = new Thickness(0),
            MinWidth = 0,
            MinHeight = 0,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, name);
        AutomationProperties.SetName(button, name);
        return button;
    }

    /// <summary>原文框右下角的「翻译 ↩」：强调色实心胶囊（24 高、左右 12、12 semibold），只在原文改过、还没重译时出现。</summary>
    private static Button TranslateCapsule()
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        content.Children.Add(new TextBlock { Text = "翻译", FontSize = 12, FontWeight = FontWeights.SemiBold });
        content.Children.Add(new TextBlock { Text = "↩", FontSize = 12, FontWeight = FontWeights.SemiBold, Opacity = 0.75 });
        var button = new Button
        {
            Content = content,
            Height = 24,
            MinHeight = 0,
            Padding = new Thickness(12, 0, 12, 0),
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Theme.AccentColor),
            Foreground = new SolidColorBrush(Theme.OnAccentColor),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        ToolTipService.SetToolTip(button, "翻译改过的原文（Enter）");
        AutomationProperties.SetName(button, "翻译");
        return button;
    }

    private unsafe void ApplyNoActivateStyle()
    {
        var style = GetWindowLong((IntPtr)_hwnd.Value, -20);
        SetWindowLong((IntPtr)_hwnd.Value, -20, style | 0x08000000); // WS_EX_NOACTIVATE
    }

    private unsafe void RemoveNoActivateStyle()
    {
        var style = GetWindowLong((IntPtr)_hwnd.Value, -20);
        SetWindowLong((IntPtr)_hwnd.Value, -20, style & ~0x08000000);
    }

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);
}
