// 数据库打不开时的恢复（第三版 §2.1，规则在 Core/BackupPlan）：
// 开库 / 建表 / 迁移 / 读表任何一步出错，或者库文件不见了 / 是空的而备份还在，就弹框让用户选：
//   · 用最近一份备份（按钮上写日期）；
//   · 重新开始；
//   · 退出。
// 前两种都先把出问题的库（连 -wal、-shm）挪进 damaged-日期-时间\（一律不删），用备份时再把当时的图片拷一份进去；
// 重新开始时图片目录和备份目录整个挪进去（旧的一整套都留着）。
// 只问一次：恢复 / 重新开始之后再开还失败就抛出去，不循环。
// REVIEW R64 B：启动时不当场问（以前在 UI 线程上同步等 ContentDialog：等不到，XamlRoot 也还是空的，
// 异常被当成「退出」，App 一声不响就退了）。OpenWithRecovery 只判断、记下 Needed；界面起来以后
// AskAndRepairAsync 再问，照选择挪开坏文件、恢复，然后重启自己（--restarted），要库的功能在新进程里正常起。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal static class Recovery
{
    public enum Choice
    {
        Restore,
        StartFresh,
        Quit,
    }

    /// <summary>OpenWithRecovery 返回 null 时要问的事：为什么、最近一份能用的备份、是不是整个丢了。</summary>
    public sealed record Pending(string Reason, (string Path, DateTime Day)? Backup, bool Lost);

    public static Pending? Needed { get; private set; }

    /// <summary>能打开就返回库；打不开就记下 <see cref="Needed"/>、返回 null，等界面起来以后 <see cref="AskAndRepairAsync"/> 再问。</summary>
    public static Database? OpenWithRecovery()
    {
        var directory = Paths.DataDirectory;
        var databasePath = Paths.DatabaseFile;

        string reason;
        var backup = Backup.LatestUsable(directory);
        long? size = File.Exists(databasePath) ? new FileInfo(databasePath).Length : null;
        if (BackupPlan.LooksLost(size, backup is not null))
        {
            reason = size is null ? "数据库文件不见了" : "数据库文件是空的";
        }
        else
        {
            try
            {
                return Database.OpenDefault();
            }
            catch (Exception ex)
            {
                reason = ex.Message;
                backup = Backup.LatestUsable(directory);
            }
        }

        Log.Warn($"recovery.needed reason={reason} backup={backup is not null}");
        Needed = new Pending(reason, backup, Lost: size is null or 0);
        return null;
    }

    /// <summary>界面起来以后问一次：用备份 / 重新开始就挪开坏文件、恢复、确认能打开，然后重启自己；选退出就退出。</summary>
    public static async Task AskAndRepairAsync()
    {
        if (Needed is not { } pending)
        {
            return;
        }

        var choice = await AskAsync(pending.Reason, pending.Backup?.Day, pending.Lost);
        if (choice == Choice.Quit)
        {
            ShellRuntime.Instance?.Exit();
            return;
        }

        var directory = Paths.DataDirectory;
        var databasePath = Paths.DatabaseFile;
        var backup = pending.Backup;
        try
        {
            var staged = databasePath + ".restoring";
            TryDelete(staged);
            if (choice == Choice.Restore && backup is { } copy)
            {
                File.Copy(copy.Path, staged, overwrite: true);
            }

            SetAside(directory, everything: choice == Choice.StartFresh);
            if (choice == Choice.Restore)
            {
                File.Move(staged, databasePath, overwrite: true);
            }

            // 先确认新库打得开，再重启；重启后的进程照常开库、起剪贴板这些。
            using (Database.OpenDefault())
            {
            }

            Log.Info($"recovery.done choice={choice}");
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Paths.ExecutablePath, "--restarted")
            {
                UseShellExecute = false,
            });
            ShellRuntime.Instance?.Exit();
        }
        catch (Exception ex)
        {
            Log.Error("recovery.still-broken", ex);
            Show("还是打不开", ex.Message + "\n\n出问题的文件都挪开了，没有删。");
        }
    }

    /// <summary>弹框：按钮和 choices 一一对应；没有可用备份时只有「重新开始 / 退出」。</summary>
    private static async Task<Choice> AskAsync(string reason, DateTime? backupDay, bool lost)
    {
        var wording = BackupPlan.Wording(reason, backupDay, lost, DateTime.Now);
        var primary = backupDay is not null ? wording.Buttons[0] : "重新开始";
        var secondary = backupDay is not null ? "重新开始" : "退出";
        var close = backupDay is not null ? "退出" : string.Empty;
        var choice = await PromptAsync(wording.Title, wording.Text, primary, secondary, close);
        if (backupDay is null)
        {
            return choice switch
            {
                0 => Choice.StartFresh,
                _ => Choice.Quit,
            };
        }

        return choice switch
        {
            0 => Choice.Restore,
            1 => Choice.StartFresh,
            _ => Choice.Quit,
        };
    }

    /// <summary>用一个小窗口 + ContentDialog 问（按钮顺序固定）。XamlRoot 要等内容 Loaded 以后才有。</summary>
    private static async Task<int> PromptAsync(string title, string text, string primary, string secondary, string close)
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
                    Content = new TextBlock
                    {
                        Text = text,
                        TextWrapping = TextWrapping.Wrap,
                        MaxWidth = 560,
                    },
                    MaxHeight = 420,
                },
                PrimaryButtonText = primary,
                SecondaryButtonText = secondary,
                CloseButtonText = close,
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = root.XamlRoot,
            };
            var result = await dialog.ShowAsync();
            return result switch
            {
                ContentDialogResult.Primary => 0,
                ContentDialogResult.Secondary => 1,
                _ => 2,
            };
        }
        catch (Exception ex)
        {
            Log.Error("recovery.prompt-failed", ex);
            return 2;
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

    private static void Show(string title, string text) => NoticeHost.Show(title, text, NoticeTone.Error);

    /// <summary>把出问题的库（连 -wal、-shm）挪进 damaged-…\；重新开始时图片和备份目录整个挪进去，用备份时图片拷一份。</summary>
    private static void SetAside(string directory, bool everything)
    {
        var images = Path.Combine(directory, "images");
        var backups = Path.Combine(directory, BackupPlan.FolderName);
        var names = new List<string>
        {
            BackupPlan.DatabaseName + "-shm",
            BackupPlan.DatabaseName + "-wal",
            BackupPlan.DatabaseName,
        };
        if (everything)
        {
            names.Add("images");
            names.Add(BackupPlan.FolderName);
        }

        var present = names
            .Where(name => File.Exists(Path.Combine(directory, name)) ||
                           Directory.Exists(Path.Combine(directory, name)))
            .ToList();
        var copyImages = !everything && Directory.Exists(images) &&
                         Directory.EnumerateFileSystemEntries(images).Any();
        if (present.Count == 0 && !copyImages)
        {
            return;
        }

        var folder = Path.Combine(directory, BackupPlan.AsideFolderName(DateTime.Now));
        var index = 2;
        while (Directory.Exists(folder))
        {
            folder = Path.Combine(directory, BackupPlan.AsideFolderName(DateTime.Now) + "-" + index);
            index++;
        }

        Directory.CreateDirectory(folder);
        foreach (var name in present)
        {
            var from = Path.Combine(directory, name);
            var to = Path.Combine(folder, name);
            try
            {
                if (Directory.Exists(from))
                {
                    Directory.Move(from, to);
                }
                else
                {
                    File.Move(from, to);
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"recovery.aside-failed {name} {ex.GetType().Name}");
            }
        }

        if (copyImages)
        {
            try
            {
                CopyDirectory(images, Path.Combine(folder, "images"));
            }
            catch (Exception ex)
            {
                Log.Warn($"recovery.images-copy-failed {ex.GetType().Name}");
            }
        }

        Log.Info($"recovery.set-aside {Path.GetFileName(folder)}");
    }

    private static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.EnumerateFiles(from))
        {
            File.Copy(file, Path.Combine(to, Path.GetFileName(file)), overwrite: true);
        }

        foreach (var directory in Directory.EnumerateDirectories(from))
        {
            CopyDirectory(directory, Path.Combine(to, Path.GetFileName(directory)));
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // 删不掉也没关系（恢复时会被覆盖）。
        }
    }
}
