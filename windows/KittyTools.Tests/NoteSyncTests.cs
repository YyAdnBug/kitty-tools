// 便签同步（PLAN-v13）：NoteSync / NoteSyncFolder / NoteFileHeader 和 mac 一字不差。
// ① NoteSyncGoldenTests：Fixtures/notes-sync-golden.json 是在 Mac 上直接编 mac 的源码跑出来的（windows/tools/notes-sync-golden.swift，
//    怎么跑见它的文件头），逐个比：哈希、另存编号、钟的写法和读法、ISO 时刻、Double 的写法、JSON 字符串、便签文件的写和读
//    （含被动过的）、墓碑文件、标记、合一条、一轮、写出去、退回去、共用图片的清理、账。
// ② NoteSyncMergeTests / NoteSyncFolderTests：mac NoteSyncTests.swift、NoteSyncFolderTests.swift 里纯函数的用例，期望值原样。
//    跳过的：NoteSyncTests.swift 后半的仓库用例（NoteStore：钟和时刻怎么走、墓碑落盘、电脑编号、0.5.0 的库、applySync、
//    switchDevice、导入接着墓碑的钟——仓库层的测试管）；NoteSyncFolderTests.swift 里拿导出文件头（NoteMarkdownFiles.parseHeader）
//    读同步文件的那几句（Windows 还没有导出文件头）。
// ③ NoteSyncFuzzTests：mac NoteSyncFuzzTests.swift，仓库换成 NoteBook（仓库在内存里的那一半）。默认 4 个种子 × 300 步随全量跑；
//    KITTY_NOTES_SYNC_FUZZ=<步数>（每 300 步一个种子）多跑，KITTY_NOTES_SYNC_FUZZ_SEED=<起始种子> 换一批。
using System.Globalization;
using System.Text;
using System.Text.Json;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

/// <summary>样本、单测、随机测试共用的小工具。</summary>
internal static class NoteSyncKit
{
    public const long T0 = 1_800_000_000_000;

    /// <summary>t0 之后多少秒（整数毫秒）。</summary>
    public static long At(double seconds) => T0 + (long)Math.Round(seconds * 1000);

    public static Dictionary<string, long> C(params (string Device, long Count)[] cells)
    {
        var clock = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var (device, count) in cells)
        {
            clock[device] = count;
        }

        return clock;
    }

    public static string NewId() => Guid.NewGuid().ToString("D").ToUpperInvariant();

    public static readonly IReadOnlyDictionary<string, NoteSync.Tombstone> NoTombstones =
        new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal);

    public static bool SameTombstones(
        IReadOnlyDictionary<string, NoteSync.Tombstone> a, IReadOnlyDictionary<string, NoteSync.Tombstone> b)
        => NoteSyncFolder.Tombstones.Of(a).Equals(NoteSyncFolder.Tombstones.Of(b));

    public static bool SameLedger(IReadOnlyDictionary<string, long> a, IReadOnlyDictionary<string, long> b)
        => a.Count == b.Count && a.All(pair => b.TryGetValue(pair.Key, out var value) && value == pair.Value);
}

[TestClass]
public sealed class NoteSyncGoldenTests
{
    /// <summary>ICU 在 1582-10-15 之前用儒略历：这之前（留一天）的时刻不比 ISO 那两行（NoteFileHeader.Iso 的 ponytail）。</summary>
    private const long GregorianStart = -12_219_292_800_000 + 86_400_000;

    private const long LatestIso = 253_402_300_799_999;

    private static readonly TimeZoneInfo Utc8 = Zone(8 * 3600);

    private static TimeZoneInfo Zone(long seconds)
    {
        var id = "UTC" + seconds.ToString(CultureInfo.InvariantCulture);
        return TimeZoneInfo.CreateCustomTimeZone(id, TimeSpan.FromSeconds(seconds), id, id);
    }

