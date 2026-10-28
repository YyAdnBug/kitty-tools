// 剪贴板面板里浮起的菜单（照 mac Shell/ActionMenu.swift）：Tab 的筛选面板和 Ctrl+K 的操作面板都是它；启动器的 Ctrl+K 也用它（PLAN-v9-launcher D2）。
// 画在面板自己里面（不是系统菜单：焦点一直留在搜索框，搜索框这时用来过滤条目）。行 28：图标 16 + 名字 + 右边的键位，
// 已生效 / 当前所在的打品牌粉 ✓，危险项用危险色，节和节之间一条发丝线；有子列表的行尾一个 ›，进去后顶上一行「‹ 上一级」。
// ↑↓ 选、Enter 执行（子列表行是进去）、→ 进子列表、过滤词为空时 ← 回上一级；鼠标悬停选中、点击执行。
using KittyTools.Core;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools;

/// <summary>菜单里的一项。Submenu 不为空时是「进去」；Run 为空的是不能点的说明行。</summary>
internal sealed record PaletteItem(
    string Title,
    string Glyph,
    int Section,
    Action? Run,
    string? Shortcut = null,
    bool Checked = false,
    bool Danger = false,
    IReadOnlyList<PaletteItem>? Submenu = null,
    string? Detail = null);

internal sealed partial class ClipPalette : Grid
{
    public const double RowHeight = 28;

    /// <summary>最多露出 8.5 行（看得出下面还有）。</summary>
    public const double MaxListHeight = RowHeight * 8.5;

    private readonly StackPanel _rows = new();
    private readonly ScrollViewer _scroll;
    private IReadOnlyList<PaletteItem> _root = Array.Empty<PaletteItem>();
    private PaletteItem? _parent;
    private List<PaletteItem> _shown = new();
    /// <summary>当前这一级每一项的行（下标同 _shown）：悬停 / ↑↓ 只换底色，不重建，免得按下和松开落在两个不同的元素上。</summary>
    private readonly List<Grid> _rowViews = new();
    private string _filter = string.Empty;
    private int _selected;

