// 状态屏的动画表情（PLAN-v12 N5，照 mac StatusScreen/StatusEmoji.swift）：28 个可选 + 被碰时冒出来的眼睛，素材是 Microsoft Fluent Emoji
// Animated（MIT，许可在 Resources\StatusEmoji\LICENSE.txt），在 Mac 上用 tools/status-emoji.swift 转成帧图集 + 静止画面 + manifest.txt。
// R107 起另有两种图标值：「pack:编号」（动画表情包里的，EmojiPack 按需下载、缓存；还没下好时画它的系统样子）和系统表情（那个字，永远
// Segoe UI Emoji 画、不动）。「pack:编号」正好是自带的同一个动画时按自带的画（EmojiPackCatalog.Canonical）。
// 怎么播（同 mac 的思路：不逐帧在 UI 线程上换图）：图集交给合成层的表面画刷，铺成「列数 × 行数」那么大的精灵，外面套一个只露一格的
// 容器（InsetClip），精灵的 Offset 用一段离散的关键帧动画一格一格挪、无限循环——合成器里跑，UI 线程不醒。
// 图集加载完之前显示静止画面（第一帧）。会动的只有告示上的表情和眼睛、设置详情页的大预览；设置、启动器、选状态的卡片一律用静止画面
// （表情包里的静止画面是图集的第一格，按小尺寸解）。帧只在显示期间占显存（一张图集约 4 MB），元素卸载时放掉。
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
using Windows.Storage.Streams;

namespace KittyTools;

internal static class StatusEmoji
{
    private static Dictionary<string, EmojiSheet>? _sheets;

    private static Dictionary<string, EmojiSheet> Sheets => _sheets ??= LoadManifest();

    private static Uri SheetUri(string id) => new($"ms-appx:///Resources/StatusEmoji/{id}.png");

    private static Uri StillUri(string id) => new($"ms-appx:///Resources/StatusEmoji/{id}-still.png");

