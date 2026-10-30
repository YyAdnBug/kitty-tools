// 同步文件夹的读写（PLAN-v5 §2.1–§2.3；REVIEW R26 从 App 挪进 Core，执行层的集成测试直接用它）：
// 只写自己的子文件夹；云盘还没下载的占位文件不读（当成没有）；单个文件超过 SyncFile.MaxBytes 不读；
// 写一律「临时文件 + 替换」。
namespace KittyTools.Core.Sync;

public sealed class SyncDisk(string root)
{
    // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS：云盘的占位文件，一读就开始下载、会卡住。
    private const FileAttributes RecallOnDataAccess = (FileAttributes)0x400000;

    public string Root { get; } = root;

    public bool IsUsable => Directory.Exists(Root);

    public static bool IsPlaceholder(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return (attributes & RecallOnDataAccess) != 0 || (attributes & FileAttributes.Offline) != 0;
        }
        catch
        {
            return true;
        }
    }

    public bool Exists(string relative) => File.Exists(Path.Combine(Root, relative));

    public string? ReadText(string relative)
    {
        var path = Path.Combine(Root, relative);
        try
        {
            if (!File.Exists(path) || IsPlaceholder(path) || new FileInfo(path).Length > SyncFile.MaxBytes)
            {
                return null;
            }

            return File.ReadAllText(path);
        }
        catch
        {
            return null;
        }
    }

    public bool WriteText(string relative, string text)
    {
        var path = Path.Combine(Root, relative);
        var temporary = path + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(temporary, text);
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public string? Marker() => ReadText(SyncFolderRules.MarkerFile) is { } text
        ? SyncFolderRules.ParseMarker(text)
        : null;

    public List<string> DeviceIds()
    {
        var folder = Path.Combine(Root, SyncFolderRules.DevicesFolder);
        try
        {
            return Directory.Exists(folder)
                ? Directory.EnumerateDirectories(folder)
                    .Select(Path.GetFileName)
                    .Where(name => name is not null && SyncFolderRules.IsDeviceName(name))
                    .Select(name => name!)
                    .ToList()
                : new List<string>();
        }
        catch
        {
            return new List<string>();
        }
    }

    /// <summary>里面有东西却连标记都没有：不是我们的文件夹，不碰。</summary>
    public bool LooksForeign()
    {
        if (Marker() is not null)
        {
            return false;
        }

        try
        {
            return Directory.Exists(Root) && Directory.EnumerateFileSystemEntries(Root).Any();
        }
        catch
        {
            return true;
        }
    }

    /// <summary>
    /// 一轮要读的那几个文件现在的样子：标记、每台的 device.json 和这几类的文件，各记路径、修改时间、大小（没有的记 -）。
    /// 和上一轮什么都没剩下时的一样，这一轮就不用整份读、整份合（REVIEW R49）。只读属性，云盘的占位文件不会因此开始下载。
    /// </summary>
    public string Fingerprint(IEnumerable<string> kinds)
    {
        var builder = new System.Text.StringBuilder();
        void Add(string relative)
        {
            var info = new FileInfo(Path.Combine(Root, relative));
            builder.Append(relative).Append('=')
                .Append(info.Exists ? $"{info.LastWriteTimeUtc.Ticks}:{info.Length}" : "-")
                .Append('\n');
        }

        var wanted = kinds.ToList();
        Add(SyncFolderRules.MarkerFile);
        foreach (var device in DeviceIds().OrderBy(id => id, StringComparer.Ordinal))
        {
            Add(DevicePath(device));
            foreach (var kind in wanted)
            {
                Add(KindPath(device, kind));
            }
        }

        return builder.ToString();
    }

    public static string DevicePath(string device)
        => Path.Combine(SyncFolderRules.DevicesFolder, device, SyncFolderRules.DeviceFile);

    public static string KindPath(string device, string kind)
        => Path.Combine(SyncFolderRules.DevicesFolder, device, SyncFolderRules.FileName(kind));
}
