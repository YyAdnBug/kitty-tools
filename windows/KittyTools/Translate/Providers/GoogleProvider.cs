// Google 翻译（v2，需要 API Key；非流式）。
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class GoogleProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var key = TranslateServiceStore.Instance?.Secret(service);
        if (string.IsNullOrEmpty(key))
        {
            throw TranslateError.Config("Google 的 API Key");
        }

        var url = new Uri(
            "https://translation.googleapis.com/language/translate/v2?key=" + Uri.EscapeDataString(key));
        var body = new JsonObject
        {
            ["q"] = request.Text,
            ["target"] = Code(request.To),
            ["format"] = "text",
        };
        if (request.From is { } from)
        {
            body["source"] = Code(from);
        }

        using var document = await TranslateHttp.SendAsync(
            url, new Dictionary<string, string>(), body, cancellationToken);
        var root = document.RootElement;
        var text = root.ValueKind == JsonValueKind.Object &&
                   root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object &&
                   data.TryGetProperty("translations", out var translations) &&
                   translations.ValueKind == JsonValueKind.Array && translations.GetArrayLength() > 0 &&
                   translations[0].ValueKind == JsonValueKind.Object &&
                   translations[0].TryGetProperty("translatedText", out var translated) &&
                   translated.ValueKind == JsonValueKind.String
            ? translated.GetString()
            : null;
        if (string.IsNullOrEmpty(text))
        {
            throw TranslateError.EmptyResult;
        }

        yield return text;
    }

    public static string Code(Lang lang) => lang switch
    {
        Lang.ZhHans => "zh-CN",
        Lang.ZhHant => "zh-TW",
        _ => lang.Code(),
    };
}
