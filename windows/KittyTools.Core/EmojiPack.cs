// 动画表情包的纯逻辑（REVIEW R107，照 mac StatusScreen/EmojiPack.swift + Settings/AnimatedEmojiPicker.swift 的纯函数）：
// 对照表（App 包里的 Resources\StatusEmoji\emoji-pack.json，同 mac 的那份、tag 换成 Windows 自己的 release）、搜索、「动画表情」气泡的分段
// 和「常用」、编号和自带表情的对应、包里文件的格式（帧图集 PNG + 一个 tEXt 块写着格子 / 列数 / 帧数 / 每帧毫秒，tools/status-emoji.swift --pack 写的）、
// 缓存超上限删哪些、下载地址和下载（跳转每一跳都核地址、限大小、下完核格式）。App 那边（StatusScreen/EmojiPack.cs）管什么时候下、存哪、画。
// Windows 的包不能用 mac 的 HEICS（Windows 不一定装了 HEIF 解码器），所以是自己的 release emoji-pack-1-win。
using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core;

/// <summary>对照表里的一个：编号、表情字（去掉了 U+FE0F）、分类、中文名、搜索用的中文 / 英文关键词。</summary>
public sealed record EmojiPackEntry(string Id, string Glyph, string Group, string Name, IReadOnlyList<string> Keywords);

/// <summary>「动画表情」气泡里的一段：分类编号 + 这一段的表情。</summary>
public sealed record EmojiPackSection(string Id, IReadOnlyList<EmojiPackEntry> Entries);

