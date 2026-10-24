// 图片文件：images\<id>.png；按 PNG 字节的 SHA-256 去重（同样的内容只会有一张图进库）。
// 编码在后台做，这里只负责落盘、删文件和清理没有条目的孤儿文件。
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

    /// <summary>写图片（原子替换）；返回 PNG 字节的 SHA-256（小写十六进制）。</summary>
    public string Save(long id, byte[] png)
    {
        Directory.CreateDirectory(_directory);
        var path = PathFor(id);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, png);
        if (File.Exists(path))
        {
            File.Replace(temporary, path, null);
        }
        else
        {
            File.Move(temporary, path);
        }

        return Hash(png);
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
