// 启动器搜得到便携软件（PLAN-v18 §6 = PLAN-v16 §4 A3 A5，Windows 独有；纯函数，配单测）：
// - UserAssist（资源管理器记的「运行过的程序」）：值名是 ROT13 编码的路径，开头可能是已知文件夹的 GUID（App 侧用 SHGetKnownFolderPath 换）；
//   值是 72 字节，偏移 4 的 uint 是运行次数、偏移 60 的 FILETIME 是最后运行时刻。
// - 哪些 exe 不收：卸载、安装、更新、崩溃报告这类（按文件名、按文件说明猜）。
// ponytail: 按名字猜，漏的靠用户在启动器里「从启动器里隐藏」；名单宁短，7zFM.exe 这类有用的不能误伤。
namespace KittyTools.Core;

public readonly record struct UserAssistEntry(string Path, uint RunCount, DateTime? LastRunUtc);

public static class PortableApps
{
    /// <summary>UserAssist 里程序那一组（{CEBFF5CD-…}，可执行文件）。</summary>
    public const string ExecutablesKey =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}\Count";

    /// <summary>ROT13（只换 ASCII 字母，别的原样）。</summary>
    public static string Rot13(string text)
        => string.Create(text.Length, text, static (span, source) =>
        {
            for (var index = 0; index < source.Length; index++)
            {
                var ch = source[index];
                span[index] = ch switch
                {
                    >= 'a' and <= 'z' => (char)('a' + (ch - 'a' + 13) % 26),
                    >= 'A' and <= 'Z' => (char)('A' + (ch - 'A' + 13) % 26),
                    _ => ch,
                };
            }
        });

    /// <summary>
    /// 一条 UserAssist：值名（ROT13 过的）和 72 字节的值 → 路径、次数、最后运行时刻；值不是 72 字节、没运行过的返回 null。
    /// knownFolder：值名开头是「{GUID}\」时把 GUID 换成真路径（换不出来返回 null，这一条跳过）。
    /// </summary>
    public static UserAssistEntry? Parse(string encodedName, byte[]? value, Func<Guid, string?> knownFolder)
    {
        if (value is not { Length: 72 })
        {
            return null;
        }

        var count = BitConverter.ToUInt32(value, 4);
        if (count == 0)
        {
            return null;
        }

        var path = Rot13(encodedName);
        if (path.StartsWith('{') && path.IndexOf('}') is var close and > 0 && Guid.TryParse(path[..(close + 1)], out var guid))
        {
            if (knownFolder(guid) is not { Length: > 0 } folder)
            {
                return null;
            }

            path = folder.TrimEnd('\\') + path[(close + 1)..];
        }

        var time = BitConverter.ToInt64(value, 60);
        DateTime? last = time > 0 && time < DateTime.MaxValue.ToFileTimeUtc() ? DateTime.FromFileTimeUtc(time) : null;
        return new UserAssistEntry(path, count, last);
    }

    private static readonly string[] JunkNames =
    {
        "unins", "uninstall", "setup", "install", "update", "updater", "upgrade", "crash", "report", "helper", "elevate",
        "vc_redist", "dxsetup",
    };

    private static readonly string[] JunkDescriptions = { "卸载", "安装", "更新", "uninstall", "setup", "installer", "updater" };

    /// <summary>这个 exe 不该当成 App（卸载、安装、更新、崩溃报告、提权助手…）：按文件名、文件说明猜。</summary>
    public static bool IsJunk(string path, string? description)
    {
        var name = System.IO.Path.GetFileNameWithoutExtension(path).ToLowerInvariant();
        if (JunkNames.Any(name.Contains))
        {
            return true;
        }

        var text = description?.ToLowerInvariant() ?? string.Empty;
        return JunkDescriptions.Any(word => text.Contains(word, StringComparison.Ordinal));
    }

    /// <summary>
    /// UserAssist 里这一条收不收：绝对路径、.exe、不在 Windows 目录和本 App 的目录下（文件在不在、过滤名单由调用方再看）。
    /// </summary>
    public static bool IsCandidate(string path, string windowsDirectory, string ownDirectory)
    {
        if (!System.IO.Path.IsPathFullyQualified(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        static bool Under(string path, string folder)
            => folder.Length > 0 && path.StartsWith(folder.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
        return !Under(path, windowsDirectory) && !Under(path, ownDirectory);
    }

    /// <summary>
    /// 同一个文件夹里文件说明一样的只留一个（xxx.exe 和 xxx64.exe 留 64 位那个）。items：（路径，文件说明）。返回留下的路径，顺序同输入。
    /// </summary>
    public static List<string> OnePerDescription(IEnumerable<(string Path, string? Description)> items)
    {
        var list = items.ToList();
        var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in list.GroupBy(item => (
                     System.IO.Path.GetDirectoryName(item.Path)?.ToLowerInvariant() ?? string.Empty,
                     string.IsNullOrWhiteSpace(item.Description) ? item.Path.ToLowerInvariant() : item.Description.Trim().ToLowerInvariant())))
        {
            var best = group.OrderByDescending(item => System.IO.Path.GetFileNameWithoutExtension(item.Path).Contains("64", StringComparison.Ordinal))
                .ThenBy(item => item.Path.Length)
                .First();
            keep.Add(best.Path);
        }

        return list.Where(item => keep.Contains(item.Path)).Select(item => item.Path).ToList();
    }
}
