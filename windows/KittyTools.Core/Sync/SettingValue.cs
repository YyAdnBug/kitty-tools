// 设置同步里一项的值（PLAN-v21 第 1 批）：mac SettingsArchive.Value 那几种（布尔、整数、小数、文字、一组文字），外加
// Windows 独有那几项用的「文字 → 文字」表（启动器命令的别名这些，只在 Windows 之间走）。
// 编出来的写法同 mac SyncRecords.encoder（CanonicalJson）：true / 7 / 1.25 / "top" / ["a","b"] / {"a":"b"}（键排好序）；
// 小数是整数值时写成整数（mac 的 JSONEncoder 把 1.0 写成 1，收的那边按整数读回再转小数，SettingsArchive.Value 的注释）。
// 解开时严（mac decodeExact）：编回去和原来的字节不一样的（更新版本的写法、多余的空格）当解不开，进透传。
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Sync;

public enum SettingType
{
    Bool,
    Int,
    Double,
    Text,
    Texts,
    Map,
}

public sealed class SettingValue : IEquatable<SettingValue>
{
    private readonly bool _flag;
    private readonly long _number;
    private readonly double _real;
    private readonly string? _text;
    private readonly string[]? _texts;
    private readonly SortedDictionary<string, string>? _map;

    private SettingValue(SettingType type, bool flag = false, long number = 0, double real = 0, string? text = null,
        string[]? texts = null, SortedDictionary<string, string>? map = null)
    {
        Type = type;
        _flag = flag;
        _number = number;
        _real = real;
        _text = text;
        _texts = texts;
        _map = map;
    }

    public SettingType Type { get; }

    public bool Flag => _flag;

    public long Number => _number;

    /// <summary>小数；整数也能当小数读（mac 收 .double 时也认 .int）。</summary>
    public double Real => Type == SettingType.Int ? _number : _real;

    public string Text => _text ?? string.Empty;

    public IReadOnlyList<string> Texts => _texts ?? Array.Empty<string>();

    public IReadOnlyDictionary<string, string> Map => (IReadOnlyDictionary<string, string>?)_map ?? new Dictionary<string, string>();

    public static SettingValue Of(bool flag) => new(SettingType.Bool, flag: flag);

    public static SettingValue Of(long number) => new(SettingType.Int, number: number);

    /// <summary>不是有限数时给 null（JSON 写不出来）。</summary>
    public static SettingValue? Of(double real) => double.IsFinite(real) ? new(SettingType.Double, real: real) : null;

    public static SettingValue Of(string text) => new(SettingType.Text, text: text);

    public static SettingValue Of(IEnumerable<string> texts) => new(SettingType.Texts, texts: texts.ToArray());

    public static SettingValue Of(IEnumerable<KeyValuePair<string, string>> map)
    {
        var sorted = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in map)
        {
            sorted[key] = value;
        }

        return new(SettingType.Map, map: sorted);
    }

    /// <summary>编成同步记录里的那一段 JSON。</summary>
    public string Encode()
    {
        var builder = new StringBuilder(32);
        switch (Type)
        {
            case SettingType.Bool:
                builder.Append(_flag ? "true" : "false");
                break;
            case SettingType.Int:
                builder.Append(_number.ToString(CultureInfo.InvariantCulture));
                break;
            case SettingType.Double:
                builder.Append(WriteReal(_real));
                break;
            case SettingType.Text:
                CanonicalJson.WriteString(Text, builder);
                break;
            case SettingType.Texts:
                builder.Append('[');
                for (var index = 0; index < Texts.Count; index++)
                {
                    if (index > 0)
                    {
                        builder.Append(',');
                    }

                    CanonicalJson.WriteString(Texts[index], builder);
                }

                builder.Append(']');
                break;
            case SettingType.Map:
                builder.Append('{');
                var first = true;
                foreach (var (key, value) in _map ?? new SortedDictionary<string, string>(StringComparer.Ordinal))
                {
                    if (!first)
                    {
                        builder.Append(',');
                    }

                    first = false;
                    CanonicalJson.WriteString(key, builder);
                    builder.Append(':');
                    CanonicalJson.WriteString(value, builder);
                }

                builder.Append('}');
                break;
        }

        return builder.ToString();
    }

    /// <summary>解一段记录（按 mac Value 的顺序认：布尔、整数、小数、文字、一组文字；再加文字表）。
    /// 编回去和原来的字节不一样、或者是别的形状（数组里有数字、表里的值不是文字）给 null。</summary>
    public static SettingValue? Decode(string text)
    {
        SettingValue? value;
        try
        {
            using var document = JsonDocument.Parse(text);
            value = Read(document.RootElement);
        }
        catch (JsonException)
        {
            return null;
        }

        return value is not null && string.Equals(value.Encode(), text, StringComparison.Ordinal) ? value : null;
    }

    private static SettingValue? Read(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.True:
                return Of(true);
            case JsonValueKind.False:
                return Of(false);
            case JsonValueKind.Number:
                if (element.TryGetInt64(out var number))
                {
                    return Of(number);
                }

                return element.TryGetDouble(out var real) ? Of(real) : null;
            case JsonValueKind.String:
                return Of(element.GetString() ?? string.Empty);
            case JsonValueKind.Array:
                var texts = new List<string>();
                foreach (var item in element.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.String)
                    {
                        return null;
                    }

                    texts.Add(item.GetString() ?? string.Empty);
                }

                return Of(texts);
            case JsonValueKind.Object:
                var map = new List<KeyValuePair<string, string>>();
                var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject())
                {
                    if (property.Value.ValueKind != JsonValueKind.String || !seen.Add(property.Name))
                    {
                        return null;
                    }

                    map.Add(new(property.Name, property.Value.GetString() ?? string.Empty));
                }

                return Of(map);
            default:
                return null;
        }
    }

    /// <summary>整数值写成整数（同 mac）；别的按最短往返写法。</summary>
    private static string WriteReal(double real)
        => real == Math.Floor(real) && Math.Abs(real) < 1e15
            ? ((long)real).ToString(CultureInfo.InvariantCulture)
            : real.ToString("R", CultureInfo.InvariantCulture);

    public bool Equals(SettingValue? other)
        => other is not null && string.Equals(Encode(), other.Encode(), StringComparison.Ordinal);

    public override bool Equals(object? obj) => obj is SettingValue other && Equals(other);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Encode());

    public override string ToString() => Encode();
}
