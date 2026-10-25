// 云厂商翻译的签名（第三版 §3.6，纯函数 + 单测）：百度 MD5、有道 v3 SHA-256、火山引擎 HMAC-SHA256（类 SigV4）、
// 腾讯云 TC3-HMAC-SHA256。时间由参数传入，单测用独立算出的期望值校验。
// 语言码各家不同，映射也在这里（同 mac 的 RESTProviders / CloudProviders）。
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace KittyTools.Core;

public static class TranslateSigning
{
    public static string Md5Hex(string text)
        => Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(text)));

    public static string Sha256Hex(string text) => Sha256Hex(Encoding.UTF8.GetBytes(text));

    public static string Sha256Hex(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    public static byte[] HmacSha256(byte[] key, string message)
        => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(message));

    public static string HmacHex(byte[] key, string message) => Convert.ToHexStringLower(HmacSha256(key, message));

    /// <summary>x-www-form-urlencoded（按传入顺序，值做百分号编码）。</summary>
    public static byte[] Form(IEnumerable<(string Name, string Value)> fields)
        => Encoding.UTF8.GetBytes(string.Join(
            '&', fields.Select(field => $"{Uri.EscapeDataString(field.Name)}={Uri.EscapeDataString(field.Value)}")));

    // ---- 百度 ----

    public static string BaiduSign(string appId, string text, string salt, string secret)
        => Md5Hex(appId + text + salt + secret);

    public static string BaiduCode(string? lang) => lang switch
    {
        null or "" => "auto",
        "zh-Hans" => "zh",
        "zh-Hant" => "cht",
        "ja" => "jp",
        "ko" => "kor",
        "fr" => "fra",
        "es" => "spa",
        _ => lang,
    };

    // ---- 有道 ----

    /// <summary>v3：sha256(应用ID + input + salt + curtime + 应用密钥)；input 超过 20 字取「前 10 字 + 字数 + 后 10 字」。</summary>
    public static string YoudaoSign(string appKey, string text, string salt, string time, string secret)
    {
        var input = text.Length <= 20
            ? text
            : string.Concat(text.AsSpan(0, 10), text.Length.ToString(CultureInfo.InvariantCulture),
                text.AsSpan(text.Length - 10, 10));
        return Sha256Hex(appKey + input + salt + time + secret);
    }

    public static string YoudaoCode(string? lang) => lang switch
    {
        null or "" => "auto",
        "zh-Hans" => "zh-CHS",
        "zh-Hant" => "zh-CHT",
        _ => lang,
    };

    // ---- 火山引擎 ----

    public const string VolcengineHost = "open.volcengineapi.com";

    public const string VolcengineQuery = "Action=TranslateText&Version=2020-06-01";

    public static string VolcengineCode(string? lang) => lang switch
    {
        "zh-Hans" => "zh",
        "zh-Hant" => "zh-Hant",
        null or "" => "auto",
        _ => lang,
    };

    /// <summary>规范请求（4 个头）→ 待签字符串 → 用 Secret Key 逐级派生（日期 → 区域 → 服务 → request）。</summary>
    public static Dictionary<string, string> VolcengineHeaders(
        string accessKey, string secretKey, byte[] body, DateTime utcNow)
    {
        const string region = "cn-north-1";
        const string service = "translate";
        var xDate = utcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var shortDate = xDate[..8];
        var bodyHash = Sha256Hex(body);
        const string signedHeaders = "content-type;host;x-content-sha256;x-date";
        var canonicalRequest = string.Join(
            '\n',
            "POST", "/", VolcengineQuery,
            $"content-type:application/json\nhost:{VolcengineHost}\nx-content-sha256:{bodyHash}\nx-date:{xDate}\n",
            signedHeaders, bodyHash);
        var scope = $"{shortDate}/{region}/{service}/request";
        var stringToSign = string.Join('\n', "HMAC-SHA256", xDate, scope, Sha256Hex(canonicalRequest));
        var key = Encoding.UTF8.GetBytes(secretKey);
        foreach (var part in new[] { shortDate, region, service, "request" })
        {
            key = HmacSha256(key, part);
        }

        var signature = HmacHex(key, stringToSign);
        return new Dictionary<string, string>
        {
            ["Authorization"] =
                $"HMAC-SHA256 Credential={accessKey}/{scope}, SignedHeaders={signedHeaders}, Signature={signature}",
            ["Content-Type"] = "application/json",
            ["Host"] = VolcengineHost,
            ["X-Content-Sha256"] = bodyHash,
            ["X-Date"] = xDate,
        };
    }

    // ---- 腾讯云 ----

    public const string TencentHost = "tmt.tencentcloudapi.com";

    public static string TencentCode(string? lang) => lang switch
    {
        "zh-Hans" => "zh",
        "zh-Hant" => "zh-TW",
        null or "" => "auto",
        _ => lang,
    };

    /// <summary>TC3-HMAC-SHA256：签名头 content-type;host；密钥派生 "TC3"+SecretKey → 日期(UTC) → tmt → tc3_request。</summary>
    public static Dictionary<string, string> TencentHeaders(
        string secretId, string secretKey, byte[] body, long unixSeconds)
    {
        const string contentType = "application/json; charset=utf-8";
        var date = DateTimeOffset.FromUnixTimeSeconds(unixSeconds).UtcDateTime
            .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var canonicalRequest = string.Join(
            '\n', "POST", "/", string.Empty,
            $"content-type:{contentType}\nhost:{TencentHost}\n", "content-type;host", Sha256Hex(body));
        var scope = $"{date}/tmt/tc3_request";
        var stringToSign = string.Join(
            '\n', "TC3-HMAC-SHA256", unixSeconds.ToString(CultureInfo.InvariantCulture), scope,
            Sha256Hex(canonicalRequest));
        var key = Encoding.UTF8.GetBytes("TC3" + secretKey);
        foreach (var part in new[] { date, "tmt", "tc3_request" })
        {
            key = HmacSha256(key, part);
        }

        var signature = HmacHex(key, stringToSign);
        return new Dictionary<string, string>
        {
            ["Authorization"] =
                $"TC3-HMAC-SHA256 Credential={secretId}/{scope}, SignedHeaders=content-type;host, Signature={signature}",
            ["Content-Type"] = contentType,
            ["Host"] = TencentHost,
            ["X-TC-Action"] = "TextTranslate",
            ["X-TC-Timestamp"] = unixSeconds.ToString(CultureInfo.InvariantCulture),
            ["X-TC-Version"] = "2018-03-21",
            ["X-TC-Region"] = "ap-beijing",
        };
    }
}