    [TestMethod]
    public void EverySampleMatchesTheMac()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "notes-sync-golden.json");
        Assert.IsTrue(File.Exists(path), path);
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var failures = new List<string>();
        var index = 0;
        foreach (var item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var kind = item.GetProperty("kind").GetString() ?? string.Empty;
            string? problem;
            try
            {
                problem = Check(kind, item.GetProperty("input"), item.GetProperty("output"));
            }
            catch (Exception error)
            {
                problem = error.GetType().Name + "：" + error.Message;
            }

            if (problem is not null)
            {
                failures.Add($"#{index} {kind}：{problem}");
            }

            index++;
        }

        Assert.IsTrue(index > 1500, $"样本只有 {index} 个");
        Assert.AreEqual(0, failures.Count, string.Join("\n", failures.Take(40)));
    }

    private static string? Check(string kind, JsonElement input, JsonElement output) => kind switch
    {
        "contentHash" => Same(output.GetString(), NoteSync.ContentHash(NoteOf(input.GetProperty("note")))),
        "copyID" => Same(output.GetString(), NoteSync.CopyId(Str(input, "id"), Str(input, "hash"))),
        "clockText" => Same(output.GetString(), NoteSync.ClockText(ClockOf(input.GetProperty("clock")))),
        "clockRead" => SameClock(ClockOf(output), NoteSync.ClockFrom(Str(input, "text"))),
        "precedes" => SameBool(output.GetBoolean(), NoteSync.Precedes(ClockOf(input.GetProperty("a")), ClockOf(input.GetProperty("b")))),
        "iso" => CheckIso(input, output),
        "number" => Same(output.GetString(), NoteFileHeader.Number(Bits(Str(input, "bits")))),
        "jsonString" => Same(output.GetString(), NoteFileHeader.JsonString(Str(input, "value"))),
        "jsonDecode" => Same(OptStr(output), NoteFileHeader.JsonDecode(Str(input, "raw"))),
        "noteText" => CheckNoteText(input, output),
        "noteParse" => CheckNoteParse(input, output),
        "isSyncFile" => SameBool(output.GetBoolean(), NoteSyncFolder.IsSyncFile(Str(input, "text"))),
        "noteID" => Same(OptStr(output), NoteSyncFolder.NoteId(Str(input, "name"))),
        "imageID" => Same(OptStr(output), NoteSyncFolder.ImageId(Str(input, "name")) is { } id ? NoteImages.IdText(id) : null),
        "erasedData" => Same(
            output.GetString(), Encoding.UTF8.GetString(NoteSyncFolder.ErasedData(TombstonesOf(input.GetProperty("tombstones"))))),
        "erasedRead" => SameRead(TombstoneReadOf(output), NoteSyncFolder.TombstonesFrom(Encoding.UTF8.GetBytes(Str(input, "raw")))),
        "markerRead" => CheckMarker(input, output),
        "ledgerText" => Same(output.GetString(), NoteSyncFolder.LedgerText(LedgerOf(input.GetProperty("ledger")))),
        "ledgerRead" => NoteSyncKit.SameLedger(LedgerOf(output), NoteSyncFolder.LedgerFrom(OptStr(input.GetProperty("text"))))
            ? null
            : "账不一样",
        "brakes" => SameBool(
            output.GetBoolean(),
            NoteSyncFolder.Brakes(input.GetProperty("trashing").GetInt32(), input.GetProperty("alive").GetInt32())),
        "merge" => CheckMerge(input, output),
        "round" => CheckRound(input, output),
        "publish" => CheckPublish(input, output),
        "regressed" => SameSet(
            StrList(output),
            NoteSyncFolder.Regressed(NotesOf(input.GetProperty("local")), FolderOf(input.GetProperty("folder")), Str(input, "device"))),
        "imagePurge" => CheckPurge(input, output),
        _ => "不认识的样本",
    };

    private static string? CheckIso(JsonElement input, JsonElement output)
    {
        var milliseconds = input.GetProperty("ms").GetInt64();
        return milliseconds < GregorianStart
            ? null
            : Same(output.GetString(), NoteFileHeader.Iso(milliseconds, Zone(input.GetProperty("offset").GetInt64())));
    }

    private static string? CheckNoteText(JsonElement input, JsonElement output)
    {
        var note = NoteOf(input.GetProperty("note"));
        var expected = output.GetString() ?? string.Empty;
        var actual = NoteSyncFolder.Text(note, Utc8);
        static bool Sane(long time) => time is >= GregorianStart and <= LatestIso;
        if (Sane(note.CreatedAt) && Sane(note.ModifiedAt))
        {
            return Same(expected, actual);
        }

        // 日期离谱的那条：created / modified 两行不比（见 CheckIso），别的照比
        static string Strip(string text) => string.Join(
            "\n", text.Split('\n').Where(line => !line.StartsWith("created: ", StringComparison.Ordinal) &&
                                                  !line.StartsWith("modified: ", StringComparison.Ordinal)));
        return Same(Strip(expected), Strip(actual));
    }

    private static string? CheckNoteParse(JsonElement input, JsonElement output)
    {
        var parsed = NoteSyncFolder.Parse(Str(input, "text"), Str(input, "fileID"));
        if (output.ValueKind == JsonValueKind.Null)
        {
            return parsed is null ? null : "应该读不出来";
        }

        if (parsed is not { } result)
        {
            return "应该读得出来";
        }

        if (result.Hash != Str(output, "hash"))
        {
            return "哈希不一样";
        }

        var expected = NoteOf(output.GetProperty("note"));
        return expected.Equals(result.Note) ? null : $"便签不一样：{result.Note}";
    }

    private static string? CheckMarker(JsonElement input, JsonElement output)
    {
        var marker = NoteSyncFolder.MarkerFrom(Encoding.UTF8.GetBytes(Str(input, "raw")));
        var expected = output.ValueKind == JsonValueKind.Null
            ? null
            : new NoteSyncFolder.Marker(Str(output, "library"), output.GetProperty("format").GetInt32());
        return expected == marker ? null : $"标记不一样：{marker}";
    }

    private static string? CheckMerge(JsonElement input, JsonElement output)
    {
        var local = input.GetProperty("local");
        var tombstone = input.GetProperty("tombstone");
        var hashes = input.GetProperty("hashes").EnumerateArray().Select(OptStr).ToList();
        var merge = NoteSync.MergeOne(
            local.ValueKind == JsonValueKind.Null ? null : NoteOf(local), NotesOf(input.GetProperty("remotes")),
            tombstone.ValueKind == JsonValueKind.Null ? null : TombstoneOf(tombstone), input.GetProperty("now").GetInt64(), hashes);
        return MergeOf(output).Equals(merge) ? null : $"合出来不一样：{merge.Note}，另存 {merge.Copies.Count} 条";
    }

    private static string? CheckRound(JsonElement input, JsonElement output)
    {
        var round = NoteSyncFolder.Round(
            NotesOf(input.GetProperty("local")), TombstonesOf(input.GetProperty("erased")), FolderOf(input.GetProperty("folder")),
            Str(input, "library"), input.GetProperty("now").GetInt64());
        var stop = output.GetProperty("stop");
        if (stop.ValueKind != JsonValueKind.Null)
        {
            var expected = new NoteSyncFolder.Stop(StopKindOf(Str(stop, "kind")), OptStr(stop.GetProperty("device")));
            return expected == round.Stop ? null : $"停的原因不一样：{round.Stop}";
        }

        if (round.Stop is not null)
        {
            return $"不该停：{round.Stop}";
        }

        var merges = output.GetProperty("merges").EnumerateObject().ToList();
        if (merges.Count != round.Merges.Count)
        {
            return $"要落的 {round.Merges.Count} 条，期望 {merges.Count} 条";
        }

        foreach (var merge in merges)
        {
            if (!round.Merges.TryGetValue(merge.Name, out var actual) || !MergeOf(merge.Value).Equals(actual))
            {
                return $"{merge.Name} 合出来不一样";
            }
        }

        if (!NoteSyncKit.SameTombstones(TombstonesOf(output.GetProperty("tombstones")), round.Tombstones))
        {
            return "墓碑不一样";
        }

        if (output.GetProperty("trashing").GetInt32() != round.Trashing || output.GetProperty("alive").GetInt32() != round.Alive)
        {
            return $"条数不一样：{round.Trashing} / {round.Alive}";
        }

        return SameSet(StrList(output.GetProperty("skipped")), round.Skipped) ??
               SameBool(output.GetProperty("brakes").GetBoolean(), round.Brakes);
    }

    private static string? CheckPublish(JsonElement input, JsonElement output)
    {
        var own = input.GetProperty("own");
        var plan = NoteSyncFolder.Publish(
            NotesOf(input.GetProperty("local")), TombstonesOf(input.GetProperty("erased")),
            own.ValueKind == JsonValueKind.Null ? null : DeviceOf(own), StrList(input.GetProperty("localImages")).ToHashSet(),
            StrList(input.GetProperty("folderImages")).ToHashSet());
        if (!StrList(output.GetProperty("writes")).SequenceEqual(plan.Writes.Select(note => note.Id)))
        {
            return "要写的不一样";
        }

        if (!StrList(output.GetProperty("deletes")).SequenceEqual(plan.Deletes))
        {
            return "要删的不一样";
        }

        var erased = output.GetProperty("erased");
        if (erased.ValueKind == JsonValueKind.Null ? plan.Erased is not null
            : plan.Erased is null || !NoteSyncKit.SameTombstones(TombstonesOf(erased), plan.Erased))
        {
            return "墓碑文件不一样";
        }

        if (!output.GetProperty("uploads").EnumerateArray().Select(ImageOf).SequenceEqual(plan.Uploads) ||
            !output.GetProperty("downloads").EnumerateArray().Select(ImageOf).SequenceEqual(plan.Downloads))
        {
            return "图片不一样";
        }

        return SameBool(output.GetProperty("isEmpty").GetBoolean(), plan.IsEmpty) ??
               SameBool(output.GetProperty("touchesNotes").GetBoolean(), plan.TouchesNotes);
    }

    private static string? CheckPurge(JsonElement input, JsonElement output)
    {
        static HashSet<Guid> Ids(JsonElement list) => StrList(list).Select(text => Guid.Parse(text)).ToHashSet();
        var purge = NoteSyncFolder.ImagePurge(
            StrList(input.GetProperty("folderImages")).ToHashSet(), Ids(input.GetProperty("referenced")),
            Ids(input.GetProperty("localImages")), LedgerOf(input.GetProperty("ledger")), input.GetProperty("readable").GetBoolean(),
            input.GetProperty("now").GetInt64());
        if (!StrList(output.GetProperty("deletes")).SequenceEqual(purge.Deletes))
        {
            return "要删的不一样";
        }

        if (!NoteSyncKit.SameLedger(LedgerOf(output.GetProperty("ledger")), purge.Ledger))
        {
            return "账不一样";
        }

        var due = output.GetProperty("due");
        long? expected = due.ValueKind == JsonValueKind.Null ? null : due.GetInt64();
        return expected == purge.Due ? null : $"到期不一样：{purge.Due}";
    }

    // ---- 比 ----

    private static string? Same(string? expected, string? actual)
        => string.Equals(expected, actual, StringComparison.Ordinal) ? null : $"期望 {Show(expected)}，实际 {Show(actual)}";

    private static string Show(string? text) => text is null ? "null" : NoteFileHeader.JsonString(text.Length > 600 ? text[..600] : text);

    private static string? SameBool(bool expected, bool actual) => expected == actual ? null : $"期望 {expected}，实际 {actual}";

    private static string? SameClock(IReadOnlyDictionary<string, long> expected, IReadOnlyDictionary<string, long> actual)
        => Note.SameClock(expected, actual) ? null : $"期望 {NoteSync.ClockText(expected)}，实际 {NoteSync.ClockText(actual)}";

    private static string? SameSet(IEnumerable<string> expected, IReadOnlySet<string> actual)
        => actual.SetEquals(expected) ? null : $"实际 {string.Join(",", actual.Order(StringComparer.Ordinal))}";

    private static string? SameRead(NoteSyncFolder.Tombstones expected, NoteSyncFolder.Tombstones actual)
        => expected.Equals(actual) ? null : $"期望 {expected.State} {expected.Entries.Count} 条，实际 {actual.State} {actual.Entries.Count} 条";

    // ---- 读样本 ----

    private static string Str(JsonElement element, string name) => element.GetProperty(name).GetString() ?? string.Empty;

    private static string? OptStr(JsonElement element) => element.ValueKind == JsonValueKind.Null ? null : element.GetString();

    private static List<string> StrList(JsonElement element) => element.EnumerateArray().Select(item => item.GetString() ?? string.Empty).ToList();

    private static long? OptLong(JsonElement element, string name)
        => element.GetProperty(name) is { ValueKind: not JsonValueKind.Null } value ? value.GetInt64() : null;

    private static double Bits(string text) => BitConverter.Int64BitsToDouble(unchecked((long)ulong.Parse(text, CultureInfo.InvariantCulture)));

    private static Dictionary<string, long> ClockOf(JsonElement element)
        => element.EnumerateObject().ToDictionary(cell => cell.Name, cell => cell.Value.GetInt64(), StringComparer.Ordinal);

    private static Dictionary<string, long> LedgerOf(JsonElement element) => ClockOf(element);

    private static Note NoteOf(JsonElement element) => new()
    {
        Id = Str(element, "id"),
        Title = Str(element, "title"),
        Body = Str(element, "body"),
        Color = element.GetProperty("color").GetInt32(),
        CreatedAt = element.GetProperty("created").GetInt64(),
        ModifiedAt = element.GetProperty("modified").GetInt64(),
        Revision = element.GetProperty("revision").GetInt32(),
        IsArchived = element.GetProperty("archived").GetBoolean(),
        IsPinned = element.GetProperty("pinned").GetBoolean(),
        Order = Bits(Str(element, "orderBits")),
        DeletedAt = OptLong(element, "deleted"),
        StateChangedAt = OptLong(element, "state"),
        OrderChangedAt = OptLong(element, "ordered"),
        Clock = ClockOf(element.GetProperty("clock")),
    };

    private static List<Note> NotesOf(JsonElement element) => element.EnumerateArray().Select(NoteOf).ToList();

    private static NoteSync.Tombstone TombstoneOf(JsonElement element)
        => new(ClockOf(element.GetProperty("clock")), element.GetProperty("state").GetInt64());

    private static Dictionary<string, NoteSync.Tombstone> TombstonesOf(JsonElement element)
        => element.EnumerateObject().ToDictionary(item => item.Name, item => TombstoneOf(item.Value), StringComparer.Ordinal);

    private static NoteSyncFolder.Tombstones TombstoneReadOf(JsonElement element) => Str(element, "kind") switch
    {
        "read" => NoteSyncFolder.Tombstones.Of(TombstonesOf(element.GetProperty("entries"))),
        "unreadable" => NoteSyncFolder.Tombstones.Unreadable,
        _ => NoteSyncFolder.Tombstones.Newer,
    };

    private static NoteSync.Merge MergeOf(JsonElement element)
    {
        var note = element.GetProperty("note");
        var revision = element.GetProperty("base");
        return new NoteSync.Merge(
            note.ValueKind == JsonValueKind.Null ? null : NoteOf(note), NotesOf(element.GetProperty("copies")),
            element.GetProperty("trashes").GetBoolean(), revision.ValueKind == JsonValueKind.Null ? null : revision.GetInt32());
    }

    private static NoteSyncFolder.Device DeviceOf(JsonElement element)
    {
        var epoch = element.GetProperty("epoch");
        var device = new NoteSyncFolder.Device
        {
            Name = OptStr(element.GetProperty("name")),
            Epoch = epoch.ValueKind == JsonValueKind.Null ? null : epoch.GetInt32(),
            Erased = TombstoneReadOf(element.GetProperty("erased")),
        };
        foreach (var item in element.GetProperty("notes").EnumerateObject())
        {
            device.Notes[item.Name] = NoteOf(item.Value);
        }

        foreach (var item in element.GetProperty("hashes").EnumerateObject())
        {
            device.Hashes[item.Name] = item.Value.GetString() ?? string.Empty;
        }

        device.Unreadable.UnionWith(StrList(element.GetProperty("unreadable")));
        return device;
    }

    private static NoteSyncFolder.Folder FolderOf(JsonElement element)
    {
        var marker = element.GetProperty("marker");
        var folder = new NoteSyncFolder.Folder
        {
            Marker = marker.ValueKind == JsonValueKind.Null
                ? null
                : new NoteSyncFolder.Marker(Str(marker, "library"), marker.GetProperty("format").GetInt32()),
        };
        foreach (var item in element.GetProperty("devices").EnumerateObject())
        {
            folder.Devices[item.Name] = DeviceOf(item.Value);
        }

        folder.Images.UnionWith(StrList(element.GetProperty("images")));
        return folder;
    }

    private static NoteImages.Image ImageOf(JsonElement element)
    {
        var width = element.GetProperty("width");
        return new NoteImages.Image(
            Guid.Parse(Str(element, "id")), Str(element, "ext"), width.ValueKind == JsonValueKind.Null ? null : width.GetInt32());
    }

    private static NoteSyncFolder.StopKind StopKindOf(string kind) => kind switch
    {
        "notTheFolder" => NoteSyncFolder.StopKind.NotTheFolder,
        "unreadableTombstones" => NoteSyncFolder.StopKind.UnreadableTombstones,
        _ => NoteSyncFolder.StopKind.NewerFormat,
    };
}

