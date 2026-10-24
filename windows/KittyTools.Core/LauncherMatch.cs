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
