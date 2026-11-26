// PLAN-v26 L1：启动器的路径模式（同 mac 0.10.1 311fa831、07082ab2，换成 Windows 的写法）。输入以盘符（C:\）、~\、%变量%\、
// \\服务器\共享\ 开头时，直接列出那个文件夹里的东西：文件夹在前、按名字排；最后一个 \ 后面没打完的那段按名字筛（开头对上的都算，
// 名字中间对上的至少两个字）；没打「.」时不列隐藏项（隐藏 / 系统属性，或点开头）。Tab 进（补成「路径\名字\」）、Shift+Tab 回上一级。
// 这里只管字符串和排序，读文件夹在 Launcher/LauncherModel（线程池，网络路径 1 秒没回就不列）。
namespace KittyTools.Core;

public static class PathBrowse
{
    /// <summary>一个文件夹最多列多少项（ponytail：再多的要往下打字筛；要更多就把列表改成分页）。</summary>
    public const int MaxEntries = 500;

    /// <summary>输入拆成：它写的那个文件夹（原样，补全时接着用）、展开后的真实文件夹、最后没打完的那段。不是路径写法返回 null。</summary>
    public readonly record struct Parsed(string Typed, string Folder, string Partial)
    {
        public bool IsNetwork => Folder.StartsWith(@"\\", StringComparison.Ordinal);
    }

    public readonly record struct Entry(string Name, bool IsFolder, bool IsHidden);

    /// <param name="home">用户文件夹（~ 换成它）。</param>
    /// <param name="variable">%名字% 换成什么；没有这个变量返回 null（那就不是路径）。</param>
    public static Parsed? Parse(string query, string home, Func<string, string?> variable)
    {
        var text = query.TrimStart().Replace('/', '\\');
        var cut = text.LastIndexOf('\\');
        if (cut < 0 || !LooksLikePath(text))
        {
            return null;
        }

        var typed = text[..(cut + 1)];
        var partial = text[(cut + 1)..];
        string folder;
        if (typed.StartsWith(@"~\", StringComparison.Ordinal))
        {
            folder = home.TrimEnd('\\') + typed[1..];
        }
        else if (typed.StartsWith('%'))
        {
            var close = typed.IndexOf('%', 1);
            if (close < 2 || variable(typed[1..close]) is not { Length: > 0 } value)
            {
                return null;
            }

            folder = value.TrimEnd('\\') + typed[(close + 1)..];
        }
        else
        {
            folder = typed;
        }

        // 「C:\a\\b」这种连着的分隔符并成一个（网络路径开头的两个留着）
        var head = folder.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\" : string.Empty;
        var rest = folder[head.Length..];
        while (rest.Contains(@"\\", StringComparison.Ordinal))
        {
            rest = rest.Replace(@"\\", @"\", StringComparison.Ordinal);
        }

        return new Parsed(typed, head + rest, partial);
    }

    /// <summary>盘符（C:\）、~\、%变量%\、\\服务器\共享\ 开头。</summary>
    public static bool LooksLikePath(string text)
    {
        if (text.Length >= 3 && char.IsAsciiLetter(text[0]) && text[1] == ':' && text[2] == '\\')
        {
            return true;
        }

        if (text.StartsWith(@"~\", StringComparison.Ordinal))
        {
            return true;
        }

        if (text.StartsWith('%') && text.IndexOf('%', 1) is var close and > 1 && close + 1 < text.Length && text[close + 1] == '\\')
        {
            return true;
        }

        // \\服务器\共享\：至少到共享那一层才列（只打了服务器名的列不出来）
        return text.StartsWith(@"\\", StringComparison.Ordinal) && text.Length > 2 &&
               text.IndexOf('\\', 2) is var share and > 2 && text.IndexOf('\\', share + 1) > share + 1;
    }

    /// <summary>
    /// 按没打完的那段筛、排：文件夹在前、按名字（不分大小写）；开头对上的都算，名字中间对上的至少两个字；
    /// 没打「.」开头时不列隐藏项。最多 MaxEntries 项。
    /// </summary>
    public static List<Entry> Filter(IEnumerable<Entry> entries, string partial)
    {
        var showHidden = partial.StartsWith('.');
        return entries
            .Where(entry => showHidden || !entry.IsHidden)
            .Where(entry => partial.Length == 0 ||
                            entry.Name.StartsWith(partial, StringComparison.OrdinalIgnoreCase) ||
                            (partial.Length >= 2 && entry.Name.Contains(partial, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(entry => entry.IsFolder ? 0 : 1)
            .ThenBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase)
            .Take(MaxEntries)
            .ToList();
    }

    /// <summary>名字是不是隐藏项：点开头，或者带隐藏 / 系统属性。</summary>
    public static bool IsHidden(string name, FileAttributes attributes)
        => name.StartsWith('.') || (attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0;

    /// <summary>Tab 进：文件夹补成「写的那个文件夹 + 名字\」，文件补成「写的那个文件夹 + 名字」（保留 ~\、%变量%\ 的写法）。</summary>
    public static string Completion(Parsed parsed, Entry entry) => parsed.Typed + entry.Name + (entry.IsFolder ? @"\" : string.Empty);

    /// <summary>
    /// 终端里的写法（L2「复制终端写法的路径」）：PowerShell 的单引号字符串，里面的单引号写两遍；
    /// 单引号里 $、`、空格都不展开。
    /// </summary>
    public static string PowerShellQuoted(string path) => "'" + path.Replace("'", "''", StringComparison.Ordinal) + "'";

    /// <summary>
    /// Shift+Tab 回上一级：先去掉没打完的那段；已经是「…\」就去掉最后一层。到了根（C:\、~\、%变量%\、\\服务器\共享\）不再往上，返回 null。
    /// </summary>
    public static string? Up(string query)
    {
        var text = query.TrimStart().Replace('/', '\\');
        if (!LooksLikePath(text))
        {
            return null;
        }

        var cut = text.LastIndexOf('\\');
        if (cut + 1 < text.Length)
        {
            return text[..(cut + 1)];
        }

        var previous = text.LastIndexOf('\\', Math.Max(0, cut - 1));
        if (previous < 0)
        {
            return null;
        }

        var up = text[..(previous + 1)];
        return LooksLikePath(up) && up.Length < text.Length ? up : null;
    }
}
