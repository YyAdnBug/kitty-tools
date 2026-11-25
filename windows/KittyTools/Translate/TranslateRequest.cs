// 一次翻译请求：From 为 null 表示交给服务自动识别。IsWord：原文是单个词、且开着单词模式，大模型按词典格式回答
// （会话定方案时决定，同 mac TranslateRequest.isWord；划词翻译并替换不用它）。
// 流里的约定：每次给出到目前为止的整段译文；空串 = 模型在思考、还没有正文。
using KittyTools.Core;

namespace KittyTools;

/// <summary>
/// Explains：这次讲解（PLAN-v26 T3：浮窗里、打开了讲解的大模型服务、一句外文译成第一语言），出译文 + 重点词 + 句型；
/// InPanel：在翻译浮窗里（附加要求只在浮窗里接上；划词替换、截图盖回要干净的译文）。
/// </summary>
internal sealed record TranslateRequest(string Text, Lang? From, Lang To, bool IsWord = false, bool Explains = false, bool InPanel = false);

internal readonly record struct StreamDelta(string? Text, bool IsThinking = false, bool IsTruncated = false);
