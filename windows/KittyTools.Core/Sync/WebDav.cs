// WebDAV 客户端（PLAN-v19 V1，issue #18；照 mac Storage/WebDAV.swift）：同步要的几样请求、multistatus 解析、出错分类。
// - 请求：PROPFIND 只列一层（Depth 1：有的服务只认 1）、GET、PUT（可选「已经有了就不写」）、DELETE、MKCOL、MOVE（不覆盖）。
//   怎么用在 SyncServer。一次一个请求（调用方串着发）。
// - 认证（PLAN-v19 D2）：每个请求自己先带 Basic（等 401 再补的话，按次数限流的服务器上请求数翻一倍）；回 401 而且服务器要的是
//   Digest，就换成这个账号专门的那个 client（handler 的 Credentials 只登记这个网址的 Digest）重发，之后这个账号都走它。
//   密码只在内存里（存在凭据管理器，App 的 Syncer 取），不进日志、不进出错的话。
// - 共用的 HttpClient（WebDavTransport.CreateDefault）：不跟 Cookie、不自动跳转（3xx 当错：自动跳转会把 PUT 的内容带到别的主机，
//   WebDAV 的跳转多半是地址少写了 /）、每台服务器最多 2 条连接、单个请求 30 秒。代理、证书照系统的（不支持自签证书，同 mac）。
// - 出错分几种（WebDavFailure），界面上的话在 Message、照 mac 原文；里面不带网址、主机名（系统给的异常文字可能带，不用它）。
// - multistatus 用 XmlReader 解（不认 DTD；命名空间按 DAV: 认、不按前缀；根不是 multistatus 的不认），只认状态 200 那组 propstat
//   里的属性；href 有的是整个网址、有的是绝对路径，解码后按路径认出「自己」那一项，名字取最后一段。
// 全是 async，不碰 UI 线程。
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Text;
using System.Xml;

namespace KittyTools.Core.Sync;

/// <summary>服务器上用来同步的那个文件夹（网址以 / 结尾）和登录的账号。</summary>
public sealed record WebDavAccount(Uri Folder, string User, string Password)
{
    /// <summary>不让密码跟着 ToString 进日志。</summary>
    public override string ToString() => nameof(WebDavAccount);
}

/// <summary>列出来的一项。</summary>
public sealed record WebDavItem(string Name, bool IsFolder, string? ETag, DateTimeOffset? Modified, long Size);

public enum WebDavError
{
    /// <summary>连不上（没联网、找不到服务器、超时、证书不受信任）：Reason 是原因。</summary>
    Offline,
    Unauthorized,
    Forbidden,
    NotFound,

    /// <summary>412：要写的地方已经有了。</summary>
    Exists,

    /// <summary>429 / 503：请求太多，过一会儿再来；服务器说了等多久就是 RetryAfter。</summary>
    Busy,
    Full,

    /// <summary>3xx：服务器让改用别的地址（不自动跳）。</summary>
    Moved,
    Status,
    Invalid,

    /// <summary>本机的镜像写不进去（磁盘满了、被占着）。</summary>
    Disk,
}

public sealed record WebDavFailure(WebDavError Error, string? Reason = null, int Status = 0, TimeSpan? RetryAfter = null)
{
    /// <summary>设置页、状态行上的一句话（照 mac WebDAV.Failure.message）。</summary>
    public string Message => Error switch
    {
        WebDavError.Offline => "连不上服务器：" + (Reason ?? "网络出错"),
        WebDavError.Unauthorized => "用户名或密码不对（有的服务要在网页上另外生成给第三方应用用的密码）",
        WebDavError.Forbidden => "服务器不让读写这个文件夹",
        WebDavError.NotFound => "服务器上没有这个文件夹",
        WebDavError.Exists => "服务器上已经有同名的了",
        WebDavError.Busy => "服务器说请求太多，过一会儿再试",
        WebDavError.Full => "服务器上的空间满了",
        WebDavError.Moved => "服务器让改用别的地址，检查地址是不是写全了",
        WebDavError.Status => $"服务器出错（HTTP {Status}）",
        WebDavError.Disk => "这台电脑上的同步副本写不进去（磁盘满了，或者被别的程序占着）",
        _ => "服务器回的东西看不懂，可能不是 WebDAV 地址",
    };