    /// <summary>manifest.txt：一个表情一行，id、格子边长、列数、帧数、每帧毫秒（逗号隔开）。读不出的行跳过（那个表情就只有静止画面）。</summary>
    private static Dictionary<string, EmojiSheet> LoadManifest()
    {
        var result = new Dictionary<string, EmojiSheet>(StringComparer.Ordinal);
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "StatusEmoji", "manifest.txt");
            foreach (var line in File.ReadAllLines(path))
            {
                var tab = line.IndexOf('\t');
                if (tab > 0 && EmojiSheet.Decode(line[(tab + 1)..]) is { } sheet)
                {
                    result[line[..tab]] = sheet;
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
    /// 存的值整理成画的那种（「pack:编号」和自带的同一个动画 → 自带的 id）。只有「pack:」开头的才去读对照表（746 条，第一次读约几毫秒、
    /// 常驻几百 KB）：没挑过动画表情的人一直不读它。
    /// </summary>
    public static string Canonical(string symbol)
        => StatusEmojiCatalog.IsPackSymbol(symbol) ? EmojiPack.Catalog?.Canonical(symbol) ?? symbol : symbol;

    /// <summary>读屏读的名字：自带的中文名、表情包里的名字、系统表情本身；都不是是 null。</summary>
    public static string? Name(string symbol)
        => StatusEmojiCatalog.IsPackSymbol(symbol) ? EmojiPack.Catalog?.Name(symbol)
            : StatusEmojiCatalog.Name(symbol) ?? (StatusEmojiCatalog.IsCustom(symbol) ? symbol : null);

    /// <summary>
    /// 小图标（设置的列表行和图标格子、启动器、选状态的卡片）：静止画面，边长 side。深色外观下「开会」「黑猫」垫一块浅底
    /// （白 0.88、圆角按色块公式，表情缩到 84%），不然看不见。
    /// </summary>
    public static FrameworkElement Still(string symbol, double side, bool dark)
    {
        var id = Canonical(symbol);
        if (!HasArt(id))
        {
            return StatusEmojiCatalog.IsPackSymbol(id) && EmojiPack.DownloadableId(id) is not null
                ? Pack(id, side, animated: false)
                : Fallback(id, side);
        }

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
    public static FrameworkElement Create(string symbol, double side, bool animated)
    {
        var id = Canonical(symbol);
        if (!HasArt(id))
        {
            return StatusEmojiCatalog.IsPackSymbol(id) && EmojiPack.DownloadableId(id) is not null
                ? Pack(id, side, animated)
                : Fallback(id, side);
        }

        var still = new Image { Source = new BitmapImage(StillUri(id)), Width = side, Height = side, Stretch = Stretch.Uniform };
        var host = new Grid { Width = side, Height = side };
        host.Children.Add(still);
        AutomationProperties.SetAccessibilityView(host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (animated && Sheets.TryGetValue(id, out var sheet))
        {
            try
            {
                Show(host, still, LoadedImageSurface.StartLoadFromUri(SheetUri(id)), sheet, side, animate: true, owned: null, failed: null);
            }
            catch (Exception ex)
            {
                // 合成层出问题就停在静止画面。
                Log.Warn($"status.emoji-play-failed {ex.GetType().Name}");
            }
        }

        return host;
    }

    private static bool HasArt(string id) => StatusEmojiCatalog.Ids.Contains(id) || id == StatusEmojiCatalog.Eyes;

    /// <summary>
    /// 动画表情包里的（R107）：先画那个表情的系统样子，同时从缓存读 / 下载（EmojiPack.LoadAsync）；拿到了就换成图集——animated 播，
    /// 不然只露第一格（按要画的大小解，不解整张）。元素在拿到之前就卸载了就不换。
    /// </summary>
    private static Grid Pack(string symbol, double side, bool animated)
    {
        var placeholder = Glyph(EmojiPack.Glyph(symbol) ?? string.Empty, side);
        var host = new Grid { Width = side, Height = side };
        host.Children.Add(placeholder);
        AutomationProperties.SetName(host, Name(symbol) ?? "动画表情");
        var unloaded = false;
        host.Unloaded += (_, _) => unloaded = true;
        _ = ShowPackAsync(host, placeholder, symbol, side, animated, () => unloaded);
        return host;
    }

    private static async Task ShowPackAsync(Grid host, UIElement placeholder, string symbol, double side, bool animated, Func<bool> unloaded)
    {
        try
        {
            if (await EmojiPack.LoadAsync(symbol) is not { } loaded || unloaded())
            {
                return;
            }

            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(loaded.Bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            if (unloaded())
            {
                stream.Dispose();
                return;
            }

            var sheet = loaded.Sheet;
            // 小图标按要画的大小解（两倍：200% 屏也清楚），告示和大预览按原大小（一格 160）
            var surface = animated
                ? LoadedImageSurface.StartLoadFromStream(stream)
                : LoadedImageSurface.StartLoadFromStream(stream, new Windows.Foundation.Size(
                    Math.Min(sheet.Cell, side * 2) * sheet.Columns, Math.Min(sheet.Cell, side * 2) * sheet.Rows));
            // 结构核过了、像素却解不开：缓存里那份删掉，过一阵重新下（EmojiPack.Forget；R107 审查）
            Show(host, placeholder, surface, sheet, side, animated, stream, () => EmojiPack.Forget(symbol));
        }
        catch (Exception ex)
        {
            // 解不开、合成层出问题：停在系统样子。
            Log.Warn($"status.emoji-pack-show-failed {EmojiPack.DownloadableId(symbol)} {ex.GetType().Name}");
        }
    }

    /// <summary>
    /// 这一版没有素材的图标（同步、导入来的更新版本才有的表情包编号、乱写的）：系统表情（那个字）照 mac 用系统的表情字体画，别的空着。
    /// </summary>
    private static FrameworkElement Fallback(string id, double side)
    {
        var custom = StatusEmojiCatalog.IsCustom(id);
        var host = new Grid { Width = side, Height = side };
        host.Children.Add(Glyph(custom ? id : string.Empty, side));
        AutomationProperties.SetName(host, custom ? id : "图标");
        return host;
    }

    private static TextBlock Glyph(string text, double side) => new()
    {
        Text = text,
        FontFamily = new FontFamily("Segoe UI Emoji"),
        FontSize = side * 0.75,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };

    /// <summary>
    /// 把图集挂到 host 上：铺成精灵、只露一格；animate 时一格一格挪（无限循环），不然停在第一格。图集解好之前 placeholder 照旧露着，
    /// 解好了藏起来。owned：跟着一起放掉的东西（表情包的那个流）；failed：解不开时调（表情包的删掉缓存）。
    /// </summary>
    private static void Show(
        Grid host, UIElement placeholder, LoadedImageSurface surface, EmojiSheet sheet, double side, bool animate, IDisposable? owned,
        Action? failed)
    {
        var compositor = ElementCompositionPreview.GetElementVisual(host).Compositor;
        var brush = compositor.CreateSurfaceBrush(surface);
        // 铺满精灵（列数 × 行数个格子那么大），不用管图集按 DIP 还是像素算尺寸。
        brush.Stretch = CompositionStretch.Fill;
        var sprite = compositor.CreateSpriteVisual();
        sprite.Size = new Vector2((float)(side * sheet.Columns), (float)(side * sheet.Rows));
        sprite.Brush = brush;
        var frame = compositor.CreateContainerVisual();
        frame.Size = new Vector2((float)side, (float)side);
        frame.Clip = compositor.CreateInsetClip();
        frame.Opacity = 0f;
        frame.Children.InsertAtTop(sprite);

        Vector3KeyFrameAnimation? animation = null;
        if (animate)
        {
            // 离散的关键帧：每一帧在它开始的时刻跳到那一格，停到下一帧开始前一点点（中间线性插值的两端一样 = 不动）。
            var total = sheet.Total;
            animation = compositor.CreateVector3KeyFrameAnimation();
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
        }

        surface.LoadCompleted += (_, args) =>
        {
            owned?.Dispose();
            owned = null;
            if (args.Status != LoadedImageSourceLoadStatus.Success)
            {
                Log.Warn($"status.emoji-load-failed {args.Status}");
                failed?.Invoke();
                return;
            }

            frame.Opacity = 1f;
            placeholder.Opacity = 0;
            if (animation is not null)
            {
                sprite.StartAnimation("Offset", animation);
            }
        };
        ElementCompositionPreview.SetElementChildVisual(host, frame);
        host.Unloaded += (_, _) =>
        {
            // 窗口关掉之后才来的 Unloaded 里摘合成层可能抛（事件里抛出去就是闪退）：抛了也接着放后面的。
            try
            {
                if (animation is not null)
                {
                    sprite.StopAnimation("Offset");
                }

                ElementCompositionPreview.SetElementChildVisual(host, null);
            }
            catch (Exception ex)
            {
                Log.Warn($"status.emoji-release-failed {ex.GetType().Name}");
            }

            owned?.Dispose();
            owned = null;
            animation?.Dispose();
            sprite.Dispose();
            frame.Dispose();
            brush.Dispose();
            surface.Dispose();
        };
    }
}
