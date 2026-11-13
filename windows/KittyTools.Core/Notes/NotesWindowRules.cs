// 全部便签窗口和打开的便签共用的规则和文字（PLAN-v13 第 5 批，照 mac Notes/NotesWindow.swift 的 NotesWindowModel 纯函数部分）：
// 三个视图（全部 / 归档 / 最近删除）谁属于谁、选中项跟着列表怎么变、各个操作的名字（工具栏、右键菜单、操作菜单同名）、
// 列表行右边的相对时间、底下那行小字（「改于 今天 09:12 · 128 字」/「删于 昨天 22:40 · 29 天后永久删除」）、字数怎么数。
namespace KittyTools.Core.Notes;

public enum NotesScope
{
    All,
    Archive,
    Trash,
}

public static class NotesWindowRules
{
    public const string NewTitle = "新建便签";
    public const string DeleteTitle = "删除";
    public const string RestoreTitle = "放回";
    public const string EraseTitle = "永久删除…";
    public const string EmptyTrashTitle = "清空最近删除…";
    public const string ColorTitle = "颜色";
    public const string TaskTitle = "任务";
    public const string TaskHelp = "任务：把这一行变成任务，或变回普通行（Ctrl+T）";
    public const string SettingsTitle = "便签设置";
    public const string OpenInWindowTitle = "在全部便签里打开";
    public const string SingleExportTitle = "导出为 Markdown…";
    public const string OverLimitText = "一条便签最多 1 MB，这次输入没有记进去";

    /// <summary>底行：编辑器里的图片和正文对不上，之后的改动交不出去（R73）。</summary>
    public const string UnsavedText = "这条便签有改动没存上";

    /// <summary>底行：落盘失败、正在隔一会儿重试（R75，同 mac）。</summary>
    public const string SaveRetryText = "没存上，正在重试";

    public static string ScopeTitle(NotesScope scope) => scope switch
    {
        NotesScope.All => "全部",
        NotesScope.Archive => "归档",
        _ => "最近删除",
    };

    public static string FloatTitle(bool isFloating, bool hasEdge = true)
        => isFloating ? (hasEdge ? "收回边缘" : "取消浮动") : "浮在屏幕上";

    public static string PinTitle(Note? note) => note?.IsPinned == true ? "取消固定" : "固定";

    public static string ArchiveTitle(Note? note) => note?.IsArchived == true ? "取消归档" : "归档";

    public static string ArchivedTitle(int count) => count > 1 ? $"已归档 {count} 条" : "已归档";

    public static string DeletedTitle(int count) => count > 1 ? $"已删除 {count} 条" : "已删除";

    public static bool Belongs(Note note, NotesScope scope) => scope switch
    {
        NotesScope.All => note.IsActive,
        NotesScope.Archive => note.DeletedAt is null && note.IsArchived,
        _ => note.DeletedAt is not null,
    };

    public static IReadOnlyList<Note> List(NoteBook book, NotesScope scope) => scope switch
    {
        NotesScope.All => book.Active,
        NotesScope.Archive => book.Archived,
        _ => book.Trashed,
    };

    /// <summary>列表换了之后选中谁：原来那条还在就不动，不在了选第一条，空的就不选。</summary>
    public static string? SelectionKeeping(string? id, IReadOnlyList<string> ids)
        => id is not null && ids.Contains(id) ? id : ids.Count > 0 ? ids[0] : null;

    /// <summary>一条从列表里拿走之后选中谁：顶上来的那条，它是最后一条就选上一条；它本来就不在列表里给 null。</summary>
    public static string? SelectionAfterRemoving(string id, IReadOnlyList<string> ids)
    {
        var index = ids.ToList().IndexOf(id);
        if (index < 0)
        {
            return null;
        }

        return index + 1 < ids.Count ? ids[index + 1] : index > 0 ? ids[index - 1] : null;
    }

    /// <summary>挪顺序：从 from 拖到 destination（插在 destination 之前的那个位置），落下之后它是第几个。</summary>
    public static int LandingIndex(int from, int destination) => destination > from ? destination - 1 : destination;

    /// <summary>列表行右边的相对时间：「现在」「3 分钟前」「2 小时前」「昨天」「3 天前」「上周」「2 周前」，再远是日期。
    /// 最近删除里看删的时间，别处看改的时间。</summary>
    // ponytail: mac 用系统的相对时间格式（zh-Hans，named）；这里照它的几档手写，更远的写「M 月 d 日」。
    public static string Ago(Note note, long now, TimeZoneInfo zone)
    {
        var date = note.DeletedAt ?? note.ModifiedAt;
        var seconds = Math.Max(now - date, 0) / 1000;
        if (seconds < 60)
        {
            return "现在";
        }

        if (seconds < 3600)
        {
            return $"{seconds / 60} 分钟前";
        }

        var local = TimeZoneInfo.ConvertTimeFromUtc(Note.Date(date).UtcDateTime, zone);
        var today = TimeZoneInfo.ConvertTimeFromUtc(Note.Date(now).UtcDateTime, zone).Date;
        var days = (today - local.Date).Days;
        if (days <= 0)
        {
            return $"{seconds / 3600} 小时前";
        }

        return days switch
        {
            1 => "昨天",
            < 7 => $"{days} 天前",
            < 14 => "上周",
            < 30 => $"{days / 7} 周前",
            _ => local.Year == today.Year ? $"{local.Month} 月 {local.Day} 日" : $"{local.Year} 年 {local.Month} 月 {local.Day} 日",
        };
    }

    /// <summary>「今天 09:12」「昨天 22:40」，再早是「10 月 1 日（3 天前）」（mac SettingsBackup.when）。</summary>
    public static string When(long milliseconds, long now, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTimeFromUtc(Note.Date(milliseconds).UtcDateTime, zone);
        var current = TimeZoneInfo.ConvertTimeFromUtc(Note.Date(now).UtcDateTime, zone);
        var days = (current.Date - local.Date).Days;
        return days switch
        {
            <= 0 => $"今天 {local:HH:mm}",
            1 => $"昨天 {local:HH:mm}",
            _ => BackupPlan.Describe(local.Date, current),
        };
    }

    /// <summary>底下那行小字里的字数：不算空白，不数图片的令牌、颜色的标记（\r\n 算一个）。</summary>
    public static int CharacterCount(string body)
    {
        var plain = NoteMarkdown.StrippingColors(NoteImages.Stripping(body.Replace("\r\n", "\n", StringComparison.Ordinal)));
        var count = 0;
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(plain);
        while (enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            if (!(element.Length == 1 && char.IsWhiteSpace(element[0])))
            {
                count++;
            }
        }

        return count;
    }

    /// <summary>最底下那行小字：「改于 今天 09:12 · 128 字」；最近删除里是「删于 昨天 22:40 · 29 天后永久删除」。</summary>
    public static string Footnote(Note note, long now, TimeZoneInfo zone, int? count = null)
    {
        if (note.DeletedAt is not { } deleted)
        {
            return $"改于 {When(note.ModifiedAt, now, zone)} · {count ?? CharacterCount(note.Body)} 字";
        }

        var left = deleted + NoteBook.TrashDays * 86_400_000L - now;
        var days = (int)Math.Ceiling(left / 86_400_000.0);
        return $"删于 {When(deleted, now, zone)} · " + (days > 0 ? $"{days} 天后永久删除" : "即将永久删除");
    }
}
