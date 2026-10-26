// 种类色块（PLAN-v7 §2.1）：家族色从上往下 0.95 → 0.75 的渐变，白色符号，0.5 px 内描边。
// 24 / 32 两档；取代以前的「家族色 12% 淡底 + 彩色符号」。
using KittyTools.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

internal static class KindTile
{
    public static Border Create(LauncherKind kind, double size = 24, string? glyph = null)
        => Create(FamilyOf(kind), glyph ?? GlyphOf(kind), size);

    public static Border Create(string family, string? glyph = null, double size = 24)
    {
        var color = Theme.Family.For(family);
        var border = Create(color, size);
        border.Child = new FontIcon
        {
            Glyph = glyph ?? Glyphs.App,
            FontSize = size * 0.5,
            Foreground = new SolidColorBrush(Colors.White),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return border;
    }

    public static Border Create(Color color, double size = 24)
    {
        var gradient = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(0, 1),
        };
        gradient.GradientStops.Add(new GradientStop
        {
            Offset = 0,
            Color = Color.FromArgb(242, color.R, color.G, color.B),
        });
        gradient.GradientStops.Add(new GradientStop
        {
            Offset = 1,
            Color = Color.FromArgb(191, color.R, color.G, color.B),
        });
        return new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size * 0.225),
            Background = gradient,
            BorderBrush = new SolidColorBrush(Color.FromArgb(46, 255, 255, 255)),
            BorderThickness = new Thickness(0.5),
            Child = new TextBlock
            {
                Text = string.Empty,
                FontSize = size * 0.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    public static string FamilyOf(LauncherKind kind) => kind switch
    {
        LauncherKind.App => "launcher",
        LauncherKind.Setting => "general",
        LauncherKind.Command => "command",
        LauncherKind.Action => "capture",
        LauncherKind.Url => "url",
        LauncherKind.Path => "shortcut",
        LauncherKind.Search => "search",
        LauncherKind.Calculation => "calculator",
        _ => "translate",
    };

    public static string GlyphOf(LauncherKind kind) => kind switch
    {
        LauncherKind.App => Glyphs.App,
        LauncherKind.Setting => Glyphs.Settings,
        LauncherKind.Command => Glyphs.CommandPrompt,
        LauncherKind.Action => Glyphs.Screenshot,
        LauncherKind.Url => Glyphs.Link,
        LauncherKind.Path => Glyphs.Folder,
        LauncherKind.Search => Glyphs.Globe,
        LauncherKind.Calculation => Glyphs.Calculator,
        _ => Glyphs.Translate,
    };
}
