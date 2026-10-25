// 四家传统云厂商翻译（第三版 §3.6）：百度、有道、火山引擎、腾讯云。
// 都是非流式（一次请求、一次给全文）；签名在 Core 的 TranslateSigning（纯函数 + 单测）。
// 错误按各家错误码给用户看得懂的中文，密钥 / 签名类算配置错误（橙色、只给「打开设置」）。
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class BaiduProvider
{
    public const int Limit = 6000;

    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var store = TranslateServiceStore.Instance;
        var appId = store?.Secret(service, "appId");
        var secret = store?.Secret(service, "secret");
        if (string.IsNullOrWhiteSpace(appId) || string.IsNullOrWhiteSpace(secret))
        {
            throw TranslateError.Config("百度翻译的 App ID 和密钥");
        }

        if (request.Text.Length > Limit)
        {
            throw new TranslateError($"一次最多 {Limit} 个字", TranslateErrorKind.Config);
        }

        var salt = Random.Shared.Next(1_000_000, 10_000_000).ToString(
            System.Globalization.CultureInfo.InvariantCulture);
        var fields = new List<(string, string)>
        {
            ("q", request.Text),
            ("from", TranslateSigning.BaiduCode(request.From?.Code())),
            ("to", TranslateSigning.BaiduCode(request.To.Code())),
            ("appid", appId),
            ("salt", salt),
            ("sign", TranslateSigning.BaiduSign(appId, request.Text, salt, secret)),
        };
        using var document = await TranslateHttp.SendFormAsync(
            new Uri("https://fanyi-api.baidu.com/api/trans/vip/translate"),
            new Dictionary<string, string>(),
            fields,
            cancellationToken);
        var root = document.RootElement;
        if (root.TryGetProperty("error_code", out var error) &&
            error.ValueKind == JsonValueKind.String &&
            error.GetString() is { } code && code != "52000")
        {
            throw Error(code);
        }

        var text = string.Empty;
        if (root.TryGetProperty("trans_result", out var results) && results.ValueKind == JsonValueKind.Array)
        {
            text = string.Join('\n', results.EnumerateArray()
                .Select(item => item.TryGetProperty("dst", out var dst) ? dst.GetString() : null)
                .Where(value => value is not null));
        }

        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }

    public static TranslateError Error(string code) => code switch
    {
        "52001" => new TranslateError("百度翻译请求超时，请重试", TranslateErrorKind.Network),
        "52002" => new TranslateError("百度翻译系统出错，请重试", TranslateErrorKind.Service),
        "52003" or "54001" or "90107" => TranslateError.Config("App ID 或密钥不对"),
        "54003" => new TranslateError("请求太频繁，稍后再试", TranslateErrorKind.Service),
        "54004" => new TranslateError("百度翻译账户余额不足", TranslateErrorKind.Config),
        "58001" => new TranslateError("百度翻译不支持这个语言方向", TranslateErrorKind.Service),
        "58002" => TranslateError.Config("服务已关闭，请到百度翻译开放平台开通"),
        _ => new TranslateError($"百度翻译出错（错误码 {code}）", TranslateErrorKind.Service),
    };
}

internal static class YoudaoProvider
{
    public const int Limit = 5000;

    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var store = TranslateServiceStore.Instance;
        var appKey = store?.Secret(service, "appKey");
        var appSecret = store?.Secret(service, "appSecret");
        if (string.IsNullOrWhiteSpace(appKey) || string.IsNullOrWhiteSpace(appSecret))
        {
            throw TranslateError.Config("有道翻译的应用 ID 和应用密钥");
        }

        if (request.Text.Length > Limit)
        {
            throw new TranslateError($"一次最多 {Limit} 个字", TranslateErrorKind.Config);
        }

        var salt = Guid.NewGuid().ToString();
        var time = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(
            System.Globalization.CultureInfo.InvariantCulture);
        var fields = new List<(string, string)>
        {
            ("q", request.Text),
            ("from", TranslateSigning.YoudaoCode(request.From?.Code())),
            ("to", TranslateSigning.YoudaoCode(request.To.Code())),
            ("appKey", appKey),
            ("salt", salt),
            ("signType", "v3"),
            ("curtime", time),
            ("sign", TranslateSigning.YoudaoSign(appKey, request.Text, salt, time, appSecret)),
        };
        using var document = await TranslateHttp.SendFormAsync(
            new Uri("https://openapi.youdao.com/api"),
            new Dictionary<string, string>(),
            fields,
            cancellationToken);
        var root = document.RootElement;
        var code = root.TryGetProperty("errorCode", out var value)
            ? value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString()
            : "未知";
        if (code != "0")
        {
            throw Error(code ?? "未知");
        }