/// <summary>mac NoteSyncTests.swift 里合并规则的那一半。</summary>
[TestClass]
public sealed class NoteSyncMergeTests
{
    private static long At(double seconds) => NoteSyncKit.At(seconds);

    private static Dictionary<string, long> C(params (string Device, long Count)[] cells) => NoteSyncKit.C(cells);

    /// <summary>一版便签：时间按秒给（相对 t0）。</summary>
    private static Note Version(
        string body, double at, IReadOnlyDictionary<string, long> clock, string id = "N", double? state = null,
        double? deleted = null, bool pinned = false, bool archived = false, int revision = 1)
        => new()
        {
            Id = id,
            Body = body,
            CreatedAt = NoteSyncKit.T0,
            ModifiedAt = At(at),
            Revision = revision,
            IsArchived = archived,
            IsPinned = pinned,
            DeletedAt = deleted is { } time ? At(time) : null,
            StateChangedAt = At(state ?? at),
            OrderChangedAt = At(state ?? at),
            Clock = clock,
        };

    /// <summary>对面是在本机这一版之上改的：直接换，不留旧版；钟取两边的最大。</summary>
    [TestMethod]
    public void FastForwardKeepsNoCopy()
    {
        var local = Version("本机", 10, C(("A", 1)));
        var remote = Version("对面改的", 20, C(("A", 1), ("B", 1)));
        var merge = NoteSync.MergeOne(local, [remote], null, At(100));
        Assert.AreEqual("对面改的", merge.Note?.Body);
        Assert.AreEqual(0, merge.Copies.Count);
        Assert.IsFalse(merge.Trashes);
        var note = merge.Note!;
        Assert.IsTrue(Note.SameClock(C(("A", 1), ("B", 1)), note.Clock));
        Assert.AreEqual(2, note.Revision, "这一轮变了：修订号往上走");
    }

    /// <summary>对面那份是旧的（钟被本机盖过）：不理，原样给回本机那条。</summary>
    [TestMethod]
    public void StaleRemoteIsIgnored()
    {
        var local = Version("本机新的", 30, C(("A", 3), ("B", 1)));
        var stale = Version("对面旧的", 50, C(("A", 1), ("B", 1)), state: 20);
        var merge = NoteSync.MergeOne(local, [stale], null, At(100));
        Assert.AreEqual(local, merge.Note);
        Assert.AreEqual(0, merge.Copies.Count);
    }

    /// <summary>两边各改了：「改于」后的赢，输的那版另存一条；两台各合一遍，赢的一样、另存的是同一条。</summary>
    [TestMethod]
    public void ConcurrentEditsKeepTheLoserOnce()
    {
        var mine = Version("A 改的", 20, C(("A", 2), ("B", 1)));
        var theirs = Version("B 改的", 30, C(("A", 1), ("B", 2)));
        var onA = NoteSync.MergeOne(mine, [theirs], null, At(100));
        var onB = NoteSync.MergeOne(theirs, [mine], null, At(200));
        Assert.AreEqual("B 改的", onA.Note?.Body);
        Assert.AreEqual("B 改的", onB.Note?.Body);
        Assert.IsTrue(Note.SameClock(C(("A", 2), ("B", 2)), onA.Note!.Clock));
        Assert.IsTrue(Note.SameClock(C(("A", 2), ("B", 2)), onB.Note!.Clock));
        Assert.AreEqual(1, onA.Copies.Count);
        var copy = onA.Copies[0];
        Assert.AreEqual(copy.Id, onB.Copies.Single().Id);
        Assert.AreEqual("A 改的", copy.Body);
        Assert.IsTrue(copy.DeletedAt == At(100));
        Assert.AreNotEqual(mine.Id, copy.Id);
        Assert.AreEqual(NoteSync.CopyId("N", NoteSync.ContentHash(mine)), copy.Id);
        Assert.AreEqual(0, copy.Clock.Count, "另存的那条是新的一条，钟从空的起：两台存的一样");
        // 合完的钟盖过两边：B 下一轮看到 A 合出来的是快进，不再算冲突
        var again = NoteSync.MergeOne(onB.Note, [onA.Note!], null, At(300));
        Assert.AreEqual(0, again.Copies.Count);
        Assert.AreEqual(onB.Note, again.Note);
    }

    /// <summary>慢了的钟：B 看过 A 的再改，「改于」反而更早——照样是快进。</summary>
    [TestMethod]
    public void SlowClockStillFastForwards()
    {
        var local = Version("A 的", 500, C(("A", 1)));
        var remote = Version("B 在 A 之上改的", 100, C(("A", 1), ("B", 1)));
        var merge = NoteSync.MergeOne(local, [remote], null, At(600));
        Assert.AreEqual("B 在 A 之上改的", merge.Note?.Body);
        Assert.AreEqual(0, merge.Copies.Count);
    }

    /// <summary>钟一样、字不一样：当两边都改了，走冲突那条路；字一样只把钟并起来。</summary>
    [TestMethod]
    public void SameClockDifferentTextIsAConflict()
    {
        var local = Version("0.5.0 里改过", 40, C());
        var remote = Version("另一台的", 30, C());
        var merge = NoteSync.MergeOne(local, [remote], null, At(100));
        Assert.AreEqual(local, merge.Note, "本机后改：赢，原样");
        Assert.AreEqual("另一台的", merge.Copies.Single().Body);
        var same = Version("一样的字", 40, C());
        var twin = Version("一样的字", 10, C(("B", 1)));
        var quiet = NoteSync.MergeOne(same, [twin], null, At(100));
        Assert.AreEqual(0, quiet.Copies.Count);
        Assert.IsTrue(Note.SameClock(C(("B", 1)), quiet.Note!.Clock), "字一样：只把钟并起来");
    }

    /// <summary>三版：X 被 Z 盖过、Y 和两个都各改各的——只有 Y 另存；几个版本换着顺序合，结果一样。</summary>
    [TestMethod]
    public void CoveredVersionsAreNotCopiedAndOrderDoesNotMatter()
    {
        var x = Version("X", 10, C(("A", 1)));
        var y = Version("Y", 20, C(("B", 1)));
        var z = Version("Z", 30, C(("A", 2)));
        foreach (var order in new[] { new[] { x, y, z }, new[] { z, y, x }, new[] { y, x, z }, new[] { y, z, x } })
        {
            var merge = NoteSync.MergeOne(order[0], order[1..], null, At(100));
            Assert.AreEqual("Z", merge.Note?.Body);
            Assert.IsTrue(Note.SameClock(C(("A", 2), ("B", 1)), merge.Note!.Clock));
            Assert.AreEqual("Y", merge.Copies.Single().Body);
        }
    }

    /// <summary>时间按原值比，比现在还晚也一样；在它之上改的（钟盖过它）不管时刻，直接是快进。</summary>
    [TestMethod]
    public void TimesCompareAsTheyAre()
    {
        var local = Version("本机", 99, C(("A", 2)));
        var ahead = Version("钟快了的那台", 99_999, C(("B", 1)));
        foreach (var now in new[] { At(100), At(500) })
        {
            var merge = NoteSync.MergeOne(local, [ahead], null, now);
            Assert.AreEqual("钟快了的那台", merge.Note?.Body);
            Assert.AreEqual(At(99_999), merge.Note!.ModifiedAt);
            Assert.AreEqual("本机", merge.Copies.Single().Body, "两边各改了：输的那版另存");
        }

        var onTop = Version("看过它再改", 120, C(("A", 2), ("B", 1)));
        var forward = NoteSync.MergeOne(onTop, [ahead], null, At(130));
        Assert.AreEqual("看过它再改", forward.Note?.Body);
        Assert.AreEqual(0, forward.Copies.Count);
    }

    /// <summary>状态一组后改的赢，和内容各合各的。</summary>
    [TestMethod]
    public void StatesMergeByTheirOwnTime()
    {
        var local = Version("本机改的字", 50, C(("A", 2), ("B", 1)), state: 10);
        var remote = Version("旧字", 5, C(("A", 1), ("B", 1)), state: 40, pinned: true);
        var merge = NoteSync.MergeOne(local, [remote], null, At(100));
        var note = merge.Note!;
        Assert.AreEqual("本机改的字", note.Body);
        Assert.IsTrue(note.IsPinned);
        Assert.IsTrue(note.StateChangedAt == At(40));
        Assert.AreEqual(At(50), note.ModifiedAt);
    }

