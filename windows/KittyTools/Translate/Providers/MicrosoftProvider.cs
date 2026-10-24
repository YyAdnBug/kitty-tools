// 微软翻译（非流式）：填了 key 走认知服务，没填走 Edge 浏览器翻译的免登录接口（translatetext）。
// 免 key 那条是 2026-08 起可用的新地址；旧的 auth 换 token 流程已经 404。
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class MicrosoftProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var key = TranslateServiceStore.Instance?.Secret(service);
        var region = service.Region?.Trim() ?? string.Empty;

        Uri url;
        var headers = new Dictionary<string, string>();
        JsonNode body;
        if (!string.IsNullOrEmpty(key))
        {
            var builder = new UriBuilder("https://api.cognitive.microsofttranslator.com/translate")
            {
                Query = "api-version=3.0&to=" + Uri.EscapeDataString(Code(request.To)) +
                        (request.From is { } from ? "&from=" + Uri.EscapeDataString(Code(from)) : string.Empty),
            };
            url = builder.Uri;
            headers["Ocp-Apim-Subscription-Key"] = key;
            if (region.Length > 0)
            {
                headers["Ocp-Apim-Subscription-Region"] = region;
            }

            body = new JsonArray(new JsonObject { ["Text"] = request.Text });
        }
        else
        {
            var builder = new UriBuilder("https://edge.microsoft.com/translate/translatetext")
            {
                Query = "isEnterpriseClient=false&to=" + Uri.EscapeDataString(Code(request.To)) +
                        (request.From is { } from ? "&from=" + Uri.EscapeDataString(Code(from)) : string.Empty),
            };
            url = builder.Uri;
            body = new JsonArray(request.Text);
        }

        using var document = await TranslateHttp.SendAsync(url, headers, body, cancellationToken);
        var root = document.RootElement;
        var text = root.ValueKind == JsonValueKind.Array && root.GetArrayLength() > 0
            ? ReadTranslation(root[0])
            : null;
        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }

    public static string Code(Lang lang) => lang switch
    {
        Lang.ZhHans => "zh-Hans",
        Lang.ZhHant => "zh-Hant",
        _ => lang.Code(),
    };

    private static string? ReadTranslation(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object ||
            !item.TryGetProperty("translations", out var translations) ||
            translations.ValueKind != JsonValueKind.Array || translations.GetArrayLength() == 0)
        {
            return null;
        }

        var first = translations[0];
        return first.ValueKind == JsonValueKind.Object &&
               first.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String
            ? text.GetString()
            : null;
    }
}
