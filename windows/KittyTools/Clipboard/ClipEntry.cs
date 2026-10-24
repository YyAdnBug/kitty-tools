// 剪贴板条目：内存里的样子（DB 行和它的映射见 Database.cs）。
// 正文、来源和文件名拼成搜索用的折叠文本，按需缓存（5000 条搜一次在 10 ms 量级）。
using KittyTools.Core;

namespace KittyTools;

internal sealed class ClipEntry
{
    public long Id { get; set; }

    public ClipKind Kind { get; set; }

    public string? Text { get; set; }

    /// <summary>文件类：路径用换行拼起来。</summary>
    public string? FilePaths { get; set; }

    public string? ImageHash { get; set; }

    public int Width { get; set; }

    public int Height { get; set; }

    public int ImageBytes { get; set; }

    public string? SourceExe { get; set; }

    public string? SourceName { get; set; }

    public long CopiedAt { get; set; }

    public bool Favorite { get; set; }

    /// <summary>搜索用的折叠文本（Search.FoldBytes），第一次搜索时建。</summary>
    public byte[]? Folded { get; set; }

    public string[] Files
        => string.IsNullOrEmpty(FilePaths)
            ? Array.Empty<string>()
            : FilePaths.Split('\n', StringSplitOptions.RemoveEmptyEntries);

    public bool HasSameContent(ClipEntry other)
    {
        if (Kind != other.Kind)
        {
            return false;
        }

        return Kind switch
        {
            ClipKind.Image => !string.IsNullOrEmpty(ImageHash) && ImageHash == other.ImageHash,
            ClipKind.Files => string.Equals(FilePaths, other.FilePaths, StringComparison.OrdinalIgnoreCase),
            _ => string.Equals(Text, other.Text, StringComparison.Ordinal),
        };
    }

    public string SearchSource => Kind switch
    {
        ClipKind.Image => string.Join('\n', new[]
        {
            $"图片 {Width} {Height}",
            SourceName,
            SourceExe,
        }.Where(s => !string.IsNullOrEmpty(s))),
        ClipKind.Files => string.Join('\n', new[] { FilePaths, SourceName, SourceExe }.Where(s => !string.IsNullOrEmpty(s))),
        _ => string.Join('\n', new[] { Text, SourceName, SourceExe }.Where(s => !string.IsNullOrEmpty(s))),
    };

    public RetentionItem ToRetentionItem()
        => new(Id.ToString(), Kind, CopiedAt, ImageBytes, Favorite);
}
