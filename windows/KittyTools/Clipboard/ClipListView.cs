// 剪贴板的列表（PLAN-v9-clipboard D1，照 mac ClipboardPanelView 的 ListLayout）：一个 ScrollViewer 里一块 Canvas，
// 按 Core 的 ClipListLayout（前缀和）摆每一项，只实例化可见区上下 320 以内的；选中行下面那块高亮就是透镜的底
// （盖住行头 + 正文 + 元信息），透镜的内容由面板建好交进来；吸顶的分组标题另画在滚动区上面，下一组顶上来时把它推上去。
// 焦点一直在面板的搜索框：这里的东西都不进 Tab 顺序，点击、拖动、右键都转成事件交给面板。
using KittyTools.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace KittyTools;

internal sealed partial class ClipListView : Grid
{
    private const double Inset = ClipListLayout.Inset;

    private readonly ScrollViewer _scroll;
    private readonly Canvas _canvas;
    private readonly Border _highlight;
    private readonly Border _stickyHost;
    private readonly Dictionary<int, FrameworkElement> _realized = new();
    private ClipListLayout _layout = new(Array.Empty<long>(), -1, 0);
    private IReadOnlyList<ClipEntry> _items = Array.Empty<ClipEntry>();
    private IReadOnlyList<long> _days = Array.Empty<long>();
    private ClipRowContext _context = new(string.Empty, false, false, false, 1);
    private IReadOnlySet<long>? _checked;
    private bool _newSnippetRow;
    private int _selected = -1;
    private FrameworkElement? _lens;
    private double _lensHeight;
    private int _stickySection = -2;
    private int _lastTapped = -1;

    public ClipListView()
    {
        _canvas = new Canvas { VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left };
        _scroll = new ScrollViewer
        {
            Content = _canvas,
            // 不露滚动条（0.1.0 用户反馈），滚轮、方向键照样滚。
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalContentAlignment = VerticalAlignment.Top,
            IsTabStop = false,
        };
        _highlight = new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = Theme.Brush("Kitty.Fill.Selected", Windows.UI.Color.FromArgb(0x12, 0, 0, 0)),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        _canvas.Children.Add(_highlight);
        _stickyHost = new Border
        {
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(Inset, 0, Inset, 0),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        Children.Add(_scroll);
        Children.Add(_stickyHost);

        _scroll.ViewChanged += (_, _) => Realize();
        SizeChanged += (_, args) =>
        {
            Clip = new RectangleGeometry { Rect = new Rect(0, 0, args.NewSize.Width, args.NewSize.Height) };
            Realize(force: true);
        };
    }

    /// <summary>单击（带当时的修饰键）。</summary>
    public event Action<int, VirtualKeyModifiers>? ItemTapped;

    /// <summary>双击：传的是第一下点中的那条（透镜收放会让行位移，第二下可能落到别的行上）。</summary>
    public event Action<int>? ItemDoubleTapped;

    public event Action<int, FrameworkElement, Point>? ItemRightTapped;

    public event Action<int, DragStartingEventArgs>? ItemDragStarting;

    public event Action? NewSnippetTapped;

    public ClipListLayout Layout => _layout;

    public double VerticalOffset => _scroll.VerticalOffset;

    public double ViewportHeight => _scroll.ViewportHeight;

    /// <summary>换一批条目（搜索、筛选、增删）：重算前缀和、重建可见区的行。</summary>
    public void SetItems(
        IReadOnlyList<ClipEntry> items, IReadOnlyList<long> days, bool newSnippetRow, ClipRowContext context,
        IReadOnlySet<long>? checkedIds, int selected, FrameworkElement? lens, double lensHeight)
    {
        _items = items;
        _days = days;
        _newSnippetRow = newSnippetRow;
        _context = context;
        _checked = checkedIds;
        _selected = selected;
        SetLensElement(lens, lensHeight);
        _layout = new ClipListLayout(days, lens is null ? -1 : selected, lensHeight, newSnippetRow);
        ClearRealized();
        _stickySection = -2;
        Realize(force: true);
        MoveHighlight(MotionCurve.Instant);
    }

    /// <summary>换选中 / 透镜（↑↓、点选）：只重算前缀和、挪已经建好的行。</summary>
    public void SetSelection(int selected, FrameworkElement? lens, double lensHeight, MotionCurve curve)
    {
        if (_selected >= 0 && _realized.TryGetValue(_layoutEntry(_selected), out var old) && old is ClipRowView oldRow)
        {
            oldRow.SetSelected(false);
        }

        _selected = selected;
        SetLensElement(lens, lensHeight);
        _layout = new ClipListLayout(_days, lens is null ? -1 : selected, lensHeight, _newSnippetRow);
        Realize(force: true);
        MoveHighlight(curve);
        if (lens is not null && curve != MotionCurve.Instant)
        {
            // 透镜换内容：淡入 + 往下落 4（settle）。
            Motion.Entrance(lens, MotionCurve.Settle, rise: -4);
        }
    }

    /// <summary>多选勾选变了：只改已经建好的行。null = 不在多选状态。</summary>
    public void SetChecked(IReadOnlySet<long>? checkedIds)
    {
        var modeChanged = (_checked is null) != (checkedIds is null);
        _checked = checkedIds;
        _context = _context with { Multi = checkedIds is not null };
        foreach (var element in _realized.Values)
        {
            if (element is ClipRowView row)
            {
                row.SetChecked(checkedIds is null ? null : checkedIds.Contains(row.Entry.Id));
            }
        }

        if (modeChanged)
        {
            MoveHighlight(MotionCurve.Instant);
        }
    }

    public void SetKeyHints(bool show)
    {
        _context = _context with { ShowsKeyHints = show };
        foreach (var element in _realized.Values)
        {
            (element as ClipRowView)?.SetKeyHint(show);
        }
    }

    /// <summary>条目被挡住时滚过去（往上让出吸顶标题，往下留内缩）。</summary>
    public void Reveal(int item)
    {
        if (_layout.Reveal(item, _scroll.VerticalOffset, _scroll.ViewportHeight > 0 ? _scroll.ViewportHeight : ActualHeight) is { } target)
        {
            // Canvas 刚因为透镜变高：先排一次，不然 ChangeView 按旧的内容高度夹住，透镜下半截露不出来。
            _scroll.UpdateLayout();
            _scroll.ChangeView(null, target, null, disableAnimation: true);
            Realize(offset: target);
            if (target > _scroll.ScrollableHeight)
            {
                // 滚动区还没认新的内容高度（被夹住了）：等这一轮布局完再滚一次。
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
                {
                    if (item < _items.Count && _layout.Reveal(item, _scroll.VerticalOffset, _scroll.ViewportHeight) is { } again)
                    {
                        _scroll.ChangeView(null, again, null, disableAnimation: true);
                        Realize(offset: again);
                    }
                });
            }
        }
    }

