// 便签的模型（便签库 notes 表的一行，PLAN-v13 第 1 批，照 mac Notes/Note.swift）和两条显示用的纯函数：标题（DisplayTitle）、
// 列表里的一行摘要（Preview）——两样都不带正文里的符号（标题的 #、任务的五种方框、Markdown 的标记和颜色、代码块的围栏行；
// 代码块里的字照原文）。
// 同步要的几样（合并规则在 NoteSync）：稳定的编号（大写 UUID 字符串，建了就不变）、内容的版本钟（Clock：每台电脑改过几次内容）、
// 状态和顺序改动的时刻（StateChangedAt / OrderChangedAt）、删除记录（DeletedAt 非空 = 在「最近删除」里；永久删除的墓碑在 NoteStore）。
// 修订号（任何字段变一次 +1）只是本机的账。
// **时间一律是整数毫秒**（1970 年起，mac 的库里、文件里也是整数毫秒；mac 内存里是对齐到毫秒的 Date，这里直接存 long）。
// 不可变：改一个字段用 with（Clock 换一整张新表，不在原表上改，所以 with 的浅拷贝是安全的）。
// 相等照 mac 的 Equatable：所有字段，Clock 按内容比。
namespace KittyTools.Core.Notes;

public sealed record Note
{
    /// <summary>预设的纸色有几种：Color 是 0..&lt;ColorCount 的下标，或者自定义的（CustomColor | 0xRRGGBB，只在内存里这么写）。</summary>
    public const int ColorCount = 8;

    public const int CustomColor = 1 << 24;

    public const int TitleLength = 60;

    public const int PreviewLength = 120;

    public const string Untitled = "未命名便签";

    /// <summary>一条便签的正文最多多大（UTF-8 字节）。编辑器、快速记一条、导入各自先按它拦（仓库自己不拦，同 mac 的 ponytail）。</summary>
    public const int MaxBodyBytes = 1 << 20;

    public const int MaxTitleLength = 200;

    public const int MaxTitleBytes = 1024;

    public const int MaxRevision = 1_000_000_000;

    private static readonly IReadOnlyDictionary<string, long> NoClock = new Dictionary<string, long>(StringComparer.Ordinal);

    public required string Id { get; init; }

    public string Title { get; init; } = string.Empty;

    public string Body { get; init; } = string.Empty;

    public int Color { get; init; }

    public long CreatedAt { get; init; }

    /// <summary>给人看的「改于」：只在标题 / 正文 / 颜色变时更新。</summary>
    public long ModifiedAt { get; init; }

    public int Revision { get; init; }

    public bool IsArchived { get; init; }

    public bool IsPinned { get; init; }

    public double Order { get; init; }

    public long? DeletedAt { get; init; }

    public long? StateChangedAt { get; init; }

    public long? OrderChangedAt { get; init; }

    /// <summary>内容的版本钟：电脑编号 → 改过几次。空 = 没记过。</summary>
    public IReadOnlyDictionary<string, long> Clock { get; init; } = NoClock;

    public bool IsActive => !IsArchived && DeletedAt is null;

    public long StateTime => StateChangedAt ?? ModifiedAt;

    public long OrderTime => OrderChangedAt ?? StateTime;

    public bool Equals(Note? other)
        => other is not null &&
           Id == other.Id && Title == other.Title && Body == other.Body && Color == other.Color &&
           CreatedAt == other.CreatedAt && ModifiedAt == other.ModifiedAt && Revision == other.Revision &&
           IsArchived == other.IsArchived && IsPinned == other.IsPinned && Order.Equals(other.Order) &&
           DeletedAt == other.DeletedAt && StateChangedAt == other.StateChangedAt &&
           OrderChangedAt == other.OrderChangedAt && SameClock(Clock, other.Clock);

    public override int GetHashCode() => HashCode.Combine(Id, Body, Revision, ModifiedAt);

    public static bool SameClock(IReadOnlyDictionary<string, long> a, IReadOnlyDictionary<string, long> b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        foreach (var (key, value) in a)
        {
            if (!b.TryGetValue(key, out var other) || other != value)
            {
                return false;
            }
        }

        return true;
    }

    // ---- 收拾（进仓库、进文件之前）----

    /// <summary>NUL（U+0000）去掉：库里的文字按 C 字符串存取，碰到它后面的就都丢了。</summary>
    public static string SanitizedText(string raw) => raw.Contains('\0') ? raw.Replace("\0", string.Empty) : raw;

