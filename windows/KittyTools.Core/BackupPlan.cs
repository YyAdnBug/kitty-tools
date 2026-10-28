// 每日备份和恢复的纯规则（第三版 §2.1，配单测）：文件名、要不要备、留哪几份、备份里删掉哪些行、
// 打不开时问什么。和 mac 的 Storage/Backup.swift 一一对应，只把 UI 和 sqlite 留给调用方。
namespace KittyTools.Core;

public static class BackupPlan
{
    /// <summary>留最近几份。</summary>
    public const int Keep = 3;

    public const string DatabaseName = "kitty.sqlite3";

    public const string FolderName = "backups";

    /// <summary>备份的文件名：kitty-2026-10-02.sqlite3（当地日期）。</summary>
    public static string Name(DateTime day) => $"kitty-{day:yyyy-MM-dd}.sqlite3";

    /// <summary>从文件名读回是哪一天；不是备份的名字给 null。</summary>
    public static DateTime? DayOf(string name)
    {
        if (name.Length != "kitty-yyyy-MM-dd.sqlite3".Length ||
            !name.StartsWith("kitty-", StringComparison.Ordinal) ||
            !name.EndsWith(".sqlite3", StringComparison.Ordinal))
        {
            return null;
        }

        var span = name.AsSpan(6, 10);
        return DateTime.TryParseExact(
            span, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.None, out var day)
            ? day.Date
            : null;
    }

    /// <summary>今天还没备过。</summary>
    public static bool IsDue(string folder, DateTime now)
        => !File.Exists(Path.Combine(folder, Name(now)));

    /// <summary>
    /// 轮换：连刚写的那份一共留 Keep 份。刚写的那份不删；多余的先删日期比「现在」还晚的（时钟调到未来写下的），
    /// 再删最旧的（同 mac 的 Backup.expired）。
    /// </summary>
    public static List<string> Expired(
        IReadOnlyList<(string Path, DateTime Day)> copies, string written, DateTime now)
    {
        var others = copies
            .Where(copy => !string.Equals(copy.Path, written, StringComparison.OrdinalIgnoreCase))
            .OrderBy(copy => copy.Day)
            .ToList();
        var ahead = others.Where(copy => copy.Day > now.Date).ToList();
        var behind = others.Where(copy => copy.Day <= now.Date).ToList();
        var ordered = ahead.Concat(behind).ToList();
        var remove = Math.Max(others.Count - Math.Max(Keep - 1, 0), 0);
        return ordered.Take(remove).Select(copy => copy.Path).ToList();
    }

    /// <summary>「10 月 1 日（昨天）」「9 月 28 日（4 天前）」「今天」。</summary>
    public static string Describe(DateTime day, DateTime now)
    {
        var date = $"{day.Month} 月 {day.Day} 日";
        var days = (now.Date - day.Date).Days;
        return days switch
        {
            <= 0 => date + "（今天）",
            1 => date + "（昨天）",
            _ => date + $"（{days} 天前）",
        };
    }

    /// <summary>挪开的文件放在数据目录里的这个文件夹：damaged-20261002-213045（重名时由调用方加序号）。</summary>
    public static string AsideFolderName(DateTime now) => $"damaged-{now:yyyyMMdd-HHmmss}";

    /// <summary>
    /// 备份里不留的行（只有「用户明确留下的」才留）：普通剪贴板历史、没收藏的翻译历史、启动器使用记录。
    /// translations 表第三版第 2 批才有，没有就跳过那一条。
    /// </summary>
    /// <summary>「留下的」剪贴板条目在库里的写法（= ClipboardStore.IsRetained，改一个要连另一个一起改）。</summary>
    public const string ClipRetainedSql = "favorite = 1 OR snippet = 1 OR group_id IS NOT NULL";

    public static IReadOnlyList<string> DroppedStatements(bool hasTranslations) => hasTranslations
        ? new[]
        {
            "DELETE FROM clips WHERE NOT (" + ClipRetainedSql + ");",
            "DELETE FROM translations WHERE favorite = 0;",
            "DELETE FROM launcher_usage;",
        }
        : new[]
        {
            "DELETE FROM clips WHERE NOT (" + ClipRetainedSql + ");",
            "DELETE FROM launcher_usage;",
        };

    /// <summary>库文件不见了 / 是空的，而备份还在：当成出了问题（同 mac 的 lostDatabase）。</summary>
    public static bool LooksLost(long? size, bool hasUsableBackup) => (size is null or 0) && hasUsableBackup;

    /// <summary>恢复时的问题描述（对话框里的文字；纯函数，配单测）。</summary>
    public static (string Title, string Text, string[] Buttons) Wording(
        string reason, DateTime? backupDay, bool lost, DateTime now)
    {
        const string head = "Kitty Tools 的数据库读不出来了。";
        const string fresh = "重新开始：全部从空的开始；现在的数据库文件、图片和备份一起挪开留着。";
        var tail = "挪开的文件不会删，在数据目录里一个「damaged-日期-时间」的文件夹里。设置和钥匙串里的密钥不受影响。";
        if (backupDay is not { } day)
        {
            return (
                "数据打不开了",
                string.Join(
                    "\n\n",
                    head + "也没有可用的备份。", fresh, tail, "原因：" + reason),
                new[] { "重新开始", "退出" });
        }

        var describe = Describe(day, now);
        var restore =
            $"用备份：片段、收藏、收藏夹、生词本和启动器的收藏回到 {describe}备份时的样子；" +
            "普通剪贴板历史、翻译历史和启动器的使用记录不在备份里，会从空的开始。" +
            (lost ? string.Empty : "出问题的数据库和当时的图片都留在「damaged-日期-时间」文件夹里（全部数据还在里面）。");
        return (
            "数据打不开了",
            string.Join("\n\n", head, restore + "\n" + fresh, tail, "原因：" + reason),
            new[] { $"用 {describe}的备份", "重新开始", "退出" });
    }
}
