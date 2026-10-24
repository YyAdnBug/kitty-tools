// 把解压好的新版本盖到安装目录（配单测）：
// 1. 同名文件先改名成 `*.old`（Windows 允许改名正在运行的文件）；
// 2. 再把新文件拷进去；
// 3. 任何一步失败：删掉已经拷进去的新文件、把 `*.old` 全改回去，保证旧版本还能启动。
// 新进程启动后再调 `RemoveOldFiles` 把 `.old` 删掉（那时旧文件已经没人占着了）。
namespace KittyTools.Core;

public sealed record InstallResult(bool Ok, string? Error, IReadOnlyList<string> Installed)
{
    public static InstallResult Failed(string error) => new(false, error, Array.Empty<string>());
}

public static class UpdateInstaller
{
    public const string OldSuffix = ".old";

    /// <summary>安装目录里有没有写权限（装在 Program Files 时没有）：写一个临时文件试一下。</summary>
    public static bool CanWriteInstallDirectory(string installDir)
    {
        try
        {
            var probe = Path.Combine(installDir, $".kitty-write-probe-{Guid.NewGuid():N}");
            using (var stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.WriteByte(0);
            }

            File.Delete(probe);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>stagingDir 是解压出来的新版本（可能带一层同名目录），installDir 是当前安装目录。</summary>
    public static InstallResult Install(string stagingDir, string installDir)
    {
        if (!Directory.Exists(stagingDir))
        {
            return InstallResult.Failed("解压目录不存在");
        }

        if (!Directory.Exists(installDir))
        {
            return InstallResult.Failed("安装目录不存在");
        }

        var files = Directory.EnumerateFiles(stagingDir, "*", SearchOption.AllDirectories).ToList();
        if (files.Count == 0)
        {
            return InstallResult.Failed("解压目录里没有文件");
        }

        var renamed = new List<(string Old, string Original)>();
        var copied = new List<string>();
        try
        {
            foreach (var source in files)
            {
                var relative = Path.GetRelativePath(stagingDir, source);
                var target = Path.Combine(installDir, relative);
                var targetDirectory = Path.GetDirectoryName(target);
                if (!string.IsNullOrEmpty(targetDirectory))
                {
                    Directory.CreateDirectory(targetDirectory);
                }

                if (File.Exists(target))
                {
                    var old = target + OldSuffix;
                    if (File.Exists(old))
                    {
                        File.Delete(old);
                    }

                    File.Move(target, old);
                    renamed.Add((old, target));
                }

                File.Copy(source, target, overwrite: true);
                copied.Add(target);
            }

            return new InstallResult(true, null, copied);
        }
        catch (Exception ex)
        {
            Rollback(renamed, copied);
            return InstallResult.Failed($"{ex.GetType().Name}: {ex.Message}");
        }
    }

    private static void Rollback(List<(string Old, string Original)> renamed, List<string> copied)
    {
        // 先删新拷进去的，再改名回去（顺序反了的话改名会被新文件挡住）。
        foreach (var target in copied)
        {
            try
            {
                if (File.Exists(target))
                {
                    File.Delete(target);
                }
            }
            catch
            {
                // 删不掉也继续，尽量把旧的改回去。
            }
        }

        for (var index = renamed.Count - 1; index >= 0; index--)
        {
            var (old, original) = renamed[index];
            try
            {
                if (File.Exists(old))
                {
                    File.Delete(original);
                    File.Move(old, original);
                }
            }
            catch
            {
                // 同上：能恢复多少算多少。
            }
        }
    }

    /// <summary>新版本启动后删掉 `*.old`；返回删了几个。</summary>
    public static int RemoveOldFiles(string installDir)
    {
        if (!Directory.Exists(installDir))
        {
            return 0;
        }

        var removed = 0;
        foreach (var file in Directory.EnumerateFiles(installDir, "*" + OldSuffix, SearchOption.AllDirectories))
        {
            try
            {
                File.Delete(file);
                removed++;
            }
            catch
            {
                // 还被占着（比如旧 exe 还没退干净）：下次启动再删。
            }
        }

        return removed;
    }

    /// <summary>
    /// 解压出来的目录里真正的 exe 在哪：发布物是一个「Kitty Tools」文件夹，
    /// 有时外面还套一层；往下找最多两层。
    /// </summary>
    public static string? FindEntryDirectory(string stagingDir, string exeName)
    {
        if (File.Exists(Path.Combine(stagingDir, exeName)))
        {
            return stagingDir;
        }

        var direct = Directory.EnumerateDirectories(stagingDir)
            .FirstOrDefault(dir => File.Exists(Path.Combine(dir, exeName)));
        if (direct is not null)
        {
            return direct;
        }

        foreach (var child in Directory.EnumerateDirectories(stagingDir))
        {
            var nested = Directory.EnumerateDirectories(child)
                .FirstOrDefault(dir => File.Exists(Path.Combine(dir, exeName)));
            if (nested is not null)
            {
                return nested;
            }
        }

        return null;
    }
}
