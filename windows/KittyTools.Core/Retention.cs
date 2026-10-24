// 剪贴板保留策略（纯函数）：按保留天数、普通图片总占用决定这一轮删哪些条目。
// 收藏的不受两条影响；图片额度只算普通图片，从最旧的删起，最新的一张普通图片这一轮不删。
namespace KittyTools.Core;

public enum ClipKind
{
    Text,
    Image,
    Files,
}

/// <summary>清理计划需要知道的字段；调用方按复制时间新→旧传入。</summary>
public readonly record struct RetentionItem(
    string Id,
    ClipKind Kind,
    long CopiedAtMs,
    int ImageBytes,
    bool Favorite);

/// <summary>保留天数 0 = 永久；图片上限 0 = 不限。</summary>
public readonly record struct RetentionLimits(int MaxAgeDays, long ImageBudgetBytes)
{
    public long? MaxAgeMs => MaxAgeDays > 0 ? MaxAgeDays * 86_400_000L : null;
}

public static class Retention
{
    /// <summary>
    /// 返回这一轮要删的条目 id。items 必须按复制时间新→旧；同一毫秒按 id 无所谓，调用方排序时会带上 rowid。
    /// hoursOfDay 不做处理：保留天数按整 24 小时算。
    /// </summary>
    public static HashSet<string> Plan(
        IReadOnlyList<RetentionItem> items,
        RetentionLimits limits,
        long nowMs)
    {
        var doomed = new HashSet<string>(StringComparer.Ordinal);
        var ordinary = new List<RetentionItem>(items.Count);
        foreach (var item in items)
        {
            if (!item.Favorite)
            {
                ordinary.Add(item);
                if (limits.MaxAgeMs is { } maxAge && nowMs - item.CopiedAtMs > maxAge)
                {
                    doomed.Add(item.Id);
                }
            }
        }

        if (limits.ImageBudgetBytes <= 0)
        {
            return doomed;
        }

        // 还没被天数删掉的普通图片，新→旧。
        var images = new List<RetentionItem>();
        long total = 0;
        foreach (var item in ordinary)
        {
            if (item.Kind == ClipKind.Image && !doomed.Contains(item.Id))
            {
                images.Add(item);
                total += item.ImageBytes;
            }
        }

        // 最新的一张普通图片这一轮不删：从第二新的开始，按最旧的先删，直到额度够。
        for (var index = images.Count - 1; index >= 1 && total > limits.ImageBudgetBytes; index--)
        {
            var item = images[index];
            doomed.Add(item.Id);
            total -= item.ImageBytes;
        }

        return doomed;
    }
}