public sealed class EmojiPackCatalog
{
    /// <summary>包里的编号和自带的不一样的那几个（其余同名，mac bundledAliases）：挑到这几个时直接用自带的。</summary>
    public static readonly IReadOnlyDictionary<string, string> BundledAliases = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["telephone-receiver"] = "telephone",
        ["busts-in-silhouette"] = "busts",
        ["hourglass-not-done"] = "hourglass",
        ["person-in-lotus-position"] = "lotus-position",
    };

    /// <summary>
    /// 分类（mac AnimatedEmojiPicker.categories 的编号和名字；底下那排的图标在 App 里）：「常用」= 最近挑过的，其余同对照表的 group。
    /// </summary>
    public static readonly (string Id, string Title)[] Categories =
    {
        ("recent", "常用"), ("people", "表情与人物"), ("nature", "动物与自然"), ("food", "食物"), ("activities", "活动"),
        ("travel", "旅行与地点"), ("objects", "物品"), ("flags", "旗帜"),
    };

    /// <summary>「常用」最多几个（三行）。</summary>
    public const int RecentLimit = 18;

    private readonly Dictionary<string, EmojiPackEntry> _byId;

    private EmojiPackCatalog(string tag, List<EmojiPackEntry> entries)
    {
        Tag = tag;
        Entries = entries;
        _byId = new Dictionary<string, EmojiPackEntry>(StringComparer.Ordinal);
        foreach (var entry in entries)
        {
            _byId.TryAdd(entry.Id, entry);
        }
    }

    /// <summary>release 的 tag（下载地址里那一段）。</summary>
    public string Tag { get; }

    public IReadOnlyList<EmojiPackEntry> Entries { get; }

    /// <summary>
    /// 读对照表：{"emoji":[{"id","glyph","group","name","keywords":[…]}…],"tag":"…"}。编号不合规的条目丢掉（地址、文件名拿它拼）；
    /// tag 只许 [A-Za-z0-9._-]；整个读不出来是 null（App 当没有动画包，只画静态）。
    /// </summary>
    public static EmojiPackCatalog? Parse(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("tag", out var tagElement) ||
                tagElement.ValueKind != JsonValueKind.String || !root.TryGetProperty("emoji", out var list) ||
                list.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var tag = tagElement.GetString() ?? string.Empty;
            if (tag.Length is 0 or > 64 || !tag.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-'))
            {
                return null;
            }

            var entries = new List<EmojiPackEntry>();
            foreach (var item in list.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object || Text(item, "id") is not { } id || !StatusEmojiCatalog.IsPackId(id))
                {
                    continue;
                }

                var keywords = new List<string>();
                if (item.TryGetProperty("keywords", out var words) && words.ValueKind == JsonValueKind.Array)
                {
                    keywords.AddRange(words.EnumerateArray()
                        .Where(word => word.ValueKind == JsonValueKind.String)
                        .Select(word => word.GetString() ?? string.Empty));
                }

                entries.Add(new EmojiPackEntry(
                    id, Text(item, "glyph") ?? string.Empty, Text(item, "group") ?? "objects", Text(item, "name") ?? id, keywords));
            }

            return new EmojiPackCatalog(tag, entries);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public bool Contains(string id) => _byId.ContainsKey(id);

    public EmojiPackEntry? Find(string id) => _byId.GetValueOrDefault(id);

    /// <summary>「pack:编号」里的编号（要在这份对照表里）；别的是 null（mac packID）。</summary>
    public string? PackId(string symbol)
        => StatusEmojiCatalog.IsPackSymbol(symbol) && Contains(symbol[StatusEmojiCatalog.PackPrefix.Length..])
            ? symbol[StatusEmojiCatalog.PackPrefix.Length..]
            : null;

    /// <summary>动画包的编号如果是自带的那 28 个之一，自带的 id（不下载，mac bundledID）。</summary>
    public static string? BundledId(string packId)
    {
        var id = BundledAliases.GetValueOrDefault(packId, packId);
        return StatusEmojiCatalog.Ids.Contains(id) ? id : null;
    }

    /// <summary>包里带着动画的（自带的 28 个、眼睛）：不下载，直接用包里的（mac bundledFile）。</summary>
    public static string? BundledFile(string packId)
        => BundledId(packId) ?? (packId == StatusEmojiCatalog.Eyes ? packId : null);

    /// <summary>动画表情包里一个编号存成什么：自带的那 28 个之一就是自带的 id，别的是「pack:编号」（mac symbol(forPack:)）。</summary>
    public static string SymbolFor(string packId) => BundledId(packId) ?? StatusEmojiCatalog.PackPrefix + packId;

    /// <summary>
    /// 存的值整理成一种写法（mac canonical）：「pack:编号」正好是自带的同一个动画（🚀、👥…）就换成自带的 id——垫浅底 / 亮光按 id 认、
    /// 格子里亮的是那一格。系统表情（字）不换：用户要的就是系统的样子。
    /// </summary>
    public string Canonical(string symbol)
        => PackId(symbol) is { } pack && BundledId(pack) is { } bundled ? bundled : symbol;

    /// <summary>读屏读的名字：自带的读中文名，表情包里的读对照表里的名字，系统表情读它本身（mac name）。</summary>
    public string? Name(string symbol)
        => StatusEmojiCatalog.Name(symbol) ?? (PackId(symbol) is { } pack ? Find(pack)?.Name :
            StatusEmojiCatalog.IsCustom(symbol) ? symbol : null);

    /// <summary>图标预览下面那行字（mac caption）：自带的、表情包里的写名字，系统表情写「系统表情」。</summary>
    public string Caption(string symbol)
    {
        var id = Canonical(symbol);
        return StatusEmojiCatalog.Name(id) ?? (PackId(id) is { } pack ? Find(pack)?.Name ?? "动画表情" :
            StatusEmojiCatalog.IsCustom(id) ? "系统表情" : string.Empty);
    }

    /// <summary>
    /// 搜（mac EmojiPack.search）：空格分开的词都要对上中文名、关键词或表情字本身（不分大小写）；没写词就是全部。
    /// 查询去掉 U+FE0F（对照表里的字去掉了它，系统表情面板插进来的「❤️」带着）。
    /// </summary>
    public static IReadOnlyList<EmojiPackEntry> Search(string query, IReadOnlyList<EmojiPackEntry> list)
    {
        var words = query.Replace("\uFE0F", string.Empty, StringComparison.Ordinal)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0)
        {
            return list;
        }

        return list.Where(entry => words.All(word =>
                entry.Name.Contains(word, StringComparison.OrdinalIgnoreCase) ||
                entry.Glyph.Contains(word, StringComparison.OrdinalIgnoreCase) ||
                entry.Keywords.Any(keyword => keyword.Contains(word, StringComparison.OrdinalIgnoreCase))))
            .ToList();
    }

    /// <summary>不搜时的几段（mac sections）：「常用」（最近挑过的、对照表里还有的）在前，再照分类的先后；空的段不要。</summary>
    public IReadOnlyList<EmojiPackSection> Sections(IReadOnlyList<string> recent)
    {
        var sections = new List<EmojiPackSection>
        {
            new("recent", recent.Select(Find).OfType<EmojiPackEntry>().ToList()),
        };
        sections.AddRange(Categories.Skip(1).Select(category =>
            new EmojiPackSection(category.Id, Entries.Where(entry => entry.Group == category.Id).ToList())));
        return sections.Where(section => section.Entries.Count > 0).ToList();
    }

    /// <summary>挑了一个之后的「常用」（mac recent(after:in:)）：挪到最前、不重复、最多 RecentLimit 个。</summary>
    public static IReadOnlyList<string> Recent(string picked, IReadOnlyList<string> list)
        => new[] { picked }.Concat(list.Where(id => id != picked)).Take(RecentLimit).ToList();

    /// <summary>设置里存的「常用」（逗号隔开）→ 编号表；不合规的丢掉。</summary>
    public static IReadOnlyList<string> ParseRecent(string? stored)
        => (stored ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Where(StatusEmojiCatalog.IsPackId).Distinct(StringComparer.Ordinal).Take(RecentLimit).ToList();
}

