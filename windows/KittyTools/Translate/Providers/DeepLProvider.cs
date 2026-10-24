// DeepL（官方接口，免费版 key 以 :fx 结尾）或自建 DeepLX（设置里填地址）。
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class DeepLProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        Uri url;
        var headers = new Dictionary<string, string>();
        JsonObject body;
        var deeplx = service.UsesDeepLX;
        if (deeplx)
        {
            var raw = service.BaseUrl?.Trim() ?? string.Empty;
            if (raw.Length == 0)
            {
                throw TranslateError.Config("没填 DeepLX 地址");
            }

            if (!raw.Contains("://", StringComparison.Ordinal))
            {
                raw = "http://" + raw;
            }

            if (!Uri.TryCreate(raw, UriKind.Absolute, out var target))
            {
                throw TranslateError.Config("DeepLX 地址不正确");
            }

            url = target;
            body = new JsonObject
            {
                ["text"] = request.Text,
                ["source_lang"] = request.From is { } from ? SourceCode(from) : "auto",
                ["target_lang"] = TargetCode(request.To),
            };
        }
        else
        {
            var key = TranslateServiceStore.Instance?.Secret(service);
            if (string.IsNullOrEmpty(key))
            {
                throw TranslateError.Config("DeepL 的 Auth Key");
            }

            // 免费版 key 以 :fx 结尾，走 api-free 域名。
            var host = key.EndsWith(":fx", StringComparison.Ordinal) ? "api-free.deepl.com" : "api.deepl.com";
            url = new Uri($"https://{host}/v2/translate");
            headers["Authorization"] = $"DeepL-Auth-Key {key}";
            body = new JsonObject
            {
                ["text"] = new JsonArray(request.Text),
                ["target_lang"] = TargetCode(request.To),
            };
            if (request.From is { } from)
            {
                body["source_lang"] = SourceCode(from);
            }
        }

        using var document = await TranslateHttp.SendAsync(url, headers, body, cancellationToken);
        var text = Read(deeplx, document.RootElement);
        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }

    /// <summary>源语言只接受基础码（简繁都是 ZH，葡语 PT）。</summary>
    public static string SourceCode(Lang lang) => lang is Lang.ZhHans or Lang.ZhHant
        ? "ZH"
        : lang.Code().ToUpperInvariant();

    /// <summary>目标语言要带变体：ZH-HANS / ZH-HANT、EN-US、PT-BR。</summary>
    public static string TargetCode(Lang lang) => lang switch
    {
        Lang.ZhHans => "ZH-HANS",
        Lang.ZhHant => "ZH-HANT",
        Lang.En => "EN-US",
        Lang.Pt => "PT-BR",
        _ => lang.Code().ToUpperInvariant(),
    };

    private static string? Read(bool deeplx, JsonElement root)
    {
        if (!deeplx)
        {
            return root.ValueKind == JsonValueKind.Object &&
                   root.TryGetProperty("translations", out var translations) &&
                   translations.ValueKind == JsonValueKind.Array && translations.GetArrayLength() > 0 &&
                   translations[0].ValueKind == JsonValueKind.Object &&
                   translations[0].TryGetProperty("text", out var text) &&
                   text.ValueKind == JsonValueKind.String
                ? text.GetString()
                : null;
        }

        return root.ValueKind == JsonValueKind.Object &&
               root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.String
            ? data.GetString()
            : null;
    }
}
