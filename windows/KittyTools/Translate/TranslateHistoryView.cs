// 翻译历史（照 mac HistoryView / HistoryList，PLAN-v9-translate 8d）：整块替换浮窗的结果区（原文区不动），高 420。
// 顶上搜索框（28 高）+「全部」「收藏」两枚范围胶囊；按 今天 / 昨天 / 日期 分组（标题 24、11 semibold tertiary），行 44（原文 13、译文 12
// 各一行，右边时间 11 和黄色星标，复制后时间换成「✓ 已复制」）；一块中性高亮按前缀和定位、在行间滑动，悬停有底色；没有底栏。
// 列表只建可见区附近的行（Core 的 HistoryListLayout 算位置），一页 500 条、滚到底取下一页。
// 按键：↑↓ 选（首尾循环）、Enter / 双击重新翻译、Shift+Tab 换范围、光标在搜索词末尾时 → 和 Ctrl+K 开动作菜单（ClipPalette，同启动器）、
// Ctrl+C 复制译文（搜索框有选中的字时交还）、Ctrl+Shift+C 复制原文、Ctrl+D 收藏、Ctrl+Delete 删（不确认，Ctrl+Z 撤销）、
// Esc 先关菜单 → 清空搜索 → 关历史。右键是系统菜单，条目和 Ctrl+K 同一份。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace KittyTools;

internal sealed partial class TranslateHistoryView : Grid
{
    /// <summary>历史开着时结果区固定这么高（mac TranslatePanelView：历史 420）。</summary>
    public const double PanelHeight = 420;

    private const int PageSize = 500;
    private const double SideInset = 12;
    private const double Overscan = 300;

    private readonly Action<TranslationEntry> _retranslate;
    private readonly Action _close;
    private readonly Func<Microsoft.UI.WindowId> _owner;
    private readonly Action<bool> _holdOpen;
    private readonly TextBox _search;
    private readonly Button _all;
    private readonly Button _favorites;
    private readonly Grid _listHost;
    private readonly ScrollViewer _scroll;
    private readonly Canvas _canvas;
    private readonly Border _highlight;
    private readonly ClipPalette _palette = new();
    private readonly Dictionary<int, Grid> _rows = new();
    private readonly List<FrameworkElement> _headers = new();
    private FrameworkElement? _empty;

    private List<TranslationEntry> _entries = new();
    private HistoryListLayout _layout = new(Array.Empty<DateTime>(), DateTime.Now);
    private bool _favoritesOnly;
    private int _pages = 1;
    private string? _selectedId;
    private string? _copiedId;
    private int _copyTick;
    private int _hovered = -1;
    private string _savedQuery = string.Empty;
    private bool _quiet;

