// 启动器的匹配与排序（纯函数，配单测）。查询按空白分词，每个词都要命中某个名字（AND），
// 各词取最好的一档、整体取最差的那个词：完全相同 100 > 名字开头 80 > 词首 60 >
// 首字母缩写开头 50 > 子串 40。缩写让 vsc 能搜到 Visual Studio Code；中文名另有拼音全拼和首字母。
// 最终分 = 匹配分 ×（1 + 0.5·g/(g+3) + q/(q+2)），g / q 是全局 / 同查询的使用分（都饱和，最多 ×2.5）。
namespace KittyTools.Core;

public readonly record struct LauncherBoost(double Global, double Query);

public static class LauncherMatch
{
    public static string Fold(string text) => Search.Fold(text.Trim());

    /// <summary>首字母缩写：按空格 / 标点 / 驼峰分词取首字母（AppCleaner → ac，Visual Studio Code → vsc）。</summary>
    public static string Initials(string name)
    {
        var builder = new System.Text.StringBuilder();
        char? previous = null;
        foreach (var character in name)
        {
            var word = char.IsLetterOrDigit(character);
            var starts = word &&
                         (previous is null || !char.IsLetterOrDigit(previous.Value) ||
                          (char.IsUpper(character) && char.IsLower(previous.Value)));
            if (starts)
            {
                builder.Append(character);
            }

            previous = character;
        }

        return Fold(builder.ToString());
    }

    /// <summary>0 表示不匹配。item.Names / Initials 必须已经 Fold 过。</summary>
    public static double Score(string query, LauncherItem item)
    {
        var whole = Fold(query);
        if (whole.Length == 0)
        {
            return 0;
        }

        var tokens = whole.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var perToken = tokens.Length == 0 ? 0 : tokens.Min(token => Tier(token, item));
        return tokens.Length > 1 ? Math.Max(Tier(whole, item), perToken) : perToken;
    }

    /// <summary>
    /// 关键词提示行（汇率，以后 open / find / quit… / kill / port / fy 也照这个）对上了没有（mac LauncherMatch.promptMatch）：
    /// 整个是关键词 = Exact（排在最前面）；关键词、中文叫法或它的全拼的开头 = Partial（排在本地结果后面、兜底搜索前面）。
    /// 英文至少 2 个字母，有汉字时 1 个字就算（IsLongEnough）。keywords / aliases 都写小写、不带空格。
    /// </summary>
    public static PromptMatchKind PromptMatch(string query, IReadOnlyList<string> keywords, IReadOnlyList<string>? aliases = null)
    {
        var text = new string(Fold(query).Where(character => !char.IsWhiteSpace(character)).ToArray());
        if (text.Length == 0)
        {
            return PromptMatchKind.None;
        }

        if (keywords.Contains(text))
        {
            return PromptMatchKind.Exact;
        }

        return IsLongEnough(text) && keywords.Concat(aliases ?? Array.Empty<string>())
            .Any(keyword => keyword.StartsWith(text, StringComparison.Ordinal))
            ? PromptMatchKind.Partial
            : PromptMatchKind.None;
    }

    /// <summary>
    /// 书签、浏览历史、兜底搜索够不够长：至少 2 个字（1 个字母命中太多）；含中文（非 ASCII）时 1 个字就够
    /// （第四轮体检 U8，同 mac LauncherMatch.isLongEnough）。
    /// </summary>
    public static bool IsLongEnough(string query)
    {
        var text = query.Trim();
        return text.Length >= 2 || text.Any(ch => ch > 0x7F);
    }

    /// <summary>
    /// 本地结果里在完全相同的输入下选过的（chosen：使用记录里这个查询的分 > 0）排到固定行（剪贴板、翻译、ip、直达、计算、
    /// 关键词提示）前面，彼此顺序不变；其余本地结果照旧跟在固定行后面（第四轮体检 E8，同 mac promoting：
    /// 输 gh 选过 GitHub Desktop 的，下次 gh 第一行不再是「用 GitHub 搜索…」）。
    /// </summary>
    public static List<LauncherItem> Promoting(
        IReadOnlyList<LauncherItem> local, IReadOnlyList<LauncherItem> top, Func<LauncherItem, bool> chosen)
    {
        var picked = local.Where(chosen).ToList();
        return picked.Concat(top).Concat(local.Where(item => !chosen(item))).ToList();
    }

    /// <summary>把查询折叠后按空白切成词（MayMatch 用，一次按键切一次）。</summary>
    public static string[] Tokens(string query)
        => Fold(query).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>
    /// 粗筛（mac mayMatch）：每个词都是某个名字的子串、或某个缩写的开头——这是 Score 不为 0 的必要条件。
    /// 书签、浏览历史几千条，先用它滤一遍再完整打分。
    /// </summary>
    public static bool MayMatch(string[] tokens, LauncherItem item)
    {
        foreach (var token in tokens)
        {
            var hit = false;
            foreach (var name in item.Names)
            {
                if (name.Contains(token, StringComparison.Ordinal))
                {
                    hit = true;
                    break;
                }
            }

            if (!hit && !(token.Length >= 2 && item.Initials.Any(initials => initials.StartsWith(token, StringComparison.Ordinal))))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>匹配、加使用加成、排序；同分先按 Priority，再标题短的在前，再按原顺序。</summary>
    public static List<LauncherItem> Rank(
        IReadOnlyList<LauncherItem> items,
        string query,
        Func<LauncherItem, LauncherBoost>? boost = null)
    {
        var scored = new List<(LauncherItem Item, double Score, int Index)>();
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var match = Score(query, item);
            if (match <= 0)
            {
                continue;
            }

            var usage = boost?.Invoke(item) ?? default;
            var multiplier = 1 + 0.5 * usage.Global / (usage.Global + 3) + usage.Query / (usage.Query + 2);
            scored.Add((item, match * multiplier, index));
        }

        scored.Sort((left, right) =>
        {
            var byScore = right.Score.CompareTo(left.Score);
            if (byScore != 0)
            {
                return byScore;
            }

            var byPriority = left.Item.Priority.CompareTo(right.Item.Priority);
            if (byPriority != 0)
            {
                return byPriority;
            }

            var byTitle = left.Item.Title.Length.CompareTo(right.Item.Title.Length);
            return byTitle != 0 ? byTitle : left.Index.CompareTo(right.Index);
        });
        return scored.Select(entry => entry.Item).ToList();
    }

    private static double Tier(string token, LauncherItem item)
    {
        double best = 0;
        foreach (var name in item.Names)
        {
            if (name == token)
            {
                return 100;
            }

            if (name.StartsWith(token, StringComparison.Ordinal))
            {
                best = Math.Max(best, 80);
            }
            else if (name.Split(WordSeparators, StringSplitOptions.RemoveEmptyEntries)
                         .Any(word => word.StartsWith(token, StringComparison.Ordinal)))
            {
                best = Math.Max(best, 60);
            }
            else if (name.Contains(token, StringComparison.Ordinal))
            {
                best = Math.Max(best, 40);
            }
        }

        if (best < 50 && token.Length >= 2 &&
            item.Initials.Any(initials => initials.StartsWith(token, StringComparison.Ordinal)))
        {
            best = 50;
        }

        return best;
    }

    private static readonly char[] WordSeparators =
        Enumerable.Range(0, 128).Select(code => (char)code)
            .Where(ch => !char.IsLetterOrDigit(ch))
            .ToArray();
}

/// <summary>关键词提示行对上的程度（LauncherMatch.PromptMatch）。</summary>
public enum PromptMatchKind
{
    None,
    Exact,
    Partial,
}
