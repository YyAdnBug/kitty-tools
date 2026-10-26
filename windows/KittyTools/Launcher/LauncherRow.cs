// 启动器列表的一行：图标 / 名字 / 副标题 / 右边 Ctrl+数字键帽 / 计算结果的特殊排版（PLAN-v2 §3.6）。
using KittyTools.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools;

public sealed class LauncherRow
{
    public LauncherItem Item { get; private init; } = null!;

    public string Title { get; private init; } = string.Empty;

    public string Subtitle { get; private init; } = string.Empty;

    public string KeyHint { get; private init; } = string.Empty;

    public Visibility KeyHintVisibility { get; private init; }

    public string Glyph { get; private init; } = string.Empty;

    public Brush IconBackground { get; private init; } = new SolidColorBrush(Colors.Transparent);

    public ImageSource? IconImage { get; private init; }

    public Visibility GlyphVisibility { get; private init; }

    public Visibility ImageVisibility { get; private init; }

    /// <summary>计算结果那一行 28 号字 + 说明，行高要单独高一点（REVIEW R7）。</summary>
    public double RowHeight { get; private init; }

    /// <summary>计算结果那一行用 28 号等宽（PLAN-v2 §3.6），普通行 14 号。</summary>
    public double TitleSize { get; private init; }

    public string TitleFontFamily { get; private init; } = "Segoe UI";

    /// <summary>U3：行尾的种类名（应用 / 设置 / 命令 …）。</summary>
    public string KindLabel => Item.Kind switch
    {
        LauncherKind.App => "应用",
        LauncherKind.Setting => "设置",
        LauncherKind.Command => "系统",
        LauncherKind.Action => "动作",
        LauncherKind.Url => "网址",
        LauncherKind.Path => "路径",
        LauncherKind.Search => "搜索",
        LauncherKind.Calculation => "计算",
        _ => string.Empty,
    };

    public Visibility NormalVisibility => Item.Kind == LauncherKind.Calculation
        ? Visibility.Collapsed
        : Visibility.Visible;

    public Visibility CalculationVisibility => Item.Kind == LauncherKind.Calculation
        ? Visibility.Visible
        : Visibility.Collapsed;

    /// <summary>危险命令上膛时副标题用危险色。</summary>
    public Brush SubtitleBrush { get; private init; } = Theme.SecondaryText();

    public static LauncherRow Create(
        LauncherItem item,
        string subtitle,
        int index,
        bool showKeyHint,
        ImageSource? icon,
        bool armed = false)
    {
        var hasImage = icon is not null;
        var calculation = item.Kind == LauncherKind.Calculation;
        return new LauncherRow
        {
            Item = item,
            Title = item.Title,
            Subtitle = subtitle,
            KeyHint = showKeyHint && index < 9 ? (index + 1).ToString() : string.Empty,
            KeyHintVisibility = showKeyHint && index < 9 ? Visibility.Visible : Visibility.Collapsed,
            Glyph = GlyphFor(item.Kind),
            IconBackground = BackgroundFor(item.Kind),
            IconImage = icon,
            GlyphVisibility = hasImage ? Visibility.Collapsed : Visibility.Visible,
            ImageVisibility = hasImage ? Visibility.Visible : Visibility.Collapsed,
            TitleSize = calculation ? 28 : 14,
            RowHeight = calculation ? PanelMetrics.LauncherCalculationRowHeight : PanelMetrics.LauncherRowHeight,
            TitleFontFamily = calculation ? "Consolas" : "Segoe UI",
            SubtitleBrush = armed ? Theme.Critical() : Theme.SecondaryText(),
        };
    }

    private static string GlyphFor(LauncherKind kind) => kind switch
    {
        LauncherKind.App => "\uE71D",
        LauncherKind.Setting => "\uE713",
        LauncherKind.Command => "\uE7E8",
        LauncherKind.Action => "\uE8C8",
        LauncherKind.Url => "\uE774",
        LauncherKind.Path => "\uE8B7",
        LauncherKind.Search => "\uE721",
        _ => "\uE8EF",
    };

    private static Brush BackgroundFor(LauncherKind kind) => Theme.Family.Tile(kind);
}
