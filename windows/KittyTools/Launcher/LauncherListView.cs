// 启动器的列表（PLAN-v9-launcher D1，照 mac LauncherPanelView.list + 剪贴板 ClipListView 的做法）：一个 ScrollViewer 里一块 Canvas，
// 按 Core 的 LauncherListLayout（前缀和）摆分组标题和每一行，只建可见区上下 320 以内的行；一块中性高亮按前缀和定位、在行间滑动
// （键盘 Snap、连发和刷新不动画、点选 Glide）。焦点一直在面板的搜索框：这里的东西都不进 Tab 顺序，点击、右键都转成事件交给面板。
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace KittyTools;

internal sealed partial class LauncherListView : Grid
{
    private const double Inset = LauncherListLayout.Inset;
    private const double Overscan = 320;

    private readonly ScrollViewer _scroll;
    private readonly Canvas _canvas;
    private readonly Border _highlight;
    private readonly Dictionary<int, LauncherRowView> _rows = new();
    private readonly List<FrameworkElement> _headers = new();
    private LauncherListLayout _layout = new(Array.Empty<double>(), Array.Empty<int>());
    private Func<int, LauncherRowView> _build = _ => throw new InvalidOperationException();
    private int _selected = -1;
    private int _lastTapped = -1;
    private bool _shortcutsShown;

    public LauncherListView()
    {
        _canvas = new Canvas { VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left };
        _scroll = new ScrollViewer
        {
            Content = _canvas,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalContentAlignment = VerticalAlignment.Top,
            IsTabStop = false,
        };
        _highlight = new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = Theme.Brush("Kitty.Fill.Selected", Color.FromArgb(0x12, 0, 0, 0)),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        _canvas.Children.Add(_highlight);
        Children.Add(_scroll);

        _scroll.ViewChanged += (_, _) => Realize();
        SizeChanged += (_, args) =>
        {
            Clip = new RectangleGeometry { Rect = new Rect(0, 0, args.NewSize.Width, args.NewSize.Height) };
            Realize(force: true);
        };
    }

    /// <summary>单击一行（选中）。</summary>
    public event Action<int>? ItemTapped;

    /// <summary>双击：传的是第一下点中的那一行。</summary>
    public event Action<int>? ItemDoubleTapped;

    public event Action<int, FrameworkElement, Point>? ItemRightTapped;

    public LauncherListLayout Layout => _layout;

    /// <summary>换一批结果：重算前缀和、重建可见区的行。build 按行号建一行；groupTitles 按「排在第几行前面」给分组标题。</summary>
    public void SetItems(
        LauncherListLayout layout, IReadOnlyDictionary<int, string> groupTitles, int selected, Func<int, LauncherRowView> build)
    {
        _layout = layout;
        _build = build;
        _selected = selected;
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
        foreach (var groupRow in layout.GroupRows)
        {
            if (!groupTitles.TryGetValue(groupRow, out var title))
            {
                continue;
            }

            var header = Header(title);
            Canvas.SetTop(header, Inset + layout.GroupTop(groupRow));
            Canvas.SetLeft(header, Inset);
            _headers.Add(header);
            _canvas.Children.Add(header);
        }

        Realize(force: true);
        MoveHighlight(MotionCurve.Instant);
    }

    /// <summary>换选中（↑↓、点选）：挪高亮、改行的选中状态。</summary>
    public void SetSelection(int selected, MotionCurve curve)
    {
        if (_rows.TryGetValue(_selected, out var old))
        {
            old.SetSelected(false);
        }

        _selected = selected;
        if (_rows.TryGetValue(selected, out var row))
        {
            row.SetSelected(true);
        }

        MoveHighlight(curve);
    }

    /// <summary>选中跟随滚动：要露出第 row 行（是一组第一行时连分组标题一起）。</summary>
    public void Reveal(int row)
    {
        var viewport = _scroll.ViewportHeight > 0 ? _scroll.ViewportHeight : ActualHeight;
        if (_layout.Reveal(row, _scroll.VerticalOffset, viewport) is { } target)
        {
            _scroll.UpdateLayout();
            _scroll.ChangeView(null, target, null, disableAnimation: true);
            Realize(offset: target);
        }
    }

    public void ScrollToTop()
    {
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
        Realize(offset: 0);
    }