    public TranslateHistoryView(
        Action<TranslationEntry> retranslate, Action close, Func<Microsoft.UI.WindowId> owner, Action<bool> holdOpen)
    {
        _retranslate = retranslate;
        _close = close;
        _owner = owner;
        _holdOpen = holdOpen;
        Height = PanelHeight;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowSpacing = 4;

        // ---- 搜索框 + 范围胶囊
        _search = new TextBox
        {
            PlaceholderText = "搜索原文或译文",
            FontSize = 13,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            MinHeight = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        SearchLine.MakePlain(_search);
        AutomationProperties.SetName(_search, "搜索翻译历史");
        _search.TextChanged += (_, _) => OnSearchChanged();
        var field = new Grid
        {
            Height = 28,
            Padding = new Thickness(8, 0, 8, 0),
            ColumnSpacing = 6,
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = Theme.Brush("Kitty.Input", Theme.Argb(11, 0, 0, 0)),
        };
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var magnifier = new FontIcon
        {
            Glyph = Glyphs.Search,
            FontSize = 12,
            Foreground = Theme.TertiaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(_search, 1);
        field.Children.Add(magnifier);
        field.Children.Add(_search);
        _all = ScopeCapsule("全部", () => SetScope(false));
        _favorites = ScopeCapsule("收藏", () => SetScope(true));
        var top = new Grid { ColumnSpacing = 6, Margin = new Thickness(SideInset, 0, SideInset, 0) };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_all, 1);
        Grid.SetColumn(_favorites, 2);
        top.Children.Add(field);
        top.Children.Add(_all);
        top.Children.Add(_favorites);
        Children.Add(top);

        // ---- 列表
        _canvas = new Canvas { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        _highlight = new Border
        {
            Height = HistoryListLayout.RowHeight,
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Background = Theme.Brush("Kitty.Fill.Selected", Theme.Argb(0x12, 0, 0, 0)),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        _canvas.Children.Add(_highlight);
        _scroll = new ScrollViewer
        {
            Content = _canvas,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            IsTabStop = false,
        };
        _scroll.ViewChanged += (_, _) =>
        {
            Realize();
            // 滚到最后一行附近时取下一页。
            if (_scroll.VerticalOffset + _scroll.ViewportHeight > _layout.TotalHeight - 200 && HasMore)
            {
                LoadMore();
            }
        };
        _listHost = new Grid();
        _listHost.Children.Add(_scroll);
        _listHost.Children.Add(_palette.Scrim);
        _listHost.Children.Add(_palette);
        _listHost.SizeChanged += (_, _) => Realize(force: true);
        _palette.HorizontalAlignment = HorizontalAlignment.Right;
        _palette.VerticalAlignment = VerticalAlignment.Bottom;
        _palette.Margin = new Thickness(0, 0, SideInset, SideInset);
        _palette.Closed += OnPaletteClosed;
        _palette.FilterReset += () => SetSearchQuietly(string.Empty);
        Grid.SetRow(_listHost, 1);
        Children.Add(_listHost);

        if (TranslationHistory.Instance is { } history)
        {
            // 同步落地这类可能不在 UI 线程上来：排回 UI 线程再刷。
            history.Changed += () => DispatcherQueue.TryEnqueue(() =>
            {
                if (Visibility == Visibility.Visible)
                {
                    Refresh(keepSelection: true);
                }
            });
        }
    }

    public TextBox SearchBox => _search;

    private bool HasMore => _entries.Count >= _pages * PageSize;

    private TranslationEntry? Selected
        => _entries.FirstOrDefault(entry => entry.Id == _selectedId) ?? _entries.FirstOrDefault();

    /// <summary>开 / 关历史时复位（搜索词、范围、菜单、页数、撤销栈）。</summary>
    public void Reset()
    {
        _palette.Close();
        SetSearchQuietly(string.Empty);
        _favoritesOnly = false;
        _pages = 1;
        _selectedId = null;
        _copiedId = null;
        TranslationHistory.Instance?.ClearUndo();
        UpdateScope();
        Refresh(keepSelection: false);
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    public void FocusSearch() => _search.Focus(FocusState.Programmatic);

    /// <summary>UI 截图自检：选中第二条；menu 时再打开 Ctrl+K 菜单。</summary>
    internal void ApplyProbeState(bool menu)
    {
        Move(1);
        if (menu)
        {
            OpenPalette();
        }
    }

    /// <summary>历史开着时的按键（窗口的 PreviewKeyDown 先给这里）。返回 true = 已经处理。</summary>
    public bool HandleKey(KeyRoutedEventArgs e, bool control, bool shift)
    {
        if (_palette.IsOpen)
        {
            return HandlePaletteKey(e, control);
        }

        switch (e.Key)
        {
            case VirtualKey.Up when !control:
                Move(-1);
                return true;
            case VirtualKey.Down when !control:
                Move(1);
                return true;
            case VirtualKey.Enter when !control && !shift:
                if (Selected is { } entry)
                {
                    _retranslate(entry);
                }
                else
                {
                    SystemSound.Beep();
                }

                return true;
            case VirtualKey.Tab when shift && !control:
                SetScope(!_favoritesOnly);
                return true;
            case VirtualKey.Right when !control && Selected is not null && CaretAtEnd:
                OpenPalette();
                return true;
            case VirtualKey.Escape:
                if (_search.Text.Length > 0)
                {
                    _search.Text = string.Empty;
                }
                else
                {
                    _close();
                }

                return true;
            case VirtualKey.K when control:
                OpenPalette();
                return true;
            case VirtualKey.C when control && shift:
                Do(entry => Copy(entry, source: true));
                return true;
            case VirtualKey.C when control && _search.SelectionLength == 0:
                Do(entry => Copy(entry, source: false));
                return true;
            case VirtualKey.D when control:
                Do(ToggleFavorite);
                return true;
            case VirtualKey.Delete when control:
                Do(Delete);
                return true;
            case VirtualKey.Z when control && TranslationHistory.Instance?.CanUndo == true:
                UndoDelete();
                return true;
        }

        return false;
    }

    private bool CaretAtEnd => _search.SelectionLength == 0 && _search.SelectionStart == _search.Text.Length;

    private void Do(Action<TranslationEntry> action)
    {
        if (Selected is { } entry)
        {
            action(entry);
        }
        else
        {
            SystemSound.Beep();
        }
    }

    private void OnSearchChanged()
    {
        if (_quiet)
        {
            return;
        }

        if (_palette.IsOpen)
        {
            _palette.SetFilter(_search.Text);
            return;
        }

        _pages = 1;
        _selectedId = null;
        Refresh(keepSelection: false);
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void SetSearchQuietly(string text)
    {
        _quiet = true;
        _search.Text = text;
        _search.SelectionStart = text.Length;
        _quiet = false;
    }

    private void SetScope(bool favoritesOnly)
    {
        if (favoritesOnly == _favoritesOnly)
        {
            return;
        }

        _favoritesOnly = favoritesOnly;
        _pages = 1;
        _selectedId = null;
        UpdateScope();
        Refresh(keepSelection: false);
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void UpdateScope()
    {
        StyleCapsule(_all, !_favoritesOnly);
        StyleCapsule(_favorites, _favoritesOnly);
    }

    // ---- 列表

    private void Refresh(bool keepSelection)
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return;
        }

        var query = _palette.IsOpen ? _savedQuery : _search.Text;
        _entries = history.Search(query, _favoritesOnly, limit: _pages * PageSize);
        if (!keepSelection || _entries.All(entry => entry.Id != _selectedId))
        {
            _selectedId = _entries.FirstOrDefault()?.Id;
        }

        var times = _entries.Select(entry => DateTimeOffset.FromUnixTimeMilliseconds(entry.CreatedAt).LocalDateTime).ToList();
        _layout = new HistoryListLayout(times, DateTime.Now);
        foreach (var row in _rows.Values)
        {
            _canvas.Children.Remove(row);
        }

        _rows.Clear();
        foreach (var header in _headers)
        {
            _canvas.Children.Remove(header);
        }

        _headers.Clear();
        _hovered = -1;
        foreach (var (title, top) in _layout.Headers)
        {
            var header = Header(title);
            Canvas.SetTop(header, top);
            Canvas.SetLeft(header, SideInset);
            _headers.Add(header);
            _canvas.Children.Add(header);
        }

        ShowEmpty();
        Realize(force: true);
        MoveHighlight(MotionCurve.Instant);
    }

    private void LoadMore()
    {
        if (!HasMore)
        {
            return;
        }

        _pages++;
        Refresh(keepSelection: true);
    }

    private double RowWidth => Math.Max(0, (_listHost.ActualWidth > 0 ? _listHost.ActualWidth : 396) - 2 * SideInset);

    /// <summary>建出可见区附近的行、拿掉远的，按前缀和摆好。</summary>
    private void Realize(bool force = false)
    {
        var width = RowWidth;
        _canvas.Width = width + 2 * SideInset;
        _canvas.Height = _layout.TotalHeight + HistoryListLayout.ScrollMargin;
        var from = _scroll.VerticalOffset - Overscan;
        var to = _scroll.VerticalOffset + Math.Max(_scroll.ViewportHeight, 1) + Overscan;
        foreach (var index in _rows.Keys.Where(index => _layout.Top(index) + HistoryListLayout.RowHeight < from || _layout.Top(index) > to).ToList())
        {
            _canvas.Children.Remove(_rows[index]);
            _rows.Remove(index);
        }

        for (var index = 0; index < _entries.Count; index++)
        {
            var top = _layout.Top(index);
            if (top + HistoryListLayout.RowHeight < from || top > to)
            {
                continue;
            }

            if (!_rows.TryGetValue(index, out var row))
            {
                row = Row(index);
                _rows[index] = row;
                _canvas.Children.Add(row);
            }
            else if (!force)
            {
                continue;
            }

            row.Width = width;
            Canvas.SetLeft(row, SideInset);
            Canvas.SetTop(row, top);
        }

        foreach (var header in _headers)
        {
            header.Width = width;
        }

        _highlight.Width = width;
    }

    private Grid Row(int index)
    {
        var entry = _entries[index];
        var row = new Grid
        {
            Height = HistoryListLayout.RowHeight,
            Padding = new Thickness(10, 0, 10, 0),
            ColumnSpacing = 8,
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Background = new SolidColorBrush(Colors.Transparent),
            Tag = entry.Id,
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1 };
        texts.Children.Add(new TextBlock
        {
            Text = OneLine(entry.Source),
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        texts.Children.Add(new TextBlock
        {
            Text = OneLine(entry.Result),
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        var copied = entry.Id == _copiedId;
        meta.Children.Add(new TextBlock
        {
            Text = copied ? "✓ 已复制" : HistoryListLayout.RowTime(DateTimeOffset.FromUnixTimeMilliseconds(entry.CreatedAt).LocalDateTime),
            FontSize = 11,
            Foreground = copied ? new SolidColorBrush(Theme.AccentTextColor) : Theme.TertiaryText(),
        });
        if (entry.Favorite)
        {
            meta.Children.Add(new FontIcon
            {
                Glyph = Glyphs.StarFilled,
                FontSize = 11,
                Foreground = Theme.Brush("Kitty.Favorite", Theme.Argb(255, 0xFF, 0xCC, 0x00)),
            });
        }

        Grid.SetColumn(meta, 1);
        row.Children.Add(texts);
        row.Children.Add(meta);
        AutomationProperties.SetName(row, $"{entry.Source}，译文：{entry.Result}" + (entry.Favorite ? "，已收藏" : string.Empty));

        row.PointerEntered += (_, _) => SetHover(index, true);
        row.PointerExited += (_, _) => SetHover(index, false);
        row.Tapped += (_, args) =>
        {
            args.Handled = true;
            _palette.Close();
            Select(entry.Id, MotionCurve.Glide);
        };
        row.DoubleTapped += (_, args) =>
        {
            args.Handled = true;
            _retranslate(entry);
        };
        row.RightTapped += (_, args) =>
        {
            args.Handled = true;
            Select(entry.Id, MotionCurve.Glide);
            ContextMenu(entry).ShowAt(row, args.GetPosition(row));
        };
        return row;
    }

    /// <summary>悬停底 0.10 s 淡入淡出，选中的那行不画（高亮已经在它下面）。</summary>
    private void SetHover(int index, bool inside)
    {
        if (!inside && _hovered != index)
        {
            return;
        }

        if (_hovered >= 0 && _rows.TryGetValue(_hovered, out var old))
        {
            old.Background = new SolidColorBrush(Colors.Transparent);
        }

        _hovered = inside ? index : -1;
        if (inside && _rows.TryGetValue(index, out var row) && _entries[index].Id != Selected?.Id)
        {
            row.Background = Theme.Brush("Kitty.Fill.Hover", Theme.Argb(0x0A, 0, 0, 0));
        }
    }

    private void Select(string id, MotionCurve curve)
    {
        _selectedId = id;
        if (_hovered >= 0 && _rows.TryGetValue(_hovered, out var hovered))
        {
            hovered.Background = new SolidColorBrush(Colors.Transparent);
        }

        MoveHighlight(curve);
        Reveal();
    }

    /// <summary>↑↓：首尾循环；还有下一页时 ↓ 走过最后一条先取下一页再往下走。</summary>
    private void Move(int offset)
    {
        if (_entries.Count == 0)
        {
            return;
        }

        var current = Math.Max(0, _entries.FindIndex(entry => entry.Id == _selectedId));
        if (offset > 0 && current + offset >= _entries.Count && HasMore)
        {
            LoadMore();
        }

        var next = (current + offset + _entries.Count) % _entries.Count;
        Select(_entries[next].Id, MotionCurve.Snap);
    }

    private void MoveHighlight(MotionCurve curve)
    {
        var index = _entries.FindIndex(entry => entry.Id == Selected?.Id);
        if (index < 0)
        {
            _highlight.Visibility = Visibility.Collapsed;
            return;
        }

        _highlight.Visibility = Visibility.Visible;
        _highlight.Width = RowWidth;
        Canvas.SetLeft(_highlight, SideInset);
        Motion.SlideTo(_highlight, 0, _layout.Top(index), Motion.Reduced ? MotionCurve.Instant : curve);
    }

    private void Reveal()
    {
        var index = _entries.FindIndex(entry => entry.Id == Selected?.Id);
        if (_layout.Reveal(index, _scroll.VerticalOffset, _scroll.ViewportHeight) is { } target)
        {
            _scroll.ChangeView(null, target, null, disableAnimation: true);
            Realize();
        }
    }

    private void ShowEmpty()
    {
        if (_empty is not null)
        {
            _listHost.Children.Remove(_empty);
            _empty = null;
        }

        _scroll.Visibility = _entries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_entries.Count > 0)
        {
            return;
        }

        _empty = _search.Text.Length > 0 && !_palette.IsOpen
            ? EmptyState.Create(Glyphs.Search, "没有匹配的记录", string.Empty)
            : _favoritesOnly
                ? EmptyState.Create(Glyphs.Star, "还没有收藏", "翻译完按 Ctrl+D 收藏，收藏就是生词本")
                : EmptyState.Create(Glyphs.History, "还没有翻译历史", "翻译过的原文和译文会记在这里");
        _listHost.Children.Insert(0, _empty);
    }

    // ---- 动作

    private void Copy(TranslationEntry entry, bool source)
    {
        var text = source ? entry.Source : entry.Result;
        if (!ClipboardWriter.WriteText(text))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
            return;
        }

        // 原文、译文都是本 App 给出的文字：同时记进剪贴板历史。
        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(text);
        _copiedId = entry.Id;
        var tick = ++_copyTick;
        RebuildRow(entry.Id);
        Announce(source ? "已复制原文" : "已复制译文");
        _ = ClearCopiedAsync(tick, entry.Id);
    }

    private async Task ClearCopiedAsync(int tick, string id)
    {
        await Task.Delay(TranslateCoordinator.CopiedHold);
        if (tick == _copyTick)
        {
            _copiedId = null;
            RebuildRow(id);
        }
    }

    private void RebuildRow(string id)
    {
        var index = _entries.FindIndex(entry => entry.Id == id);
        if (index >= 0 && _rows.Remove(index, out var old))
        {
            _canvas.Children.Remove(old);
            Realize(force: true);
        }
    }

    private void ToggleFavorite(TranslationEntry entry)
    {
        // 「收藏」范围里取消收藏会让这行消失：选中挪到下一条。
        if (_favoritesOnly && entry.Favorite)
        {
            MoveSelectionAway(entry);
        }

        TranslationHistory.Instance?.SetFavorite(entry.Id, !entry.Favorite);
        Announce(entry.Favorite ? "已取消收藏" : "已收藏");
    }

    private void Delete(TranslationEntry entry)
    {
        MoveSelectionAway(entry);
        TranslationHistory.Instance?.Delete(entry.Id);
        NoticeHost.Show("已删除", "Ctrl+Z 可以撤销", NoticeTone.Normal, new NoticeAction("撤销", UndoDelete));
    }

    private void UndoDelete()
    {
        if (TranslationHistory.Instance?.Undo() is { } entry)
        {
            _selectedId = entry.Id;
            Refresh(keepSelection: true);
            Reveal();
            Announce("已恢复");
        }
    }

    private void MoveSelectionAway(TranslationEntry entry)
    {
        var index = _entries.FindIndex(item => item.Id == entry.Id);
        if (Selected?.Id != entry.Id || index < 0)
        {
            return;
        }

        var rest = _entries.Where(item => item.Id != entry.Id).ToList();
        _selectedId = rest.Count == 0 ? null : rest[Math.Min(index, rest.Count - 1)].Id;
    }

    /// <summary>一条记录的动作（Ctrl+K 和右键同一份）：单条操作 ｜ 导出（4 种）、清空历史…</summary>
    private List<PaletteItem> Actions(TranslationEntry entry)
    {
        var exports = HistoryMenu.Exports
            .Select(export => new PaletteItem(export.Title, export.FavoritesOnly ? Glyphs.Star : Glyphs.History, 0,
                () => _ = ExportAsync(export.FavoritesOnly, export.Anki)))
            .ToList();
        var items = new List<PaletteItem>
        {
            new("重新翻译", Glyphs.Refresh, 0, () => _retranslate(entry), "Enter"),
            new("复制译文", Glyphs.Copy, 0, () => Copy(entry, source: false), "Ctrl+C"),
            new("复制原文", Glyphs.Copy, 0, () => Copy(entry, source: true), "Ctrl+Shift+C"),
            new(entry.Favorite ? "取消收藏" : "收藏", entry.Favorite ? Glyphs.StarFilled : Glyphs.Star, 0,
                () => ToggleFavorite(entry), "Ctrl+D"),
            new("删除", Glyphs.Delete, 0, () => Delete(entry), "Ctrl+Delete", Danger: true),
            new("导出", Glyphs.Save, 1, null, Submenu: exports),
        };
        var (total, favorites) = TranslationHistory.Instance?.Counts() ?? (0, 0);
        if (total > favorites)
        {
            items.Add(new PaletteItem("清空历史…", Glyphs.Delete, 1, () => _ = ClearAsync(), Danger: true));
        }

        return items;
    }

    private async Task ExportAsync(bool favoritesOnly, bool anki)
    {
        // 文件对话框是另一扇窗：开着时浮窗别因为失去激活收起来。
        _holdOpen(true);
        try
        {
            await HistoryMenu.ExportAsync(_owner(), favoritesOnly, anki);
        }
        finally
        {
            _holdOpen(false);
        }
    }

    private async Task ClearAsync()
    {
        if (XamlRoot is { } root)
        {
            await HistoryMenu.ConfirmClearAsync(root);
        }
    }

    /// <summary>Ctrl+K / →：没有选中的记录时不打开；开着再按是关。</summary>
    private void OpenPalette()
    {
        if (_palette.IsOpen)
        {
            _palette.Close();
            return;
        }

        if (Selected is not { } entry)
        {
            return;
        }

        _savedQuery = _search.Text;
        SetSearchQuietly(string.Empty);
        _palette.Open("actions", Actions(entry));
        _search.PlaceholderText = "搜索操作";
        FocusSearch();
    }

    private void OnPaletteClosed()
    {
        SetSearchQuietly(_savedQuery);
        _savedQuery = string.Empty;
        _search.PlaceholderText = "搜索原文或译文";
        FocusSearch();
    }

    /// <summary>菜单开着时的按键（同启动器）：↑↓ 选、Enter 执行、→ 进子列表、过滤词为空时 ← / Esc 回上一级再关。</summary>
    private bool HandlePaletteKey(KeyRoutedEventArgs e, bool control)
    {
        switch (e.Key)
        {
            case VirtualKey.Escape:
            case VirtualKey.Left when _search.Text.Length == 0:
                if (!_palette.Back())
                {
                    _palette.Close();
                }

                return true;
            case VirtualKey.Up:
                _palette.Move(-1);
                return true;
            case VirtualKey.Down:
                _palette.Move(1);
                return true;
            case VirtualKey.Enter:
                _palette.Activate();
                return true;
            case VirtualKey.Right when CaretAtEnd:
                _palette.EnterSelected();
                return true;
            case VirtualKey.K when control:
                _palette.Close();
                return true;
        }

        return false;
    }

    /// <summary>右键：系统菜单，条目和 Ctrl+K 同一份（分节是分隔线、子菜单是子菜单，不写键位）。</summary>
    private MenuFlyout ContextMenu(TranslationEntry entry)
    {
        var menu = new MenuFlyout();
        var section = 0;
        foreach (var item in Actions(entry))
        {
            if (item.Section != section)
            {
                section = item.Section;
                menu.Items.Add(new MenuFlyoutSeparator());
            }

            if (item.Submenu is { } submenu)
            {
                var sub = new MenuFlyoutSubItem { Text = item.Title };
                foreach (var child in submenu)
                {
                    sub.Items.Add(MenuItem(child));
                }

                menu.Items.Add(sub);
            }
            else
            {
                menu.Items.Add(MenuItem(item));
            }
        }

        return menu;
    }

    private static MenuFlyoutItem MenuItem(PaletteItem item)
    {
        var menuItem = new MenuFlyoutItem { Text = item.Title };
        if (item.Run is { } run)
        {
            menuItem.Click += (_, _) => run();
        }

        if (item.Danger)
        {
            menuItem.Foreground = Theme.Critical();
        }

        return menuItem;
    }

    // ---- 小零件

    private void Announce(string text)
    {
        var peer = Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_search)
                   ?? Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(_search);
        peer?.RaiseNotificationEvent(
            Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.ActionCompleted,
            Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.ImportantMostRecent,
            text,
            "translate.history");
    }

    /// <summary>范围胶囊（22 高）：选中的强调色 0.16 底 + 强调色字，没选中的 secondary 字。</summary>
    private static Button ScopeCapsule(string title, Action select)
    {
        var button = new Button
        {
            Content = title,
            Height = 22,
            MinHeight = 0,
            MinWidth = 0,
            Padding = new Thickness(10, 0, 10, 0),
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            CornerRadius = new CornerRadius(11),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            IsTabStop = false,
        };
        button.Click += (_, _) => select();
        AutomationProperties.SetName(button, "范围：" + title);
        return button;
    }

    private static void StyleCapsule(Button button, bool on)
    {
        var accent = Theme.AccentColor;
        button.Background = on
            ? new SolidColorBrush(Theme.Argb(41, accent.R, accent.G, accent.B))
            : new SolidColorBrush(Colors.Transparent);
        button.Foreground = on ? new SolidColorBrush(Theme.AccentTextColor) : Theme.SecondaryText();
    }

    /// <summary>分组标题：24 高、11 semibold tertiary，缩进 10（行内边距）、贴底留 2。</summary>
    private static FrameworkElement Header(string title)
    {
        var host = new Grid { Height = HistoryListLayout.HeaderHeight, IsHitTestVisible = false };
        host.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.TertiaryText(),
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(10, 0, 0, 2),
        });
        AutomationProperties.SetHeadingLevel(host, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        AutomationProperties.SetName(host, title);
        return host;
    }

    private static string OneLine(string text)
    {
        var line = text.ReplaceLineEndings(" ").Trim();
        return line.Length <= 200 ? line : line[..200];
    }
}
