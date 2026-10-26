// 数据库打不开时的恢复（第三版 §2.1，规则在 Core/BackupPlan）：
// 开库 / 建表 / 迁移 / 读表任何一步出错，或者库文件不见了 / 是空的而备份还在，就弹框让用户选：
//   · 用最近一份备份（按钮上写日期）；
//   · 重新开始；
//   · 退出。
// 前两种都先把出问题的库（连 -wal、-shm）挪进 damaged-日期-时间\（一律不删），用备份时再把当时的图片拷一份进去；
// 重新开始时图片目录和备份目录整个挪进去（旧的一整套都留着）。
// 只问一次：恢复 / 重新开始之后再开还失败就抛出去，不循环。
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

    /// <summary>打不开时问用户（只问一次），照选择恢复 / 重新开始后返回新的 Database；选退出返回 null。</summary>
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
        var choice = Ask(reason, backup?.Day, lost: size is null or 0);
        if (choice == Choice.Quit)
        {
            return null;
        }

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

            var database = Database.OpenDefault();
            Log.Info($"recovery.done choice={choice}");
            return database;
        }
        catch (Exception ex)
        {
            Log.Error("recovery.still-broken", ex);
            Show("还是打不开", ex.Message + "\n\n出问题的文件都挪开了，没有删。");
            return null;
        }
    }

    /// <summary>弹框：按钮和 choices 一一对应；没有可用备份时只有「重新开始 / 退出」。</summary>
    private static Choice Ask(string reason, DateTime? backupDay, bool lost)
    {
        var wording = BackupPlan.Wording(reason, backupDay, lost, DateTime.Now);
        var primary = backupDay is not null ? wording.Buttons[0] : "重新开始";
        var secondary = backupDay is not null ? "重新开始" : "退出";
        var close = backupDay is not null ? "退出" : string.Empty;
        var choice = Prompt(wording.Title, wording.Text, primary, secondary, close);
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

    /// <summary>用一个小窗口 + ContentDialog 问（启动早期也能用；按钮顺序固定）。</summary>
    private static int Prompt(string title, string text, string primary, string secondary, string close)
    {
        var window = new Window { Title = Paths.ProductName };
        try
        {
            window.Content = new Grid();
            window.Activate();
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
                XamlRoot = (window.Content as FrameworkElement)?.XamlRoot,
            };
            var result = dialog.ShowAsync().AsTask().GetAwaiter().GetResult();
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
