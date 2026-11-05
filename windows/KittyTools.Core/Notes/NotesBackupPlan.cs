// 便签库每日备份和打不开时恢复的纯规则（PLAN-v13 第 2 批，照 mac Notes/NotesBackup.swift 的纯部分；读写文件在 App 的 NotesBackup）：
// - 一天一个文件夹 notes-backups\notes-2026-10-12\：里面 notes.sqlite3 是整库的一致快照，images\ 是当时的图片目录；留最近 7 份。
//   和剪贴板的备份不同，**便签整库都备**（都是用户自己写下留着的，「最近删除」里的也在）；表是空的不备。
// - 轮换同剪贴板（BackupPlan.Expired 的口径，只是留 7 份）：刚写的那份不删；多出来的先删日期比现在还晚的，再删最旧的。
// - 打不开时问什么（Wording）：用最近的备份 / 重新开始 / 这次先不用便签。
namespace KittyTools.Core.Notes;

public static class NotesBackupPlan
{
    public const int Keep = 7;

    public const string FolderName = "notes-backups";

    public const string DatabaseName = "notes.sqlite3";

    public const string ImagesName = "notes-images";

    public const string CopiedImagesName = "images";

    public static string Name(DateTime day) => $"notes-{day:yyyy-MM-dd}";

    public static DateTime? DayOf(string name)
    {
        if (name.Length != "notes-yyyy-MM-dd".Length || !name.StartsWith("notes-", StringComparison.Ordinal))
        {
            return null;
        }

        return DateTime.TryParseExact(name.AsSpan(6), "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.None, out var day)
            ? day.Date
            : null;
    }

    /// <summary>轮换：连刚写的那份一共留 Keep 份。</summary>
    public static List<string> Expired(IReadOnlyList<(string Path, DateTime Day)> copies, string written, DateTime now)
    {
        var others = copies
            .Where(copy => !string.Equals(copy.Path, written, StringComparison.OrdinalIgnoreCase))
            .OrderBy(copy => copy.Day)
            .ToList();
        var ordered = others.Where(copy => copy.Day > now.Date).Concat(others.Where(copy => copy.Day <= now.Date)).ToList();
        var remove = Math.Max(others.Count - (Keep - 1), 0);
        return ordered.Take(remove).Select(copy => copy.Path).ToList();
    }

    public enum Choice
    {
        Restore,
        StartFresh,
        Skip,
    }

    /// <summary>打不开时的对话框（mac NotesRecovery.wording）：标题、正文、按钮和按钮对应的选择。exported：每日 JSON 备份里带着几条便签、是哪天的。</summary>
    public static (string Title, string Text, string[] Buttons, Choice[] Choices) Wording(
        string reason, DateTime? backupDay, bool lost, (DateTime Day, int Count)? exported, DateTime now)
    {
        const string title = "便签打不开了";
        const string head = "便签的数据读不出来了。剪贴板、翻译和别的功能不受影响。";
        const string fresh = "重新开始：便签从空的开始；现在的便签数据、图片和备份一起挪开留着。";
        const string skip = "这次先不用便签：什么都不动，便签这次用不了，下次打开 Kitty Tools 时再试。";
        const string kept = "挪开的文件不会删，在数据目录里一个「damaged-日期-时间」的文件夹里。";
        var tail = new List<string> { kept };
        if (exported is { } saved)
        {
            tail.Add(
                $"选了重新开始，便签的文字之后还能导回来：到 设置 › 通用 点「从备份恢复」，选 {BackupPlan.Describe(saved.Day, now)}那份，只勾「便签」" +
                $"（{saved.Count} 条；图片和「最近删除」里的不在里面）。");
        }

        tail.Add("原因：" + reason);
        if (backupDay is not { } day)
        {
            return (title, string.Join("\n\n", new[] { head + "也没有可用的备份。", fresh + "\n" + skip }.Concat(tail)),
                new[] { "重新开始", "这次先不用便签" }, new[] { Choice.StartFresh, Choice.Skip });
        }

        var describe = BackupPlan.Describe(day, now);
        var restore = $"用备份：便签回到 {describe}备份时的样子，那之后写的、改的不在里面。" +
                      (lost ? string.Empty : "出问题的便签数据留在「damaged-日期-时间」文件夹里。");
        return (title, string.Join("\n\n", new[] { head, string.Join("\n", restore, fresh, skip) }.Concat(tail)),
            new[] { $"用 {describe}的备份", "重新开始", "这次先不用便签" },
            new[] { Choice.Restore, Choice.StartFresh, Choice.Skip });
    }
}
