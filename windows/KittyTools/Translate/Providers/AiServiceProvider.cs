// 大模型翻译（用户自建 AI 实例：OpenAI 兼容 / Azure OpenAI / Anthropic），SSE 流式输出。
// 地址补全、max_tokens、关思考分档都是 Core 的纯函数（AiEndpoint）。
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AiServiceProvider
{
    public static async IAsyncEnumerable<string> StreamAsync(
        TranslateServiceConfig service,
        TranslateRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var protocol = Protocol(service.Protocol);
        var model = service.Model?.Trim() ?? string.Empty;
        var key = TranslateServiceStore.Instance?.Secret(service) ?? string.Empty;
        var url = AiEndpoint.Resolve(service.BaseUrl, protocol);
        if (url is null || model.Length == 0)
        {
            throw TranslateError.Config("请先在设置里填写服务地址和模型");
        }

        var target = request.To.EnglishName();
        var from = request.From is { } source ? $" from {source.EnglishName()}" : string.Empty;
        var system =
            "You are a translation engine. Translate the user's text" + from + " into " + target + ". " +
            "Output only the translation: no explanations, no quotes. Keep line breaks and Markdown structure.";

        switch (protocol)
        {
            case AiProtocol.Anthropic:
            {
                var body = new JsonObject
                {
                    ["model"] = model,
                    ["system"] = system,
                    ["max_tokens"] = 4096,
                    ["stream"] = true,
                    ["messages"] = new JsonArray(
                        new JsonObject { ["role"] = "user", ["content"] = request.Text }),
                };
                var headers = new Dictionary<string, string>
                {
                    ["x-api-key"] = key,
                    ["anthropic-version"] = "2023-06-01",
                };
                await foreach (var piece in AiStreamRunner.RunAsync(
                                   url, headers, body, AiEndpoint.Tiers(url, protocol, model), model,
                                   AiStreamRunner.AnthropicDelta, cancellationToken))
                {
                    yield return piece;
                }

                yield break;
            }
            case AiProtocol.Azure:
            case AiProtocol.OpenAi:
            default:
            {
                var body = new JsonObject
                {
                    ["model"] = model,
                    ["stream"] = true,
                    ["messages"] = new JsonArray(
                        new JsonObject { ["role"] = "system", ["content"] = system },
                        new JsonObject { ["role"] = "user", ["content"] = request.Text }),
                };
                if (AiEndpoint.MaxTokens(url, protocol) is { } maxTokens)
                {
                    body["max_tokens"] = maxTokens;
                }

                var headers = new Dictionary<string, string>();
                if (protocol == AiProtocol.Azure)
                {
                    headers["api-key"] = key;
                }
                else if (key.Length > 0)
                {
                    headers["Authorization"] = $"Bearer {key}";
                }

                await foreach (var piece in AiStreamRunner.RunAsync(
                                   url, headers, body, AiEndpoint.Tiers(url, protocol, model), model,
                                   AiStreamRunner.OpenAiDelta, cancellationToken))
                {
                    yield return piece;
                }

                yield break;
            }
        }
    }

    public static AiProtocol Protocol(string? value) => value?.ToLowerInvariant() switch
    {
        "azure" => AiProtocol.Azure,
        "anthropic" => AiProtocol.Anthropic,
        _ => AiProtocol.OpenAi,
    };
}
