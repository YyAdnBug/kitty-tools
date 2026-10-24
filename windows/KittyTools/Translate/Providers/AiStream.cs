// 大模型流式请求的公共部分：按「关闭思考」分档发请求，只有 400 / 422 才降一档；
// 成功的档位按「地址 + 模型」记在内存里，下次直接从它开始。
// 输出到上限（finish_reason = length / stop_reason = max_tokens）时先给半截、再抛 Truncated。
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;

namespace KittyTools;

internal static class AiStreamRunner
{
    private static readonly Dictionary<string, int> WorkingTier = new();
    private static readonly object Gate = new();

    public static async IAsyncEnumerable<string> RunAsync(
        Uri url,
        IReadOnlyDictionary<string, string> headers,
        JsonObject body,
        IReadOnlyList<IReadOnlyDictionary<string, object?>> tiers,
        string model,
        Func<JsonElement, StreamDelta> delta,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var cacheKey = url + "\n" + model;
        int tier;
        lock (Gate)
        {
            tier = WorkingTier.GetValueOrDefault(cacheKey);
        }

        while (true)
        {
            var request = (JsonObject)body.DeepClone();
            TranslateHttp.Apply(request, tiers[tier]);
            var text = new StreamingText();
            var truncated = false;
            var changed = false;
            string? shown = null;
            var failedTier = false;

            var events = TranslateHttp.StreamAsync(url, headers, request, cancellationToken)
                .GetAsyncEnumerator(cancellationToken);
            try
            {
                while (true)
                {
                    bool moved;
                    try
                    {
                        moved = await events.MoveNextAsync();
                    }
                    catch (TranslateError error) when (error.Status is 400 or 422 && tier < tiers.Count - 1)
                    {
                        failedTier = true;
                        break;
                    }

                    if (!moved)
                    {
                        break;
                    }

                    JsonDocument document;
                    try
                    {
                        document = JsonDocument.Parse(events.Current);
                    }
                    catch (JsonException)
                    {
                        continue;
                    }

                    using (document)
                    {
                        var root = document.RootElement;
                        var serverMessage = TranslateHttp.ServerMessage(root);
                        if (serverMessage is not null)
                        {
                            throw new TranslateError(serverMessage);
                        }

                        var piece = delta(root);
                        if (piece.Text is { } content)
                        {
                            text.Append(content);
                        }

                        truncated |= piece.IsTruncated;
                        var visible = text.Visible;
                        if ((visible.Length > 0 || piece.IsThinking || text.IsThinking) && visible != shown)
                        {
                            shown = visible;
                            changed = true;
                            yield return visible;
                        }
                    }
                }
            }
            finally
            {
                await events.DisposeAsync();
            }

            if (failedTier)
            {
                tier++;
                continue;
            }

            lock (Gate)
            {
                WorkingTier[cacheKey] = tier;
            }

            var final = text.Final;
            if (final.Length == 0)
            {
                throw TranslateError.EmptyResult;
            }

            if (!changed || shown != final)
            {
                yield return final;
            }

            if (truncated)
            {
                throw TranslateError.Truncated;
            }

            yield break;
        }
    }

    public static StreamDelta OpenAiDelta(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array ||
            choices.GetArrayLength() == 0)
        {
            return default;
        }

        var choice = choices[0];
        var thinking = false;
        string? text = null;
        if (choice.TryGetProperty("delta", out var delta) && delta.ValueKind == JsonValueKind.Object)
        {
            if (delta.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.String)
            {
                text = content.GetString();
            }

            foreach (var name in new[] { "reasoning_content", "reasoning" })
            {
                if (delta.TryGetProperty(name, out var reasoning) && reasoning.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrEmpty(reasoning.GetString()))
                {
                    thinking = true;
                }
            }
        }

        var truncated = choice.TryGetProperty("finish_reason", out var finish) &&
                        finish.ValueKind == JsonValueKind.String && finish.GetString() == "length";
        return new StreamDelta(text, thinking, truncated);
    }

    public static StreamDelta AnthropicDelta(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String)
        {
            return default;
        }

        switch (type.GetString())
        {
            case "content_block_delta":
                if (root.TryGetProperty("delta", out var delta) && delta.ValueKind == JsonValueKind.Object &&
                    delta.TryGetProperty("type", out var deltaType) && deltaType.ValueKind == JsonValueKind.String)
                {
                    return deltaType.GetString() switch
                    {
                        "text_delta" => new StreamDelta(
                            delta.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String
                                ? text.GetString()
                                : null),
                        "thinking_delta" => new StreamDelta(null, true),
                        _ => default,
                    };
                }

                return default;
            case "message_delta":
                var truncated = root.TryGetProperty("delta", out var messageDelta) &&
                                messageDelta.ValueKind == JsonValueKind.Object &&
                                messageDelta.TryGetProperty("stop_reason", out var stop) &&
                                stop.ValueKind == JsonValueKind.String && stop.GetString() == "max_tokens";
                return new StreamDelta(null, false, truncated);
            default:
                return default;
        }
    }
}
