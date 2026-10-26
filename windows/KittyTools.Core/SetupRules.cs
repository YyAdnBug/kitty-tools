// 安装程序的规矩（PLAN-setup §2.2–§2.4，纯函数 + 单测）：装到哪、哪里不许装、卸载时能不能整个删、
// 标记文件 .kitty-install、「设置 › 应用」里登记的值、测试用的名字。
// 路径一律按 Windows 的写法处理（反斜杠、不分大小写），不依赖运行平台的 Path，所以在 Mac 上也能单测；
// 系统文件夹由调用方传进来（SetupFolders）。
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core;

/// <summary>
/// System：它们本身和下面都不许装（Windows、Program Files 那几个）；
/// Personal：只是它们本身不许（用户主目录、桌面、文档、下载、图片、音乐、视频）。
/// </summary>
public sealed record SetupFolders(IReadOnlyList<string> System, IReadOnlyList<string> Personal);

/// <summary>.kitty-install 的内容。Files 是装进去的文件（相对路径），卸载时认得哪些是我们的。</summary>
public sealed record SetupMarker(string Path, string Version, long InstalledAt, IReadOnlyList<string> Files);

/// <summary>注册表里的一个值：Number 不为 null 时是 REG_DWORD，否则是 REG_SZ。</summary>
public sealed record SetupRegistryValue(string Name, string? Text, int? Number);

/// <summary>
/// 正式版和测试用的名字。测试名和 App 的 KITTY_PROBE_PROFILE 那一套对齐（互斥量、管道、开机启动值、凭据前缀、数据目录都是
/// 「.Probe.&lt;名字&gt;」），端到端测试用同一个名字开 App，安装程序就能叫它退出、卸载时删的也是它那一份。
/// </summary>
public sealed record SetupNames(
    string UninstallKey,
    string RunValue,
    string ShortcutFile,
    string CredentialPrefix,
    string MutexName,
    string PipeName,
    string DataFolder,
    string LogFile,
    string? ProbeProfile);

/// <summary>卸载时删什么：整个文件夹，或者只删认得的那几个文件（相对路径）。</summary>
public sealed record SetupRemoval(bool WholeDirectory, IReadOnlyList<string> Files);

public static class SetupRules
{
    public const string FolderName = "Kitty Tools";

    public const string ExeName = "KittyTools.exe";

    public const string UninstallerName = "Uninstall.exe";

    public const string MarkerName = ".kitty-install";

    public const int MaxInstallPathLength = 200;

    public const string UninstallRoot = @"Software\Microsoft\Windows\CurrentVersion\Uninstall";

    public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public const string TestKeyVariable = "KITTY_SETUP_TEST_KEY";

    public const string Homepage = "https://github.com/YyAdnBug/kitty-tools";

    /// <summary>测试名：1–32 个 ASCII 字母或数字（和 App 的 KITTY_PROBE_PROFILE 同一个规矩）。</summary>
    public static bool IsValidTestKey(string key) => key.Length is >= 1 and <= 32 && key.All(char.IsAsciiLetterOrDigit);

    /// <summary>testKey 为 null 或空是正式版的名字；不合规的测试名直接抛，免得退回正式名去碰用户真实的注册表。</summary>
    public static SetupNames NamesFor(string? testKey)
    {
        if (string.IsNullOrEmpty(testKey))
        {
            return new SetupNames(
                "KittyTools", "KittyTools", "Kitty Tools.lnk", "KittyTools/", @"Local\KittyTools",
                "KittyTools.Instance", "KittyTools", "KittyTools-setup.log", null);
        }

        if (!IsValidTestKey(testKey))
        {
            throw new ArgumentException($"{TestKeyVariable} 只能是 1–32 个字母或数字", nameof(testKey));
        }

        var suffix = ".Probe." + testKey;
        return new SetupNames(
            "KittyTools.Test." + testKey,
            "KittyTools" + suffix,
            $"Kitty Tools.Test.{testKey}.lnk",
            "KittyTools/" + suffix,
            @"Local\KittyTools" + suffix,
            "KittyTools.Instance" + suffix,
            "KittyTools" + suffix,
            $"KittyTools-setup.Test.{testKey}.log",
            testKey);
    }

