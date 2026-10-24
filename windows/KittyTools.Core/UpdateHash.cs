// 更新包的校验（纯函数 + 文件哈希，配单测）：release 里附的 `.sha256` 长这样（和 sha256sum 一致）：
//   <64 位十六进制>  KittyTools-0.1.1-windows-x64.zip
// 也可能只有一行哈希。按文件名找对应那一行；找不到就返回 null（宁可不更新）。
using System.Security.Cryptography;

namespace KittyTools.Core;

public static class UpdateHash
{
    /// <summary>从 .sha256 文件内容里取某个文件的期望哈希（小写十六进制）；格式不对返回 null。</summary>
    public static string? ExpectedFor(string sha256FileText, string assetFileName)
    {
        if (string.IsNullOrWhiteSpace(sha256FileText))
        {
            return null;
        }

        string? single = null;
        foreach (var raw in sha256FileText.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length == 0)
            {
                continue;
            }

            var space = line.IndexOfAny(new[] { ' ', '\t', '*' });
            var hash = space < 0 ? line : line[..space];
            if (!IsHex(hash))
            {
                continue;
            }

            if (space < 0)
            {
                single = hash;
                continue;
            }

            var name = line[(space + 1)..].Trim().TrimStart('*');
            if (string.Equals(name, assetFileName, StringComparison.OrdinalIgnoreCase))
            {
                return hash.ToLowerInvariant();
            }
        }

        // 只有一行、没写文件名的也认（不多见，但各家发布脚本不一样）。
        return single?.ToLowerInvariant();
    }

    public static bool IsHex(string? value)
        => value is { Length: 64 } && value.All(Uri.IsHexDigit);

    /// <summary>算文件的 SHA-256（小写十六进制）。</summary>
    public static string ComputeFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    public static bool FileMatches(string path, string expectedHex)
    {
        if (!IsHex(expectedHex) || !File.Exists(path))
        {
            return false;
        }

        return string.Equals(ComputeFile(path), expectedHex, StringComparison.OrdinalIgnoreCase);
    }
}
