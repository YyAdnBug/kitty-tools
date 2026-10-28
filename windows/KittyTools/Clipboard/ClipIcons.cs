// 剪贴板行首图标块用的两样图（PLAN-v9-clipboard D5）：来源程序的图标（按 exe 路径）、图片条目的缩略图（按条目 id）。
// 都在后台取 / 解码到 24 DIP 的像素数，回 UI 线程再交给调用方；按最近用过的留 300 张（同 mac 行图标缓存 iconCount），
// 一张 24 DIP 的图几 KB，留满也就一两 MB。空闲回收不清它们（一屏十来张一起重做太贵，同 mac）。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class ClipIcons
{
    private const int Capacity = 300;

    /// <summary>图标块 24 DIP。</summary>
    private const double TileDip = 24;

    private static readonly Dictionary<string, LinkedListNode<(string Key, ImageSource? Image)>> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly LinkedList<(string Key, ImageSource? Image)> Recent = new();
    private static readonly Dictionary<string, List<Action<ImageSource>>> Pending = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>来源程序的图标；已经有就直接返回，没有就后台取、取到了回调（取不到的记成 null，不再取）。</summary>
    public static ImageSource? AppIcon(string exePath, double scale, Action<ImageSource> ready)
        => Get("app:" + exePath, ready, () =>
        {
            var png = ShellIcons.LoadPng(exePath, scale, TileDip);
            return Task.FromResult(png);
        });

    /// <summary>图片条目的缩略图（图标块里铺满裁切；解码宽 72 px，同 mac iconPixel，高缩放屏按比例放大）。</summary>
    public static ImageSource? Thumbnail(long id, string path, double scale, Action<ImageSource> ready)
        => Get("img:" + id, ready, async () =>
        {
            if (!File.Exists(path))
            {
                return null;
            }

            return await File.ReadAllBytesAsync(path);
        }, decodePixels: (int)Math.Round(72 * Math.Max(1, scale / 1.5)));

    private static ImageSource? Get(string key, Action<ImageSource> ready, Func<Task<byte[]?>> load, int decodePixels = 0)
    {
        if (Cache.TryGetValue(key, out var node))
        {
            Recent.Remove(node);
            Recent.AddFirst(node);
            return node.Value.Image;
        }

        if (Pending.TryGetValue(key, out var waiting))
        {
            waiting.Add(ready);
            return null;
        }

        Pending[key] = new List<Action<ImageSource>> { ready };
        var queue = DispatcherQueue.GetForCurrentThread();
        _ = Task.Run(async () =>
        {
            byte[]? bytes = null;
            try
            {
                bytes = await load();
            }
            catch (Exception ex)
            {
                Log.Warn($"clipboard.icon-failed {ex.GetType().Name}");
            }

            queue.TryEnqueue(() => _ = FinishAsync(key, bytes, decodePixels));
        });
        return null;
    }

    private static async Task FinishAsync(string key, byte[]? bytes, int decodePixels)
    {
        ImageSource? image = null;
        if (bytes is { Length: > 0 })
        {
            try
            {
                var bitmap = new BitmapImage();
                if (decodePixels > 0)
                {
                    bitmap.DecodePixelWidth = decodePixels;
                    bitmap.DecodePixelType = DecodePixelType.Physical;
                }

                using var stream = new InMemoryRandomAccessStream();
                await stream.WriteAsync(bytes.AsBuffer());
                stream.Seek(0);
                await bitmap.SetSourceAsync(stream);
                image = bitmap;
            }
            catch (Exception ex)
            {
                Log.Warn($"clipboard.icon-decode-failed {ex.GetType().Name}");
            }
        }

        Remember(key, image);
        if (Pending.Remove(key, out var callbacks) && image is not null)
        {
            foreach (var callback in callbacks)
            {
                callback(image);
            }
        }
    }

    private static void Remember(string key, ImageSource? image)
    {
        var node = Recent.AddFirst((key, image));
        Cache[key] = node;
        while (Recent.Count > Capacity && Recent.Last is { } oldest)
        {
            Recent.RemoveLast();
            Cache.Remove(oldest.Value.Key);
        }
    }

    /// <summary>条目删掉 / 图片换了：丢掉它的缩略图。</summary>
    public static void Forget(long id)
    {
        if (Cache.Remove("img:" + id, out var node))
        {
            Recent.Remove(node);
        }
    }
}