    /// <summary>HTTP 状态码 → 出错（2xx 不该走到这里）。</summary>
    public static WebDavFailure FromStatus(int status, TimeSpan? retryAfter = null) => status switch
    {
        401 => new(WebDavError.Unauthorized),
        403 => new(WebDavError.Forbidden),
        404 or 410 => new(WebDavError.NotFound),
        412 => new(WebDavError.Exists),
        429 or 503 => new(WebDavError.Busy, RetryAfter: retryAfter),
        507 => new(WebDavError.Full),
        >= 300 and < 400 => new(WebDavError.Moved, Status: status),
        _ => new(WebDavError.Status, Status: status),
    };
}

public sealed class WebDavException(WebDavFailure failure) : Exception(failure.Message)
{
    public WebDavFailure Failure { get; } = failure;
}

/// <summary>
/// 发请求的那一层（PLAN-v19 D2）：一个共用的 client（每个请求自己带 Basic）；服务器要 Digest 时换成这个账号专门的那个，
/// 账号（地址、用户名、密码任何一样）一换就扔掉重建。单测传一个包着假服务器的 client。
/// </summary>
public sealed class WebDavTransport(HttpMessageInvoker basic, Func<WebDavAccount, HttpMessageInvoker>? digest = null)
{
    /// <summary>一个回应最大多少：认得的文件里最大的是 32 MB（SyncFile.MaxBytes），多留一点给 multistatus。</summary>
    public const int MaxResponseBytes = 48 << 20;

    private static readonly Lazy<HttpClient> Shared = new(() => Client(null));

    private readonly object _gate = new();
    private WebDavAccount? _digestAccount;
    private HttpMessageInvoker? _digestClient;

    /// <summary>App 用的那个：共用的 client + Digest 的退路。</summary>
    public static WebDavTransport CreateDefault() => new(Shared.Value, account => Client(account));

    public HttpMessageInvoker Basic => basic;

    /// <summary>这个账号已经换成 Digest 了：那个 client；没有是 null。</summary>
    public HttpMessageInvoker? DigestFor(WebDavAccount account)
    {
        lock (_gate)
        {
            return _digestAccount == account ? _digestClient : null;
        }
    }

    /// <summary>这个账号从现在起走 Digest：建它专门的 client（没有退路时是 null）。</summary>
    public HttpMessageInvoker? UseDigest(WebDavAccount account)
    {
        if (digest is null)
        {
            return null;
        }

        lock (_gate)
        {
            if (_digestAccount != account || _digestClient is null)
            {
                // ponytail: 换账号时直接扔掉旧的；正好有一个请求在用它的话那个请求会失败，下一轮再来
                _digestClient?.Dispose();
                _digestClient = digest(account);
                _digestAccount = account;
            }

            return _digestClient;
        }
    }

    private static HttpClient Client(WebDavAccount? digestFor)
    {
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            AllowAutoRedirect = false,
            MaxConnectionsPerServer = 2,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
        if (digestFor is not null)
        {
            var origin = new Uri(digestFor.Folder.GetLeftPart(UriPartial.Authority));
            handler.Credentials = new CredentialCache
            {
                { origin, "Digest", new NetworkCredential(digestFor.User, digestFor.Password) },
            };
        }

        return new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(30),
            MaxResponseContentBufferSize = MaxResponseBytes,
        };
    }
}

public sealed class WebDav(WebDavAccount account, WebDavTransport transport)
{
    private const string Dav = "DAV:";

    private static readonly HttpMethod Propfind = new("PROPFIND");
    private static readonly HttpMethod Mkcol = new("MKCOL");
    private static readonly HttpMethod MoveMethod = new("MOVE");

    private static readonly byte[] PropfindBody = Encoding.UTF8.GetBytes(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
        "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/>" +
        "<d:getcontentlength/></d:prop></d:propfind>");

    public WebDavAccount Account => account;

    /// <summary>服务器上的文件夹 + 用户名：镜像的账上记着它，换了就从头记。</summary>
    public string Identity => account.Folder.AbsoluteUri + " " + account.User;

