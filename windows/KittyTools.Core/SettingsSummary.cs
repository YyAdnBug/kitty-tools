// 设置里收成一行、点进去编辑的那几项的小字（PLAN-v18 L4，mac FeaturesPage.summary 8bbc2f8d）：纯函数，配单测。
// 网页搜索那一行在 WebSearch.Summary。
// PLAN-v28 X1：推进行行尾的状态（次要字色写在 › 左边，中文不超过 10 个字；Problem 是橙字），子页页头那一句用同一个函数。
namespace KittyTools.Core;

public static class SettingsSummary
{
    /// <summary>通用页「功能」那一行：关着的少列关着的，开着的少列开着的。features：按显示顺序的（名字，开没开）。</summary>
    public static string Features(IReadOnlyList<(string Title, bool On)> features)
    {
        var opened = features.Where(feature => feature.On).Select(feature => feature.Title).ToList();
        var closed = features.Where(feature => !feature.On).Select(feature => feature.Title).ToList();
        if (closed.Count == 0)
        {
            return $"{features.Count} 个功能都开着";
        }

        if (opened.Count == 0)
        {
            return $"{features.Count} 个功能都关着";
        }

        return closed.Count <= opened.Count
            ? $"开着 {opened.Count} 个；关着：" + string.Join("、", closed)
            : "开着：" + string.Join("、", opened) + $"；另外 {closed.Count} 个关着";
    }

    /// <summary>推进行行尾：文字和是不是问题（橙字）。</summary>
    public readonly record struct RowValue(string Text, bool Problem = false);

    /// <summary>
    /// 通用 › 同步：没开「关」/ 正在同步「正在同步…」/ 好了「x 分钟前」/ 停了橙「停了」/ 等确认橙「等你确认」（同 mac SyncSection 的口径）。
    /// state 是 Syncer 的状态（idle / syncing / busy / stopped / confirm），lastSync 是 Unix 毫秒（0 = 还没同步过）。
    /// </summary>
    public static RowValue Sync(bool enabled, string? state, long lastSync, DateTimeOffset now)
    {
        if (!enabled)
        {
            return new RowValue("关");
        }

        return state switch
        {
            "stopped" => new RowValue("停了", true),
            "confirm" => new RowValue("等你确认", true),
            "syncing" => new RowValue("正在同步…"),
            _ when lastSync <= 0 => new RowValue("还没同步过"),
            _ => new RowValue(Ago(DateTimeOffset.FromUnixTimeMilliseconds(lastSync), now)),
        };
    }

    /// <summary>「刚刚」「12 分钟前」「3 小时前」「昨天」「11月3日」。</summary>
    public static string Ago(DateTimeOffset at, DateTimeOffset now)
    {
        var local = at.ToOffset(now.Offset);
        var minutes = (now - local).TotalMinutes;
        if (minutes < 1)
        {
            return "刚刚";
        }

        if (minutes < 60)
        {
            return $"{(int)minutes} 分钟前";
        }

        if (local.Date == now.Date)
        {
            return $"{(int)(minutes / 60)} 小时前";
        }

        return local.Date == now.Date.AddDays(-1) ? "昨天" : $"{local.Month}月{local.Day}日";
    }

    /// <summary>
    /// 通用 › 备份与导出导入：自动备份开着写最近一份的时刻（今天 09:12 / 昨天 / 11月3日），没备成橙「没备成」；关着「自动备份关着」。
    /// latest：最近一份每日备份的时刻（没有是 null）；failed：另存的那份没写成（ArchiveService.CopyProblem）。
    /// </summary>
    public static RowValue Backup(bool daily, DateTime? latest, bool failed, DateTime now)
    {
        if (!daily)
        {
            return new RowValue("自动备份关着");
        }

        if (failed)
        {
            return new RowValue("没备成", true);
        }

        if (latest is not { } at)
        {
            return new RowValue("还没有备份");
        }

        return at.Date == now.Date ? new RowValue($"今天 {at:HH:mm}")
            : at.Date == now.Date.AddDays(-1) ? new RowValue("昨天")
            : new RowValue($"{at.Month}月{at.Day}日");
    }

    /// <summary>截图 › 截图历史：开「30 天 · 2 GB」（0 写「一直留着」「不限」）/ 关「关」。</summary>
    public static RowValue ShotHistory(bool on, int days, int megabytes)
    {
        if (!on)
        {
            return new RowValue("关");
        }

        var keep = days <= 0 ? "一直留着" : $"{days} 天";
        var size = megabytes <= 0 ? "不限" : megabytes % 1024 == 0 ? $"{megabytes / 1024} GB" : $"{megabytes} MB";
        return new RowValue($"{keep} · {size}");
    }

    /// <summary>翻译 › 翻译历史：开「最多 5000 条」/「不限」/ 关「关」。</summary>
    public static RowValue TranslateHistory(bool on, int limit)
        => !on ? new RowValue("关") : limit <= 0 ? new RowValue("不限") : new RowValue($"最多 {limit} 条");

    /// <summary>翻译 › 查词与朗读：发音那一项的短名，大模型按词典回答开着时前面加「词典 · 」。</summary>
    public static RowValue Lookup(bool wordMode, int voice)
    {
        var name = WordVoiceChoice.Short[Math.Clamp(voice, 0, WordVoiceChoice.Short.Length - 1)];
        return new RowValue(wordMode ? "词典 · " + name : name);
    }

    /// <summary>启动器 › 脚本命令：开「n 个脚本」，有读不成的橙「n 个有问题」；关「关」。</summary>
    public static RowValue Scripts(bool enabled, int count, int broken)
        => !enabled ? new RowValue("关")
            : broken > 0 ? new RowValue($"{broken} 个有问题", true)
            : new RowValue(count == 0 ? "还没有脚本" : $"{count} 个脚本");

    /// <summary>便签 › 屏幕边缘：「开着 · 右边」/「开着 · 左边」/「关」。</summary>
    public static RowValue Deck(bool enabled, string? edge)
        => !enabled ? new RowValue("关") : new RowValue(edge == "left" ? "开着 · 左边" : "开着 · 右边");

    /// <summary>启动器 › 应用：「n 个别名」（没有时不写）。</summary>
    public static RowValue Apps(int aliases) => new(aliases > 0 ? $"{aliases} 个别名" : string.Empty);
}
