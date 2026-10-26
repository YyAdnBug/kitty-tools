// 剪贴板面板：搜索框 + 收藏范围 + 左列表右预览。焦点一直在搜索框，方向键转给列表。
// 按键表见 PLAN §6.3；删除先只从列表拿掉（Ctrl+Z 可撤），面板收起时才真的删库。
// 列表用一个固定的 ObservableCollection，按键搜索时只替换变了的尾部，不整表重建 ItemsSource。
// 第二版 §3.5：高度随内容（三行起、十行封顶）、只有一块会滑动的选中高亮、按住 Ctrl 150 ms 后
// 前九行右边浮现数字键帽、预览卡按内容换字体 / 色块 / 棋盘格、空状态各一句。
using System.Collections.ObjectModel;
using System.Numerics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using Windows.Win32;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;

namespace KittyTools;

public sealed partial class ClipboardPanel : UserControl
{
    private readonly List<ClipEntry> _visible = new();
    private readonly ObservableCollection<ClipRow> _rows = new();
    /// <summary>搜索线的输入框（PLAN-v7 §2.2 的共用部件）。</summary>
    private TextBox SearchBox => SearchLineControl.Box;
    /// <summary>当前选中行透镜里的内容（U1：原地展开，不再有右边那一栏）。</summary>
    private readonly StackPanel PreviewHost = new() { Spacing = 8 };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _keyHintTimer;
    private bool _favoritesOnly;
    private ClipScope _scope = ClipScope.All;
    private string? _groupFilterId;
    private bool _active;
    private bool _showKeyHints;
    private bool _animateHighlight;
    private MotionCurve _highlightCurve = MotionCurve.Glide;
    private ScrollViewer? _listScroll;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _linkTimer;
    private CancellationTokenSource? _linkCts;
    private Uri? _linkPending;
    private bool _composing;

