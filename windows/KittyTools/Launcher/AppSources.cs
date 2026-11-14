// 应用目录开始菜单之外的几处来源（PLAN-v18 §6 = PLAN-v16 §4，启动器搜不到便携软件；Windows 独有）：
// A2 注册表 App Paths、A3 资源管理器记的「运行过的程序」（UserAssist，设置 › 启动器「把运行过的程序也列出来」，默认开）、
// A4 用户加的应用文件夹（往下两层、每个文件夹最多 500 个 exe、2 秒超时）和单个程序；A1 桌面在 AppCatalog.ScanStartMenu 里一起扫。
// A3 A4 过 Core PortableApps 的名单（卸载、安装、更新…不收；没图标的命令行小工具不收；同一个文件夹说明一样的只留一个）。
// 另外给每个应用算别名的键（L5）和系统记的最后一次运行（L6 同分排序）。全在后台线程。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Win32;

namespace KittyTools;

internal static partial class AppSources
{
    /// <summary>每个文件夹最多收这么多 exe（超了只记日志）。</summary>
    private const int FolderLimit = 500;

    /// <summary>UserAssist 里快捷方式那一组（{F4E57C4B-…}，.lnk 的路径）。</summary>
    private const string ShortcutsKey =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}\Count";

    /// <summary>别名的键里折路径用的几个文件夹（%ProgramFiles% 这类）。</summary>
    public static readonly (string Variable, string Path)[] AliasFolders =
    {
        ("%ProgramFiles%", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)),
        ("%ProgramFiles(x86)%", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86)),
        ("%LocalAppData%", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)),
        ("%AppData%", Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)),
        ("%UserProfile%", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
        ("%SystemRoot%", Environment.GetFolderPath(Environment.SpecialFolder.Windows)),
    };

    /// <summary>A2：HKCU / HKLM 的 App Paths（默认值是 exe 路径，可能带引号和 %变量%）；文件不在、在 Windows 目录下的不要。</summary>
    public static List<string> AppPaths()
    {
        var found = new List<string>();
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var root = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths");
                foreach (var name in root?.GetSubKeyNames() ?? Array.Empty<string>())
                {
                    using var key = root!.OpenSubKey(name);
                    if (key?.GetValue(null) is not string raw)
                    {
                        continue;
                    }

                    var path = Environment.ExpandEnvironmentVariables(raw.Trim().Trim('"'));
                    if (path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(path) &&
                        PortableApps.IsCandidate(path, windows, string.Empty))
                    {
                        found.Add(path);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.app-paths-failed {ex.GetType().Name}");
            }
        }

        return found;
    }

    /// <summary>
    /// A3 / L6：资源管理器记的运行记录。Programs：运行过的 exe（过了候选、文件还在）；LastRun：exe 和 .lnk 路径（小写）→ 最后运行时刻。
    /// 「允许 Windows 跟踪应用启动」关着时是空的，不报错。
    /// </summary>
    public static (List<UserAssistEntry> Programs, Dictionary<string, DateTime> LastRun) UserAssist()
    {
        var programs = new List<UserAssistEntry>();
        var lastRun = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var own = AppContext.BaseDirectory.TrimEnd('\\');
        foreach (var (subKey, executables) in new[] { (PortableApps.ExecutablesKey, true), (ShortcutsKey, false) })
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(subKey);
                foreach (var name in key?.GetValueNames() ?? Array.Empty<string>())
                {
                    if (PortableApps.Parse(name, key!.GetValue(name) as byte[], KnownFolder) is not { } entry)
                    {
                        continue;
                    }

                    if (entry.LastRunUtc is { } last)
                    {
                        lastRun[entry.Path] = last;
                    }

                    if (executables && PortableApps.IsCandidate(entry.Path, windows, own) && File.Exists(entry.Path))
                    {
                        programs.Add(entry);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.userassist-failed {ex.GetType().Name}");
            }
        }

        return (programs, lastRun);
    }

    /// <summary>A4：用户加的文件夹往下两层的 exe、单个程序（.exe / .lnk）。每个文件夹 2 秒超时（离线的网络盘），超时那个这一轮跳过。</summary>
    public static List<string> UserFolders(IEnumerable<string> entries)
    {
        var found = new List<string>();
        foreach (var entry in entries)
        {
            if (entry.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || entry.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
            {
                if (File.Exists(entry))
                {
                    found.Add(entry);
                }

                continue;
            }

            var scan = Task.Run(() => ExesUnder(entry));
            if (!scan.Wait(2000))
            {
                Log.Warn("launcher.app-folder-timeout");
                continue;
            }

            found.AddRange(scan.Result);
        }

        return found;
    }

    private static List<string> ExesUnder(string folder)
    {
        var found = new List<string>();
        try
        {
            if (!Directory.Exists(folder))
            {
                return found;
            }

            void Add(string directory, int depth)
            {
                foreach (var exe in Directory.EnumerateFiles(directory, "*.exe"))
                {
                    if (found.Count >= FolderLimit)
                    {
                        return;
                    }

                    found.Add(exe);
                }

                if (depth >= 2)
                {
                    return;
                }

                foreach (var child in Directory.EnumerateDirectories(directory))
                {
                    try
                    {
                        Add(child, depth + 1);
                    }
                    catch (UnauthorizedAccessException)
                    {
                        // 进不去的子文件夹跳过
                    }
                }
            }

            Add(folder, 0);
            if (found.Count >= FolderLimit)
            {
                Log.Info($"launcher.app-folder-limit count={found.Count}");
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.app-folder-failed {ex.GetType().Name}");
        }

        return found;
    }

    /// <summary>
    /// 一个 exe 当成应用的那一行：标题是文件说明（空的或等于文件名时用文件名），名字里也放文件名；没图标的（命令行小工具）、
    /// 名单里的（卸载、安装…）返回 null（filter 关着时只看有没有图标，App Paths 用）。
    /// </summary>
    public static LauncherItem? ExeItem(string path, string subtitle, double scale, bool filter)
    {
        string? description = null;
        try
        {
            description = FileVersionInfo.GetVersionInfo(path).FileDescription?.Trim();
        }
        catch
        {
            // 读不到版本信息：用文件名
        }

        if (filter && PortableApps.IsJunk(path, description))
        {
            return null;
        }

        var icon = ShellIcons.LoadPng(path, scale);
        if (icon is not { Length: > 0 })
        {
            return null;
        }

        var fileTitle = Path.GetFileNameWithoutExtension(path);
        var title = string.IsNullOrWhiteSpace(description) || string.Equals(description, fileTitle, StringComparison.OrdinalIgnoreCase)
            ? fileTitle
            : description;
        var names = new List<string> { LauncherMatch.Fold(title), LauncherMatch.Fold(fileTitle) };
        var initials = new List<string> { LauncherMatch.Initials(title), LauncherMatch.Initials(fileTitle) };
        if (Pinyin.For(title) is { } pinyin)
        {
            names.Add(pinyin.Full);
            initials.Add(pinyin.Initials);
        }

        return new LauncherItem
        {
            Kind = LauncherKind.App,
            Target = path,
            Title = title,
            Subtitle = subtitle,
            Names = names.Distinct().ToList(),
            Initials = initials.Where(value => value.Length > 0).Distinct().ToList(),
            IconPath = path,
            IconData = icon,
            AliasKey = AppAliases.Key(path, path, AliasFolders),
        };
    }

    /// <summary>文件说明（同一个文件夹里说明一样的只留一个用）。</summary>
    public static string? Description(string path)
    {
        try
        {
            return FileVersionInfo.GetVersionInfo(path).FileDescription?.Trim();
        }
        catch
        {
            return null;
        }
    }

    private static string? KnownFolder(Guid id)
    {
        try
        {
            return SHGetKnownFolderPath(id, 0, IntPtr.Zero, out var pointer) == 0 && pointer != IntPtr.Zero
                ? Marshal.PtrToStringUni(pointer) is var path && FreeAndReturn(pointer, path) is { } result ? result : null
                : null;
        }
        catch
        {
            return null;
        }
    }

    private static string? FreeAndReturn(IntPtr pointer, string? value)
    {
        Marshal.FreeCoTaskMem(pointer);
        return value;
    }

    [LibraryImport("shell32.dll")]
    private static partial int SHGetKnownFolderPath(in Guid id, uint flags, IntPtr token, out IntPtr path);
}
