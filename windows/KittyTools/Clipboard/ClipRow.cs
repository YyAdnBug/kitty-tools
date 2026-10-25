// 剪贴板列表的一行：标题 / 副标题 / 时间 / 日期分隔 / 收藏标记，给 x:Bind 用的只读属性。
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools;

public sealed class ClipRow
{
    private static readonly SolidColorBrush ClipboardBlue =
        (SolidColorBrush)Theme.Family.Tint(Theme.Family.Clipboard, 32);

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

    /// <summary>右边的「来源 · 多久前」（PLAN-v2 §3.5）。</summary>
    public string RightText { get; private init; } = string.Empty;

    /// <summary>按住 Ctrl 时右侧浮现的数字键帽。</summary>
    public string KeyHint { get; private init; } = string.Empty;

    public Visibility KeyHintVisibility { get; private init; } = Visibility.Collapsed;

    internal ClipEntry Entry { get; private init; } = null!;

    internal static ClipRow Create(
        ClipEntry entry,
        bool showDateHeader,
        int index = -1,
        bool showKeyHint = false,
        string query = "")
    {
        var right = Relative(entry.CopiedAt);
        return new ClipRow
        {
            Entry = entry,
            Title = TitleOf(entry),
            Subtitle = SubtitleOf(entry),
            Glyph = GlyphOf(entry),
            Time = TimeLabel(entry.CopiedAt),
            RightText = right,
            KeyHint = showKeyHint && index is >= 0 and < 9 ? (index + 1).ToString() : string.Empty,
            KeyHintVisibility = showKeyHint && index is >= 0 and < 9 ? Visibility.Visible : Visibility.Collapsed,
            DateHeader = showDateHeader ? DateLabel(entry.CopiedAt) : string.Empty,
            DateHeaderVisibility = HeaderVisibility(showDateHeader),
            FavoriteVisibility = FavoriteVisibilityOf(entry),
        };
    }

    /// <summary>
    /// 这一行和「同一条条目、同样的日期分隔」画出来是不是一模一样。
    /// 面板按键搜索时靠它找出可以沿用的前缀，不再整表重建 ItemsSource（第二版 §2 P3）。
    /// </summary>
    internal bool SameAs(ClipEntry entry, bool showDateHeader, int index, bool showKeyHint)
        => ReferenceEquals(Entry, entry) &&
           Time == TimeLabel(entry.CopiedAt) &&
           DateHeaderVisibility == HeaderVisibility(showDateHeader) &&
           FavoriteVisibility == FavoriteVisibilityOf(entry) &&
           Subtitle == SubtitleOf(entry) &&
           RightText == Relative(entry.CopiedAt) &&
           KeyHint == (showKeyHint && index is >= 0 and < 9 ? (index + 1).ToString() : string.Empty) &&
           KeyHintVisibility == (showKeyHint && index is >= 0 and < 9 ? Visibility.Visible : Visibility.Collapsed) &&
           Title == TitleOf(entry);

    /// <summary>行右栏只放短时间（REVIEW R6）：列表窄，标题要占六成以上；来源在预览卡的卡头显示。</summary>
    internal static string Relative(long copiedAt)
    {
        var then = DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime();
        var span = DateTimeOffset.Now - then;
        if (span.TotalSeconds < 60)
        {
            return "刚刚";
        }

        if (span.TotalMinutes < 60)
        {
            return $"{(int)span.TotalMinutes} 分钟前";
        }

        if (then.Date == DateTime.Today)
        {
            return $"{(int)span.TotalHours} 小时前";
        }

        if (then.Date == DateTime.Today.AddDays(-1))
        {
            return "昨天";
        }

        return then.Date.Year == DateTime.Today.Year
            ? then.ToString("MM-dd")
            : then.ToString("yyyy-MM-dd");
    }

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
