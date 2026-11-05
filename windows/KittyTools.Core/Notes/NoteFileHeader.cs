// 便签文件头（`---` 那几行）里值的写法和读法（PLAN-v13，照 mac Notes/NoteMarkdownFiles.swift 的 jsonString / iso / jsonDecode，
// 和 Swift 标准库给 Int / Double / Bool 的写法、读法）：同步文件夹的便签文件（NoteSyncFolder）和以后的 Markdown 导出共用。
// 同步文件要和 mac 一字不差（Fixtures/notes-sync-golden.json 锁住），所以这里每样都照 Swift 的行为写，不照 .NET 的习惯：
// - JsonString：Swift `JSONEncoder()`（默认设置）编一个字符串：转义 " \ 和控制字符（\b \f \n \r \t 短写，别的 \u00xx 小写），
//   **/ 写成 \/**（默认没开 withoutEscapingSlashes；同步那几类用的 CanonicalJson 开了，所以在它后面再换一道），别的原样。
// - JsonDecode：Swift `JSONDecoder` 解一个 JSON 字符串片段：开头一个 BOM 跳过；解不出来、不是字符串、有落单的代理项给 null。
// - Iso：`ISO8601DateFormatter`（.withInternetDateTime + .withFractionalSeconds）。时区由调用方给（mac 用 TimeZone.current，
//   这里不读本机时区）。同步时这两行（created / modified）读的时候不看，各台时区不同写出来不一样也不要紧。
// - Number：Swift 的 `Double.description`（「order: 」那一行）：最短能读回的数字；绝对值 ≤ 2^53、科学计数的指数 ≥ -4 写成小数
//   （整数带 .0），别的写成 1e+16 / 1e-05 这样；-0.0、inf、-inf、nan 照 Swift。
// - 读数：Swift 的 `Int64(String)` / `Double(String)` / `Bool(String)`：可以带一个 + 或 -，**不许有空白**（.NET 默认的数字格式
//   两头的空白都认，这里不用）；Bool 只认小写的 true / false。
// - Split：Swift 的 `split(separator:)`，按字（字位簇）切：分隔符后面跟着组合符号的那个字不算分隔符。
// - Decode：Swift `String(data:encoding: .utf8)`：严格的 UTF-8（坏字节整个给 null），开头的一个 BOM 去掉。
using System.Globalization;
using System.Text;
using System.Text.Json;
using KittyTools.Core.Sync;

namespace KittyTools.Core.Notes;

public static class NoteFileHeader
{
    private const long Day = 86_400_000;

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private static readonly JsonDocumentOptions Lenient = new() { AllowTrailingCommas = true };

    // ---- 写 ----

    /// <summary>值按 JSON 字符串写（mac NoteMarkdownFiles.jsonString）：JSON 字符串也是合法的 YAML。</summary>
    public static string JsonString(string value)
    {
        var builder = new StringBuilder(value.Length + 2);
        CanonicalJson.WriteString(value, builder);
        // CanonicalJson 的输出里 / 只会是它自己（转义序列里没有 /）
        return builder.Replace("/", "\\/").ToString();
    }

    /// <summary>时刻（整数毫秒）→ ISO 8601，到毫秒，带时区（UTC 写 Z）。</summary>
    // ponytail: 只在 1583–9999 年和 mac 一字不差。mac 的 ICU 在 1582-10-15 之前用儒略历、公元前的年份不带符号、离谱的年份
    // （同步文件里最大 ±2^53 毫秒）算出来的时分也怪；这里一律按公历往外推。读同步文件时不看这两行，不影响合并。
    public static string Iso(long milliseconds, TimeZoneInfo zone)
    {
        // 毫秒照原样写（在 Mac 上实测 30 万个随机时刻，ISO8601DateFormatter 写出来的毫秒都和原值一样，不会差 1）
        var instant = Math.Clamp(milliseconds, -NoteSyncFolder.MaxMilliseconds, NoteSyncFolder.MaxMilliseconds);
        var probe = Math.Clamp(instant, -62_135_596_800_000 + Day, 253_402_300_799_999 - Day);
        var offset = zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(probe));
        var offsetSeconds = offset.Ticks / TimeSpan.TicksPerSecond;
        var local = instant + offsetSeconds * 1000;
        var days = FloorDiv(local, Day);
        var inDay = local - days * Day;
        var (year, month, date) = Civil(days);
        var builder = new StringBuilder(32);
        builder.Append((year >= 1 ? year : 1 - year).ToString("D4", CultureInfo.InvariantCulture)).Append('-')
            .Append(Two(month)).Append('-').Append(Two(date)).Append('T')
            .Append(Two(inDay / 3_600_000)).Append(':').Append(Two(inDay / 60_000 % 60)).Append(':')
            .Append(Two(inDay / 1000 % 60)).Append('.')
            .Append((inDay % 1000).ToString("D3", CultureInfo.InvariantCulture));
        if (offsetSeconds == 0)
        {
            return builder.Append('Z').ToString();
        }

