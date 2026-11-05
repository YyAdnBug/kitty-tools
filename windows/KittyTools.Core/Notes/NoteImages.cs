// 便签正文里的行内图片（PLAN-v13 第 1 批，照 mac Notes/NoteImages.swift）：
// **令牌**是存的正文里图片的样子——`![image](kitty-note-image://<UUID>.<ext>)`，记了宽度时 `![image|240](kitty-note-image://<UUID>.<ext>)`。
// 载入编辑器时令牌换成图片（RichEditBox 里是 U+FFFC）、存盘时换回来。这里全是纯函数：认令牌、拼令牌、摘要里换「[图片]」、
// 找一条正文引用了哪些编号、插图要换哪一段。别的写法一律不是令牌，当普通文字——**绝不拿正文去碰文件系统**。
namespace KittyTools.Core.Notes;

public static class NoteImages
{
    /// <summary>一张图的令牌里记着的东西：编号（大写 UUID）、扩展名（小写字母数字 1–10 位）、宽度（整数，null = 没记）。</summary>
    public readonly record struct Image(Guid Id, string Ext, int? Width)
    {
        /// <summary>文件名 `&lt;大写 UUID&gt;.&lt;ext&gt;`。</summary>
        public string FileName => $"{IdText(Id)}.{Ext}";
    }

    public const string Scheme = "kitty-note-image://";

    public const int MinWidth = 40;

    public const int MaxWidth = 4000;

    public const string Placeholder = "[图片]";

    public const int MaxExtension = 10;

    private const string TokenPrefix = "![image";

    /// <summary>Swift UUID.uuidString 的写法：大写、带连字符。</summary>
    public static string IdText(Guid id) => id.ToString("D").ToUpperInvariant();

    // ---- 拼 ----

    public static string Token(Image image)
        => $"![image{(image.Width is { } width ? "|" + width : string.Empty)}]({Scheme}{IdText(image.Id)}.{image.Ext})";

    /// <summary>记了宽度时不在 40–4000 里当没写。</summary>
    public static int? Width(int? raw) => raw is { } value && value is >= MinWidth and <= MaxWidth ? value : null;

    public enum WidthPreset
    {
        Small,
        Medium,
        Large,
        Fill,
        Original,
    }

    public static readonly WidthPreset[] Presets =
        { WidthPreset.Small, WidthPreset.Medium, WidthPreset.Large, WidthPreset.Fill, WidthPreset.Original };

    public static string Title(WidthPreset preset) => preset switch
    {
        WidthPreset.Small => "小",
        WidthPreset.Medium => "中",
        WidthPreset.Large => "大",
        WidthPreset.Fill => "铺满",
        _ => "原始大小",
    };

    /// <summary>存进令牌的宽度（原始大小不记；铺满存上限 4000）。</summary>
    public static int? WidthOf(WidthPreset preset) => preset switch
    {
        WidthPreset.Small => 120,
        WidthPreset.Medium => 240,
        WidthPreset.Large => 360,
        WidthPreset.Fill => MaxWidth,
        _ => null,
    };

    /// <summary>令牌里记着的宽度是哪一档；不在这几个数上的不是任何一档。</summary>
    public static WidthPreset? PresetOf(int? width)
    {
        foreach (var preset in Presets)
        {
            if (WidthOf(preset) == width)
            {
                return preset;
            }
        }

        return null;
    }

    /// <summary>裁完之后令牌里的宽度：记了宽度 W 的按裁下来的占原图多宽换算，夹进 40–4000；没记的照旧不记，「铺满」照旧铺满。</summary>
    public static int? CroppedWidth(int? width, int fullWidth, int croppedWidth)
    {
        if (width is not { } value || fullWidth <= 0)
        {
            return null;
        }

        if (value == MaxWidth)
        {
            return value;
        }

        var scaled = Math.Round((double)value * croppedWidth / fullWidth, MidpointRounding.AwayFromZero);
        return (int)Math.Clamp(scaled, MinWidth, MaxWidth);
    }

    // ---- 认 ----

    private static bool IsUpperHex(char ch) => ch is >= '0' and <= '9' or >= 'A' and <= 'F';

    /// <summary>从 index 开始是不是一段令牌：是就给它的区间和内容。</summary>
    public static (NoteRange Range, Image Image)? Match(string text, int index)
    {
        bool Literal(string word, int offset)
            => index + offset + word.Length <= text.Length &&
               string.CompareOrdinal(text, index + offset, word, 0, word.Length) == 0;

        char? Unit(int offset)
        {
            var position = index + offset;
            return position >= 0 && position < text.Length ? text[position] : null;
        }

        if (!Literal(TokenPrefix, 0))
        {
            return null;
        }

        var offset = 7;
        int? stored = null;
        if (Unit(offset) == '|')
        {
            offset++;
            var (digits, value) = (0, 0);
            while (Unit(offset) is { } current && char.IsAsciiDigit(current) && digits < 9)
            {
                value = value * 10 + (current - '0');
                digits++;
                offset++;
            }

            if (digits == 0)
            {
                return null;
            }

            stored = Width(value);
        }

        if (Unit(offset) != ']' || Unit(offset + 1) != '(')
        {
            return null;
        }

        offset += 2;
        if (!Literal(Scheme, offset))
        {
            return null;
        }

        offset += Scheme.Length;
        for (var position = 0; position < 36; position++)
        {
            if (Unit(offset + position) is not { } current)
            {
                return null;
            }

            if ((position is 8 or 13 or 18 or 23) ? current != '-' : !IsUpperHex(current))
            {
                return null;
            }
        }

        if (!Guid.TryParseExact(text.AsSpan(index + offset, 36), "D", out var id))
        {
            return null;
        }

        offset += 36;
        if (Unit(offset) != '.')
        {
            return null;
        }

        offset++;
        var extStart = offset;
        while (offset - extStart < MaxExtension && Unit(offset) is { } current &&
               (char.IsAsciiDigit(current) || current is >= 'a' and <= 'z'))
        {
            offset++;
        }

        if (offset == extStart || Unit(offset) != ')')
        {
            return null;
        }

        var ext = text.Substring(index + extStart, offset - extStart);
        offset++;
        return (new NoteRange(index, offset), new Image(id, ext, stored));
    }

