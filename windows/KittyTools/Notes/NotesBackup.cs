// 便签的数据保险（PLAN-v13 第 2 批，照 mac Notes/NotesBackup.swift；规则在 Core 的 NotesBackupPlan）：
// - NotesBackup：便签库每天备份一份到 notes-backups\notes-YYYY-MM-DD\（notes.sqlite3 整库快照 + images\ 当时的图片目录），留 7 份。
//   另开一个连接在线程池上做（VACUUM INTO，不碰 UI 线程那个连接）：库是坏的不备、也不动已有的备份；表是空的不备；先写进半成品文件夹，
//   拷出来的库查过才改成正式的名字、才轮换。**图片尽力而为**：一张张带上，拷不成的记日志，不让这份备份作废。
//   什么时候做跟着剪贴板库的备份（ShellRuntime.ScheduleBackup：启动、锁屏 / 解锁、睡眠唤醒）。
// - NotesRecovery：便签库打不开（或者库文件不见了 / 成了空文件而备份文件夹还在）时问：用最近的备份 / 重新开始 / 这次先不用便签。
//   前两种先把出问题的文件挪进数据目录里带时间的文件夹（damaged-…\，只挪不删），再开一次；还开不了就当「这次先不用」，不循环。
//   库是更新版本写的不算坏：不问、不动，这次不可用。用备份时把电脑编号换掉（备份里的钟是旧的，接着用原来的编号会和已经同步出去的撞上）。
// 两条死规矩：便签的问题不让 App 退出（最坏是这次运行里便签不可用）；这里的任何流程不碰剪贴板的文件（kitty.sqlite3、images\、backups\）。
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal static class NotesBackup
{
    public enum Outcome
    {
        Made,
        NotDue,
        Empty,
        Damaged,
        Failed,
    }

    private static int _running;

    public static string Folder(string directory) => Path.Combine(directory, NotesBackupPlan.FolderName);

    public static List<(string Path, DateTime Day)> List(string directory)
    {
        var found = new List<(string Path, DateTime Day)>();
        var folder = Folder(directory);
        try
        {
            if (Directory.Exists(folder))
            {
                foreach (var path in Directory.EnumerateDirectories(folder))
                {
                    if (NotesBackupPlan.DayOf(System.IO.Path.GetFileName(path)) is { } day)
                    {
                        found.Add((path, day));
                    }
                }
            }
        }
        catch
        {
            // 列不出来当没有。
        }

        found.Sort((a, b) => b.Day.CompareTo(a.Day));
        return found;
    }

    public static (string Path, DateTime Day)? LatestUsable(string directory)
    {
        foreach (var copy in List(directory))
        {
            if (IsUsable(Path.Combine(copy.Path, NotesBackupPlan.DatabaseName)))
            {
                return copy;
            }
        }

        return null;
    }

    /// <summary>这份库好不好用：查得过、版本不比认识的大。</summary>
    public static bool IsUsable(string file)
    {
        if (!File.Exists(file) || !Backup.IsIntact(file))
        {
            return false;
        }

        try
        {
            using var connection = new SqliteConnection(file, readOnly: true);
            using var statement = connection.Prepare("PRAGMA user_version;");
            return statement.Step() && statement.GetInt64(0) <= NoteStore.SchemaVersion;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>今天还没备过就备一份；调用方放到线程池（不碰 UI 线程的连接）。</summary>
    public static Outcome Run(string directory, DateTime now)
    {
        if (Interlocked.Exchange(ref _running, 1) == 1)
        {
            return Outcome.NotDue;
        }

        try
        {
            return RunCore(directory, now);
        }
        finally
        {
            Interlocked.Exchange(ref _running, 0);
        }
    }

    private static Outcome RunCore(string directory, DateTime now)
    {
        var folder = Folder(directory);
        var target = Path.Combine(folder, NotesBackupPlan.Name(now));
        var partial = Path.Combine(folder, "notes.partial");
        Discard(partial);
        if (Directory.Exists(target))
        {
            return Outcome.NotDue;
        }

        var database = Path.Combine(directory, NotesBackupPlan.DatabaseName);
        if (!File.Exists(database))
        {
            return Outcome.Empty;
        }

        if (!Backup.IsIntact(database))
        {
            Log.Warn("notes.backup-damaged");
            return Outcome.Damaged;
        }

        try
        {
            using (var source = new SqliteConnection(database, readOnly: true))
            using (var count = source.Prepare("SELECT COUNT(*) FROM notes;"))
            {
                if (!count.Step() || count.GetInt64(0) == 0)
                {
                    return Outcome.Empty;
                }
            }

            Directory.CreateDirectory(partial);
            var copy = Path.Combine(partial, NotesBackupPlan.DatabaseName);
            // 同剪贴板的备份：winsqlite3 上只读连接做 VACUUM INTO 会报只读，用普通连接（它只读源库、写目标文件）。
            using (var source = new SqliteConnection(database))
            {
                source.Execute($"VACUUM INTO '{copy.Replace("'", "''")}';");
            }

            if (!IsUsable(copy))
            {
                throw new IOException("备份出来的文件不完整");
            }

            CopyImages(Path.Combine(directory, NotesBackupPlan.ImagesName), Path.Combine(partial, NotesBackupPlan.CopiedImagesName));
            Directory.Move(partial, target);
            foreach (var old in NotesBackupPlan.Expired(List(directory), target, now))
            {
                try
                {
                    Directory.Delete(old, recursive: true);
                }
                catch (Exception ex)
                {
                    Log.Warn($"notes.backup-rotate-failed {ex.GetType().Name}");
                }
            }

            Log.Info("notes.backup-made");
            return Outcome.Made;
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.backup-failed {ex.GetType().Name}");
            Discard(partial);
            return Outcome.Failed;
        }
    }

    /// <summary>图片尽力而为（同 mac）：列目录、建文件夹出错也只记日志，不让这份库备份作废。</summary>
    private static void CopyImages(string images, string copied)
    {
        List<string> names;
        try
        {
            if (!Directory.Exists(images))
            {
                return;
            }

            names = Directory.EnumerateFiles(images).ToList();
            if (names.Count == 0)
            {
                return;
            }

            Directory.CreateDirectory(copied);
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.backup-images-failed {ex.GetType().Name}");
            return;
        }

        var failed = 0;
        foreach (var path in names)
        {
            try
            {
                File.Copy(path, Path.Combine(copied, Path.GetFileName(path)), overwrite: true);
            }
            catch
            {
                failed++;
            }
        }

        if (failed > 0)
        {
            Log.Warn($"notes.backup-images-failed count={failed} total={names.Count}");
        }
    }

    private static void Discard(string folder)
    {
        try
        {
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, recursive: true);
            }
        }
        catch
        {
            // 下次再清。
        }
    }
}

internal static class NotesRecovery
{
    /// <summary>OpenOrRecord 返回 null 时要问的事。</summary>
    public sealed record Problem(string Reason, (string Path, DateTime Day)? Backup, bool Lost);

    public static Problem? Needed { get; private set; }

    /// <summary>这次为什么用不了便签（给设置页和刘海岛说一句；null = 能用）。</summary>
    public static string? Unavailable { get; private set; }

    /// <summary>能打开就返回仓库；打不开就记下 Needed、返回 null，等界面起来以后 AskAndRepairAsync 再问。更新版本写的：不问、这次不可用。</summary>
    public static NoteStore? OpenOrRecord(Microsoft.UI.Dispatching.DispatcherQueue queue)
    {
        var directory = Paths.DataDirectory;
        var path = Paths.NotesDatabaseFile;
        long? size = File.Exists(path) ? new FileInfo(path).Length : null;
        if (size is null or 0 && NotesBackup.List(directory).Count > 0)
        {
            Needed = new Problem(size is null ? "便签的数据库文件不见了" : "便签的数据库文件是空的", NotesBackup.LatestUsable(directory), Lost: true);
            Unavailable = "便签的数据打不开";
            Log.Warn("notes.recovery-needed lost=True");
            return null;
        }

        try
        {
            return NoteStore.Start(path, queue);
        }
        catch (NotesNewerException ex)
        {
            Unavailable = ex.Message;
            Log.Warn($"notes.newer version={ex.Version}");
            return null;
        }
        catch (Exception ex)
        {
            Needed = new Problem(ex.Message, NotesBackup.LatestUsable(directory), Lost: false);
            Unavailable = "便签的数据打不开";
            Log.Warn($"notes.recovery-needed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>界面起来以后问一次；照选择挪开坏文件、恢复，再开一次。开成了返回仓库（调用方接着起便签那几样），否则 null。</summary>
    public static async Task<NoteStore?> AskAndRepairAsync(Microsoft.UI.Dispatching.DispatcherQueue queue, (DateTime Day, int Count)? exported)
    {
        if (Needed is not { } problem)
        {
            return null;
        }

        Needed = null;
        var wording = NotesBackupPlan.Wording(problem.Reason, problem.Backup?.Day, problem.Lost, exported, DateTime.Now);
        var answer = await PromptAsync(wording.Title, wording.Text, wording.Buttons);
        var choice = answer < wording.Choices.Length ? wording.Choices[answer] : NotesBackupPlan.Choice.Skip;
        if (choice == NotesBackupPlan.Choice.Skip || (choice == NotesBackupPlan.Choice.Restore && problem.Backup is null))
        {
            Log.Info("notes.recovery-skipped");
            return null;
        }

        var directory = Paths.DataDirectory;
        var database = Paths.NotesDatabaseFile;
        try
        {
            var staged = database + ".restoring";
            TryDelete(staged);
            if (choice == NotesBackupPlan.Choice.Restore && problem.Backup is { } backup)
            {
                File.Copy(Path.Combine(backup.Path, NotesBackupPlan.DatabaseName), staged, overwrite: true);
                ForgetDevice(staged);
            }

            SetAside(directory, everything: choice == NotesBackupPlan.Choice.StartFresh);
            if (choice == NotesBackupPlan.Choice.Restore && problem.Backup is { } restored)
            {
                File.Move(staged, database, overwrite: true);
                RestoreImages(restored.Path, directory);
                // 备份里的钟是旧的：换一个电脑编号，恢复之后打的字不会被已经同步出去的那几版盖掉（mac forgetDevice）。
                SyncDevice.Instance?.Rotate(NoteBook.NewId());
            }

            var store = NoteStore.Start(database, queue);
            Unavailable = null;
            Log.Info($"notes.recovery-done choice={choice}");
            return store;
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.recovery-still-broken {ex.GetType().Name}");
            Unavailable = "便签的数据打不开";
            NoticeHost.Show("便签还是打不开",
                "便签这次用不了，下次打开 Kitty Tools 时再试。剪贴板、翻译和别的功能不受影响。已经挪开的文件没有删，在数据目录的「damaged-日期-时间」文件夹里。",
                NoticeTone.Error);
            return null;
        }
    }

    /// <summary>备份里的库：把电脑编号清掉（打开时用别的）。更早的备份没有这张表，删不成不算错。</summary>
    private static void ForgetDevice(string path)
    {
        try
        {
            using var connection = new SqliteConnection(path);
            connection.Execute("DELETE FROM note_meta WHERE key = 'device';");
            connection.Execute("PRAGMA journal_mode = DELETE;");
        }
        catch
        {
            // 没有这张表。
        }
    }

    private static void SetAside(string directory, bool everything)
    {
        var names = new List<string>
        {
            NotesBackupPlan.DatabaseName + "-shm", NotesBackupPlan.DatabaseName + "-wal", NotesBackupPlan.DatabaseName,
        };
        if (everything)
        {
            names.Add(NotesBackupPlan.ImagesName);
            names.Add(NotesBackupPlan.FolderName);
        }

        var present = names.Where(name => File.Exists(Path.Combine(directory, name)) || Directory.Exists(Path.Combine(directory, name))).ToList();
        var images = Path.Combine(directory, NotesBackupPlan.ImagesName);
        var copiesImages = !everything && Directory.Exists(images) && Directory.EnumerateFileSystemEntries(images).Any();
        if (present.Count == 0 && !copiesImages)
        {
            return;
        }

        var folder = Path.Combine(directory, BackupPlan.AsideFolderName(DateTime.Now) + "-notes");
        var index = 2;
        while (Directory.Exists(folder))
        {
            folder = Path.Combine(directory, BackupPlan.AsideFolderName(DateTime.Now) + "-notes-" + index);
            index++;
        }

        Directory.CreateDirectory(folder);
        foreach (var name in present)
        {
            var from = Path.Combine(directory, name);
            var to = Path.Combine(folder, name);
            if (Directory.Exists(from))
            {
                Directory.Move(from, to);
            }
            else
            {
                File.Move(from, to);
            }
        }

        if (copiesImages)
        {
            try
            {
                var copy = Path.Combine(folder, NotesBackupPlan.ImagesName);
                Directory.CreateDirectory(copy);
                foreach (var file in Directory.EnumerateFiles(images))
                {
                    File.Copy(file, Path.Combine(copy, Path.GetFileName(file)));
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"notes.recovery-images-aside-failed {ex.GetType().Name}");
            }
        }
    }

    /// <summary>用备份时把备份里的图补回来：只补缺的、不覆盖本地已有的。</summary>
    private static void RestoreImages(string backup, string directory)
    {
        var source = Path.Combine(backup, NotesBackupPlan.CopiedImagesName);
        if (!Directory.Exists(source))
        {
            return;
        }

        var images = Path.Combine(directory, NotesBackupPlan.ImagesName);
        try
        {
            Directory.CreateDirectory(images);
            foreach (var file in Directory.EnumerateFiles(source))
            {
                var target = Path.Combine(images, Path.GetFileName(file));
                if (!File.Exists(target))
                {
                    File.Copy(file, target);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.recovery-images-failed {ex.GetType().Name}");
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // 没有就算了。
        }
    }

    /// <summary>用一个小窗口 + ContentDialog 问（同 Recovery.PromptAsync）；返回按的是第几个按钮（关掉 = 最后一个）。</summary>
    private static async Task<int> PromptAsync(string title, string text, string[] buttons)
    {
        var window = new Window { Title = Paths.ProductName };
        try
        {
            var root = new Grid();
            var loaded = new TaskCompletionSource();
            root.Loaded += (_, _) => loaded.TrySetResult();
            window.Content = root;
            window.Activate();
            await loaded.Task;
            var dialog = new ContentDialog
            {
                RequestedTheme = Theme.ElementTheme,
                Title = title,
                Content = new ScrollViewer
                {
                    Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 560 },
                    MaxHeight = 420,
                },
                PrimaryButtonText = buttons[0],
                SecondaryButtonText = buttons.Length > 2 ? buttons[1] : string.Empty,
                CloseButtonText = buttons[^1],
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = root.XamlRoot,
            };
            var result = await dialog.ShowAsync();
            return result switch
            {
                ContentDialogResult.Primary => 0,
                ContentDialogResult.Secondary => 1,
                _ => buttons.Length - 1,
            };
        }
        catch (Exception ex)
        {
            Log.Error("notes.recovery-prompt-failed", ex);
            return buttons.Length - 1;
        }
        finally
        {
            try
            {
                window.Close();
            }
            catch
            {
                // 关不掉就算了。
            }
        }
    }
}