        var text = root.TryGetProperty("translation", out var translation) &&
                   translation.ValueKind == JsonValueKind.Array
            ? string.Join('\n', translation.EnumerateArray()
                .Select(item => item.GetString())
                .Where(item => item is not null))
            : string.Empty;
        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }

    public static TranslateError Error(string code) => code switch
    {
        "101" or "108" or "202" => TranslateError.Config("应用 ID 或应用密钥不对"),
        "401" => new TranslateError("有道翻译账户已欠费", TranslateErrorKind.Config),
        "411" => new TranslateError("请求太频繁，稍后再试", TranslateErrorKind.Service),
        _ => new TranslateError($"有道翻译出错（错误码 {code}）", TranslateErrorKind.Service),
    };
}

internal static class VolcengineProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var store = TranslateServiceStore.Instance;
        var accessKey = store?.Secret(service, "accessKey");
        var secretKey = store?.Secret(service, "secretKey");
        if (string.IsNullOrWhiteSpace(accessKey) || string.IsNullOrWhiteSpace(secretKey))
        {
            throw TranslateError.Config("火山引擎的 Access Key 和 Secret Key");
        }

        var body = new JsonObject
        {
            ["TargetLanguage"] = TranslateSigning.VolcengineCode(request.To.Code()),
            ["TextList"] = new JsonArray(request.Text),
        };
        if (request.From is { } from)
        {
            body["SourceLanguage"] = TranslateSigning.VolcengineCode(from.Code());
        }

        var bytes = Encoding.UTF8.GetBytes(body.ToJsonString());
        var headers = TranslateSigning.VolcengineHeaders(accessKey, secretKey, bytes, DateTime.UtcNow);
        using var document = await TranslateHttp.SendRawAsync(
            new Uri($"https://{TranslateSigning.VolcengineHost}/?{TranslateSigning.VolcengineQuery}"),
            headers, bytes, "application/json", cancellationToken);
        var root = document.RootElement;
        if (root.TryGetProperty("ResponseMetadata", out var metadata) &&
            metadata.TryGetProperty("Error", out var error))
        {
            var message = error.TryGetProperty("Message", out var value) ? value.GetString() : "未知";
            var code = error.TryGetProperty("Code", out var codeValue) ? codeValue.GetString() ?? "" : "";
            var config = code.Contains("Signature", StringComparison.Ordinal) ||
                         code.Contains("AccessKey", StringComparison.Ordinal) ||
                         code.Contains("Auth", StringComparison.Ordinal);
            throw new TranslateError(
                $"火山翻译错误：{Trim(message)}",
                config ? TranslateErrorKind.Config : TranslateErrorKind.Service);
        }

        var text = root.TryGetProperty("TranslationList", out var list) &&
                   list.ValueKind == JsonValueKind.Array && list.GetArrayLength() > 0 &&
                   list[0].TryGetProperty("Translation", out var translation)
            ? translation.GetString()
            : null;
        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }

    private static string Trim(string? message)
        => string.IsNullOrEmpty(message) ? "未知" : message.Length <= 160 ? message : message[..160];
}

internal static class TencentProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var store = TranslateServiceStore.Instance;
        var secretId = store?.Secret(service, "secretId");
        var secretKey = store?.Secret(service, "secretKey");
        if (string.IsNullOrWhiteSpace(secretId) || string.IsNullOrWhiteSpace(secretKey))
        {
            throw TranslateError.Config("腾讯云的 SecretId 和 SecretKey");
        }

        var body = new JsonObject
        {
            ["SourceText"] = request.Text,
            ["Source"] = request.From is { } from
                ? TranslateSigning.TencentCode(from.Code())
                : "auto",
            ["Target"] = TranslateSigning.TencentCode(request.To.Code()),
            ["ProjectId"] = 0,
        };
        var bytes = Encoding.UTF8.GetBytes(body.ToJsonString());
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var headers = TranslateSigning.TencentHeaders(secretId, secretKey, bytes, timestamp);
        using var document = await TranslateHttp.SendRawAsync(
            new Uri($"https://{TranslateSigning.TencentHost}"),
            headers, bytes, "application/json; charset=utf-8", cancellationToken);
        var root = document.RootElement;
        if (root.TryGetProperty("Response", out var response) &&
            response.TryGetProperty("Error", out var error))
        {
            var message = error.TryGetProperty("Message", out var value) ? value.GetString() : "未知";
            var code = error.TryGetProperty("Code", out var codeValue) ? codeValue.GetString() ?? "" : "";
            throw new TranslateError(
                $"腾讯翻译错误：{(string.IsNullOrEmpty(message) ? "未知" : message.Length <= 160 ? message : message[..160])}",
                code.StartsWith("AuthFailure", StringComparison.Ordinal)
                    ? TranslateErrorKind.Config
                    : TranslateErrorKind.Service);
        }

        var text = response.TryGetProperty("TargetText", out var target) ? target.GetString() : null;
        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }
}
