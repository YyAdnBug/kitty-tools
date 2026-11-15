// 一条路径「真正」指到哪（PLAN-v20 N2，mac resolvingSymlinksInPath，配单测）：从盘符起一级一级往下，碰到符号链接或目录联接
// （junction）就换成它指的地方，整条解析完再拿去比。便签导入 Markdown 的图片要在导入的文件夹里：原来只看最后那个文件是不是链接，
// 文件夹里一个联接指到外面（比如 C:\Users\某人），「图片/../../x.png」这类就能把外面的文件带进来。
// 联接套联接最多解 32 次（转圈的给 null）；路径上哪一级读不了也给 null（宁可不导入这张图）。
namespace KittyTools.Core;

public static class RealPath
{
    private const int MaxLinks = 32;

    /// <summary>解析完的完整路径；解析不了（转圈、读不了）给 null。</summary>
    public static string? Resolve(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            var root = Path.GetPathRoot(full);
            if (string.IsNullOrEmpty(root))
            {
                return null;
            }

            var current = root;
            var parts = new Queue<string>(full[root.Length..].Split(
                new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries));
            var links = 0;
            while (parts.Count > 0)
            {
                var next = Path.Combine(current, parts.Dequeue());
                FileSystemInfo info = Directory.Exists(next) ? new DirectoryInfo(next) : new FileInfo(next);
                if (info.Exists && info.LinkTarget is { } target)
                {
                    if (++links > MaxLinks)
                    {
                        return null;
                    }

                    // 联接 / 链接指的地方可能是相对的（相对链接本身所在的文件夹）；指的地方里可能还有链接，接着往下解
                    var resolved = Path.GetFullPath(Path.IsPathRooted(target) ? target : Path.Combine(current, target));
                    var rest = parts.ToArray();
                    var newRoot = Path.GetPathRoot(resolved);
                    if (string.IsNullOrEmpty(newRoot))
                    {
                        return null;
                    }

                    current = newRoot;
                    parts = new Queue<string>(resolved[newRoot.Length..]
                        .Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries)
                        .Concat(rest));
                    continue;
                }

                current = next;
            }

            return current;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>file 解析完在 folder（也解析完）里面。</summary>
    public static bool IsInside(string file, string folder)
    {
        if (Resolve(file) is not { } real || Resolve(folder) is not { } bas)
        {
            return false;
        }

        bas = bas.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return real.StartsWith(bas, StringComparison.OrdinalIgnoreCase);
    }
}