    /// <summary>
    /// 设置里填的地址 + 文件夹 → 同步用的那个文件夹的网址（以 / 结尾）。地址不是 http(s)、没有主机、文件夹里有 . / .. 这一段时是 null；
    /// 地址里带的用户名密码、查询串扔掉（密码另填、存凭据管理器）。
    /// </summary>
    public static Uri? Folder(string address, string path)
    {
        if (!Uri.TryCreate(address.Trim(), UriKind.Absolute, out var typed) ||
            (typed.Scheme != Uri.UriSchemeHttp && typed.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrEmpty(typed.Host))
        {
            return null;
        }

        var builder = new UriBuilder(typed)
        {
            UserName = string.Empty,
            Password = string.Empty,
            Query = string.Empty,
            Fragment = string.Empty,
        };
        var text = builder.Uri.AbsoluteUri;
        if (!text.EndsWith('/'))
        {
            text += "/";
        }

        foreach (var part in path.Split('/'))
        {
            var name = part.Trim();
            if (name.Length == 0)
            {
                continue;
            }

            if (name is "." or "..")
            {
                return null;
            }

            text += Uri.EscapeDataString(name) + "/";
        }

        return Uri.TryCreate(text, UriKind.Absolute, out var folder) ? folder : null;
    }

    /// <summary>文件夹里一个东西的网址：path 是一段一段的名字（文件夹最后带 /）。</summary>
    public Uri Url(IReadOnlyList<string> path, bool folder = false)
    {
        var builder = new StringBuilder(account.Folder.AbsoluteUri);
        for (var index = 0; index < path.Count; index++)
        {
            builder.Append(Uri.EscapeDataString(path[index]));
            if (index < path.Count - 1 || folder)
            {
                builder.Append('/');
            }
        }

        return new Uri(builder.ToString());
    }

    // ---- 请求 ----

    /// <summary>列一层：不在是 null（文件夹本身不算在里面）。</summary>
    public async Task<List<WebDavItem>?> ListAsync(IReadOnlyList<string> path)
    {
        var target = Url(path, folder: true);
        var reply = await SendAsync(
            Propfind, target,
            () => new ByteArrayContent(PropfindBody)
            {
                Headers = { ContentType = new MediaTypeHeaderValue("application/xml") { CharSet = "utf-8" } },
            },
            ("Depth", "1"));
        if (reply.Status is 404 or 410)
        {
            return null;
        }

        if (reply.Status != 207)
        {
            throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
        }

        return ParseListing(reply.Body, target) ?? throw new WebDavException(new WebDavFailure(WebDavError.Invalid));
    }

    /// <summary>读一个文件：不在是 null。</summary>
    public async Task<byte[]?> GetAsync(IReadOnlyList<string> path)
    {
        var reply = await SendAsync(HttpMethod.Get, Url(path));
        if (reply.Status is 404 or 410)
        {
            return null;
        }

        return reply.Status is >= 200 and < 300
            ? reply.Body
            : throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
    }

    /// <summary>写一个文件；ifAbsent：已经有了就不写（抛 Exists）。</summary>
    public async Task PutAsync(IReadOnlyList<string> path, byte[] data, bool ifAbsent = false)
    {
        var headers = ifAbsent ? new[] { ("If-None-Match", "*") } : Array.Empty<(string, string)>();
        var reply = await SendAsync(
            HttpMethod.Put, Url(path),
            () => new ByteArrayContent(data)
            {
                Headers = { ContentType = new MediaTypeHeaderValue("application/octet-stream") },
            },
            headers);
        if (reply.Status is < 200 or >= 300)
        {
            throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
        }
    }

    /// <summary>删一个文件（本来就不在也算删了）。</summary>
    public async Task DeleteAsync(IReadOnlyList<string> path)
    {
        var reply = await SendAsync(HttpMethod.Delete, Url(path));
        if (reply.Status is not (>= 200 and < 300 or 404))
        {
            throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
        }
    }

    /// <summary>建一个文件夹（已经有了也算建好：405）。</summary>
    public async Task MakeFolderAsync(IReadOnlyList<string> path)
    {
        var reply = await SendAsync(Mkcol, Url(path, folder: true));
        if (reply.Status is not (>= 200 and < 300 or 405))
        {
            throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
        }
    }

    /// <summary>建好同步的那个文件夹，连同没有的上级（409 = 上级没有：往上找到有的那一级，再一级一级往下建）。</summary>
    public async Task MakeFoldersAsync()
    {
        var missing = new List<Uri>();
        var target = account.Folder;
        while (true)
        {
            var reply = await SendAsync(Mkcol, target);
            if (reply.Status is >= 200 and < 300 or 405)
            {
                break;
            }

            if (reply.Status != 409 || target.Segments.Length <= 2)
            {
                throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
            }

            missing.Add(target);
            target = new Uri(target, "..");
        }

        for (var index = missing.Count - 1; index >= 0; index--)
        {
            var reply = await SendAsync(Mkcol, missing[index]);
            if (reply.Status is not (>= 200 and < 300 or 405))
            {
                throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
            }
        }
    }

    /// <summary>改名 / 挪到别处，不覆盖（目标已经有了：抛 Exists）。</summary>
    public async Task MoveAsync(IReadOnlyList<string> from, IReadOnlyList<string> to)
    {
        var reply = await SendAsync(
            MoveMethod, Url(from), null, ("Destination", Url(to).AbsoluteUri), ("Overwrite", "F"));
        if (reply.Status is < 200 or >= 300)
        {
            throw new WebDavException(WebDavFailure.FromStatus(reply.Status, reply.RetryAfter));
        }
    }

    private readonly record struct Reply(int Status, byte[] Body, TimeSpan? RetryAfter, bool WantsDigest);

    /// <summary>发一个请求：401 而且服务器要 Digest 时换 Digest 的 client 重发一次；还是 401 就是用户名密码不对；3xx 当错。</summary>
    private async Task<Reply> SendAsync(
        HttpMethod method, Uri url, Func<HttpContent>? content = null, params (string Name, string Value)[] headers)
    {
        try
        {
            var digest = transport.DigestFor(account);
            var reply = await SendOnceAsync(digest ?? transport.Basic, digest is null, method, url, content, headers);
            if (reply.Status == 401 && digest is null && reply.WantsDigest && transport.UseDigest(account) is { } switched)
            {
                reply = await SendOnceAsync(switched, false, method, url, content, headers);
            }

            if (reply.Status == 401)
            {
                throw new WebDavException(new WebDavFailure(WebDavError.Unauthorized));
            }

            if (reply.Status is >= 300 and < 400)
            {
                throw new WebDavException(WebDavFailure.FromStatus(reply.Status));
            }

            return reply;
        }
        catch (HttpRequestException ex)
        {
            throw new WebDavException(Offline(ex));
        }
        catch (OperationCanceledException)
        {
            // HttpClient 的超时是 TaskCanceledException
            throw new WebDavException(new WebDavFailure(WebDavError.Offline, "服务器很久没回应"));
        }
    }

    private async Task<Reply> SendOnceAsync(
        HttpMessageInvoker invoker, bool basic, HttpMethod method, Uri url, Func<HttpContent>? content,
        (string Name, string Value)[] headers)
    {
        using var request = new HttpRequestMessage(method, url);
        if (content is not null)
        {
            request.Content = content();
        }

        if (basic)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue(
                "Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes(account.User + ":" + account.Password)));
        }

        foreach (var (name, value) in headers)
        {
            request.Headers.TryAddWithoutValidation(name, value);
        }

        using var response = await invoker.SendAsync(request, CancellationToken.None);
        var body = await response.Content.ReadAsByteArrayAsync();
        TimeSpan? retryAfter = null;
        if (response.Headers.RetryAfter is { } retry)
        {
            retryAfter = retry.Delta ?? (retry.Date is { } date ? (TimeSpan?)(date - DateTimeOffset.UtcNow) : null);
            if (retryAfter < TimeSpan.Zero)
            {
                retryAfter = TimeSpan.Zero;
            }
        }

        var wantsDigest = response.Headers.WwwAuthenticate.Any(
            challenge => string.Equals(challenge.Scheme, "Digest", StringComparison.OrdinalIgnoreCase));
        return new Reply((int)response.StatusCode, body, retryAfter, wantsDigest);
    }

    /// <summary>连不上：分几种原因（不用系统给的文字：可能带主机名）。</summary>
    private static WebDavFailure Offline(HttpRequestException ex)
    {
        if (!NetworkInterface.GetIsNetworkAvailable())
        {
            return new WebDavFailure(WebDavError.Offline, "没联网");
        }

        return new WebDavFailure(WebDavError.Offline, ex.HttpRequestError switch
        {
            HttpRequestError.NameResolutionError => "找不到这个服务器",
            HttpRequestError.ConnectionError => "服务器没开或者端口不对",
            HttpRequestError.SecureConnectionError => "服务器的证书不受信任（不支持自签的证书）",
            HttpRequestError.ConfigurationLimitExceeded => "服务器回的东西太大",
            _ => "网络出错",
        });
    }

    // ---- multistatus ----

    /// <summary>解出来的一项（还没认哪个是文件夹自己）。</summary>
    public sealed class RawItem
    {
        public string Href { get; set; } = string.Empty;

        public bool IsFolder { get; set; }

        public string? ETag { get; set; }

        public DateTimeOffset? Modified { get; set; }

        public long Size { get; set; }
    }

    /// <summary>PROPFIND Depth 1 回的 multistatus → 文件夹里的东西（不含自己）；解不出来是 null。</summary>
    public static List<WebDavItem>? ParseListing(byte[] xml, Uri folder)
        => Multistatus(xml) is { } raw ? Children(raw, folder) : null;

    /// <summary>每个 response 一项；只认状态是 200 的那组 propstat 里的属性。不是 XML、带 DTD、根不是 DAV:multistatus 的是 null。</summary>
    public static List<RawItem>? Multistatus(byte[] xml)
    {
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
        };
        var items = new List<RawItem>();
        RawItem? current = null;
        var pending = new RawItem();
        var status = string.Empty;
        var text = new StringBuilder();
        var rooted = false;
        try
        {
            using var stream = new MemoryStream(xml, writable: false);
            using var reader = XmlReader.Create(stream, settings);
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                    {
                        text.Clear();
                        if (reader.Depth == 0)
                        {
                            rooted = reader.NamespaceURI == Dav && reader.LocalName == "multistatus";
                        }

                        if (reader.NamespaceURI != Dav)
                        {
                            break;
                        }

                        switch (reader.LocalName)
                        {
                            case "response":
                                current = new RawItem();
                                break;
                            case "propstat":
                                pending = new RawItem();
                                status = string.Empty;
                                break;
                            case "collection":
                                pending.IsFolder = true;
                                break;
                        }

                        break;
                    }

                    case XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.Whitespace or XmlNodeType.SignificantWhitespace:
                        text.Append(reader.Value);
                        break;
                    case XmlNodeType.EndElement:
                    {
                        if (reader.NamespaceURI == Dav)
                        {
                            var value = text.ToString().Trim();
                            switch (reader.LocalName)
                            {
                                case "href" when current is not null:
                                    current.Href = value;
                                    break;
                                case "status":
                                    status = value;
                                    break;
                                case "getetag":
                                    pending.ETag = value.Length == 0 ? null : value;
                                    break;
                                case "getlastmodified":
                                    pending.Modified = HttpDate(value);
                                    break;
                                case "getcontentlength":
                                    pending.Size = long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var size)
                                        ? size
                                        : 0;
                                    break;
                                case "propstat" when current is not null:
                                {
                                    // 「HTTP/1.1 200 OK」；没写状态的当成 200
                                    var parts = status.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                                    if (status.Length == 0 || (parts.Length > 1 && parts[1] == "200"))
                                    {
                                        current.IsFolder |= pending.IsFolder;
                                        current.ETag = pending.ETag ?? current.ETag;
                                        current.Modified = pending.Modified ?? current.Modified;
                                        if (pending.Size > 0)
                                        {
                                            current.Size = pending.Size;
                                        }
                                    }

                                    break;
                                }

                                case "response":
                                    if (current is { Href.Length: > 0 })
                                    {
                                        items.Add(current);
                                    }

                                    current = null;
                                    break;
                            }
                        }

                        text.Clear();
                        break;
                    }
                }
            }
        }
        catch (XmlException)
        {
            return null;
        }

        return rooted ? items : null;
    }

    /// <summary>去掉文件夹自己、取名字：href 解码后和请求的路径一样的是自己；对不上（前面隔着改路径的反向代理）时，第一项是同名的文件夹也算。</summary>
    public static List<WebDavItem> Children(IReadOnlyList<RawItem> raw, Uri folder)
    {
        static string PathOf(string href)
        {
            var decoded = (href.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                           href.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) &&
                          Uri.TryCreate(href, UriKind.Absolute, out var absolute)
                ? Uri.UnescapeDataString(absolute.AbsolutePath)
                : Uri.UnescapeDataString(href);
            return decoded.TrimEnd('/').Normalize(NormalizationForm.FormC);
        }

        var own = PathOf(folder.AbsolutePath);
        var ownName = own.Split('/').LastOrDefault();
        var items = new List<WebDavItem>();
        for (var index = 0; index < raw.Count; index++)
        {
            var entry = raw[index];
            var entryPath = PathOf(entry.Href);
            var name = entryPath.Split('/').LastOrDefault();
            if (string.IsNullOrEmpty(name))
            {
                continue;
            }

            if (entryPath == own || (index == 0 && entry.IsFolder && name == ownName))
            {
                continue;
            }

            items.Add(new WebDavItem(name, entry.IsFolder, entry.ETag, entry.Modified, entry.Size));
        }

        return items;
    }

    /// <summary>HTTP 的日期（RFC 1123：Wed, 13 Nov 2026 03:30:46 GMT）；认不出来是 null（镜像里的文件用写下来的时刻）。</summary>
    public static DateTimeOffset? HttpDate(string text)
        => DateTimeOffset.TryParseExact(
            text.Trim(), "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)
            ? date
            : null;
}
