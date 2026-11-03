// 图片文件：images\<id>.png；按 PNG 字节的 SHA-256 去重（同样的内容只会有一张图进库）。
// 编码在后台做，这里只负责落盘、删文件和清理没有条目的孤儿文件。
// REVIEW R48：写盘和算哈希在线程池上（Stage），入库拿到编号后 UI 线程只换个名（Adopt）；单张图最多 128 MB，以前整张在 UI 线程上写、算两遍哈希。
using System.Security.Cryptography;

namespace KittyTools;

internal sealed class ImageStore
{
    private readonly string _directory;

    public ImageStore(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(_directory);
    }

    public string PathFor(long id) => Path.Combine(_directory, $"{id}.png");

    public bool Exists(long id) => File.Exists(PathFor(id));

    /// <summary>先写到 images\staged-*.tmp、算好 SHA-256（小写十六进制）。在线程池上调；入库后 Adopt，查重命中就 Discard。</summary>
    public (string Hash, string Staged) Stage(byte[] png)
    {
        Directory.CreateDirectory(_directory);
        var staged = Path.Combine(_directory, $"staged-{Guid.NewGuid():N}.tmp");
        File.WriteAllBytes(staged, png);
        return (Hash(png), staged);
    }

    /// <summary>暂存的那份换成这一条的图（原子替换，同一个盘上只是改名）。</summary>
    public void Adopt(long id, string staged)
    {
        var path = PathFor(id);
        if (File.Exists(path))
        {
            File.Replace(staged, path, null);
        }
        else
        {
            File.Move(staged, path);
        }
    }

    public static void Discard(string staged)
    {
        try
        {
            File.Delete(staged);
        }
        catch
        {
            // 删不掉就留着，下次启动清孤儿时再试。
        }
    }

    public void Delete(long id)
    {
        try
        {
            File.Delete(PathFor(id));
        }
        catch
        {
            // 删不掉就留着，下次启动清孤儿时再试。
        }
    }

    /// <summary>库里已经没有的图片顺手删掉（启动时调）。</summary>
    public int CleanupOrphans(IReadOnlyCollection<long> keep)
    {
        var deleted = 0;
        // 暂存了还没入库就退出 / 闪退留下的（Stage）。
        foreach (var file in Directory.EnumerateFiles(_directory, "staged-*.tmp"))
        {
            Discard(file);
        }

        foreach (var file in Directory.EnumerateFiles(_directory, "*.png"))
        {
            var name = Path.GetFileNameWithoutExtension(file);
            if (!long.TryParse(name, out var id) || !keep.Contains(id))
            {
                try
                {
                    File.Delete(file);
                    deleted++;
                }
                catch
                {
                    // 被别的程序占着就下次再删。
                }
            }
        }

        return deleted;
    }

    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
