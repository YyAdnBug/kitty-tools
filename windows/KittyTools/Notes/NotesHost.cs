// 便签这一族在运行时的总管（PLAN-v13 第 2 批起；照 mac AppDelegate 里 finishLaunchingNotes / applyFeatures 的便签那几段）：
// - 启动：打开便签库（打不开时记下，界面起来以后问一次怎么恢复）、图片目录、到期清理（「最近删除」满 30 天、没人引用的图满 30 天）、
//   示例便签；之后的窗口（快速记一条、全部便签、屏幕边缘那叠、浮动便签）各批接到这里。
// - **数据层不跟着功能开关走**（mac-native §1「功能开关」）：便签功能关着时库照开、每日备份照做、到期照删，只是入口全藏。
// - Flush：锁屏、睡眠、退出前把攒着的打字落下去。
// - 每日维护（ScheduleBackup 时跟着走：启动、锁屏 / 解锁、睡眠唤醒）：到期清理 + 便签库的每日备份（线程池上）。
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal static class NotesHost
{
    private static DispatcherQueue? _queue;
    private static DateTime _maintainedDay;

    public static NoteStore? Store => NoteStore.Instance;

    /// <summary>启动时调一次（UI 线程）。</summary>
    public static void Start(DispatcherQueue queue)
    {
        _queue = queue;
        var store = NotesRecovery.OpenOrRecord(queue);
        if (store is not null)
        {
            Ready(store);
            return;
        }

        if (NotesRecovery.Needed is not null)
        {
            // 界面起来以后再问（同 Recovery：启动时同步等对话框等不到 XamlRoot）。
            queue.TryEnqueue(async () =>
            {
                if (await NotesRecovery.AskAndRepairAsync(queue, ExportedNotes()) is { } repaired)
                {
                    Ready(repaired);
                }
            });
        }
    }

    private static void Ready(NoteStore store)
    {
        store.Images = new NoteImageStore(Paths.NotesImagesDirectory);
        Maintain(force: true);
        var settings = SettingsService.Current;
        var step = NoteSample.Next(settings.NotesSampleAdded, settings.NotesDeckEnabled, store.Book.All.Count);
        if (step != NoteSample.Step.Skip)
        {
            if (step == NoteSample.Step.Add)
            {
                var binding = SettingsDefaults.BindingFor(settings, HotKeyActions.NoteCapture);
                var key = binding.VirtualKey == 0 ? null : Core.HotKeyRules.Format(binding.VirtualKey, binding.Modifiers);
                store.Create(NoteSample.Body(settings.NotesDeckEdge == "left" ? "左" : "右", key));
            }

            settings.NotesSampleAdded = true;
            SettingsService.Save();
        }

        Log.Info($"notes.ready count={store.Book.All.Count}");
    }

    /// <summary>锁屏、睡眠、退出前：把攒着的打字落下去。</summary>
    public static void Flush() => Store?.Flush();

    /// <summary>每天一次的清理：「最近删除」满 30 天的真删、没人引用满 30 天的图删（便签这次用不了时不清）。</summary>
    public static void Maintain(bool force = false)
    {
        if (Store is not { } store || (!force && _maintainedDay == DateTime.Today))
        {
            return;
        }

        _maintainedDay = DateTime.Today;
        var purged = store.PurgeExpired();
        if (purged > 0)
        {
            Log.Info($"notes.trash-purged count={purged}");
        }

        store.Images?.Purge(store.Book.ReferencedImages, NoteStore.Now);
    }

    /// <summary>便签库的每日备份（线程池上调）；便签这次用不了、还没问怎么恢复的时候不备（别拿坏的库顶掉好的备份）。</summary>
    public static void BackupIfDue(string directory, DateTime now)
    {
        if (NotesRecovery.Needed is null && File.Exists(Path.Combine(directory, NotesBackupPlan.DatabaseName)))
        {
            NotesBackup.Run(directory, now);
        }
    }

    /// <summary>每日 JSON 备份里最近一份带着几条便签（打不开时的对话框说一句「之后还能导回来」）。</summary>
    private static (DateTime Day, int Count)? ExportedNotes()
    {
        try
        {
            foreach (var path in ArchiveService.BackupFiles("Kitty Tools 自动备份 *.json"))
            {
                if (ArchiveService.Decode(File.ReadAllText(path)) is { Notes: { Count: > 0 } notes })
                {
                    return (File.GetLastWriteTime(path).Date, notes.Count);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.exported-scan-failed {ex.GetType().Name}");
        }

        return null;
    }
}
