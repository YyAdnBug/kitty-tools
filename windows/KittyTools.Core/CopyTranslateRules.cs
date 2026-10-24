// 复制即译要不要翻（纯函数，配单测）：网址、单行路径、纯数字 / 符号、超长的、
// 和上次原文相同的、目标「自动」而原文本来就是第一语言的，都静默跳过。
namespace KittyTools.Core;

public static class CopyTranslateRules
{
    public const int MaxSourceBytes = 32 * 1024;

    public static bool WorthTranslating(
        string text,
        string? translated,
        Lang first,
        Lang second,
        bool autoTarget)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed == translated ||
            System.Text.Encoding.UTF8.GetByteCount(trimmed) > MaxSourceBytes)
        {
            return false;
        }

        if (Langs.IsUrlLike(trimmed) || Langs.IsPathLike(trimmed))
        {
            return false;
        }

        var detected = Langs.Detect(trimmed, new[] { first, second });
        if (detected is null)
        {
            return false;
        }

        return !(autoTarget && detected.Value.SameLanguage(first));
    }
}
