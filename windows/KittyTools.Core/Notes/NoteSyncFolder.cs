// 便签的同步文件夹（PLAN-v13，照 mac Notes/NoteSyncFolder.swift 逐个移植；合并规则在 NoteSync，读写文件夹、什么时候合一轮在
// 执行层）：文件夹里放什么、一个文件怎么写怎么读、一轮扫描下来该做什么——全是纯函数。**和 mac 读写同一个文件夹**，便签文件、
// erased.json 的字节和 mac 一样（Fixtures/notes-sync-golden.json 锁住）。
//
// 文件夹（**每台电脑只写自己的子文件夹**）：
//   kitty-notes-sync.json                  标记：库的编号和格式（写法复用 SyncFolderRules.Marker，读法见 MarkerFrom）
//   devices/<电脑编号>/device.json           这台电脑叫什么、写出去的是第几轮（SyncFolderRules.DeviceJson / ParseDevice）
//   devices/<电脑编号>/notes/<便签编号>.md     这台电脑眼里每条便签的样子（含「最近删除」里的）
//   devices/<电脑编号>/erased.json           这台电脑知道的墓碑（NoteSync.Tombstone）
//   images/<图片编号>.<扩展名>                 正文里的图片：存了就不改，同名就是同一张
// 便签文件：开头是和导出一样的文件头键（kitty-note、title、color、tint、created、modified、revision、archived、pinned、order），
// 后面加同步要的几样（整数毫秒的时刻、删除时刻、版本钟、**内容哈希**），文件头之后**正文原样**。**读的时候从严**（文件夹是信任
// 边界）：先看大小，写了却解不出来的键、重复的键、内容和哈希对不上都当「读不出来」。
// 一轮（Round）：本机的便签 + 本机的墓碑 + **所有子文件夹（含自己的）**里的便签和墓碑 → 每条合一遍（NoteSync.MergeOne）。
// - 读不出来的那一版这一轮不算（只扔这一版）；哪台的墓碑读不出来：整轮不合；标记或墓碑文件是更新的格式：整轮不合。
// - **刹车**（Brakes）：一轮要把本机没删的放进「最近删除」（或真删）的超过 20 条、或者至少 5 条且超过三成，先停下来问。
// 写出去（Publish，合完、落盘之后）：自己子文件夹里那一版和本机的不一样（或读不出来、没有）就重写；本机已经没有、有墓碑的删；
// 墓碑变了重写 erased.json；正文里引用的图片两头补齐。共用的 images/ 里没人引用的图按 ImagePurge 删（宁可少删）。
// 认出「库被退回去了」（Regressed）：哪一版里本机那一格的钟比库里那条的大——执行层换一个新编号，**要在写出去之前做**。
// 执行层要守的先后（照 mac NoteSyncer.round）写在 NoteSyncFolder 末尾的注释里。
using System.Globalization;
using System.Text;
using System.Text.Json;
using KittyTools.Core.Sync;

namespace KittyTools.Core.Notes;

public static class NoteSyncFolder
{
    public const string MarkerName = SyncFolderRules.MarkerFile;

    public const string DevicesName = SyncFolderRules.DevicesFolder;

    public const string NotesName = "notes";

    public const string ErasedName = "erased.json";

    public const string DeviceInfoName = SyncFolderRules.DeviceFile;

    public const string ImagesName = "images";

    /// <summary>便签那部分的名字（和类别名放在同一组里：设置页的勾、刹车的额度、读到的文件属性）。</summary>
    public const string NotesPart = "notes";

    /// <summary>文件夹格式的版本（标记、墓碑文件里写着）：读到更大的整轮不合、说先更新。</summary>
    public const int Format = 1;

    /// <summary>共用的 images/ 里没人引用的图：本机已经没有它的记满几天删、本机还有它的记满几天删。</summary>
    public const int ImageGraceDays = 1;

    /// <summary>同本机图片目录的「没人引用满 30 天才删」（mac NoteImageStore.orphanDays）。</summary>
    public const int ImageOrphanDays = NoteImageRules.OrphanDays;

    /// <summary>那本账在库里（note_meta）的哪一项。</summary>
    public const string ImageLedgerKey = "sync-image-orphans";

    public const int BrakeCount = SyncFolderRules.MaxDeletions;

    public const int BrakeFloor = SyncFolderRules.MinDeletionsForShare;

    /// <summary>一个便签文件最大多少（正文上限 + 64 KB 的头）；钟最多几格、那一行最长多少（UTF-8 字节）。</summary>
    public const int MaxNoteFileBytes = Note.MaxBodyBytes + 64 * 1024;

    public const int MaxClockCells = 1024;

    public const int MaxClockText = 64 * 1024;

    /// <summary>读进来的时刻夹在这个范围里（毫秒）。</summary>
    public const long MaxMilliseconds = 1L << 53;

    private const long Day = 86_400_000;