    /// <summary>自己起的标题：去掉 NUL，再截到 MaxTitleLength 个字、MaxTitleBytes 字节（哪个先到算哪个）。</summary>
    public static string SanitizedTitle(string raw)
    {
        var clean = SanitizedText(raw);
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(clean);
        var (count, bytes, end) = (0, 0, 0);
        while (count < MaxTitleLength && enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            bytes += System.Text.Encoding.UTF8.GetByteCount(element);
            if (bytes > MaxTitleBytes)
            {
                break;
            }

            count++;
            end = enumerator.ElementIndex + element.Length;
        }

        return end >= clean.Length ? clean : clean[..end];
    }

    public static int Clamped(int raw) => CustomRgb(raw) is not null ? raw : Math.Clamp(raw, 0, ColorCount - 1);

    public static int Custom(int rgb) => CustomColor | (rgb & 0xFFFFFF);

    public static int? CustomRgb(int color) => color >> 24 == 1 ? color & 0xFFFFFF : null;

    /// <summary>落盘的那个下标：预设的照旧（夹进范围），自定义的是最接近的那种预设。</summary>
    public static int StoredPreset(int color)
        => CustomRgb(color) is { } rgb ? NotePaper.NearestPreset(rgb) : Clamped(color);

    /// <summary>文件里读回来（导出文件、Markdown 文件头）：预设下标 + 色值 → 内存里的纸色。</summary>
    public static int ColorFrom(int preset, int? tint)
        => tint is { } value && value is >= 0 and <= 0xFFFFFF ? Custom(value) : Math.Clamp(preset, 0, ColorCount - 1);

    /// <summary>库的 tint 列：写入那一刻的预设下标 &lt;&lt; 24 | 色值。</summary>
    public static int? StoredTint(int color)
        => CustomRgb(color) is { } rgb ? StoredPreset(color) << 24 | rgb : null;

    /// <summary>库里读回来：tint 里记的预设和 color 列对得上才算自定义；对不上说明旧版本换过颜色。</summary>
    public static int ColorFromStored(int preset, int? tint)
    {
        preset = Math.Clamp(preset, 0, ColorCount - 1);
        return tint is { } value && value >= 0 && value >> 24 == preset ? Custom(value & 0xFFFFFF) : preset;
    }

    /// <summary>取色挑了一个颜色：正好是哪种预设的浅纸就是那种预设，不然是自定义的。</summary>
    public static int Picked(int rgb)
    {
        for (var index = 0; index < NotePaper.All.Count; index++)
        {
            if (NotePaper.All[index].Light.Paper == (rgb & 0xFFFFFF))
            {
                return index;
            }
        }

        return Custom(rgb);
    }

    /// <summary>Ctrl+. 和新建便签的轮换：只在 8 种预设里轮。</summary>
    public static int NextPreset(int color) => (StoredPreset(color) + 1) % ColorCount;

