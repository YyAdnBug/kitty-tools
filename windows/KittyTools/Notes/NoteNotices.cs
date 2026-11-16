// 便签删了 / 归档了之后底部那句（REVIEW R99，照 mac NotesWindow / NoteSheetModel）：6 秒内连着删的合成「已删除 N 条」、按钮「放回」一起放回；
// 连着归档的合成「已归档 N 条」、按钮「取消归档」。全部便签窗口、打开的便签、屏幕边缘那叠共用这一份（各处连着删也合在一起）。
using KittyTools.Core;
using KittyTools.Core.Notes;

namespace KittyTools;

internal static class NoteNotices
{
    /// <summary>这么久以内的算「连着」（同 mac）。</summary>
    private const long MergeMilliseconds = 6000;

    private static readonly List<string> Deleted = new();
    private static long _deletedAt;

    private static readonly List<string> Archived = new();
    private static long _archivedAt;

    /// <param name="undoKey">这个窗口里 Ctrl+Z 也能撤销时写进说明（全部便签窗口）。</param>
    public static void ShowDeleted(string id, bool undoKey)
    {
        var ids = Merge(Deleted, ref _deletedAt, id);
        NoticeHost.Show(NotesWindowRules.DeletedTitle(ids.Count),
            undoKey ? "Ctrl+Z 撤销，或到「最近删除」里放回" : "可以到全部便签的「最近删除」里放回", NoticeTone.Normal,
            new NoticeAction("放回", () =>
            {
                foreach (var each in ids)
                {
                    NoteStore.Instance?.Restore(each);
                }

                Deleted.Clear();
            }));
    }

    public static void ShowArchived(string id, string title)
    {
        var ids = Merge(Archived, ref _archivedAt, id);
        NoticeHost.Show(NotesWindowRules.ArchivedTitle(ids.Count), ids.Count == 1 ? title : string.Empty, NoticeTone.Normal,
            new NoticeAction("取消归档", () =>
            {
                foreach (var each in ids)
                {
                    NoteStore.Instance?.SetArchived(each, false, toFront: false);
                }

                Archived.Clear();
            }));
    }

    private static List<string> Merge(List<string> recent, ref long at, string id)
    {
        var now = Environment.TickCount64;
        if (now - at > MergeMilliseconds)
        {
            recent.Clear();
        }

        at = now;
        if (!recent.Contains(id))
        {
            recent.Add(id);
        }

        return recent.ToList();
    }
}