    /// <summary>某一行现在建好的视图（换副标题、键帽用）；不在可见区附近时 null。</summary>
    public LauncherRowView? RowAt(int row) => _rows.TryGetValue(row, out var view) ? view : null;

    /// <summary>按住 Ctrl 150 ms：前九行的种类换成键帽；之后建出来的行跟着。</summary>
    public void SetShortcutsShown(bool shown)
    {
        _shortcutsShown = shown;
        foreach (var row in _rows.Values)
        {
            row.SetShortcutShown(shown);
        }
    }

    private double RowWidth => Math.Max(0, (ActualWidth > 0 ? ActualWidth : 720) - 2 * Inset);

    /// <summary>建出可见区附近的行、拿掉远的，按前缀和摆好。</summary>
    private void Realize(bool force = false, double? offset = null)
    {
        var top = offset ?? _scroll.VerticalOffset;
        var viewport = Math.Max(_scroll.ViewportHeight > 0 ? _scroll.ViewportHeight : ActualHeight, 1);
        var width = RowWidth;
        _canvas.Height = _layout.TotalHeight + 2 * Inset;
        _canvas.Width = width + 2 * Inset;
        var from = top - Inset - Overscan;
        var to = top - Inset + viewport + Overscan;
        foreach (var index in _rows.Keys.Where(index => _layout.Top(index) + _layout.Height(index) < from || _layout.Top(index) > to).ToList())
        {
            _canvas.Children.Remove(_rows[index]);
            _rows.Remove(index);
        }

        for (var index = 0; index < _layout.Count; index++)
        {
            var rowTop = _layout.Top(index);
            if (rowTop + _layout.Height(index) < from || rowTop > to)
            {
                continue;
            }

            if (!_rows.TryGetValue(index, out var row))
            {
                row = _build(index);
                Hook(row);
                row.SetSelected(index == _selected);
                if (_shortcutsShown)
                {
                    row.SetShortcutShown(true);
                }

                _rows[index] = row;
                _canvas.Children.Add(row);
            }
            else if (!force)
            {
                continue;
            }

            row.Width = width;
            Canvas.SetLeft(row, Inset);
            Canvas.SetTop(row, Inset + rowTop);
        }

        foreach (var header in _headers)
        {
            header.Width = width;
        }

        _highlight.Width = width;
    }

    private void Hook(LauncherRowView row)
    {
        var index = row.Index;
        row.PointerEntered += (_, _) => row.SetHovered(true);
        row.PointerExited += (_, _) => row.SetHovered(false);
        row.PointerCanceled += (_, _) => row.SetHovered(false);
        row.Tapped += (_, args) =>
        {
            args.Handled = true;
            _lastTapped = index;
            ItemTapped?.Invoke(index);
        };
        row.DoubleTapped += (_, args) =>
        {
            args.Handled = true;
            ItemDoubleTapped?.Invoke(_lastTapped >= 0 ? _lastTapped : index);
        };
        row.RightTapped += (_, args) =>
        {
            args.Handled = true;
            ItemRightTapped?.Invoke(index, row, args.GetPosition(row));
        };
    }

    private void MoveHighlight(MotionCurve curve)
    {
        if (_selected < 0 || _selected >= _layout.Count)
        {
            _highlight.Visibility = Visibility.Collapsed;
            return;
        }

        _highlight.Height = _layout.Height(_selected);
        _highlight.Width = RowWidth;
        _highlight.Visibility = Visibility.Visible;
        Canvas.SetLeft(_highlight, Inset);
        Motion.SlideTo(_highlight, 0, Inset + _layout.Top(_selected), Motion.Reduced ? MotionCurve.Instant : curve);
    }

    /// <summary>分组标题（mac groupHeader）：28 高，12 semibold tertiary，缩进 10 = 行内边距，贴底留 2。</summary>
    private static FrameworkElement Header(string title)
    {
        var text = new TextBlock
        {
            Text = title,
            FontSize = Theme.FontSize("Kitty.FontSize.GroupHeader"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(10, 0, 0, 2),
        };
        var host = new Grid { Height = LauncherListLayout.GroupHeight, IsHitTestVisible = false };
        host.Children.Add(text);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(host, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(host, title);
        return host;
    }
}
