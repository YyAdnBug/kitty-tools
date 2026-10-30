// 种类色块（PLAN-v7 §2.1）：家族色从上往下 0.95 → 0.75 的渐变，白色符号，0.5 px 内描边。
// 24 / 32 两档；取代以前的「家族色 12% 淡底 + 彩色符号」。启动器各种结果的家族色和符号照 mac（PLAN-v9-launcher V8）。
// 功能图标（2026-10-30，PLAN-v10 §6）：和 mac 共用的那一套是路径数据（FeatureIcons，"F1 M…"），这里解析（Core 的 PathData）后画成路径；
// 别的符号照旧是 Segoe 字形。调用的地方传哪种都行，一个入口分开画。
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

    /// <summary>启动器一项的色块（行首和底栏左边是同一个）：kill、port、cb、fy 和内置动作各有各的。</summary>
    public static Border Create(LauncherKind kind, string target, double size)
        => Create(FamilyOf(kind, target), GlyphOf(kind, target), size);

    public static Border Create(string family, string? glyph = null, double size = 24)
    {
        var color = Theme.Family.For(family);
        var border = Create(color, size);
        border.Child = Symbol(glyph ?? Glyphs.App, size);
        return border;
    }

    /// <summary>
    /// 色块里的符号：功能图标（<see cref="FeatureIcons"/>）画成路径，24 格放进色块的 0.6（同 mac KindTile：20 → 12、24 → 14.4、
    /// 32 → 19.2）；Segoe 字形照旧，字号是色块的一半。
    /// </summary>
    private static FrameworkElement Symbol(string glyph, double size)
    {
        var white = new SolidColorBrush(Colors.White);
        if (!glyph.StartsWith("F1 ", StringComparison.Ordinal))
        {
            return new FontIcon
            {
                Glyph = glyph,
                FontSize = size * 0.5,
                Foreground = white,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        var path = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = Geometry(glyph),
            Fill = white,
            Width = 24,
            Height = 24,
            Stretch = Stretch.None,
        };
        return new Viewbox
        {
            Width = size * 0.6,
            Height = size * 0.6,
            Child = path,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    // 解析过的路径数据（最多 26 个图标）；Geometry 不能被几个 Path 共用，每个色块照样新建一份。
    private static readonly Dictionary<string, PathDataResult> Parsed = new(StringComparer.Ordinal);

    /// <summary>
    /// 路径数据拼成 PathGeometry。不用 XamlReader.Load：Native AOT 里它拿回来的对象转不成 Path
    /// （0.1.1 Release 实测一打开设置窗就 InvalidCastException），解析在 Core 的 PathData。
    /// </summary>
    private static PathGeometry Geometry(string data)
    {
        if (!Parsed.TryGetValue(data, out var parsed))
        {
            parsed = PathData.Parse(data);
            Parsed[data] = parsed;
        }

        var geometry = new PathGeometry { FillRule = parsed.NonZero ? FillRule.Nonzero : FillRule.EvenOdd };
        foreach (var figure in parsed.Figures)
        {
            var built = new PathFigure
            {
                StartPoint = new Windows.Foundation.Point(figure.StartX, figure.StartY),
                IsClosed = figure.Closed,
                IsFilled = true,
            };
            foreach (var segment in figure.Segments)
            {
                built.Segments.Add(segment.Command switch
                {
                    PathCommand.Line => new LineSegment { Point = new(segment.X1, segment.Y1) },
                    PathCommand.Quadratic => new QuadraticBezierSegment
                    {
                        Point1 = new(segment.X1, segment.Y1),
                        Point2 = new(segment.X2, segment.Y2),
                    },
                    _ => new BezierSegment
                    {
                        Point1 = new(segment.X1, segment.Y1),
                        Point2 = new(segment.X2, segment.Y2),
                        Point3 = new(segment.X3, segment.Y3),
                    },
                });
            }

            geometry.Figures.Add(built);
        }

        return geometry;
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

    /// <summary>
    /// 启动器每种结果的家族色（照 mac LauncherItem.familyColor）：应用 / 文件灰（只在取不到图标时露出来）、系统命令和进程紫、
    /// 网址青、搜索和补全提示靛、计算橙、cb 那一行蓝、fy 那一行绿；内置动作跟它在托盘菜单里那一节。
    /// </summary>
    public static string FamilyOf(LauncherKind kind) => kind switch
    {
        LauncherKind.Command or LauncherKind.Process or LauncherKind.Ip => "command",
        LauncherKind.Url => "url",
        LauncherKind.Search or LauncherKind.Prompt => "search",
        LauncherKind.Calculation => "calculator",
        LauncherKind.Clip => "clipboard",
        LauncherKind.Translate => "translate",
        _ => "general",
    };

    public static string GlyphOf(LauncherKind kind) => kind switch
    {
        LauncherKind.App => Glyphs.App,
        LauncherKind.Setting => Glyphs.Settings,
        LauncherKind.Command => Glyphs.Shutdown,
        LauncherKind.Action => Glyphs.Settings,
        LauncherKind.Url => Glyphs.Globe,
        LauncherKind.Path => Glyphs.File,
        LauncherKind.Search or LauncherKind.Prompt => Glyphs.Search,
        LauncherKind.Calculation => Glyphs.Calculator,
        LauncherKind.Clip => FeatureIcons.Clipboard,
        LauncherKind.Translate => FeatureIcons.Translate,
        LauncherKind.Process => Glyphs.Process,
        LauncherKind.Ip => Glyphs.Port,
        _ => Glyphs.App,
    };

    /// <summary>按目标细分：内置动作用它自己的、系统命令各有各的符号、补全提示看是哪一种（文件 / 系统命令 / fy / 网页搜索）。</summary>
    public static string FamilyOf(LauncherKind kind, string target) => kind switch
    {
        LauncherKind.Action => LauncherActions.FamilyOf(target),
        LauncherKind.Prompt when target.StartsWith("file-", StringComparison.Ordinal) => "general",
        LauncherKind.Prompt when target.StartsWith("system-", StringComparison.Ordinal) => "command",
        LauncherKind.Prompt when target == "translate-fy" => "translate",
        _ => FamilyOf(kind),
    };

    public static string GlyphOf(LauncherKind kind, string target) => kind switch
    {
        LauncherKind.Action => LauncherActions.GlyphOf(target),
        LauncherKind.Command => SystemCommands.GlyphOf(target),
        LauncherKind.Path when target.EndsWith('\\') => Glyphs.Folder,
        // ip：外网是地球、VPN 是锁、局域网是网络（mac globe / lock.shield / network）。
        LauncherKind.Ip when target.StartsWith("public", StringComparison.Ordinal) => Glyphs.Globe,
        LauncherKind.Ip when target.StartsWith("vpn:", StringComparison.Ordinal) => Glyphs.Lock,
        LauncherKind.Prompt => target switch
        {
            "file-open" or "file-find" => Glyphs.Search,
            "system-quit" => Glyphs.Close,
            "system-hide" => Glyphs.Minimize,
            "system-forcequit" => Glyphs.Error,
            "system-kill" => Glyphs.Stop,
            "system-port" => Glyphs.Port,
            "translate-fy" => FeatureIcons.Translate,
            _ => Glyphs.Search,
        },
        _ => GlyphOf(kind),
    };
}
