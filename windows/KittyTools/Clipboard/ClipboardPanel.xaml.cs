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
    /// <summary>JSON 默认美化；一次呼出里点过「原文」就一直看原文，收起面板才复位（mac 体检 A10）。</summary>
    private bool _prettyJson = true;
    /// <summary>美化结果按条目缓存（正文变了重算，收起面板时清空）。</summary>
    private readonly Dictionary<long, (string Source, string? Pretty)> _prettyCache = new();
    /// <summary>当前透镜里的链接卡（取到预览后更新它）。</summary>
    private ClipLinkLens? _linkLens;
    /// <summary>Tab 的筛选面板 / Ctrl+K 的操作面板（画在面板里，焦点留在搜索框）。</summary>
    private readonly ClipPalette _palette = new();
    /// <summary>菜单开着时搜索框是过滤词：原来的搜索词先收在这里。</summary>
    private string? _savedQuery;
    private bool _suppressSearch;
    /// <summary>筛选：类型、形态（选了形态类型一定是文本）、来源（exe 路径）。</summary>
    private ClipKind? _kindFilter;
    private ContentForm? _formFilter;
    private string? _sourceFilter;
    /// <summary>⌫ 第一下：最后一个标签待删。</summary>
    private bool _pendingChip;
    private readonly List<Action> _chipRemovers = new();
    /// <summary>合成的复制（多条合并、路径、图中文字）：收起面板时剪贴板还是它，就记成一条新历史（mac）。</summary>
    private (string Text, uint Sequence)? _recordOnHide;
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
        ListHost.Children.Add(_palette);
        _palette.Closed += OnPaletteClosed;
        _palette.FilterReset += () => SetSearchQuietly(string.Empty);
        _list.ItemTapped += OnItemTapped;
        _list.ItemDoubleTapped += index =>
        {
            Select(index, MotionCurve.Instant);
            Paste(plain: false);
        };
        _list.ItemRightTapped += OnItemRightTapped;
        _list.ItemDragStarting += OnItemDragStarting;
        // 真放下了（对方收了）照常收起面板，固定着不收；拖回来 / 没放成不收（mac）。
        _list.ItemDropCompleted += result =>
        {
            if (result != DataPackageOperation.None)
            {
                CloseUnlessPinned();
            }
        };
        _list.NewSnippetTapped += () => _ = NewSnippetAsync();
        if (ClipboardService.Instance?.Store is { } store)
        {
            store.Changed += OnStoreChanged;
        }

        // 空闲两分钟后放掉预览卡（图片解码最占内存），下次选中再建。
        IdleReclaimer.Register(ReleaseCaches);
    }

    /// <summary>空闲回收：丢掉 JSON 美化的缓存（透镜本身面板收起时就拆了）。</summary>
    public void ReleaseCaches()
    {
        _prettyCache.Clear();
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
    {
        get
        {
            var height = PanelMetrics.ClipboardHeightFor(
                _visible.Count + (ShowsNewSnippetRow ? 1 : 0), _list.Layout.SectionTops.Count, reservesLens: LensEnabled);
            // 浮起的菜单开着时至少放得下 8.5 行（mac paletteListHeight）。
            return _palette.IsOpen
                ? Math.Max(height, PanelMetrics.ClipboardPanelChrome + ClipPalette.MaxListHeight + 24)
                : height;
        }
    }

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
        _linkLens = null;
        _palette.Close();
        _savedQuery = null;
        _kindFilter = null;
        _formFilter = null;
        _sourceFilter = null;
        _pendingChip = false;
        _prettyJson = true;
        _prettyCache.Clear();
        _list.SetItems(_visible, Array.Empty<long>(), false, RowContext(), null, -1, null, 0);
        if (Store is { } store)
        {
            store.CommitDeletion();
            if (_copiedOnHide is { } copied && copied.Sequence == PInvoke.GetClipboardSequenceNumber())
            {
                store.Bump(copied.Id);
            }

            if (_recordOnHide is { } composed && composed.Sequence == PInvoke.GetClipboardSequenceNumber() &&
                ClipboardService.Instance?.Paused != true)
            {
                store.RecordOwnText(composed.Text);
            }

            store.EnforceLimits();
        }

        _copiedOnHide = null;
        _recordOnHide = null;
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
        var query = _palette.IsOpen ? _savedQuery ?? string.Empty : SearchBox.Text;
        _visible.AddRange(store.Filter(query.Trim(), _scope, _groupFilterId).Where(entry =>
            (_kindFilter is not { } kind || entry.Kind == kind) &&
            (_formFilter is not { } form || entry.Form == form) &&
            (_sourceFilter is null || string.Equals(entry.SourceExe, _sourceFilter, StringComparison.OrdinalIgnoreCase))));
        // 某来源的条目都没了自动清掉这个筛选（mac）。
        if (_sourceFilter is { } source && !store.Items.Any(entry => string.Equals(entry.SourceExe, source, StringComparison.OrdinalIgnoreCase)))
        {
            _sourceFilter = null;
            UpdateFilterChips();
        }

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
                // 「收藏夹…」打开收藏夹列表（和 Ctrl+K 的「移到收藏夹」子列表同一份，mac 体检 C3）。
                Footer.AddVerb("收藏夹…", null, primary: false, () => OpenPalette("groups", GroupItems(SelectedEntries), top: false));
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
                Footer.AddVerb("操作", "Ctrl+K", primary: false, OpenActionPalette);
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
            case "clip-lens-text":
                SelectWhere(entry => entry.Kind == ClipKind.Text && ContentForms.Detect(entry.Text) is null && entry.Text!.Contains('\n'));
                break;
            case "clip-lens-code":
                SelectWhere(entry => ContentForms.Detect(entry.Text) == ContentForm.Code);
                break;
            case "clip-lens-json":
                SelectWhere(entry => ContentForms.Detect(entry.Text) == ContentForm.Json);
                break;
            case "clip-lens-color":
                SelectWhere(entry => ContentForms.Detect(entry.Text) == ContentForm.Color && entry.Text!.StartsWith("rgba", StringComparison.Ordinal));
                break;
            case "clip-lens-link":
                SelectWhere(entry => ContentForms.Detect(entry.Text) == ContentForm.Link);
                break;
            case "clip-actions":
                SelectWhere(entry => entry.Form == ContentForm.Json);
                OpenActionPalette();
                break;
            case "clip-actions-multi":
                SelectFirstForProbe(3);
                OpenActionPalette();
                break;
            case "clip-filter":
                OpenFilterPalette();
                SearchBox.Text = "json";
                break;
            case "clip-chips":
                _scope = ClipScope.Favorites;
                _formFilter = ContentForm.Code;
                _kindFilter = ClipKind.Text;
                Refresh(animated: false);
                _pendingChip = true;
                UpdateFilterChips();
                break;
            case "clip-scrolled":
                Select(3, MotionCurve.Instant);
                _list.ScrollTo(150);
                break;
        }
    }

    private void SelectWhere(Func<ClipEntry, bool> match)
    {
        var index = _visible.FindIndex(entry => match(entry));
        if (index >= 0)
        {
            Select(index, MotionCurve.Instant);
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
        if (_suppressSearch || !CompositionRules.ShouldSearch(_composing, SearchBox.Text))
        {
            return;
        }

        if (_palette.IsOpen)
        {
            _palette.SetFilter(SearchBox.Text);
            return;
        }

        if (_pendingChip)
        {
            _pendingChip = false;
            UpdateFilterChips();
        }

        Refresh(animated: false);
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
        _linkLens = null;
        if (SelectedEntry is not { } entry || _checked.Count > 0 || !LensEnabled)
        {
            return (null, ClipListLayout.RowHeight);
        }

        var form = entry.Form;
        var body = LensBodyHeight(entry);
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var host = new Grid
        {
            Height = body + ClipLens.Meta + ClipLens.Bottom,
            Padding = new Thickness(ClipLensView.Left, 0, ClipLens.RowPadding, ClipLens.Bottom),
        };
        host.RowDefinitions.Add(new RowDefinition { Height = new GridLength(body) });
        host.RowDefinitions.Add(new RowDefinition { Height = new GridLength(ClipLens.Meta) });
        if (body > 0)
        {
            var content = LensContent(entry, form, body, scale);
            // 正文放进固定高度里裁掉（不滚：滚轮滚的是列表）。
            var clip = new Grid { Height = body, VerticalAlignment = VerticalAlignment.Top, Children = { content } };
            clip.SizeChanged += (_, args) => clip.Clip = new RectangleGeometry
            {
                Rect = new Windows.Foundation.Rect(0, 0, args.NewSize.Width, body),
            };
            content.VerticalAlignment = VerticalAlignment.Top;
            host.Children.Add(clip);
        }

        var meta = ClipLensView.Meta(
            entry, form, scale,
            form == ContentForm.Json ? _prettyJson : null,
            () =>
            {
                _prettyJson = !_prettyJson;
                Select(_selected, MotionCurve.Instant);
            });
        Grid.SetRow(meta, 1);
        host.Children.Add(meta);
        var preview = entry.Kind == ClipKind.Text ? ClipLens.TextTitle(entry.Text) : ClipRowView.TitleText(entry);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            host,
            body > 0 ? $"{ClipLensView.TypeTitle(entry, form)} · {(preview.Length > 200 ? preview[..200] : preview)}" : ClipLensView.TypeTitle(entry, form));
        return (host, ClipLens.Head + body + ClipLens.Meta + ClipLens.Bottom);
    }

    /// <summary>正文区里按类型画什么。</summary>
    private FrameworkElement LensContent(ClipEntry entry, ContentForm? form, double body, double scale)
    {
        var query = SearchBox.Text.Trim();
        switch (entry.Kind)
        {
            case ClipKind.Image:
                return ClipLensView.Picture(entry, scale);
            case ClipKind.Files:
                return ClipLensView.Files(entry.Files, scale);
        }

        var text = entry.Text ?? string.Empty;
        switch (form)
        {
            case ContentForm.Color when ContentForms.Color(text) is { } color:
                return ClipLensView.ColorSwatch(color, CopyColorValue);
            case ContentForm.Link when LinkPreviewRules.SingleUrl(text) is { } uri:
            {
                var link = new ClipLinkLens(uri);
                if (LinkPreviewService.Enabled && LinkPreviewService.Peek(uri) is { } cached)
                {
                    link.Update(cached, animate: false);
                }

                _linkLens = link;
                return link;
            }

            case ContentForm.Code:
                return ClipLensView.Code(text, json: false, query, body);
            case ContentForm.Json:
                return ClipLensView.Code(DisplayText(entry), json: true, query, body);
            default:
                return ClipLensView.Text(text, query, body);
        }
    }

    /// <summary>透镜 / 放大卡里显示的正文：JSON 默认美化（缓存），其余原样。</summary>
    private string DisplayText(ClipEntry entry)
    {
        var text = entry.Text ?? string.Empty;
        if (!_prettyJson)
        {
            return text;
        }

        if (!_prettyCache.TryGetValue(entry.Id, out var cached) || !ReferenceEquals(cached.Source, text))
        {
            cached = (text, ClipPreviewRules.PrettyJson(text));
            _prettyCache[entry.Id] = cached;
        }

        return cached.Pretty ?? text;
    }

    /// <summary>透镜里的色值胶囊：只写剪贴板、不记历史（记了新条目会把选中跳走），底栏「已复制 #3478F6」。</summary>
    private void CopyColorValue(string value)
    {
        if (ClipboardWriter.WriteText(value))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            Footer.ShowNotice($"已复制 {value}");
        }
    }

    /// <summary>正文区高度（Core 的 ClipLens 查表）；文本的 0 档先量标题在最窄的标题列里放不放得下。</summary>
    private double LensBodyHeight(ClipEntry entry)
    {
        var form = entry.Form;
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
        if (e.Key != VirtualKey.Back && _pendingChip)
        {
            _pendingChip = false;
            UpdateFilterChips();
            if (e.Key == VirtualKey.Escape)
            {
                // Esc 这一下只取消标签待删。
                e.Handled = true;
                return;
            }
        }

        // 菜单开着：↑↓ Enter → ← Esc Tab 归菜单；Ctrl 组合键做了才收起菜单（mac：同启动器）。
        if (_palette.IsOpen && HandlePaletteKey(e, control))
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                // mac 的顺序：标签待删 → 清搜索词 → 取消多选 → 收起。
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
            case VirtualKey.Enter when control:
                // Ctrl+Enter 仅复制（mac ⌘↩）。
                e.Handled = true;
                CopySelected();
                break;
            case VirtualKey.Enter:
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
                OpenFilterPalette();
                break;
            case VirtualKey.Right when SearchBox.SelectionStart == SearchBox.Text.Length && SearchBox.SelectionLength == 0 &&
                                       SelectedEntry is not null:
                // 光标在搜索词末尾（或搜索为空）且有选中项：→ 打开 Ctrl+K（mac）。
                e.Handled = true;
                OpenActionPalette();
                break;
            case VirtualKey.Back when SearchBox.Text.Length == 0 && SearchLineControl.Chips.Children.Count > 0:
                // 搜索为空且有标签：第一下选中最后一个标签（待删），第二下删掉（mac）。
                e.Handled = true;
                if (_pendingChip)
                {
                    _pendingChip = false;
                    RemoveLastChip();
                }
                else
                {
                    _pendingChip = true;
                    UpdateFilterChips();
                    Footer.ShowNotice("再按一次删除键移除这个标签");
                }

                break;
            case VirtualKey.N when control:
                e.Handled = true;
                _ = NewSnippetAsync();
                break;
            case VirtualKey.E when control:
                e.Handled = true;
                if (SingleTarget is { Kind: ClipKind.Text } editable)
                {
                    _ = EditSnippetAsync(editable);
                }

                break;
            case VirtualKey.P when control:
                e.Handled = true;
                PinRequested?.Invoke();
                break;
            case VirtualKey.K when control:
                e.Handled = true;
                OpenActionPalette();
                break;
            case (VirtualKey)188 when control:
                // Ctrl+,：设置 › 剪贴板（底栏齿轮同样直达）。
                e.Handled = true;
                SettingsRequested?.Invoke();
                break;
            case VirtualKey.Delete when SearchBox.SelectionStart == SearchBox.Text.Length &&
                                        SearchBox.SelectionLength == 0:
                e.Handled = true;
                DeleteSelected();
                break;
            case VirtualKey.C when control && shift:
                // Ctrl+Shift+C：复制路径（全是文件时）。
                e.Handled = true;
                if (!CopyPaths(SelectedEntries))
                {
                    Beep();
                }

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
                if (SingleTarget is { } translatable && CanTranslate(translatable))
                {
                    TranslateEntry(translatable);
                }
                else
                {
                    Beep();
                }

                break;
            case VirtualKey.O when control:
                // Ctrl+O：打开链接 / 用默认程序打开文件。
                e.Handled = true;
                if (!OpenTarget(SingleTarget))
                {
                    Beep();
                }

                break;
            case VirtualKey.R when control:
                // Ctrl+R：在资源管理器中显示（文件）。
                e.Handled = true;
                if (SingleTarget is { Kind: ClipKind.Files } files)
                {
                    RevealFiles(files);
                }
                else
                {
                    Beep();
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

    /// <summary>菜单开着时的按键；返回 true = 已经处理（不再往下走）。</summary>
    private bool HandlePaletteKey(KeyRoutedEventArgs e, bool control)
    {
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                if (!_palette.Back())
                {
                    _palette.Close();
                }

                return true;
            case VirtualKey.Up:
                e.Handled = true;
                _palette.Move(-1);
                return true;
            case VirtualKey.Down:
                e.Handled = true;
                _palette.Move(1);
                return true;
            case VirtualKey.Enter when !control:
                e.Handled = true;
                _palette.Activate();
                return true;
            case VirtualKey.Right when SearchBox.SelectionStart == SearchBox.Text.Length:
                e.Handled = true;
                _palette.EnterSelected();
                return true;
            case VirtualKey.Left when SearchBox.Text.Length == 0:
                e.Handled = true;
                if (!_palette.Back())
                {
                    _palette.Close();
                }

                return true;
            case VirtualKey.Tab:
                // Tab 开 / 关筛选面板；操作面板开着时 Tab 换成筛选面板。
                e.Handled = true;
                var wasFilter = _palette.Kind == "filter";
                _palette.Close();
                if (!wasFilter)
                {
                    OpenFilterPalette();
                }

                return true;
            case VirtualKey.K when control && _palette.Kind == "actions":
                e.Handled = true;
                _palette.Close();
                return true;
        }

        // 过滤框里有字时 Ctrl+Delete / A / V / X / Z 交给输入框、菜单留着；其余 Ctrl 组合键做了就收起菜单（mac 体检 B10）。
        if (control && e.Key is not (VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu))
        {
            if (SearchBox.Text.Length > 0 && e.Key is VirtualKey.A or VirtualKey.V or VirtualKey.X or VirtualKey.Z or VirtualKey.Back or VirtualKey.Delete)
            {
                return true;
            }

            _palette.Close();
        }

        return false;
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

        if (!LinkPreviewService.Enabled || _linkLens is not { } lens || LinkPreviewService.Peek(lens.Uri) is not null ||
            !LinkPreviewRules.CanFetch(lens.Uri) || SensitiveText.LooksSensitive(SelectedEntry?.Text ?? string.Empty))
        {
            return;
        }

        _linkPending = lens.Uri;
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
            _linkLens?.SetLoading(true);
            _ = LoadLinkPreviewAsync(uri, _linkCts.Token);
        }
    }

    private async Task LoadLinkPreviewAsync(Uri uri, CancellationToken cancellationToken)
    {
        var cached = await LinkPreviewService.FetchAsync(uri, cancellationToken);
        if (cancellationToken.IsCancellationRequested || _linkLens is not { } lens || lens.Uri != uri)
        {
            return;
        }

        if (cached is null || !LinkPreviewService.Enabled)
        {
            lens.SetLoading(false);
            return;
        }

        lens.Update(cached, animate: true);
    }

    /// <summary>写一段字进剪贴板；recordOnHide：面板里不动，收起时剪贴板还是它就记成一条新历史（mac 合成的复制）。</summary>
    private void CopyText(string text, bool recordOnHide = false, string notice = "已复制")
    {
        if (ClipboardWriter.WriteText(text))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            if (recordOnHide)
            {
                _recordOnHide = (text, PInvoke.GetClipboardSequenceNumber());
            }

            // 面板开着：成功的提示进底栏（PLAN-v7 §3.1），出错的才走轻提示。
            Footer.ShowNotice(notice);
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

    /// <summary>翻译文本，或识别出文字的图片（翻译识别出的字）。</summary>
    private static void TranslateEntry(ClipEntry entry)
    {
        var text = entry.Kind == ClipKind.Image ? entry.OcrText : entry.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            NoticeHost.Show("不能翻译", "只有文本和识别出文字的图片能翻译", NoticeTone.Warning);
            return;
        }

        // 剪贴板面板留着，翻译浮窗只露出（PLAN §7.4 / PLAN-v2 §6 第 1 批）。
        TranslateHost.ShowTextKeepOverlay(text);
    }

    /// <summary>钉到屏幕：多张依次往右下错开 24，不叠在一起（mac）；没固定就先收起面板。</summary>
    private async Task PinImagesAsync(IReadOnlyList<ClipEntry> entries)
    {
        CloseUnlessPinned();
        for (var index = 0; index < entries.Count; index++)
        {
            await PinImageAsync(entries[index], index * 24);
        }
    }

    private async Task PinImageAsync(ClipEntry entry, int offset)
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
            var left = Math.Clamp(cursor.X - width / 2 + offset, area.X, area.X + area.Width - width);
            var top = Math.Clamp(cursor.Y - height / 2 + offset, area.Y, area.Y + area.Height - height);
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

        // 右键对着被点的那一条（mac「右键传被点的 [item]」）；点在勾选项上就对着全部勾选项。
        var targets = _checked.Contains(_visible[index].Id) ? SelectedEntries : new List<ClipEntry> { _visible[index] };
        if (targets.Count == 1)
        {
            _checked.Clear();
            _list.SetChecked(null);
            Select(index, MotionCurve.Glide);
        }

        ContextMenu(targets).ShowAt(row, new FlyoutShowOptions { Position = position });
    }

    // ---- 菜单：Tab 的筛选面板、Ctrl+K 的操作面板、多选底栏的收藏夹列表、右键菜单（PLAN-v9-clipboard I5、I11、I12、I16）

    /// <summary>单条操作（Ctrl+E / T / O / R）的对象：操作对象只有一条时就是它（mac singleTarget）。</summary>
    private ClipEntry? SingleTarget => SelectedEntries is { Count: 1 } targets ? targets[0] : null;

    private void OpenFilterPalette()
    {
        OpenPalette("filter", FilterItems(), top: true);
    }

    private void OpenActionPalette()
    {
        var targets = SelectedEntries;
        if (targets.Count == 0)
        {
            Beep();
            return;
        }

        OpenPalette("actions", ActionItems(targets), top: false);
    }

    /// <summary>
    /// 打开面板里的菜单：搜索框这时用来过滤菜单，原来的搜索词先收着、关菜单时放回去。
    /// 筛选面板锚在搜索线左下，操作面板 / 收藏夹列表锚在底栏右上（对着「操作 Ctrl+K」）。
    /// </summary>
    private void OpenPalette(string kind, IReadOnlyList<PaletteItem> items, bool top, string? submenu = null)
    {
        if (!_palette.IsOpen)
        {
            _savedQuery = SearchBox.Text;
            SetSearchQuietly(string.Empty);
        }

        _palette.HorizontalAlignment = top ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        _palette.VerticalAlignment = top ? VerticalAlignment.Top : VerticalAlignment.Bottom;
        _palette.Margin = top ? new Thickness(12, 4, 0, 0) : new Thickness(0, 0, 12, 4);
        _palette.Open(kind, items, submenu);
        SearchBox.PlaceholderText = kind == "filter" ? "过滤筛选项" : "过滤操作";
        UpdateFooter();
        HeightRequested?.Invoke(ContentHeightDip, false);
        FocusSearch();
    }

    private void OnPaletteClosed()
    {
        SetSearchQuietly(_savedQuery ?? string.Empty);
        _savedQuery = null;
        SearchBox.PlaceholderText = SearchLineControl.Chips.Children.Count > 0 ? "搜索" : "搜索剪贴板，Tab 筛选";
        if (_active)
        {
            UpdateFooter();
            HeightRequested?.Invoke(ContentHeightDip, false);
            FocusSearch();
        }
    }

    /// <summary>改搜索框里的字但不触发搜索（菜单开关时换过滤词）。</summary>
    private void SetSearchQuietly(string text)
    {
        _suppressSearch = true;
        SearchBox.Text = text;
        SearchBox.SelectionStart = text.Length;
        _suppressSearch = false;
    }

    /// <summary>
    /// 筛选面板（mac）：收藏、各个收藏夹（紧跟在收藏下面，按顺序）、片段 ｜ 类型 ｜ 形态 ｜ 来源（按条数从多到少）｜ 管理收藏夹…；
    /// 已生效的打 ✓，对它再按一次 = 取消。
    /// </summary>
    private List<PaletteItem> FilterItems()
    {
        var items = new List<PaletteItem>
        {
            new("收藏", Glyphs.Star, 0, () => ToggleScope(ClipScope.Favorites), Checked: _scope == ClipScope.Favorites && _groupFilterId is null),
        };
        foreach (var group in Store?.Groups.OrderBy(item => item.Position) ?? Enumerable.Empty<ClipGroup>())
        {
            var id = group.Id;
            items.Add(new PaletteItem(group.Name, Glyphs.Folder, 0, () =>
            {
                if (_groupFilterId == id)
                {
                    _groupFilterId = null;
                    SetScope(ClipScope.All);
                    return;
                }

                _scope = ClipScope.Favorites;
                _groupFilterId = id;
                RefreshGroups();
                Refresh();
            }, Checked: _groupFilterId == id));
        }

        items.Add(new PaletteItem("片段", Glyphs.Snippet, 0, () => ToggleScope(ClipScope.Snippets), Checked: _scope == ClipScope.Snippets));
        foreach (var (kind, title, glyph) in new[] { (ClipKind.Text, "文本", Glyphs.Text), (ClipKind.Image, "图片", Glyphs.Image), (ClipKind.Files, "文件", Glyphs.Folder) })
        {
            items.Add(new PaletteItem(title, glyph, 1, () =>
            {
                _kindFilter = _kindFilter == kind && _formFilter is null ? null : kind;
                // 选图片或文件就清掉形态（mac 联动）。
                _formFilter = null;
                Refresh(animated: false);
                UpdateFilterChips();
            }, Checked: _kindFilter == kind && _formFilter is null));
        }

        foreach (var form in new[] { ContentForm.Color, ContentForm.Json, ContentForm.Link, ContentForm.Code })
        {
            var glyph = ClipRowView.KindOf(new ClipEntry { Kind = ClipKind.Text }, form).Glyph;
            items.Add(new PaletteItem(ContentForms.Title(form), glyph, 2, () =>
            {
                // 选了形态自动把类型切到文本（mac 联动）。
                _formFilter = _formFilter == form ? null : form;
                _kindFilter = _formFilter is null ? null : ClipKind.Text;
                Refresh(animated: false);
                UpdateFilterChips();
            }, Checked: _formFilter == form));
        }

        foreach (var (exe, name, _) in Sources())
        {
            items.Add(new PaletteItem(name, Glyphs.App, 3, () =>
            {
                _sourceFilter = _sourceFilter == exe ? null : exe;
                Refresh(animated: false);
                UpdateFilterChips();
            }, Checked: string.Equals(_sourceFilter, exe, StringComparison.OrdinalIgnoreCase)));
        }

        items.Add(new PaletteItem("管理收藏夹…", Glyphs.Settings, 4, () => _ = ManageGroupsAsync()));
        return items;
    }

    /// <summary>来源候选：按条数从多到少（没有来源的不列）。</summary>
    private List<(string Exe, string Name, int Count)> Sources()
        => (Store?.Items ?? Array.Empty<ClipEntry>())
            .Where(entry => !string.IsNullOrEmpty(entry.SourceExe))
            .GroupBy(entry => entry.SourceExe!, StringComparer.OrdinalIgnoreCase)
            .Select(group => (group.Key, group.First().SourceName ?? Path.GetFileNameWithoutExtension(group.Key), group.Count()))
            .OrderByDescending(item => item.Item3)
            .ToList();

    private void ToggleScope(ClipScope scope)
    {
        _groupFilterId = null;
        SetScope(_scope == scope ? ClipScope.All : scope);
    }

    /// <summary>
    /// 操作面板（mac ClipboardPanelModel.actions(for:targets:)）：粘贴与复制 ｜ 按类型打开 / 查看 ｜ 收藏、收藏夹、片段、备注、编辑 ｜ 删除。
    /// 勾了不止一条时只给批量操作。右键菜单是同一份。
    /// </summary>
    private List<PaletteItem> ActionItems(List<ClipEntry> targets)
    {
        var single = targets.Count == 1 ? targets[0] : null;
        var formatted = targets.Count > 1 || single?.Rich == true;
        var mode = MultiPaste.Mode(
            targets.Count,
            targets.All(entry => entry.Kind == ClipKind.Text),
            targets.All(entry => entry.Kind == ClipKind.Files));
        var items = new List<PaletteItem>
        {
            new(targets.Count > 1 ? MultiPaste.ShortVerb(mode) : "粘贴", Glyphs.Paste, 0, () => Paste(plain: false), "Enter"),
        };
        if (formatted)
        {
            items.Add(new PaletteItem("粘贴为纯文本", Glyphs.Text, 0, () => Paste(plain: true), "Shift+Enter"));
        }

        items.Add(new PaletteItem("仅复制", Glyphs.Copy, 0, CopySelected, "Ctrl+C"));
        if (formatted && targets.All(entry => entry.Kind == ClipKind.Text))
        {
            items.Add(new PaletteItem("复制为纯文本", Glyphs.Copy, 0, () => CopyPlain(targets)));
        }

        if (single is { Kind: ClipKind.Image } image && !string.IsNullOrWhiteSpace(image.OcrText))
        {
            items.Add(new PaletteItem("复制图中文字", Glyphs.Ocr, 0, () => CopyText(image.OcrText!, recordOnHide: true)));
        }

        if (targets.All(entry => entry.Kind == ClipKind.Files))
        {
            items.Add(new PaletteItem("复制路径", Glyphs.Link, 0, () => CopyPaths(targets), "Ctrl+Shift+C"));
        }

        if (single is not null)
        {
            if (single.Kind == ClipKind.Files)
            {
                items.Add(new PaletteItem("打开", Glyphs.OpenInNewWindow, 1, () => OpenTarget(single), "Ctrl+O"));
                items.Add(new PaletteItem("在资源管理器中显示", Glyphs.Folder, 1, () => RevealFiles(single), "Ctrl+R"));
            }
            else if (single.Kind == ClipKind.Text && ContentForms.FirstLink(single.Text) is not null)
            {
                items.Add(new PaletteItem("打开链接", Glyphs.Globe, 1, () => OpenTarget(single), "Ctrl+O"));
            }

            if (single.Kind == ClipKind.Image)
            {
                items.Add(new PaletteItem("钉到屏幕", Glyphs.Pin, 1, () => _ = PinImagesAsync(new[] { single })));
            }

            if (CanTranslate(single))
            {
                items.Add(new PaletteItem("翻译", Glyphs.Translate, 1, () => TranslateEntry(single), "Ctrl+T"));
            }

            if (single.Form == ContentForm.Json)
            {
                items.Add(new PaletteItem(_prettyJson ? "显示原文" : "美化 JSON", Glyphs.Code, 1, () =>
                {
                    _prettyJson = !_prettyJson;
                    Select(_selected, MotionCurve.Instant);
                }));
            }
        }
        else if (targets.Any(entry => entry.Kind == ClipKind.Image))
        {
            items.Add(new PaletteItem("钉到屏幕", Glyphs.Pin, 1, () => _ = PinImagesAsync(targets.Where(entry => entry.Kind == ClipKind.Image).ToList())));
        }

        var favorite = targets.All(entry => entry.Favorite);
        items.Add(new PaletteItem(favorite ? "取消收藏" : "收藏", favorite ? Glyphs.FavoriteFilled : Glyphs.Star, 2, FavoriteSelected, "Ctrl+D"));
        if (Store?.Groups.Count is null or 0)
        {
            items.Add(new PaletteItem("放进新收藏夹…", Glyphs.Folder, 2, () => _ = NewGroupForAsync(targets)));
        }
        else
        {
            items.Add(new PaletteItem("移到收藏夹", Glyphs.Folder, 2, null, Submenu: GroupItems(targets)));
        }

        if (single is { Kind: ClipKind.Text, Snippet: false })
        {
            items.Add(new PaletteItem("存为片段", Glyphs.Snippet, 2, () => ToggleSnippet(single)));
        }

        var snippets = targets.Where(entry => entry.Snippet).ToList();
        if (snippets.Count > 0)
        {
            items.Add(new PaletteItem("移出片段", Glyphs.Snippet, 2, () => RemoveSnippets(snippets)));
        }

        if (single is not null)
        {
            items.Add(new PaletteItem("备注…", Glyphs.Edit, 2, () => _ = EditNoteAsync(single)));
            if (single.Kind == ClipKind.Text)
            {
                items.Add(new PaletteItem("编辑内容…", Glyphs.Edit, 2, () => _ = EditSnippetAsync(single), "Ctrl+E"));
            }
        }

        items.Add(new PaletteItem("删除", Glyphs.Delete, 3, DeleteSelected, "Delete", Danger: true));
        return items;
    }

    /// <summary>「移到收藏夹 ›」：各个收藏夹（都在里面的那个 ✓，再选一次移出）、「移出收藏夹」「新建收藏夹…」。</summary>
    private List<PaletteItem> GroupItems(List<ClipEntry> targets)
    {
        var items = new List<PaletteItem>();
        if (Store is not { } store)
        {
            return items;
        }

        foreach (var group in store.Groups.OrderBy(item => item.Position))
        {
            var id = group.Id;
            var inIt = targets.All(entry => entry.GroupId == id);
            items.Add(new PaletteItem(group.Name, Glyphs.Folder, 0, () => MoveToGroup(targets, inIt ? null : id, inIt ? null : group.Name), Checked: inIt));
        }

        if (targets.Any(entry => entry.GroupId is not null))
        {
            items.Add(new PaletteItem("移出收藏夹", Glyphs.Folder, 1, () => MoveToGroup(targets, null, null)));
        }

        items.Add(new PaletteItem("新建收藏夹…", Glyphs.Add, 1, () => _ = NewGroupForAsync(targets)));
        return items;
    }

    private void MoveToGroup(List<ClipEntry> targets, string? groupId, string? name)
    {
        if (Store is not { } store)
        {
            return;
        }

        foreach (var entry in targets)
        {
            store.MoveToGroup(entry.Id, groupId);
        }

        Refresh(SelectedEntry?.Id, animated: false);
        Footer.ShowNotice(name is null ? "已移出收藏夹" : $"已移到「{name}」");
    }

    private async Task NewGroupForAsync(List<ClipEntry> targets)
    {
        var name = await PromptAsync("新建收藏夹", "收藏夹的名字（最多 24 字）");
        if (string.IsNullOrWhiteSpace(name) || Store is not { } store)
        {
            return;
        }

        if (store.CreateGroup(name) is not { } group)
        {
            NoticeHost.Show("名字不能用", "不能为空、不能重名、最多 24 字", NoticeTone.Warning);
            return;
        }

        MoveToGroup(targets, group.Id, group.Name);
    }

    /// <summary>一行字的小对话框（6e 换成画在面板里的）。</summary>
    private async Task<string?> PromptAsync(string title, string placeholder)
    {
        var box = new TextBox { PlaceholderText = placeholder, MaxLength = ClipGroups.MaxNameLength };
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = title,
            PrimaryButtonText = "好",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            Content = box,
            XamlRoot = XamlRoot,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? box.Text : null;
    }

    private void RemoveSnippets(List<ClipEntry> snippets)
    {
        if (Store is not { } store)
        {
            return;
        }

        var expired = store.SetSnippet(snippets.Select(entry => entry.Id).ToList(), false);
        if (!ShowExpiredNotice(expired))
        {
            Footer.ShowNotice(snippets.Count > 1 ? $"已移出片段 {snippets.Count} 条" : "已移出片段");
        }
    }

    /// <summary>右键菜单：和 Ctrl+K 同一份条目；分节是分隔线、子列表是子菜单、不写键位（Windows 右键菜单的习惯）、删除是危险色。</summary>
    private MenuFlyout ContextMenu(List<ClipEntry> targets)
    {
        var menu = new MenuFlyout();
        void Fill(IList<MenuFlyoutItemBase> into, IReadOnlyList<PaletteItem> items)
        {
            var section = int.MinValue;
            foreach (var item in items)
            {
                if (section != int.MinValue && item.Section != section)
                {
                    into.Add(new MenuFlyoutSeparator());
                }

                section = item.Section;
                if (item.Submenu is { } submenu)
                {
                    var sub = new MenuFlyoutSubItem { Text = item.Title, Icon = new FontIcon { Glyph = item.Glyph } };
                    Fill(sub.Items, submenu);
                    into.Add(sub);
                    continue;
                }

                var entry = new MenuFlyoutItem
                {
                    Text = item.Title,
                    Icon = new FontIcon { Glyph = item.Checked ? Glyphs.Check : item.Glyph },
                    IsEnabled = item.Run is not null,
                };
                if (item.Danger)
                {
                    entry.Foreground = new SolidColorBrush(Theme.Value(0xFF3B30, 0xFF453A));
                }

                var run = item.Run;
                entry.Click += (_, _) => run?.Invoke();
                into.Add(entry);
            }
        }

        Fill(menu.Items, ActionItems(targets));
        return menu;
    }

    private static bool CanTranslate(ClipEntry entry)
        => entry.Kind == ClipKind.Text ? !string.IsNullOrWhiteSpace(entry.Text) : entry.Kind == ClipKind.Image && !string.IsNullOrWhiteSpace(entry.OcrText);

    /// <summary>打开链接 / 用默认程序打开文件：没固定就先收起面板，再交给系统在后台打开（mac 体检 B13）。</summary>
    private bool OpenTarget(ClipEntry? entry)
    {
        string? target = entry?.Kind switch
        {
            ClipKind.Files => entry.Files.FirstOrDefault(path => File.Exists(path) || Directory.Exists(path)),
            ClipKind.Text => ContentForms.FirstLink(entry.Text)?.ToString(),
            _ => null,
        };
        if (target is null)
        {
            if (entry?.Kind == ClipKind.Files)
            {
                NoticeHost.Show("没能打开", "文件已经不在原处", NoticeTone.Warning);
                return true;
            }

            return false;
        }

        CloseUnlessPinned();
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.open-failed {ex.GetType().Name}");
            NoticeHost.Show("没能打开", ex.GetType().Name, NoticeTone.Error);
        }

        return true;
    }

    private void RevealFiles(ClipEntry entry)
    {
        var first = entry.Files.FirstOrDefault(path => File.Exists(path) || Directory.Exists(path));
        if (first is null)
        {
            NoticeHost.Show("没能显示", "文件已经不在原处", NoticeTone.Warning);
            return;
        }

        CloseUnlessPinned();
        RevealInExplorer(first);
    }

    private void CloseUnlessPinned()
    {
        if (!_pinned)
        {
            CloseRequested?.Invoke();
        }
    }

    private static void Beep() => MessageBeep(0xFFFFFFFF);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool MessageBeep(uint type);

    // ---- 标签（范围 / 收藏夹、类型或形态、来源）

    /// <summary>搜索线里的标签：范围（收藏 / 片段）或收藏夹、类型或形态、来源；点 × 移除，点标签本身开筛选面板；⌫ 待删时底色加深。</summary>
    private void UpdateFilterChips()
    {
        SearchLineControl.Chips.Children.Clear();
        var chips = new List<(string Text, Action Remove)>();
        if (_groupFilterId is { } id)
        {
            chips.Add((Store?.GroupName(id) ?? "收藏夹", () =>
            {
                _groupFilterId = null;
                SetScope(ClipScope.All);
            }));
        }
        else if (_scope != ClipScope.All)
        {
            chips.Add((_scope == ClipScope.Favorites ? "收藏" : "片段", () => SetScope(ClipScope.All)));
        }

        if (_formFilter is { } form)
        {
            chips.Add((ContentForms.Title(form), () =>
            {
                _formFilter = null;
                _kindFilter = null;
                Refresh(animated: false);
                UpdateFilterChips();
            }));
        }
        else if (_kindFilter is { } kind)
        {
            chips.Add((kind switch { ClipKind.Image => "图片", ClipKind.Files => "文件", _ => "文本" }, () =>
            {
                _kindFilter = null;
                Refresh(animated: false);
                UpdateFilterChips();
            }));
        }

        if (_sourceFilter is { } source)
        {
            var name = Sources().FirstOrDefault(item => string.Equals(item.Exe, source, StringComparison.OrdinalIgnoreCase)).Name
                       ?? Path.GetFileNameWithoutExtension(source);
            chips.Add((name, () =>
            {
                _sourceFilter = null;
                Refresh(animated: false);
                UpdateFilterChips();
            }));
        }

        _chipRemovers.Clear();
        for (var index = 0; index < chips.Count; index++)
        {
            var (text, remove) = chips[index];
            _chipRemovers.Add(remove);
            var chip = SearchLineControl.AddChip(text, () =>
            {
                remove();
                FocusSearch();
            });
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(chip, $"筛选：{text}");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(chip, "按删除键移除");
            chip.Tapped += (_, args) =>
            {
                args.Handled = true;
                OpenFilterPalette();
            };
            if (_pendingChip && index == chips.Count - 1)
            {
                var accent = Theme.AccentColor;
                chip.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(77, accent.R, accent.G, accent.B));
            }
        }

        if (!_palette.IsOpen)
        {
            SearchBox.PlaceholderText = chips.Count > 0 ? "搜索" : "搜索剪贴板，Tab 筛选";
        }
    }

    private void RemoveLastChip()
    {
        if (_chipRemovers.Count > 0)
        {
            _chipRemovers[^1]();
        }

        UpdateFilterChips();
    }

    // ---- 复制

    /// <summary>
    /// Ctrl+C / 仅复制（mac copy(targets)）：一条照常；全是文本合成一段；全是文件一次写进全部文件；
    /// 混着图片的只写第 1 条、底栏警告。合成的面板里不动，收起面板时才记成一条新历史。
    /// </summary>
    private void CopySelected()
    {
        var targets = SelectedEntries;
        if (targets.Count == 0)
        {
            return;
        }

        if (targets.Count == 1)
        {
            Copy(targets[0]);
            return;
        }

        if (targets.All(entry => entry.Kind == ClipKind.Text))
        {
            CopyText(MultiPaste.Merge(targets.Select(entry => entry.Text ?? string.Empty)), recordOnHide: true, $"已复制 {targets.Count} 条，合成一段");
            return;
        }

        if (targets.All(entry => entry.Kind == ClipKind.Files))
        {
            var files = targets.SelectMany(entry => entry.Files).Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(path => File.Exists(path) || Directory.Exists(path)).ToList();
            if (files.Count > 0 && ClipboardWriter.WriteFiles(files))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                Footer.ShowNotice($"已复制 {files.Count} 个文件");
            }

            return;
        }

        Copy(targets[0]);
        Footer.ShowNotice("只复制了第 1 条，图片和别的一起没法放进剪贴板", success: false);
    }

    /// <summary>复制为纯文本：去掉格式写进剪贴板，收起面板时记一条。</summary>
    private void CopyPlain(List<ClipEntry> targets)
        => CopyText(MultiPaste.Merge(targets.Select(entry => entry.Text ?? string.Empty)), recordOnHide: true);

    /// <summary>复制路径（全是文件时，多个按换行拼）；同 Ctrl+C：面板开着时列表不动，收起时才记成一条新历史。</summary>
    private bool CopyPaths(List<ClipEntry> targets)
    {
        if (targets.Count == 0 || !targets.All(entry => entry.Kind == ClipKind.Files))
        {
            return false;
        }

        CopyText(string.Join("\r\n", targets.SelectMany(entry => entry.Files)), recordOnHide: true, "已复制路径");
        return true;
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