    private static readonly IReadOnlyDictionary<string, NoteSync.Tombstone> NoTombstones =
        new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal);

    // ---- 标记、墓碑 ----

    /// <summary>标记里要用的两样（mac Marker：kind、format、library；kind 读的时候不核对）。</summary>
    public sealed record Marker(string Library, int Format = NoteSyncFolder.Format);

    /// <summary>读标记（mac 的 JSONDecoder 口径：kind 字符串、format 整数、library 字符串都要有；格式比这一版新的也读出来，
    /// 由 Check 说「更新的格式」）。写标记用 SyncFolderRules.Marker（它读的时候只认 format 1，分不出「更新的格式」）。</summary>
    public static Marker? MarkerFrom(ReadOnlySpan<byte> utf8)
    {
        using var document = NoteFileHeader.Json(utf8);
        if (document is null || document.RootElement.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var root = document.RootElement;
        return NoteFileHeader.TryGetFirst(root, "kind", out var kind) && kind.ValueKind == JsonValueKind.String &&
               NoteFileHeader.TryGetFirst(root, "format", out var format) &&
               NoteFileHeader.TryGetInteger(format, out var version) &&
               NoteFileHeader.TryGetFirst(root, "library", out var library) && library.ValueKind == JsonValueKind.String &&
               Text(library) is { } id
            ? new Marker(id, (int)Math.Clamp(version, int.MinValue, int.MaxValue))
            : null;
    }

    /// <summary>读 erased.json 的结果。</summary>
    public enum TombstoneRead
    {
        Read,

        /// <summary>读不出来（没下载完、写坏了）。</summary>
        Unreadable,

        /// <summary>更新的格式。</summary>
        Newer,
    }

    /// <summary>一台电脑的墓碑文件读成什么样（mac Tombstones：.read([..]) / .unreadable / .newer）。按值比。</summary>
    public sealed record Tombstones(TombstoneRead State, IReadOnlyDictionary<string, NoteSync.Tombstone> Entries)
    {
        public static readonly Tombstones Empty = new(TombstoneRead.Read, NoTombstones);

        public static readonly Tombstones Unreadable = new(TombstoneRead.Unreadable, NoTombstones);

        public static readonly Tombstones Newer = new(TombstoneRead.Newer, NoTombstones);

        public static Tombstones Of(IReadOnlyDictionary<string, NoteSync.Tombstone> entries) => new(TombstoneRead.Read, entries);

        public bool Equals(Tombstones? other)
            => other is not null && State == other.State && (State != TombstoneRead.Read || SameTombstones(Entries, other.Entries));

        public override int GetHashCode() => HashCode.Combine(State, Entries.Count);
    }

    /// <summary>erased.json：编号 → 被删那一版的钟和状态时刻（整数毫秒）。和 mac 的 JSONEncoder（prettyPrinted + sortedKeys）一字不差。</summary>
    public static byte[] ErasedData(IReadOnlyDictionary<string, NoteSync.Tombstone> tombstones)
    {
        var builder = new StringBuilder("{\n  \"erased\" : {");
        if (tombstones.Count == 0)
        {
            builder.Append("\n\n  }");
        }
        else
        {
            var first = true;
            foreach (var (id, tombstone) in tombstones.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                builder.Append(first ? "\n" : ",\n").Append("    ").Append(NoteFileHeader.JsonString(id))
                    .Append(" : {\n      \"clock\" : ").Append(NoteFileHeader.JsonString(NoteSync.ClockText(tombstone.Clock)))
                    .Append(",\n      \"state\" : ").Append(tombstone.State.ToString(CultureInfo.InvariantCulture))
                    .Append("\n    }");
                first = false;
            }

            builder.Append("\n  }");
        }

        builder.Append(",\n  \"format\" : ").Append(Format.ToString(CultureInfo.InvariantCulture)).Append("\n}");
        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    /// <summary>读 erased.json（mac tombstones(from:)）：整个解不出来是 Unreadable、格式更新是 Newer；编号不是 UUID 的条目、钟太长的条目
    /// 跳过；同一个编号写了几份（大小写不同）并起来。</summary>
    // ponytail: Swift 的解析器对没用上的那部分比这里宽（多出来的键的值写成 01、"\x" 它照读，这里整个算读不出来）；mac 写出去的
    // 从来没有这种
    public static Tombstones TombstonesFrom(ReadOnlySpan<byte> data)
    {
        using var document = NoteFileHeader.Json(data);
        if (document is null || document.RootElement.ValueKind != JsonValueKind.Object ||
            !NoteFileHeader.TryGetFirst(document.RootElement, "format", out var formatElement) ||
            !NoteFileHeader.TryGetInteger(formatElement, out var format) ||
            !NoteFileHeader.TryGetFirst(document.RootElement, "erased", out var erased) ||
            erased.ValueKind != JsonValueKind.Object)
        {
            return Tombstones.Unreadable;
        }

        // 先整个解完（解不出来就是读不出来，不管格式新不新），再看格式
        var entries = new List<(string Raw, string Clock, long State)>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in erased.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                continue;
            }

            var entry = property.Value;
            if (entry.ValueKind != JsonValueKind.Object ||
                !NoteFileHeader.TryGetFirst(entry, "clock", out var clock) || clock.ValueKind != JsonValueKind.String ||
                Text(clock) is not { } clockText ||
                !NoteFileHeader.TryGetFirst(entry, "state", out var stateElement) ||
                !NoteFileHeader.TryGetInteger(stateElement, out var state))
            {
                return Tombstones.Unreadable;
            }

            entries.Add((property.Name, clockText, state));
        }

        if (format > Format)
        {
            return Tombstones.Newer;
        }

        var result = new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal);
        foreach (var (raw, clockText, state) in entries)
        {
            if (NoteFileHeader.UuidText(raw) is not { } id || Encoding.UTF8.GetByteCount(clockText) > MaxClockText)
            {
                continue;
            }

            var tombstone = new NoteSync.Tombstone(NoteSync.ClockFrom(clockText), Clamp(state));
            result[id] = result.TryGetValue(id, out var old) ? old.Merged(tombstone) : tombstone;
        }

        return Tombstones.Of(result);
    }

    // ---- 便签文件 ----

    /// <summary>一条便签在文件夹里的文件名。</summary>
    public static string FileName(string id) => id + ".md";

    /// <summary>文件名 → 便签编号（不是 `&lt;UUID&gt;.md` 的给 null）。</summary>
    public static string? NoteId(string name)
        => name.EndsWith(".md", StringComparison.Ordinal) ? NoteFileHeader.UuidText(name[..^3]) : null;

    /// <summary>共用 images/、本机图片目录里的文件名 → 图片编号（mac NoteImageStore.identifier(ofFileNamed:)：`&lt;UUID&gt;.&lt;1–10 个小写字母数字&gt;`）。
    /// 不用 NoteImageRules.Identifier：它走 Guid.TryParseExact，.NET 为了兼容认每段开头的 + 和 0x，mac 不认。</summary>
    public static Guid? ImageId(string name)
    {
        var parts = NoteFileHeader.Split(name, '.', omittingEmpty: false);
        if (parts.Count != 2 || NoteFileHeader.UuidText(parts[0]) is not { } id ||
            parts[1].Length is < 1 or > NoteImages.MaxExtension ||
            !parts[1].All(ch => ch is >= 'a' and <= 'z' or >= '0' and <= '9'))
        {
            return null;
        }

        return Guid.ParseExact(id, "D");
    }

    /// <summary>是不是同步文件（设置里「导入…」认出来就跳过：它读不全删除时刻）。</summary>
    public static bool IsSyncFile(string text)
    {
        if (!text.StartsWith("---\n", StringComparison.Ordinal))
        {
            return false;
        }

        var head = NoteText.Prefix(text, 4096);
        for (var index = head.IndexOf("\nsync-clock:", StringComparison.Ordinal); index >= 0;
             index = head.IndexOf("\nsync-clock:", index + 1, StringComparison.Ordinal))
        {
            // \r\n 在 Swift 里是一个字，不是 \n
            if (index == 0 || head[index - 1] != '\r')
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>一条便签的文件（mac text(of:)）：导出同样的键 + 同步的几样，文件头之后正文原样。zone：created / modified 两行用的时区。</summary>
    public static string Text(Note note, TimeZoneInfo zone)
    {
        var builder = new StringBuilder(note.Body.Length + 512);
        builder.Append("---\nkitty-note: ").Append(note.Id).Append('\n');
        if (note.Title.Length > 0)
        {
            builder.Append("title: ").Append(NoteFileHeader.JsonString(note.Title)).Append('\n');
        }

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
            .Append("order: ").Append(NoteFileHeader.Number(note.Order)).Append('\n')
            .Append("sync-created: ").Append(Invariant(note.CreatedAt)).Append('\n')
            .Append("sync-modified: ").Append(Invariant(note.ModifiedAt)).Append('\n')
            .Append("sync-state: ").Append(Invariant(note.StateTime)).Append('\n')
            .Append("sync-order: ").Append(Invariant(note.OrderTime)).Append('\n');
        if (note.DeletedAt is { } deleted)
        {
            builder.Append("sync-deleted: ").Append(Invariant(deleted)).Append('\n');
        }

        builder.Append("sync-clock: ").Append(NoteSync.ClockText(note.Clock)).Append('\n')
            .Append("sync-hash: ").Append(NoteSync.ContentHash(note)).Append("\n---\n")
            .Append(note.Body);
        return builder.ToString();
    }

    /// <summary>读回来（mac note(from:fileID:)）：认不出给 null（这一版这一轮不算）。</summary>
    public static Note? NoteFrom(string text, string fileId) => Parse(text, fileId)?.Note;

    /// <summary>同 NoteFrom，连核对过的内容哈希一起给（Device.Hashes：一轮里合的时候不用再算一遍）。要是自家的同步文件（第一行 `---`、
    /// 40 行里收尾、头里有合法的 kitty-note、sync-clock、sync-hash，编号对得上文件名），写了的键都要解得出来、不许重复，内容和哈希
    /// 对得上；文字过一遍收拾（同导入）。</summary>
    public static (Note Note, string Hash)? Parse(string text, string fileId)
    {
        if (!text.StartsWith("---\n", StringComparison.Ordinal) || Encoding.UTF8.GetByteCount(text) > MaxNoteFileBytes)
        {
            return null;
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var cursor = 4;
        var closed = false;
        for (var count = 0; count < 40; count++)
        {
            var end = LineEnd(text, cursor);
            if (end < 0)
            {
                break;
            }

            var line = text[cursor..end];
            cursor = end + 1;
            if (line == "---")
            {
                closed = true;
                break;
            }

            var colon = NoteFileHeader.IndexOfCharacter(line, ':');
            if (colon < 0)
            {
                return null;
            }

            var key = NoteText.TrimSpaces(line[..colon]);
            if (!values.TryAdd(key, NoteText.TrimSpaces(line[(colon + 1)..])))
            {
                return null;
            }
        }

        if (!closed ||
            Value("kitty-note") is not { } rawId || NoteFileHeader.UuidText(rawId) is not { } id || id != fileId ||
            Value("sync-clock") is not { } clockText || Encoding.UTF8.GetByteCount(clockText) > MaxClockText ||
            Value("sync-hash") is not { } hash ||
            Integer("sync-created") is not { } created ||
            Integer("sync-modified") is not { } modified ||
            Integer("sync-state") is not { } state ||
            Integer("sync-order") is not { } ordered ||
            Integer("color") is not { } preset || preset is < 0 or >= Note.ColorCount ||
            (Value("order") is { } rawOrder ? NoteFileHeader.ParseDouble(rawOrder) : null) is not { } order ||
            !double.IsFinite(order) ||
            Integer("revision") is not { } revision ||
            (Value("archived") is { } rawArchived ? NoteFileHeader.ParseBool(rawArchived) : null) is not { } archived ||
            (Value("pinned") is { } rawPinned ? NoteFileHeader.ParseBool(rawPinned) : null) is not { } pinned)
        {
            return null;
        }

        // 选填的：写了就要解得出来
        var title = string.Empty;
        if (Value("title") is { } rawTitle)
        {
            if (NoteFileHeader.JsonDecode(rawTitle) is not { } decoded)
            {
                return null;
            }

            title = decoded;
        }

        int? tint = null;
        if (Value("tint") is { } rawTint)
        {
            if (NoteFileHeader.JsonDecode(rawTint) is not { } decoded || Note.RgbFromHex(decoded) is not { } value)
            {
                return null;
            }

            tint = value;
        }

        long? deletedAt = null;
        if (Value("sync-deleted") is { } rawDeleted)
        {
            if (NoteFileHeader.ParseInt64(rawDeleted) is not { } value)
            {
                return null;
            }

            deletedAt = Clamp(value);
        }

        var clock = NoteSync.ClockFrom(clockText);
        if (clock.Count > MaxClockCells)
        {
            return null;
        }

        var body = Note.SanitizedText(text[cursor..]);
        if (Encoding.UTF8.GetByteCount(body) > Note.MaxBodyBytes)
        {
            return null;
        }

        var note = new Note
        {
            Id = id,
            Title = Note.SanitizedTitle(title),
            Body = body,
            Color = Note.ColorFrom((int)preset, tint),
            CreatedAt = Clamp(created),
            ModifiedAt = Clamp(modified),
            Revision = (int)Math.Clamp(revision, 0, Note.MaxRevision),
            IsArchived = archived,
            IsPinned = pinned,
            Order = order,
            DeletedAt = deletedAt,
            StateChangedAt = Clamp(state),
            OrderChangedAt = Clamp(ordered),
            Clock = clock,
        };
        return NoteSync.ContentHash(note) == hash ? (note, hash) : null;

        string? Value(string name) => values.TryGetValue(name, out var value) ? value : null;

        long? Integer(string name) => Value(name) is { } raw ? NoteFileHeader.ParseInt64(raw) : null;
    }

    /// <summary>从 start 起下一个换行在哪：Swift 按字找「\n」，\r\n 是一个字、不算。</summary>
    private static int LineEnd(string text, int start)
    {
        for (var index = text.IndexOf('\n', start); index >= 0; index = text.IndexOf('\n', index + 1))
        {
            if (index == 0 || text[index - 1] != '\r')
            {
                return index;
            }
        }

        return -1;
    }

    // ---- 一轮 ----

    /// <summary>读到的一台电脑的子文件夹（执行层读文件时填）。</summary>
    public sealed class Device
    {
        public string? Name { get; set; }

        /// <summary>device.json 里记的「写出去的是第几轮」。</summary>
        public int? Epoch { get; set; }

        /// <summary>读出来的便签（编号 → 那一版）。</summary>
        public Dictionary<string, Note> Notes { get; init; } = new(StringComparer.Ordinal);

        /// <summary>读出来的便签的内容哈希（Parse 给的、核对过的；手搭的文件夹可以不给，合的时候现算）。</summary>
        public Dictionary<string, string> Hashes { get; init; } = new(StringComparer.Ordinal);

        /// <summary>有文件、但读不出来的（没下载完、写坏了、格式认不出）。</summary>
        public HashSet<string> Unreadable { get; init; } = new(StringComparer.Ordinal);

        /// <summary>墓碑文件（没有这个文件 = Tombstones.Empty）。</summary>
        public Tombstones Erased { get; set; } = Tombstones.Empty;
    }

    /// <summary>读到的整个文件夹。</summary>
    public sealed class Folder
    {
        /// <summary>标记（没有、读不出来 = null）。</summary>
        public Marker? Marker { get; set; }

        /// <summary>电脑编号 → 它的子文件夹（含本机自己的）。</summary>
        public Dictionary<string, Device> Devices { get; init; } = new(StringComparer.Ordinal);

        /// <summary>images/ 里的文件名。</summary>
        public HashSet<string> Images { get; init; } = new(StringComparer.Ordinal);
    }

    public enum StopKind
    {
        /// <summary>没有标记、或者标记里的编号不是这个库的。</summary>
        NotTheFolder,

        /// <summary>这台电脑的墓碑读不出来（多半是还没下载完；Stop.Device 是哪台）。</summary>
        UnreadableTombstones,

        /// <summary>文件夹是更新版本的 Kitty Tools 写的。</summary>
        NewerFormat,
    }

    /// <summary>这一轮为什么不合。</summary>
    public sealed record Stop(StopKind Kind, string? Device = null);

    /// <summary>合一轮的结果（mac Round；Stop 非 null = 这一轮不合，别的都是空的）。</summary>
    public sealed class RoundPlan
    {
        public Stop? Stop { get; init; }

        /// <summary>要落下去的（仓库的 ApplySync）：只有和本机不一样的、或者带着要另存的。</summary>
        public Dictionary<string, NoteSync.Merge> Merges { get; } = new(StringComparer.Ordinal);

        /// <summary>这一轮的墓碑（本机的和各台的并起来）：ApplySync 的第二个参数。</summary>
        public Dictionary<string, NoteSync.Tombstone> Tombstones { get; init; } = new(StringComparer.Ordinal);

        /// <summary>本机没删的、这一轮要放进「最近删除」或真删掉的有几条；本机一共有几条没删的。</summary>
        public int Trashing { get; set; }

        public int Alive { get; set; }

        /// <summary>这一轮读不出来、没算进去的那几版（编号）。</summary>
        public HashSet<string> Skipped { get; } = new(StringComparer.Ordinal);

        /// <summary>要不要先停下来问。</summary>
        public bool Brakes => NoteSyncFolder.Brakes(Trashing, Alive);
    }

    /// <summary>刹车：超过 20 条；或者至少 5 条、超过三成（同 SyncFolderRules.ShouldBrake，同步那几类也用它）。</summary>
    public static bool Brakes(int trashing, int alive) => SyncFolderRules.ShouldBrake(trashing, alive);

    /// <summary>是不是那个文件夹：有标记、格式不比这一版新、库编号对得上（文件夹里的东西信得过之前什么都不做）。</summary>
    public static Stop? Check(Marker? marker, string library)
    {
        if (marker is null)
        {
            return new Stop(StopKind.NotTheFolder);
        }

        if (marker.Format > Format)
        {
            return new Stop(StopKind.NewerFormat);
        }

        return marker.Library == library ? null : new Stop(StopKind.NotTheFolder);
    }

    /// <summary>合一轮（mac round）：local / erased 是本机的便签（全部，含最近删除里的）和墓碑，folder 是读到的文件夹，library 是本机记着的
    /// 库编号，now 是现在（整数毫秒）。</summary>
    public static RoundPlan Round(
        IReadOnlyList<Note> local, IReadOnlyDictionary<string, NoteSync.Tombstone> erased, Folder folder, string library, long now)
    {
        if (Check(folder.Marker, library) is { } stop)
        {
            return new RoundPlan { Stop = stop };
        }

        var tombstones = new Dictionary<string, NoteSync.Tombstone>(erased, StringComparer.Ordinal);
        foreach (var (device, other) in folder.Devices.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            switch (other.Erased.State)
            {
                case TombstoneRead.Newer:
                    return new RoundPlan { Stop = new Stop(StopKind.NewerFormat) };
                case TombstoneRead.Unreadable:
                    return new RoundPlan { Stop = new Stop(StopKind.UnreadableTombstones, device) };
                default:
                    foreach (var (id, tombstone) in other.Erased.Entries)
                    {
                        tombstones[id] = tombstones.TryGetValue(id, out var old) ? old.Merged(tombstone) : tombstone;
                    }

                    break;
            }
        }

        var round = new RoundPlan { Tombstones = tombstones };
        var remotes = new Dictionary<string, List<Note>>(StringComparer.Ordinal);
        var hashes = new Dictionary<string, List<string?>>(StringComparer.Ordinal);
        foreach (var other in folder.Devices.Values)
        {
            round.Skipped.UnionWith(other.Unreadable);
            foreach (var (id, note) in other.Notes)
            {
                if (!remotes.TryGetValue(id, out var versions))
                {
                    remotes[id] = versions = new List<Note>();
                    hashes[id] = new List<string?>();
                }

                versions.Add(note);
                hashes[id].Add(other.Hashes.TryGetValue(id, out var hash) ? hash : null);
            }
        }

        var mine = new Dictionary<string, Note>(StringComparer.Ordinal);
        foreach (var note in local)
        {
            mine[note.Id] = note;
        }

        round.Alive = local.Count(note => note.DeletedAt is null);
        var ids = new HashSet<string>(mine.Keys, StringComparer.Ordinal);
        ids.UnionWith(remotes.Keys);
        foreach (var id in ids)
        {
            var old = mine.TryGetValue(id, out var found) ? found : null;
            var merge = NoteSync.MergeOne(
                old, remotes.TryGetValue(id, out var versions) ? versions : [],
                tombstones.TryGetValue(id, out var tombstone) ? tombstone : null, now,
                hashes.TryGetValue(id, out var known) ? known : null);
            var fresh = merge.Copies.Any(copy => !mine.ContainsKey(copy.Id) && !tombstones.ContainsKey(copy.Id));
            if (merge.Note == old && !fresh)
            {
                continue;
            }

            round.Merges[id] = merge;
            if (old is { DeletedAt: null } && merge.Note is not { DeletedAt: null })
            {
                round.Trashing++;
            }
        }

        return round;
    }

    /// <summary>写出去的计划（mac Publish）：merges 落下去之后，本机的便签和墓碑 → 自己子文件夹里要重写 / 删的、erased.json 要不要重写、
    /// 图片传上去 / 拿下来、共用 images/ 里要删的。</summary>
    public sealed class PublishPlan
    {
        /// <summary>要（重）写的便签（执行层写成 Text(note, zone)，文件名 FileName(id)）。</summary>
        public List<Note> Writes { get; } = new();

        /// <summary>要删的便签文件（编号：本机已经没有了、有墓碑的）。</summary>
        public List<string> Deletes { get; } = new();

        /// <summary>erased.json 要重写成这样（null = 不用动）。</summary>
        public IReadOnlyDictionary<string, NoteSync.Tombstone>? Erased { get; set; }

        /// <summary>文件夹里没有、要传上去的图片；本机没有、要拿下来的图片（宽度都是 null，文件名 Image.FileName）。</summary>
        public List<NoteImages.Image> Uploads { get; } = new();

        public List<NoteImages.Image> Downloads { get; } = new();

        /// <summary>共用的 images/ 里要删的（文件名；执行层按 ImagePurge 定的填）。</summary>
        public List<string> ImageDeletes { get; set; } = new();

        /// <summary>什么都不用做。</summary>
        public bool IsEmpty => !TouchesNotes && Uploads.Count == 0 && Downloads.Count == 0 && ImageDeletes.Count == 0;

        /// <summary>便签文件、墓碑文件要动（这才算写出去新的一轮：图片两头补齐不算，执行层的 epoch）。</summary>
        public bool TouchesNotes => Writes.Count > 0 || Deletes.Count > 0 || Erased is not null;
    }

    /// <summary>own：读到的自己的子文件夹（还没有 = null）；localImages：本机图片目录里的文件名；folderImages：images/ 里的文件名。</summary>
    public static PublishPlan Publish(
        IReadOnlyList<Note> local, IReadOnlyDictionary<string, NoteSync.Tombstone> erased, Device? own,
        IReadOnlySet<string> localImages, IReadOnlySet<string> folderImages)
    {
        var plan = new PublishPlan();
        // 自己文件夹里那一版和本机的不一样（读不出来、没有都算不一样）就重写
        foreach (var note in local)
        {
            if (own is null || !own.Notes.TryGetValue(note.Id, out var written) || written != note)
            {
                plan.Writes.Add(note);
            }
        }

        // 只删永久删过的（有墓碑）：本机没有、又没墓碑的，读得出来的这一轮已经合回来了；读不出来的可能是唯一的一份，留着
        var ids = local.Select(note => note.Id).ToHashSet(StringComparer.Ordinal);
        if (own is not null)
        {
            var onDisk = new HashSet<string>(own.Notes.Keys, StringComparer.Ordinal);
            onDisk.UnionWith(own.Unreadable);
            plan.Deletes.AddRange(onDisk.Where(id => !ids.Contains(id) && erased.ContainsKey(id)).OrderBy(id => id, StringComparer.Ordinal));
        }

        if (own is null || !own.Erased.Equals(Tombstones.Of(erased)))
        {
            plan.Erased = new Dictionary<string, NoteSync.Tombstone>(erased, StringComparer.Ordinal);
        }

        var referenced = new Dictionary<string, NoteImages.Image>(StringComparer.Ordinal);
        foreach (var note in local)
        {
            if (!NoteImages.ContainsToken(note.Body))
            {
                continue;
            }

            foreach (var (_, image) in NoteImages.Matches(note.Body))
            {
                var bare = image with { Width = null };
                referenced[bare.FileName] = bare;
            }
        }

        foreach (var (name, image) in referenced.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (localImages.Contains(name) && !folderImages.Contains(name))
            {
                plan.Uploads.Add(image);
            }

            if (!localImages.Contains(name) && folderImages.Contains(name))
            {
                plan.Downloads.Add(image);
            }
        }

        return plan;
    }

    /// <summary>共用 images/ 这一轮能删哪几张（mac imagePurge 的结果）：要删的（排好序）、新的账（文件名 → 第一次发现没人引用的
    /// 时刻，毫秒）、账上还没到期的那几张里最早哪一刻到期（null = 没有）。</summary>
    public sealed record ImagePurgePlan(IReadOnlyList<string> Deletes, IReadOnlyDictionary<string, long> Ledger, long? Due);

    /// <summary>共用的 images/ 这一轮能删哪几张。一张图同时满足才删：本机和所有子文件夹里的便签（含最近删除里的）都不再引用它；
    /// 这台电脑记着它没人引用已经有一阵（本机图片目录里也没有它的满 ImageGraceDays 天，不然满 ImageOrphanDays 天）；这一轮整个
    /// 文件夹都读得清楚（readable：IsReadable 再加执行层那一半——没下载完的、刚改过的、读不出来的 device.json、列不出来的目录）。
    /// 读得不清楚时一张不删、账原样。要删的也照记（删成了下一轮文件不在了再去掉）；有人引用的、文件不在了的从账上去掉。</summary>
    public static ImagePurgePlan ImagePurge(
        IReadOnlySet<string> folderImages, IReadOnlySet<Guid> referenced, IReadOnlySet<Guid> localImages,
        IReadOnlyDictionary<string, long> ledger, bool readable, long now)
    {
        if (!readable)
        {
            return new ImagePurgePlan(Array.Empty<string>(), ledger, null);
        }

        var deletes = new List<string>();
        var kept = new Dictionary<string, long>(StringComparer.Ordinal);
        long? due = null;
        foreach (var name in folderImages.Order(StringComparer.Ordinal))
        {
            if (ImageId(name) is not { } id || referenced.Contains(id))
            {
                continue;
            }

            var since = ledger.TryGetValue(name, out var noted) ? noted : now;
            kept[name] = since;
            var days = localImages.Contains(id) ? ImageOrphanDays : ImageGraceDays;
            var deadline = since + days * Day;
            if (now >= deadline)
            {
                deletes.Add(name);
            }
            else
            {
                due = due is { } earlier ? Math.Min(earlier, deadline) : deadline;
            }
        }

        return new ImagePurgePlan(deletes, kept, due);
    }

    /// <summary>账存进库里的样子：文件名 → 毫秒（同 mac 的 JSONEncoder prettyPrinted + sortedKeys）。</summary>
    public static string LedgerText(IReadOnlyDictionary<string, long> ledger)
    {
        if (ledger.Count == 0)
        {
            return "{\n\n}";
        }

        var builder = new StringBuilder("{");
        var first = true;
        foreach (var (name, time) in ledger.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            builder.Append(first ? "\n  " : ",\n  ").Append(NoteFileHeader.JsonString(name)).Append(" : ")
                .Append(time.ToString(CultureInfo.InvariantCulture));
            first = false;
        }

        return builder.Append("\n}").ToString();
    }

    /// <summary>读回来：没有、写坏了都当空账（从头记：只会晚删，不会早删）。</summary>
    public static Dictionary<string, long> LedgerFrom(string? text)
    {
        var ledger = new Dictionary<string, long>(StringComparer.Ordinal);
        if (text is null)
        {
            return ledger;
        }

        using var document = NoteFileHeader.Json(Encoding.UTF8.GetBytes(text));
        if (document is null || document.RootElement.ValueKind != JsonValueKind.Object)
        {
            return ledger;
        }

        foreach (var property in document.RootElement.EnumerateObject())
        {
            // 重复的键用第一个，后面的不看（同 Swift JSONDecoder）
            if (ledger.ContainsKey(property.Name))
            {
                continue;
            }

            if (!NoteFileHeader.TryGetInteger(property.Value, out var time))
            {
                return new Dictionary<string, long>(StringComparer.Ordinal);
            }

            ledger[property.Name] = Clamp(time);
        }

        return ledger;
    }

    /// <summary>便签和墓碑都读得出来：每台的墓碑文件读到了、没有读不出来的便签文件（ImagePurge 的 readable 还要执行层那一半）。</summary>
    public static bool IsReadable(Folder folder)
        => folder.Devices.Values.All(device => device.Erased.State == TombstoneRead.Read && device.Unreadable.Count == 0);

    /// <summary>文件夹里各台的便签（含最近删除里的）正文引用到的图片编号。</summary>
    public static HashSet<Guid> ReferencedImages(Folder folder)
    {
        var ids = new HashSet<Guid>();
        foreach (var device in folder.Devices.Values)
        {
            foreach (var note in device.Notes.Values)
            {
                if (NoteImages.ContainsToken(note.Body))
                {
                    ids.UnionWith(NoteImages.Ids(note.Body));
                }
            }
        }

        return ids;
    }

    /// <summary>库被退回去了吗（从旧备份恢复了整个数据目录）：哪一版（各子文件夹里的，含自己的）里本机那一格的钟比库里那条的大。
    /// 返回这样的便签编号（空 = 没退回去）；本机没有的不算。</summary>
    public static HashSet<string> Regressed(IReadOnlyList<Note> local, Folder folder, string device)
    {
        var mine = new Dictionary<string, Note>(StringComparer.Ordinal);
        foreach (var note in local)
        {
            mine[note.Id] = note;
        }

        var found = new HashSet<string>(StringComparer.Ordinal);
        foreach (var other in folder.Devices.Values)
        {
            foreach (var (id, version) in other.Notes)
            {
                if (mine.TryGetValue(id, out var note) && NoteSync.CountOf(version.Clock, device) > NoteSync.CountOf(note.Clock, device))
                {
                    found.Add(id);
                }
            }
        }

        return found;
    }

    private static long Clamp(long milliseconds) => Math.Clamp(milliseconds, -MaxMilliseconds, MaxMilliseconds);

    private static string Invariant(long value) => value.ToString(CultureInfo.InvariantCulture);

    /// <summary>JSON 字符串的值；落单的代理项这类 GetString 解不出来的给 null（mac 的 JSONDecoder 整个读不出来）。</summary>
    private static string? Text(JsonElement element)
    {
        try
        {
            return element.GetString();
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private static bool SameTombstones(
        IReadOnlyDictionary<string, NoteSync.Tombstone> a, IReadOnlyDictionary<string, NoteSync.Tombstone> b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        foreach (var (id, tombstone) in a)
        {
            if (!b.TryGetValue(id, out var other) || !tombstone.Equals(other))
            {
                return false;
            }
        }

        return true;
    }

    // ---- 执行层（App 的便签同步，照 mac NoteSyncer.round）要守的先后 ----
    // 1. 便签这部分开着时，先把仓库落盘（写进文件夹的必须是落下去了的）。
    // 2. 线程池上读文件夹：标记、每台的 device.json / erased.json（≤ 32 MB）/ notes/*.md（≤ MaxNoteFileBytes）、images/ 的文件名。
    //    文件按 NoteFileHeader.Decode 解（严格 UTF-8、去一个 BOM），便签文件过 Parse（读不出来的记进 Device.Unreadable，不是丢掉），
    //    墓碑过 TombstonesFrom；云盘还没下载的占位文件不读，那个文件算读不出来（墓碑文件 = Tombstones.Unreadable）。
    // 3. 文件夹不在了 → 停（不替它建回来）。标记有、却读不出来 → 停（「还在下载」，别新建一个盖掉）。Check(marker, library) 不过 → 停。
    //    **自己的 device.json 有、却读不出来 → 停**：认清文件夹之前不换编号、不合。
    // 4. 认库被退回去了：Regressed(本机, 文件夹, 本机编号) 非空，或者自己子文件夹 device.json 的 epoch 比库里记的大（这时把和自己
    //    文件夹里那版不一样的几条也加进去）→ 先换编号（仓库 SwitchDevice：那几条去掉旧编号那一格、新编号那一格 +1；**先落盘这几条、
    //    成了再记新编号**）。**要在写出去之前做**。
    // 5. Round(本机全部便签, 本机墓碑, 文件夹, 库编号, 现在)；Stop 非 null → 停。Brakes 且 Trashing 超过用户上次点「继续」时的条数 → 停下来问。
    // 6. **正在编辑的先不换**：有焦点的编辑器里的、挂着没确认的组字的那几条从 Merges 里拿掉（下一轮再合）。
    // 7. 仓库 ApplySync(Merges, Tombstones) → 落盘；没落下去就停，不写文件。Merges 里有新另存出来的那条 → 胶囊上说一句。
    // 8. Publish(落盘之后的本机便签, 本机墓碑, 自己的子文件夹, 本机图片文件名, images/ 文件名)；第 6 步拿掉的那几条也从 Writes 里拿掉
    //    （没合的样子写出去，别的电脑会每轮另存一条半截）。ImageDeletes 照 ImagePurge 填（账在库里 ImageLedgerKey；本机图片目录
    //    没接上、账读不出来都不删）。
    // 9. TouchesNotes 时**先在库里把 epoch +1**，再写：便签文件（先写临时名再改名）、要删的、erased.json、图片两头补齐（临时名再改名，
    //    目标已经有了就不动）、共用图片要删的（删不成只记日志）、别的几类，**device.json 最后写**（前面都写成了、内容变了才写）。
    // 10. 写成了的便签告诉仓库（Published：这次运行里新建的空白便签丢掉时要留墓碑）；删成了的共用图片从账上去掉。
}