    /// <summary>一边删、一边改：最新的内容在「最近删除」里；本机那条原来没删、合完删了要记 Trashes。</summary>
    [TestMethod]
    public void DeleteMeetsEditKeepsTheNewestText()
    {
        var edited = Version("删之后又改了", 60, C(("A", 2)), state: 10);
        var deleted = Version("原来的", 5, C(("A", 1)), state: 50, deleted: 50);
        var onEditor = NoteSync.MergeOne(edited, [deleted], null, At(100));
        Assert.AreEqual("删之后又改了", onEditor.Note?.Body);
        Assert.IsTrue(onEditor.Note!.DeletedAt == At(50));
        Assert.IsTrue(onEditor.Trashes);
        Assert.AreEqual(0, onEditor.Copies.Count);
        var onDeleter = NoteSync.MergeOne(deleted, [edited], null, At(100));
        Assert.AreEqual("删之后又改了", onDeleter.Note?.Body);
        Assert.IsTrue(onDeleter.Note!.DeletedAt == At(50));
        Assert.IsFalse(onDeleter.Trashes);
    }

    /// <summary>墓碑压住被删那一版和它的前身；删了之后又改过、放回过的压不住；救回来的那条钟里并上墓碑的；几台的墓碑并起来。</summary>
    [TestMethod]
    public void TombstonesBuryTheErasedVersionAndItsAncestors()
    {
        var tombstone = new NoteSync.Tombstone(C(("A", 1)), At(30));
        NoteSync.Merge Merge(Note? local, IReadOnlyList<Note> remotes) => NoteSync.MergeOne(local, remotes, tombstone, At(100));
        var trashed = Version("在最近删除里", 10, C(("A", 1)), state: 20, deleted: 20);
        Assert.IsNull(Merge(trashed, []).Note, "本机那条压住了：真删");
        var stale = Version("旧文件夹里没删的那份", 10, C(("A", 1)), state: 5);
        Assert.IsNull(Merge(stale, []).Note);
        Assert.IsNull(Merge(null, [stale]).Note, "本机永久删过：别人那份旧的救不回来");
        var edited = Version("删了之后又改", 40, C(("A", 2)), state: 20, deleted: 20);
        Assert.AreEqual(edited, Merge(edited, []).Note);
        var restored = Version("对面放回了", 10, C(("A", 1)), state: 40);
        Assert.AreEqual("对面放回了", Merge(null, [restored]).Note?.Body);
        Assert.IsTrue(Merge(trashed, [restored]).Note is { DeletedAt: null }, "本机压住了、但对面还有一份压不住的：照常合");
        var deeper = new NoteSync.Tombstone(C(("A", 5)), At(30));
        var concurrent = Version("对面删前改过的", 25, C(("A", 3), ("B", 1)), state: 25);
        var revived = NoteSync.MergeOne(null, [concurrent], deeper, At(100));
        Assert.AreEqual("对面删前改过的", revived.Note?.Body);
        Assert.IsTrue(Note.SameClock(C(("A", 5), ("B", 1)), revived.Note!.Clock));
        var other = new NoteSync.Tombstone(C(("A", 0), ("B", 2)), At(10));
        Assert.AreEqual(new NoteSync.Tombstone(C(("A", 1), ("B", 2)), At(30)), tombstone.Merged(other));
    }

    /// <summary>顺序单独后改的赢：一台整列重排，另一台同时删了这条 → 删除不被翻回去，顺序照重排的。</summary>
    [TestMethod]
    public void OrderMergesOnItsOwn()
    {
        var moved = Version("一条", 5, C(("A", 1)), state: 5) with { Order = 3, OrderChangedAt = At(60) };
        var deleted = Version("一条", 5, C(("A", 1)), state: 50, deleted: 50);
        var merge = NoteSync.MergeOne(moved, [deleted], null, At(100));
        var note = merge.Note!;
        Assert.IsTrue(note.DeletedAt == At(50));
        Assert.IsTrue(note.Order == 3.0);
        Assert.IsTrue(note.OrderChangedAt == At(60));
        Assert.IsTrue(merge.Trashes);
    }

    /// <summary>本机没有的：合出来就是新来的（修订号从 0 起）；都没有：null。</summary>
    [TestMethod]
    public void NewNotesComeInAndNothingIsNothing()
    {
        var remote = Version("新来的", 10, C(("B", 1)), revision: 7);
        var merge = NoteSync.MergeOne(null, [remote], null, At(100));
        Assert.AreEqual(remote with { Revision = 0 }, merge.Note, "修订号是本机的账：新来的从 0 起");
        Assert.IsFalse(merge.Trashes);
        Assert.IsNull(NoteSync.MergeOne(null, [], null, At(100)).Note);
    }

    [TestMethod]
    public void ClockTextRoundTripsAndSkipsBrokenCells()
    {
        var clock = C(("B-2", 5), ("A1", 3));
        Assert.AreEqual("A1:3,B-2:5", NoteSync.ClockText(clock));
        Assert.IsTrue(Note.SameClock(clock, NoteSync.ClockFrom(NoteSync.ClockText(clock))));
        Assert.AreEqual(0, NoteSync.ClockFrom(string.Empty).Count);
        Assert.IsTrue(Note.SameClock(C(("A", 2), ("F", 4)), NoteSync.ClockFrom("A:2,坏:1,B:0,C:-1,D:x,:3,E:1:2,F:4")));
        Assert.IsTrue(Note.SameClock(C(("A", 5)), NoteSync.ClockFrom("A:2,A:5")));
        var limits = $"A:{NoteSync.MaxCount},B:{NoteSync.MaxCount + 1},C:{long.MaxValue}";
        Assert.IsTrue(Note.SameClock(C(("A", NoteSync.MaxCount)), NoteSync.ClockFrom(limits)), "次数有上限");
    }

    [TestMethod]
    public void CopyIdIsStableAndAUuid()
    {
        var id = NoteSync.CopyId("N", "abc");
        Assert.AreEqual(id, NoteSync.CopyId("N", "abc"));
        Assert.AreNotEqual(id, NoteSync.CopyId("N", "abd"));
        Assert.AreNotEqual(id, NoteSync.CopyId("M", "abc"));
        Assert.AreEqual(id, NoteFileHeader.UuidText(id));
        Assert.AreEqual('5', id[14], "第 5 版的写法");
    }
}

/// <summary>mac NoteSyncFolderTests.swift。</summary>
[TestClass]
public sealed class NoteSyncFolderTests
{
    private static long At(double seconds) => NoteSyncKit.At(seconds);

    private static Dictionary<string, long> C(params (string Device, long Count)[] cells) => NoteSyncKit.C(cells);

    private static Note Make(
        string body, string? id = null, double at = 10, IReadOnlyDictionary<string, long>? clock = null, double? deleted = null,
        int revision = 1)
        => new()
        {
            Id = id ?? NoteSyncKit.NewId(),
            Body = body,
            CreatedAt = NoteSyncKit.T0,
            ModifiedAt = At(at),
            Revision = revision,
            DeletedAt = deleted is { } time ? At(time) : null,
            StateChangedAt = At(deleted ?? at),
            OrderChangedAt = At(at),
            Clock = clock ?? C(("A", 1)),
        };

    private static NoteSyncFolder.Folder Folder(Dictionary<string, NoteSyncFolder.Device> devices)
    {
        var folder = new NoteSyncFolder.Folder { Marker = new NoteSyncFolder.Marker("L") };
        foreach (var (id, device) in devices)
        {
            folder.Devices[id] = device;
        }

        return folder;
    }

    private static NoteSyncFolder.Device Device(
        IEnumerable<Note>? notes = null, IEnumerable<string>? unreadable = null, NoteSyncFolder.Tombstones? erased = null)
    {
        var device = new NoteSyncFolder.Device { Erased = erased ?? NoteSyncFolder.Tombstones.Empty };
        foreach (var note in notes ?? [])
        {
            device.Notes[note.Id] = note;
        }

        device.Unreadable.UnionWith(unreadable ?? []);
        return device;
    }

    /// <summary>导出文件那样的头（没有 sync- 那几行）。</summary>
    private static string ExportHeader(Note note)
    {
        var lines = NoteSyncFolder.Text(note, TimeZoneInfo.Utc).Split('\n');
        var close = Array.IndexOf(lines, "---", 1);
        return string.Join("\n", lines.Take(close + 1).Where(line => !line.StartsWith("sync-", StringComparison.Ordinal)));
    }

    /// <summary>往返一个字不差：只有空格的标题、带 `---` 的行、开头的空行、行尾的空白、\r、U+2028、自定义纸色、删除时刻、钟、小数的顺序。</summary>
    [TestMethod]
    public void NoteFilesRoundTripExactly()
    {
        var tricky = Make(
            "\n\n---\n第一行 \r\n---" + (char)0x2028 + "☐ 待办\n![image](kitty-note-image://6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F.png)\n\n",
            deleted: 30, revision: 42) with
        {
            Title = "  ",
            Color = Note.Custom(0xC2DFF8),
            IsArchived = true,
            IsPinned = true,
            Order = -0.1 + 1e-9,
            Clock = C(("A", 3), ("B-2", 7)),
            CreatedAt = 1_700_000_000_123,
        };
        var plain = Make("一行") with { Title = "标题：带「引号」\"和\\反斜杠\"\n换行" };
        foreach (var original in new[] { tricky, plain, Make(string.Empty), Make("x", clock: C()) })
        {
            var text = NoteSyncFolder.Text(original, TimeZoneInfo.Utc);
            Assert.AreEqual(original, NoteSyncFolder.NoteFrom(text, original.Id));
            Assert.AreEqual(NoteSync.ContentHash(original), NoteSyncFolder.Parse(text, original.Id)?.Hash, "一并给出的哈希就是核对过的那个");
            Assert.IsTrue(NoteSyncFolder.IsSyncFile(text));
        }

        Assert.IsFalse(NoteSyncFolder.IsSyncFile(ExportHeader(tricky) + "\n\n正文"));
    }

