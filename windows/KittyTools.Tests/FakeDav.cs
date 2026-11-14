// 测试用的 WebDAV 服务器（PLAN-v19 D3）：一个 HttpMessageHandler，拿临时文件夹当服务器真读真写，不开端口、不弹防火墙。
// 认 PROPFIND（只认 Depth 1）、GET、PUT（If-None-Match: *）、DELETE、MKCOL、MOVE（Overwrite: F），带 Basic 认证；
// https://dav.test/dav/ 对应 Root。能按请求插话（Intercept：回 429 / 503、跳转这些）、能断网（Offline）、能当成不支持 MOVE，
// 记下每个请求（「方法 路径」，路径相对 Root）。ETag 按内容算（不按改动时间：NTFS 的时间戳一次写不到毫秒，连着写两遍会撞上）。
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using KittyTools.Core.Sync;

namespace KittyTools.Tests;

internal sealed class FakeDav(string root) : HttpMessageHandler
{
    public const string User = "kitty";
    public const string Password = "secret";

    public static readonly Uri Base = new("https://dav.test/dav/");

    public string Root { get; } = root;

    public List<string> Log { get; } = new();

    public bool Offline { get; set; }

    public bool SupportsMove { get; set; } = true;

    /// <summary>插话：返回非 null 就直接回它（第二个参数是相对 Root 的路径）。</summary>
    public Func<HttpRequestMessage, string, HttpResponseMessage?>? Intercept { get; set; }

    /// <summary>服务器上的这个文件夹（path 相对 Base，以 / 结尾或空着 = Base 本身）。</summary>
    public static WebDavAccount Account(string path = "", string password = Password)
        => new(new Uri(Base, path), User, password);

    public WebDavTransport Transport() => new(new HttpClient(this, disposeHandler: false));

    public WebDav Dav(string password = Password) => new(Account(password: password), Transport());

    public List<string> Requests()
    {
        lock (Log)
        {
            return Log.ToList();
        }
    }

    public void ClearLog()
    {
        lock (Log)
        {
            Log.Clear();
        }
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (Offline)
        {
            throw new HttpRequestException(HttpRequestError.ConnectionError, "offline");
        }

        var relative = Relative(request.RequestUri!);
        lock (Log)
        {
            Log.Add($"{request.Method.Method} {relative ?? "?"}");
        }

        if (Intercept?.Invoke(request, relative ?? string.Empty) is { } intercepted)
        {
            return intercepted;
        }

        var expected = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(User + ":" + Password));
        if (request.Headers.Authorization?.ToString() != expected)
        {
            var refused = new HttpResponseMessage(HttpStatusCode.Unauthorized);
            refused.Headers.WwwAuthenticate.Add(new AuthenticationHeaderValue("Basic", "realm=\"dav\""));
            return refused;
        }

        if (relative is null)
        {
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }

