// 状态屏的动画表情（PLAN-v12 N5，照 mac StatusScreen/StatusEmoji.swift）：16 个可选 + 被碰时冒出来的眼睛，素材是 Microsoft Fluent Emoji
// Animated（MIT，许可在 Resources\StatusEmoji\LICENSE.txt），在 Mac 上用 tools/status-emoji.swift 转成帧图集 + 静止画面 + manifest.txt。
// 怎么播（同 mac 的思路：不逐帧在 UI 线程上换图）：图集交给合成层的表面画刷，铺成「列数 × 行数」那么大的精灵，外面套一个只露一格的
// 容器（InsetClip），精灵的 Offset 用一段离散的关键帧动画一格一格挪、无限循环——合成器里跑，UI 线程不醒。
// 图集加载完之前显示静止画面（第一帧）。会动的只有告示上的表情和眼睛；设置、启动器、选状态的卡片一律用静止画面。
// 帧只在告示显示期间占显存（一张图集约 4 MB），元素卸载时放掉。
using System.Numerics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace KittyTools;

internal static class StatusEmoji
{
    private sealed record Sheet(int Columns, int Count, int[] Durations);

    private static Dictionary<string, Sheet>? _sheets;

    private static Dictionary<string, Sheet> Sheets => _sheets ??= LoadManifest();

    private static Uri SheetUri(string id) => new($"ms-appx:///Resources/StatusEmoji/{id}.png");

    private static Uri StillUri(string id) => new($"ms-appx:///Resources/StatusEmoji/{id}-still.png");

    /// <summary>manifest.txt：一个表情一行，id、格子边长、列数、帧数、每帧毫秒（逗号隔开）。读不出的行跳过（那个表情就只有静止画面）。</summary>
    private static Dictionary<string, Sheet> LoadManifest()
    {
        var result = new Dictionary<string, Sheet>(StringComparer.Ordinal);
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "StatusEmoji", "manifest.txt");
            foreach (var line in File.ReadAllLines(path))
            {
                var parts = line.Split('\t');
                if (parts.Length != 5 || !int.TryParse(parts[2], out var columns) || !int.TryParse(parts[3], out var count) ||
                    columns <= 0 || count <= 1)
                {
                    continue;
                }

                var durations = parts[4].Split(',')
                    .Select(text => int.TryParse(text, out var ms) ? Math.Clamp(ms, 10, 2000) : 84)
                    .ToArray();
                if (durations.Length == count)
                {
                    result[parts[0]] = new Sheet(columns, count, durations);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-manifest-failed {ex.GetType().Name}");
        }

        return result;
    }

    /// <summary>
    /// 小图标（设置的列表行和图标格子、启动器、选状态的卡片）：静止画面，边长 side。深色外观下「开会」「黑猫」垫一块浅底
    /// （白 0.88、圆角按色块公式，表情缩到 84%），不然看不见。
    /// </summary>
    public static FrameworkElement Still(string id, double side, bool dark)
    {
        var image = new Image
        {
            Source = new BitmapImage(StillUri(id)) { DecodePixelWidth = (int)Math.Ceiling(side * 2) },
            Width = side,
            Height = side,
            Stretch = Stretch.Uniform,
        };
        AutomationProperties.SetName(image, StatusEmojiCatalog.Name(id) ?? id);
        if (!StatusEmojiCatalog.NeedsPlate(id, dark))
        {
            return image;
        }

        image.Width = image.Height = side * 0.84;
        return new Border
        {
            Width = side,
            Height = side,
            CornerRadius = new CornerRadius(side * 0.225),
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 224, 224, 224)),
            Child = image,
        };
    }

    /// <summary>告示上的表情：animated 时播帧图集，否则（动画关着、减弱动态效果、预览）是静止画面。</summary>
    public static FrameworkElement Create(string id, double side, bool animated)
    {
        var still = new Image { Source = new BitmapImage(StillUri(id)), Width = side, Height = side, Stretch = Stretch.Uniform };
        var host = new Grid { Width = side, Height = side };
        host.Children.Add(still);
        AutomationProperties.SetAccessibilityView(host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (animated && Sheets.TryGetValue(id, out var sheet))
        {
            try
            {
                Play(host, still, id, sheet, side);
            }
            catch (Exception ex)
            {
                // 合成层出问题就停在静止画面。
                Log.Warn($"status.emoji-play-failed {ex.GetType().Name}");
            }
        }

        return host;
    }

    private static void Play(Grid host, Image still, string id, Sheet sheet, double side)
    {
        var compositor = ElementCompositionPreview.GetElementVisual(host).Compositor;
        var rows = (sheet.Count + sheet.Columns - 1) / sheet.Columns;
        var surface = LoadedImageSurface.StartLoadFromUri(SheetUri(id));
        var brush = compositor.CreateSurfaceBrush(surface);
        // 铺满精灵（列数 × 行数个格子那么大），不用管图集按 DIP 还是像素算尺寸。
        brush.Stretch = CompositionStretch.Fill;
        var sprite = compositor.CreateSpriteVisual();
        sprite.Size = new Vector2((float)(side * sheet.Columns), (float)(side * rows));
        sprite.Brush = brush;
        var frame = compositor.CreateContainerVisual();
        frame.Size = new Vector2((float)side, (float)side);
        frame.Clip = compositor.CreateInsetClip();
        frame.Opacity = 0f;
        frame.Children.InsertAtTop(sprite);

        // 离散的关键帧：每一帧在它开始的时刻跳到那一格，停到下一帧开始前一点点（中间线性插值的两端一样 = 不动）。
        var total = sheet.Durations.Sum();
        var animation = compositor.CreateVector3KeyFrameAnimation();
        var linear = compositor.CreateLinearEasingFunction();
        var elapsed = 0;
        for (var index = 0; index < sheet.Count; index++)
        {
            var offset = new Vector3((float)(-(index % sheet.Columns) * side), (float)(-(index / sheet.Columns) * side), 0);
            var start = elapsed / (float)total;
            elapsed += sheet.Durations[index];
            var end = elapsed / (float)total;
            animation.InsertKeyFrame(start, offset, linear);
            animation.InsertKeyFrame(index == sheet.Count - 1 ? 1f : Math.Max(start, end - 0.0005f), offset, linear);
        }

        animation.Duration = TimeSpan.FromMilliseconds(total);
        animation.IterationBehavior = AnimationIterationBehavior.Forever;

        surface.LoadCompleted += (_, args) =>
        {
            if (args.Status != LoadedImageSourceLoadStatus.Success)
            {
                Log.Warn($"status.emoji-load-failed {args.Status}");
                return;
            }

            frame.Opacity = 1f;
            still.Opacity = 0;
            sprite.StartAnimation("Offset", animation);
        };
        ElementCompositionPreview.SetElementChildVisual(host, frame);
        host.Unloaded += (_, _) =>
        {
            sprite.StopAnimation("Offset");
            ElementCompositionPreview.SetElementChildVisual(host, null);
            animation.Dispose();
            sprite.Dispose();
            frame.Dispose();
            brush.Dispose();
            surface.Dispose();
        };
    }
}