/// <summary>一张帧图集怎么切：格子边长、列数、帧数、每帧毫秒（Durations.Length == Count）。</summary>
public sealed record EmojiSheet(int Cell, int Columns, int Count, IReadOnlyList<int> Durations)
{
    public int Rows => (Count + Columns - 1) / Columns;

    public int Total => Durations.Sum();

    /// <summary>manifest.txt 那一行去掉 id（tEXt 块里写的也是它）：格子边长 \t 列数 \t 帧数 \t 每帧毫秒（逗号隔开）。</summary>
    public string Encode()
        => string.Join('\t', Cell.ToString(CultureInfo.InvariantCulture), Columns.ToString(CultureInfo.InvariantCulture),
            Count.ToString(CultureInfo.InvariantCulture), string.Join(',', Durations.Select(ms => ms.ToString(CultureInfo.InvariantCulture))));

    /// <summary>
    /// 读那一行。格子 1…512、列数 1…16、帧数 2…256、列数够摆下（不多出一整行）、每帧毫秒是整数（夹到 10…2000）、个数对得上；不对是 null。
    /// </summary>
    public static EmojiSheet? Decode(string text)
    {
        var parts = text.Split('\t');
        if (parts.Length != 4 || !TryInt(parts[0], out var cell) || !TryInt(parts[1], out var columns) || !TryInt(parts[2], out var count) ||
            cell is < 1 or > 512 || columns is < 1 or > 16 || count is < 2 or > 256 || (count + columns - 1) / columns > 16)
        {
            return null;
        }

        var durations = new List<int>(count);
        foreach (var part in parts[3].Split(','))
        {
            if (!TryInt(part, out var ms))
            {
                return null;
            }

            durations.Add(Math.Clamp(ms, 10, 2000));
        }

        return durations.Count == count ? new EmojiSheet(cell, columns, count, durations) : null;
    }

    private static bool TryInt(string text, out int value)
        => int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value);
}

/// <summary>表情包里的一个文件：帧图集 PNG，tEXt 块（关键字 kitty-emoji）里写着怎么切。下下来的按不可信输入核。</summary>
public static class EmojiPackFile
{
    public const string Keyword = "kitty-emoji";

    /// <summary>格子边长（同包里自带的，tools/status-emoji.swift 的 cell）。</summary>
    public const int Cell = 160;

    /// <summary>一个文件最多这么大（mac maxFileBytes 3 MB；160 像素 12 帧的图集实测 0.2–0.8 MB）。</summary>
    public const int MaxBytes = 3 * 1024 * 1024;

