// 账本的写法（REVIEW R26，原来在 App 的 Syncer 里）：{"entries":{编号:{"clock","hash","modified"}},"erased":{编号:钟}}，
// 键按序数排，同样的账本同样的字节（执行层靠比字节判断账本变没变，没变就不落）。
// 旧格式 {编号:"钟|哈希"}（R13 之前）当 modified=0 迁过来；写坏了、看不懂的抛 FormatException（照 mac SyncLedger.load：
// 当成第一次合的话，本机上一轮之后改的会被盖回去、删的被救回来）。
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Sync;

public static class SyncLedgerText
{
    public static string Encode(SyncLedgerData ledger)
    {
        var builder = new StringBuilder("{\"entries\":{");
        var first = true;
        foreach (var (id, entry) in ledger.Entries.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(":{\"clock\":");
            CanonicalJson.WriteString(entry.Clock.Text(), builder);
            builder.Append(",\"hash\":");
            CanonicalJson.WriteString(entry.Hash, builder);
            builder.Append(",\"modified\":").Append(entry.Modified).Append('}');
        }

        builder.Append("},\"erased\":{");
        first = true;
        foreach (var (id, clock) in ledger.Erased.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(':');
            CanonicalJson.WriteString(clock.Text(), builder);
        }

        return builder.Append("}}").ToString();
    }

    /// <summary>读账本；null / 空串 = 没有（第一次合）。</summary>
    public static SyncLedgerData? Decode(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new FormatException("ledger is not an object");
            }

            var ledger = new SyncLedgerData();
            if (root.TryGetProperty("entries", out var entries))
            {
                if (entries.ValueKind != JsonValueKind.Object)
                {
                    throw new FormatException("ledger entries");
                }

                foreach (var property in entries.EnumerateObject())
                {
                    if (property.Value.ValueKind != JsonValueKind.Object ||
                        !property.Value.TryGetProperty("clock", out var clock) ||
                        clock.ValueKind != JsonValueKind.String ||
                        !property.Value.TryGetProperty("hash", out var hash) ||
                        hash.ValueKind != JsonValueKind.String ||
                        !property.Value.TryGetProperty("modified", out var modified) ||
                        !modified.TryGetInt64(out var value))
                    {
                        throw new FormatException("ledger entry");
                    }

                    ledger.Entries[property.Name] = new SyncEntry(
                        SyncClock.Parse(clock.GetString()), hash.GetString() ?? string.Empty, value);
                }

                if (root.TryGetProperty("erased", out var erased))
                {
                    if (erased.ValueKind != JsonValueKind.Object)
                    {
                        throw new FormatException("ledger erased");
                    }

                    foreach (var property in erased.EnumerateObject())
                    {
                        if (property.Value.ValueKind != JsonValueKind.String)
                        {
                            throw new FormatException("ledger tombstone");
                        }

                        ledger.Erased[property.Name] = SyncClock.Parse(property.Value.GetString());
                    }
                }

                return ledger;
            }

            // 旧格式：{id: "clock|hash"}，没有墓碑。
            foreach (var property in root.EnumerateObject())
            {
                if (property.Name == "~clock")
                {
                    continue;
                }

                var parts = property.Value.ValueKind == JsonValueKind.String
                    ? (property.Value.GetString() ?? string.Empty).Split('|')
                    : Array.Empty<string>();
                if (parts.Length != 2)
                {
                    throw new FormatException("old ledger entry");
                }

                ledger.Entries[property.Name] = new SyncEntry(SyncClock.Parse(parts[0]), parts[1], 0);
            }

            return ledger.Entries.Count > 0 ? ledger : null;
        }
        catch (JsonException ex)
        {
            throw new FormatException("ledger json", ex);
        }
    }
}
