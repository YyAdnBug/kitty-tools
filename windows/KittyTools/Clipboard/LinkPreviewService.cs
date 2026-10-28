// 链接预览的取数（第三版 §5，E5）：规则在 Core 的 LinkPreviewRules（拦截、解析都配单测）。
// 不发 Cookie、不缓存到磁盘；网页读到 </head> 或 512 KB 就停，图片超过 4 MB 放弃；内存里最多记 12 条
// （头图缩到长边 1200，空闲回收时丢掉解码好的图、留着字节——这里直接按字节缓存，够用）。
// 设置里关掉时调用方不取，缓存也不显示。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class LinkPreviewService
{
    private static readonly HttpClient Http = CreateClient();
    private static readonly Dictionary<string, CachedPreview?> Cache = new(StringComparer.Ordinal);

    public static bool Enabled => SettingsService.Current.LinkPreviews;

    /// <summary>取到的预览：头图和网站图标都是下载来的原始字节（透镜、放大卡各自解码）。</summary>
    public sealed record CachedPreview(LinkPreview Preview, byte[]? ImageBytes, byte[]? IconBytes);

    /// <summary>已经取过的（透镜一出来就显示，不等 0.25 s）；没取过返回 null。</summary>
    public static CachedPreview? Peek(Uri uri)
    {
        lock (Cache)
        {
            return Cache.TryGetValue(uri.ToString(), out var cached) ? cached : null;
        }
    }

    /// <summary>
    /// 启动器网站图标的兜底（mac SiteIcons：本机浏览器的图标库里没有时用剪贴板链接预览取到的）：按主机找一条带网站图标的；
    /// 设置里关了链接预览时不给（同「缓存也不显示」）。只看内存里那十几条，不联网。
    /// </summary>
    public static byte[]? IconFor(string host)
    {
        if (!Enabled)
        {
            return null;
        }

        lock (Cache)
        {
            foreach (var (key, cached) in Cache)
            {
                if (cached?.IconBytes is { Length: > 0 } icon && string.Equals(LauncherText.Host(key), host, StringComparison.Ordinal))
                {
                    return icon;
                }
            }
        }

        return null;
    }

    public static async Task<CachedPreview?> FetchAsync(Uri uri, CancellationToken cancellationToken)
    {
        var key = uri.ToString();
        lock (Cache)
        {
            if (Cache.TryGetValue(key, out var cached))
            {
                return cached;
            }
        }

        if (!LinkPreviewRules.CanFetch(uri))
        {
            Log.Info("linkpreview.skipped guard");
            return null;
        }

        try
        {
            using var response = await Http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                Remember(key, null);
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var buffer = new byte[LinkPreviewRules.MaxHtmlBytes];
            var total = 0;
            while (total < buffer.Length)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(total), cancellationToken);
                if (read <= 0)
                {
                    break;
                }

                total += read;
                var headEnd = IndexOf(buffer.AsSpan(0, total), "</head"u8);
                if (headEnd >= 0)
                {
                    total = headEnd + 6;
                    break;
                }
            }

            var html = System.Text.Encoding.UTF8.GetString(buffer, 0, total);
            var preview = LinkPreviewRules.Parse(uri, html);
            if (preview is null)
            {
                Remember(key, null);
                return null;
            }

            var image = preview.ImageUrl is { } imageUrl && Uri.TryCreate(imageUrl, UriKind.Absolute, out var imageUri)
                ? await ImageAsync(imageUri, cancellationToken)
                : null;
            var icon = preview.IconUrl is { } iconUrl && iconUrl != preview.ImageUrl &&
                       Uri.TryCreate(iconUrl, UriKind.Absolute, out var iconUri)
                ? await ImageAsync(iconUri, cancellationToken)
                : null;
            var cached = new CachedPreview(preview, image, icon is { Length: <= 512 * 1024 } ? icon : null);
            Remember(key, cached);
            return cached;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception ex)
        {
            Log.Warn($"linkpreview.failed {ex.GetType().Name}");
            Remember(key, null);
            return null;
        }
    }

    public static void Clear()
    {
        lock (Cache)
        {
            Cache.Clear();
        }
    }

    private static async Task<byte[]?> ImageAsync(Uri uri, CancellationToken cancellationToken)
    {
        if (!LinkPreviewRules.CanFetch(uri))
        {
            return null;
        }

        try
        {
            using var response = await Http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            if (response.Content.Headers.ContentLength is > LinkPreviewRules.MaxImageBytes)
            {
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var memory = new MemoryStream();
            var chunk = new byte[81920];
            while (memory.Length <= LinkPreviewRules.MaxImageBytes)
            {
                var read = await stream.ReadAsync(chunk, cancellationToken);
                if (read <= 0)
                {
                    break;
                }

                memory.Write(chunk, 0, read);
            }

            return memory.Length is > 0 and <= LinkPreviewRules.MaxImageBytes ? memory.ToArray() : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"linkpreview.image-failed {ex.GetType().Name}");
            return null;
        }
    }

    private static void Remember(string key, CachedPreview? preview)
    {
        lock (Cache)
        {
            Cache[key] = preview;
            while (Cache.Count > LinkPreviewRules.MaxCachedPreviews)
            {
                Cache.Remove(Cache.Keys.First());
            }
        }
    }

    private static int IndexOf(ReadOnlySpan<byte> haystack, ReadOnlySpan<byte> needle)
    {
        for (var index = 0; index <= haystack.Length - needle.Length; index++)
        {
            if (haystack.Slice(index, needle.Length).SequenceEqual(needle))
            {
                return index;
            }
        }

        return -1;
    }

    private static HttpClient CreateClient()
    {
        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 5,
            AutomaticDecompression = System.Net.DecompressionMethods.All,
        };
        var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("KittyTools/0.3 (+https://github.com/YyAdnBug/kitty-tools)");
        client.DefaultRequestHeaders.Accept.Add(new System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("text/html"));
        return client;
    }
}
