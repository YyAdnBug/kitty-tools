// 多选粘贴的规则（第三版 §5，纯函数 + 单测）：
// 全是文本 → 合并粘贴（换行连成一条，并记一条新历史）；全是文件 → 一起粘贴；其余 → 依次粘贴（每条间隔 250 ms）。
// 还有「靠识字命中」时行标题显示哪一段（OcrHit）。
using System.Text;

namespace KittyTools.Core;

public enum MultiPasteMode
{
    MergeText,
    FilesTogether,
    Sequential,
}

public static class MultiPaste
{
    public const int SequentialDelayMs = 250;

    public static MultiPasteMode Mode(int count, bool allText, bool allFiles)
    {
        if (count <= 1)
        {
            return MultiPasteMode.Sequential;
        }

        if (allText)
        {
            return MultiPasteMode.MergeText;
        }

        return allFiles ? MultiPasteMode.FilesTogether : MultiPasteMode.Sequential;
    }

    /// <summary>合并粘贴：按复制先后（调用方给旧→新）用换行连起来。</summary>
    public static string Merge(IEnumerable<string> texts)
        => string.Join('\n', texts.Where(text => !string.IsNullOrEmpty(text)));

    public static string Verb(MultiPasteMode mode, int count) => mode switch
    {
        MultiPasteMode.MergeText => $"合并粘贴 {count} 条",
        MultiPasteMode.FilesTogether => $"一起粘贴 {count} 个文件",
        _ => $"依次粘贴 {count} 条",
    };

    public static string Footer(int count, MultiPasteMode mode)
        => count <= 1 ? string.Empty : $"已选 {count} 条 · {Verb(mode, count)} · Esc 取消选择";
}

/// <summary>图片的识字结果（后台排队写进 ocr_text）与「靠它命中时显示哪一段」。</summary>
public static class OcrHit
{
    public const int SnippetLength = 80;

    /// <summary>在识字文本里找第一个命中的词，返回前后的那一小段（最多 80 字）。</summary>
    public static string? Snippet(string? ocrText, IReadOnlyList<string> tokens)
    {
        if (string.IsNullOrWhiteSpace(ocrText) || tokens.Count == 0)
        {
            return null;
        }

        foreach (var token in tokens)
        {
            var index = ocrText.IndexOf(token, StringComparison.OrdinalIgnoreCase);
            if (index < 0)
            {
                continue;
            }

            var start = Math.Max(0, index - SnippetLength / 2);
            var length = Math.Min(SnippetLength, ocrText.Length - start);
            var snippet = ocrText.Substring(start, length).Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (start > 0)
            {
                snippet = "…" + snippet;
            }

            if (start + length < ocrText.Length)
            {
                snippet += "…";
            }

            return snippet;
        }

        return null;
    }

    /// <summary>OCR 文本归一：换行合成空格、压缩空白（搜索用）。</summary>
    public static string Clean(string text)
    {
        var builder = new StringBuilder(text.Length);
        var space = false;
        foreach (var ch in text)
        {
            if (char.IsWhiteSpace(ch))
            {
                space = true;
                continue;
            }

            if (space && builder.Length > 0)
            {
                builder.Append(' ');
            }

            space = false;
            builder.Append(ch);
        }

        return builder.ToString();
    }
}
