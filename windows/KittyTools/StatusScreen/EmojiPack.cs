// 动画表情包（REVIEW R107，照 mac StatusScreen/EmojiPack.swift）：「动画表情」气泡里挑的 Microsoft Fluent Emoji Animated（746 个，默认肤色，
// 存「pack:编号」），第一次用到时下载那个动画、缓存在本机，之后就是动的。系统表情不走这里（永远系统样子）。
// - 对照表 Resources\StatusEmoji\emoji-pack.json（同 mac 那份，tag 换成 emoji-pack-1-win）打进包里；动画在本仓库一个单独的 release
//   （emoji-pack-1-win，不标 latest），一个是帧图集 PNG（约 0.2–0.8 MB，tools/status-emoji.swift --pack 生成，帧信息写在图集自己的 tEXt 块里）。
//   mac 的 emoji-pack-1 是 HEICS，Windows 不一定装了 HEIF 解码器，用不了。包里自带的 28 个和眼睛不下载（EmojiPackCatalog.BundledFile）。
// - 缓存在数据目录的 emoji-pack\（<编号>.png），不备份、不导出、不同步（另一台用到时自己下）；用一次把修改时间碰成现在，
//   超过 50 MB 删最久没用的（这次运行第一次用到时、每下好一个之后，线程池里做）。
// - 什么时候下：选上的那个显示到的时候（设置的图标格子和预览、列表行、进入状态屏、全屏提醒、启动器的状态行）——还没下好、没联网时先画
//   那个表情的系统样子（Segoe UI Emoji），下好了画它的那个元素自己换成动画 / 静止画面（StatusEmoji）。同一个同时只下一次；下不成的这次运行里
//   10 分钟内不再试。mac 还没下好时垫包里带的缩略图（746 张 96 × 96 约 3.2 MB），Windows 不带：系统表情就是同一个表情、不占包。
// - 开关「自动下载动画表情」（Settings.EmojiPackDownloads，默认开，设置 › 状态屏「动画」、设置 › 提醒「图标」两处）：关掉就不联网，已经下好的照用。
// - 下载时只带表情编号（地址里那一段）；下下来的按不可信输入看：跳转每一跳只认本仓库的 release 和 GitHub 的资产主机、不超过 3 MB、
//   tEXt 块和图的大小对得上才存（Core 的 EmojiPackRemote / EmojiPackFile）；先写临时名再换过去，写到一半的不会被当成好的。
// - 发表情包之前在本机试：环境变量 KITTY_EMOJI_PACK_SERVER=http://127.0.0.1:<端口>（只认 http 的 127.0.0.1 / localhost），
//   在 --pack 的输出目录起一个静态文件服务器（同 mac 的 emojiPackTestServer）。只在测试档认（Debug，或 Release 的 KITTY_PROBE_PROFILE），
//   同自动更新的测试源。
// - 一次下载最多 60 秒（正文传到一半卡住也停，HttpClient.Timeout 只管到响应头）；缓存里的文件结构对、像素却解不开时删掉，过 10 分钟再下。
// - 日志只写编号和成没成，不写地址。
using System.Net;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class EmojiPack
{
    private static readonly Lazy<EmojiPackCatalog?> LazyCatalog = new(LoadCatalog);
    private static readonly Dictionary<string, Task<bool>> Loading = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, DateTime> FailedAt = new(StringComparer.Ordinal);
    private static readonly HttpClient Http = CreateClient();
    private static bool _trimmed;

    /// <summary>正在收拾缓存（线程池里）：同一时间只跑一个。</summary>
    private static int _trimming;

    /// <summary>一次下载最多多久（连上、收头、收完正文）。</summary>
    private static readonly TimeSpan DownloadLimit = TimeSpan.FromSeconds(60);

    /// <summary>包里的对照表；读不出来是 null（当没有动画包：「动画表情」那一格不出，存着的 pack: 画成空格子）。</summary>
    public static EmojiPackCatalog? Catalog => LazyCatalog.Value;

    public static string Folder => Path.Combine(Paths.DataDirectory, EmojiPackCache.FolderName);

    /// <summary>开关开着才联网。</summary>
    public static bool IsEnabled => SettingsService.Current.EmojiPackDownloads;

    /// <summary>本机测试服务器：只在测试档认（同自动更新的测试源只在 Debug / 自检认，R107 审查）。</summary>
    private static string? TestServer
        => Paths.IsTestProfile ? Environment.GetEnvironmentVariable(EmojiPackRemote.TestServerVariable) : null;

    private static HttpClient CreateClient()
    {
        // 自己跳转（每一跳都过白名单），不带 Cookie；文件自己存一份，不进系统的网址缓存（HttpClient 本来就没有）。
        var client = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.None,
        })
        {
            Timeout = TimeSpan.FromSeconds(20),
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("KittyTools-Windows");
        return client;
    }

    private static EmojiPackCatalog? LoadCatalog()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "StatusEmoji", "emoji-pack.json");
            var catalog = EmojiPackCatalog.Parse(File.ReadAllText(path, System.Text.Encoding.UTF8));
            if (catalog is null)
            {
                Log.Warn("status.emoji-pack-catalog-unreadable");
            }

            return catalog;
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-pack-catalog-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>「pack:编号」里的编号（在这一版的对照表里、不是自带的）：要下载 / 从缓存画的那种；别的是 null。</summary>
    public static string? DownloadableId(string symbol)
        => Catalog is { } catalog && catalog.PackId(symbol) is { } id && EmojiPackCatalog.BundledFile(id) is null ? id : null;

    /// <summary>那个编号的表情字（还没下好时画它的系统样子）；不认识的是 null。</summary>
    public static string? Glyph(string symbol)
        => Catalog is { } catalog && catalog.PackId(symbol) is { } id ? catalog.Find(id)?.Glyph : null;

    private static string CachePath(string id) => Path.Combine(Folder, id + ".png");

    /// <summary>
    /// 要用到了：表情包里的（不是自带的）——缓存里有就读出来（碰一下修改时间），没有、开关开着、10 分钟内没失败过就下。
    /// 给出文件的字节和怎么切；不成是 null（调用方停在系统表情）。只在 UI 线程上调。
    /// </summary>
    public static async Task<(byte[] Bytes, EmojiSheet Sheet)?> LoadAsync(string symbol)
    {
        if (DownloadableId(symbol) is not { } id || Catalog is not { } catalog)
        {
            return null;
        }

        if (!_trimmed)
        {
            _trimmed = true;
            TrimSoon();
        }

        if (await ReadCachedAsync(id) is { } cached)
        {
            return cached;
        }

        if (!IsEnabled || !EmojiPackCache.MayRetry(FailedAt.TryGetValue(id, out var failed) ? (DateTime?)failed : null, DateTime.UtcNow))
        {
            return null;
        }

        if (!Loading.TryGetValue(id, out var download))
        {
            download = DownloadAsync(id, catalog.Tag);
            Loading[id] = download;
        }

        bool done;
        try
        {
            done = await download;
        }
        finally
        {
            Loading.Remove(id);
        }

        if (!done)
        {
            FailedAt[id] = DateTime.UtcNow;
            return null;
        }

        FailedAt.Remove(id);
        return await ReadCachedAsync(id);
    }

    /// <summary>缓存里的那份：读出来、再核一遍格式（文件可能被别的东西动过），碰一下修改时间。没有、读不出、不对是 null。</summary>
    private static async Task<(byte[] Bytes, EmojiSheet Sheet)?> ReadCachedAsync(string id)
    {
        var path = CachePath(id);
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length > EmojiPackFile.MaxBytes)
            {
                return null;
            }

            var bytes = await File.ReadAllBytesAsync(path);
            if (EmojiPackFile.Read(bytes) is not { } sheet)
            {
                Log.Warn($"status.emoji-pack-cache-bad {id}");
                File.Delete(path);
                return null;
            }

            File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
            return (bytes, sheet);
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-pack-cache-failed {id} {ex.GetType().Name}");
            return null;
        }
    }

    private static async Task<bool> DownloadAsync(string id, string tag)
    {
        var testServer = TestServer;
        if (EmojiPackRemote.Url(id, tag, testServer) is not { } url)
        {
            return false;
        }

        // 整个下载的时限：正文卡住也停（不然 Loading 里一直挂着，这次运行再也不试）；到点 FetchAsync 给 null，按失败记
        using var limit = new CancellationTokenSource(DownloadLimit);
        var bytes = await EmojiPackRemote.FetchAsync(Http, url, testServer, limit.Token);
        if (bytes is null)
        {
            Log.Warn($"status.emoji-pack-download-failed {id}");
            return false;
        }

        var target = CachePath(id);
        var temp = target + ".partial";
        try
        {
            Directory.CreateDirectory(Folder);
            await File.WriteAllBytesAsync(temp, bytes);
            File.Move(temp, target, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-pack-store-failed {id} {ex.GetType().Name}");
            try
            {
                File.Delete(temp);
            }
            catch (Exception)
            {
                // 删不掉的临时文件下次 Trim 收拾
            }

            return false;
        }

        Log.Info($"status.emoji-pack-downloaded {id} bytes={bytes.Length}");
        TrimSoon();
        return true;
    }

    /// <summary>
    /// 缓存里这个表情的文件结构对、像素却解不开（StatusEmoji 加载失败时调）：删掉，记一次失败——过 10 分钟再用到时重新下
    /// （不当场重下：服务器上那个本身坏了的话会一直下）。
    /// </summary>
    public static void Forget(string symbol)
    {
        if (DownloadableId(symbol) is not { } id)
        {
            return;
        }

        FailedAt[id] = DateTime.UtcNow;
        try
        {
            File.Delete(CachePath(id));
            Log.Warn($"status.emoji-pack-undecodable {id}");
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-pack-forget-failed {id} {ex.GetType().Name}");
        }
    }

    /// <summary>在线程池里收拾一次缓存；上一次还没收拾完就不再起（两个同时删会互相踩）。</summary>
    private static void TrimSoon()
    {
        if (Interlocked.CompareExchange(ref _trimming, 1, 0) != 0)
        {
            return;
        }

        _ = Task.Run(() =>
        {
            try
            {
                Trim();
            }
            finally
            {
                Volatile.Write(ref _trimming, 0);
            }
        });
    }

    /// <summary>
    /// 把缓存收到上限以内，顺手删掉没写完的临时文件（线程池里列目录、删文件）。一个文件删不掉（被占着、没权限）只跳过它，
    /// 别的照删。
    /// </summary>
    private static void Trim()
    {
        List<EmojiPackCache.CachedFile> files;
        try
        {
            if (!Directory.Exists(Folder))
            {
                return;
            }

            foreach (var partial in Directory.EnumerateFiles(Folder, "*.partial"))
            {
                // 正在写的那个刚建出来：只删放了一会儿的
                Delete(partial, File.Exists(partial) && DateTime.UtcNow - File.GetLastWriteTimeUtc(partial) > TimeSpan.FromMinutes(5));
            }

            files = new DirectoryInfo(Folder).EnumerateFiles("*.png")
                .Select(file => new EmojiPackCache.CachedFile(file.Name, file.Length, file.LastWriteTimeUtc))
                .ToList();
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-pack-trim-failed {ex.GetType().Name}");
            return;
        }

        foreach (var name in EmojiPackCache.Overflow(files, EmojiPackCache.MaxBytes))
        {
            Delete(Path.Combine(Folder, name), true);
        }
    }

    private static void Delete(string path, bool due)
    {
        if (!due)
        {
            return;
        }

        try
        {
            File.Delete(path);
        }
        catch (Exception ex)
        {
            Log.Warn($"status.emoji-pack-trim-skip {ex.GetType().Name}");
        }
    }
}