    /// <summary>正文里所有的令牌（从前到后，互不相交）。</summary>
    public static List<(NoteRange Range, Image Image)> Matches(string text)
    {
        var found = new List<(NoteRange Range, Image Image)>();
        if (!ContainsToken(text))
        {
            return found;
        }

        var index = 0;
        while (index < text.Length)
        {
            if (text[index] == '!' && Match(text, index) is { } match)
            {
                found.Add(match);
                index = match.Range.End;
                continue;
            }

            index++;
        }

        return found;
    }

    /// <summary>有没有令牌：先做一个便宜的判断，绝大多数没有图片的便签就此打住。</summary>
    public static bool ContainsToken(string text) => text.Contains(TokenPrefix, StringComparison.Ordinal);

    public static Image? First(string text) => Matches(text) is { Count: > 0 } all ? all[0].Image : null;

    /// <summary>正文里引用到的图片编号（清理时算「谁还被引用着」；归档的、「最近删除」里的便签都算）。</summary>
    public static HashSet<Guid> Ids(string text) => Matches(text).Select(match => match.Image.Id).ToHashSet();

    /// <summary>index 那个字在哪张图上（令牌的中间也算）。</summary>
    public static Image? ImageCovering(string text, int index)
    {
        foreach (var match in Matches(text))
        {
            if (match.Range.Contains(index))
            {
                return match.Image;
            }
        }

        return null;
    }

    /// <summary>这一行是不是「只有图片」：去掉令牌和空白之后什么都不剩。</summary>
    public static bool IsImageOnly(string line)
        => ContainsToken(line) && NoteText.TrimSpaces(Stripping(line)).Length == 0;

    // ---- 显示用 ----

    public static string Display(string text) => Replace(text, Placeholder);

    /// <summary>令牌整段去掉（字数、搜索用：一张图不算字）。</summary>
    public static string Stripping(string text) => Replace(text, string.Empty);

    private static string Replace(string text, string with)
    {
        var matches = Matches(text);
        if (matches.Count == 0)
        {
            return text;
        }

        var builder = new System.Text.StringBuilder(text.Length);
        var last = 0;
        foreach (var (range, _) in matches)
        {
            builder.Append(text, last, range.Location - last).Append(with);
            last = range.End;
        }

        return builder.Append(text, last, text.Length - last).ToString();
    }

    /// <summary>正文的显示形式（墙卡片上那段字用）：只有图片的行整行去掉（连行尾的换行），行内的令牌换成「[图片]」。截取之前做。</summary>
    public static string DisplayLines(string text)
    {
        if (!ContainsToken(text))
        {
            return text;
        }

        var builder = new System.Text.StringBuilder(text.Length);
        foreach (var (start, contentsEnd, end) in NoteText.Lines(text))
        {
            var line = text[start..contentsEnd];
            if (IsImageOnly(line))
            {
                continue;
            }

            builder.Append(Display(line)).Append(text, contentsEnd, end - contentsEnd);
        }

        return builder.ToString();
    }

    // ---- 插图插在哪 ----

    /// <summary>插一段图片时正文怎么改：Lead = 前面先加一个换行、Trail = 后面再加一个换行、Caret = 插完光标相对替换区间开头的位置。
    /// 每张图独占一行；图后面总要有一个换行，插完光标落到图下一行的行首。</summary>
    public readonly record struct Insertion(bool Lead, bool Trail, int Caret);

    public static Insertion InsertionPlan(string text, NoteRange range, int count)
    {
        int Snapped(int value)
            => value > 0 && value < text.Length && text[value - 1] == '\r' && text[value] == '\n' ? value + 1 : value;

        var start = Snapped(Math.Clamp(range.Location, 0, text.Length));
        var lineStart = Math.Clamp(NoteText.Line(text, start).Start, 0, start);
        var lead = HasContent(text[lineStart..start]);
        var caret = (lead ? 1 : 0) + count + Math.Max(0, count - 1) + 1;
        return new Insertion(lead, true, caret);
    }

    /// <summary>这一段（一行里插入点前面那截）有没有正文内容：行首的列表标记不算。</summary>
    public static bool HasContent(string head)
    {
        var start = Math.Min(NoteTasks.PrefixOf(head)?.ContentStart ?? 0, head.Length);
        return head.Skip(start).Any(ch => !NoteText.IsWhite(ch));
    }
}