    public ClipPalette()
    {
        Width = 300;
        Padding = new Thickness(6);
        CornerRadius = Theme.Corner("Kitty.Corner.Card");
        Background = Theme.Brush("Kitty.CardSolid", Color.FromArgb(255, 251, 251, 251));
        BorderBrush = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0));
        BorderThickness = new Thickness(1);
        Visibility = Visibility.Collapsed;
        // 不用 ThemeShadow + Translation Z：菜单浮在列表上时它可能让点击落到后面的条目上（2026-10-28 用户报点菜单穿透）；
        // 边上一条发丝线就分得开层次。
        _scroll = new ScrollViewer
        {
            Content = _rows,
            MaxHeight = MaxListHeight,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            IsTabStop = false,
        };
        Children.Add(_scroll);
        AutomationProperties.SetName(this, "菜单");
        Scrim.Tapped += (_, args) =>
        {
            args.Handled = true;
            Close();
        };
        Scrim.RightTapped += (_, args) =>
        {
            args.Handled = true;
            Close();
        };
    }

    public bool IsOpen => Visibility == Visibility.Visible;

    /// <summary>
    /// 菜单开着时垫在菜单和列表之间的透明层（宿主把它放在菜单下面、盖满列表区）：点到菜单外面只关菜单，
    /// 不落到后面的条目上（mac：同系统菜单；2026-10-28 用户报剪贴板的操作菜单点击穿透）。开关由菜单自己管。
    /// </summary>
    public Grid Scrim { get; } = new()
    {
        Background = new SolidColorBrush(Colors.Transparent),
        Visibility = Visibility.Collapsed,
    };

    /// <summary>在子列表里（← / Esc 先回第一级）。</summary>
    public bool InSubmenu => _parent is not null;

    /// <summary>这一次是哪种菜单（"filter" / "actions" / "groups"）。</summary>
    public string Kind { get; private set; } = string.Empty;

    public event Action? Closed;

    public void Open(string kind, IReadOnlyList<PaletteItem> items, string? enterSubmenuTitle = null)
    {
        Kind = kind;
        _root = items;
        _parent = enterSubmenuTitle is null ? null : items.FirstOrDefault(item => item.Title == enterSubmenuTitle && item.Submenu is not null);
        _filter = string.Empty;
        _selected = 0;
        Visibility = Visibility.Visible;
        Scrim.Visibility = Visibility.Visible;
        Render();
        Motion.Entrance(this, MotionCurve.Settle, rise: Kind == "filter" ? -6 : 6);
    }

    /// <summary>条目变了（比如收藏夹多了一个）：照现在这一级重画，选中的位置不动。</summary>
    public void Replace(IReadOnlyList<PaletteItem> items)
    {
        var parentTitle = _parent?.Title;
        _root = items;
        _parent = parentTitle is null ? null : items.FirstOrDefault(item => item.Title == parentTitle && item.Submenu is not null);
        Render();
    }

    public void Close()
    {
        if (!IsOpen)
        {
            return;
        }

        Visibility = Visibility.Collapsed;
        Scrim.Visibility = Visibility.Collapsed;
        _parent = null;
        Closed?.Invoke();
    }

    /// <summary>搜索框里的字（菜单开着时它是过滤词）；按名字和拼音首字母、全拼过滤当前这一级。</summary>
    public void SetFilter(string text)
    {
        _filter = text.Trim();
        _selected = 0;
        Render();
    }

    public void Move(int delta)
    {
        var count = _shown.Count;
        if (count == 0)
        {
            return;
        }

        var next = _selected;
        for (var step = 0; step < count; step++)
        {
            next = (next + delta + count) % count;
            if (_shown[next].Run is not null || _shown[next].Submenu is not null)
            {
                break;
            }
        }

        _selected = next;
        ApplySelection(bringIntoView: true);
    }

    /// <summary>Enter：执行选中的（子列表行是进去）。返回有没有执行一个动作（执行了菜单自己关掉）。</summary>
    public bool Activate()
    {
        if (_selected < 0 || _selected >= _shown.Count)
        {
            return false;
        }

        var item = _shown[_selected];
        if (item.Submenu is not null)
        {
            Enter(item);
            return false;
        }

        if (item.Run is not { } run)
        {
            return false;
        }

        Close();
        run();
        return true;
    }

    /// <summary>→：选中行有子列表就进去。</summary>
    public bool EnterSelected()
    {
        if (_selected >= 0 && _selected < _shown.Count && _shown[_selected].Submenu is not null)
        {
            Enter(_shown[_selected]);
            return true;
        }

        return false;
    }

    /// <summary>← / Esc：从子列表回第一级，选中进去的那一行。</summary>
    public bool Back()
    {
        if (_parent is not { } parent)
        {
            return false;
        }

        _parent = null;
        _filter = string.Empty;
        FilterReset?.Invoke();
        Render();
        _selected = Math.Max(0, _shown.IndexOf(parent));
        Render();
        return true;
    }

    /// <summary>进出子列表时过滤词清空（搜索框跟着清）。</summary>
    public event Action? FilterReset;

    private void Enter(PaletteItem item)
    {
        _parent = item;
        _filter = string.Empty;
        _selected = 0;
        FilterReset?.Invoke();
        Render();
    }

    private void Render()
    {
        var level = _parent?.Submenu ?? _root;
        _shown = level.Where(item => Search.MatchesTitle(item.Title, _filter)).ToList();
        if (_selected >= _shown.Count)
        {
            _selected = Math.Max(0, _shown.Count - 1);
        }

        if (_shown.Count > 0 && _shown[_selected].Run is null && _shown[_selected].Submenu is null)
        {
            _selected = Math.Max(0, _shown.FindIndex(item => item.Run is not null || item.Submenu is not null));
        }

        _rows.Children.Clear();
        _rowViews.Clear();
        if (_parent is { } parent)
        {
            var back = Row(new PaletteItem(parent.Title, Glyphs.ChevronLeft, -1, null), selected: false, header: true);
            back.Tapped += (_, args) =>
            {
                args.Handled = true;
                Back();
            };
            _rows.Children.Add(back);
        }

        var lastSection = int.MinValue;
        for (var index = 0; index < _shown.Count; index++)
        {
            var item = _shown[index];
            if (lastSection != int.MinValue && item.Section != lastSection && _filter.Length == 0)
            {
                _rows.Children.Add(new Border
                {
                    Height = 1,
                    Margin = new Thickness(8, 4, 8, 4),
                    Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
                });
            }

            lastSection = item.Section;
            var row = Row(item, index == _selected, header: false);
            var at = index;
            row.PointerEntered += (_, _) =>
            {
                if (_selected != at)
                {
                    _selected = at;
                    ApplySelection(bringIntoView: false);
                }
            };
            row.Tapped += (_, args) =>
            {
                args.Handled = true;
                _selected = at;
                Activate();
            };
            _rows.Children.Add(row);
            _rowViews.Add(row);
        }

        if (_shown.Count == 0)
        {
            _rows.Children.Add(new TextBlock
            {
                Text = "没有匹配的条目",
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                Foreground = Theme.SecondaryText(),
                Margin = new Thickness(10, 6, 10, 6),
            });
        }
    }

    /// <summary>选中的那行换成 Fill.Selected，其余透明（读屏状态跟着换）。</summary>
    private void ApplySelection(bool bringIntoView)
    {
        for (var index = 0; index < _rowViews.Count; index++)
        {
            var selected = index == _selected;
            _rowViews[index].Background = selected
                ? Theme.Brush("Kitty.Fill.Selected", Color.FromArgb(18, 0, 0, 0))
                : new SolidColorBrush(Colors.Transparent);
            AutomationProperties.SetItemStatus(_rowViews[index], selected ? "已选中" : string.Empty);
        }

        if (bringIntoView && _selected >= 0 && _selected < _rowViews.Count)
        {
            _rowViews[_selected].StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        }
    }

    private static Grid Row(PaletteItem item, bool selected, bool header)
    {
        var enabled = item.Run is not null || item.Submenu is not null || header;
        var grid = new Grid
        {
            Height = RowHeight,
            Padding = new Thickness(8, 0, 8, 0),
            ColumnSpacing = 8,
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = selected ? Theme.Brush("Kitty.Fill.Selected", Color.FromArgb(18, 0, 0, 0)) : new SolidColorBrush(Colors.Transparent),
            Opacity = enabled ? 1 : 0.45,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var danger = item.Danger ? new SolidColorBrush(Theme.Value(0xFF3B30, 0xFF453A)) : null;
        grid.Children.Add(new FontIcon
        {
            Glyph = item.Checked ? Glyphs.Check : item.Glyph,
            FontSize = 13,
            Foreground = item.Checked ? new SolidColorBrush(Theme.AccentColor) : danger ?? Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var title = new TextBlock
        {
            Text = item.Title,
            FontSize = 13,
            FontWeight = header ? FontWeights.SemiBold : FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (danger is not null)
        {
            title.Foreground = danger;
        }

        Grid.SetColumn(title, 1);
        grid.Children.Add(title);
        // 右边：子列表的 ›、键位，或一行小字（启动器计算结果「复制十六进制」要复制的值，mac ActionMenu 的 detail）。
        FrameworkElement? trailing = item.Submenu is not null
            ? new FontIcon { Glyph = Glyphs.ChevronRight, FontSize = 10, Foreground = Theme.SecondaryText() }
            : item.Shortcut is { } shortcut
                ? KeyCap.Create(shortcut)
                : item.Detail is { } detail
                    ? new TextBlock
                    {
                        Text = detail,
                        FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                        Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxWidth = 120,
                    }
                    : null;
        if (trailing is not null)
        {
            trailing.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(trailing, 2);
            grid.Children.Add(trailing);
        }

        AutomationProperties.SetName(grid, item.Shortcut is null ? item.Title : $"{item.Title}，{item.Shortcut}");
        if (selected)
        {
            AutomationProperties.SetItemStatus(grid, "已选中");
        }

        return grid;
    }
}