    /// <summary>反斜杠、去掉末尾的分隔符（根目录 C:\ 保留）。不解析 . 和 ..：调用方先 GetFullPath。</summary>
    public static string Normalize(string path)
    {
        var text = path.Trim().Replace('/', '\\');
        while (text.Length > 3 && text.EndsWith('\\'))
        {
            text = text[..^1];
        }

        return text.Length == 2 && text[1] == ':' ? text + "\\" : text;
    }

    public static bool SamePath(string a, string b) => string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>选的文件夹名字不是「Kitty Tools」就在它下面拼一个，保证安装目录整个是我们的。</summary>
    public static string ResolveInstallDir(string chosen)
    {
        var dir = Normalize(chosen);
        return string.Equals(LastSegment(dir), FolderName, StringComparison.OrdinalIgnoreCase) ? dir : Join(dir, FolderName);
    }

    /// <summary>§2.2：驱动器根目录；System 本身和下面；Personal 本身。不是「盘符:\」开头的（网络路径等）也不许。</summary>
    public static bool IsForbiddenInstallDir(string path, SetupFolders folders)
    {
        var dir = Normalize(path);
        if (!IsDrivePath(dir) || dir.Length == 3)
        {
            return true;
        }

        return folders.System.Any(root => IsSameOrUnder(dir, root)) ||
               folders.Personal.Any(exact => SamePath(dir, exact));
    }

    /// <summary>ResolveInstallDir 之后的路径能不能用；能用返回 null，否则是给用户看的原因。写权限另由 UpdateInstaller 试。</summary>
    public static string? WhyNotInstallDir(string installDir, SetupFolders folders)
    {
        var dir = Normalize(installDir);
        if (!IsDrivePath(dir))
        {
            return "请选这台电脑磁盘上的文件夹。";
        }

        if (IsForbiddenInstallDir(dir, folders))
        {
            return "不能装在驱动器根目录、Windows 或 Program Files 里，也不能直接装在桌面、文档、下载这类文件夹本身。";
        }

        return dir.Length > MaxInstallPathLength ? "这个位置的路径太长，请选一个浅一点的文件夹。" : null;
    }

    /// <summary>installing 不比 installed 新（一样或更旧）：要问一句「重新安装」。installed 读不出来当更旧。</summary>
    public static bool IsSameOrOlder(string installing, string? installed)
        => Version.TryParse(installing, out var next) && Version.TryParse(installed, out var current) && next <= current;

    public static string WriteMarker(SetupMarker marker)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteString("path", marker.Path);
            writer.WriteString("version", marker.Version);
            writer.WriteNumber("installedAt", marker.InstalledAt);
            writer.WriteStartArray("files");
            foreach (var file in marker.Files)
            {
                writer.WriteStringValue(file);
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>更新后并文件清单（R38）：新装的文件并上旧的，大小写不敏感去重，版本换成新的。</summary>
    public static SetupMarker WithInstalledFiles(
        SetupMarker marker, string version, IEnumerable<string> installedRelative)
    {
        var files = marker.Files.ToList();
        var seen = new HashSet<string>(files, StringComparer.OrdinalIgnoreCase);
        foreach (var relative in installedRelative.Select(NormalizeRelative))
        {
            if (seen.Add(relative))
            {
                files.Add(relative);
            }
        }

        return marker with { Version = version, Files = files };
    }

    /// <summary>读 .kitty-install；结构不对返回 null。files 是后加的，没有就当空。</summary>
    public static SetupMarker? ParseMarker(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("path", out var path) || path.GetString() is not { Length: > 0 } pathText ||
                !root.TryGetProperty("version", out var version) || version.GetString() is not { } versionText ||
                !root.TryGetProperty("installedAt", out var at) || !at.TryGetInt64(out var installedAt))
            {
                return null;
            }

            var files = new List<string>();
            if (root.TryGetProperty("files", out var list) && list.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in list.EnumerateArray())
                {
                    if (item.GetString() is { Length: > 0 } file)
                    {
                        files.Add(file);
                    }
                }
            }

