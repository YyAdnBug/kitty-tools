// 剪贴板行和透镜的几何（照 mac LensView.swift 的 Lens、ClipRowView.swift 的 title / showsWholeText；纯函数，配单测）。
// 透镜正文区按类型查表定高，不量内在尺寸：前缀和、跟随滚动、窗口的透镜预留都靠它算得准。
// 「标题已经显示全」要量字宽：量的那一下由调用方给（App 用 DirectWrite），这里只管规则和宽度预算。
namespace KittyTools.Core;

public static class ClipLens
{
    /// <summary>行头（= 行高）、元信息行、底。</summary>
    public const double Head = 40;

    public const double Meta = 22;

    public const double Bottom = 8;

    /// <summary>最高的透镜（代码 / JSON）比普通行多出来的：窗口一直按它预留，↑↓ 永远不改窗口高度。</summary>
    public const double Reserve = 128 + Meta + Bottom;

    /// <summary>行的左右内边距、行内间距、右侧文字最宽（布局和 ShowsWholeText 的宽度预算共用）。</summary>
    public const double RowPadding = 10;

    public const double RowSpacing = 10;

    public const double TrailingMax = 220;

    /// <summary>
    /// 标题列最窄时的宽度：面板 720 − 两边内缩 6 − 滚动条 16 − 行的左右内边距 − 图标块 24 − 三处间距 − 最窄的弹性空白 8
    /// − 右侧文字那一格（再短也占满 220）− 数字键帽（连它前面的间距）= 352（同 mac）。
    /// </summary>
    public const double TitleRoom = 720 - 2 * 6 - 16 - 2 * RowPadding - 24 - 3 * RowSpacing - 8 - TrailingMax - (RowSpacing + 28);

    /// <summary>正文区高度（查表，mac-whisker-clipboard「透镜」）；文本的 0 档要先量过标题（showsWholeText）。</summary>
    public static double BodyHeight(ClipKind kind, ContentForm? form, string? text, bool showsWholeText) => kind switch
    {
        ClipKind.Image => 108,
        ClipKind.Files => 76,
        _ => form switch
        {
            ContentForm.Color => 72,
            ContentForm.Code or ContentForm.Json => 128,
            ContentForm.Link => 90,
            _ => showsWholeText ? 0 : IsShort(text ?? string.Empty) ? 36 : 90,
        },
    };

    /// <summary>透镜总高 = 行头 + 正文 + 元信息 + 底（最高 198，标题已显示全的文本最矮 70）。</summary>
    public static double Height(ClipKind kind, ContentForm? form, string? text, bool showsWholeText)
        => Head + BodyHeight(kind, form, text, showsWholeText) + Meta + Bottom;

    /// <summary>没有换行且不超过 60 字：两行高就够，免得一行字下面空一大块。</summary>
    public static bool IsShort(string text)
    {
        var trimmed = (text.Length > 400 ? text[..400] : text).Trim();
        return new System.Globalization.StringInfo(trimmed).LengthInTextElements <= 60 &&
               trimmed.IndexOfAny(['\n', '\r', '\u2028', '\u2029']) < 0;
    }

    /// <summary>文本条目的行标题：去掉首尾空白、取前 200 字、连续空白压成一个空格（同 mac ClipItem.title）。</summary>
    public static string TextTitle(string? text)
    {
        var trimmed = (text ?? string.Empty).Trim();
        if (trimmed.Length > 200)
        {
            trimmed = trimmed[..200];
        }

        var builder = new System.Text.StringBuilder(trimmed.Length);
        var lastSpace = false;
        foreach (var ch in trimmed)
        {
            var space = char.IsWhiteSpace(ch);
            if (space && lastSpace)
            {
                continue;
            }

            builder.Append(space ? ' ' : ch);
            lastSpace = space;
        }

        return builder.ToString();
    }

    /// <summary>标题右边那几个标记占掉的宽度（各连它前面的间距；没收藏时星标连间距都不占）。</summary>
    public static double MarkersWidth(bool rich, bool snippet, bool favorite)
        => (rich ? RowSpacing + 24 : 0) + (snippet ? RowSpacing + 16 : 0) + (favorite ? RowSpacing + 16 : 0);

    /// <summary>
    /// 行标题已经把整条文本原样显示出来了：去掉首尾空白后和标题一字不差（一行、没有被压掉的连续空白），
    /// 且标题列最窄时也放得下（measure 给标题的宽度）。只看条目自己的数据，所以仍是常数。
    /// </summary>
    public static bool ShowsWholeText(string? text, bool rich, bool snippet, bool favorite, Func<string, double> measure)
    {
        // 标题列再宽也放不下 400 字节；长文本不在这里整段处理。
        if (text is null || System.Text.Encoding.UTF8.GetByteCount(text) > 400)
        {
            return false;
        }

        var title = TextTitle(text);
        if (title.Length == 0 || title != text.Trim())
        {
            return false;
        }

        return Math.Ceiling(measure(title)) <= TitleRoom - MarkersWidth(rich, snippet, favorite);
    }
}