    public void ScrollToTop() => ScrollTo(0);

    public void ScrollTo(double offset)
    {
        _scroll.ChangeView(null, offset, null, disableAnimation: true);
        Realize(offset: offset);
    }

    /// <summary>某一条现在建好的行（Ctrl+K 锚点、探针用）；不在可见区附近时 null。</summary>
    public FrameworkElement? RowElement(int item)
        => item >= 0 && item < _items.Count && _realized.TryGetValue(_layout.EntryOfItem(item), out var element) ? element : null;

    private int _layoutEntry(int item) => item >= 0 && item < _items.Count ? _layout.EntryOfItem(item) : -1;

    private void SetLensElement(FrameworkElement? lens, double lensHeight)
    {
        if (!ReferenceEquals(_lens, lens))
        {
            if (_lens is not null)
            {
                _canvas.Children.Remove(_lens);
            }

            _lens = lens;
            if (lens is not null)
            {
                _canvas.Children.Add(lens);
            }
        }

        _lensHeight = lensHeight;
    }

    private void ClearRealized()
    {
        foreach (var element in _realized.Values)
        {
            _canvas.Children.Remove(element);
        }

        _realized.Clear();
    }

    private double RowWidth => Math.Max(0, (ActualWidth > 0 ? ActualWidth : 720) - 2 * Inset);

    /// <summary>建出可见区附近的项、拿掉远的，按前缀和摆好；顺带更新吸顶标题。</summary>
    private void Realize(bool force = false, double? offset = null)
    {
        var top = offset ?? _scroll.VerticalOffset;
        var viewport = _scroll.ViewportHeight > 0 ? _scroll.ViewportHeight : ActualHeight;
        _canvas.Height = _layout.TotalHeight + 2 * Inset;
        _canvas.Width = RowWidth + 2 * Inset;
        var (first, end) = _layout.Window(top, Math.Max(viewport, 1));
        foreach (var index in _realized.Keys.Where(index => index < first || index >= end).ToList())
        {
            _canvas.Children.Remove(_realized[index]);
            _realized.Remove(index);
        }

        var width = RowWidth;
        for (var index = first; index < end; index++)
        {
            if (!_realized.TryGetValue(index, out var element))
            {
                element = Build(index);
                _realized[index] = element;
                _canvas.Children.Add(element);
            }
            else if (!force)
            {
                continue;
            }

            element.Width = width;
            Canvas.SetLeft(element, Inset);
            Canvas.SetTop(element, Inset + _layout.Top(index));
            if (element is ClipRowView row)
            {
                row.SetSelected(row.Index == _selected);
            }
        }

        if (_lens is not null && _layout.LensItem >= 0)
        {
            _lens.Width = width;
            _lens.Height = _layout.LensHeight - ClipLens.Head;
            Canvas.SetLeft(_lens, Inset);
            Canvas.SetTop(_lens, Inset + _layout.RowTop(_layout.LensItem) + ClipLens.Head);
            Canvas.SetZIndex(_lens, 1);
        }

        _highlight.Width = width;
        UpdateSticky(top);
    }