    public ClipboardPanel()
    {
        InitializeComponent();
        SearchBox.PlaceholderText = "搜索剪贴板…";
        SearchBox.TextChanged += OnSearchTextChanged;
        AddHandler(KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: true);
        AddHandler(KeyUpEvent, new KeyEventHandler(OnKeyUp), handledEventsToo: true);
        SearchBox.TextCompositionStarted += (_, _) => _composing = true;
        SearchBox.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            Refresh(animated: false);
        };
        List.ContainerContentChanging += (_, e) =>
        {
            if (e.Item is ClipRow row && e.ItemContainer is { } container)
            {
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
                    container, $"{row.Title}，{row.RightText}");
            }
        };
        SearchBox.Loaded += (_, _) =>
        {
            if (_active)
            {
                FocusSearch();
            }
        };
        _keyHintTimer = DispatcherQueue.CreateTimer();
        _keyHintTimer.Interval = TimeSpan.FromMilliseconds(150);
        _keyHintTimer.IsRepeating = false;
        _keyHintTimer.Tick += (_, _) => SetKeyHints(true);

        List.Loaded += (_, _) =>
        {
            _listScroll ??= FindDescendant<ScrollViewer>(List);
            if (_listScroll is not null)
            {
                _listScroll.ViewChanged += (_, _) => MoveHighlight(animated: false);
            }

            MoveHighlight(animated: false);
        };
        if (ClipboardService.Instance?.Store is { } store)
        {
            store.Changed += OnStoreChanged;
        }

        // 空闲两分钟后放掉预览卡（图片解码最占内存），下次选中再建。
        IdleReclaimer.Register(ReleaseCaches);
    }

    /// <summary>空闲回收：清掉预览里的图片和控件。</summary>
    public void ReleaseCaches()
    {
        _lensScroll?.Content = null;
        PreviewHost.Children.Clear();
        Log.Info("clipboard.caches-released");
    }

    public event Action? CloseRequested;

    public event Action? SettingsRequested;

    /// <summary>底栏图钉 / Ctrl+P：固定面板（第三版 §4）。</summary>
    public event Action? PinRequested;

    /// <summary>内容高度变了（DIP，是否带动画）：浮层窗口据此改高度、顶边不动（第二版 §3.5）。</summary>
    public event Action<double, bool>? HeightRequested;

    /// <summary>按当前条数算出来的面板高度（三行起、十行封顶、最多 520 DIP）。</summary>
    public double ContentHeightDip
    {
        get
        {
            var groups = _visible
                .Select(entry => ClipRow.DateLabel(entry.CopiedAt))
                .Distinct(StringComparer.Ordinal)
                .Count();
            return PanelMetrics.ClipboardHeightFor(_visible.Count, groups);
        }
    }

    private static ClipboardStore? Store => ClipboardService.Instance?.Store;

    public void OnShown()
    {
        _active = true;
        SearchBox.Text = string.Empty;
        SetKeyHints(false);
        SetScope(ClipScope.All, refresh: false);
        Refresh(animated: false);
        FocusSearch();
    }

    /// <summary>从启动器「cb 词」进来：把词填进搜索框。</summary>
    public void SetQuery(string query)
    {
        SearchBox.Text = query;
        SearchBox.SelectionStart = SearchBox.Text.Length;
        Refresh();
        FocusSearch();
    }

    /// <summary>窗口激活后再抢一次焦点：刚 Activate 时 Focus 可能落不下去。</summary>
    public void FocusSearch()
    {
        var ok = SearchBox.Focus(FocusState.Programmatic);
        Log.Info($"clipboard.focus ok={ok}");
        if (!ok)
        {
            _ = FocusManager.TryFocusAsync(SearchBox, FocusState.Programmatic);
        }
    }

    public void OnHidden()
    {
        _active = false;
        _keyHintTimer.Stop();
        _showKeyHints = false;
        SearchBox.Text = string.Empty;
        _visible.Clear();
        _rows.Clear();
        List.SelectedIndex = -1;
        Highlight.Visibility = Visibility.Collapsed;
        PreviewHost.Children.Clear();
        if (Store is { } store)
        {
            store.CommitDeletion();
            store.EnforceLimits();
        }
    }

    public void Refresh(long? keepSelection = null, bool animated = true)
    {
        if (Store is not { } store)
        {
            return;
        }

        var previous = keepSelection ?? SelectedEntry?.Id;
        _visible.Clear();
        _visible.AddRange(store.Filter(SearchBox.Text.Trim(), _scope, _groupFilterId));

        ApplyRows();

        if (_visible.Count == 0)
        {
            _animateHighlight = false;
            List.SelectedIndex = -1;
            ShowPreview(null);
        }
        else
        {
            var index = previous is { } id ? _visible.FindIndex(entry => entry.Id == id) : 0;
            index = index < 0 ? 0 : index;
            if (List.SelectedIndex == index)
            {
                // 同一条还在同一个位置：选中项没变，高亮自己重新量一次就行。
                ShowPreview(_visible[index]);
                DispatcherQueue.TryEnqueue(() => MoveHighlight(animated: false));
            }
            else
            {
                _animateHighlight = animated;
                List.SelectedIndex = index;
            }

            List.ScrollIntoView(_rows[List.SelectedIndex]);
        }

        UpdateFooter();
        UpdateEmptyState();
        HeightRequested?.Invoke(ContentHeightDip, animated);
    }

    /// <summary>
    /// 只把变了的尾部换掉：前缀的条目和日期分隔都没变就沿用原来的行，
    /// 不重设 ItemsSource（每按一个键整表重建会让列表跳动、虚拟化的容器全丢）。
    /// </summary>
    private void ApplyRows()
    {
        if (!ReferenceEquals(List.ItemsSource, _rows))
        {
            List.ItemsSource = _rows;
        }

        var headers = new bool[_visible.Count];
        var lastDate = long.MinValue;
        for (var index = 0; index < _visible.Count; index++)
        {
            var localDate = DateTimeOffset.FromUnixTimeMilliseconds(_visible[index].CopiedAt).ToLocalTime().Date.Ticks;
            headers[index] = localDate != lastDate;
            lastDate = localDate;
        }

        var reuse = 0;
        while (reuse < _visible.Count && reuse < _rows.Count &&
               _rows[reuse].SameAs(_visible[reuse], headers[reuse], reuse, _showKeyHints))
        {
            reuse++;
        }

        for (var index = _rows.Count - 1; index >= reuse; index--)
        {
            _rows.RemoveAt(index);
        }

        for (var index = reuse; index < _visible.Count; index++)
        {
            _rows.Add(ClipRow.Create(_visible[index], headers[index], index, _showKeyHints));
        }
    }

    private void UpdateFooter()
    {
        if (_visible.Count == 0)
        {
            FooterText.Text = string.Empty;
            return;
        }

        var scope = _favoritesOnly ? "收藏 · " : string.Empty;
        var selected = SelectedEntries;
        FooterText.Text = selected.Count > 1
            ? $"{_visible.Count} 条 ｜ {MultiPaste.Footer(selected.Count, MultiPaste.Mode(selected.Count, selected.All(entry => entry.Kind == ClipKind.Text), selected.All(entry => entry.Kind == ClipKind.Files)))}"
            : $"{_visible.Count} 条 ｜ {scope}粘贴 Enter · 纯文本 Shift+Enter · 更多（右键）· 收藏 Ctrl+D";
    }

    private List<ClipEntry> SelectedEntries => List.SelectedItems
        .OfType<ClipRow>()
        .Select(row => row.Entry)
        .OrderBy(entry => entry.CopiedAt)
        .ToList();

    /// <summary>拖出去（第三版 §5）：文本带格式、文件给原文件、图片给临时 PNG；拖不算粘贴，不挪顺序也不记历史。</summary>
    private void OnDragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        var entries = e.Items.OfType<ClipRow>()
            .Select(row => row.Entry)
            .OrderBy(entry => entry.CopiedAt)
            .ToList();
        if (entries.Count == 0)
        {
            return;
        }

        try
        {
            e.Data.Properties.Title = "Kitty Tools";
            if (entries.All(entry => entry.Kind == ClipKind.Text))
            {
                var text = MultiPaste.Merge(entries.Select(entry => entry.Text ?? string.Empty));
                e.Data.SetText(text);
                if (entries.Count == 1)
                {
                    var rich = RichOf(entries[0]);
                    if (!string.IsNullOrEmpty(rich.Html))
                    {
                        e.Data.SetHtmlFormat(HtmlFormatHelper.CreateHtmlFormat(rich.Html));
                    }
                }
            }
            else
            {
                var files = entries
                    .Where(entry => entry.Kind == ClipKind.Files)
                    .SelectMany(entry => entry.Files)
                    .Where(File.Exists)
                    .ToList();
                if (files.Count == 0 && Store is { } store)
                {
                    files = entries
                        .Where(entry => entry.Kind == ClipKind.Image)
                        .Select(entry => store.Images.PathFor(entry.Id))
                        .Where(File.Exists)
                        .ToList();
                }

                if (files.Count > 0)
                {
                    e.Data.SetStorageItems(files.Select(path =>
                        StorageFile.GetFileFromPathAsync(path).AsTask().GetAwaiter().GetResult()));
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.drag-failed {ex.GetType().Name}");
        }
    }

    private void UpdateEmptyState()
    {
        var empty = _visible.Count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (empty)
        {
            EmptyText.Text = SearchBox.Text.Trim().Length > 0
                ? "没有匹配的条目\n换个词试试"
                : "还没有剪贴板历史\n复制点什么就会出现";
        }
    }

    /// <summary>按住 Ctrl 150 ms 后前九行右边浮现数字键帽（PLAN-v2 §3.5）。</summary>
    private void SetKeyHints(bool show)
    {
        if (_showKeyHints == show)
        {
            return;
        }

        _showKeyHints = show;
        ApplyRows();
    }

    /// <summary>只有一块中性高亮，换选中项时滑过去：键盘用 snap，鼠标点用 glide，换列表时不动画。</summary>
    private void MoveHighlight(bool animated)
    {
        var index = List.SelectedIndex;
        if (index < 0 || index >= _visible.Count)
        {
            Highlight.Visibility = Visibility.Collapsed;
            return;
        }

        if (List.ContainerFromIndex(index) is not ListViewItem container)
        {
            // 容器还没实现（虚拟化 / 刚换列表）：等下一次布局。
            Highlight.Visibility = Visibility.Collapsed;
            return;
        }

        var row = container.ContentTemplateRoot is Panel panel && panel.Children.Count > 1 &&
                  panel.Children[1] is FrameworkElement inner
            ? inner
            : container;
        var offset = row.TransformToVisual(List).TransformPoint(new Windows.Foundation.Point(0, 0));
        Highlight.Width = Math.Max(0, List.ActualWidth - 2);
        Highlight.Height = Math.Max(24, row.ActualHeight);
        Highlight.Visibility = Visibility.Visible;
        if (animated)
        {
            Motion.SlideTo(Highlight, 0, offset.Y, EnableAnimations ? _highlightCurve : MotionCurve.Instant);
        }
        else
        {
            Highlight.Translation = new Vector3(0, (float)offset.Y, 0);
        }
    }

    private bool EnableAnimations => !Motion.Reduced;

    private static T? FindDescendant<T>(DependencyObject root)
        where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T match)
            {
                return match;
            }

            if (FindDescendant<T>(child) is { } deeper)
            {
                return deeper;
            }
        }

        return null;
    }

    private ClipEntry? SelectedEntry => (List.SelectedItem as ClipRow)?.Entry;

    private void OnStoreChanged()
    {
        if (_active)
        {
            Refresh(SelectedEntry?.Id, animated: false);
        }
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        if (!CompositionRules.ShouldSearch(_composing, SearchBox.Text))
        {
            return;
        }

        Refresh(animated: false);
    }

    private void OnAllScopeClick(object sender, RoutedEventArgs e) =>
        SetScope(ClipScope.All);

    private void OnFavoriteScopeClick(object sender, RoutedEventArgs e) =>
        SetScope(ClipScope.Favorites);

    private void OnSnippetScopeClick(object sender, RoutedEventArgs e) =>
        SetScope(ClipScope.Snippets);

    private void OnGroupFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_active)
        {
            return;
        }

        _groupFilterId = GroupFilter.SelectedItem is ComboBoxItem { Tag: string id } ? id : null;
        Refresh(animated: false);
        SearchBox.Focus(FocusState.Programmatic);
        UpdateFilterChips();
    }

    /// <summary>U2：Tab 弹出筛选菜单（全部 / 收藏 / 片段 / 收藏夹）。</summary>
    private void ShowFilterMenu()
    {
        var menu = new MenuFlyout();
        void AddScope(string text, ClipScope scope, bool selected)
        {
            var item = new MenuFlyoutItem { Text = text };
            if (selected)
            {
                item.Icon = new FontIcon { Glyph = Glyphs.Check };
            }

            item.Click += (_, _) => SetScope(scope);
            menu.Items.Add(item);
        }

        AddScope("全部", ClipScope.All, _scope == ClipScope.All);
        AddScope("收藏", ClipScope.Favorites, _scope == ClipScope.Favorites);
        AddScope("片段", ClipScope.Snippets, _scope == ClipScope.Snippets);
        if (Store is { } store && store.Groups.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var group in store.Groups.OrderBy(item => item.Position))
            {
                var item = new MenuFlyoutItem { Text = "收藏夹 · " + group.Name };
                if (_groupFilterId == group.Id)
                {
                    item.Icon = new FontIcon { Glyph = Glyphs.Check };
                }

                item.Click += (_, _) =>
                {
                    SetScope(ClipScope.Favorites, refresh: false);
                    _groupFilterId = group.Id;
                    Refresh();
                    UpdateFilterChips();
                    SearchBox.Focus(FocusState.Programmatic);
                };
                menu.Items.Add(item);
            }
        }

        menu.ShowAt(SearchLineControl, new FlyoutShowOptions
        {
            Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
        });
    }

    private void OnPinClick(object sender, RoutedEventArgs e) => PinRequested?.Invoke();

    private void SetScope(ClipScope scope, bool refresh = true)
    {
        _scope = scope;
        _favoritesOnly = scope == ClipScope.Favorites;
        AllScope.IsChecked = scope == ClipScope.All;
        FavoriteScope.IsChecked = scope == ClipScope.Favorites;
        SnippetScope.IsChecked = scope == ClipScope.Snippets;
        RefreshGroups();
        UpdateFilterChips();
        if (refresh)
        {
            Refresh();
            SearchBox.Focus(FocusState.Programmatic);
        }
    }

    /// <summary>U2：当前范围做成搜索线里的标签胶囊；点 × 回到全部。</summary>
    private void UpdateFilterChips()
    {
        SearchLineControl.Chips.Children.Clear();
        var text = _groupFilterId is { } id
            ? Store?.Groups.FirstOrDefault(group => group.Id == id)?.Name ?? "收藏夹"
            : _scope switch
            {
                ClipScope.Favorites => "收藏",
                ClipScope.Snippets => "片段",
                _ => "全部",
            };
        if (_scope == ClipScope.All && _groupFilterId is null)
        {
            SearchLineControl.AddChip(text);
            return;
        }

        SearchLineControl.AddChip(text, () =>
        {
            _groupFilterId = null;
            SetScope(ClipScope.All);
        });
    }

    /// <summary>「收藏」范围旁边那个收藏夹下拉：第一项是全部收藏夹。</summary>
    private void RefreshGroups()
    {
        GroupFilter.Visibility = _scope == ClipScope.Favorites ? Visibility.Visible : Visibility.Collapsed;
        if (_scope != ClipScope.Favorites)
        {
            _groupFilterId = null;
            return;
        }

        var store = Store;
        if (store is null)
        {
            return;
        }

        var previous = _groupFilterId;
        GroupFilter.Items.Clear();
        GroupFilter.Items.Add(new ComboBoxItem { Content = "全部收藏夹", Tag = string.Empty });
        foreach (var group in store.Groups.OrderBy(item => item.Position))
        {
            GroupFilter.Items.Add(new ComboBoxItem { Content = group.Name, Tag = group.Id });
        }

        var index = 0;
        if (previous is not null)
        {
            for (var item = 1; item < GroupFilter.Items.Count; item++)
            {
                if ((GroupFilter.Items[item] as ComboBoxItem)?.Tag as string == previous)
                {
                    index = item;
                    break;
                }
            }
        }

        _groupFilterId = index == 0 ? null : previous;
        GroupFilter.SelectedIndex = index;
        UpdateFilterChips();
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ShowPreview(SelectedEntry);
        ScheduleLinkPreview();
        UpdateFooter();
        var animated = _animateHighlight;
        _animateHighlight = false;
        // 选中项的容器可能还没实现：等这一轮布局完再量它的位置。
        DispatcherQueue.TryEnqueue(() => MoveHighlight(animated));
    }

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ClipRow row)
        {
            _animateHighlight = true;
            _highlightCurve = MotionCurve.Glide;
            List.SelectedItem = row;
        }
    }

    private void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        e.Handled = true;
        Paste(plain: false);
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private void ShowPreview(ClipEntry? entry)
    {
        PreviewHost.Children.Clear();
        if (entry is null)
        {
            AttachLens(null);
            PreviewHost.Children.Add(new TextBlock
            {
                Text = "选中一条看预览",
                Foreground = Theme.SecondaryText(),
                Margin = new Thickness(0, 8, 0, 0),
            });
            return;
        }

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // 卡头：类型图标 + 来源 + 时间（PLAN-v2 §3.5）。
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(new FontIcon
        {
            Glyph = entry.Kind switch
            {
                ClipKind.Image => "\uEB9F",
                ClipKind.Files => "\uE8B7",
                _ => "\uE8C8",
            },
            FontSize = 13,
            Foreground = new SolidColorBrush(Theme.Family.Clipboard),
            VerticalAlignment = VerticalAlignment.Center,
        });
        title.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(entry.SourceName) ? "本机" : entry.SourceName,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 120,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        title.Children.Add(new TextBlock
        {
            Text = PreviewRules.SourceAndAge(null, ClipRow.Relative(entry.CopiedAt)) + " · " +
                   DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt).ToLocalTime().ToString("HH:mm"),
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 72,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(title, 0);
        header.Children.Add(title);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var favorite = new Button
        {
            Content = entry.Favorite ? "取消收藏" : "收藏",
            Padding = new Thickness(10, 4, 10, 4),
        };
        favorite.Click += (_, _) =>
        {
            Store?.ToggleFavorite(entry.Id);
            Refresh(entry.Id, animated: false);
        };
        var copy = new Button { Content = "复制", Padding = new Thickness(10, 4, 10, 4) };
        copy.Click += (_, _) => Copy(entry);
        if (entry.Kind == ClipKind.Text)
        {
            var translate = new Button { Content = "翻译", Padding = new Thickness(10, 4, 10, 4) };
            translate.Click += (_, _) => TranslateEntry(entry);
            actions.Children.Add(translate);
        }

        actions.Children.Add(favorite);
        actions.Children.Add(copy);
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        PreviewHost.Children.Add(header);

        switch (entry.Kind)
        {
            case ClipKind.Image:
                ShowImage(entry);
                break;
            case ClipKind.Files:
                ShowFiles(entry);
                break;
            default:
                ShowText(entry);
                break;
        }

        AttachLens(entry);
    }

    private ScrollViewer? _lensScroll;

    /// <summary>把 PreviewHost 挂到选中行的透镜里；其它行的透镜收起来。</summary>
    private void AttachLens(ClipEntry? entry)
    {
        foreach (var row in _rows)
        {
            row.SetLens(null, 0);
        }

        if (entry is null)
        {
            return;
        }

        var index = _visible.FindIndex(item => item.Id == entry.Id);
        if (index < 0 || index >= _rows.Count)
        {
            return;
        }

        if (_lensScroll is not null)
        {
            _lensScroll.Content = null;
        }

        var body = LensBodyHeight(entry);
        _lensScroll = new ScrollViewer
        {
            Content = PreviewHost,
            MaxHeight = body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(16, 0, 16, 0),
            IsTabStop = false,
        };
        var host = new Grid { Height = body + 28 };
        host.Children.Add(_lensScroll);
        var cardColor = Theme.CardColor();
        host.Children.Add(new Border
        {
            Height = 26,
            VerticalAlignment = VerticalAlignment.Bottom,
            IsHitTestVisible = false,
            Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0),
                EndPoint = new Windows.Foundation.Point(0, 1),
                GradientStops =
                {
                    new GradientStop { Color = Theme.Argb(0, cardColor.R, cardColor.G, cardColor.B), Offset = 0 },
                    new GradientStop { Color = cardColor, Offset = 1 },
                },
            },
        });
        _rows[index].SetLens(host, body + 28);
        DispatcherQueue.TryEnqueue(() => MoveHighlight(animated: false));
    }

    private static double LensBodyHeight(ClipEntry entry)
    {
        if (entry.Kind == ClipKind.Image)
        {
            return 108;
        }

        if (entry.Kind == ClipKind.Files)
        {
            return 90;
        }

        var text = entry.Text ?? string.Empty;
        if (PreviewRules.TryParseColor(text, out _, out _, out _))
        {
            return 72;
        }

        if (PreviewRules.LooksLikeCode(text))
        {
            return 128;
        }

        if (LinkPreviewRules.SingleUrl(text) is not null)
        {
            return 90;
        }

        return text.Length <= 80 && !text.Contains('\n') ? 36 : 90;
    }

    private void ShowText(ClipEntry entry)
    {
        var text = entry.Text ?? string.Empty;

        // 整条就是一个颜色值：上面加一块色块（PLAN-v2 §3.5）。
        if (PreviewRules.TryParseColor(text, out var red, out var green, out var blue))
        {
            var swatch = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            swatch.Children.Add(new Border
            {
                Width = 44,
                Height = 44,
                CornerRadius = new CornerRadius(8),
                Background = new SolidColorBrush(Theme.Argb(255, red, green, blue)),
                BorderThickness = new Thickness(1),
                BorderBrush = Theme.Brush("ControlStrokeColorDefaultBrush", Theme.Argb(40, 128, 128, 128)),
            });
            swatch.Children.Add(new TextBlock
            {
                Text = $"#{red:X2}{green:X2}{blue:X2}",
                FontFamily = new FontFamily("Consolas"),
                FontSize = 13,
                VerticalAlignment = VerticalAlignment.Center,
            });
            PreviewHost.Children.Add(swatch);
        }

        const int limit = 50_000;
        var truncated = text.Length > limit;
        var code = PreviewRules.LooksLikeCode(text);
        var block = new TextBlock
        {
            Text = truncated ? text[..limit] : text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontSize = code ? 13 : 14,
            LineHeight = code ? 20 : 22,
        };
        if (code)
        {
            // FontFamily 不能设成 null（WinUI 里会直接挂掉），只在是代码时才换字体。
            block.FontFamily = new FontFamily("Consolas");
        }

        PreviewHost.Children.Add(block);
        if (truncated)
        {
            PreviewHost.Children.Add(new TextBlock
            {
                Text = $"只显示前 {limit:N0} 个字，粘贴时是完整内容",
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                Foreground = Theme.SecondaryText(),
            });
        }
    }

    private void ShowImage(ClipEntry entry)
    {
        var path = Paths.ImagesFile(entry.Id);
        if (!File.Exists(path))
        {
            PreviewHost.Children.Add(new TextBlock
            {
                Text = "图片文件丢了（可能被清理了）",
                Foreground = Theme.SecondaryText(),
            });
            return;
        }

        var stack = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        var checker = Checkerboard();
        stack.Children.Add(checker);

        var image = new Image
        {
            MaxHeight = 340,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        stack.Children.Add(image);

        // 右上角标「宽 × 高」（PLAN-v2 §3.5）。
        var size = new Border
        {
            Padding = new Thickness(6, 2, 6, 2),
            CornerRadius = new CornerRadius(4),
            Background = Theme.Brush("ControlFillColorSecondaryBrush", Theme.Argb(160, 32, 32, 32)),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 4, 4, 0),
            Child = new TextBlock
            {
                Text = $"{entry.Width} × {entry.Height}",
                FontSize = 11,
                FontFamily = new FontFamily("Consolas"),
            },
        };
        stack.Children.Add(size);
        PreviewHost.Children.Add(stack);
        _ = LoadImageAsync(image, path, PreviewDecodeWidth());
    }

    /// <summary>透明图片后面的棋盘格（十来行，比引一个平铺画刷省事）。</summary>
    private static Grid Checkerboard()
    {
        var grid = new Grid
        {
            Width = 320,
            Height = 240,
            HorizontalAlignment = HorizontalAlignment.Left,
            Opacity = 0.5,
        };
        var light = new SolidColorBrush(Theme.Argb(255, 220, 220, 220));
        var dark = new SolidColorBrush(Theme.Argb(255, 190, 190, 190));
        const int cell = 16;
        for (var row = 0; row < 15; row++)
        {
            for (var column = 0; column < 20; column++)
            {
                var square = new Border
                {
                    Width = cell,
                    Height = cell,
                    Background = (row + column) % 2 == 0 ? light : dark,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(column * cell, row * cell, 0, 0),
                };
                grid.Children.Add(square);
            }
        }

        return grid;
    }

    /// <summary>
    /// 预览按预览区的宽度 × 缩放比例解码（4K 截图整张解码要 33 MB）。预览区还没排好时给个保守值。
    /// </summary>
    private int PreviewDecodeWidth()
    {
        var width = List.ActualWidth > 0 ? Math.Max(240, List.ActualWidth - 48) : 520;
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        return Math.Clamp((int)Math.Round(width * scale), 64, 2048);
    }

    private async Task LoadImageAsync(Image image, string path, int decodeWidth)
    {
        try
        {
            using var stream = await FileRandomAccessStream.OpenAsync(path, FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = decodeWidth };
            await bitmap.SetSourceAsync(stream);
            image.Source = bitmap;
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.preview-image-failed {ex.GetType().Name}");
        }
    }

    private void ShowFiles(ClipEntry entry)
    {
        var files = entry.Files;
        var panel = new StackPanel { Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var file in files.Take(50))
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var exists = File.Exists(file) || Directory.Exists(file);
            row.Children.Add(new FontIcon
            {
                Glyph = Directory.Exists(file) ? "\uE8B7" : "\uE8A5",
                FontSize = 14,
                Opacity = exists ? 0.8 : 0.4,
            });
            row.Children.Add(new TextBlock
            {
                Text = exists ? file : file + "（找不到了）",
                TextWrapping = TextWrapping.Wrap,
                FontSize = 13,
                Opacity = exists ? 0.9 : 0.5,
            });
            panel.Children.Add(row);
        }

        if (files.Length > 50)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"还有 {files.Length - 50} 个文件",
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                Foreground = Theme.SecondaryText(),
            });
        }

        PreviewHost.Children.Add(panel);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_active)
        {
            return;
        }

        if (e.Key == VirtualKey.Control)
        {
            // 按住 Ctrl 150 ms 才浮现键帽：中途松开就不显示（PLAN-v2 §3.5）。
            _keyHintTimer.Stop();
            _keyHintTimer.Start();
            return;
        }

        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                if (SearchBox.Text.Length > 0)
                {
                    SearchBox.Text = string.Empty;
                }
                else
                {
                    CloseRequested?.Invoke();
                }

                break;
            case VirtualKey.W when control:
                e.Handled = true;
                CloseRequested?.Invoke();
                break;
            case VirtualKey.Down:
                e.Handled = true;
                MoveSelection(1);
                break;
            case VirtualKey.Up:
                e.Handled = true;
                MoveSelection(-1);
                break;
            case VirtualKey.Enter when !control:
                e.Handled = true;
                Paste(shift);
                break;
            case VirtualKey.Tab:
                e.Handled = true;
                ShowFilterMenu();
                break;
            case VirtualKey.N when control:
                e.Handled = true;
                _ = NewSnippetAsync();
                break;
            case VirtualKey.E when control:
                e.Handled = true;
                _ = EditSnippetAsync();
                break;
            case VirtualKey.P when control:
                e.Handled = true;
                PinRequested?.Invoke();
                break;
            case VirtualKey.K when control:
                e.Handled = true;
                ShowActionPanel();
                break;
            case VirtualKey.Delete when SearchBox.SelectionStart == SearchBox.Text.Length &&
                                        SearchBox.SelectionLength == 0:
                e.Handled = true;
                DeleteSelected();
                break;
            case VirtualKey.C when control:
                if (SearchBox.SelectionLength > 0)
                {
                    break; // 搜索框里选中了字：交还给搜索框
                }

                e.Handled = true;
                CopySelected();
                break;
            case VirtualKey.D when control:
                e.Handled = true;
                FavoriteSelected();
                break;
            case VirtualKey.Z when control:
                if (SearchBox.Text.Length > 0)
                {
                    break; // 搜索框里有字：让输入框自己撤销
                }

                e.Handled = true;
                UndoDelete();
                break;
            case VirtualKey.T when control:
                e.Handled = true;
                if (SelectedEntry is { } selected)
                {
                    TranslateEntry(selected);
                }

                break;
            case VirtualKey.Number1 or VirtualKey.Number2 or VirtualKey.Number3 or VirtualKey.Number4
                or VirtualKey.Number5 or VirtualKey.Number6 or VirtualKey.Number7 or VirtualKey.Number8
                or VirtualKey.Number9 when control:
                e.Handled = true;
                var number = (int)e.Key - (int)VirtualKey.Number1;
                if (number < _visible.Count)
                {
                    List.SelectedIndex = number;
                    Paste(plain: false);
                }

                break;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Control)
        {
            _keyHintTimer.Stop();
            SetKeyHints(false);
        }
    }

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void MoveSelection(int delta)
    {
        if (_visible.Count == 0)
        {
            return;
        }

        var index = Math.Clamp(List.SelectedIndex + delta, 0, _visible.Count - 1);
        _highlightCurve = MotionCurve.Snap;
        _animateHighlight = true;
        List.SelectedIndex = index;
        List.ScrollIntoView(List.SelectedItem);
    }

    private async void Paste(bool plain)
    {
        var selected = SelectedEntries;
        if (selected.Count > 1)
        {
            await PasteManyAsync(selected, plain);
            return;
        }

        var entry = SelectedEntry;
        if (entry is null)
        {
            return;
        }

        if (!EntryUsable(entry))
        {
            NoticeHost.Show("没能粘贴", entry.Kind == ClipKind.Image ? "图片文件丢了" : "文件已经不在原处", NoticeTone.Warning);
            return;
        }

        var target = OverlayHost.PasteTarget;
        if (target == default)
        {
            Copy(entry);
            return;
        }

        try
        {
            // 片段先展开占位符（第三版 §4），粘贴完再按 {cursor} 往左挪。
            var expansion = Expander.Of(entry, Store);
            var dib = entry.Kind == ClipKind.Image ? await PrepareDibAsync(entry) : null;
            var rich = RichOf(entry);
            var service = ClipboardService.Instance;
            var pasted = Paster.Paste(
                target,
                expansion is { } expanded
                    ? () => ClipboardWriter.WriteText(expanded.Text)
                    : () => ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plain, dib),
                service);
            if (pasted)
            {
                service?.Store.Bump(entry.Id);
                if (expansion is { CursorBackChars: > 0 } cursor)
                {
                    await Task.Delay(80);
                    Paster.SendLeft(cursor.CursorBackChars);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.paste-failed", ex);
            NoticeHost.Show("没能粘贴", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>多选粘贴（第三版 §5）：全文本合并、全文件一起、其余依次（间隔 250 ms）。</summary>
    private async Task PasteManyAsync(List<ClipEntry> entries, bool plain)
    {
        if (entries.Any(entry => !EntryUsable(entry)))
        {
            NoticeHost.Show("有文件已经不在原处", "先取消选择那几条", NoticeTone.Warning);
            return;
        }

        var mode = MultiPaste.Mode(
            entries.Count,
            entries.All(entry => entry.Kind == ClipKind.Text),
            entries.All(entry => entry.Kind == ClipKind.Files));
        var target = OverlayHost.PasteTarget;
        if (target == default)
        {
            // 没有可粘的目标：合并的复制合并结果，其余只复制第一条。
            var text = mode == MultiPasteMode.MergeText
                ? MultiPaste.Merge(entries.Select(entry => entry.Text ?? string.Empty))
                : entries[0].Text;
            if (!string.IsNullOrEmpty(text))
            {
                CopyText(text);
            }

            return;
        }

        try
        {
            switch (mode)
            {
                case MultiPasteMode.MergeText:
                {
                    var merged = MultiPaste.Merge(entries.Select(entry => entry.Text ?? string.Empty));
                    if (Paster.Paste(target, () => ClipboardWriter.WriteText(merged), ClipboardService.Instance))
                    {
                        ClipboardService.Instance?.Store.RecordOwnText(merged);
                        NoticeHost.Show("已合并粘贴", $"{entries.Count} 条", NoticeTone.Normal);
                    }

                    break;
                }

                case MultiPasteMode.FilesTogether:
                {
                    var combined = new ClipEntry
                    {
                        Kind = ClipKind.Files,
                        FilePaths = string.Join('\n', entries.SelectMany(entry => entry.Files)),
                    };
                    Paster.Paste(
                        target,
                        () => ClipboardWriter.WriteEntry(combined, null, null, plainText: false, null),
                        ClipboardService.Instance);
                    NoticeHost.Show("已一起粘贴", $"{combined.Files.Length} 个文件", NoticeTone.Normal);
                    break;
                }

                default:
                {
                    for (var index = 0; index < entries.Count; index++)
                    {
                        var entry = entries[index];
                        var dib = entry.Kind == ClipKind.Image ? await PrepareDibAsync(entry) : null;
                        var rich = RichOf(entry);
                        var expansion = Expander.Of(entry, Store);
                        var pasted = Paster.Paste(
                            target,
                            expansion is { } expanded
                                ? () => ClipboardWriter.WriteText(expanded.Text)
                                : () => ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plain, dib),
                            ClipboardService.Instance);
                        if (!pasted)
                        {
                            NoticeHost.Show("没能粘贴", "第 " + (index + 1) + " 条失败", NoticeTone.Error);
                            break;
                        }

                        if (index < entries.Count - 1)
                        {
                            await Task.Delay(MultiPaste.SequentialDelayMs);
                        }
                    }

                    NoticeHost.Show("已依次粘贴", $"{entries.Count} 条", NoticeTone.Normal);
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.paste-many-failed", ex);
            NoticeHost.Show("没能粘贴", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>选中「只有一个网址」的文本，停 0.25 s 再取预览（第三版 §5）；关掉设置时连缓存都不显示。</summary>
    private void ScheduleLinkPreview()
    {
        _linkTimer ??= DispatcherQueue.CreateTimer();
        _linkTimer.Interval = TimeSpan.FromMilliseconds(250);
        _linkTimer.IsRepeating = false;
        _linkTimer.Stop();
        _linkCts?.Cancel();
        _linkPending = null;

        if (!LinkPreviewService.Enabled || SelectedEntries is not { Count: 1 } selected ||
            selected[0].Kind != ClipKind.Text || LinkPreviewRules.SingleUrl(selected[0].Text) is not { } uri)
        {
            return;
        }

        _linkPending = uri;
        _linkTimer.Tick -= OnLinkTimerTick;
        _linkTimer.Tick += OnLinkTimerTick;
        _linkTimer.Start();
    }

    private void OnLinkTimerTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        if (_linkPending is { } uri)
        {
            _linkCts = new CancellationTokenSource();
            _ = LoadLinkPreviewAsync(uri, _linkCts.Token);
        }
    }

    private async Task LoadLinkPreviewAsync(Uri uri, CancellationToken cancellationToken)
    {
        var cached = await LinkPreviewService.FetchAsync(uri, cancellationToken);
        if (cancellationToken.IsCancellationRequested || !LinkPreviewService.Enabled || cached is null ||
            SelectedEntry is not { } entry || LinkPreviewRules.SingleUrl(entry.Text) != uri)
        {
            return;
        }

        AppendLinkCard(cached);
    }

    private void AppendLinkCard(LinkPreviewService.CachedPreview cached)
    {
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(new TextBlock
        {
            Text = cached.Preview.Title,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        stack.Children.Add(new TextBlock
        {
            Text = cached.Preview.Site,
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Foreground = Theme.SecondaryText(),
        });
        if (!string.IsNullOrEmpty(cached.Preview.Description))
        {
            stack.Children.Add(new TextBlock
            {
                Text = cached.Preview.Description,
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 3,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }

        if (cached.ImageBytes is { Length: > 0 } bytes)
        {
            try
            {
                var bitmap = new BitmapImage { DecodePixelWidth = 1200 };
                var stream = new InMemoryRandomAccessStream();
                using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
                {
                    writer.WriteBytes(bytes);
                    writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                }

                bitmap.SetSource(stream);
                stack.Children.Add(new Image
                {
                    Source = bitmap,
                    Stretch = Stretch.Uniform,
                    MaxHeight = 160,
                    HorizontalAlignment = HorizontalAlignment.Left,
                });
            }
            catch (Exception ex)
            {
                Log.Warn($"linkpreview.image-show-failed {ex.GetType().Name}");
            }
        }

        var card = new Border
        {
            Padding = new Thickness(10, 8, 10, 8),
            CornerRadius = new CornerRadius(8),
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            Child = stack,
            Margin = new Thickness(0, 8, 0, 0),
        };
        PreviewHost.Children.Add(card);
    }

    private void CopyText(string text)
    {
        if (ClipboardWriter.WriteText(text))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            NoticeHost.Show("已复制", KillLine(text), NoticeTone.Normal);
        }
    }

    private static async Task<byte[]?> PrepareDibAsync(ClipEntry entry)
        => (await ClipboardWriter.PrepareImageAsync(entry))?.Dib;

    private static (string? Html, string? Rtf) RichOf(ClipEntry entry)
        => entry.Kind == ClipKind.Text && ClipboardService.Instance is { } service
            ? service.Database.LoadRich(entry.Id)
            : (null, null);

    /// <summary>文件条目：只要还有一个在就还能粘（PLAN 和 mac 是全都不在才拦）。</summary>
    private static bool EntryUsable(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => File.Exists(Paths.ImagesFile(entry.Id)),
        ClipKind.Files => entry.Files.Any(file => File.Exists(file) || Directory.Exists(file)),
        _ => true,
    };

    private void CopySelected()
    {
        var entry = SelectedEntry;
        if (entry is not null)
        {
            Copy(entry);
        }
    }

    private async void Copy(ClipEntry entry)
    {
        if (!EntryUsable(entry))
        {
            NoticeHost.Show("没能复制", entry.Kind == ClipKind.Image ? "图片文件丢了" : "文件已经不在原处", NoticeTone.Warning);
            return;
        }

        try
        {
            var dib = entry.Kind == ClipKind.Image ? await PrepareDibAsync(entry) : null;
            var rich = RichOf(entry);
            var expansion = Expander.Of(entry, Store);
            var wrote = expansion is { } expanded
                ? ClipboardWriter.WriteText(expanded.Text)
                : ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plainText: false, dib);
            if (!wrote)
            {
                NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
                return;
            }

            ClipboardService.Instance?.MarkOwnWrite();
            NoticeHost.Show("已复制", PreviewLine(entry), NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.copy-failed", ex);
            NoticeHost.Show("没能复制", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static string PreviewLine(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => $"{entry.Width} × {entry.Height} 的图片",
        ClipKind.Files => entry.Files.FirstOrDefault() ?? "文件",
        _ => KillLine(entry.Text ?? string.Empty),
    };

    private static string KillLine(string text)
    {
        var line = text.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return line.Length <= 40 ? line : line[..40] + "…";
    }

    private void DeleteSelected()
    {
        var entries = SelectedEntries;
        if (entries.Count == 0 || Store is not { } store)
        {
            return;
        }

        store.DeleteWithUndo(entries.Select(entry => entry.Id).ToList());
        NoticeHost.Show(
            entries.Count > 1 ? $"已删除 {entries.Count} 条" : "已删除",
            "收起面板前可以按 Ctrl+Z 撤销",
            NoticeTone.Normal);
        Refresh();
    }

    private void UndoDelete()
    {
        if (Store is not { } store)
        {
            return;
        }

        var restored = store.Undo();
        if (restored is { Count: > 0 })
        {
            NoticeHost.Show("已撤销", string.Empty, NoticeTone.Normal);
            Refresh(restored[0].Id);
        }
    }

    private void FavoriteSelected()
    {
        var entries = SelectedEntries;
        if (entries.Count == 0 || Store is not { } store)
        {
            return;
        }

        // 批量：只要有一条不是收藏就全部收藏；全是收藏就全部取消。
        var target = entries.Any(entry => !entry.Favorite);
        foreach (var entry in entries.Where(entry => entry.Favorite != target))
        {
            store.ToggleFavorite(entry.Id);
        }

        Refresh(entries[0].Id);
    }

    private static void TranslateEntry(ClipEntry entry)
    {
        if (entry.Kind != ClipKind.Text || string.IsNullOrWhiteSpace(entry.Text))
        {
            NoticeHost.Show("不能翻译", "只有文本条目能翻译", NoticeTone.Warning);
            return;
        }

        // 剪贴板面板留着，翻译浮窗只露出（PLAN §7.4 / PLAN-v2 §6 第 1 批）。
        TranslateHost.ShowTextKeepOverlay(entry.Text);
    }

    private async Task PinImageAsync(ClipEntry entry)
    {
        try
        {
            var path = Paths.ImagesFile(entry.Id);
            if (!File.Exists(path))
            {
                return;
            }
            var png = await File.ReadAllBytesAsync(path);
            var decoded = await ImageCodec.PngToBgraAsync(png);
            if (decoded is not { } image)
            {
                return;
            }
            PInvoke.GetCursorPos(out var cursor);
            var area = DisplayArea.GetFromPoint(
                new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary).WorkArea;
            var scale = Math.Min(1, Math.Min(area.Width * 0.8 / image.Width, area.Height * 0.8 / image.Height));
            var width = Math.Max(1, (int)(image.Width * scale));
            var height = Math.Max(1, (int)(image.Height * scale));
            var left = Math.Clamp(cursor.X - width / 2, area.X, area.X + area.Width - width);
            var top = Math.Clamp(cursor.Y - height / 2, area.Y, area.Y + area.Height - height);
            PinHost.Show(png, new PixelBounds(left, top, left + width, top + height));
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.pin-failed", ex);
            NoticeHost.Show("没能钉图", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private void OnListRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var row = (e.OriginalSource as FrameworkElement)?.DataContext as ClipRow;
        if (row is null)
        {
            return;
        }

        List.SelectedItem = row;
        var entry = row.Entry;
        var menu = BuildEntryMenu(entry);
        menu.ShowAt(List, new FlyoutShowOptions { Position = e.GetPosition(List) });
        e.Handled = true;
    }

    /// <summary>一条的全部操作（右键菜单和 Ctrl+K 操作面板共用这一份）。</summary>
    private MenuFlyout BuildEntryMenu(ClipEntry entry)
    {
        var menu = new MenuFlyout();
        AddItem(menu, "粘贴", () => Paste(plain: false));
        AddItem(menu, "粘贴为纯文本", () => Paste(plain: true));
        AddItem(menu, "复制", () => Copy(entry));
        AddItem(menu, entry.Favorite ? "取消收藏" : "收藏", () => FavoriteSelected());
        // 片段（第三版 §4）
        AddItem(menu, entry.Snippet ? "移出片段" : "存为片段", () => Store?.ToggleSnippet(entry.Id));
        AddItem(menu, "编辑片段…", () => _ = EditSnippetAsync(entry));
        AddItem(menu, "编辑备注…", () => _ = EditNoteAsync(entry));
        menu.Items.Add(GroupMenu(entry));
        AddItem(menu, "管理收藏夹…", () => _ = ManageGroupsAsync());
        if (entry.Kind == ClipKind.Text)
        {
            AddItem(menu, "翻译", () => TranslateEntry(entry));
        }

        if (entry.Kind == ClipKind.Image)
        {
            AddItem(menu, "钉到屏幕", () => _ = PinImageAsync(entry));
            if (!string.IsNullOrWhiteSpace(entry.OcrText))
            {
                AddItem(menu, "复制图中文字", () => CopyText(entry.OcrText!));
            }
        }

        if (entry.Kind == ClipKind.Files && entry.Files.FirstOrDefault() is { } first)
        {
            AddItem(menu, "在资源管理器中显示", () => RevealInExplorer(first));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        AddItem(menu, "删除", () => DeleteSelected());
        return menu;
    }

    /// <summary>「移到收藏夹 ›」：默认收藏 + 每个命名收藏夹。</summary>
    private MenuFlyoutSubItem GroupMenu(ClipEntry entry)
    {
        var submenu = new MenuFlyoutSubItem { Text = "移到收藏夹" };
        var none = new MenuFlyoutItem { Text = "默认收藏", IsEnabled = entry.GroupId is not null };
        none.Click += (_, _) => Store?.MoveToGroup(entry.Id, null);
        submenu.Items.Add(none);
        if (Store is { } store)
        {
            foreach (var group in store.Groups.OrderBy(item => item.Position))
            {
                var item = new MenuFlyoutItem
                {
                    Text = group.Name,
                    IsEnabled = entry.GroupId != group.Id,
                };
                var id = group.Id;
                item.Click += (_, _) => store.MoveToGroup(entry.Id, id);
                submenu.Items.Add(item);
            }
        }

        return submenu;
    }

    /// <summary>Ctrl+K：在选中行旁边弹出同一份操作（第三版 §4），可以打字过滤。</summary>
    private void ShowActionPanel()
    {
        if (SelectedEntry is not { } entry || List.ContainerFromItem(List.SelectedItem) is not FrameworkElement row)
        {
            return;
        }

        var panel = new StackPanel { Width = 260, Spacing = 4 };
        var filter = new TextBox
        {
            PlaceholderText = "过滤操作…",
            FontSize = 12,
            Padding = new Thickness(8, 4, 8, 4),
        };
        var list = new StackPanel { Spacing = 1 };
        panel.Children.Add(filter);
        panel.Children.Add(list);
        var flyout = new Flyout
        {
            Content = panel,
            Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
            FlyoutPresenterStyle = null,
        };

        var actions = EntryActionList(entry);
        void Populate()
        {
            list.Children.Clear();
            foreach (var (text, action) in actions.Where(item =>
                         item.Text.Contains(filter.Text, StringComparison.OrdinalIgnoreCase)))
            {
                var button = new Button
                {
                    Content = text,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Thickness(8, 4, 8, 4),
                    BorderThickness = new Thickness(0),
                    FontSize = 12,
                };
                button.Click += (_, _) =>
                {
                    flyout.Hide();
                    action();
                };
                list.Children.Add(button);
            }

            if (list.Children.Count == 0)
            {
                list.Children.Add(new TextBlock
                {
                    Text = "没有匹配的操作",
                    Foreground = Theme.SecondaryText(),
                    FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                    Margin = new Thickness(8, 4, 8, 4),
                });
            }
        }

        filter.TextChanged += (_, _) => Populate();
        filter.KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Escape)
            {
                args.Handled = true;
                flyout.Hide();
            }
            else if (args.Key == VirtualKey.Enter && list.Children.FirstOrDefault() is Button first)
            {
                args.Handled = true;
                first.Focus(FocusState.Programmatic);
            }
        };
        flyout.Opened += (_, _) =>
        {
            Populate();
            filter.Focus(FocusState.Programmatic);
        };
        flyout.ShowAt(row, new FlyoutShowOptions
        {
            Position = new Windows.Foundation.Point(8, Math.Min(row.ActualHeight, 24)),
        });
    }

    /// <summary>Ctrl+K 操作面板的条目（和右键菜单同名同顺序，收藏夹摊平）。</summary>
    private List<(string Text, Action Action)> EntryActionList(ClipEntry entry)
    {
        var actions = new List<(string, Action)>
        {
            ("粘贴", () => Paste(plain: false)),
            ("粘贴为纯文本", () => Paste(plain: true)),
            ("复制", () => Copy(entry)),
            (entry.Favorite ? "取消收藏" : "收藏", FavoriteSelected),
            (entry.Snippet ? "移出片段" : "存为片段", () => Store?.ToggleSnippet(entry.Id)),
            ("编辑片段…", () => _ = EditSnippetAsync(entry)),
            ("编辑备注…", () => _ = EditNoteAsync(entry)),
        };
        if (Store is { } store)
        {
            actions.Add(("移到收藏夹：默认收藏", () => store.MoveToGroup(entry.Id, null)));
            foreach (var group in store.Groups.OrderBy(item => item.Position))
            {
                var id = group.Id;
                actions.Add(("移到收藏夹：" + group.Name, () => store.MoveToGroup(entry.Id, id)));
            }
        }

        actions.Add(("管理收藏夹…", () => _ = ManageGroupsAsync()));
        if (entry.Kind == ClipKind.Text)
        {
            actions.Add(("翻译", () => TranslateEntry(entry)));
        }

        if (entry.Kind == ClipKind.Image)
        {
            actions.Add(("钉到屏幕", () => _ = PinImageAsync(entry)));
            if (!string.IsNullOrWhiteSpace(entry.OcrText))
            {
                actions.Add(("复制图中文字", () => CopyText(entry.OcrText!)));
            }
        }

        if (entry.Kind == ClipKind.Files && entry.Files.FirstOrDefault() is { } first)
        {
            actions.Add(("在资源管理器中显示", () => RevealInExplorer(first)));
        }

        actions.Add(("删除", DeleteSelected));
        return actions;
    }

    private async Task NewSnippetAsync()
    {
        var name = new TextBox { Header = "名称（存成备注，可空）", MaxLength = 100 };
        var body = new TextBox
        {
            Header = "内容（可以用 {date} {time} {datetime} {weekday} {uuid} {clipboard} {clipboard:N} {cursor}）",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
            MaxHeight = 260,
        };
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "新建片段",
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel { Spacing = 10, Children = { body, name } },
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary ||
            string.IsNullOrWhiteSpace(body.Text) ||
            ClipboardService.Instance?.Store is not { } store)
        {
            return;
        }

        store.AddSnippet(body.Text, name.Text);
        SetScope(ClipScope.Snippets);
        SearchBox.Focus(FocusState.Programmatic);
    }

    private async Task EditSnippetAsync(ClipEntry? target = null)
    {
        var entry = target ?? SelectedEntry;
        if (entry is null || entry.Kind != ClipKind.Text || ClipboardService.Instance?.Store is not { } store)
        {
            return;
        }

        var name = new TextBox { Header = "名称（存成备注，可空）", Text = entry.Note ?? string.Empty, MaxLength = 100 };
        var body = new TextBox
        {
            Header = "内容",
            Text = entry.Text ?? string.Empty,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
            MaxHeight = 260,
        };
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = entry.Snippet ? "编辑片段" : "新建片段",
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel { Spacing = 10, Children = { body, name } },
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(body.Text))
        {
            return;
        }

        store.SetNote(entry.Id, name.Text);
        store.UpdateText(entry.Id, body.Text);
        if (!entry.Snippet)
        {
            store.ToggleSnippet(entry.Id);
        }

        SetScope(ClipScope.Snippets);
    }

    private async Task EditNoteAsync(ClipEntry entry)
    {
        var box = new TextBox
        {
            Header = "备注（能搜到；取消收藏不清备注）",
            Text = entry.Note ?? string.Empty,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 80,
            MaxHeight = 200,
        };
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "备注",
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            Content = box,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            if (string.IsNullOrWhiteSpace(box.Text))
            {
                ClipboardService.Instance?.Store.SetNote(entry.Id, null);
            }
            else
            {
                ClipboardService.Instance?.Store.SetNote(entry.Id, box.Text);
            }
        }
    }

    private async Task ManageGroupsAsync()
    {
        if (ClipboardService.Instance?.Store is not { } store)
        {
            return;
        }

        var list = new StackPanel { Spacing = 6 };
        void Rebuild()
        {
            list.Children.Clear();
            foreach (var group in store.Groups.OrderBy(item => item.Position))
            {
                var name = new TextBox { Text = group.Name, MinWidth = 180 };
                var rename = new Button { Content = "改名" };
                rename.Click += (_, _) =>
                {
                    if (!store.RenameGroup(group.Id, name.Text))
                    {
                        NoticeHost.Show("名字不能用", "不能为空、不能重名、最多 24 字", NoticeTone.Warning);
                    }
                    else
                    {
                        Rebuild();
                    }
                };
                var up = new Button { Content = "↑" };
                up.Click += (_, _) =>
                {
                    store.MoveGroup(group.Id, -1);
                    Rebuild();
                };
                var down = new Button { Content = "↓" };
                down.Click += (_, _) =>
                {
                    store.MoveGroup(group.Id, 1);
                    Rebuild();
                };
                var delete = new Button { Content = "删除" };
                delete.Click += (_, _) =>
                {
                    store.DeleteGroup(group.Id);
                    RefreshGroups();
                    Refresh(animated: false);
                    Rebuild();
                };
                var rowPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                rowPanel.Children.Add(name);
                rowPanel.Children.Add(rename);
                rowPanel.Children.Add(up);
                rowPanel.Children.Add(down);
                rowPanel.Children.Add(delete);
                list.Children.Add(rowPanel);
            }

            if (store.Groups.Count == 0)
            {
                list.Children.Add(new TextBlock { Text = "还没有收藏夹。", Foreground = Theme.SecondaryText() });
            }
        }

        Rebuild();
        var create = new TextBox { PlaceholderText = "新收藏夹的名字（最多 24 字）", MinWidth = 200 };
        var add = new Button { Content = "新建" };
        add.Click += (_, _) =>
        {
            if (store.CreateGroup(create.Text) is null)
            {
                NoticeHost.Show("名字不能用", "不能为空、不能重名、最多 24 字", NoticeTone.Warning);
                return;
            }

            create.Text = string.Empty;
            RefreshGroups();
            Rebuild();
        };
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        footer.Children.Add(create);
        footer.Children.Add(add);
        var content = new StackPanel { Spacing = 10 };
        content.Children.Add(list);
        content.Children.Add(footer);
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "管理收藏夹",
            CloseButtonText = "完成",
            Content = new ScrollViewer { Content = content, MaxHeight = 360 },
            XamlRoot = XamlRoot,
        };
        await dialog.ShowAsync();
        RefreshGroups();
        Refresh(animated: false);
    }

    private static void AddItem(MenuFlyout menu, string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    private static void RevealInExplorer(string path)
    {
        try
        {
            var arguments = File.Exists(path) ? $"/select,\"{path}\"" : $"\"{path}\"";
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = arguments,
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.reveal-failed {ex.GetType().Name}");
        }
    }
}
