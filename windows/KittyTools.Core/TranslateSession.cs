// 一次翻译会话里的纯规则（照 mac TranslateCoordinator / TranslatePanelView 的同名静态函数，单测也照搬，PLAN-v9-translate 8a）：
// 主结果是哪张卡、替换原文时补回原选区首尾的空白、自动复制不复制、原文改过没有、浮窗多高。
// 折叠着的服务不自动翻译（PLAN-v22，同 mac 2026-11-15）：开会话时是「没翻」的卡（Idle）、不发请求，点开才翻；
// 点开后才翻的不当主结果；不开浮窗的两条路按 Ordered 先试没折叠的。
namespace KittyTools.Core;

public enum CardState
{
    Waiting,
    Running,
    Done,
    Failed,
    Truncated,

    /// <summary>没翻：服务折叠着，这次会话不自动翻译，点开才翻（PLAN-v22）。放最后，不改别的值。</summary>
    Idle,
}

public static class TranslateSession
{
    /// <summary>
    /// 主结果（写历史、自动复制、收藏、替换原文都认它）：按列表顺序第一个翻成功、结果不为空的卡。
    /// 排在它前面的都得已经没成（出错、截断、中断）才轮到它——前面的还在跑就先等（-1），免得先认了第二个、第一个出来又换。
    /// </summary>
    public static int Primary(IReadOnlyList<(CardState State, string Text)> cards)
        => Primary(cards.Select(card => (card.State, card.Text, false)).ToList());

    /// <summary>
    /// skip：词典类服务（有道词典）给的是释义、不是译文，不当主结果，也不挡后面的（PLAN-v14 V4，mac Kind.isDictionary）；
    /// 点开后才翻的折叠卡也跳过（点开一张卡不该换掉剪贴板、再写一条历史，PLAN-v22 D5）。没翻的卡（Idle）不挡着等。
    /// </summary>
    public static int Primary(IReadOnlyList<(CardState State, string Text, bool Skip)> cards)
    {
        for (var index = 0; index < cards.Count; index++)
        {
            if (cards[index].Skip)
            {
                continue;
            }

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

    /// <summary>开会话时一张卡的状态：折叠着的是「没翻」、不发请求（PLAN-v22 D1）。</summary>
    public static CardState StartState(bool collapsed) => collapsed ? CardState.Idle : CardState.Waiting;

    /// <summary>点开一张卡跑不跑：只有没翻的才跑（D2：翻过 / 在翻的再点开不重复请求）。</summary>
    public static bool ExpandRuns(CardState state) => state == CardState.Idle;

    /// <summary>
    /// 再打开输入翻译（ResumeInput）时一张卡怎么办（D4）：上次收起时被中断的，折叠着的回到没翻（Idle、不跑），
    /// 没折叠的重跑（Waiting）；别的不动（null）。
    /// </summary>
    public static CardState? ResumeState(CardState state, bool interrupted, bool collapsed)
        => state == CardState.Failed && interrupted ? StartState(collapsed) : null;

    /// <summary>
    /// 不开浮窗的两条路（静默替换、截图翻译盖回）按这个顺序试服务：没折叠的在前、折叠的垫底，各自保持列表顺序（D6，mac ordered）。
    /// </summary>
    public static List<T> Ordered<T>(IEnumerable<T> services, Func<T, string> id, IReadOnlyCollection<string> collapsed)
    {
        var list = services.ToList();
        return list.Where(service => !collapsed.Contains(id(service)))
            .Concat(list.Where(service => collapsed.Contains(id(service))))
            .ToList();
    }

    /// <summary>
    /// 不花钱、不用自己申请 key 就能用的种类（PLAN-v22 F1，mac Kind.isFree）：智谱内置的免费模型、微软（没填 Key 时走 Edge 接口）、
    /// 有道词典。mac 的系统翻译也算，但 Windows 上用不了（不开卡），不标。
    /// </summary>
    public static bool IsFreeKind(string kind) => kind is "zhipu" or "microsoft" or "youdaoDict";

    /// <summary>设置里服务行标不标「免费」（F3）：免费的种类，微软填了自己的 Key（走 Azure）就不算。</summary>
    public static bool ShowsFree(string kind, bool hasOwnKey) => IsFreeKind(kind) && !(kind == "microsoft" && hasOwnKey);

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

    /// <summary>浮窗最矮多高（也是拖下边的下限）。</summary>
    public const double MinHeight = 220;

    /// <summary>浮窗默认宽度（「恢复默认大小」回到它）。</summary>
    public const double DefaultWidth = 420;

    /// <summary>
    /// 浮窗的高（mac TranslatePanelView.panelHeight）：随内容、最矮 220；平时最高到可见区的 85%，
    /// 但 mustFit（结果卡多于三张时到第三张的下沿）要放得下，这时最高到可见区减 24。
    /// cap：拖下边定的最高多高（PLAN-v14 V10，null / 0 = 自动）；拖过的就照它（前三张卡也不例外，卡片区里滚），内容少时照样变矮。
    /// </summary>
    public static double PanelHeight(double height, double mustFit, double visible, double? cap = null)
    {
        var limit = cap is > 0
            ? Math.Min(Math.Max(cap.Value, MinHeight), visible - 24)
            : Math.Min(Math.Max(visible * 0.85, mustFit), visible - 24);
        return Math.Min(Math.Max(height, MinHeight), limit);
    }
}