    /// <summary>认不出、被动过的给 null。</summary>
    [TestMethod]
    public void ForeignOrTamperedFilesAreNotNotes()
    {
        var good = Make("正文");
        var text = NoteSyncFolder.Text(good, TimeZoneInfo.Utc);
        bool Reads(string candidate) => NoteSyncFolder.NoteFrom(candidate, good.Id) is not null;
        Assert.IsTrue(Reads(text));
        Assert.IsNull(NoteSyncFolder.NoteFrom(text, NoteSyncKit.NewId()), "编号对不上");
        Assert.IsFalse(Reads(ExportHeader(good) + "\n\n正文"));
        Assert.IsFalse(Reads("---\nkitty-note: " + good.Id + "\nsync-clock: A:1\n"));
        Assert.IsFalse(Reads(text + "\n"), "编辑器补了一个换行");
        Assert.IsFalse(Reads(text.Replace("正文", "正")), "读到一半");
        Assert.IsFalse(Reads(text.Replace("---\nkitty-note", "---\ntitle: 没引号\nkitty-note")));
        Assert.IsFalse(Reads(text.Replace("color: 0", "color: 9")));
        Assert.IsFalse(Reads(text.Replace("sync-clock:", "sync-deleted: 坏\nsync-clock:")));
        Assert.IsFalse(Reads(text.Replace("pinned: false", "pinned: false\npinned: true")));
        Assert.IsFalse(Reads(text.Replace("pinned: false", "pinned: 否")));
        var cells = string.Join(",", Enumerable.Range(0, 1100).Select(index => $"D{index}:1"));
        Assert.IsFalse(Reads(text.Replace("sync-clock: A:1", "sync-clock: " + cells)));
        Assert.IsFalse(Reads(text + new string('字', Note.MaxBodyBytes / 3 + 30_000)));
        Assert.IsFalse(Reads("随便什么"));
    }

    [TestMethod]
    public void FileNamesAreIds()
    {
        var id = NoteSyncKit.NewId();
        Assert.AreEqual(id + ".md", NoteSyncFolder.FileName(id));
        Assert.AreEqual(id, NoteSyncFolder.NoteId(id + ".md"));
        Assert.AreEqual(id, NoteSyncFolder.NoteId(id.ToLowerInvariant() + ".md"));
        Assert.IsNull(NoteSyncFolder.NoteId(id + ".txt"));
        Assert.IsNull(NoteSyncFolder.NoteId("笔记.md"));
    }

