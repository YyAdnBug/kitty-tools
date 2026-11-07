// 有道词典（PLAN-v14 V4，照 mac YoudaoDict）：有道词典网页版的查词接口，一个普通的 GET（不签名、不带冒充别的客户端的请求头），
// 只查单词和短语：英文词出美 / 英音标、各词性的释义、变形、一个双语例句，中文词出拼音和英文释义（Core YoudaoDict.Entry）。
// 不是单词的原文不开它的卡（TranslateCoordinator.Start），也不当主结果、不进静默替换。非流式。
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class YoudaoDictProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var text = await TranslateHttp.GetTextAsync(
            YoudaoDict.RequestUrl(request.Text), new Dictionary<string, string>(), cancellationToken);
        string? entry;
        try
        {
            using var document = JsonDocument.Parse(text);
            entry = YoudaoDict.Entry(document.RootElement);
        }
        catch (JsonException)
        {
            entry = null;
        }

        if (string.IsNullOrEmpty(entry))
        {
            throw new TranslateError("有道词典里没有这个词");
        }

        yield return entry;
    }
}
