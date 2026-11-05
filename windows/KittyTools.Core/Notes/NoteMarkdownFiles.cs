// 便签的 Markdown 导出 / 导入的纯函数（PLAN-v13 第 7 批，照 mac Notes/NoteMarkdownFiles.swift 的纯函数部分；读文件、写文件、
// 存图片、存储面板、刘海岛在 App 的 Notes/NotesTransfer）：
// - 导出：每条便签一个 .md（文件名 = 显示标题，清理、截断、重名加「 2」「 3」），正文里的任务、颜色、图片令牌换成 Markdown；
//   文件头带编号、自己起的标题、颜色（自定义纸色另写 tint）、时间（到毫秒、调用方给的时区）、修订号、归档、固定、顺序、正文哈希；
//   新建一个文件夹「Kitty Tools 便签 2026-10-17」（重名加「 2」「 3」，FolderNames 给候选名，绝不往已有的文件夹里混写）。
// - 导入：自家的文件（ParseHeader 认得出头）按编号合并（OwnNote）；**在别处改过的**（第四轮体检 E18）：有正文哈希只看哈希，
//   没有的（旧导出文件）文件时间比文件头晚 2 秒以上才算（EditedElsewhere）；别处的 .md 每个一条新便签（ForeignNote），
//   开头有别人的 YAML 头就原样留在正文里（ForeignHeaderEnd）。正文里的 Markdown 图片换成令牌（ConvertImagesAsync：读文件、
//   存图片由调用方的 store 做）。
// - 文件头里值的写法、读法（JSON 字符串、Swift 的数字 / 布尔、ISO 时间）在 NoteFileHeader，同步文件夹也用那一份。
// 和 mac 不一样的地方：
// - 文件名另把 Windows 不许的 < > " | ? * 也换成「-」，CON / NUL / COM1 这类设备名前面加「_」（mac 只换 / : \）。
// - 时区由调用方给（mac 用 TimeZone.current）；时刻是整数毫秒（mac 是对齐到毫秒的 Date）。
// - ISO 时间只认 yyyy-MM-ddTHH:mm:ss[.小数](Z|±HH:mm[:ss])，年份 0001–9999；小数秒取前 3 位（截断）。
// ponytail: mac 的 ISO8601DateFormatter 背后是 ICU，比这里宽（+0800 不带冒号之类的写法它也许认）；导出文件是自家写的，
//   碰上手改过的怪写法这里当认不出：created 当没有、modified 用文件时间。要更宽再照 ICU 的宽松解析补。
// ponytail: 导出时文件名截到 80 个字 / 200 字节，不是按文件系统的实际上限（255 个 UTF-16）算的：够用，长名字截短比被系统拒了好。
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace KittyTools.Core.Notes;

public static class NoteMarkdownFiles
{
    /// <summary>导出文件夹的名字前缀。</summary>
    public const string FolderPrefix = "Kitty Tools 便签 ";

    /// <summary>图片放在导出文件夹里的哪个子文件夹。</summary>
    public const string AttachmentsName = "attachments";

    /// <summary>一次最多导入这么多个文件（按文件名排序取前这么多）。</summary>
    public const int MaxFiles = 2000;

    /// <summary>单个 .md 文件最多多大（字节）。</summary>
    public const int MaxFileBytes = 4 << 20;

    /// <summary>文件名最多几个字（字位簇）、UTF-8 最多几个字节。</summary>
    public const int MaxNameLength = 80;

    public const int MaxNameBytes = 200;

    /// <summary>没有哈希的旧文件，文件时间比文件头晚多少毫秒才算在别处改过：有的盘、拷来拷去时刻只精确到 1–2 秒。</summary>
    public const long EditedSlackMs = 2000;

    /// <summary>三处入口菜单里那一项的名字（全部便签窗口的右键、那叠 / 浮动便签的操作菜单）。</summary>
    public const string SingleExportTitle = "导出为 Markdown…";

    // ---- 文件名 ----

    /// <summary>一条便签导出时的文件名（不带 .md）：显示标题去掉控制字符（Cc、Cf），/ : \ 和 Windows 不许的 &lt; &gt; " | ? * 换成「-」，
    /// 去掉两头的空白和开头的「.」，截到 80 个字（且 UTF-8 不超过 200 字节）；设备名前面加「_」；空的叫「未命名便签」。</summary>
    public static string FileName(Note note)
    {
        var title = note.DisplayTitle;
        var builder = new StringBuilder(title.Length);
        foreach (var rune in title.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format)
            {
                continue;
            }

            builder.Append(rune.ToString());
        }

