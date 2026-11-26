// 应用在启动器里能搜的名字（纯函数，配单测；PLAN-v27 §1 B1 B4）：开始菜单 / 桌面的快捷方式、exe、商店应用共用这一份。
// - 标题（资源管理器显示的本地化名）、文件名，中文的拼音全拼和首字母（原来三处各写一遍）；
// - 快捷方式**目标 exe 的名字**：「命令提示符」→ cmd、「注册表编辑器」→ regedit、「任务管理器」→ taskmgr（以前只写在副标题里、搜不到；
//   成熟的启动器的程序插件也按可执行文件名匹配）。一堆快捷方式共用的宿主（rundll32、javaw、PWA 的 *_proxy…）和更新器不算；
// - 商店应用另加**包名去掉发布者那一截**（Microsoft.WindowsTerminal → WindowsTerminal）：中文系统上「终端」「计算器」「画图」
//   也能用 terminal / wt、calc、paint 搜到。
// ponytail: 宿主名单按印象列的，漏的（某个 exe 名被一堆快捷方式共用）真机上看到再加。
namespace KittyTools.Core;

public static class AppNames
{
    /// <summary>目标 exe 名在这里的不拿来当名字：很多快捷方式共用，打出来一串（不是用户想找的那个程序）。</summary>
    private static readonly HashSet<string> Hosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "rundll32", "javaw", "java", "wscript", "cscript", "mshta", "msiexec", "dllhost", "conhost",
        "chrome_proxy", "msedge_proxy", "pwahelper",
    };

    /// <summary>能当「程序名」的扩展名（.msc / .cpl 是系统管理工具：services.msc、ncpa.cpl）。</summary>
    private static readonly HashSet<string> Runnable = new(StringComparer.OrdinalIgnoreCase) { ".exe", ".com", ".msc", ".cpl" };

    /// <summary>
    /// 名字和首字母（都已折叠、去重、去空）。labels：标题、文件名这些给人看的名字（中文的另加拼音）；
    /// targetExe：快捷方式解析出来的目标（可以带 %windir% 这类变量），能当程序名的话把文件名（不带扩展名）加进名字。
    /// </summary>
    public static (List<string> Names, List<string> Initials) Build(IEnumerable<string?> labels, string? targetExe = null)
    {
        var names = new List<string>();
        var initials = new List<string>();
        foreach (var label in labels)
        {
            if (string.IsNullOrWhiteSpace(label))
            {
                continue;
            }

            names.Add(LauncherMatch.Fold(label));
            initials.Add(LauncherMatch.Initials(label));
            if (Pinyin.For(label) is { } pinyin)
            {
                names.Add(pinyin.Full);
                initials.Add(pinyin.Initials);
            }
        }

        if (ExeStem(targetExe) is { } stem)
        {
            names.Add(LauncherMatch.Fold(stem));
        }

        return (names.Where(value => value.Length > 0).Distinct().ToList(), initials.Where(value => value.Length > 0).Distinct().ToList());
    }

    /// <summary>目标的程序名（cmd、regedit、services）；不是程序、是宿主或更新器（Update.exe --processStart …）时 null。</summary>
    public static string? ExeStem(string? target)
    {
        if (string.IsNullOrWhiteSpace(target))
        {
            return null;
        }

        var file = target.Trim().Trim('"');
        var slash = file.LastIndexOfAny(new[] { '\\', '/' });
        var name = slash >= 0 ? file[(slash + 1)..] : file;
        var dot = name.LastIndexOf('.');
        if (dot <= 0 || !Runnable.Contains(name[dot..]))
        {
            return null;
        }

        var stem = name[..dot];
        return Hosts.Contains(stem) || PortableApps.IsJunk(stem, null) ? null : stem;
    }

    /// <summary>
    /// 商店应用包名去掉发布者那一截：Microsoft.WindowsTerminal → WindowsTerminal、5319275A.WeChatDesktop → WeChatDesktop；
    /// 剩下的是一串编号（Microsoft.549981C3F5F10）或者没有点的，返回 null。
    /// </summary>
    public static string? PackageShortName(string? packageName)
    {
        if (string.IsNullOrWhiteSpace(packageName))
        {
            return null;
        }

        var dot = packageName.IndexOf('.');
        var tail = dot < 0 ? string.Empty : packageName[(dot + 1)..].Trim();
        return tail.Length < 2 || tail.Count(char.IsDigit) * 2 > tail.Length ? null : tail;
    }
}
