// 启动器汇率换算的汇率表（PLAN-v12 N1，照 mac ExchangeRates.fetch / load / save）：联网取、存在数据目录、启动器用时读。
// 取：依次问 Core 的 ExchangeRates.Sources（jsDelivr，连不上换数据源自己的备用地址），5 秒没回、不是 200、回的不是一张像样的表
// （ExchangeRates.FromReply 验过）都换下一家；都不成就 null。不带 Cookie、不解 Brotli（压缩只收 gzip / deflate）。
// 存：数据目录的 exchange-rates.json（先写临时名再换过去）；不进设置文件、不导出、不同步（同 mac 不注册默认值）。
// 日志里不写地址和汇率（AGENTS 红线），只写成没成、几种货币。
using System.Net;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class ExchangeRateStore
{
    /// <summary>数据源回的一份不超过这么大（实测约 3 KB 压缩、7 KB 原文）；再大就不是那张表了。</summary>
    private const int MaxReplyBytes = 1 << 20;

    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        UseCookies = false,
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 3,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
    })
    {
        Timeout = TimeSpan.FromSeconds(5),
    };

    private static string FilePath => Path.Combine(Paths.DataDirectory, "exchange-rates.json");

    /// <summary>存着的那份；没有、读不出来、坏了是 null。</summary>
    public static ExchangeRates.Table? Load()
    {
        try
        {
            return File.Exists(FilePath) ? ExchangeRates.Decode(File.ReadAllText(FilePath, Encoding.UTF8)) : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.rates-load-failed {ex.GetType().Name}");
            return null;
        }
    }

    public static void Save(ExchangeRates.Table table)
    {
        try
        {
            Directory.CreateDirectory(Paths.DataDirectory);
            var temporary = FilePath + ".tmp";
            File.WriteAllText(temporary, ExchangeRates.Encode(table), new UTF8Encoding(false));
            File.Move(temporary, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.rates-save-failed {ex.GetType().Name}");
        }
    }

    /// <summary>依次问数据源，取到一张像样的表就返回；都不成是 null。哪个线程调都行。</summary>
    public static async Task<ExchangeRates.Table?> FetchAsync(CancellationToken cancellation)
    {
        for (var index = 0; index < ExchangeRates.Sources.Count; index++)
        {
            try
            {
                using var response = await Http.GetAsync(
                    ExchangeRates.Sources[index], HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
                if (response.StatusCode != HttpStatusCode.OK ||
                    response.Content.Headers.ContentLength is > MaxReplyBytes)
                {
                    Log.Warn($"launcher.rates-source-failed source={index} status={(int)response.StatusCode}");
                    continue;
                }

                var bytes = await response.Content.ReadAsByteArrayAsync(cancellation).ConfigureAwait(false);
                var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                if (bytes.Length <= MaxReplyBytes &&
                    ExchangeRates.FromReply(Encoding.UTF8.GetString(bytes), now) is { } table)
                {
                    Log.Info($"launcher.rates-fetched source={index} currencies={table.Rates.Count}");
                    return table;
                }

                Log.Warn($"launcher.rates-source-invalid source={index}");
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                // 超时（TaskCanceledException，不是我们取消的）、断网、DNS 解析不了都换下一家。
                Log.Warn($"launcher.rates-source-failed source={index} {ex.GetType().Name}");
            }
        }

        return null;
    }
}
