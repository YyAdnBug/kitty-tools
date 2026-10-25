// 同步文件（PLAN-v5 §2.2）：{"erased":[…],"format":1,"kind":"clips","records":[…]}，
// 键按字母排、records / erased 按 id 序数排；value 是那一条内容的 JSON 文本，原样存。
// 读的时候从严：任何一条不合格整份算读不出来；format 比 1 大、结构又对的算「更新版本写的」。
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Sync;

public sealed class SyncRecord
{
    public string Id { get; init; } = string.Empty;

    public SyncClock Clock { get; init; } = new();

    public long Modified { get; init; }

    public string Value { get; init; } = string.Empty;
}

public sealed class SyncErased
{
    public string Id { get; init; } = string.Empty;

    public SyncClock Clock { get; init; } = new();
}

public sealed class SyncFile
{
    public const int CurrentFormat = 1;

    public const int MaxBytes = 32 << 20;

    public string Kind { get; init; } = string.Empty;

    public int Format { get; init; } = CurrentFormat;

    public List<SyncRecord> Records { get; init; } = new();

    public List<SyncErased> Erased { get; init; } = new();

    /// <summary>文件是更新版本写的：这一类整轮不合。</summary>
    public bool IsNewer { get; init; }

    public static SyncFile Empty(string kind) => new() { Kind = kind };

    public string Encode()
    {
        var builder = new StringBuilder(256);
        builder.Append("{\"erased\":[");
        var first = true;
        foreach (var erased in Erased.OrderBy(item => item.Id, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append("{\"clock\":");
            CanonicalJson.WriteString(erased.Clock.Text(), builder);
            builder.Append(",\"id\":");
            CanonicalJson.WriteString(erased.Id, builder);
            builder.Append('}');
        }

        builder.Append("],\"format\":").Append(Format).Append(",\"kind\":");
        CanonicalJson.WriteString(Kind, builder);
        builder.Append(",\"records\":[");
        first = true;
        foreach (var record in Records.OrderBy(item => item.Id, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append("{\"clock\":");
            CanonicalJson.WriteString(record.Clock.Text(), builder);
            builder.Append(",\"id\":");
            CanonicalJson.WriteString(record.Id, builder);
            builder.Append(",\"modified\":").Append(record.Modified);
            builder.Append(",\"value\":");
            CanonicalJson.WriteString(record.Value, builder);
            builder.Append('}');
        }

        builder.Append("]}");
        return builder.ToString();
    }

    /// <summary>读一份；kind 对不上、结构不对返回 null；format &gt; 1 且结构对返回 IsNewer。</summary>
    public static SyncFile? Decode(string text, string expectedKind)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaxBytes)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("format", out var formatElement) ||
                !formatElement.TryGetInt32(out var format) || format < 1 ||
                !root.TryGetProperty("kind", out var kindElement) ||
                kindElement.ValueKind != JsonValueKind.String ||
                kindElement.GetString() != expectedKind)
            {
                return null;
            }

            var records = new List<SyncRecord>();
            var erased = new List<SyncErased>();
            // records 和 erased 各自查重（同一编号在两边的都有是合法的：别处删过、本机又改回来了——
            // mac 的 file(from:) 也是分开查的；共用一套会把这一份整份当成读不出来）。
            var recordIds = new HashSet<string>(StringComparer.Ordinal);
            var erasedIds = new HashSet<string>(StringComparer.Ordinal);
            if (root.TryGetProperty("records", out var recordsElement))
            {
                if (recordsElement.ValueKind != JsonValueKind.Array)
                {
                    return null;
                }

                foreach (var item in recordsElement.EnumerateArray())
                {
                    var record = ReadRecord(item);
                    if (record is null || !recordIds.Add(record.Id))
                    {
                        return null;
                    }

                    records.Add(record);
                }
            }

            if (root.TryGetProperty("erased", out var erasedElement))
            {
                if (erasedElement.ValueKind != JsonValueKind.Array)
                {
                    return null;
                }

                foreach (var item in erasedElement.EnumerateArray())
                {
                    var erasedItem = ReadErased(item);
                    if (erasedItem is null || !erasedIds.Add(erasedItem.Id))
                    {
                        return null;
                    }

                    erased.Add(erasedItem);
                }
            }

