// 一次翻译请求：From 为 null 表示交给服务自动识别。
// 流里的约定：每次给出到目前为止的整段译文；空串 = 模型在思考、还没有正文。
using KittyTools.Core;

namespace KittyTools;

internal sealed record TranslateRequest(string Text, Lang? From, Lang To);

internal readonly record struct StreamDelta(string? Text, bool IsThinking = false, bool IsTruncated = false);
