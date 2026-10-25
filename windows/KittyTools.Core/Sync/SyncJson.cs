// 同步用的 JSON 写出（PLAN-v5 §2.4）：键按字母排、空值不写、只转义 " \ 和控制字符
// （\b \f \n \r \t 用短写法，其余 U+0000–U+001F 写 \u00xx 小写）；/ < > & ' 和所有非 ASCII 原样写。
// 不用 System.Text.Json 的序列化器（它会转义非 ASCII 和 <>&'）。哈希 = UTF-8 的 SHA-256 前 16 字节小写十六进制。
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Sync;

public static class CanonicalJson
{
    public static string Write(JsonElement element)
    {
        var builder = new StringBuilder(128);
        Write(element, builder);
        return builder.ToString();
    }

    public static string Hash(string json)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(json));
        return Convert.ToHexStringLower(digest.AsSpan(0, 16));
    }

    /// <summary>
    /// 同步的 decodeExact（PLAN-v5 §2.4）：把内容解开再按我们的规矩编回去，必须和原来的字节一样。
    /// 不一样说明这份不是按规矩写的（或者有我们不认识的写法），这一条不能落地。
    /// </summary>
    public static bool IsCanonical(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return string.Equals(Write(document.RootElement), json, StringComparison.Ordinal);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static void Write(JsonElement element, StringBuilder builder)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                builder.Append('{');
                var first = true;
                foreach (var property in element.EnumerateObject()
                             .Where(item => item.Value.ValueKind != JsonValueKind.Null)
                             .OrderBy(item => item.Name, StringComparer.Ordinal))
                {
                    if (!first)
                    {
                        builder.Append(',');
                    }

                    first = false;
                    WriteString(property.Name, builder);
                    builder.Append(':');
                    Write(property.Value, builder);
                }

                builder.Append('}');
                break;

            case JsonValueKind.Array:
                builder.Append('[');
                var index = 0;
                foreach (var item in element.EnumerateArray())
                {
                    if (index++ > 0)
                    {
                        builder.Append(',');
                    }

                    Write(item, builder);
                }

                builder.Append(']');
                break;

            case JsonValueKind.String:
                WriteString(element.GetString() ?? string.Empty, builder);
                break;

            case JsonValueKind.Number:
                // 整数原样写；小数按最短往返写法（同步的内容里只有整数）。
                builder.Append(element.GetRawText());
                break;

            case JsonValueKind.True:
                builder.Append("true");
                break;

            case JsonValueKind.False:
                builder.Append("false");
                break;

            case JsonValueKind.Null:
                builder.Append("null");
                break;

            default:
                builder.Append("null");
                break;
        }
    }

    public static void WriteString(string value, StringBuilder builder)
    {
        builder.Append('"');
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '\b':
                    builder.Append("\\b");
                    break;
                case '\f':
                    builder.Append("\\f");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                default:
                    if (ch < 0x20)
                    {
                        builder.Append("\\u").Append(((int)ch).ToString("x4"));
                    }
                    else
                    {
                        builder.Append(ch);
                    }

                    break;
            }
        }

        builder.Append('"');
    }
}

/// <summary>版本钟：编号 → 次数；写成「编号:次数」按编号排、逗号隔开，空钟是空串。</summary>
public sealed class SyncClock
{
    public const int MaxEntries = 1024;

    public const int MaxTextBytes = 64 * 1024;

    /// <summary>一格计数最大到多少：mac 是 1 &lt;&lt; 40，Windows 的计数是 int，收到 1 &lt;&lt; 30（再加一也不溢出）。
    /// 超出的格子读文件时算读不出来（同 mac 的 NoteSync.clock 丢格子后 count 对不上）。</summary>
    public const int MaxCounter = 1 << 30;

    private readonly Dictionary<string, int> _counters = new(StringComparer.Ordinal);

    public SyncClock()
    {
    }

    public SyncClock(IEnumerable<KeyValuePair<string, int>> counters)
    {
        foreach (var (key, value) in counters)
        {
            _counters[key] = value;
        }
    }

    public IReadOnlyDictionary<string, int> Counters => _counters;

    public int this[string id]
    {
        get => _counters.TryGetValue(id, out var value) ? value : 0;
        set => _counters[id] = value;
    }

    public bool IsEmpty => _counters.Count == 0;

    public static SyncClock Parse(string? text)
    {
        var clock = new SyncClock();
        if (string.IsNullOrEmpty(text))
        {
            return clock;
        }

        if (Encoding.UTF8.GetByteCount(text) > MaxTextBytes)
        {
            throw new FormatException("clock too large");
        }

        var entries = text.Split(',', StringSplitOptions.RemoveEmptyEntries);
        if (entries.Length > MaxEntries)
        {
            throw new FormatException("clock too many entries");
        }

        foreach (var entry in entries)
        {
            var colon = entry.LastIndexOf(':');
            if (colon <= 0 || colon == entry.Length - 1)
            {
                throw new FormatException("clock entry");
            }

            var id = entry[..colon];
            if (!IsValidId(id) || !int.TryParse(entry[(colon + 1)..], out var counter) ||
                counter is < 1 or > MaxCounter)
            {
                throw new FormatException("clock entry");
            }

            if (clock._counters.ContainsKey(id))
            {
                throw new FormatException("clock duplicate");
            }

            clock._counters[id] = counter;
        }

        return clock;
    }

    public string Text()
        => string.Join(',', _counters
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{pair.Key}:{pair.Value}"));

    public bool Precedes(SyncClock other)
    {
        var less = false;
        foreach (var (id, count) in _counters)
        {
            var theirs = other[id];
            if (count > theirs)
            {
                return false;
            }

            less |= count < theirs;
        }

        foreach (var id in other._counters.Keys)
        {
            if (!_counters.ContainsKey(id))
            {
                less = true;
            }
        }

        return less;
    }

    /// <summary>并：每个编号取较大的次数。</summary>
    public SyncClock Union(SyncClock other)
    {
        var result = new SyncClock(_counters);
        foreach (var (id, count) in other._counters)
        {
            result[id] = Math.Max(result[id], count);
        }

        return result;
    }

    public static bool IsValidId(string id)
        => id.Length is > 0 and <= 256 && id.All(ch => !char.IsControl(ch));
}
