// 启动器面板：搜索框 + 单列结果（行高 48，最多同时看到 8 行）+ 底栏。
// 空查询是「常用」8 行；结果来源和顺序在 LauncherModel。焦点一直在搜索框，方向键转给列表。
// 第二版 §3.6：高度随内容（三行起、八行封顶）、选中高亮滑动、按住 Ctrl 150 ms 后前九行出数字键帽、
// 计算结果单独一种行（28 号等宽）、危险命令上膛时副标题用危险色。
using System.Numerics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.System;

namespace KittyTools;

public sealed partial class LauncherPanel : UserControl
{
    private static string _lastQuery = string.Empty;
    private static string? _lastTarget;
    private static long _lastClosedAt;

    private readonly List<LauncherItem> _items = new();
    private readonly Dictionary<string, BitmapImage> _icons = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _keyHintTimer;
    private LauncherMode _specialMode = LauncherMode.Normal;
    private readonly List<LauncherItem> _specialItems = new();
    private CancellationTokenSource? _specialCts;
    private string? _specialQuery;
    private bool _specialLoading;
    private bool _active;
    private bool _showKeyHints;
    private bool _executed;
    private bool _animateHighlight;
    private MotionCurve _highlightCurve = MotionCurve.Glide;
    private string _query = string.Empty;
    private bool _composing;
    private ScrollViewer? _listScroll;

    public LauncherPanel()
    {
        InitializeComponent();
        AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: true);
        AddHandler(UIElement.KeyUpEvent, new KeyEventHandler(OnKeyUp), handledEventsToo: true);
        SearchBox.TextCompositionStarted += (_, _) => _composing = true;
        SearchBox.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            OnSearchTextChanged(SearchBox, null!);
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
        if (AppCatalog.Instance is { } catalog)
        {
            catalog.Changed += OnCatalogChanged;
        }

