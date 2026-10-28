// 启动器列表的一行（PLAN-v9-launcher V4–V10，照 mac LauncherPanelView.LauncherRow）：40 高、左右 10；图标 24（应用 / 文件 / 网站图标，
// 没有就是种类色块）；标题 14 medium 后面同一行跟副标题（secondary；上了膛是危险色，按住修饰键时换成替代动作、primary）；
// 右边是种类 12 tertiary，按住 Ctrl 150 ms 后换成「Ctrl+1」…键帽（每行错开 15 ms 淡入）；选中的内置动作种类前面多一组它的
// 全局快捷键键帽。计算卡 64 高、一行：算式（等宽 14 secondary）→ 结果（28 semibold）。没选中的行悬停铺 Fill.Hover（0.10 s）。
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

/// <summary>画一行要的东西（面板按模型算好交进来）。</summary>
internal sealed record LauncherRowContext(
    string Subtitle,
    bool SubtitleIsAlternate,
    bool Armed,
    string KindName,
    string? HotKey,
    ImageSource? Icon);

internal sealed partial class LauncherRowView : Grid
{
    private readonly Border _hover;
    private readonly TextBlock _kind;
    private readonly Border _shortcut;
    private readonly StackPanel _trailing;
    private TextBlock? _subtitle;
    private Border? _hotKey;
    private bool _hovered;
    private bool _selected;

    public LauncherRowView(LauncherItem item, int index, LauncherRowContext context)
    {
        Item = item;
        Index = index;
        Height = LauncherListLayout.HeightOf(item.Kind);
        IsTabStop = false;
        Background = new SolidColorBrush(Colors.Transparent);

        _hover = new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = Theme.Brush("Kitty.Fill.Hover", Color.FromArgb(10, 0, 0, 0)),
            Opacity = 0,
            IsHitTestVisible = false,
        };
        Children.Add(_hover);