    /// <summary>墓碑文件往返；坏的读不出来、格式更新的说更新；编号不是 UUID 的条目跳过；同一个编号大小写写了两份并起来。</summary>
    [TestMethod]
    public void TombstoneFilesRoundTrip()
    {
        var id = NoteSyncKit.NewId();
        var tombstones = new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal)
        {
            [id] = new(C(("A", 2), ("B", 1)), At(5)),
        };
        NoteSyncFolder.Tombstones Read(string json) => NoteSyncFolder.TombstonesFrom(Encoding.UTF8.GetBytes(json));
        Assert.AreEqual(NoteSyncFolder.Tombstones.Of(tombstones), NoteSyncFolder.TombstonesFrom(NoteSyncFolder.ErasedData(tombstones)));
        Assert.AreEqual(
            NoteSyncFolder.Tombstones.Empty, NoteSyncFolder.TombstonesFrom(NoteSyncFolder.ErasedData(NoteSyncKit.NoTombstones)));
        Assert.AreEqual(NoteSyncFolder.Tombstones.Unreadable, Read("坏了"));
        Assert.AreEqual(NoteSyncFolder.Tombstones.Newer, Read("{\"format\": 99, \"erased\": {}}"));
        Assert.AreEqual(
            NoteSyncFolder.Tombstones.Empty, Read("{\"format\": 1, \"erased\": {\"不是编号\": {\"clock\": \"A:1\", \"state\": 5}}}"));
        var twice = "{\"format\": 1, \"erased\": {\"" + id + "\": {\"clock\": \"A:2\", \"state\": 5},\n  \"" +
                    id.ToLowerInvariant() + "\": {\"clock\": \"B:3\", \"state\": 9}}}";
        var merged = new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal) { [id] = new(C(("A", 2), ("B", 3)), 9) };
        Assert.AreEqual(NoteSyncFolder.Tombstones.Of(merged), Read(twice));
    }

    /// <summary>不是那个文件夹、更新的格式、谁的墓碑读不出来（带上是哪台）：整轮不合。</summary>
    [TestMethod]
    public void RoundStops()
    {
        var folder = new NoteSyncFolder.Folder();
        NoteSyncFolder.Stop? Round() => NoteSyncFolder.Round([Make("本机")], NoteSyncKit.NoTombstones, folder, "L", At(100)).Stop;
        Assert.AreEqual(new NoteSyncFolder.Stop(NoteSyncFolder.StopKind.NotTheFolder), Round());
        folder.Marker = new NoteSyncFolder.Marker("别的");
        Assert.AreEqual(new NoteSyncFolder.Stop(NoteSyncFolder.StopKind.NotTheFolder), Round());
        folder.Marker = new NoteSyncFolder.Marker("L", 2);
        Assert.AreEqual(new NoteSyncFolder.Stop(NoteSyncFolder.StopKind.NewerFormat), Round());
        folder.Marker = new NoteSyncFolder.Marker("L");
        folder.Devices["B"] = Device(erased: NoteSyncFolder.Tombstones.Unreadable);
        Assert.AreEqual(new NoteSyncFolder.Stop(NoteSyncFolder.StopKind.UnreadableTombstones, "B"), Round());
        folder.Devices["B"] = Device(erased: NoteSyncFolder.Tombstones.Newer);
        Assert.AreEqual(new NoteSyncFolder.Stop(NoteSyncFolder.StopKind.NewerFormat), Round());
        folder.Devices["B"] = Device();
        Assert.IsNull(Round());
    }

    /// <summary>合一轮：别人的新来、对面改了的换上；自己子文件夹里本机没有、也没墓碑的合回来；读不出来的那一版不算；没变的不交出来。</summary>
    [TestMethod]
    public void RoundMergesEveryoneAndSkipsUnreadableVersions()
    {
        var same = Make("没变的");
        var changed = Make("本机旧的");
        var theirs = changed with { Body = "对面改的", Clock = C(("A", 1), ("B", 1)), ModifiedAt = At(20) };
        var incoming = Make("新来的", clock: C(("B", 1)));
        var blocked = Make("这条那边没下载完");
        var orphan = Make("自己文件夹里有、本机没有（0.5.0 清掉了）", clock: C(("A", 2)));
        var round = NoteSyncFolder.Round(
            [same, changed, blocked], NoteSyncKit.NoTombstones,
            Folder(new()
            {
                ["A"] = Device([same, orphan]),
                ["B"] = Device([same, theirs, incoming], unreadable: [blocked.Id]),
            }), "L", At(100));
        Assert.IsNull(round.Stop);
        Assert.IsTrue(round.Merges.Keys.ToHashSet().SetEquals([changed.Id, incoming.Id, orphan.Id]));
        Assert.AreEqual("对面改的", round.Merges[changed.Id].Note?.Body);
        Assert.AreEqual("新来的", round.Merges[incoming.Id].Note?.Body);
        Assert.AreEqual(orphan.Body, round.Merges[orphan.Id].Note?.Body);
        Assert.IsTrue(round.Skipped.SetEquals([blocked.Id]));
        Assert.IsFalse(round.Merges.ContainsKey(blocked.Id));
        Assert.AreEqual(0, round.Trashing);
        Assert.AreEqual(3, round.Alive);
        Assert.IsFalse(round.Brakes);
    }

    /// <summary>数要放进最近删除（或真删）的条数：对面删了的、墓碑压住的；本机原来就在最近删除里的不算。</summary>
    [TestMethod]
    public void RoundCountsTrashing()
    {
        var deletedThere = Make("对面删了");
        var theirs = deletedThere with { DeletedAt = At(50), StateChangedAt = At(50) };
        var buried = Make("对面永久删了");
        var alreadyTrashed = Make("本机早就删了", deleted: 5);
        var theirsToo = alreadyTrashed with { DeletedAt = At(60), StateChangedAt = At(60) };
        var erased = new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal) { [buried.Id] = new(C(("A", 1)), At(70)) };
        var round = NoteSyncFolder.Round(
            [deletedThere, buried, alreadyTrashed], NoteSyncKit.NoTombstones,
            Folder(new() { ["B"] = Device([theirs, theirsToo], erased: NoteSyncFolder.Tombstones.Of(erased)) }), "L", At(100));
        Assert.AreEqual(2, round.Trashing);
        Assert.AreEqual(2, round.Alive);
        Assert.IsNull(round.Merges[buried.Id].Note);
        Assert.IsTrue(round.Tombstones.ContainsKey(buried.Id));
    }

    /// <summary>刹车：超过 20 条；或者至少 5 条、超过三成。</summary>
    [TestMethod]
    public void Brakes()
    {
        Assert.IsTrue(NoteSyncFolder.Brakes(21, 1000));
        Assert.IsFalse(NoteSyncFolder.Brakes(20, 1000));
        Assert.IsFalse(NoteSyncFolder.Brakes(4, 5), "不到 5 条不按三成算");
        Assert.IsTrue(NoteSyncFolder.Brakes(5, 10));
        Assert.IsFalse(NoteSyncFolder.Brakes(6, 20), "正好三成不算");
        Assert.IsTrue(NoteSyncFolder.Brakes(7, 20));
        Assert.IsFalse(NoteSyncFolder.Brakes(0, 0));
    }

    /// <summary>和自己文件夹里那一版不一样的、没有的、读不出来的重写；本机已经没有的删；墓碑变了重写；图片文件夹没有的传、本机没有的拿。</summary>
    [TestMethod]
    public void PublishWritesDeletesAndMovesImages()
    {
        var image = new NoteImages.Image(Guid.NewGuid(), "png", 240);
        var other = new NoteImages.Image(Guid.NewGuid(), "jpg", null);
        var synced = Make("没变的", revision: 3);
        var edited = Make("改过的", revision: 5);
        var stale = edited with { Revision = 4 };
        var missing = Make("文件被人删了", revision: 2);
        var broken = Make("自己那份写坏了", revision: 2);
        var pictured = Make("图 " + NoteImages.Token(image) + " 和 " + NoteImages.Token(other), revision: 1);
        var goneId = NoteSyncKit.NewId();
        // 本机没有、也没墓碑、读不出来（还在下载 / 库被退回去了）：可能是唯一的一份，不删
        var strayId = NoteSyncKit.NewId();
        var own = Device([synced, stale, Make("永久删了的", id: goneId)], unreadable: [broken.Id, strayId]);
        var tombstones = new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal) { [goneId] = new(C(("A", 1)), At(9)) };
        var plan = NoteSyncFolder.Publish(
            [synced, edited, missing, broken, pictured], tombstones, own, new HashSet<string> { image.FileName },
            new HashSet<string> { other.FileName });
        Assert.IsTrue(plan.Writes.Select(note => note.Id).ToHashSet().SetEquals([edited.Id, missing.Id, broken.Id, pictured.Id]));
        Assert.AreEqual(goneId, plan.Deletes.Single());
        Assert.IsNotNull(plan.Erased);
        Assert.IsTrue(NoteSyncKit.SameTombstones(tombstones, plan.Erased));
        Assert.AreEqual(image with { Width = null }, plan.Uploads.Single());
        Assert.AreEqual(other, plan.Downloads.Single());
        // 都一样：什么都不用做
        var calm = NoteSyncFolder.Publish([synced], NoteSyncKit.NoTombstones, Device([synced]), new HashSet<string>(), new HashSet<string>());
        Assert.IsTrue(calm.IsEmpty);
        // 自己的子文件夹还没有（第一次）：全写、墓碑文件也写；墓碑文件读不出来：重写
        var first = NoteSyncFolder.Publish([synced], NoteSyncKit.NoTombstones, null, new HashSet<string>(), new HashSet<string>());
        Assert.AreEqual(synced.Id, first.Writes.Single().Id);
        Assert.IsTrue(first.Erased is { Count: 0 });
        var rewrite = NoteSyncFolder.Publish(
            [], NoteSyncKit.NoTombstones, Device(erased: NoteSyncFolder.Tombstones.Unreadable), new HashSet<string>(),
            new HashSet<string>());
        Assert.IsTrue(rewrite.Erased is { Count: 0 });
    }

    /// <summary>库被退回去了：哪一版里本机那一格的钟比库里大，就是那几条；别的电脑那一格大不算；本机没有的不算。</summary>
    [TestMethod]
    public void RegressionIsDetected()
    {
        var current = Make("现在的", clock: C(("A", 3), ("B", 2)));
        var ahead = current with { Clock = C(("A", 5), ("B", 2)) };
        var otherAhead = current with { Clock = C(("A", 3), ("B", 9)) };
        var carried = current with { Clock = C(("A", 4), ("B", 3)) };
        var vanished = Make("后来建的");
        HashSet<string> Regressed(string device, Note note)
            => NoteSyncFolder.Regressed([current], Folder(new() { [device] = Device([note]) }), "A");
        Assert.AreEqual(0, Regressed("A", current).Count);
        Assert.AreEqual(0, Regressed("A", otherAhead).Count);
        Assert.IsTrue(Regressed("A", ahead).SetEquals([current.Id]));
        Assert.IsTrue(Regressed("B", carried).SetEquals([current.Id]), "自己的文件读不出来时，别人那份里也带着本机那一格");
        Assert.AreEqual(0, Regressed("A", vanished).Count);
    }

    /// <summary>共用 images/：没人引用；本机已经没有的记满 1 天、本机还有的记满 30 天；读不清楚整轮不删、账不动。</summary>
    [TestMethod]
    public void FolderImagesArePurgedConservatively()
    {
        var (gone, kept, used) = (Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid());
        static string Name(Guid id) => NoteImages.IdText(id) + ".png";
        var names = new HashSet<string> { Name(gone), Name(kept), Name(used), "不是图片.txt" };
        NoteSyncFolder.ImagePurgePlan Purge(IReadOnlyDictionary<string, long> ledger, double now, bool readable)
            => NoteSyncFolder.ImagePurge(names, new HashSet<Guid> { used }, new HashSet<Guid> { kept }, ledger, readable, At(now));
        var empty = new Dictionary<string, long>(StringComparer.Ordinal);
        var first = Purge(empty, 0, true);
        Assert.AreEqual(0, first.Deletes.Count);
        Assert.IsTrue(NoteSyncKit.SameLedger(
            new Dictionary<string, long>(StringComparer.Ordinal) { [Name(gone)] = At(0), [Name(kept)] = At(0) }, first.Ledger));
        Assert.IsTrue(first.Due == At(86_400));
        Assert.AreEqual(0, Purge(first.Ledger, 86_399, true).Deletes.Count);
        var day = Purge(first.Ledger, 86_400, true);
        Assert.AreEqual(Name(gone), day.Deletes.Single());
        Assert.IsTrue(NoteSyncKit.SameLedger(first.Ledger, day.Ledger), "要删的也照记，删成了下一轮文件不在了再去掉");
        Assert.IsTrue(day.Due == At(30 * 86_400));
        Assert.IsTrue(Purge(first.Ledger, 30 * 86_400, true).Deletes.ToHashSet().SetEquals([Name(gone), Name(kept)]));
        var blind = Purge(first.Ledger, 40 * 86_400, false);
        Assert.AreEqual(0, blind.Deletes.Count);
        Assert.IsTrue(NoteSyncKit.SameLedger(first.Ledger, blind.Ledger));
        Assert.IsNull(blind.Due);
        Assert.AreEqual(0, Purge(empty, 40 * 86_400, false).Ledger.Count);
        var revived = NoteSyncFolder.ImagePurge(
            new HashSet<string> { Name(kept) }, new HashSet<Guid> { kept }, new HashSet<Guid>(), first.Ledger, true, At(40 * 86_400));
        Assert.AreEqual(0, revived.Deletes.Count);
        Assert.AreEqual(0, revived.Ledger.Count);
        Assert.IsNull(revived.Due);
        Assert.IsTrue(NoteSyncKit.SameLedger(first.Ledger, NoteSyncFolder.LedgerFrom(NoteSyncFolder.LedgerText(first.Ledger))));
        Assert.AreEqual(0, NoteSyncFolder.LedgerFrom("乱写的").Count);
        Assert.AreEqual(0, NoteSyncFolder.LedgerFrom(null).Count);
    }

    /// <summary>文件夹里各台的引用（含最近删除里的）、读没读清楚（墓碑、便签文件）。</summary>
    [TestMethod]
    public void FolderReferencesAndReadability()
    {
        var image = new NoteImages.Image(Guid.NewGuid(), "png", null);
        var trashed = Make("图 " + NoteImages.Token(image), deleted: 20);
        var plain = Make("没有图");
        var devices = new Dictionary<string, NoteSyncFolder.Device>(StringComparer.Ordinal)
        {
            ["A"] = Device([plain]),
            ["B"] = Device([trashed]),
        };
        Assert.IsTrue(NoteSyncFolder.ReferencedImages(Folder(devices)).SetEquals([image.Id]));
        Assert.IsTrue(NoteSyncFolder.IsReadable(Folder(devices)));
        devices["B"].Unreadable.Add(NoteSyncKit.NewId());
        Assert.IsFalse(NoteSyncFolder.IsReadable(Folder(devices)));
        devices["B"].Unreadable.Clear();
        devices["B"].Erased = NoteSyncFolder.Tombstones.Unreadable;
        Assert.IsFalse(NoteSyncFolder.IsReadable(Folder(devices)));
    }
}

/// <summary>mac NoteSyncFuzzTests.swift：三台电脑各一本 NoteBook，钟各快慢几分钟，随机改、写出去、读别人的合一轮；第四台中途写过
/// 一次就再也不动了。检查不丢字、安静下来之后几台一样、再合一轮什么都不变；走文件夹的那个另查从没误认成「库被退回去了」。</summary>
[TestClass]
public sealed class NoteSyncFuzzTests
{
    private const long Day = 86_400_000;

    /// <summary>线性同余（同 mac）。</summary>
    private sealed class Rng(ulong state)
    {
        private ulong _state = state;

        public int Next(int bound)
        {
            _state = unchecked(_state * 6_364_136_223_846_793_005UL + 1_442_695_040_888_963_407UL);
            return (int)((_state >> 33) % (ulong)Math.Max(bound, 1));
        }

        public bool Chance(int odds) => Next(odds) == 0;

        public T? Pick<T>(IReadOnlyList<T> items) where T : class => items.Count == 0 ? null : items[Next(items.Count)];
    }

    /// <summary>一台电脑：自己的仓库、钟快慢多少；整份快照的那种文件夹（Folder / Tombstones）和走文件的那种（Files：文件名 → 这个文件
    /// 先后的几版，最后一版是现在的，null = 删了；Erased：墓碑文件先后的几版）。</summary>
    private sealed class Mac
    {
        public Mac(string device, long skew)
        {
            Device = device;
            Skew = skew;
            Book = new NoteBook(() => Device);
        }