        // 空闲两分钟后放掉缓存的图标位图，下次打开再按需解码。
        IdleReclaimer.Register(ReleaseCaches);
    }

    /// <summary>空闲回收：放掉暂时不用的图标位图。</summary>
    public void ReleaseCaches()
    {
        _icons.Clear();
        Log.Info("launcher.caches-released");
    }

    public event Action? CloseRequested;

    /// <summary>调试 / 从别处带查询打开（截图和手测用）。</summary>
    public void SetQuery(string query)
    {
        _query = query;
        SearchBox.Text = query;
        SearchBox.SelectionStart = query.Length;
        Refresh(keepSelection: false, animated: false);
        _heightDip = ContentHeightDip;
        SearchBox.Focus(FocusState.Programmatic);
    }

    private double _heightDip;

    public event Action? SettingsRequested;

    /// <summary>内容高度变了（DIP，是否带动画）：浮层窗口据此改高度、顶边不动。</summary>
    public event Action<double, bool>? HeightRequested;

    public double ContentHeightDip
    {
        get
        {
            var heights = _items
                .Select(item => item.Kind == LauncherKind.Calculation
                    ? PanelMetrics.LauncherCalculationRowHeight
                    : PanelMetrics.LauncherRowHeight)
                .ToList();
            return PanelMetrics.LauncherHeightFor(heights);
        }
    }

    public void OnShown()
    {
        _active = true;
        _executed = false;
        SetKeyHints(false);
        var restore = _lastClosedAt != 0 &&
                      Environment.TickCount64 - _lastClosedAt <= 60_000 &&
                      _lastQuery.Trim().Length > 0;
        _query = restore ? _lastQuery : string.Empty;
        SearchBox.Text = _query;
        Refresh(keepSelection: restore, animated: false);
        if (restore && _lastTarget is not null)
        {
            var index = _items.FindIndex(item => item.Target == _lastTarget);
            if (index >= 0)
            {
                _highlightCurve = MotionCurve.Snap;
                _animateHighlight = true;
                List.SelectedIndex = index;
                List.ScrollIntoView(List.SelectedItem);
            }
        }

        FocusSearch();
        AppCatalog.Instance?.RefreshIfStale();
    }

    public void FocusSearch()
    {
        if (!SearchBox.Focus(FocusState.Programmatic))
        {
            _ = FocusManager.TryFocusAsync(SearchBox, FocusState.Programmatic);
        }
    }

    public void OnHidden()
    {
        _active = false;
        if (!_executed)
        {
            _lastQuery = _query;
            _lastTarget = SelectedItem?.Target;
            _lastClosedAt = Environment.TickCount64;
        }
        else
        {
            _lastQuery = string.Empty;
            _lastTarget = null;
            _lastClosedAt = 0;
        }

        SearchBox.Text = string.Empty;
        _items.Clear();
        List.ItemsSource = null;
        Highlight.Visibility = Visibility.Collapsed;
        _keyHintTimer.Stop();
        _showKeyHints = false;
    }

    private void OnCatalogChanged()
    {
        if (_active)
        {
            Refresh(keepSelection: true);
        }
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        _query = SearchBox.Text;
        if (!CompositionRules.ShouldSearch(_composing, _query))
        {
            return;
        }

        Refresh(animated: false);
    }

    private void Refresh(bool keepSelection = false, bool animated = true)
    {
        if (LauncherModel.Instance is not { } model)
        {
            return;
        }

        // 空格开头 / open / find / kill / port：走异步的额外查找（第三版 §6）。
        var classified = LauncherCommands.Classify(_query);
        if (classified.Mode != LauncherMode.Normal)
        {
            _specialMode = classified.Mode;
            _items.Clear();
            _items.AddRange(_specialItems);
            RenderRows(model, keepSelection, animated);
            ScheduleSpecial(classified);
            return;
        }

        _specialMode = LauncherMode.Normal;
        _specialCts?.Cancel();
        _specialQuery = null;

        var previousTarget = keepSelection ? SelectedItem?.Target : null;
        _items.Clear();
        _items.AddRange(model.Results(_query));

        var rows = new List<LauncherRow>(_items.Count);
        for (var index = 0; index < _items.Count; index++)
        {
            var item = _items[index];
            rows.Add(LauncherRow.Create(
                item,
                model.SubtitleFor(item),
                index,
                _showKeyHints,
                IconFor(item),
                model.IsArmed(item)));
        }

        List.ItemsSource = rows;
        EmptyState.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (rows.Count == 0)
        {
            EmptyIcon.Glyph = _query.Trim().Length == 0 ? "\uE721" : "\uE946";
            EmptyText.Text = AppCatalog.Instance is { IsScanning: true, HasScanned: false }
                ? "正在扫描应用…"
                : _query.Trim().Length == 0
                    ? "输入以搜索应用、设置、命令…"
                    : "没有结果\n换个词试试";
        }

        if (rows.Count == 0)
        {
            List.SelectedIndex = -1;
            Highlight.Visibility = Visibility.Collapsed;
        }
        else
        {
            var index = previousTarget is null
                ? 0
                : Math.Max(0, _items.FindIndex(item => item.Target == previousTarget));
            if (List.SelectedIndex != index)
            {
                _animateHighlight = animated;
                _highlightCurve = MotionCurve.Snap;
                List.SelectedIndex = index;
            }
            else
            {
                DispatcherQueue.TryEnqueue(() => MoveHighlight(animated: false));
            }

            List.ScrollIntoView(rows[index]);
        }

        UpdateFooter();
        HeightRequested?.Invoke(ContentHeightDip, animated);
    }

    /// <summary>特殊模式的行和普通模式一样渲染（图标、键帽、选中）。</summary>
    private void RenderRows(LauncherModel model, bool keepSelection, bool animated)
    {
        var previousTarget = keepSelection ? SelectedItem?.Target : null;
        var rows = new List<LauncherRow>(_items.Count);
        for (var index = 0; index < _items.Count; index++)
        {
            var item = _items[index];
            rows.Add(LauncherRow.Create(
                item, model.SubtitleFor(item), index, _showKeyHints, IconFor(item), model.IsArmed(item)));
        }

        List.ItemsSource = rows;
        EmptyState.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (rows.Count == 0)
        {
            EmptyIcon.Glyph = "\uE721";
            EmptyText.Text = _specialLoading
                ? _specialMode switch
                {
                    LauncherMode.FileSearch => "正在找文件…",
                    LauncherMode.Kill => "正在列进程…",
                    _ => "正在列端口…",
                }
                : _specialMode switch
                {
                    LauncherMode.FileSearch => "没有找到文件\n会搜桌面、文档、下载、图片、视频、音乐和 OneDrive",
                    LauncherMode.Kill => "没有匹配的进程",
                    _ => "没有匹配的端口",
                };
            List.SelectedIndex = -1;
            Highlight.Visibility = Visibility.Collapsed;
        }
        else
        {
            var index = previousTarget is null
                ? 0
                : Math.Max(0, _items.FindIndex(item => item.Target == previousTarget));
            _animateHighlight = animated;
            _highlightCurve = MotionCurve.Snap;
            List.SelectedIndex = index;
            List.ScrollIntoView(rows[index]);
        }

        UpdateFooter();
        HeightRequested?.Invoke(ContentHeightDip, animated);
    }

    private void ScheduleSpecial((LauncherMode Mode, string Query) request)
    {
        _specialLoading = _specialItems.Count == 0;
        if (_specialQuery == request.Query && _specialCts is not null && !_specialCts.IsCancellationRequested)
        {
            return;
        }

        _specialQuery = request.Query;
        _specialCts?.Cancel();
        var cts = new CancellationTokenSource();
        _specialCts = cts;
        var query = request.Query;
        var mode = request.Mode;
        _ = Task.Run(async () =>
        {
            // 打字时别每个字都扫一遍磁盘。
            await Task.Delay(180, cts.Token);
            List<LauncherItem> items;
            try
            {
                items = mode switch
                {
                    LauncherMode.FileSearch => LauncherModel.FileItems(
                        query.Length == 0
                            ? FileSearch.Recent(20)
                            : await FileSearch.SearchAsync(query, cts.Token)),
                    LauncherMode.Kill => LauncherModel.ProcessItems(
                        await ProcessSearch.SearchAsync(query, cts.Token)),
                    _ => LauncherModel.PortItems(await PortSearch.SearchAsync(query, cts.Token)),
                };
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.special-failed {ex.GetType().Name}");
                items = new List<LauncherItem>();
            }

            DispatcherQueue.TryEnqueue(() =>
            {
                if (cts.IsCancellationRequested || _specialQuery != query || _specialMode != mode)
                {
                    return;
                }

                _specialItems.Clear();
                _specialItems.AddRange(items);
                _specialLoading = false;
                if (LauncherModel.Instance is { } model)
                {
                    _items.Clear();
                    _items.AddRange(_specialItems);
                    RenderRows(model, keepSelection: true, animated: false);
                }
            });
        });
    }

    private void UpdateFooter()
    {
        if (_specialMode != LauncherMode.Normal)
        {
            FooterText.Text = _specialMode switch
            {
                LauncherMode.FileSearch =>
                    "文件搜索 · Enter 打开 · Ctrl+Enter 在资源管理器里显示 · Ctrl+C 复制路径 · Esc 关闭",
                LauncherMode.Kill => "进程 · Enter 两次结束（第二次才真的结束）· Esc 关闭",
                _ => "端口 · Enter 复制 localhost:端口 · Esc 关闭",
            };
            return;
        }

        var catalog = AppCatalog.Instance;
        if (_items.Count == 0)
        {
            FooterText.Text = catalog is { IsScanning: true, HasScanned: false }
                ? "正在扫描应用…"
                : _query.Trim().Length == 0
                    ? "输入以搜索应用、设置、命令…"
                    : "没有结果";
            return;
        }

        var prefix = _query.Trim().Length == 0 ? "常用 · " : string.Empty;
        FooterText.Text =
            $"{prefix}{_items.Count} 项 · Enter 打开 · Ctrl+Enter 位置 / 复制 · Ctrl+Shift+Enter 管理员 · Tab 补全 · Esc 关闭";
    }

    private LauncherItem? SelectedItem => (List.SelectedItem as LauncherRow)?.Item;

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LauncherRow row)
        {
            _animateHighlight = true;
            _highlightCurve = MotionCurve.Glide;
            List.SelectedItem = row;
        }
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var animated = _animateHighlight;
        _animateHighlight = false;
        DispatcherQueue.TryEnqueue(() => MoveHighlight(animated));
    }

    /// <summary>只有一块中性高亮，换选中项时滑过去（PLAN-v2 §3.6）。</summary>
    private void MoveHighlight(bool animated)
    {
        var index = List.SelectedIndex;
        if (index < 0 || index >= _items.Count)
        {
            Highlight.Visibility = Visibility.Collapsed;
            return;
        }

        if (List.ContainerFromIndex(index) is not ListViewItem container)
        {
            Highlight.Visibility = Visibility.Collapsed;
            return;
        }

        var offset = container.TransformToVisual(List).TransformPoint(new Windows.Foundation.Point(0, 0));
        Highlight.Width = Math.Max(0, List.ActualWidth - 2);
        Highlight.Height = Math.Max(24, container.ActualHeight);
        Highlight.Visibility = Visibility.Visible;
        if (animated)
        {
            Motion.SlideTo(Highlight, 0, offset.Y, Motion.Reduced ? MotionCurve.Instant : _highlightCurve);
        }
        else
        {
            Highlight.Translation = new Vector3(0, (float)offset.Y, 0);
        }
    }

    private void SetKeyHints(bool show)
    {
        if (_showKeyHints == show)
        {
            return;
        }

        _showKeyHints = show;
        Refresh(keepSelection: true, animated: false);
    }

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

    private void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        e.Handled = true;
        Execute(control: false, shift: false);
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_active)
        {
            return;
        }

        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        if (e.Key == VirtualKey.Control)
        {
            // 按住 Ctrl 150 ms 才浮现键帽（PLAN-v2 §3.6）。
            if (!_showKeyHints)
            {
                _keyHintTimer.Stop();
                _keyHintTimer.Start();
            }

            return;
        }

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
            case VirtualKey.Down:
                e.Handled = true;
                if (control && IsDown(VirtualKey.Menu) && SelectedItem is { } downItem &&
                    LauncherModel.Instance is { } downModel)
                {
                    downModel.MoveFavorite(downItem, 1);
                    Refresh(keepSelection: true, animated: false);
                }
                else
                {
                    MoveSelection(1);
                }

                break;
            case VirtualKey.Up:
                e.Handled = true;
                if (control && IsDown(VirtualKey.Menu) && SelectedItem is { } upItem &&
                    LauncherModel.Instance is { } upModel)
                {
                    upModel.MoveFavorite(upItem, -1);
                    Refresh(keepSelection: true, animated: false);
                }
                else
                {
                    MoveSelection(-1);
                }

                break;
            case VirtualKey.Enter:
                e.Handled = true;
                Execute(control, shift);
                break;
            case VirtualKey.Tab:
                e.Handled = true;
                Complete();
                break;
            case VirtualKey.D when control:
                e.Handled = true;
                if (SelectedItem is { } favorite && LauncherModel.Instance is { } favoriteModel)
                {
                    var on = favoriteModel.ToggleFavorite(favorite);
                    NoticeHost.Show("启动器", on ? "已收藏" : "已取消收藏", NoticeTone.Normal);
                    Refresh(keepSelection: true, animated: false);
                }

                break;
            case VirtualKey.C when control:
                e.Handled = true;
                CopyTarget();
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number9 when control:
                e.Handled = true;
                var index = (int)e.Key - (int)VirtualKey.Number1;
                if (index < _items.Count)
                {
                    List.SelectedIndex = index;
                    Execute(control: false, shift: false);
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
        if (_items.Count == 0)
        {
            return;
        }

        var index = (List.SelectedIndex + delta + _items.Count) % _items.Count;
        _animateHighlight = true;
        _highlightCurve = MotionCurve.Snap;
        List.SelectedIndex = index;
        List.ScrollIntoView(List.SelectedItem);
    }

    private void Complete()
    {
        if (SelectedItem?.Completion is not { Length: > 0 } completion)
        {
            return;
        }

        SearchBox.Text = completion;
        SearchBox.SelectionStart = SearchBox.Text.Length;
    }

    private void CopyTarget()
    {
        var item = SelectedItem;
        if (item is null)
        {
            return;
        }

        var text = item.Kind switch
        {
            LauncherKind.Url or LauncherKind.Search or LauncherKind.Path => item.Target,
            LauncherKind.App when !item.Target.StartsWith(@"shell:AppsFolder\", StringComparison.Ordinal) =>
                item.Target,
            _ => null,
        };
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        if (ClipboardWriter.WriteText(text))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            ClipboardService.Instance?.Store.RecordOwnText(text);
            NoticeHost.Show("已复制", text, NoticeTone.Normal);
        }
    }

    private void Execute(bool control, bool shift)
    {
        var item = SelectedItem;
        if (item is null || LauncherModel.Instance is not { } model)
        {
            return;
        }

        if (!model.Execute(item, control, shift, OverlayHost.PasteTarget, out var error))
        {
            if (error is not null)
            {
                NoticeHost.Show("没能打开", error, NoticeTone.Warning);
            }
            else
            {
                Refresh(keepSelection: true);
            }

            return;
        }

        var keepsPanel = item.Kind == LauncherKind.Action &&
                         (item.Target == LauncherActions.Clipboard ||
                          item.Target == LauncherActions.Translate ||
                          item.Target.StartsWith("cb:", StringComparison.Ordinal) ||
                          item.Target.StartsWith("fy:", StringComparison.Ordinal));
        _executed = true;
        if (!keepsPanel)
        {
            CloseRequested?.Invoke();
        }
    }

    private void OnListRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var row = (e.OriginalSource as FrameworkElement)?.DataContext as LauncherRow;
        if (row is null)
        {
            return;
        }

        List.SelectedItem = row;
        var item = row.Item;
        var menu = new MenuFlyout();
        AddItem(menu, "打开", () => Execute(control: false, shift: false));
        if (item.Kind == LauncherKind.App)
        {
            if (!item.Target.StartsWith(@"shell:AppsFolder\", StringComparison.Ordinal))
            {
                AddItem(menu, "打开文件所在位置", () => Execute(control: true, shift: false));
            }

            AddItem(menu, "以管理员身份运行", () => Execute(control: true, shift: true));
        }

        if (item.Kind is LauncherKind.Url or LauncherKind.Path or LauncherKind.Search)
        {
            AddItem(menu, "复制路径 / 网址", CopyTarget);
        }

        if (item.Kind == LauncherKind.Calculation)
        {
            AddItem(menu, "复制结果", () => Execute(control: true, shift: false));
        }

        menu.ShowAt(List, new FlyoutShowOptions { Position = e.GetPosition(List) });
        e.Handled = true;
    }

    private static void AddItem(MenuFlyout menu, string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    private BitmapImage? IconFor(LauncherItem item)
    {
        if (item.IconData is not { Length: > 0 } bytes)
        {
            return null;
        }

        if (_icons.TryGetValue(item.Target, out var cached))
        {
            return cached;
        }

        var image = new BitmapImage { DecodePixelWidth = 32 };
        _icons[item.Target] = image;
        _ = LoadIconAsync(image, bytes);
        return image;
    }

    private static async Task LoadIconAsync(BitmapImage image, byte[] bytes)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            await image.SetSourceAsync(stream);
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.icon-failed {ex.GetType().Name}");
        }
    }
}