        foreach (var forbidden in "/:\\<>\"|?*")
        {
            builder.Replace(forbidden, '-');
        }

        var name = NoteText.TrimSpacesAndNewlines(builder.ToString()).TrimStart('.');
        name = Truncate(NoteText.TrimSpacesAndNewlines(name), MaxNameLength, MaxNameBytes);
        if (name.Length == 0)
        {
            return Note.Untitled;
        }

        return IsDeviceName(name) ? "_" + name : name;
    }

    /// <summary>几条便签的文件名：重名（不分大小写、Unicode 规范化后比）加「 2」「 3」。taken 里是已经用掉的（不带 .md）。</summary>
    public static List<string> FileNames(IReadOnlyList<Note> notes, IReadOnlySet<string>? taken = null)
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var name in taken ?? new HashSet<string>())
        {
            used.Add(Normalized(name));
        }

        var names = new List<string>(notes.Count);
        foreach (var note in notes)
        {
            var name = FileName(note);
            var candidate = name;
            var counter = 2;
            while (!used.Add(Normalized(candidate)))
            {
                candidate = Numbered(name, counter);
                counter++;
            }

            names.Add(candidate);
        }

        return names;
    }

    /// <summary>截到这么多个字（字位簇）、UTF-8 不超过这么多字节。</summary>
    public static string Truncate(string text, int characters, int bytes)
    {
        var (count, size, end) = (0, 0, 0);
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (count < characters && enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            size += Encoding.UTF8.GetByteCount(element);
            if (size > bytes)
            {
                break;
            }

            count++;
            end = enumerator.ElementIndex + element.Length;
        }

        return text[..end];
    }

    /// <summary>导出文件夹的候选名：「Kitty Tools 便签 2026-10-17」、「… 2」、「… 3」…（调用方挨个试，第一个不存在的就建）。</summary>
    public static IEnumerable<string> FolderNames(DateTime localDate)
    {
        var name = FolderPrefix + localDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        yield return name;
        for (var number = 2; number <= 10_000; number++)
        {
            yield return name + " " + number.ToString(CultureInfo.InvariantCulture);
        }
    }

    /// <summary>加序号之后仍不超过 80 个字 / 200 字节（序号算在里面）。</summary>
    private static string Numbered(string name, int number)
    {
        var suffix = " " + number.ToString(CultureInfo.InvariantCulture);
        return Truncate(name, Math.Max(MaxNameLength - suffix.Length, 0), MaxNameBytes - suffix.Length) + suffix;
    }

    /// <summary>名字比较用的规范形：Unicode 规范化 + 小写。规范化不了的（落单的代理项，别处的文件名里可能有）只转小写。</summary>
    private static string Normalized(string name)
    {
        try
        {
            return name.Normalize(NormalizationForm.FormC).ToLowerInvariant();
        }
        catch (ArgumentException)
        {
            return name.ToLowerInvariant();
        }
    }

    /// <summary>Windows 的设备名（CON、PRN、AUX、NUL、COM0–9、LPT0–9，带不带扩展名都算）：拿它当文件名建不出来。</summary>
    private static bool IsDeviceName(string name)
    {
        var dot = name.IndexOf('.');
        var stem = (dot < 0 ? name : name[..dot]).TrimEnd(' ').ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" ||
               (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) &&
                stem[3] is >= '0' and <= '9' or '\u00B9' or '\u00B2' or '\u00B3');
    }

    // ---- 文件头 ----

    /// <summary>一条便签的文件头（`---` 那几行，不带后面的空行）。zone：created / modified 两行用的时区。</summary>
    public static string Header(Note note, string? bodyHash, TimeZoneInfo zone)
    {
        var builder = new StringBuilder(256);
        builder.Append("---\nkitty-note: ").Append(note.Id).Append('\n');
        if (NoteText.TrimSpacesAndNewlines(note.Title).Length > 0)
        {
            builder.Append("title: ").Append(NoteFileHeader.JsonString(note.Title)).Append('\n');
        }

        // 纸色：color 写预设（自定义的写最接近的那种），自定义的色值另写一行 tint（要带引号：YAML 里 # 起注释）
        builder.Append("color: ").Append(Invariant(Note.StoredPreset(note.Color))).Append('\n');
        if (Note.CustomRgb(note.Color) is { } rgb)
        {
            builder.Append("tint: ").Append(NoteFileHeader.JsonString(Note.Hex(rgb))).Append('\n');
        }

        builder.Append("created: ").Append(NoteFileHeader.Iso(note.CreatedAt, zone)).Append('\n')
            .Append("modified: ").Append(NoteFileHeader.Iso(note.ModifiedAt, zone)).Append('\n')
            .Append("revision: ").Append(Invariant(Math.Clamp(note.Revision, 0, Note.MaxRevision))).Append('\n')
            .Append("archived: ").Append(NoteFileHeader.Bool(note.IsArchived)).Append('\n')
            .Append("pinned: ").Append(NoteFileHeader.Bool(note.IsPinned)).Append('\n')
            .Append("order: ").Append(NoteFileHeader.Number(note.Order)).Append('\n');
        if (bodyHash is not null)
        {
            builder.Append("body-hash: ").Append(bodyHash).Append('\n');
        }

        return builder.Append("---").ToString();
    }

    /// <summary>文件头之后那段正文的哈希（E18：导回时看正文在别处改过没有）：UTF-8 做 SHA-256，前 16 字节的小写十六进制。
    /// 导出时算写出去的那段，导回时算读到的那段（\r\n 已经换成 \n：只换了换行符的不算改过）。</summary>
    public static string BodyHash(string text)
        => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)).AsSpan(0, 16));

    /// <summary>自家文件的头里读到的东西。内存里的纸色 = Note.ColorFrom(Color, Tint)；Text 是收尾的 `---` 后面的正文（Markdown 原样）。</summary>
    public sealed record FileHeader
    {
        public required string Id { get; init; }

        public string Title { get; init; } = string.Empty;

        public int Color { get; init; }

        /// <summary>自定义纸色的色值（0xRRGGBB）。</summary>
        public int? Tint { get; init; }

        public long? Created { get; init; }

        public long? Modified { get; init; }

        public int Revision { get; init; }

        public bool Archived { get; init; }

        public bool Pinned { get; init; }

        public double Order { get; init; }

        /// <summary>导出时正文的哈希（E18；mac 0.7.1 之前导出的没有）。</summary>
        public string? BodyHash { get; init; }

        public string Text { get; init; } = string.Empty;
    }

    /// <summary>自家文件的头（第一行正好是 `---`、前 40 行里有收尾的 `---`、头里有合法的 kitty-note）；不是给 null。
    /// 只认导出的那几个键；每个值都验：颜色夹到 0–7（tint 认不出当没有）、时间认不出 created 当没有 / modified 用 fallback、
    /// revision 夹到 0…上限、archived / pinned 只认 true、order 有限的数否则 0、title 按 JSON 字符串解（解不出当空）。
    /// 正文从收尾的 `---` 下一行起；导出的文件在那里空一行再写正文，那一行空行不算正文（别处手写的没空行照旧）。</summary>
    public static FileHeader? ParseHeader(string text, long modifiedFallback)
    {
        var lines = HeadLines(text, 43);
        if (!IsFence(text, lines[0]))
        {
            return null;
        }

        var closing = -1;
        for (var index = 1; index < Math.Min(lines.Count, 41); index++)
        {
            if (IsFence(text, lines[index]))
            {
                closing = index;
                break;
            }
        }

        if (closing < 0)
        {
            return null;
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 1; index < closing; index++)
        {
            var line = text[lines[index].Start..lines[index].End];
            var colon = NoteFileHeader.IndexOfCharacter(line, ':');
            if (colon >= 0)
            {
                values[NoteText.TrimSpaces(line[..colon])] = NoteText.TrimSpaces(line[(colon + 1)..]);
            }
        }

        if (!values.TryGetValue("kitty-note", out var raw) || NoteFileHeader.UuidText(raw) is not { } id)
        {
            return null;
        }

        var start = closing + 1;
        if (start < lines.Count && lines[start].End == lines[start].Start)
        {
            start++;
        }

        return new FileHeader
        {
            Id = id,
            Title = Value("title") is { } title ? NoteFileHeader.JsonDecode(title) ?? string.Empty : string.Empty,
            Color = Value("color") is { } color && NoteFileHeader.ParseInt64(color) is { } preset ? StoredPreset(preset) : 0,
            Tint = Value("tint") is { } tint && NoteFileHeader.JsonDecode(tint) is { } hex ? Note.RgbFromHex(hex) : null,
            Created = Value("created") is { } created ? ParseDate(created) : null,
            Modified = (Value("modified") is { } modified ? ParseDate(modified) : null) ?? modifiedFallback,
            Revision = Value("revision") is { } revision && NoteFileHeader.ParseInt64(revision) is { } number
                ? (int)Math.Clamp(number, 0, Note.MaxRevision)
                : 0,
            Archived = Value("archived") == "true",
            Pinned = Value("pinned") == "true",
            Order = Value("order") is { } order && NoteFileHeader.ParseDouble(order) is { } value && double.IsFinite(value) ? value : 0,
            BodyHash = Value("body-hash") is { Length: > 0 } hash ? hash : null,
            Text = start < lines.Count ? text[lines[start].Start..] : string.Empty,
        };

        string? Value(string key) => values.TryGetValue(key, out var found) ? found : null;
    }

    /// <summary>开头有 YAML 头（`---` … `---`，收尾在前 40 行里）时它到哪为止（含收尾那行的换行）；没有给 null。
    /// 别处的文件原样留在正文里，只对它后面的字做任务 / 颜色 / 图片的换法。</summary>
    public static int? ForeignHeaderEnd(string text)
    {
        var lines = HeadLines(text, 41);
        if (!IsFence(text, lines[0]))
        {
            return null;
        }

        for (var index = 1; index < lines.Count; index++)
        {
            if (IsFence(text, lines[index]))
            {
                return lines[index].End + 1;
            }
        }

        return null;
    }

    /// <summary>前 max 行（按 \n 切，同 mac components(separatedBy: "\n")）：每行的开头和换行之前。至少一行。</summary>
    private static List<(int Start, int End)> HeadLines(string text, int max)
    {
        var lines = new List<(int Start, int End)>();
        var start = 0;
        while (lines.Count < max)
        {
            var end = text.IndexOf('\n', start);
            if (end < 0)
            {
                lines.Add((start, text.Length));
                break;
            }

            lines.Add((start, end));
            start = end + 1;
        }

        return lines;
    }

    private static bool IsFence(string text, (int Start, int End) line)
        => line.End - line.Start == 3 && string.CompareOrdinal(text, line.Start, "---", 0, 3) == 0;

    /// <summary>文件里写的颜色（Swift 的 Int，64 位）→ 预设下标：超出 32 位的照 mac 夹进 0–7。</summary>
    private static int StoredPreset(long raw)
        => raw is >= int.MinValue and <= int.MaxValue ? Note.StoredPreset((int)raw) : raw < 0 ? 0 : Note.ColorCount - 1;

    /// <summary>mac parseDate：ISO 8601（带不带小数秒都认）→ 整数毫秒；认不出给 null。</summary>
    private static long? ParseDate(string raw)
    {
        int Digits(int from, int length)
        {
            if (from + length > raw.Length)
            {
                return -1;
            }

            var value = 0;
            for (var index = from; index < from + length; index++)
            {
                if (!char.IsAsciiDigit(raw[index]))
                {
                    return -1;
                }

                value = value * 10 + (raw[index] - '0');
            }

            return value;
        }

        if (raw.Length < 20 || raw[4] != '-' || raw[7] != '-' || raw[10] != 'T' || raw[13] != ':' || raw[16] != ':')
        {
            return null;
        }

        var (year, month, day) = (Digits(0, 4), Digits(5, 2), Digits(8, 2));
        var (hour, minute, second) = (Digits(11, 2), Digits(14, 2), Digits(17, 2));
        if (year < 1 || month is < 1 or > 12 || day < 1 || day > DateTime.DaysInMonth(year, month) ||
            hour is < 0 or > 23 || minute is < 0 or > 59 || second is < 0 or > 59)
        {
            return null;
        }

        var at = 19;
        var milliseconds = 0;
        if (raw[at] == '.')
        {
            var digits = ++at;
            while (at < raw.Length && char.IsAsciiDigit(raw[at]))
            {
                if (at - digits < 3)
                {
                    milliseconds = milliseconds * 10 + (raw[at] - '0');
                }

                at++;
            }

            if (at == digits)
            {
                return null;
            }

            for (var count = at - digits; count < 3; count++)
            {
                milliseconds *= 10;
            }
        }

        long offset;
        if (at == raw.Length - 1 && raw[at] == 'Z')
        {
            offset = 0;
        }
        else if (at < raw.Length && raw[at] is '+' or '-')
        {
            var rest = raw.Length - at - 1;
            var (hours, minutes) = (Digits(at + 1, 2), rest is 5 or 8 && raw[at + 3] == ':' ? Digits(at + 4, 2) : -1);
            var seconds = rest == 8 ? (raw[at + 6] == ':' ? Digits(at + 7, 2) : -1) : 0;
            if (hours is < 0 or > 23 || minutes is < 0 or > 59 || seconds is < 0 or > 59)
            {
                return null;
            }

            offset = (hours * 3600 + minutes * 60 + seconds) * (raw[at] == '-' ? -1L : 1L);
        }
        else
        {
            return null;
        }

        var local = new DateTimeOffset(year, month, day, hour, minute, second, milliseconds, TimeSpan.Zero).ToUnixTimeMilliseconds();
        return local - offset * 1000;
    }

    private static string Invariant(long value) => value.ToString(CultureInfo.InvariantCulture);

    // ---- 正文 ⇄ Markdown ----

    /// <summary>一份正文 → 导出时写进 .md 的正文（任务、颜色、图片都换好；代码块里的行不换任务和颜色、照换图片）。</summary>
    public static string MarkdownBody(string body)
        => MarkdownImages(NoteMarkdown.Html(NoteTasks.MarkdownFromBody(body))).Text;

    /// <summary>正文里的图片令牌换成 `![image|宽](attachments/&lt;编号&gt;.&lt;扩展名&gt;)`，另外给用到的图片（同一张只给一次，按第一次出现的先后）。
    /// **代码块里的行也换**：块里的令牌也显示成图，导出时图片文件也得跟着走；导回来时代码块里只认这种路径（IsExported）。</summary>
    public static (string Text, List<NoteImages.Image> Images) MarkdownImages(string body)
    {
        var images = new List<NoteImages.Image>();
        if (!body.Contains(NoteImages.Scheme, StringComparison.Ordinal))
        {
            return (body, images);
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new StringBuilder(body.Length);
        foreach (var (start, contentsEnd, end) in NoteText.Lines(body))
        {
            var line = body[start..contentsEnd];
            var last = 0;
            // 一行几张图：从前往后拼一份新的（mac 从后往前就地换，结果一样；从前往后就地换的话后面几张的位置就错了）
            foreach (var (range, image) in NoteImages.Matches(line))
            {
                if (seen.Add(image.FileName))
                {
                    images.Add(image);
                }

                result.Append(line, last, range.Location - last).Append("![image")
                    .Append(image.Width is { } width ? "|" + width.ToString(CultureInfo.InvariantCulture) : string.Empty)
                    .Append("](").Append(AttachmentsName).Append('/').Append(image.FileName).Append(')');
                last = range.End;
            }

            result.Append(line, last, line.Length - last).Append(body, contentsEnd, end - contentsEnd);
        }

        return (result.ToString(), images);
    }

    /// <summary>导入时把正文换回来：任务、颜色（图片要读文件、存图片，在 ConvertImagesAsync）。headerEnd：别人的 YAML 头到哪，
    /// 那一段原样当 Prefix，不换。</summary>
    public static (string Prefix, string Body) BodyFromMarkdown(string markdown, int? headerEnd = null)
    {
        if (headerEnd is not { } end)
        {
            return (string.Empty, FromMarkdown(markdown));
        }

        var cut = Math.Clamp(end, 0, markdown.Length);
        return (markdown[..cut], FromMarkdown(markdown[cut..]));
    }

    private static string FromMarkdown(string markdown) => NoteMarkdown.BodyFromHtml(NoteTasks.BodyFromMarkdown(markdown));

    // ---- Markdown 里的图片 ----

    /// <summary>一段 Markdown 图片：`![说明](路径)` / `![说明|宽](路径)`，Range 是整段（这一行里的 UTF-16 位置）。</summary>
    public readonly record struct MarkdownImage(NoteRange Range, int? Width, string Path);

    /// <summary>一行里的 Markdown 图片（跳过行内代码里的）。说明到第一个没转义的 ]，路径里的括号成对就行、不能是空的。</summary>
    public static List<MarkdownImage> MarkdownImagesIn(string line)
    {
        var found = new List<MarkdownImage>();
        if (!line.Contains("![", StringComparison.Ordinal))
        {
            return found;
        }

        var code = NoteMarkdown.Inline(line, 0, line.Length)
            .Where(span => span.Kind.Tag == NoteStyles.KindTag.Code).Select(span => span.Range).ToList();
        var index = 0;
        while (index + 1 < line.Length)
        {
            if (line[index] != '!' || line[index + 1] != '[' || code.Any(range => range.Contains(index)))
            {
                index++;
                continue;
            }

            var close = index + 2;
            while (close < line.Length && line[close] != ']')
            {
                close += line[close] == '\\' ? 2 : 1;
            }

            if (close + 1 >= line.Length || line[close + 1] != '(')
            {
                index++;
                continue;
            }

            var end = close + 2;
            var depth = 0;
            while (end < line.Length)
            {
                var unit = line[end];
                if (unit == '\\')
                {
                    end += 2;
                    continue;
                }

                if (unit == '(')
                {
                    depth++;
                }

                if (unit == ')')
                {
                    if (depth == 0)
                    {
                        break;
                    }

                    depth--;
                }

                end++;
            }

            if (end >= line.Length || end <= close + 2)
            {
                index++;
                continue;
            }

            var alt = line[(index + 2)..close];
            var bar = alt.LastIndexOf('|');
            // 同 NoteImages.Width：不在 40–4000 里当没写
            int? width = bar >= 0 && NoteFileHeader.ParseInt64(alt[(bar + 1)..]) is { } raw &&
                         raw is >= NoteImages.MinWidth and <= NoteImages.MaxWidth
                ? (int)raw
                : null;
            found.Add(new MarkdownImage(NoteRange.Of(index, end + 1), width, line[(close + 2)..end]));
            index = end + 1;
        }

        return found;
    }

    /// <summary>一条便签在导出文件里的全文（文件头 + 空行 + 正文）和用到的图片。整个文件夹导出和单条导出共用这一份，两边一字不差。</summary>
    public static (string Text, List<NoteImages.Image> Images) FileText(Note note, TimeZoneInfo zone)
    {
        var (body, images) = MarkdownImages(NoteTasks.MarkdownFromBody(note.Body));
        var markdown = NoteMarkdown.Html(body);
        return (Header(note, BodyHash(markdown), zone) + "\n\n" + markdown, images);
    }

    /// <summary>导出时写出去的图片路径：`attachments/&lt;UUID&gt;.&lt;小写扩展名&gt;`。</summary>
    public static bool IsExported(string path)
    {
        const string prefix = AttachmentsName + "/";
        return path.StartsWith(prefix, StringComparison.Ordinal) && NoteSyncFolder.ImageId(path[prefix.Length..]) is not null;
    }

    /// <summary>正文里的 Markdown 图片换成令牌（mac convertImages 的纯逻辑部分）：逐行，代码块里的行（连围栏行）只认 IsExported 的路径——
    /// 别处的代码块里写着的图片语法是代码，原样留着、不调 store、不算失败。store 给 null = 失败（算进 Failures，原样留着）。
    /// 一行里从后往前换、从后往前调 store。没有图片目录时 mac 整段不换、不算失败：调用方那时别调这个。</summary>
    public static async Task<(string Body, int Failures)> ConvertImagesAsync(string body, Func<MarkdownImage, Task<string?>> store)
    {
        var blocks = NoteMarkdown.CodeBlocks(body);
        var result = new StringBuilder(body.Length);
        var failures = 0;
        foreach (var (start, contentsEnd, end) in NoteText.Lines(body))
        {
            var line = body[start..contentsEnd];
            if (line.Contains("![", StringComparison.Ordinal))
            {
                var inCode = NoteMarkdown.RoleAt(start, blocks) is not null;
                var images = MarkdownImagesIn(line).Where(image => !inCode || IsExported(image.Path)).ToList();
                for (var index = images.Count - 1; index >= 0; index--)
                {
                    var image = images[index];
                    if (await store(image).ConfigureAwait(false) is { } replacement)
                    {
                        line = line[..image.Range.Location] + replacement + line[image.Range.End..];
                    }
                    else
                    {
                        failures++;
                    }
                }
            }

            result.Append(line).Append(body, contentsEnd, end - contentsEnd);
        }

        return (result.ToString(), failures);
    }

    // ---- 读文件 ----

    /// <summary>读文件的字节 → 文本：去 BOM、严格 UTF-8（不是就 null）、\r\n 和 \r 换成 \n。
    /// 同 mac：先手动去一个 BOM，再按 Swift String(data:encoding:) 的口径解（它自己也去一个）。</summary>
    public static string? Decode(byte[] data)
    {
        ReadOnlySpan<byte> bytes = data;
        ReadOnlySpan<byte> bom = [0xEF, 0xBB, 0xBF];
        if (bytes.StartsWith(bom))
        {
            bytes = bytes[3..];
        }

        return NoteFileHeader.Decode(bytes) is { } text
            ? text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n')
            : null;
    }

    /// <summary>为什么跳过一个文件（岛上写清原因）。</summary>
    public enum Skip
    {
        /// <summary>超过 MaxFileBytes。</summary>
        TooLarge,

        /// <summary>不是 UTF-8 文本。</summary>
        NotText,

        /// <summary>换完正文超过一条便签的上限。</summary>
        TooLong,

        /// <summary>读不出来（没权限、读到一半出错）。</summary>
        Unreadable,

        /// <summary>同步文件夹里的文件。</summary>
        SyncFile,

        /// <summary>超过一次 MaxFiles 个。</summary>
        OverLimit,
    }

    private static readonly Skip[] AllSkips =
        [Skip.TooLarge, Skip.NotText, Skip.TooLong, Skip.Unreadable, Skip.SyncFile, Skip.OverLimit];

    public static string SkipText(Skip reason) => reason switch
    {
        Skip.TooLarge => $"太大（超过 {MaxFileBytes >> 20} MB）",
        Skip.NotText => "不是 UTF-8 文本",
        Skip.TooLong => $"超过一条便签 {Note.MaxBodyBytes >> 20} MB 的上限",
        Skip.Unreadable => "读不出来",
        Skip.SyncFile => "是同步文件夹里的文件",
        _ => $"超过一次 {MaxFiles} 个",
    };

    /// <summary>导入做了什么。</summary>
    public sealed class ImportResult
    {
        public List<Note> Notes { get; } = new();

        /// <summary>跳过的一共几个；各为什么在 Reasons。</summary>
        public int Skipped { get; private set; }

        public Dictionary<Skip, int> Reasons { get; } = new();

        /// <summary>图片没导进来的张数（跑出文件夹、不在、太大、读不出、不是图片）。</summary>
        public int MissingImages { get; set; }

        /// <summary>只导了前 MaxFiles 个。</summary>
        public bool LimitHit { get; set; }

        /// <summary>「改于」按文件的修改时间算的那几条（编号；在别的编辑器里改过正文）：合并时只取内容，状态留本机的。</summary>
        public HashSet<string> EditedElsewhere { get; } = new(StringComparer.Ordinal);

        public void Add(Skip reason, int count = 1)
        {
            if (count <= 0)
            {
                return;
            }

            Skipped += count;
            Reasons[reason] = Reasons.GetValueOrDefault(reason) + count;
        }
    }

    /// <summary>自家文件在别处改过没有（E18）。header / file：文件头里的「改于」、文件的修改时间（整数毫秒；读不出来给 null = 没改过）。
    /// bodyChanged：文件头里有正文哈希时，读到的正文和它对不对得上（null = 旧文件没有哈希）。有哈希就只看它（文件时间被 cp、git、
    /// 编辑器原样存一次碰过都不算）；没有的，文件时间比文件头晚 EditedSlackMs 以上算改过。</summary>
    public static bool EditedElsewhere(long header, long? file, bool? bodyChanged)
        => file is { } time && (bodyChanged ?? time - header > EditedSlackMs);

    /// <summary>导入完岛上怎么说：files 是选中的地方里有几个能导的文件；added / updated 是合并的结果。标题按新增 / 更新写，都是 0 说
    /// 「没有变化」；一条都没读出来时写清为什么（没有 .md、全都被跳过了及原因）。</summary>
    public static (string Title, string? Detail, bool Warning) ImportMessage(int files, ImportResult result, int added, int updated)
    {
        if (files <= 0)
        {
            return ("没有导入", "选的地方没有 .md 文件", true);
        }

        if (result.Notes.Count == 0)
        {
            return ("没有导入", "全部跳过了：" + string.Join("、", Reasons(result, null)), true);
        }

        var title = (added, updated) switch
        {
            (0, 0) => "没有变化",
            (_, 0) => $"已导入 {added} 条新便签",
            (0, _) => $"已更新 {updated} 条便签",
            _ => $"已导入：新增 {added} 条，更新 {updated} 条",
        };
        var parts = new List<string>();
        var same = result.Notes.Count - added - updated;
        if (same > 0)
        {
            parts.Add($"{same} 条和现在的一样");
        }

        // 超过 MaxFiles 个：只说「只导了前 2000 个」那一句，不再算进跳过
        var skipped = Reasons(result, result.LimitHit ? Skip.OverLimit : null);
        if (skipped.Count > 0)
        {
            parts.Add("跳过 " + string.Join("、", skipped));
        }

        if (result.MissingImages > 0)
        {
            parts.Add($"{result.MissingImages} 张图片没导进来");
        }

        if (result.LimitHit)
        {
            parts.Add($"只导了前 {MaxFiles} 个");
        }

        return (title, parts.Count == 0 ? null : string.Join(" · ", parts), false);
    }

    /// <summary>跳过的原因一句一句：「2 个太大（超过 4 MB）」。</summary>
    private static List<string> Reasons(ImportResult result, Skip? excluding)
    {
        var lines = new List<string>();
        foreach (var reason in AllSkips)
        {
            if (reason != excluding && result.Reasons.TryGetValue(reason, out var count))
            {
                lines.Add($"{count} 个{SkipText(reason)}");
            }
        }

        return lines;
    }

    // ---- 读出来的文件 → 便签 ----

    /// <summary>自家文件 → 一条便签（mac importNotes 里 parseHeader 那一支）：body 是换好图片之后的正文；fileModified 是文件的修改时间
    /// （读不出来给 null，那时按 now 算）。在别处改过的（edited）「改于」按文件时间，调用方把编号记进 ImportResult.EditedElsewhere。</summary>
    public static Note OwnNote(FileHeader header, string body, long? fileModified, long now, out bool edited)
    {
        var modified = fileModified ?? now;
        var headerModified = header.Modified ?? modified;
        edited = EditedElsewhere(
            headerModified, fileModified, header.BodyHash is { } hash ? hash != BodyHash(header.Text) : null);
        return new Note
        {
            Id = header.Id,
            Title = Note.SanitizedTitle(header.Title),
            Body = Note.SanitizedText(body),
            Color = Note.ColorFrom(header.Color, header.Tint),
            CreatedAt = header.Created ?? modified,
            ModifiedAt = edited ? fileModified ?? headerModified : headerModified,
            Revision = header.Revision,
            IsArchived = header.Archived,
            IsPinned = header.Pinned,
            Order = header.Order,
        };
    }

    /// <summary>别处的文件 → 一条新便签：content = 原样留着的 YAML 头 + 换好的正文；第一个有字的行是「# 」开头就不起标题（显示标题就是它），
    /// 否则用文件名（去掉扩展名）当标题；排在最前（-1e9 + 第几个文件）；时间取 min(文件时间, now)。id 由调用方新建。</summary>
    public static Note ForeignNote(string content, string fileStem, int index, long modified, long now, string id)
    {
        var first = string.Empty;
        foreach (var line in content.Split('\n'))
        {
            if (NoteText.TrimSpaces(line).Length > 0)
            {
                first = line;
                break;
            }
        }

        var time = Math.Min(modified, now);
        return new Note
        {
            Id = id,
            Title = first.StartsWith("# ", StringComparison.Ordinal) ? string.Empty : Note.SanitizedTitle(fileStem),
            Body = Note.SanitizedText(content),
            CreatedAt = time,
            ModifiedAt = time,
            Order = -1_000_000_000 + (double)index,
        };
    }
}