        public string Device { get; }

        public long Skew { get; }

        public NoteBook Book { get; }

        public Dictionary<string, Note> Folder { get; private set; } = new(StringComparer.Ordinal);

        public Dictionary<string, NoteSync.Tombstone> Tombstones { get; private set; } = new(StringComparer.Ordinal);

        public Dictionary<string, List<string?>> Files { get; } = new(StringComparer.Ordinal);

        public List<byte[]> Erased { get; } = new();

        public void Snapshot()
        {
            Folder = Book.All.ToDictionary(note => note.Id, StringComparer.Ordinal);
            Tombstones = new Dictionary<string, NoteSync.Tombstone>(Book.Erased, StringComparer.Ordinal);
        }
    }

    /// <summary>打过的每一版（第几步打的）、有人在它之上改过的、被人永久删过的（第几步）。</summary>
    private sealed class Tracker
    {
        private static readonly string[] Words = ["买菜", "开会", "**粗**", "☐ 待办", "", "一段很长的字", "改了", "Hello"];

        private readonly Dictionary<string, Dictionary<string, int>> _typed = new(StringComparer.Ordinal);
        private readonly Dictionary<string, HashSet<string>> _built = new(StringComparer.Ordinal);
        private readonly Dictionary<string, int> _erased = new(StringComparer.Ordinal);
        private int _step;

        public void Act(NoteBook store, Rng random, long now)
        {
            var before = store.All.ToDictionary(note => note.Id, StringComparer.Ordinal);
            var alive = store.All.Where(note => note.DeletedAt is null).ToList();
            var trashed = store.All.Where(note => note.DeletedAt is not null).ToList();
            string? edited = null;
            switch (random.Next(12))
            {
                case 0:
                    if (store.All.Count < 30)
                    {
                        edited = store.Create(now, random.Pick(Words) ?? string.Empty).Id;
                    }

                    break;
                case 1:
                case 2:
                    if (random.Pick(alive) is { } appended)
                    {
                        store.SetBody(appended.Id, appended.Body + (random.Pick(Words) ?? string.Empty), now);
                        edited = appended.Id;
                    }

                    break;
                case 3:
                    if (random.Pick(alive) is { } titled)
                    {
                        store.SetTitle(titled.Id, random.Pick(Words) ?? string.Empty, now);
                        edited = titled.Id;
                    }

                    break;
                case 4:
                    if (random.Pick(alive) is { } colored)
                    {
                        store.SetColor(colored.Id, random.Next(8), now);
                        edited = colored.Id;
                    }

                    break;
                case 5:
                    if (random.Pick(alive) is { } pinned)
                    {
                        store.SetPinned(pinned.Id, !pinned.IsPinned, now);
                    }

                    break;
                case 6:
                    if (random.Pick(alive) is { } archived)
                    {
                        store.SetArchived(archived.Id, !archived.IsArchived, now);
                    }

                    break;
                case 7:
                    if (random.Pick(store.Active) is { } moved)
                    {
                        store.Move(moved.Id, random.Next(store.Active.Count + 1), now);
                    }

                    break;
                case 8:
                    if (random.Pick(alive) is { } deleted)
                    {
                        store.Delete(deleted.Id, now);
                    }

                    break;
                case 9:
                    if (random.Pick(trashed) is { } restored)
                    {
                        store.Restore(restored.Id, now);
                    }

                    break;
                case 10:
                    if (random.Chance(4))
                    {
                        store.EmptyTrash();
                    }
                    else if (random.Pick(trashed) is { } erased)
                    {
                        store.Erase([erased.Id]);
                    }

                    break;
                default:
                    store.PurgeExpired(now);
                    break;
            }

            // 内容真变了才算打过（改成一样的字、换成同一种颜色不算）
            if (edited is not null && store.Find(edited) is { } after)
            {
                var hash = NoteSync.ContentHash(after);
                var old = before.TryGetValue(edited, out var previous) ? previous : null;
                if (old is null || NoteSync.ContentHash(old) != hash)
                {
                    if (!_typed.TryGetValue(edited, out var hashes))
                    {
                        _typed[edited] = hashes = new Dictionary<string, int>(StringComparer.Ordinal);
                    }

                    hashes[hash] = _step;
                    if (old is not null)
                    {
                        if (!_built.TryGetValue(edited, out var built))
                        {
                            _built[edited] = built = new HashSet<string>(StringComparer.Ordinal);
                        }

                        built.Add(NoteSync.ContentHash(old));
                    }
                }
            }

            // 本机这一下没了的都是本机永久删的
            var remaining = store.All.Select(note => note.Id).ToHashSet(StringComparer.Ordinal);
            foreach (var id in before.Keys.Where(key => !remaining.Contains(key)))
            {
                _erased[id] = _step;
            }

            _step++;
        }

        /// <summary>不丢字：打过的每一版要么还是那一条（或另存它的那条）的内容、要么有人在它之上改过、要么打完之后那一条（或另存它的那条）
        /// 被永久删过。</summary>
        public void Check(IReadOnlyList<Note> notes, ulong seed, List<string> failures)
        {
            var contents = notes.ToDictionary(note => note.Id, NoteSync.ContentHash, StringComparer.Ordinal);
            foreach (var (id, hashes) in _typed)
            {
                foreach (var (hash, typedAt) in hashes)
                {
                    if (contents.TryGetValue(id, out var current) && current == hash)
                    {
                        continue;
                    }

                    var copy = NoteSync.CopyId(id, hash);
                    var kept = contents.TryGetValue(copy, out var saved) && saved == hash;
                    var superseded = (_built.TryGetValue(id, out var built) && built.Contains(hash)) ||
                                     (_built.TryGetValue(copy, out var builtCopy) && builtCopy.Contains(hash));
                    var erasedLater = (_erased.TryGetValue(id, out var at) ? at : -1) >= typedAt || _erased.ContainsKey(copy);
                    if (!kept && !superseded && !erasedLater)
                    {
                        failures.Add($"种子 {seed}：便签 {id[..8]} 打过的一版（{hash[..8]}）没了");
                    }
                }
            }
        }
    }

    /// <summary>比的那几样（修订号是各自的账，不比；状态、顺序的时刻按 StateTime / OrderTime 比）。</summary>
    private static Note Shape(Note note) => note with { Revision = 0, StateChangedAt = note.StateTime, OrderChangedAt = note.OrderTime };

    private static void Converged(IReadOnlyList<Mac> macs, ulong seed, List<string> failures)
    {
        static Dictionary<string, Note> Shapes(Mac mac) => mac.Book.All.ToDictionary(note => note.Id, Shape, StringComparer.Ordinal);
        var reference = Shapes(macs[0]);
        foreach (var mac in macs.Skip(1))
        {
            var mine = Shapes(mac);
            var differing = reference.Keys.Union(mine.Keys)
                .Where(id => !(reference.TryGetValue(id, out var a) && mine.TryGetValue(id, out var b) && a.Equals(b)))
                .Order(StringComparer.Ordinal).ToList();
            if (differing.Count > 0)
            {
                failures.Add($"种子 {seed}：几台没合到一起，不一样的 {differing.Count} 条，例如 {string.Join(",", differing.Take(3))}");
            }
        }
    }

    private static (ulong First, int Count, int Steps) Seeds()
    {
        var first = ulong.TryParse(Environment.GetEnvironmentVariable("KITTY_NOTES_SYNC_FUZZ_SEED"), out var seed) ? seed : 1;
        var steps = Math.Max(int.TryParse(Environment.GetEnvironmentVariable("KITTY_NOTES_SYNC_FUZZ"), out var count) ? count : 1200, 1);
        return (first, Math.Max(steps / 300, 1), Math.Min(steps, 300));
    }

    private static (List<Mac> Live, Mac Gone) Macs()
        => (
            new List<Mac>
            {
                new("A0000000-0000-4000-8000-00000000000A", 0), new("B0000000-0000-4000-8000-00000000000B", -180_000),
                new("C0000000-0000-4000-8000-00000000000C", 90_000),
            },
            new Mac("D0000000-0000-4000-8000-00000000000D", 30_000));

    // ---- 整份快照 ----

    /// <summary>合一轮：别人快照里的版本 + 所有人的墓碑（并起来）。返回变没变。</summary>
    private static bool Sync(Mac mac, IEnumerable<Mac> others, long now)
    {
        var remotes = new Dictionary<string, List<Note>>(StringComparer.Ordinal);
        var tombstones = new Dictionary<string, NoteSync.Tombstone>(mac.Book.Erased, StringComparer.Ordinal);
        foreach (var other in others)
        {
            foreach (var (id, note) in other.Folder)
            {
                if (!remotes.TryGetValue(id, out var list))
                {
                    remotes[id] = list = new List<Note>();
                }

                list.Add(note);
            }

            foreach (var (id, tombstone) in other.Tombstones)
            {
                tombstones[id] = tombstones.TryGetValue(id, out var old) ? old.Merged(tombstone) : tombstone;
            }
        }

        var local = mac.Book.All.ToDictionary(note => note.Id, StringComparer.Ordinal);
        var merges = new Dictionary<string, NoteSync.Merge>(StringComparer.Ordinal);
        foreach (var id in local.Keys.Union(remotes.Keys).ToList())
        {
            var mine = local.TryGetValue(id, out var found) ? found : null;
            var merge = NoteSync.MergeOne(
                mine, remotes.TryGetValue(id, out var versions) ? versions : [],
                tombstones.TryGetValue(id, out var tombstone) ? tombstone : null, now);
            var fresh = merge.Copies.Any(copy => !local.ContainsKey(copy.Id) && !tombstones.ContainsKey(copy.Id));
            if (merge.Note != mine || fresh)
            {
                merges[id] = merge;
            }
        }

        mac.Book.ApplySync(merges, tombstones);
        return merges.Count > 0;
    }