    private static ReadOnlySpan<byte> Signature => new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    /// <summary>
    /// 核一个下下来的文件，能放就给出怎么切（mac isPlayable）：不超过 MaxBytes、PNG 签名、头一块是 IHDR（8 位 RGBA、不隔行）、
    /// 块的长度不越界、IHDR 和 tEXt 的校验对、有 IDAT、以 IEND 收尾、tEXt 里那一行读得出、格子是 160、宽高正好是列数 × 行数个格子。
    /// 像素解不解得开由 App 解的时候再看（解不开就停在系统表情）。
    /// </summary>
    public static EmojiSheet? Read(ReadOnlySpan<byte> png)
    {
        if (png.Length > MaxBytes || png.Length < 8 + 25 + 12 || !png[..8].SequenceEqual(Signature))
        {
            return null;
        }

        int width = 0, height = 0;
        var pos = 8;
        var sawData = false;
        EmojiSheet? sheet = null;
        while (pos + 12 <= png.Length)
        {
            var start = pos;
            var length = BinaryPrimitives.ReadUInt32BigEndian(png.Slice(start, 4));
            if (length > (uint)(png.Length - start - 12))
            {
                return null;
            }

            var size = (int)length;
            var type = png.Slice(start + 4, 4);
            var body = png.Slice(start + 8, size);
            var checksummed = Crc32(png.Slice(start + 4, 4 + size)) == BinaryPrimitives.ReadUInt32BigEndian(png.Slice(start + 8 + size, 4));
            pos = start + 12 + size;
            if (start == 8)
            {
                // 头一块必须是 IHDR：8 位、RGBA（色彩类型 6）、不隔行
                if (!type.SequenceEqual("IHDR"u8) || size != 13 || !checksummed || body[8] != 8 || body[9] != 6 || body[12] != 0)
                {
                    return null;
                }

                width = (int)Math.Min(BinaryPrimitives.ReadUInt32BigEndian(body[..4]), int.MaxValue);
                height = (int)Math.Min(BinaryPrimitives.ReadUInt32BigEndian(body.Slice(4, 4)), int.MaxValue);
            }
            else if (type.SequenceEqual("IDAT"u8))
            {
                sawData = true;
            }
            else if (type.SequenceEqual("tEXt"u8) && body.Length > Keyword.Length && body[Keyword.Length] == 0 &&
                     body[..Keyword.Length].SequenceEqual("kitty-emoji"u8))
            {
                if (!checksummed)
                {
                    return null;
                }

                sheet = EmojiSheet.Decode(Encoding.ASCII.GetString(body[(Keyword.Length + 1)..]));
            }
            else if (type.SequenceEqual("IEND"u8))
            {
                return sawData && pos == png.Length && sheet is { } found && found.Cell == Cell &&
                       width == found.Columns * found.Cell && height == found.Rows * found.Cell
                    ? found
                    : null;
            }
        }

        return null;
    }

    /// <summary>
    /// 在 IEND 前插 tEXt 块（同 tools/status-emoji.swift --pack 的 withText）：单测拿包里自带的图集 + manifest 那一行拼出表情包的文件。
    /// 不是以 IEND 收尾的原样返回。
    /// </summary>
    public static byte[] Embed(byte[] png, EmojiSheet sheet)
    {
        ReadOnlySpan<byte> iend = new byte[] { 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82 };
        if (png.Length < 20 || !png.AsSpan(png.Length - 12).SequenceEqual(iend))
        {
            return png;
        }

        var body = Encoding.ASCII.GetBytes("tEXt" + Keyword + "\0" + sheet.Encode());
        var chunk = new byte[12 + body.Length - 4];
        BinaryPrimitives.WriteUInt32BigEndian(chunk, (uint)(body.Length - 4));
        body.CopyTo(chunk, 4);
        BinaryPrimitives.WriteUInt32BigEndian(chunk.AsSpan(4 + body.Length), Crc32(body));
        return png[..^12].Concat(chunk).Concat(iend.ToArray()).ToArray();
    }

    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++)
        {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        }

        return c;
    }).ToArray();

    /// <summary>PNG 块的 CRC-32（ISO 3309，同 zlib crc32）：块类型 + 数据。</summary>
    public static uint Crc32(ReadOnlySpan<byte> bytes)
    {
        var c = 0xFFFFFFFFu;
        foreach (var b in bytes)
        {
            c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        }

        return c ^ 0xFFFFFFFFu;
    }
}

/// <summary>缓存的上限（mac overflow）。</summary>
public static class EmojiPackCache
{
    /// <summary>缓存目录在数据目录下的名字（不备份、不导出、不同步）。</summary>
    public const string FolderName = "emoji-pack";

    /// <summary>缓存最多这么大（mac maxCacheBytes 50 MB）。</summary>
    public const long MaxBytes = 50L * 1024 * 1024;

    /// <summary>下不成的这次运行里多久内不再试（mac retryAfter 10 分钟）。</summary>
    public static readonly TimeSpan RetryAfter = TimeSpan.FromMinutes(10);

    public sealed record CachedFile(string Name, long Bytes, DateTime UsedAt);

    /// <summary>超过上限时删哪些：从最久没用的删起，删到不超过为止（用一次把修改时间碰成现在）。</summary>
    public static IReadOnlyList<string> Overflow(IEnumerable<CachedFile> files, long limit)
    {
        var list = files.ToList();
        var total = list.Sum(file => file.Bytes);
        var doomed = new List<string>();
        foreach (var file in list.OrderBy(file => file.UsedAt).ThenBy(file => file.Name, StringComparer.Ordinal))
        {
            if (total <= limit)
            {
                break;
            }

            doomed.Add(file.Name);
            total -= file.Bytes;
        }

        return doomed;
    }

