// 智谱 GLM 翻译（内置免费服务，可填自己的 key），SSE 流式。
// 接口硬约束：max_tokens 合法范围 [1, 1024]；混合推理模型默认开思考，必须显式关闭，
// 否则 content 可能为空；目标语言必须是具体语言（提示词里不能出现「自动」）。提示词用中文。
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class ZhipuProvider
{
    public static readonly Uri Endpoint =
        new("https://open.bigmodel.cn/api/paas/v4/chat/completions");

    public const int MaxTokens = 1024;

    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var key = TranslateServiceStore.Instance?.Secret(service) ?? TranslateServiceStore.BuiltinZhipuKey;
        if (string.IsNullOrWhiteSpace(key))
        {
            throw TranslateError.Config("没有可用的智谱 API Key");
        }

        var model = TranslatePresets.ZhipuModel(service.Model);
        var from = request.From is { } source ? source.Title() : string.Empty;
        var target = request.To.Title();
        var prompt =
            $"请把下面的{from}文本翻译成{target}。只输出译文，不要解释，不要加引号，保留原文的换行和段落。\n\n" +
            request.Text;

        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = MaxTokens,
            ["stream"] = true,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "user", ["content"] = prompt }),
        };
        var headers = new Dictionary<string, string> { ["Authorization"] = $"Bearer {key}" };
        var tiers = AiEndpoint.Tiers(Endpoint, AiProtocol.OpenAi, model);
        await foreach (var piece in AiStreamRunner.RunAsync(
                           Endpoint, headers, body, tiers, model, AiStreamRunner.OpenAiDelta, cancellationToken))
        {
            yield return piece;
        }
    }
}