        var magnitude = Math.Abs(offsetSeconds);
        builder.Append(offsetSeconds < 0 ? '-' : '+').Append(Two(magnitude / 3600)).Append(':').Append(Two(magnitude / 60 % 60));
        if (magnitude % 60 != 0)
        {
            builder.Append(':').Append(Two(magnitude % 60));
        }

        return builder.ToString();
    }

    /// <summary>Swift 的 Double.description。</summary>
    public static string Number(double value)
    {
        if (double.IsNaN(value))
        {
            return "nan";
        }

        if (double.IsInfinity(value))
        {
            return value > 0 ? "inf" : "-inf";
        }

        if (value == 0)
        {
            return double.IsNegative(value) ? "-0.0" : "0.0";
        }

        // .NET 的 R 是最短能读回的数字（同 Swift），只是排法不一样：拆成有效数字和科学计数的指数，再照 Swift 排
        var text = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture);
        var exponent = 0;
        var mark = text.IndexOfAny(['E', 'e']);
        if (mark >= 0)
        {
            exponent = int.Parse(text.AsSpan(mark + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            text = text[..mark];
        }

        var dot = text.IndexOf('.');
        var whole = dot < 0 ? text : text[..dot];
        var all = dot < 0 ? text : whole + text[(dot + 1)..];
        var zeros = 0;
        while (zeros < all.Length - 1 && all[zeros] == '0')
        {
            zeros++;
        }

        var digits = all[zeros..].TrimEnd('0');
        if (digits.Length == 0)
        {
            digits = "0";
        }

        var scientific = whole.Length - 1 - zeros + exponent;
        var sign = value < 0 ? "-" : string.Empty;
        if (scientific < -4 || Math.Abs(value) > 9_007_199_254_740_992.0)
        {
            var mantissa = digits.Length > 1 ? digits[..1] + "." + digits[1..] : digits;
            return sign + mantissa + "e" + (scientific < 0 ? "-" : "+") +
                   Math.Abs(scientific).ToString("D2", CultureInfo.InvariantCulture);
        }

        if (scientific < 0)
        {
            return sign + "0." + new string('0', -scientific - 1) + digits;
        }

        var integer = digits.Length > scientific + 1 ? digits[..(scientific + 1)] : digits + new string('0', scientific + 1 - digits.Length);
        var fraction = digits.Length > scientific + 1 ? digits[(scientific + 1)..] : "0";
        return sign + integer + "." + fraction;
    }

    public static string Bool(bool value) => value ? "true" : "false";

    // ---- 读 ----

    /// <summary>mac NoteMarkdownFiles.jsonDecode：一个 JSON 字符串片段 → 字符串；别的给 null。</summary>
    public static string? JsonDecode(string raw)
    {
        // ponytail: Swift 的解析器对没用上的那部分比这里宽（片段后面不许有东西，这里一样；对象里多出来的键的值写坏了它照读）；
        // 字符串片段两边一样
        var text = raw.Length > 0 && raw[0] == '\uFEFF' ? raw[1..] : raw;
        try
        {
            using var document = JsonDocument.Parse(text, Lenient);
            return document.RootElement.ValueKind == JsonValueKind.String ? document.RootElement.GetString() : null;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>解一段 JSON（Swift JSONDecoder 的口径：开头一个 BOM 跳过、允许结尾多一个逗号）；解不出来给 null。调用方负责 Dispose。</summary>
    public static JsonDocument? Json(ReadOnlySpan<byte> utf8)
    {
        ReadOnlySpan<byte> bom = [0xEF, 0xBB, 0xBF];
        if (utf8.StartsWith(bom))
        {
            utf8 = utf8[3..];
        }

        try
        {
            return JsonDocument.Parse(new ReadOnlyMemory<byte>(utf8.ToArray()), Lenient);
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>对象里一个键第一次出现时的值（Swift JSONDecoder 碰上重复的键用第一个；System.Text.Json 的 TryGetProperty 用最后一个）。</summary>
    public static bool TryGetFirst(JsonElement element, string name, out JsonElement value)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (property.NameEquals(name))
            {
                value = property.Value;
                return true;
            }
        }

        value = default;
        return false;
    }

    /// <summary>Swift JSONDecoder 解一个整数（Int / Int64）：整数字面量，或者正好是整数、在范围里的小数写法（1.0、1e3）。</summary>
    public static bool TryGetInteger(JsonElement element, out long value)
    {
        value = 0;
        if (element.ValueKind != JsonValueKind.Number)
        {
            return false;
        }

        if (element.TryGetInt64(out value))
        {
            return true;
        }

        if (!element.TryGetDouble(out var number) || !double.IsFinite(number) || Math.Floor(number) != number ||
            number < -9_223_372_036_854_775_808.0 || number >= 9_223_372_036_854_775_808.0)
        {
            return false;
        }

        value = (long)number;
        return true;
    }

    /// <summary>Swift 的 Int64(String)：可以带一个 + 或 -，只认 ASCII 数字，不许有空白。</summary>
    public static long? ParseInt64(string raw)
        => raw.Length > 0 && !raw.Contains('\0') &&
           long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;

    /// <summary>Swift 的 Double(String)：不许有空白。</summary>
    // ponytail: Swift 还认十六进制的浮点数（0x1p3），这里不认——mac 写出去的从来不是那种写法，只有被人改过的文件才会碰上
    public static double? ParseDouble(string raw)
        => raw.Length > 0 && !raw.Contains('\0') &&
           double.TryParse(raw, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent,
               CultureInfo.InvariantCulture, out var value)
            ? value
            : null;

    /// <summary>Swift 的 Bool(String)：只认 true / false。</summary>
    public static bool? ParseBool(string raw) => raw switch
    {
        "true" => true,
        "false" => false,
        _ => null,
    };

    /// <summary>Swift String(data:encoding: .utf8)：严格的 UTF-8，开头的一个 BOM 去掉；坏了给 null。</summary>
    public static string? Decode(ReadOnlySpan<byte> bytes)
    {
        ReadOnlySpan<byte> bom = [0xEF, 0xBB, 0xBF];
        if (bytes.StartsWith(bom))
        {
            bytes = bytes[3..];
        }

        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>Swift 的 split(separator:)（按字位簇）：omittingEmpty 时丢掉空段。</summary>
    public static List<string> Split(string text, char separator, bool omittingEmpty = true)
    {
        var parts = new List<string>();
        void Add(int start, int end)
        {
            if (end > start || !omittingEmpty)
            {
                parts.Add(text[start..end]);
            }
        }

        var begin = 0;
        if (Ascii.IsValid(text))
        {
            // 全是 ASCII：字位簇只有 \r\n 一种是两个字符的，分隔符不是 \r \n，按字符切一样
            for (var index = 0; index < text.Length; index++)
            {
                if (text[index] == separator)
                {
                    Add(begin, index);
                    begin = index + 1;
                }
            }
        }
        else
        {
            var enumerator = StringInfo.GetTextElementEnumerator(text);
            while (enumerator.MoveNext())
            {
                var index = enumerator.ElementIndex;
                if (text[index] == separator && enumerator.GetTextElement().Length == 1)
                {
                    Add(begin, index);
                    begin = index + 1;
                }
            }
        }

        Add(begin, text.Length);
        return parts;
    }

    /// <summary>一行里第一个单独成字的 ch（后面没跟组合符号）；没有给 -1。</summary>
    public static int IndexOfCharacter(string line, char ch)
    {
        if (Ascii.IsValid(line))
        {
            return line.IndexOf(ch);
        }

        var enumerator = StringInfo.GetTextElementEnumerator(line);
        while (enumerator.MoveNext())
        {
            if (line[enumerator.ElementIndex] == ch && enumerator.GetTextElement().Length == 1)
            {
                return enumerator.ElementIndex;
            }
        }

        return -1;
    }

    /// <summary>UUID 的写法（Swift UUID(uuidString:)：36 个字、8-4-4-4-12、十六进制大小写都行）→ 大写；不是给 null。</summary>
    public static string? UuidText(string raw)
    {
        if (raw.Length != 36)
        {
            return null;
        }

        for (var index = 0; index < 36; index++)
        {
            var ok = (index is 8 or 13 or 18 or 23) ? raw[index] == '-' : char.IsAsciiHexDigit(raw[index]);
            if (!ok)
            {
                return null;
            }
        }

        return raw.ToUpperInvariant();
    }

    // ---- 日期换算 ----

    private static long FloorDiv(long a, long b) => a / b - (a % b < 0 ? 1 : 0);

    private static string Two(long value) => value.ToString("D2", CultureInfo.InvariantCulture);

    /// <summary>1970-01-01 起第几天 → 公历的年月日（往外推的公历，H. Hinnant 的算法）。</summary>
    private static (long Year, long Month, long Day) Civil(long days)
    {
        var z = days + 719_468;
        var era = FloorDiv(z, 146_097);
        var dayOfEra = z - era * 146_097;
        var yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        var dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        var shifted = (5 * dayOfYear + 2) / 153;
        var day = dayOfYear - (153 * shifted + 2) / 5 + 1;
        var month = shifted < 10 ? shifted + 3 : shifted - 9;
        var year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
        return (year, month, day);
    }
}