    public static string Hex(int rgb) => "#" + (rgb & 0xFFFFFF).ToString("X6", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>「#RRGGBB」（大小写不分）→ 色值；别的写法给 null。</summary>
    public static int? RgbFromHex(string raw)
    {
        if (raw.Length != 7 || raw[0] != '#')
        {
            return null;
        }

        for (var index = 1; index < 7; index++)
        {
            if (!char.IsAsciiHexDigit(raw[index]))
            {
                return null;
            }
        }

        return Convert.ToInt32(raw[1..], 16);
    }

    public static int NextRevision(int revision) => Math.Clamp(revision, 0, MaxRevision - 1) + 1;

    // ---- 时间 ----

    public static long Milliseconds(DateTimeOffset date) => date.ToUnixTimeMilliseconds();

    public static DateTimeOffset Date(long milliseconds) => DateTimeOffset.FromUnixTimeMilliseconds(
        Math.Clamp(milliseconds, -62135596800000, 253402300799999));

    // ---- 显示 ----

    /// <summary>显示用的标题：自己起的标题；没起就是正文第一个有字的行（去掉行首的 #、任务符号和 Markdown 的标记），
    /// 超过 TitleLength 个字截断加「…」；都没有就是「未命名便签」。只有图片的行跳过，和字同一行的图去掉。</summary>
    public string DisplayTitle
    {
        get
        {
            var own = NoteText.TrimSpacesAndNewlines(Title);
            if (own.Length > 0)
            {
                return own;
            }

            var lines = LinesOf(NoteImages.Stripping(Body), 0, 0, droppingImageLines: true);
            if (lines.Count == 0)
            {
                return NoteImages.ContainsToken(Body) ? NoteImages.Placeholder : Untitled;
            }

            var collapsed = string.Join(' ', lines[0].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            return NoteText.Clipped(collapsed, TitleLength);
        }
    }

    /// <summary>列表里标题下面那一行摘要：其余有内容的行拼成一行，超过 PreviewLength 个字截断。图片写成「[图片]」。</summary>
    public string Preview
    {
        get
        {
            var hasOwnTitle = NoteText.TrimSpacesAndNewlines(Title).Length > 0;
            if (!hasOwnTitle && NoteImages.ContainsToken(Body) &&
                LinesOf(Body, 0, 0, droppingImageLines: true).Count == 0)
            {
                return string.Empty;
            }

            var rest = LinesOf(Body, hasOwnTitle ? 0 : 1, PreviewLength);
            return NoteText.Clipped(string.Join(' ', rest), PreviewLength);
        }
    }

    /// <summary>「最近删除」里只读的那份正文：令牌换成「[图片]」，其余照原文。</summary>
    public string ReadOnlyBody => NoteImages.Display(Body);

    /// <summary>任务做完几条 / 共几条（没有任务是 null）。</summary>
    public (int Done, int Total)? TaskProgress => NoteTasks.Progress(Body);

    public static string ProgressText((int Done, int Total) progress) => $"{progress.Done} / {progress.Total}";

    public static string ProgressSpoken((int Done, int Total) progress) => $"任务完成 {progress.Done} 项，共 {progress.Total} 项";

    /// <summary>去标记时一行最多看这么多个字。</summary>
    private const int ScanLimit = 4096;

    /// <summary>认代码块时最多看正文开头这么多个 UTF-16。</summary>
    public const int BlockScanLimit = 1 << 16;

    /// <summary>正文里有内容的行（每行过一遍 Clean），跳过前 skipping 行；拼起来超过 budget 个字就不再往下读。
    /// 代码块的围栏行不算、块里的行照原文。只有图片的行不占「跳过」的名额。</summary>
    private static List<string> LinesOf(string body, int skipping, int budget, bool droppingImageLines = false)
    {
        var lines = new List<string>();
        var (skipped, length) = (0, 0);
        var blocks = NoteMarkdown.CodeBlocks(body.Length > BlockScanLimit ? NoteText.SafePrefix(body, BlockScanLimit) : body);
        var location = 0;
        while (location < body.Length && length <= budget)
        {
            var (start, end, contentsEnd) = NoteText.Line(body, location);
            location = Math.Max(end, location + 1);
            var raw = body[start..contentsEnd];
            if (droppingImageLines && NoteImages.IsImageOnly(raw))
            {
                continue;
            }

            string line;
            switch (NoteMarkdown.RoleAt(start, blocks))
            {
                case null:
                    line = Clean(raw);
                    break;
                case NoteMarkdown.Role.Content:
                    line = NoteImages.Display(NoteText.TrimSpaces(NoteText.Prefix(raw, ScanLimit)));
                    break;
                default:
                    continue;
            }

            if (line.Length == 0)
            {
                continue;
            }

            if (skipped < skipping && !NoteImages.IsImageOnly(raw))
            {
                skipped++;
                continue;
            }

            length += NoteText.Count(line) + (lines.Count == 0 ? 0 : 1);
            lines.Add(line);
        }

        return lines;
    }

    /// <summary>一行去掉两头的空白、行首的标题标记和任务符号（还有贴进来没转成方框的「- [ ] 」），再去掉 Markdown 的标记。</summary>
    private static string Clean(string raw)
    {
        var index = 0;
        while (index < raw.Length && NoteText.IsWhite(raw[index]))
        {
            index++;
        }

        var line = raw[index..];
        var isContent = false;
        var hashes = 0;
        while (hashes < line.Length && line[hashes] == '#')
        {
            hashes++;
        }

        if (hashes is >= 1 and <= 6 && (hashes == line.Length || NoteText.IsWhite(line[hashes])))
        {
            line = line[hashes..].TrimStart();
            isContent = true;
        }

        if (line.Length > 0 && NoteTasks.StateOf(line[0]) is not null)
        {
            line = line[1..].TrimStart();
            isContent = true;
        }
        else if (!isContent)
        {
            var head = line.Length > 6 ? line[..6] : line;
            if (NoteTasks.BodyFromMarkdown(head) != head)
            {
                line = line[Math.Min(5, line.Length)..].TrimStart();
                isContent = true;
            }
        }

        return NoteText.TrimSpaces(NoteMarkdown.Plain(NoteText.Prefix(line, ScanLimit), blocks: !isContent));
    }
}
