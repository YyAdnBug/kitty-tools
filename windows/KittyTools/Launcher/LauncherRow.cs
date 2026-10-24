// 启动器列表的一行：图标 / 名字 / 副标题 / 右边 Ctrl+数字键帽。
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

    public string Glyph { get; private init; } = string.Empty;

    public Brush IconBackground { get; private init; } = new SolidColorBrush(Colors.Transparent);

    public ImageSource? IconImage { get; private init; }

    public Visibility GlyphVisibility { get; private init; }

    public Visibility ImageVisibility { get; private init; }

    public static LauncherRow Create(
        LauncherItem item,
        string subtitle,
        int index,
        bool showKeyHint,
        ImageSource? icon)
    {
        var hasImage = icon is not null;
        return new LauncherRow
        {
            Item = item,
            Title = item.Title,
            Subtitle = subtitle,
            KeyHint = showKeyHint && index < 9 ? $"Ctrl+{index + 1}" : string.Empty,
            Glyph = GlyphFor(item.Kind),
            IconBackground = BackgroundFor(item.Kind),
            IconImage = icon,
            GlyphVisibility = hasImage ? Visibility.Collapsed : Visibility.Visible,
            ImageVisibility = hasImage ? Visibility.Visible : Visibility.Collapsed,
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

    private static Brush BackgroundFor(LauncherKind kind)
    {
        var color = kind switch
        {
            LauncherKind.App => Color.FromArgb(32, 124, 92, 255),
            LauncherKind.Setting => Color.FromArgb(28, 128, 128, 128),
            LauncherKind.Command => Color.FromArgb(30, 234, 120, 40),
            LauncherKind.Action => Color.FromArgb(30, 255, 77, 126),
            LauncherKind.Url => Color.FromArgb(30, 40, 140, 240),
            LauncherKind.Path => Color.FromArgb(30, 220, 170, 40),
            LauncherKind.Search => Color.FromArgb(30, 140, 90, 240),
            _ => Color.FromArgb(30, 60, 170, 110),
        };
        return new SolidColorBrush(color);
    }
}
