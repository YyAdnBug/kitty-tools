// REVIEW R107：动画表情包（照 mac StatusScreenTests 里 EmojiPack 那几组）——对照表、搜索、分段和「常用」、和自带的对应、
// 文件格式（Fixtures/emoji-pack/person-walking.png 是 tools/status-emoji.swift --pack 从本机的原文件真转出来的，再过了一遍无损压缩）、
// 缓存上限、下载地址；最后起一个本机的临时 HTTP 服务（只认 127.0.0.1，TcpListener，不用管理员权限）真的下一遍：
// 跳转、404、太大、校验不对、没有 tEXt 块、跳去别的主机都不收（同 mac 4ada1f35 的本机试用）。
using System.Net;
using System.Net.Sockets;
using System.Text;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class EmojiPackTests
{
    private static readonly string Fixtures = Path.Combine(AppContext.BaseDirectory, "Fixtures");

    private static EmojiPackCatalog Catalog()
        => EmojiPackCatalog.Parse(File.ReadAllText(Path.Combine(Fixtures, "emoji-pack.json"), Encoding.UTF8))
           ?? throw new AssertFailedException("对照表读不出来");

    private static byte[] Walking() => File.ReadAllBytes(Path.Combine(Fixtures, "emoji-pack", "person-walking.png"));

    [TestMethod]
    public void CatalogMatchesTheBundledEmoji()
    {
        var catalog = Catalog();
        Assert.AreEqual(EmojiPackRemote.Tag, catalog.Tag, "Windows 自己的 release");
        Assert.AreEqual(746, catalog.Entries.Count);
        CollectionAssert.AllItemsAreUnique(catalog.Entries.Select(entry => entry.Id).ToList());
        Assert.IsTrue(catalog.Entries.All(entry => StatusEmojiCatalog.IsPackId(entry.Id)));
        // 自带的 28 个都在表里（有的换了名字），所以从「动画表情」里挑到它们时存自带的 id、不下载
        foreach (var id in StatusEmojiCatalog.Ids)
        {
            Assert.IsTrue(catalog.Contains(id) || EmojiPackCatalog.BundledAliases.Values.Contains(id), id);
        }

        Assert.AreEqual("rocket", EmojiPackCatalog.SymbolFor("rocket"));
        Assert.AreEqual("telephone", EmojiPackCatalog.SymbolFor("telephone-receiver"));
        Assert.AreEqual("lotus-position", EmojiPackCatalog.SymbolFor("person-in-lotus-position"));
        Assert.AreEqual("pack:dog-face", EmojiPackCatalog.SymbolFor("dog-face"));
        Assert.AreEqual("eyes", EmojiPackCatalog.BundledFile("eyes"), "眼睛用包里的");
        Assert.IsNull(EmojiPackCatalog.BundledFile("dog-face"));

        Assert.AreEqual("dog-face", catalog.PackId("pack:dog-face"));
        Assert.IsNull(catalog.PackId("pack:not-in-this-version"), "更新版本的编号能存（IsStorable），这一版不画不下");
        Assert.IsTrue(StatusEmojiCatalog.IsStorable("pack:not-in-this-version"));
        Assert.IsNull(catalog.PackId("rocket"));
        Assert.AreEqual("rocket", catalog.Canonical("pack:rocket"), "和自带的同一个动画按自带的画（垫浅底 / 亮光按 id 认）");
        Assert.AreEqual("busts", catalog.Canonical("pack:busts-in-silhouette"));
        Assert.AreEqual("🚀", catalog.Canonical("🚀"), "系统表情不换成动画版");
        Assert.AreEqual("pack:dog-face", catalog.Canonical("pack:dog-face"));

        Assert.AreEqual("火箭", catalog.Caption("pack:rocket"));
        Assert.AreEqual("狗脸", catalog.Caption("pack:dog-face"));
        Assert.AreEqual("系统表情", catalog.Caption("🍵"));
        Assert.AreEqual(string.Empty, catalog.Caption(string.Empty));
        Assert.AreEqual("狗脸", catalog.Name("pack:dog-face"));
        Assert.AreEqual("🍵", catalog.Name("🍵"));
        Assert.AreEqual("厨师", catalog.Name("cook"));
    }

    [TestMethod]
    public void CatalogRejectsJunk()
    {
        Assert.IsNull(EmojiPackCatalog.Parse("not json"));
        Assert.IsNull(EmojiPackCatalog.Parse("{\"emoji\":[]}"), "没有 tag");
        Assert.IsNull(EmojiPackCatalog.Parse("{\"emoji\":[],\"tag\":\"../x\"}"), "tag 拼进地址，只许字母数字 . _ -");
        var catalog = EmojiPackCatalog.Parse(
            "{\"emoji\":[{\"id\":\"ok-1\",\"glyph\":\"🐶\",\"group\":\"nature\",\"name\":\"狗\",\"keywords\":[\"dog\",1]}," +
            "{\"id\":\"../bad\",\"glyph\":\"x\"},{\"id\":\"UPPER\"},{\"glyph\":\"无编号\"}],\"tag\":\"t-1\"}")!;
        Assert.AreEqual(1, catalog.Entries.Count, "编号不合规的丢掉");
        CollectionAssert.AreEqual(new[] { "dog" }, catalog.Entries[0].Keywords.ToList(), "不是字的关键词丢掉");
    }

    [TestMethod]
    public void SearchSectionsAndRecent()
    {
        var catalog = Catalog();
        var all = catalog.Entries;
        Assert.AreSame(all, EmojiPackCatalog.Search("  ", all), "没写词就是全部");
        Assert.IsTrue(EmojiPackCatalog.Search("狗", all).Any(entry => entry.Id == "dog-face"));
        Assert.IsTrue(EmojiPackCatalog.Search("DOG face", all).Any(entry => entry.Id == "dog-face"), "英文、不分大小写、两个词都要对上");
        Assert.IsTrue(EmojiPackCatalog.Search("🐶", all).Any(entry => entry.Id == "dog-face"), "表情字本身");
        CollectionAssert.AreEqual(
            EmojiPackCatalog.Search("❤", all).Select(entry => entry.Id).ToList(),
            EmojiPackCatalog.Search("❤\uFE0F", all).Select(entry => entry.Id).ToList(),
            "查询去掉 U+FE0F");
        Assert.AreEqual(0, EmojiPackCatalog.Search("狗 火箭", all).Count);

        var plain = catalog.Sections(Array.Empty<string>());
        Assert.AreEqual("people", plain[0].Id, "没挑过就没有「常用」");
        Assert.IsTrue(plain.All(section => section.Entries.Count > 0));
        Assert.AreEqual(all.Count, plain.Sum(section => section.Entries.Count), "每个都在某一段里");
        var order = EmojiPackCatalog.Categories.Select(category => category.Id).ToList();
        Assert.IsTrue(plain.Select(section => order.IndexOf(section.Id)).SequenceEqual(plain.Select(section => order.IndexOf(section.Id)).Order()));

        var withRecent = catalog.Sections(new[] { "rocket", "gone", "dog-face" });
        Assert.AreEqual("recent", withRecent[0].Id);
        CollectionAssert.AreEqual(new[] { "rocket", "dog-face" }, withRecent[0].Entries.Select(entry => entry.Id).ToList(), "表里没有的不画");

        var recent = EmojiPackCatalog.Recent("b", new[] { "a", "b", "c" });
        CollectionAssert.AreEqual(new[] { "b", "a", "c" }, recent.ToList());
        var many = Enumerable.Range(0, 30).Select(index => $"e{index}").ToList();
        Assert.AreEqual(EmojiPackCatalog.RecentLimit, EmojiPackCatalog.Recent("new", many).Count);
        CollectionAssert.AreEqual(new[] { "a-1", "b" }, EmojiPackCatalog.ParseRecent("a-1,,B,../x,b,a-1").ToList(), "存的不合规的丢掉、去重");
        Assert.AreEqual(0, EmojiPackCatalog.ParseRecent(null).Count);
    }

    [TestMethod]
    public void SheetLines()
    {
        var sheet = EmojiSheet.Decode("160\t5\t17\t84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,42")!;
        Assert.AreEqual(160, sheet.Cell);
        Assert.AreEqual(4, sheet.Rows);
        Assert.AreEqual(84 * 16 + 42, sheet.Total);
        Assert.AreEqual("160\t5\t17\t84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,42", sheet.Encode());
        CollectionAssert.AreEqual(new[] { 10, 2000 }, EmojiSheet.Decode("160\t2\t2\t1,99999")!.Durations.ToList(), "夹到 10–2000");
        foreach (var bad in new[]
                 {
                     "160\t5\t17\t84", "160\t5\t1\t84", "160\t0\t2\t84,84", "160\t17\t2\t84,84", "0\t1\t2\t84,84", "160\t1\t20\t" + string.Join(',', Enumerable.Repeat(84, 20)),
                     "160\t2\t2\t84,x", "160\t2\t2\t-5,84", "160\t2\t2", "160\t2\t2\t84,84\textra", "+160\t2\t2\t84,84",
                 })
        {
            Assert.IsNull(EmojiSheet.Decode(bad), bad);
        }
    }

    [TestMethod]
    public void PackFilesAreChecked()
    {
        var walking = Walking();
        var sheet = EmojiPackFile.Read(walking);
        Assert.IsNotNull(sheet, "tools/status-emoji.swift --pack 写的文件认得");
        Assert.AreEqual(5, sheet.Columns);
        Assert.AreEqual(17, sheet.Count);
        Assert.AreEqual(160, sheet.Cell);

        // 拿掉 tEXt 块就不认（包里自带的图集是这个样子，帧信息在 manifest.txt）；再按同一行插回去又认
        var plain = WithoutText(walking);
        Assert.IsNull(EmojiPackFile.Read(plain));
        var embedded = EmojiPackFile.Embed(plain, sheet);
        Assert.AreEqual(sheet.Encode(), EmojiPackFile.Read(embedded)?.Encode());

        // 改了 tEXt 里一个字：校验对不上
        var tampered = (byte[])walking.Clone();
        var at = IndexOf(tampered, Encoding.ASCII.GetBytes("kitty-emoji\0160"));
        tampered[at + 14] = (byte)'5';
        Assert.IsNull(EmojiPackFile.Read(tampered));

        // 说的格子数和图的大小对不上（5 列说成 6 列）
        Assert.IsNull(EmojiPackFile.Read(EmojiPackFile.Embed(plain, sheet with { Columns = 6 })));
        // 截短、后面多东西、不是 PNG、太大
        Assert.IsNull(EmojiPackFile.Read(walking.AsSpan(0, walking.Length - 1)));
        Assert.IsNull(EmojiPackFile.Read(walking.Concat(new byte[] { 0 }).ToArray()));
        Assert.IsNull(EmojiPackFile.Read(Encoding.ASCII.GetBytes("GIF89a not a png at all, definitely not")));
        Assert.IsNull(EmojiPackFile.Read(new byte[EmojiPackFile.MaxBytes + 1]));
        Assert.AreEqual(0xCBF43926u, EmojiPackFile.Crc32("123456789"u8), "CRC-32 的标准校验值");
    }

    [TestMethod]
    public void CacheKeepsTheRecentlyUsed()
    {
        var day = new DateTime(2026, 11, 17, 0, 0, 0, DateTimeKind.Utc);
        var files = new[]
        {
            new EmojiPackCache.CachedFile("old.png", 30, day),
            new EmojiPackCache.CachedFile("new.png", 30, day.AddDays(2)),
            new EmojiPackCache.CachedFile("mid.png", 30, day.AddDays(1)),
        };
        Assert.AreEqual(0, EmojiPackCache.Overflow(files, 90).Count);
        CollectionAssert.AreEqual(new[] { "old.png" }, EmojiPackCache.Overflow(files, 89).ToList());
        CollectionAssert.AreEqual(new[] { "old.png", "mid.png" }, EmojiPackCache.Overflow(files, 30).ToList());
        CollectionAssert.AreEqual(new[] { "old.png", "mid.png", "new.png" }, EmojiPackCache.Overflow(files, 0).ToList());
        // MaxBytes 是常量，分析器认为恒真（MSTEST0032）；留着是为了有人改缓存上限时这里先红。
#pragma warning disable MSTEST0032
        Assert.AreEqual(50L * 1024 * 1024, EmojiPackCache.MaxBytes);
#pragma warning restore MSTEST0032

        Assert.IsTrue(EmojiPackCache.MayRetry(null, day));
        Assert.IsFalse(EmojiPackCache.MayRetry(day, day.AddMinutes(9)));
        Assert.IsTrue(EmojiPackCache.MayRetry(day, day.AddMinutes(10)));
    }

    [TestMethod]
    public void DownloadAddresses()
    {
        Assert.AreEqual("https://github.com/YyAdnBug/kitty-tools/releases/download/emoji-pack-1-win/dog-face.png",
            EmojiPackRemote.Url("dog-face", EmojiPackRemote.Tag, null));
        Assert.IsNull(EmojiPackRemote.Url("../x", EmojiPackRemote.Tag, null));
        Assert.IsNull(EmojiPackRemote.Url("dog", "../../x", null));
        Assert.AreEqual("http://127.0.0.1:8123/dog-face.png", EmojiPackRemote.Url("dog-face", EmojiPackRemote.Tag, "http://127.0.0.1:8123"));
        Assert.AreEqual("http://localhost:8123/out/dog-face.png", EmojiPackRemote.Url("dog-face", EmojiPackRemote.Tag, "http://localhost:8123/out/"));
        // 只认 http 的本机：别的地址照旧走 release
        foreach (var server in new[] { "http://example.com:8123", "https://127.0.0.1:8123", "http://user:pw@127.0.0.1:1", "file:///C:/x", "garbage" })
        {
            Assert.IsTrue(EmojiPackRemote.Url("dog", EmojiPackRemote.Tag, server)?.StartsWith("https://github.com/", StringComparison.Ordinal) == true, server);
        }

        Assert.IsTrue(EmojiPackRemote.IsAllowed("https://github.com/YyAdnBug/kitty-tools/releases/download/emoji-pack-1-win/dog.png", null));
        Assert.IsTrue(EmojiPackRemote.IsAllowed("https://release-assets.githubusercontent.com/github-production-release-asset/1/2?x=1", null));
        Assert.IsFalse(EmojiPackRemote.IsAllowed("https://github.com/someone-else/repo/releases/download/x/dog.png", null));
        Assert.IsFalse(EmojiPackRemote.IsAllowed("https://evil.example/dog.png", null));
        Assert.IsFalse(EmojiPackRemote.IsAllowed("http://127.0.0.1:8123/dog.png", null), "没设测试服务器时不认本机");
        Assert.IsTrue(EmojiPackRemote.IsAllowed("http://127.0.0.1:8123/dog.png", "http://127.0.0.1:8123"));
        Assert.IsFalse(EmojiPackRemote.IsAllowed("http://127.0.0.1:9999/dog.png", "http://127.0.0.1:8123"), "端口要对上");
    }

    [TestMethod]
    public async Task DownloadsFromALocalServer()
    {
        var walking = Walking();
        var tampered = (byte[])walking.Clone();
        tampered[IndexOf(tampered, Encoding.ASCII.GetBytes("kitty-emoji\0160")) + 14] = (byte)'5';
        var routes = new Dictionary<string, Func<string>>
        {
            ["/out/person-walking.png"] = () => Reply(200, walking),
            ["/out/moved.png"] = () => Header(302, "Location: /out/person-walking.png"),
            ["/out/away.png"] = () => Header(302, "Location: https://evil.example/person-walking.png"),
            ["/out/plain.png"] = () => Reply(200, WithoutText(walking)),
            ["/out/tampered.png"] = () => Reply(200, tampered),
            ["/out/huge.png"] = () => Header(200, $"Content-Length: {EmojiPackFile.MaxBytes + 1}"),
        };
        // 只发响应头和一点正文、然后不动（Serve 里认这个路径，挂到测试收尾）
        const string stall = "/out/stall.png";
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var stop = new CancellationTokenSource();
        var serving = Serve(listener, routes, stall, stop.Token);
        var server = $"http://127.0.0.1:{port}/out";
        using var client = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false, UseProxy = false })
        {
            Timeout = TimeSpan.FromSeconds(10),
        };
        try
        {
            async Task<byte[]?> Fetch(string id)
                => await EmojiPackRemote.FetchAsync(client, EmojiPackRemote.Url(id, EmojiPackRemote.Tag, server)!, server, CancellationToken.None);

            CollectionAssert.AreEqual(walking, await Fetch("person-walking"), "下得下来、原样");
            CollectionAssert.AreEqual(walking, await Fetch("moved"), "跟着本机里的跳转");
            Assert.IsNull(await Fetch("away"), "跳去别的主机不跟");
            Assert.IsNull(await Fetch("missing"), "404");
            Assert.IsNull(await Fetch("plain"), "没有帧信息");
            Assert.IsNull(await Fetch("tampered"), "校验不对");
            Assert.IsNull(await Fetch("huge"), "声明的长度超了");
            // 没设测试服务器时本机地址一跳都不去
            Assert.IsNull(await EmojiPackRemote.FetchAsync(client, $"{server}/person-walking.png", null, CancellationToken.None));

            // 正文传到一半卡住：HttpClient.Timeout（10 秒）只管到响应头，停得下来靠调用方的取消（App 给 60 秒），到点给 null、不抛
            using var quick = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            var clock = System.Diagnostics.Stopwatch.StartNew();
            Assert.IsNull(await EmojiPackRemote.FetchAsync(client, $"http://127.0.0.1:{port}{stall}", server, quick.Token));
            Assert.IsTrue(clock.Elapsed < TimeSpan.FromSeconds(5), $"卡住的正文要按取消停下，用了 {clock.Elapsed}");
        }
        finally
        {
            stop.Cancel();
            listener.Stop();
            await serving;
        }
    }

    /// <summary>最小的 HTTP/1.1：一个连接一个请求，回完就关；每个连接各自处理（卡住的那个不挡后面的）。stall 那个路径只回响应头和 10 个字节就不动了。</summary>
    private static async Task Serve(TcpListener listener, Dictionary<string, Func<string>> routes, string stall, CancellationToken token)
    {
        var handlers = new List<Task>();
        while (!token.IsCancellationRequested)
        {
            TcpClient connection;
            try
            {
                connection = await listener.AcceptTcpClientAsync(token);
            }
            catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException)
            {
                break;
            }

            handlers.Add(Handle(connection, routes, stall, token));
        }

        await Task.WhenAll(handlers);
    }

    private static async Task Handle(TcpClient connection, Dictionary<string, Func<string>> routes, string stall, CancellationToken token)
    {
        try
        {
            using var owned = connection;
            var stream = connection.GetStream();
            var request = new StringBuilder();
            var buffer = new byte[4096];
            while (!request.ToString().Contains("\r\n\r\n", StringComparison.Ordinal))
            {
                var read = await stream.ReadAsync(buffer, token);
                if (read == 0)
                {
                    break;
                }

                request.Append(Encoding.Latin1.GetString(buffer, 0, read));
            }

            var path = request.ToString().Split(' ').ElementAtOrDefault(1) ?? "/";
            if (path == stall)
            {
                await stream.WriteAsync(Encoding.Latin1.GetBytes(Header(200, "Content-Length: 100000") + "0123456789"), token);
                await Task.Delay(Timeout.Infinite, token);
                return;
            }

            var reply = routes.TryGetValue(path, out var route) ? route() : Header(404, "Content-Length: 0");
            await stream.WriteAsync(Encoding.Latin1.GetBytes(reply), token);
        }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
        {
            // 客户端先断了（声明太大的那个不读正文）、测试收尾取消了卡住的那个
        }
    }

    private static string Header(int status, string extra)
        => $"HTTP/1.1 {status} X\r\n{extra}\r\nConnection: close\r\n\r\n";

    private static string Reply(int status, byte[] body)
        => $"HTTP/1.1 {status} X\r\nContent-Type: image/png\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n" +
           Encoding.Latin1.GetString(body);

    /// <summary>拿掉 tEXt 块（剩下的块原样）。</summary>
    private static byte[] WithoutText(byte[] png)
    {
        var output = new List<byte>(png.Take(8));
        var pos = 8;
        while (pos < png.Length)
        {
            var length = (png[pos] << 24) | (png[pos + 1] << 16) | (png[pos + 2] << 8) | png[pos + 3];
            var type = Encoding.ASCII.GetString(png, pos + 4, 4);
            if (type != "tEXt")
            {
                output.AddRange(png.Skip(pos).Take(12 + length));
            }

            pos += 12 + length;
        }

        return output.ToArray();
    }

    private static int IndexOf(byte[] haystack, byte[] needle)
    {
        var at = haystack.AsSpan().IndexOf(needle);
        Assert.IsTrue(at >= 0);
        return at;
    }
}
