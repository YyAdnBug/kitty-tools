// 剪贴板列表的一行：标题 / 副标题 / 时间 / 日期分隔 / 收藏标记，给 x:Bind 用的只读属性。
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools;

public sealed class ClipRow
{
    private static readonly SolidColorBrush ClipboardBlue =
        new(Color.FromArgb(32, 59, 130, 246));

    private ClipRow()
    {
    }

    public string Title { get; private init; } = string.Empty;

    public string Subtitle { get; private init; } = string.Empty;

    public string Time { get; private init; } = string.Empty;

    public string DateHeader { get; private init; } = string.Empty;

    public Visibility DateHeaderVisibility { get; private init; }

    public string Glyph { get; private init; } = string.Empty;

    public Brush IconBackground { get; private init; } = ClipboardBlue;

    public Visibility FavoriteVisibility { get; private init; }

    internal ClipEntry Entry { get; private init; } = null!;

    internal static ClipRow Create(ClipEntry entry, bool showDateHeader, string query = "")
    {
        return new ClipRow
        {
            Entry = entry,
            Title = TitleOf(entry),
            Subtitle = SubtitleOf(entry),
            Glyph = GlyphOf(entry),
            Time = TimeLabel(entry.CopiedAt),
            DateHeader = showDateHeader ? DateLabel(entry.CopiedAt) : string.Empty,
            DateHeaderVisibility = HeaderVisibility(showDateHeader),
            FavoriteVisibility = FavoriteVisibilityOf(entry),
        };
    }

    /// <summary>
    /// 这一行和「同一条条目、同样的日期分隔」画出来是不是一模一样。
    /// 面板按键搜索时靠它找出可以沿用的前缀，不再整表重建 ItemsSource（第二版 §2 P3）。
    /// </summary>
    internal bool SameAs(ClipEntry entry, bool showDateHeader)
        => ReferenceEquals(Entry, entry) &&
           Time == TimeLabel(entry.CopiedAt) &&
           DateHeaderVisibility == HeaderVisibility(showDateHeader) &&
           FavoriteVisibility == FavoriteVisibilityOf(entry) &&
           Subtitle == SubtitleOf(entry) &&
           Title == TitleOf(entry);

    private static string TitleOf(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => $"图片 {entry.Width} × {entry.Height}",
        ClipKind.Files => FilesTitle(entry).Title,
        _ => OneLine(entry.Text ?? string.Empty),
    };

    private static string GlyphOf(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => "\uEB9F",
        ClipKind.Files => FilesTitle(entry).Glyph,
        _ => "\uE8C8",
    };

    private static string SubtitleOf(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => Size(entry.ImageBytes) + SourceSuffix(entry),
        ClipKind.Files => SourceSuffix(entry).TrimStart(' ', '·'),
        _ => $"{entry.Text?.Length ?? 0} 字" + SourceSuffix(entry),
    };

    private static string TimeLabel(long copiedAt)
        => DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime().ToString("HH:mm");

    private static Visibility HeaderVisibility(bool showDateHeader)
        => showDateHeader ? Visibility.Visible : Visibility.Collapsed;

    private static Visibility FavoriteVisibilityOf(ClipEntry entry)
        => entry.Favorite ? Visibility.Visible : Visibility.Collapsed;

    public static string DateLabel(long copiedAt)
    {
        var local = DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime().Date;
        var today = DateTime.Today;
        if (local == today)
        {
            return "今天";
        }

        if (local == today.AddDays(-1))
        {
            return "昨天";
        }

        return local.Year == today.Year ? $"{local.Month} 月 {local.Day} 日" : $"{local.Year} 年 {local.Month} 月 {local.Day} 日";
    }

    private static string OneLine(string text)
    {
        var builder = new System.Text.StringBuilder(Math.Min(text.Length, 120));
        var lastSpace = false;
        foreach (var ch in text)
        {
            var space = char.IsWhiteSpace(ch);
            if (space && lastSpace)
            {
                continue;
            }

            builder.Append(space ? ' ' : ch);
            lastSpace = space;
            if (builder.Length >= 120)
            {
                builder.Append('…');
                break;
            }
        }

        var result = builder.ToString().Trim();
        return result.Length == 0 ? "（空白）" : result;
    }

    private static (string Title, string Glyph) FilesTitle(ClipEntry entry)
    {
        var files = entry.Files;
        if (files.Length == 0)
        {
            return ("文件", "\uE8B7");
        }

        var name = Path.GetFileName(files[0]);
        return (files.Length == 1 ? name : $"{name} 等 {files.Length} 个文件", "\uE8B7");
    }

    private static string SourceSuffix(ClipEntry entry)
        => string.IsNullOrEmpty(entry.SourceName) ? string.Empty : " · " + entry.SourceName;

    private static string Size(int bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:F1} KB",
        _ => $"{bytes / 1_048_576.0:F1} MB",
    };
}