            return new SetupMarker(pathText, versionText, installedAt, files);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>安装目录里的 .kitty-install（App 用它判断自己是不是安装程序装的，PLAN-setup §4.2 / §4.3）。</summary>
    public static SetupMarker? ReadMarker(string installDir)
    {
        try
        {
            var file = System.IO.Path.Combine(installDir, MarkerName);
            return File.Exists(file) ? ParseMarker(File.ReadAllText(file, Encoding.UTF8)) : null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// §2.3：文件夹里有 KittyTools.exe、标记里记的就是这个文件夹、名字是「Kitty Tools」、不在禁止名单里，
    /// 而且没有不认得的文件，才整个删；否则只删认得的。present 是文件夹里现有文件的相对路径。
    /// </summary>
    public static SetupRemoval PlanRemoval(string installDir, IReadOnlyCollection<string> present, SetupMarker? marker, SetupFolders folders)
    {
        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ExeName, UninstallerName, MarkerName };
        if (marker is not null)
        {
            known.UnionWith(marker.Files.Select(NormalizeRelative));
        }

        bool IsKnown(string file)
        {
            var relative = NormalizeRelative(file);
            return known.Contains(relative) || relative.EndsWith(UpdateInstaller.OldSuffix, StringComparison.OrdinalIgnoreCase);
        }

        var ours = present.Where(IsKnown).ToList();
        var whole = present.Any(file => string.Equals(NormalizeRelative(file), ExeName, StringComparison.OrdinalIgnoreCase)) &&
                    marker is not null && SamePath(marker.Path, installDir) &&
                    string.Equals(LastSegment(Normalize(installDir)), FolderName, StringComparison.OrdinalIgnoreCase) &&
                    !IsForbiddenInstallDir(installDir, folders) &&
                    ours.Count == present.Count;
        return new SetupRemoval(whole, ours);
    }

    /// <summary>§2.4「设置 › 应用」里的登记。sizeKb 超过 DWORD 范围就封顶。</summary>
    public static IReadOnlyList<SetupRegistryValue> UninstallValues(string installDir, string version, long sizeKb, DateTime date)
    {
        var dir = Normalize(installDir);
        var uninstaller = Join(dir, UninstallerName);
        return
        [
            new("DisplayName", FolderName, null),
            new("DisplayVersion", version, null),
            new("Publisher", FolderName, null),
            new("DisplayIcon", Join(dir, ExeName) + ",0", null),
            new("InstallLocation", dir, null),
            new("UninstallString", $"\"{uninstaller}\"", null),
            new("QuietUninstallString", $"\"{uninstaller}\" --quiet", null),
            new("NoModify", null, 1),
            new("NoRepair", null, 1),
            new("EstimatedSize", null, (int)Math.Clamp(sizeKb, 0, int.MaxValue)),
            new("InstallDate", date.ToString("yyyyMMdd", CultureInfo.InvariantCulture), null),
            new("URLInfoAbout", Homepage, null),
        ];
    }

    /// <summary>文件夹里所有文件的大小，单位 KB（向上取整）；读不到的文件跳过。</summary>
    public static long DirectorySizeKb(string dir)
    {
        long bytes = 0;
        try
        {
            foreach (var file in new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories))
            {
                bytes += file.Length;
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }

        return (bytes + 1023) / 1024;
    }

    private static string NormalizeRelative(string path) => path.Replace('/', '\\').TrimStart('\\');

    private static bool IsDrivePath(string dir) => dir.Length >= 3 && char.IsAsciiLetter(dir[0]) && dir[1] == ':' && dir[2] == '\\';

    private static bool IsSameOrUnder(string dir, string root)
    {
        var parent = Normalize(root);
        if (parent.Length == 0)
        {
            return false;
        }

        if (string.Equals(dir, parent, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var prefix = parent.EndsWith('\\') ? parent : parent + "\\";
        return dir.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static string LastSegment(string dir)
    {
        var index = dir.LastIndexOf('\\');
        return index < 0 ? dir : dir[(index + 1)..];
    }

    private static string Join(string dir, string name) => dir.EndsWith('\\') ? dir + name : dir + "\\" + name;
}