    [TestMethod]
    public void RandomEditsOnSeveralMacsConverge()
    {
        var (first, count, steps) = Seeds();
        var failures = new List<string>();
        for (var seed = first; seed < first + (ulong)count; seed++)
        {
            var random = new Rng(unchecked(seed * 0x9E3779B97F4A7C15UL) | 1);
            var (macs, gone) = Macs();
            var everyone = macs.Append(gone).ToList();
            var goneAt = random.Next(Math.Max(steps / 2, 1));
            var tracker = new Tracker();
            var clock = 1_800_000_000_000L;
            for (var step = 0; step < steps; step++)
            {
                clock += random.Next(5_000);
                if (random.Chance(60))
                {
                    clock += 10 * Day;
                }

                if (random.Pick(step <= goneAt ? everyone : macs) is not { } mac)
                {
                    continue;
                }

                var now = clock + mac.Skew;
                switch (random.Next(16))
                {
                    case < 12:
                        tracker.Act(mac.Book, random, now);
                        break;
                    case 12:
                    case 13:
                        mac.Snapshot();
                        break;
                    default:
                        Sync(mac, everyone.Where(other => other != mac), now);
                        break;
                }

                if (step == goneAt)
                {
                    gone.Snapshot();
                }
            }

            // 安静下来：先等到几台的钟都过了刚才那些改动，再轮流写、读几遍（第四台不动了）
            clock += 600_000;
            for (var pass = 0; pass < 4; pass++)
            {
                clock += 1000;
                foreach (var mac in macs)
                {
                    mac.Snapshot();
                }

                foreach (var mac in macs)
                {
                    Sync(mac, everyone.Where(other => other != mac), clock + mac.Skew);
                }
            }

            Converged(macs, seed, failures);
            tracker.Check(macs[0].Book.All, seed, failures);
            foreach (var mac in macs)
            {
                mac.Snapshot();
            }

            foreach (var mac in macs)
            {
                if (Sync(mac, everyone.Where(other => other != mac), clock + mac.Skew))
                {
                    failures.Add($"种子 {seed}：安静下来之后再合一轮还在变");
                }
            }
        }

        Assert.AreEqual(0, failures.Count, string.Join("\n", failures.Take(20)));
    }

    // ---- 走文件夹（文件写法 + 一轮的规划；读别人的时候随机旧一版、没下载完）----

    /// <summary>自己的子文件夹（读自己的不延迟）。</summary>
    private static NoteSyncFolder.Device Own(Mac mac)
    {
        var device = new NoteSyncFolder.Device();
        foreach (var (name, history) in mac.Files)
        {
            if (NoteSyncFolder.NoteId(name) is not { } id || history[^1] is not { } text)
            {
                continue;
            }

            if (NoteSyncFolder.NoteFrom(text, id) is { } note)
            {
                device.Notes[id] = note;
            }
            else
            {
                device.Unreadable.Add(id);
            }
        }

        device.Erased = mac.Erased.Count > 0 ? NoteSyncFolder.TombstonesFrom(mac.Erased[^1]) : NoteSyncFolder.Tombstones.Empty;
        return device;
    }

    /// <summary>挑一个文件读到的是哪一版（先后的第几版；null = 还没有）：七成是最新的、两成是更早的哪一版（或者还没有）、一成没下载完。
    /// full：全都看得见。</summary>
    private static (int? Index, bool Unreadable) PickVersion(int count, Rng random, bool full)
    {
        if (count == 0)
        {
            return (null, false);
        }

        if (full)
        {
            return (count - 1, false);
        }

        switch (random.Next(10))
        {
            case 0:
                return (null, true);
            case 1:
            case 2:
                var back = random.Next(count + 1);
                return (back < count ? back : (int?)null, false);
            default:
                return (count - 1, false);
        }
    }

    /// <summary>别人的子文件夹，同步盘那样慢慢到；另有一点点是被外面动过的（补了个换行：哈希对不上，当读不出来）。墓碑文件同样。</summary>
    private static NoteSyncFolder.Device View(Mac mac, Rng random, bool full)
    {
        var device = new NoteSyncFolder.Device();
        foreach (var (name, history) in mac.Files)
        {
            if (NoteSyncFolder.NoteId(name) is not { } id)
            {
                continue;
            }

            var (slot, unreadable) = PickVersion(history.Count, random, full);
            if (unreadable)
            {
                device.Unreadable.Add(id);
            }
            else if (slot is { } index && history[index] is { } text)
            {
                if (!full && random.Chance(20))
                {
                    text += "\n";
                }

                if (NoteSyncFolder.NoteFrom(text, id) is { } note)
                {
                    device.Notes[id] = note;
                }
                else
                {
                    device.Unreadable.Add(id);
                }
            }
        }

        var (last, erasedUnreadable) = PickVersion(mac.Erased.Count, random, full);
        device.Erased = erasedUnreadable
            ? NoteSyncFolder.Tombstones.Unreadable
            : last is { } chosen ? NoteSyncFolder.TombstonesFrom(mac.Erased[chosen]) : NoteSyncFolder.Tombstones.Empty;
        return device;
    }

    /// <summary>写出去：Publish 说要写的写成文件（往历史里加一版）、要删的加一个 null、墓碑变了重写。</summary>
    private static bool Publish(Mac mac)
    {
        var plan = NoteSyncFolder.Publish(
            mac.Book.All, mac.Book.Erased, mac.Files.Count == 0 && mac.Erased.Count == 0 ? null : Own(mac), new HashSet<string>(),
            new HashSet<string>());
        foreach (var note in plan.Writes)
        {
            History(mac, note.Id).Add(NoteSyncFolder.Text(note, TimeZoneInfo.Utc));
        }

        foreach (var id in plan.Deletes)
        {
            History(mac, id).Add(null);
        }

        if (plan.Erased is { } erased)
        {
            mac.Erased.Add(NoteSyncFolder.ErasedData(erased));
        }

        return !plan.IsEmpty;
    }

    private static List<string?> History(Mac mac, string id)
    {
        var name = NoteSyncFolder.FileName(id);
        if (!mac.Files.TryGetValue(name, out var history))
        {
            mac.Files[name] = history = new List<string?>();
        }

        return history;
    }

    /// <summary>自己文件夹里随便一个文件被写坏了（下一次写出去要重写它）。</summary>
    private static void Corrupt(Mac mac, Rng random)
    {
        if (random.Pick(mac.Files.Keys.Order(StringComparer.Ordinal).ToList()) is { } name && mac.Files[name][^1] is not null)
        {
            mac.Files[name].Add("写坏了");
        }
    }

    /// <summary>读一轮、合、落下去。返回变没变。</summary>
    private static bool Round(Mac mac, IEnumerable<Mac> others, Rng random, long now, bool full, ulong seed, List<string> failures)
    {
        var folder = new NoteSyncFolder.Folder { Marker = new NoteSyncFolder.Marker("L") };
        folder.Devices[mac.Device] = Own(mac);
        foreach (var other in others)
        {
            folder.Devices[other.Device] = View(other, random, full);
        }

        if (NoteSyncFolder.Regressed(mac.Book.All, folder, mac.Device).Count > 0)
        {
            failures.Add($"种子 {seed}：误认成库被退回去了");
        }

        var round = NoteSyncFolder.Round(mac.Book.All, mac.Book.Erased, folder, "L", now);
        if (round.Stop is not null)
        {
            return false;
        }

        mac.Book.ApplySync(round.Merges, round.Tombstones);
        return round.Merges.Count > 0;
    }

    [TestMethod]
    public void RandomRoundsThroughTheFolderConverge()
    {
        var (first, count, steps) = Seeds();
        var failures = new List<string>();
        for (var seed = first; seed < first + (ulong)count; seed++)
        {
            var random = new Rng(unchecked(seed * 0xBF58476D1CE4E5B9UL) | 1);
            var (macs, gone) = Macs();
            var everyone = macs.Append(gone).ToList();
            var goneAt = random.Next(Math.Max(steps / 2, 1));
            var tracker = new Tracker();
            var clock = 1_800_000_000_000L;
            for (var step = 0; step < steps; step++)
            {
                clock += random.Next(5_000);
                if (random.Chance(60))
                {
                    clock += 10 * Day;
                }

                if (random.Pick(step <= goneAt ? everyone : macs) is not { } mac)
                {
                    continue;
                }

                var now = clock + mac.Skew;
                switch (random.Next(16))
                {
                    case < 12:
                        tracker.Act(mac.Book, random, now);
                        break;
                    case 12:
                        Publish(mac);
                        break;
                    case 13:
                        if (random.Chance(5))
                        {
                            Corrupt(mac, random);
                        }
                        else
                        {
                            Publish(mac);
                        }

                        break;
                    default:
                        Round(mac, everyone.Where(other => other != mac), random, now, false, seed, failures);
                        Publish(mac);
                        break;
                }

                if (step == goneAt)
                {
                    Publish(gone);
                }
            }

            clock += 600_000;
            for (var pass = 0; pass < 4; pass++)
            {
                clock += 1000;
                foreach (var mac in macs)
                {
                    Publish(mac);
                }

                foreach (var mac in macs)
                {
                    Round(mac, everyone.Where(other => other != mac), random, clock + mac.Skew, true, seed, failures);
                }
            }

            Converged(macs, seed, failures);
            tracker.Check(macs[0].Book.All, seed, failures);
            foreach (var mac in macs)
            {
                Publish(mac);
            }

            foreach (var mac in macs)
            {
                if (Round(mac, everyone.Where(other => other != mac), random, clock + mac.Skew, true, seed, failures))
                {
                    failures.Add($"种子 {seed}：安静下来之后再合一轮还在变");
                }

                if (Publish(mac))
                {
                    failures.Add($"种子 {seed}：安静下来之后还有要写的");
                }
            }
        }

        Assert.AreEqual(0, failures.Count, string.Join("\n", failures.Take(20)));
    }
}