            return new SyncFile
            {
                Kind = expectedKind,
                Format = format,
                Records = records,
                Erased = erased,
                IsNewer = format > CurrentFormat,
            };
        }
        catch (JsonException)
        {
            return null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static SyncRecord? ReadRecord(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object ||
            !item.TryGetProperty("id", out var idElement) || idElement.ValueKind != JsonValueKind.String ||
            !item.TryGetProperty("clock", out var clockElement) || clockElement.ValueKind != JsonValueKind.String ||
            !item.TryGetProperty("modified", out var modifiedElement) ||
            !modifiedElement.TryGetInt64(out var modified) ||
            modified is < 0 or > (1L << 53) ||
            !item.TryGetProperty("value", out var valueElement) || valueElement.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        var id = idElement.GetString() ?? string.Empty;
        if (!SyncClock.IsValidId(id))
        {
            return null;
        }

        try
        {
            return new SyncRecord
            {
                Id = id,
                Clock = SyncClock.Parse(clockElement.GetString()),
                Modified = modified,
                Value = valueElement.GetString() ?? string.Empty,
            };
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static SyncErased? ReadErased(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object ||
            !item.TryGetProperty("id", out var idElement) || idElement.ValueKind != JsonValueKind.String ||
            !item.TryGetProperty("clock", out var clockElement) || clockElement.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        var id = idElement.GetString() ?? string.Empty;
        if (!SyncClock.IsValidId(id))
        {
            return null;
        }

        try
        {
            return new SyncErased { Id = id, Clock = SyncClock.Parse(clockElement.GetString()) };
        }
        catch (FormatException)
        {
            return null;
        }
    }
}

/// <summary>合并（PLAN-v5 §3 的简化版）：同一条取「modified 大的」；一样时看版本钟（后者胜）；
/// 墓碑盖过不比它新的记录。第一版只做并集，不做落地和账本（见报告）。</summary>
public static class SyncMerge
{
    public static SyncFile Merge(string kind, IReadOnlyList<SyncFile> files)
    {
        var records = new Dictionary<string, SyncRecord>(StringComparer.Ordinal);
        var erased = new Dictionary<string, SyncErased>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            foreach (var record in file.Records)
            {
                if (!records.TryGetValue(record.Id, out var current) || Wins(record, current))
                {
                    records[record.Id] = record;
                }
            }

            foreach (var tombstone in file.Erased)
            {
                if (!erased.TryGetValue(tombstone.Id, out var current) ||
                    ClockWins(tombstone.Clock, current.Clock))
                {
                    erased[tombstone.Id] = tombstone;
                }
            }
        }

        foreach (var (id, tombstone) in erased)
        {
            // 记录比墓碑新（墓碑的钟 precedes 记录的钟）就复活，否则按删除处理。
            if (records.TryGetValue(id, out var record) && !tombstone.Clock.Precedes(record.Clock))
            {
                records.Remove(id);
            }
        }

        return new SyncFile
        {
            Kind = kind,
            Records = records.Values.ToList(),
            Erased = erased.Values.ToList(),
        };
    }

    private static bool Wins(SyncRecord candidate, SyncRecord current)
    {
        if (candidate.Modified != current.Modified)
        {
            return candidate.Modified > current.Modified;
        }

        // 同时改的两条（钟互不包含）也要有一个确定的结果，几台合出来才收敛：
        // 先看钟的文本，再看内容本身。
        if (ClockWins(candidate.Clock, current.Clock))
        {
            return true;
        }

        if (ClockWins(current.Clock, candidate.Clock))
        {
            return false;
        }

        return string.CompareOrdinal(candidate.Value, current.Value) > 0;
    }

    private static bool ClockWins(SyncClock candidate, SyncClock current)
    {
        if (current.Precedes(candidate))
        {
            return true;
        }

        if (candidate.Precedes(current))
        {
            return false;
        }

        return string.CompareOrdinal(candidate.Text(), current.Text()) > 0;
    }
}