        var local = Local(relative);
        var body = request.Content is null ? Array.Empty<byte>() : await request.Content.ReadAsByteArrayAsync(cancellationToken);
        return request.Method.Method switch
        {
            "PROPFIND" => Propfind(request, relative, local),
            "GET" => File.Exists(local)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(File.ReadAllBytes(local)) }
                : new HttpResponseMessage(HttpStatusCode.NotFound),
            "PUT" => Put(request, local, body),
            "DELETE" => Delete(local),
            "MKCOL" => Mkcol(local),
            "MOVE" => Move(request, local),
            _ => new HttpResponseMessage(HttpStatusCode.MethodNotAllowed),
        };
    }

    /// <summary>网址 → 相对 Root 的路径（解码后、不带结尾的 /）；不在 Base 下面是 null。</summary>
    private static string? Relative(Uri uri)
    {
        var path = Uri.UnescapeDataString(uri.AbsolutePath);
        var basePath = Base.AbsolutePath;
        if (path == basePath.TrimEnd('/'))
        {
            return string.Empty;
        }

        return path.StartsWith(basePath, StringComparison.Ordinal) ? path[basePath.Length..].TrimEnd('/') : null;
    }

    private string Local(string relative)
        => relative.Length == 0 ? Root : Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));

    private static string ETag(string file)
        => "\"" + Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file)))[..16] + "\"";

    private HttpResponseMessage Propfind(HttpRequestMessage request, string relative, string local)
    {
        if (!request.Headers.TryGetValues("Depth", out var depth) || depth.FirstOrDefault() != "1")
        {
            return new HttpResponseMessage(HttpStatusCode.BadRequest);
        }

        var entries = new List<(string Relative, string Local)>();
        if (Directory.Exists(local))
        {
            entries.Add((relative, local));
            foreach (var child in Directory.EnumerateFileSystemEntries(local).Order(StringComparer.Ordinal))
            {
                var name = Path.GetFileName(child);
                entries.Add((relative.Length == 0 ? name : relative + "/" + name, child));
            }
        }
        else if (File.Exists(local))
        {
            entries.Add((relative, local));
        }
        else
        {
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }

        var xml = new StringBuilder("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">");
        foreach (var (path, file) in entries)
        {
            var folder = Directory.Exists(file);
            var href = Base.AbsolutePath +
                       string.Join('/', path.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(name => Uri.EscapeDataString(name))) +
                       (folder && path.Length > 0 ? "/" : string.Empty);
            xml.Append("<D:response><D:href>").Append(href).Append("</D:href><D:propstat><D:prop>");
            if (folder)
            {
                xml.Append("<D:resourcetype><D:collection/></D:resourcetype>");
            }
            else
            {
                var info = new FileInfo(file);
                xml.Append("<D:resourcetype/><D:getetag>").Append(ETag(file)).Append("</D:getetag>")
                    .Append("<D:getlastmodified>")
                    .Append(info.LastWriteTimeUtc.ToString("r", CultureInfo.InvariantCulture))
                    .Append("</D:getlastmodified><D:getcontentlength>").Append(info.Length).Append("</D:getcontentlength>");
            }

            xml.Append("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>");
        }

        xml.Append("</D:multistatus>");
        return new HttpResponseMessage((HttpStatusCode)207)
        {
            Content = new StringContent(xml.ToString(), Encoding.UTF8, "application/xml"),
        };
    }

    private static HttpResponseMessage Put(HttpRequestMessage request, string local, byte[] body)
    {
        if (!Directory.Exists(Path.GetDirectoryName(local)))
        {
            return new HttpResponseMessage(HttpStatusCode.Conflict);
        }

        if (request.Headers.TryGetValues("If-None-Match", out var match) && match.Contains("*") && File.Exists(local))
        {
            return new HttpResponseMessage(HttpStatusCode.PreconditionFailed);
        }

        File.WriteAllBytes(local, body);
        return new HttpResponseMessage(HttpStatusCode.Created);
    }

    private static HttpResponseMessage Delete(string local)
    {
        if (File.Exists(local))
        {
            File.Delete(local);
            return new HttpResponseMessage(HttpStatusCode.NoContent);
        }

        if (Directory.Exists(local))
        {
            Directory.Delete(local, recursive: true);
            return new HttpResponseMessage(HttpStatusCode.NoContent);
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    }

    private static HttpResponseMessage Mkcol(string local)
    {
        if (File.Exists(local) || Directory.Exists(local))
        {
            return new HttpResponseMessage(HttpStatusCode.MethodNotAllowed);
        }

        if (!Directory.Exists(Path.GetDirectoryName(local)))
        {
            return new HttpResponseMessage(HttpStatusCode.Conflict);
        }

        Directory.CreateDirectory(local);
        return new HttpResponseMessage(HttpStatusCode.Created);
    }

    private HttpResponseMessage Move(HttpRequestMessage request, string local)
    {
        if (!SupportsMove)
        {
            return new HttpResponseMessage(HttpStatusCode.MethodNotAllowed);
        }

        if (!request.Headers.TryGetValues("Destination", out var destination) ||
            Relative(new Uri(destination.First())) is not { } target)
        {
            return new HttpResponseMessage(HttpStatusCode.BadRequest);
        }

        var to = Local(target);
        var overwrite = !request.Headers.TryGetValues("Overwrite", out var flag) || flag.First() != "F";
        if (File.Exists(to) && !overwrite)
        {
            return new HttpResponseMessage(HttpStatusCode.PreconditionFailed);
        }

        if (!File.Exists(local))
        {
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }

        File.Move(local, to, overwrite);
        return new HttpResponseMessage(HttpStatusCode.Created);
    }
}
