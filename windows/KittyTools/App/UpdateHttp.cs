// 自动更新的网络层（REVIEW R1、R3）：自己逐跳处理跳转、每一跳都过白名单；下载流式写 .partial。
//
// 正常运行的 Release 版只认 UpdateTrust 里的 GitHub https 地址；KITTY_UPDATE_FEED、file://、
// 本地路径、http:// 只在 Debug 构建或带 --update-test 启动时才认（UpdateTrust.AllowTestSources）。
// 下载先写 <文件名>.partial，写完才改名；失败、取消、校验不过都删掉半成品（R3）。
// 日志里不写 URL、不写请求头。
using System.Net;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class UpdateHttp
{
#if DEBUG
    private const bool IsDebugBuild = true;
#else
    private const bool IsDebugBuild = false;
#endif

    private const int MaxRedirects = 5;

    private static readonly TimeSpan FeedTimeout = TimeSpan.FromSeconds(12);
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(10);

    /// <summary>这一轮允不允许测试用的地址（Debug 或 --update-test）。</summary>
    public static bool TestMode { get; } =
        UpdateTrust.AllowTestSources(IsDebugBuild, Environment.GetCommandLineArgs());

    /// <summary>读发布列表（GitHub API）。</summary>
    public static async Task<string> GetFeedAsync(string feed, CancellationToken cancellationToken = default)
    {
        EnsureTrusted(feed, isFeed: true);
        if (IsLocalSource(feed))
        {
            return await File.ReadAllTextAsync(LocalPath(feed), cancellationToken);
        }

        using var client = NewClient(FeedTimeout);
        using var response = await SendAsync(client, feed, cancellationToken);
        return await response.Content.ReadAsStringAsync(cancellationToken);
    }

    /// <summary>读 .sha256 的文本（和 zip 一样只认白名单里的地址）。</summary>
    public static async Task<string> GetTextAsync(string url, CancellationToken cancellationToken = default)
    {
        EnsureTrusted(url, isFeed: false);
        if (IsLocalSource(url))
        {
            return await File.ReadAllTextAsync(LocalPath(url), cancellationToken);
        }

        using var client = NewClient(FeedTimeout);
        using var response = await SendAsync(client, url, cancellationToken);
        return await response.Content.ReadAsStringAsync(cancellationToken);
    }

    /// <summary>
    /// 流式下载到 <paramref name="path"/>：先写 path + ".partial"，成功才改名。
    /// <paramref name="progress"/> 收到「已下载字节 / 总字节（可能不知道）」。
    /// </summary>
    public static async Task DownloadAsync(
        string url,
        string path,
        Action<long, long?>? progress,
        CancellationToken cancellationToken = default)
    {
        EnsureTrusted(url, isFeed: false);
        if (IsLocalSource(url))
        {
            var local = LocalPath(url);
            await UpdateDownload.WriteAsync(
                path, _ => Task.FromResult<Stream>(File.OpenRead(local)), progress, cancellationToken);
            return;
        }

        using var client = NewClient(DownloadTimeout);
        using var response = await SendAsync(client, url, cancellationToken);
        var total = response.Content.Headers.ContentLength;
        await UpdateDownload.WriteAsync(
            path,
            async ct =>
            {
                var stream = await response.Content.ReadAsStreamAsync(ct);
                return new ResponseStream(stream, total);
            },
            progress,
            cancellationToken,
            knownTotal: total);
    }

    /// <summary>下载 / 校验途中失败时删掉半成品（R3 的验收：断网后 updates\ 里没有残留）。</summary>
    public static void TryDelete(string path) => UpdateDownload.TryDelete(path);

    /// <summary>把 updates\ 里上次留下的半成品清掉（启动时调一次）。</summary>
    public static void CleanupPartialFiles(string directory)
    {
        try
        {
            if (!Directory.Exists(directory))
            {
                return;
            }

            foreach (var file in Directory.EnumerateFiles(directory, "*.partial"))
            {
                TryDelete(file);
            }
        }
        catch
        {
            // 目录没有权限之类的，忽略。
        }
    }

    private static HttpClient NewClient(TimeSpan timeout)
    {
        // 自己处理跳转：自动跳转会让每一跳都跳过白名单检查。
        var handler = new HttpClientHandler { AllowAutoRedirect = false };
        var client = new HttpClient(handler) { Timeout = timeout };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("KittyTools-Windows");
        return client;
    }

    private static async Task<HttpResponseMessage> SendAsync(
        HttpClient client,
        string url,
        CancellationToken cancellationToken)
    {
        var current = url;
        for (var hop = 0; hop <= MaxRedirects; hop++)
        {
            var response = await client.GetAsync(current, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (IsRedirect(response.StatusCode))
            {
                var location = response.Headers.Location;
                response.Dispose();
                if (location is null)
                {
                    throw new HttpRequestException("redirect-without-location");
                }

                // 转义原样保留（ToString 会把 %20 还原成空格，真 GitHub 的跳转地址过不了白名单，见 NextHop）。
                current = UpdateTrust.NextHop(current, location);
                // 跳转之后的每一跳也按同一张表查（R1）。
                EnsureTrusted(current, isFeed: false);
                continue;
            }

            response.EnsureSuccessStatusCode();
            return response;
        }

        throw new HttpRequestException("too-many-redirects");
    }

    private static bool IsRedirect(HttpStatusCode status)
        => status is HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther
            or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect;

    /// <summary>包一层响应流，让 Core 的 WriteAsync 用 await using 关掉它。</summary>
    private sealed class ResponseStream(Stream inner, long? total) : Stream
    {
        public override bool CanRead => inner.CanRead;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => total ?? 0;

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() => inner.Flush();

        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);

        public override long Seek(long offset, SeekOrigin loc) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer, CancellationToken cancellationToken = default)
            => inner.ReadAsync(buffer, cancellationToken);

        public override Task<int> ReadAsync(
            byte[] buffer, int offset, int count, CancellationToken cancellationToken)
            => inner.ReadAsync(buffer, offset, count, cancellationToken);

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inner.Dispose();
            }

            base.Dispose(disposing);
        }

        public override async ValueTask DisposeAsync()
        {
            await inner.DisposeAsync();
            await base.DisposeAsync();
        }
    }

    private static bool IsLocalSource(string url)
        => url.StartsWith("file://", StringComparison.OrdinalIgnoreCase)
           || !url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
           && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase);

    private static string LocalPath(string url)
        => url.StartsWith("file://", StringComparison.OrdinalIgnoreCase) ? new Uri(url).LocalPath : url;

    /// <summary>白名单检查：测试模式下放行，正常 Release 只认 GitHub 的 https 地址。</summary>
    private static void EnsureTrusted(string url, bool isFeed)
    {
        if (TestMode)
        {
            return;
        }

        var allowed = isFeed ? UpdateTrust.IsAllowedFeedUrl(url) : UpdateTrust.IsAllowedDownloadUrl(url);
        if (!allowed)
        {
            Log.Warn("update.untrusted-url");
            throw new InvalidOperationException("update-untrusted-url");
        }
    }
}
