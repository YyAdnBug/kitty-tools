// 复制即译要不要翻（纯函数，配单测）：网址、单行路径、纯数字 / 符号、超长的、和上次原文相同的，都静默跳过。
// 第一语言的文字照翻（翻成第二语言；2026-10-29 用户反馈：复制中文不弹浮窗，以前目标「自动」时第一语言一律跳过）。
namespace KittyTools.Core;

public static class CopyTranslateRules
{
    public const int MaxSourceBytes = 32 * 1024;

    public static bool WorthTranslating(string text, string? translated, Lang first, Lang second)
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

        return Langs.Detect(trimmed, new[] { first, second }) is not null;
    }
}
