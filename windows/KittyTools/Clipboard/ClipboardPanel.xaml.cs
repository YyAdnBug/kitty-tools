// 剪贴板面板（照 mac 的透镜指令条 Lens Bar）：搜索线 + 单列列表 + 底栏。焦点一直在搜索框，方向键、Ctrl 组合键都在这里处理。
// 列表是 ClipListView（Core 的前缀和摆放，只建可见区附近的行）；选中行原地展开成透镜，高亮就是透镜的底。
// 选择模型在这里：一个选中项 + 多选的勾选集（Ctrl 单击 / Shift 单击 / Shift+↑↓），操作对象 = 勾选项（按复制先后）或选中项。
// 删除先只从列表拿掉（Ctrl+Z 可撤），面板收起时才真的删库。
using System.Diagnostics;
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
    private readonly ClipListView _list = new();
    /// <summary>多选的勾选项（条目 id）；空 = 不在多选状态。</summary>
    private readonly HashSet<long> _checked = new();
    /// <summary>搜索线的输入框（PLAN-v7 §2.2 的共用部件）。</summary>
    private TextBox SearchBox => SearchLineControl.Box;
    /// <summary>当前选中行透镜里的内容（U1：原地展开，不再有右边那一栏）。</summary>
    private readonly StackPanel PreviewHost = new() { Spacing = 8 };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _keyHintTimer;
    private readonly TextBlock _titleMeasure = new() { FontSize = 14, TextWrapping = TextWrapping.NoWrap };
    private ClipScope _scope = ClipScope.All;
    private string? _groupFilterId;
    private int _selected = -1;
    /// <summary>Shift 单击 / Shift+↑↓ 整段选的起点。</summary>
    private long? _anchorId;
    private bool _active;
    private bool _showKeyHints;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _linkTimer;
    private CancellationTokenSource? _linkCts;
    private Uri? _linkPending;
    private bool _composing;
    private bool _shiftHeld;
    private bool _pinned;
    /// <summary>Ctrl+C 复制的那条和当时剪贴板的序号：收起面板时剪贴板还是它，就挪到最前。</summary>
    private (long Id, uint Sequence)? _copiedOnHide;
    /// <summary>底栏右边现在摆的是哪一套按钮：没变就不重建（按 ↓ 连发时每下都重建会拖慢）。</summary>
    private string _footerActions = string.Empty;

    /// <summary>R33 性能探针用：当前显示的面板。</summary>
    public static ClipboardPanel? Current { get; private set; }

    public ClipboardPanel()
    {
        InitializeComponent();
        SearchBox.PlaceholderText = "搜索剪贴板，Tab 筛选";
        SearchLineControl.ExtendHairline();
        SearchBox.TextChanged += OnSearchTextChanged;
        AddHandler(KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: true);
        AddHandler(KeyUpEvent, new KeyEventHandler(OnKeyUp), handledEventsToo: true);
        SearchBox.TextCompositionStarted += (_, _) => _composing = true;
        SearchBox.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            Refresh(animated: false);
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

        ListHost.Children.Insert(0, _list);
        _list.ItemTapped += OnItemTapped;
        _list.ItemDoubleTapped += index =>
        {
            Select(index, MotionCurve.Instant);
            Paste(plain: false);
        };
        _list.ItemRightTapped += OnItemRightTapped;
        _list.ItemDragStarting += OnItemDragStarting;
        _list.NewSnippetTapped += () => _ = NewSnippetAsync();
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

    /// <summary>按当前条数算出来的面板高度（照 mac：透镜预留是常数，↑↓ 不改窗口高度；最多 520 DIP）。</summary>
    public double ContentHeightDip
        => PanelMetrics.ClipboardHeightFor(
            _visible.Count + (ShowsNewSnippetRow ? 1 : 0), _list.Layout.SectionTops.Count, reservesLens: LensEnabled);

    /// <summary>设置 › 剪贴板「显示透镜」（6g 接上设置；关掉 = 纯列表）。</summary>
    private static bool LensEnabled => true;

    /// <summary>片段范围、没有搜索词时第一行固定一条「＋ 新建片段 Ctrl+N」（mac）。</summary>
    private bool ShowsNewSnippetRow => _scope == ClipScope.Snippets && SearchBox.Text.Trim().Length == 0;

    private static ClipboardStore? Store => ClipboardService.Instance?.Store;

    public void OnShown()
    {
        Current = this;
        _active = true;
        _shiftHeld = false;
        _pinned = false;
        // 外观可能在收起期间换过：底栏按钮按新颜色重建一次。
        _footerActions = string.Empty;
        Footer.HideNotice();
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
        Current = null;
        _active = false;
        _keyHintTimer.Stop();
        _showKeyHints = false;
        _shiftHeld = false;
        Footer.HideNotice();
        SearchBox.Text = string.Empty;
        _visible.Clear();
        _checked.Clear();
        _anchorId = null;
        _selected = -1;
        PreviewHost.Children.Clear();
        _list.SetItems(_visible, Array.Empty<long>(), false, RowContext(), null, -1, null, 0);
        if (Store is { } store)
        {
            store.CommitDeletion();
            if (_copiedOnHide is { } copied && copied.Sequence == PInvoke.GetClipboardSequenceNumber())
            {
                store.Bump(copied.Id);
            }

            store.EnforceLimits();
        }

        _copiedOnHide = null;
    }

    /// <summary>R33：5000 条时在第 4000 条附近按 ↓ 从选中到布局更新的耗时；返回中位数 / 最慢 5%。</summary>
    public (double Median, double P95, int Count) MeasureSelection(int steps)
    {
        var times = new List<double>(Math.Max(1, steps));
        // PLAN-v7 第 2 批的口径：在第 4000 条附近按 ↓（每一下都是从选中到布局更新完）。
        Select(Math.Min(3990, Math.Max(0, _visible.Count - steps - 1)), MotionCurve.Instant);
        UpdateLayout();
        for (var step = 0; step < steps && _visible.Count > 1; step++)
        {
            var watch = Stopwatch.StartNew();
            MoveSelection(1, extending: false, repeat: false);
            UpdateLayout();
            times.Add(watch.Elapsed.TotalMilliseconds);
        }

        if (times.Count == 0)
        {
            return (0, 0, 0);
        }

        times.Sort();
        var median = times[times.Count / 2];
        var p95 = times[Math.Min(times.Count - 1, (int)(times.Count * 0.95))];
        return (median, p95, times.Count);
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

        // 勾选裁成看得见的；一条不剩就退出多选（mac 体检 B8）。
        var visibleIds = _visible.Select(entry => entry.Id).ToHashSet();
        _checked.IntersectWith(visibleIds);
        if (_anchorId is { } anchor && !visibleIds.Contains(anchor))
        {
            _anchorId = null;
        }

        var index = previous is { } id ? _visible.FindIndex(entry => entry.Id == id) : 0;
        _selected = _visible.Count == 0 ? -1 : Math.Max(0, index);
        var (lens, lensHeight) = BuildLens();
        _list.SetItems(
            _visible, _visible.Select(entry => ClipRowView.DayKey(entry.CopiedAt)).ToList(), ShowsNewSnippetRow, RowContext(),
            CheckedOrNull(), _selected, lens, lensHeight);
        if (_selected >= 0)
        {
            _list.Reveal(_selected);
        }
        else
        {
            _list.ScrollToTop();
        }

        ScheduleLinkPreview();
        UpdateFooter();
        UpdateEmptyState();
        HeightRequested?.Invoke(ContentHeightDip, animated);
    }

    /// <summary>换选中项（↑↓、点选、撤销回来）：只挪高亮和透镜，不重建列表。</summary>
    private void Select(int index, MotionCurve curve)
    {
        if (index < 0 || index >= _visible.Count)
        {
            return;
        }

        _selected = index;
        var (lens, lensHeight) = BuildLens();
        _list.SetSelection(index, lens, lensHeight, Motion.Reduced ? MotionCurve.Instant : curve);
        _list.Reveal(index);
        Footer.HideNotice();
        ScheduleLinkPreview();
        UpdateFooter();
    }

    private ClipRowContext RowContext() => new(
        SearchBox.Text.Trim(),
        ShowsGroupPill: _groupFilterId is null,
        ShowsKeyHints: _showKeyHints,
        Multi: _checked.Count > 0,
        Scale: XamlRoot?.RasterizationScale ?? 1.0);

    private IReadOnlySet<long>? CheckedOrNull() => _checked.Count > 0 ? new HashSet<long>(_checked) : null;

    /// <summary>勾选变了：行上的勾选圈跟着换，透镜在多选时收起。</summary>
    private void CheckedChanged(MotionCurve curve)
    {
        _list.SetChecked(CheckedOrNull());
        Select(_selected, curve);
    }

    /// <summary>单击 / Ctrl 单击 / Shift 单击（mac ClipboardPanelModel.click）。</summary>
    private void OnItemTapped(int index, VirtualKeyModifiers modifiers)
    {
        if (index < 0 || index >= _visible.Count)
        {
            return;
        }

        var entry = _visible[index];
        if (modifiers.HasFlag(VirtualKeyModifiers.Control))
        {
            if (_checked.Count == 0 && SelectedEntry is { } current)
            {
                _checked.Add(current.Id);
            }

            if (!_checked.Remove(entry.Id))
            {
                _checked.Add(entry.Id);
            }

            _anchorId = entry.Id;
        }
        else if (modifiers.HasFlag(VirtualKeyModifiers.Shift))
        {
            var anchor = _anchorId ?? SelectedEntry?.Id;
            var from = _visible.FindIndex(item => item.Id == anchor);
            if (from < 0)
            {
                return;
            }

            _checked.Clear();
            for (var at = Math.Min(from, index); at <= Math.Max(from, index); at++)
            {
                _checked.Add(_visible[at].Id);
            }
        }
        else
        {
            _checked.Clear();
            _anchorId = entry.Id;
        }

        _list.SetChecked(CheckedOrNull());
        Select(index, MotionCurve.Glide);
        FocusSearch();
    }

    /// <summary>
    /// PLAN-v7 §3.1 底栏：左边「N 条」（暂停记录时带「⏸ 已暂停记录 ·」，按住 Shift 换成纯文本粘贴的说明），
    /// 右边「粘贴 ↩ · 操作 Ctrl+K ｜ 齿轮 图钉」；多选时左边「已选 N 条」，右边 合并粘贴 / 收藏 / 删除 / 取消。
    /// </summary>
    private void UpdateFooter()
    {
        var selected = SelectedEntries;
        if (selected.Count > 1)
        {
            var mode = MultiPaste.Mode(
                selected.Count,
                selected.All(entry => entry.Kind == ClipKind.Text),
                selected.All(entry => entry.Kind == ClipKind.Files));
            Footer.Status = PanelFooterText.ClipSelected(selected.Count);
            SetFooterActions($"multi:{mode}", () =>
            {
                Footer.AddVerb(MultiPaste.ShortVerb(mode), "↩", primary: true, () => Paste(plain: false));
                Footer.AddVerb("收藏", "Ctrl+D", primary: false, FavoriteSelected);
                Footer.AddVerb("删除", "Del", primary: false, DeleteSelected, danger: true);
                Footer.AddVerb("取消", "Esc", primary: false, CancelMultiSelect);
            });
            return;
        }

        var paused = ClipboardService.Instance?.Paused == true;
        Footer.Status = _shiftHeld && _visible.Count > 0
            ? PanelFooterText.ShiftHint
            : _visible.Count > 0 || paused
                ? PanelFooterText.ClipStatus(_visible.Count, paused)
                : string.Empty;
        var hasItems = _visible.Count > 0;
        SetFooterActions($"single:{hasItems}:{_pinned}", () =>
        {
            if (hasItems)
            {
                Footer.AddVerb("粘贴", "↩", primary: true, () => Paste(plain: false));
                Footer.AddVerb("操作", "Ctrl+K", primary: false, ShowActionPanel);
                Footer.AddSeparator();
            }

            Footer.AddIconButton(Glyphs.Settings, "打开剪贴板设置", "设置", () => SettingsRequested?.Invoke());
            Footer.AddIconButton(
                _pinned ? Glyphs.Unpin : Glyphs.Pin,
                _pinned ? "取消固定剪贴板面板" : "固定剪贴板面板",
                _pinned ? "取消固定（Ctrl+P）" : "固定面板（Ctrl+P）",
                () => PinRequested?.Invoke());
        });
    }

    private void SetFooterActions(string key, Action build)
    {
        if (key == _footerActions)
        {
            return;
        }

        _footerActions = key;
        Footer.ClearActions();
        build();
    }

    /// <summary>浮层固定 / 取消固定之后（Ctrl+P、底栏图钉）：图钉换样子，左边就地提示一下。</summary>
    public void SetPinned(bool pinned)
    {
        _pinned = pinned;
        UpdateFooter();
        Footer.ShowNotice(pinned ? "已固定 · Esc 仍然可以收起" : "已取消固定");
        // 点底栏图钉时焦点在按钮上（按钮也刚被重建掉）：还给搜索框。
        FocusSearch();
    }

    /// <summary>--ui-snapshots：勾选前 count 行，出多选底栏的图。</summary>
    internal void SelectFirstForProbe(int count)
    {
        if (_visible.Count == 0)
        {
            return;
        }

        _checked.Clear();
        foreach (var entry in _visible.Take(count))
        {
            _checked.Add(entry.Id);
        }

        CheckedChanged(MotionCurve.Instant);
    }

    /// <summary>--ui-snapshots 的几种状态（只在自检档里用）。</summary>
    internal void ApplyProbeState(string name)
    {
        switch (name)
        {
            case "clip-multi":
                SelectFirstForProbe(3);
                break;
            case "clip-search":
                SearchBox.Text = "release";
                Refresh(animated: false);
                break;
            case "clip-snippets":
                SetScope(ClipScope.Snippets);
                break;
            case "clip-favorites":
                SetScope(ClipScope.Favorites);
                break;
            case "clip-scrolled":
                Select(3, MotionCurve.Instant);
                _list.ScrollTo(150);
                break;
        }
    }

    /// <summary>多选时的「取消」/ Esc：退出多选，选中项不变。</summary>
    private void CancelMultiSelect()
    {
        if (_checked.Count == 0)
        {
            return;
        }

        _checked.Clear();
        CheckedChanged(MotionCurve.Instant);
    }

    /// <summary>操作对象（mac targets）：勾选项里看得见的、按复制先后；没有勾选时是选中项。</summary>
    private List<ClipEntry> SelectedEntries => _checked.Count > 0
        ? _visible.Where(entry => _checked.Contains(entry.Id)).OrderBy(entry => entry.CopiedAt).ThenBy(entry => entry.Id).ToList()
        : SelectedEntry is { } entry ? new List<ClipEntry> { entry } : new List<ClipEntry>();

    /// <summary>
    /// 拖出去（第三版 §5）：文本带格式、文件给原文件、图片给一份临时副本；拖不算粘贴，不挪顺序也不记历史。
    /// 一律请求「复制」（REVIEW R64 C）：资源管理器在同一个盘上默认是「移动」，以前会把 images 里的原图挪走、把用户的原文件搬走。
    /// </summary>
    private void OnItemDragStarting(int index, DragStartingEventArgs e)
    {
        // 拖的是勾选项之一就拖全部勾选项，否则只拖这一条（mac dragItems）。
        var entries = index >= 0 && index < _visible.Count && !_checked.Contains(_visible[index].Id)
            ? new List<ClipEntry> { _visible[index] }
            : SelectedEntries;
        if (entries.Count == 0)
        {
            return;
        }

        try
        {
            e.Data.Properties.Title = "Kitty Tools";
            e.Data.RequestedOperation = DataPackageOperation.Copy;
            e.AllowedOperations = DataPackageOperation.Copy;
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
                        .Select(entry => DragCopy(store.Images.PathFor(entry.Id), entry))
                        .OfType<string>()
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

    /// <summary>
    /// 图片拖出去用的临时副本：%TEMP%\KittyTools-drag\Kitty Tools 图片 时间.png。拖的是副本，被「移动」走了也不碍事；
    /// 每次拖之前顺手删掉一天前的。原图不在了返回 null。
    /// </summary>
    private static string? DragCopy(string source, ClipEntry entry)
    {
        if (!File.Exists(source))
        {
            return null;
        }

        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "KittyTools-drag");
            Directory.CreateDirectory(folder);
            foreach (var old in Directory.EnumerateFiles(folder, "*.png"))
            {
                if (File.GetLastWriteTimeUtc(old) < DateTime.UtcNow.AddDays(-1))
                {
                    File.Delete(old);
                }
            }

            var stamp = DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt).ToLocalTime();
            var path = Path.Combine(folder, $"Kitty Tools 图片 {stamp:yyyy-MM-dd HH.mm.ss}-{entry.Id}.png");
            File.Copy(source, path, overwrite: true);
            return path;
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.drag-copy-failed {ex.GetType().Name}");
            return null;
        }
    }

    private void UpdateEmptyState()
    {
        var empty = _visible.Count == 0 && !ShowsNewSnippetRow;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (!empty)
        {
            return;
        }

        // 搜索 / 筛选没结果：「没有匹配的条目 · 清除搜索和筛选」（后半句能点，mac）。
        var filtered = SearchBox.Text.Trim().Length > 0 || _scope != ClipScope.All || _groupFilterId is not null;
        EmptyText.Text = filtered ? "没有匹配的条目 ·" : "还没有剪贴板历史，复制点什么就会出现";
        EmptyClear.Visibility = filtered ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnEmptyClearClick(object sender, RoutedEventArgs e)
    {
        SearchBox.Text = string.Empty;
        _groupFilterId = null;
        SetScope(ClipScope.All);
        FocusSearch();
    }

    /// <summary>按住 Ctrl 150 ms 后前九行右边浮现数字键帽（PLAN-v2 §3.5）。</summary>
    private void SetKeyHints(bool show)
    {
        if (_showKeyHints == show)
        {
            return;
        }

        _showKeyHints = show;
        _list.SetKeyHints(show);
    }

    private ClipEntry? SelectedEntry => _selected >= 0 && _selected < _visible.Count ? _visible[_selected] : null;

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

    private void SetScope(ClipScope scope, bool refresh = true)
    {
        _scope = scope;
        RefreshGroups();
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
            // 「全部」不出标签（mac）。
            return;
        }

        SearchLineControl.AddChip(text, () =>
        {
            _groupFilterId = null;
            SetScope(ClipScope.All);
        });
    }

    /// <summary>收藏夹筛选只在「收藏」范围里有；收藏夹被删了就清掉这个筛选。</summary>
    private void RefreshGroups()
    {
        if (_scope != ClipScope.Favorites ||
            (_groupFilterId is { } id && Store?.Groups.Any(group => group.Id == id) != true))
        {
            _groupFilterId = null;
        }

        UpdateFilterChips();
    }

    /// <summary>
    /// 选中项的透镜：正文区（按类型查表定高，可能是 0）+ 元信息行 22 + 底 8（同 mac LensView）；多选、没有选中、关了透镜时没有。
    /// 返回透镜（不含行头）和它的总高（含行头 40）。
    /// </summary>
    private (FrameworkElement? Lens, double Height) BuildLens()
    {
        if (_lensScroll is not null)
        {
            _lensScroll.Content = null;
            _lensScroll = null;
        }

        PreviewHost.Children.Clear();
        if (SelectedEntry is not { } entry || _checked.Count > 0 || !LensEnabled)
        {
            return (null, ClipListLayout.RowHeight);
        }

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

        var body = LensBodyHeight(entry);
        _lensScroll = new ScrollViewer
        {
            Content = PreviewHost,
            Height = body,
            // 不露滚动条（0.1.0 用户反馈）；长内容照样能用滚轮滚，底下的渐隐提示还有。
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            // 左边和行标题对齐（同 mac LensView 的 x = 44）。
            Padding = new Thickness(ClipLens.RowPadding + 24 + ClipLens.RowSpacing, 0, ClipLens.RowPadding, 0),
            IsTabStop = false,
        };
        var host = new Grid { Height = body + ClipLens.Meta + ClipLens.Bottom };
        host.RowDefinitions.Add(new RowDefinition { Height = new GridLength(body) });
        host.RowDefinitions.Add(new RowDefinition { Height = new GridLength(ClipLens.Meta) });
        host.Children.Add(_lensScroll);
        var meta = new TextBlock
        {
            Text = LensMeta(entry),
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(ClipLens.RowPadding + 24 + ClipLens.RowSpacing, 0, ClipLens.RowPadding, 0),
        };
        Grid.SetRow(meta, 1);
        host.Children.Add(meta);
        if (body > 0)
        {
            // 正文底部 12 的渐隐：颜色取透镜底下那一层（面板底 + 选中高亮）。
            var fade = Theme.CardColor();
            host.Children.Add(new Border
            {
                Height = 12,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, body - 12, 0, 0),
                IsHitTestVisible = false,
                Background = new LinearGradientBrush
                {
                    StartPoint = new Windows.Foundation.Point(0, 0),
                    EndPoint = new Windows.Foundation.Point(0, 1),
                    GradientStops =
                    {
                        new GradientStop { Color = Theme.Argb(0, fade.R, fade.G, fade.B), Offset = 0 },
                        new GradientStop { Color = Theme.Argb(160, fade.R, fade.G, fade.B), Offset = 1 },
                    },
                },
            });
        }

        return (host, ClipLens.Head + body + ClipLens.Meta + ClipLens.Bottom);
    }

    private ScrollViewer? _lensScroll;

    /// <summary>正文区高度（Core 的 ClipLens 查表）；文本的 0 档先量标题在最窄的标题列里放不放得下。</summary>
    private double LensBodyHeight(ClipEntry entry)
    {
        var form = entry.Kind == ClipKind.Text ? ContentForms.Detect(entry.Text) : null;
        var whole = entry.Kind == ClipKind.Text && form is null &&
                    ClipLens.ShowsWholeText(entry.Text, entry.Rich, entry.Snippet, entry.Favorite, MeasureTitle);
        return ClipLens.BodyHeight(entry.Kind, form, entry.Text, whole);
    }

    /// <summary>行标题 14 号的宽度（DirectWrite 排一次）。</summary>
    private double MeasureTitle(string title)
    {
        _titleMeasure.Text = title;
        _titleMeasure.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return _titleMeasure.DesiredSize.Width;
    }

    /// <summary>「文本 · 70 字 · 14:02 · 记事本」（同 mac LensView.metaText）。</summary>
    private static string LensMeta(ClipEntry entry)
    {
        var text = entry.Text ?? string.Empty;
        var (type, detail) = entry.Kind switch
        {
            ClipKind.Image => ("图片", entry.Width > 0 ? $"{entry.Width}×{entry.Height}" : null),
            ClipKind.Files => ("文件", $"{entry.Files.Length} 个"),
            _ when PreviewRules.TryParseColor(text, out _, out _, out _) => ("颜色", (string?)null),
            _ when LinkPreviewRules.SingleUrl(text) is not null => ("链接", null),
            _ when PreviewRules.LooksLikeCode(text) => ("代码", $"{text.Length} 字"),
            _ => ("文本", $"{text.Length} 字"),
        };
        var copied = DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt).ToLocalTime();
        var now = DateTimeOffset.Now;
        var time = copied.Date == now.Date ? copied.ToString("HH:mm")
            : copied.Year == now.Year ? copied.ToString("M月d日 HH:mm")
            : copied.ToString("yyyy年M月d日 HH:mm");
        return string.Join(" · ", new[] { type, detail, time, entry.SourceName }.Where(part => !string.IsNullOrEmpty(part)));
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

        if (LensBodyHeight(entry) == 0)
        {
            return;
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
        var width = _list.ActualWidth > 0 ? Math.Max(240, _list.ActualWidth - 64) : 520;
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
        // REVIEW R64 E：输入法组字时的 Enter / Esc / ↑↓ 是给输入法的（上屏、取消、选词），别当成粘贴、收起、换行。
        // 0xE5 = VK_PROCESSKEY：按键先交给了输入法。
        if (!_active || _composing || e.Key == (VirtualKey)0xE5)
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

        if (e.Key == VirtualKey.Shift)
        {
            // 按住 Shift：底栏左边换成「Shift+Enter 粘贴为纯文本」（PLAN-v7 §3.1）。
            if (!_shiftHeld)
            {
                _shiftHeld = true;
                UpdateFooter();
            }

            return;
        }

        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                // mac 的顺序：先清搜索词，再取消多选，最后收起。
                if (SearchBox.Text.Length > 0)
                {
                    SearchBox.Text = string.Empty;
                }
                else if (_checked.Count > 0)
                {
                    CancelMultiSelect();
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
                MoveSelection(1, shift, e.KeyStatus.WasKeyDown);
                break;
            case VirtualKey.Up:
                e.Handled = true;
                MoveSelection(-1, shift, e.KeyStatus.WasKeyDown);
                break;
            case VirtualKey.A when control && SearchBox.Text.Length == 0:
                // 搜索框空着时 Ctrl+A 全选（mac）。
                e.Handled = true;
                if (_visible.Count > 1)
                {
                    _checked.Clear();
                    _checked.UnionWith(_visible.Select(entry => entry.Id));
                    CheckedChanged(MotionCurve.Instant);
                }

                break;
            case VirtualKey.Enter when !control:
                e.Handled = true;
                Paste(shift);
                break;
            case VirtualKey.Tab when shift:
                // 范围在 全部 → 收藏 → 片段 之间循环（mac cycleScope）。
                e.Handled = true;
                _groupFilterId = null;
                SetScope(_scope switch
                {
                    ClipScope.All => ClipScope.Favorites,
                    ClipScope.Favorites => ClipScope.Snippets,
                    _ => ClipScope.All,
                });
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
                    _checked.Clear();
                    _list.SetChecked(null);
                    Select(number, MotionCurve.Instant);
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
        else if (e.Key == VirtualKey.Shift && _shiftHeld)
        {
            _shiftHeld = false;
            UpdateFooter();
        }
    }

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    /// <summary>
    /// ↑↓ 移动（到头绕回，mac）/ Shift+↑↓ 从锚点整段选（到头停住）；按住连发时不动画。
    /// </summary>
    private void MoveSelection(int delta, bool extending, bool repeat)
    {
        if (_visible.Count == 0)
        {
            return;
        }

        var current = Math.Max(0, _selected);
        var count = _visible.Count;
        var next = extending ? Math.Clamp(current + delta, 0, count - 1) : (current + delta + count) % count;
        if (extending)
        {
            if (_anchorId is null || _checked.Count == 0)
            {
                _anchorId = _visible[current].Id;
            }

            var anchor = Math.Max(0, _visible.FindIndex(entry => entry.Id == _anchorId));
            _checked.Clear();
            for (var at = Math.Min(anchor, next); at <= Math.Max(anchor, next); at++)
            {
                _checked.Add(_visible[at].Id);
            }

            _list.SetChecked(CheckedOrNull());
        }
        else if (_checked.Count > 0)
        {
            _checked.Clear();
            _list.SetChecked(null);
        }

        Select(next, repeat ? MotionCurve.Instant : MotionCurve.Snap);
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
                    // REVIEW R60：Paster 失败时自己会弹具体原因（没能切回原窗口 / 管理员窗口 / 剪贴板被占），
                    // 不能再无条件盖一句「已一起粘贴」。
                    if (Paster.Paste(
                            target,
                            () => ClipboardWriter.WriteEntry(combined, null, null, plainText: false, null),
                            ClipboardService.Instance))
                    {
                        NoticeHost.Show("已一起粘贴", $"{combined.Files.Length} 个文件", NoticeTone.Normal);
                    }

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
                            // REVIEW R60：失败就停在这一条，别再用「已依次粘贴 N 条」把刚报的错盖掉。
                            NoticeHost.Show("没能粘贴", "第 " + (index + 1) + " 条失败", NoticeTone.Error);
                            return;
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
            // 面板开着：成功的提示进底栏（PLAN-v7 §3.1），出错的才走轻提示。
            Footer.ShowNotice("已复制");
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
            // 面板里不动，收起时再挪到最前（剪贴板没被换掉才挪，mac 体检 A8）。
            _copiedOnHide = (entry.Id, PInvoke.GetClipboardSequenceNumber());
            Footer.ShowNotice("已复制");
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.copy-failed", ex);
            NoticeHost.Show("没能复制", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private void DeleteSelected()
    {
        var entries = SelectedEntries;
        if (entries.Count == 0 || Store is not { } store)
        {
            return;
        }

        store.DeleteWithUndo(entries.Select(entry => entry.Id).ToList());
        Refresh();
        // 「已删除 N 条 · 撤销 Ctrl+Z」：撤销是 AccentText 的文字按钮，收起面板前都能撤（Refresh 之后再挂，免得被刷新顶掉）。
        Footer.ShowNotice(
            entries.Count > 1 ? $"已删除 {entries.Count} 条 ·" : "已删除 ·",
            "撤销 Ctrl+Z",
            UndoDelete,
            success: false);
    }

    private void UndoDelete()
    {
        if (Store is not { } store)
        {
            return;
        }

        switch (store.Undo())
        {
            case { Kind: ClipUndoKind.Deleted, Entries: { Count: > 0 } restored }:
                // 删掉的回来后选中这批里最靠前的（mac）。
                Refresh(FirstInList(restored));
                Footer.ShowNotice(restored.Count > 1 ? $"已恢复 {restored.Count} 条" : "已恢复");
                break;
            case { Kind: ClipUndoKind.Group } group:
                RefreshGroups();
                Refresh(animated: false);
                Footer.ShowNotice($"已恢复收藏夹「{group.GroupName}」");
                break;
            case { Kind: ClipUndoKind.Unretained } unretained:
                Refresh(animated: false);
                Footer.ShowNotice($"已撤销，{unretained.Entries.Count} 条不会被清理");
                break;
        }
    }

    /// <summary>撤销回来的那批里排在列表最前的一条。</summary>
    private static long FirstInList(IReadOnlyList<ClipEntry> restored)
        => restored.OrderByDescending(entry => entry.CopiedAt).ThenByDescending(entry => entry.Id).First().Id;

    private void FavoriteSelected()
    {
        var entries = SelectedEntries;
        if (entries.Count == 0 || Store is not { } store)
        {
            return;
        }

        // 批量：只要有一条不是收藏就全部收藏；全是收藏就全部取消（同时移出收藏夹，片段和备注不动）。
        var target = entries.Any(entry => !entry.Favorite);
        var expired = store.ToggleFavorite(entries.Select(entry => entry.Id).ToList());
        Refresh(entries[0].Id);
        if (!ShowExpiredNotice(expired))
        {
            Footer.ShowNotice(target ? "已加入收藏" : "已取消收藏");
        }
    }

    /// <summary>
    /// 取消收藏 / 移出片段后已经超过保留天数的：底栏「超过 N 天，收起面板后会被清理 · 撤销 Ctrl+Z」（mac changeRetention）。
    /// </summary>
    private bool ShowExpiredNotice(int expired)
    {
        if (expired <= 0)
        {
            return false;
        }

        var days = SettingsService.Current.ClipboardRetentionDays;
        Footer.ShowNotice($"超过 {days} 天，收起面板后会被清理 ·", "撤销 Ctrl+Z", UndoDelete, success: false);
        return true;
    }

    private void ToggleSnippet(ClipEntry entry)
    {
        if (Store is not { } store)
        {
            return;
        }

        var removing = entry.Snippet;
        var expired = store.ToggleSnippet(entry.Id);
        if (!ShowExpiredNotice(expired))
        {
            Footer.ShowNotice(removing ? "已移出片段" : "已存为片段");
        }
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

    private void OnItemRightTapped(int index, FrameworkElement row, Windows.Foundation.Point position)
    {
        if (index < 0 || index >= _visible.Count)
        {
            return;
        }

        if (!_checked.Contains(_visible[index].Id))
        {
            _checked.Clear();
            _list.SetChecked(null);
            Select(index, MotionCurve.Glide);
        }

        BuildEntryMenu(_visible[index]).ShowAt(row, new FlyoutShowOptions { Position = position });
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
        AddItem(menu, entry.Snippet ? "移出片段" : "存为片段", () => ToggleSnippet(entry));
        if (entry.Kind == ClipKind.Text)
        {
            AddItem(menu, "编辑内容…", () => _ = EditSnippetAsync(entry));
        }

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
        if (SelectedEntry is not { } entry || _list.RowElement(_selected) is not { } row)
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
        Action? firstMatch = null;
        var composing = false;
        void Populate()
        {
            list.Children.Clear();
            firstMatch = null;
            foreach (var (text, action) in actions.Where(item =>
                         item.Text.Contains(filter.Text, StringComparison.OrdinalIgnoreCase)))
            {
                firstMatch ??= action;
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
        filter.TextCompositionStarted += (_, _) => composing = true;
        filter.TextCompositionEnded += (_, _) => composing = false;
        filter.KeyDown += (_, args) =>
        {
            if (composing)
            {
                return;
            }

            if (args.Key == VirtualKey.Escape)
            {
                args.Handled = true;
                flyout.Hide();
            }
            else if (args.Key == VirtualKey.Enter && firstMatch is { } run)
            {
                // REVIEW R41：Enter 直接执行第一个匹配的操作（mac 同样），不只是把焦点挪过去。
                args.Handled = true;
                flyout.Hide();
                run();
            }
        };
        flyout.Opened += (_, _) =>
        {
            Populate();
            filter.Focus(FocusState.Programmatic);
        };
        // 关掉后焦点还给搜索框（从底栏「操作」点开时焦点在按钮上）；执行的动作收起了面板就不管。
        flyout.Closed += (_, _) =>
        {
            if (_active)
            {
                FocusSearch();
            }
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
            (entry.Snippet ? "移出片段" : "存为片段", () => ToggleSnippet(entry)),
            ("编辑备注…", () => _ = EditNoteAsync(entry)),
        };
        if (entry.Kind == ClipKind.Text)
        {
            actions.Insert(actions.Count - 1, ("编辑内容…", () => _ = EditSnippetAsync(entry)));
        }
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

        // 「编辑内容…」只改正文，不改类型、不换范围（mac）；只有片段才有名称框。
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
            Title = entry.Snippet ? "编辑片段" : "编辑内容",
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            Content = entry.Snippet ? new StackPanel { Spacing = 10, Children = { body, name } } : body,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(body.Text))
        {
            return;
        }

        if (entry.Snippet)
        {
            store.SetNote(entry.Id, name.Text);
        }

        if (body.Text != entry.Text)
        {
            store.UpdateText(entry.Id, body.Text);
        }
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
                    Footer.ShowNotice($"已删除收藏夹「{group.Name}」 ·", "撤销 Ctrl+Z", UndoDelete, success: false);
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
