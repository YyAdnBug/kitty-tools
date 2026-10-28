// 一次翻译会话里的纯规则（照 mac TranslateCoordinator / TranslatePanelView 的同名静态函数，单测也照搬，PLAN-v9-translate 8a）：
// 主结果是哪张卡、替换原文时补回原选区首尾的空白、自动复制不复制、原文改过没有、浮窗多高。
namespace KittyTools.Core;

public enum CardState
{
    Waiting,
    Running,
    Done,
    Failed,
    Truncated,
}

public static class TranslateSession
{
    /// <summary>
    /// 主结果（写历史、自动复制、收藏、替换原文都认它）：按列表顺序第一个翻成功、结果不为空的卡。
    /// 排在它前面的都得已经没成（出错、截断、中断）才轮到它——前面的还在跑就先等（-1），免得先认了第二个、第一个出来又换。
    /// </summary>
    public static int Primary(IReadOnlyList<(CardState State, string Text)> cards)
    {
        for (var index = 0; index < cards.Count; index++)
        {
            switch (cards[index].State)
            {
                case CardState.Done when cards[index].Text.Length > 0:
                    return index;
                case CardState.Waiting or CardState.Running:
                    return -1;
            }
        }

        return -1;
    }

    /// <summary>替换原文用：译文去掉首尾空白，套上原选区的首尾空白（三击选中的整行带着换行，替换后段落不能被接起来）。</summary>
    public static string Rewrap(string translation, string original)
    {
        var leading = original.Length - original.TrimStart().Length;
        if (leading == original.Length)
        {
            return translation;
        }

        var trailing = original.Length - original.TrimEnd().Length;
        return original[..leading] + translation.Trim() + original[^trailing..];
    }

    /// <summary>这次的结果自动复制吗：设置开着、不是查词（释义不该换掉剪贴板）、原文不是复制即译带来又没改过的。</summary>
    public static bool AutoCopies(bool enabled, bool isWord, string? copied, string? translated)
        => enabled && !isWord && (copied is null || copied != translated);

    /// <summary>原文改过、还没重新翻译（原文框右下角出「翻译 ↩」）：非空、且和最近一次翻译的原文（去首尾空白）不同。</summary>
    public static bool IsEdited(string source, string? translated)
    {
        var text = source.Trim();
        return text.Length > 0 && text != translated;
    }

    /// <summary>轻提示里的摘录（mac Island.excerpt）：去首尾空白后的第一行，最多 24 个字，截了加「…」。</summary>
    public static string Excerpt(string text)
    {
        var trimmed = text.Trim();
        var line = trimmed.Split('\n', '\r')[0];
        var head = line.Length > 24 ? line[..24] : line;
        return head.Length < trimmed.Length ? head + "…" : head;
    }

    /// <summary>
    /// 浮窗的高（mac TranslatePanelView.panelHeight）：随内容、最矮 220；平时最高到可见区的 85%，
    /// 但 mustFit（结果卡多于三张时到第三张的下沿）要放得下，这时最高到可见区减 24。
    /// </summary>
    public static double PanelHeight(double height, double mustFit, double visible)
        => Math.Min(Math.Max(height, 220), Math.Min(Math.Max(visible * 0.85, mustFit), visible - 24));
}
