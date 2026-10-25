// 导出文件的自动备份轮换（第三版 §2.2，纯函数，配单测）：文件名里带日期 / 时间，按名字倒序留最新的几份。
namespace KittyTools.Core;

public static class ArchiveRotation
{
    /// <summary>该删哪几份：按文件名（序数）倒序，留下前 keep 份；刚写的那份永远不删。</summary>
    public static List<string> Expired(IEnumerable<string> files, int keep, string? written = null)
        => files
            .OrderByDescending(path => Path.GetFileName(path), StringComparer.Ordinal)
            .Skip(Math.Max(keep, 1))
            .Where(path => written is null ||
                           !string.Equals(
                               Path.GetFullPath(path), Path.GetFullPath(written),
                               StringComparison.OrdinalIgnoreCase))
            .ToList();
}