        var content = new Grid { Padding = new Thickness(10, 0, 10, 0), ColumnSpacing = 10 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Children.Add(content);

        var icon = Icon(item, context.Icon);
        icon.VerticalAlignment = VerticalAlignment.Center;
        content.Children.Add(icon);

        var middle = item.Kind == LauncherKind.Calculation ? Calculation(item, context) : Line(item, context);
        SetColumn(middle, 1);
        content.Children.Add(middle);

        _kind = new TextBlock
        {
            Text = context.KindName,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        _shortcut = KeyCap.Create("Ctrl+" + (index + 1));
        _shortcut.Opacity = 0;
        _shortcut.HorizontalAlignment = HorizontalAlignment.Right;
        _shortcut.VerticalAlignment = VerticalAlignment.Center;
        var kindHost = new Grid { VerticalAlignment = VerticalAlignment.Center };
        kindHost.Children.Add(_kind);
        kindHost.Children.Add(_shortcut);
        _trailing = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _trailing.Children.Add(kindHost);
        SetColumn(_trailing, 2);
        content.Children.Add(_trailing);
        SetHotKey(context.HotKey);

        AutomationProperties.SetName(this, string.IsNullOrEmpty(context.Subtitle)
            ? $"{item.Title}，{context.KindName}"
            : $"{item.Title}，{context.Subtitle}，{context.KindName}");
    }

    public LauncherItem Item { get; }

    public int Index { get; }

    public void SetHovered(bool hovered)
    {
        _hovered = hovered;
        ApplyHover();
    }

    public void SetSelected(bool selected)
    {
        _selected = selected;
        AutomationProperties.SetItemStatus(this, selected ? "已选中" : string.Empty);
        ApplyHover();
    }

    /// <summary>按住 Ctrl 150 ms：种类换成「Ctrl+N」键帽（前九行，每行错开 15 ms）；松开换回。</summary>
    public void SetShortcutShown(bool shown)
    {
        if (Index >= 9)
        {
            return;
        }

        var delay = Motion.Reduced ? 0 : Index * 15;
        Motion.Fade(_kind, shown ? 0 : 1, 0.12, delay);
        Motion.Fade(_shortcut, shown ? 1 : 0, 0.12, delay);
        if (_hotKey is not null)
        {
            _hotKey.Visibility = shown ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    /// <summary>选中行换副标题（按住修饰键的替代动作、上膛的确认提示），不重建整行。</summary>
    public void SetSubtitle(string text, bool alternate, bool armed)
    {
        if (_subtitle is null)
        {
            return;
        }

        if (Item.Kind == LauncherKind.Calculation)
        {
            // 计算卡平时那一格是算式（等宽，同 Calculation 建行时）；面板传进来的是 item.Subtitle（「计算结果 · Enter 粘贴…」），
            // 不换回来的话换一次选中 / 松开 Ctrl 算式就没了。
            text = alternate || armed ? text : Item.Target.Trim();
            _subtitle.FontFamily = alternate ? FontFamily.XamlAutoFontFamily : new FontFamily("Cascadia Mono, Consolas");
        }

        _subtitle.Text = text;
        _subtitle.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        _subtitle.Foreground = SubtitleBrush(alternate, armed);
    }

    /// <summary>选中的内置动作：种类前面一组它的全局快捷键键帽（没设不显示）。</summary>
    public void SetHotKey(string? hotKey)
    {
        if (_hotKey is not null)
        {
            _trailing.Children.Remove(_hotKey);
            _hotKey = null;
        }

        if (string.IsNullOrEmpty(hotKey))
        {
            return;
        }

        _hotKey = KeyCap.Create(hotKey);
        _hotKey.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(_hotKey, "快捷键 " + hotKey);
        _trailing.Children.Insert(0, _hotKey);
    }

    private void ApplyHover()
    {
        var target = _hovered && !_selected ? 1 : 0;
        if (Motion.Reduced)
        {
            _hover.Opacity = target;
        }
        else
        {
            Motion.Fade(_hover, target, 0.10);
        }
    }

    private static Brush SubtitleBrush(bool alternate, bool armed)
        => armed
            ? Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28))
            : alternate
                ? Theme.Brush("TextFillColorPrimaryBrush", Color.FromArgb(255, 32, 32, 32))
                : Theme.SecondaryText();

    /// <summary>图标：解码好的图（应用 / 文件 / 网站图标，网站图标垫白底方块）或种类色块。</summary>
    private static FrameworkElement Icon(LauncherItem item, ImageSource? image)
    {
        if (image is null)
        {
            return KindTile.Create(KindTile.FamilyOf(item.Kind, item.Target), KindTile.GlyphOf(item.Kind, item.Target), 24);
        }

        var picture = new Image { Source = image, Width = 24, Height = 24, Stretch = Stretch.Uniform };
        if (item.Kind is not (LauncherKind.Url or LauncherKind.Search))
        {
            return picture;
        }

        // 网站图标（mac 同翻译的 ServiceTile）：24 的白底方块、发丝线描边、图标四周留 14%。
        picture.Width = picture.Height = 17;
        return new Border
        {
            Width = 24,
            Height = 24,
            CornerRadius = new CornerRadius(5.5),
            Background = new SolidColorBrush(Colors.White),
            BorderBrush = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            BorderThickness = new Thickness(0.5),
            Child = picture,
        };
    }

    /// <summary>普通行：标题（放得下就全放，太长才截）+ 副标题（同一行、截掉的是中间，Core 已截好）。</summary>
    private FrameworkElement Line(LauncherItem item, LauncherRowContext context)
    {
        var line = new Grid { VerticalAlignment = VerticalAlignment.Center, ColumnSpacing = 8 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var title = new TextBlock
        {
            Text = item.Title,
            FontSize = Theme.FontSize("Kitty.FontSize.RowTitle"),
            FontWeight = FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            MaxWidth = 440,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if ((item.Kind == LauncherKind.Process && item.Title.StartsWith(':')) ||
            (item.Kind == LauncherKind.Ip && item.Title.Length > 0 && char.IsAsciiDigit(item.Title[0])))
        {
            // port 的标题是端口号、ip 的是地址：等宽数字，后面的副标题才成一列。
            title.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        }

        line.Children.Add(title);
        _subtitle = new TextBlock
        {
            Text = context.Subtitle,
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            Foreground = SubtitleBrush(context.SubtitleIsAlternate, context.Armed),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = context.Subtitle.Length == 0 ? Visibility.Collapsed : Visibility.Visible,
        };
        SetColumn(_subtitle, 1);
        line.Children.Add(_subtitle);
        return line;
    }

    /// <summary>计算卡：算式 → 结果（大字千分位分组、单位换算带单位；粘贴的是不分组的原值）。按住 Ctrl 时算式换成替代动作。</summary>
    private FrameworkElement Calculation(LauncherItem item, LauncherRowContext context)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        _subtitle = new TextBlock
        {
            Text = context.SubtitleIsAlternate || context.Armed ? context.Subtitle : item.Target.Trim(),
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            FontFamily = context.SubtitleIsAlternate ? FontFamily.XamlAutoFontFamily : new FontFamily("Cascadia Mono, Consolas"),
            Foreground = SubtitleBrush(context.SubtitleIsAlternate, context.Armed),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 260,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(_subtitle);
        row.Children.Add(new FontIcon
        {
            Glyph = "",
            FontSize = 11,
            Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(new TextBlock
        {
            Text = item.Title,
            FontSize = Theme.FontSize("Kitty.FontSize.Result"),
            FontWeight = FontWeights.SemiBold,
            FontFamily = new FontFamily("Segoe UI Variable Display"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            VerticalAlignment = VerticalAlignment.Center,
        });
        return row;
    }
}