    private FrameworkElement Build(int index)
    {
        var entry = _layout.Entries[index];
        switch (entry.Kind)
        {
            case ClipListEntryKind.NewSnippet:
            {
                var row = ClipHeaderView.NewSnippetRow();
                row.Tapped += (_, args) =>
                {
                    args.Handled = true;
                    NewSnippetTapped?.Invoke();
                };
                return row;
            }

            case ClipListEntryKind.Header:
            {
                var first = FirstItemOf(entry.Section);
                return ClipHeaderView.Create(
                    ClipRowView.DateLabel(_items[first].CopiedAt), _layout.SectionCounts[entry.Section], sticky: false);
            }

            default:
            {
                var item = entry.Item;
                var row = new ClipRowView(_items[item], item, _context)
                {
                    CanDrag = true,
                    IsTabStop = false,
                };
                row.SetChecked(_checked is null ? null : _checked.Contains(_items[item].Id));
                row.SetSelected(item == _selected);
                row.PointerEntered += (_, _) => row.SetHovered(true);
                row.PointerExited += (_, _) => row.SetHovered(false);
                row.PointerCanceled += (_, _) => row.SetHovered(false);
                row.Tapped += (_, args) =>
                {
                    args.Handled = true;
                    _lastTapped = item;
                    ItemTapped?.Invoke(item, Modifiers());
                };
                row.DoubleTapped += (_, args) =>
                {
                    args.Handled = true;
                    ItemDoubleTapped?.Invoke(_lastTapped >= 0 ? _lastTapped : item);
                };
                row.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    ItemRightTapped?.Invoke(item, row, args.GetPosition(row));
                };
                row.DragStarting += (_, args) => ItemDragStarting?.Invoke(item, args);
                return row;
            }
        }
    }

    private int FirstItemOf(int section)
    {
        for (var index = 0; index < _layout.Entries.Count; index++)
        {
            var entry = _layout.Entries[index];
            if (entry.Kind == ClipListEntryKind.Row && entry.Section == section)
            {
                return entry.Item;
            }
        }

        return 0;
    }

    /// <summary>高亮 = 透镜的底：选中行的顶、行头 + 透镜的高；多选时（透镜收起）只盖行头。</summary>
    private void MoveHighlight(MotionCurve curve)
    {
        if (_selected < 0 || _selected >= _items.Count)
        {
            _highlight.Visibility = Visibility.Collapsed;
            return;
        }

        _highlight.Height = _layout.RowHeightOf(_selected);
        _highlight.Width = RowWidth;
        _highlight.Visibility = Visibility.Visible;
        Canvas.SetLeft(_highlight, Inset);
        Motion.SlideTo(_highlight, 0, Inset + _layout.RowTop(_selected), curve);
    }

    private void UpdateSticky(double offset)
    {
        var (section, y) = _layout.Sticky(offset);
        if (section < 0)
        {
            _stickyHost.Visibility = Visibility.Collapsed;
            _stickySection = -1;
            return;
        }

        if (section != _stickySection)
        {
            _stickySection = section;
            _stickyHost.Child = ClipHeaderView.Create(
                ClipRowView.DateLabel(_items[FirstItemOf(section)].CopiedAt), _layout.SectionCounts[section], sticky: true);
        }

        _stickyHost.Visibility = Visibility.Visible;
        _stickyHost.Margin = new Thickness(Inset, Inset + y - offset, Inset, 0);
    }

    private static VirtualKeyModifiers Modifiers()
    {
        var modifiers = VirtualKeyModifiers.None;
        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down))
        {
            modifiers |= VirtualKeyModifiers.Control;
        }

        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down))
        {
            modifiers |= VirtualKeyModifiers.Shift;
        }

        return modifiers;
    }
}