    /// <summary>这次运行里上次下不成是什么时候：RetryAfter 以内不再试。</summary>
    public static bool MayRetry(DateTime? failedAt, DateTime now) => failedAt is not { } failed || now - failed >= RetryAfter;
}

/// <summary>下载地址和下载（mac remoteURL / download）。</summary>
public static class EmojiPackRemote
{
    /// <summary>Windows 自己的表情包 release（mac 的是 emoji-pack-1，里面是 HEICS）。</summary>
    public const string Tag = "emoji-pack-1-win";

    /// <summary>发表情包之前在本机试：这个环境变量设成 http://127.0.0.1:端口（或 localhost）时从那里下（mac Prefs.emojiPackTestServer）。</summary>
    public const string TestServerVariable = "KITTY_EMOJI_PACK_SERVER";

    private const int MaxRedirects = 5;

    /// <summary>本机测试服务器：只认 http 的 127.0.0.1 / localhost，带不带端口都行，后面不带路径以外的东西。</summary>
    public static Uri? TestServer(string? value)
        => Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttp &&
           (uri.Host == "127.0.0.1" || string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase)) &&
           string.IsNullOrEmpty(uri.UserInfo) && string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.Fragment)
            ? uri
            : null;

    /// <summary>
    /// 一个编号的下载地址：本仓库那个 release 里的 &lt;编号&gt;.png；设了本机测试服务器时是那里的。编号、tag 不合规是 null。
    /// 下载时只带这个编号（地址里的那一段），不带别的。
    /// </summary>
    public static string? Url(string id, string tag, string? testServer)
    {
        if (!StatusEmojiCatalog.IsPackId(id) || tag.Length is 0 or > 64 || !tag.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-'))
        {
            return null;
        }

        if (TestServer(testServer) is { } server)
        {
            return new Uri(server, server.AbsolutePath.TrimEnd('/') + "/" + id + ".png").AbsoluteUri;
        }

        return $"https://github.com/YyAdnBug/kitty-tools/releases/download/{tag}/{id}.png";
    }

    /// <summary>这一跳能不能去：GitHub 本仓库的 release 下载地址和它跳去的资产主机（同 App 内更新的白名单），或者设了的本机测试服务器。</summary>
    public static bool IsAllowed(string url, string? testServer)
    {
        if (UpdateTrust.IsAllowedDownloadUrl(url))
        {
            return true;
        }

        return TestServer(testServer) is { } server && Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
               uri.Scheme == server.Scheme && string.Equals(uri.Host, server.Host, StringComparison.OrdinalIgnoreCase) &&
               uri.Port == server.Port;
    }

    /// <summary>
    /// 下一个文件：client 不能自动跳转（自己跳，每一跳都过 IsAllowed）；200 才收，声明的长度、实际读到的都不超过 EmojiPackFile.MaxBytes，
    /// 下完过 EmojiPackFile.Read。不成（网络、地址、大小、格式）一律 null，不抛（取消照常抛 OperationCanceledException）。
    /// </summary>
    public static async Task<byte[]?> FetchAsync(HttpClient client, string url, string? testServer, CancellationToken cancellationToken)
    {
        try
        {
            var current = url;
            for (var hop = 0; hop <= MaxRedirects; hop++)
            {
                if (!IsAllowed(current, testServer))
                {
                    return null;
                }

                using var response = await client.GetAsync(current, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                    .ConfigureAwait(false);
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                {
                    if (response.Headers.Location is not { } location)
                    {
                        return null;
                    }

                    current = UpdateTrust.NextHop(current, location);
                    continue;
                }

                if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentLength > EmojiPackFile.MaxBytes)
                {
                    return null;
                }

                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                using var buffer = new MemoryStream();
                var chunk = new byte[81920];
                int read;
                while ((read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    if (buffer.Length + read > EmojiPackFile.MaxBytes)
                    {
                        return null;
                    }

                    buffer.Write(chunk, 0, read);
                }

                var bytes = buffer.ToArray();
                return EmojiPackFile.Read(bytes) is null ? null : bytes;
            }

            return null;
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidOperationException or UriFormatException ||
                                   (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            // 超时（HttpClient 的超时是 TaskCanceledException，但不是我们取消的）、连不上、读一半断了
            return null;
        }
    }
}
