// PLAN-v19 V1：WebDAV 客户端（Core/Sync/WebDav.cs）的纯函数和出错分类，照 mac WebDAVTests：地址拼法、文件夹里一项的网址、
// multistatus 的几种写法（Apache、反向代理后面的整个网址、乱码、带 DTD 的）、HTTP 日期、状态码 → 出错、Retry-After 两种写法、
// 401 带 Digest 挑战时换 Digest 的 client、断网、跳转。
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class WebDavTests
{
    /// <summary>每个请求都回同一个样子的假 handler（Digest 那条用）。</summary>
    private sealed class Canned(Func<HttpRequestMessage, HttpResponseMessage> reply) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Seen { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Seen.Add(request);
            return Task.FromResult(reply(request));
        }
    }

    private static string Temp()
    {
        var folder = Path.Combine(Path.GetTempPath(), "kitty-webdav-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    [TestMethod]
    public void FolderUrl()
    {
        Assert.AreEqual(
            "https://dav.example.com/dav/Kitty%20Tools%20%E5%90%8C%E6%AD%A5/",
            WebDav.Folder("https://dav.example.com/dav", "Kitty Tools 同步")?.AbsoluteUri);
        Assert.AreEqual(
            "https://dav.example.com/dav/a/b/",
            WebDav.Folder("  https://user:pw@dav.example.com/dav/?x=1#y  ", "/a//b/")?.AbsoluteUri,
            "地址里的用户名密码、查询串扔掉，文件夹的空段跳过");
        Assert.AreEqual("http://192.168.1.2:5005/", WebDav.Folder("http://192.168.1.2:5005", string.Empty)?.AbsoluteUri);
        Assert.IsNull(WebDav.Folder("dav.example.com", "x"), "没写 http(s)://");
        Assert.IsNull(WebDav.Folder("ftp://dav.example.com/", "x"));
        Assert.IsNull(WebDav.Folder("https://dav.example.com/", "../别处"), "文件夹里不许有 . / ..");
    }

    [TestMethod]
    public void ItemUrl()
    {
        var dav = new WebDav(FakeDav.Account(), new WebDavTransport(new HttpClient()));
        Assert.AreEqual("https://dav.test/dav/devices/ABC/notes/X.md", dav.Url(new[] { "devices", "ABC", "notes", "X.md" }).AbsoluteUri);
        Assert.AreEqual("https://dav.test/dav/devices/", dav.Url(new[] { "devices" }, folder: true).AbsoluteUri);
        Assert.AreEqual("https://dav.test/dav/", dav.Url(Array.Empty<string>(), folder: true).AbsoluteUri);
        Assert.AreEqual("https://dav.test/dav/a%20b%23c%3F.md", dav.Url(new[] { "a b#c?.md" }).AbsoluteUri);
    }

    [TestMethod]
    public void ParsesApacheStyle()
    {
        const string xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
            <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
            <D:href>/dav/sync/</D:href>
            <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype>
            <lp1:getlastmodified>Fri, 13 Nov 2026 03:30:46 GMT</lp1:getlastmodified><D:getetag>"1000-5d1"</D:getetag></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            </D:response>
            <D:response xmlns:lp1="DAV:">
            <D:href>/dav/sync/kitty-notes-sync.json</D:href>
            <D:propstat><D:prop><lp1:resourcetype/><lp1:getcontentlength>87</lp1:getcontentlength>
            <lp1:getetag>"57-5d2"</lp1:getetag><lp1:getlastmodified>Fri, 13 Nov 2026 03:30:46 GMT</lp1:getlastmodified></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            <D:propstat><D:prop><D:getcontentlength>999</D:getcontentlength><D:quota/></D:prop>
            <D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
            </D:response>
            <D:response><D:href>/dav/sync/devices/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            </D:response>
            <D:response><D:href>/dav/sync/%E5%90%8C%E6%AD%A5%20x.md</D:href>
            <D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            </D:response>
            </D:multistatus>
            """;
        var items = WebDav.ParseListing(Encoding.UTF8.GetBytes(xml), new Uri("https://dav.example.com/dav/sync/"));
        Assert.IsNotNull(items);
        CollectionAssert.AreEqual(
            new[] { "kitty-notes-sync.json", "devices", "同步 x.md" }, items.Select(item => item.Name).ToArray());
        var marker = items[0];
        Assert.IsFalse(marker.IsFolder);
        Assert.AreEqual("\"57-5d2\"", marker.ETag);
        Assert.AreEqual(87L, marker.Size, "404 那组 propstat 里的不算");
        Assert.AreEqual(new DateTimeOffset(2026, 11, 13, 3, 30, 46, TimeSpan.Zero), marker.Modified);
        Assert.IsTrue(items[1].IsFolder);
    }

    [TestMethod]
    public void ParsesAbsoluteHrefsBehindProxy()
    {
        // 前面隔着改路径的反向代理：href 是整个网址、路径和请求的对不上——第一项是同名文件夹就当自己
        const string xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
            <d:response><d:href>https://cloud.example.com/remote.php/dav/files/kitty/sync/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>https://cloud.example.com/remote.php/dav/files/kitty/sync/a.md</d:href>
            <d:propstat><d:prop><d:getetag>W/"x"</d:getetag><d:getcontentlength>5</d:getcontentlength></d:prop></d:propstat></d:response>
            </d:multistatus>
            """;
        var items = WebDav.ParseListing(Encoding.UTF8.GetBytes(xml), new Uri("https://dav.example.com/dav/sync/"));
        Assert.IsNotNull(items);
        Assert.AreEqual(1, items.Count);
        Assert.AreEqual("a.md", items[0].Name);
        Assert.AreEqual("W/\"x\"", items[0].ETag, "没写状态的 propstat 当成 200");
        Assert.AreEqual(5L, items[0].Size);
    }

    [TestMethod]
    public void RejectsGarbage()
    {
        var folder = new Uri("https://dav.example.com/dav/");
        Assert.IsNull(WebDav.ParseListing(Encoding.UTF8.GetBytes("这不是 XML"), folder));
        Assert.IsNull(WebDav.ParseListing(Encoding.UTF8.GetBytes("<html><body>登录</body></html>"), folder), "根不是 multistatus");
        const string entity = """
            <?xml version="1.0"?>
            <!DOCTYPE d:multistatus [<!ENTITY x SYSTEM "file:///etc/passwd">]>
            <d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>
            """;
        Assert.IsNull(WebDav.ParseListing(Encoding.UTF8.GetBytes(entity), folder), "带 DTD 的一律不认");
    }

    [TestMethod]
    public void HttpDate()
    {
        Assert.AreEqual(new DateTimeOffset(2026, 11, 13, 3, 30, 46, TimeSpan.Zero), WebDav.HttpDate("Fri, 13 Nov 2026 03:30:46 GMT"));
        Assert.IsNull(WebDav.HttpDate("2026-11-13T03:30:46Z"));
        Assert.IsNull(WebDav.HttpDate(string.Empty));
    }

    [TestMethod]
    public void Failures()
    {
        Assert.AreEqual(WebDavError.Unauthorized, WebDavFailure.FromStatus(401).Error);
        Assert.AreEqual(WebDavError.Forbidden, WebDavFailure.FromStatus(403).Error);
        Assert.AreEqual(WebDavError.NotFound, WebDavFailure.FromStatus(404).Error);
        Assert.AreEqual(WebDavError.Exists, WebDavFailure.FromStatus(412).Error);
        Assert.AreEqual(WebDavError.Busy, WebDavFailure.FromStatus(429).Error);
        Assert.AreEqual(TimeSpan.FromSeconds(60), WebDavFailure.FromStatus(503, TimeSpan.FromSeconds(60)).RetryAfter);
        Assert.AreEqual(WebDavError.Full, WebDavFailure.FromStatus(507).Error);
        Assert.AreEqual(WebDavError.Moved, WebDavFailure.FromStatus(301).Error);
        Assert.AreEqual("服务器出错（HTTP 500）", WebDavFailure.FromStatus(500).Message);
        Assert.AreEqual("连不上服务器：找不到这个服务器", new WebDavFailure(WebDavError.Offline, "找不到这个服务器").Message);
        Assert.AreEqual(nameof(WebDavAccount), FakeDav.Account().ToString(), "账号的 ToString 不带密码");
    }

    [TestMethod]
    public void RetryAfterBothForms()
    {
        var root = Temp();
        try
        {
            var server = new FakeDav(root);
            var reply = new RetryConditionHeaderValue(TimeSpan.FromSeconds(120));
            server.Intercept = (_, _) =>
            {
                var busy = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
                busy.Headers.RetryAfter = reply;
                return busy;
            };
            var seconds = Assert.ThrowsExactly<WebDavException>(() => server.Dav().ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
            Assert.AreEqual(WebDavError.Busy, seconds.Failure.Error);
            Assert.AreEqual(TimeSpan.FromSeconds(120), seconds.Failure.RetryAfter);

            reply = new RetryConditionHeaderValue(DateTimeOffset.UtcNow.AddMinutes(10));
            var date = Assert.ThrowsExactly<WebDavException>(() => server.Dav().ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
            Assert.IsTrue(date.Failure.RetryAfter > TimeSpan.FromMinutes(9) && date.Failure.RetryAfter <= TimeSpan.FromMinutes(10));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void SwitchesToDigestWhenAsked()
    {
        var basic = new Canned(_ =>
        {
            var refused = new HttpResponseMessage(HttpStatusCode.Unauthorized);
            refused.Headers.WwwAuthenticate.Add(new AuthenticationHeaderValue("Digest", "realm=\"dav\", nonce=\"1\""));
            return refused;
        });
        var digest = new Canned(_ => new HttpResponseMessage((HttpStatusCode)207)
        {
            Content = new StringContent("<d:multistatus xmlns:d=\"DAV:\"/>", Encoding.UTF8, "application/xml"),
        });
        var made = 0;
        var transport = new WebDavTransport(new HttpClient(basic), _ =>
        {
            made++;
            return new HttpClient(digest, disposeHandler: false);
        });
        var dav = new WebDav(FakeDav.Account(), transport);
        Assert.IsNotNull(dav.ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
        Assert.IsNotNull(dav.ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
        Assert.AreEqual(1, basic.Seen.Count, "换成 Digest 之后这个账号都走它");
        Assert.AreEqual(2, digest.Seen.Count);
        Assert.AreEqual(1, made);
        Assert.IsNull(digest.Seen[0].Headers.Authorization, "Digest 的 client 自己答挑战，不先带 Basic");

        // 换了密码：重建
        var other = new WebDav(FakeDav.Account(password: "another"), transport);
        Assert.IsNotNull(other.ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
        Assert.AreEqual(2, made);
    }

    [TestMethod]
    public void WrongPasswordOfflineAndMoved()
    {
        var root = Temp();
        try
        {
            var server = new FakeDav(root);
            var wrong = Assert.ThrowsExactly<WebDavException>(
                () => server.Dav(password: "nope").ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
            Assert.AreEqual(WebDavError.Unauthorized, wrong.Failure.Error);

            server.Offline = true;
            var offline = Assert.ThrowsExactly<WebDavException>(
                () => server.Dav().ListAsync(Array.Empty<string>()).GetAwaiter().GetResult());
            Assert.AreEqual(WebDavError.Offline, offline.Failure.Error);
            Assert.IsFalse(offline.Failure.Message.Contains("dav.test", StringComparison.Ordinal), "出错的话里不带主机名");

            server.Offline = false;
            server.Intercept = (_, _) =>
            {
                var moved = new HttpResponseMessage(HttpStatusCode.MovedPermanently);
                moved.Headers.Location = new Uri("https://elsewhere.test/dav/");
                return moved;
            };
            var redirected = Assert.ThrowsExactly<WebDavException>(
                () => server.Dav().GetAsync(new[] { "a.md" }).GetAwaiter().GetResult());
            Assert.AreEqual(WebDavError.Moved, redirected.Failure.Error);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
