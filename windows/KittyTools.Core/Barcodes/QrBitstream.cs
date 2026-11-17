// 识字认码（REVIEW R105）：二维码纠错后的数据码字 → 文字（ISO/IEC 18004 第 7 章）。
// 模式：数字（3 位一组 10 位）、字母数字（2 个一组 11 位，45 个字符）、字节、汉字（Shift_JIS 的双字节，13 位一个）、
// ECI（换字符集，1–3 字节的指定符）、结构链接（跳过 16 位，各个码分开认）、FNC1（GS1：字母数字里的 % 是分隔符 GS，%% 是 %）。
// 字符数指示符的位数按版本 1–9 / 10–26 / 27–40 三档。遇到不认识的模式、位数不够就当读不出来。
// 字节模式的字符集：有 ECI 照 ECI；没有时 UTF-8 合法就按 UTF-8，不然试 GB18030（国内老的生成器写 GBK 不带 ECI），再不行按 ISO-8859-1。
// mac 的 Vision 没有 ECI 时不是 UTF-8 就按 ISO-8859-1（GBK 的码读出来是乱码），这里多试一步 GB18030（REVIEW R105「替用户定的」）。
using System.Text;

namespace KittyTools.Core.Barcodes;

internal static class QrBitstream
{
    private const string Alphanumeric = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

    static QrBitstream() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    /// <summary>读不出来（模式不认识、位数不够、数值越界）返回 null。</summary>
    public static string? Parse(byte[] data, int version)
    {
        var reader = new BitReader(data);
        var text = new StringBuilder();
        var pending = new List<byte>();
        var eci = -1;
        var fnc1 = false;
        var sizeClass = version <= 9 ? 0 : version <= 26 ? 1 : 2;

        void Flush()
        {
            if (pending.Count > 0)
            {
                text.Append(Decode(pending.ToArray(), eci));
                pending.Clear();
            }
        }

        while (reader.Available >= 4)
        {
            var mode = reader.Read(4);
            switch (mode)
            {
                case 0:  // 结束符
                    Flush();
                    return text.ToString();

                case 7:  // ECI
                {
                    Flush();
                    if (reader.Available < 8)
                    {
                        return null;
                    }

                    var first = reader.Read(8);
                    if ((first & 0x80) == 0)
                    {
                        eci = first & 0x7F;
                    }
                    else if ((first & 0xC0) == 0x80 && reader.Available >= 8)
                    {
                        eci = ((first & 0x3F) << 8) | reader.Read(8);
                    }
                    else if ((first & 0xE0) == 0xC0 && reader.Available >= 16)
                    {
                        eci = ((first & 0x1F) << 16) | reader.Read(16);
                    }
                    else
                    {
                        return null;
                    }

                    break;
                }

                case 3:  // 结构链接：序号和校验，每个码各认各的
                    if (reader.Available < 16)
                    {
                        return null;
                    }

                    reader.Read(16);
                    break;

                case 5:  // FNC1 在第一位（GS1）
                    fnc1 = true;
                    break;

                case 9:  // FNC1 在第二位：跟着 8 位应用指示符
                    if (reader.Available < 8)
                    {
                        return null;
                    }

                    reader.Read(8);
                    fnc1 = true;
                    break;

                case 1:
                    Flush();
                    if (!ReadNumeric(ref reader, new[] { 10, 12, 14 }[sizeClass], text))
                    {
                        return null;
                    }

                    break;

                case 2:
                    Flush();
                    if (!ReadAlphanumeric(ref reader, new[] { 9, 11, 13 }[sizeClass], fnc1, text))
                    {
                        return null;
                    }

                    break;

                case 4:
                {
                    var bits = sizeClass == 0 ? 8 : 16;
                    if (reader.Available < bits)
                    {
                        return null;
                    }

                    var count = reader.Read(bits);
                    if (reader.Available < count * 8)
                    {
                        return null;
                    }

                    for (var i = 0; i < count; i++)
                    {
                        pending.Add((byte)reader.Read(8));
                    }

                    break;
                }

                case 8:
                {
                    Flush();
                    var bits = new[] { 8, 10, 12 }[sizeClass];
                    if (reader.Available < bits)
                    {
                        return null;
                    }

                    var count = reader.Read(bits);
                    if (reader.Available < count * 13)
                    {
                        return null;
                    }

                    var shiftJis = new byte[count * 2];
                    for (var i = 0; i < count; i++)
                    {
                        var value = reader.Read(13);
                        var assembled = ((value / 0xC0) << 8) | (value % 0xC0);
                        assembled += assembled < 0x1F00 ? 0x8140 : 0xC140;
                        shiftJis[2 * i] = (byte)(assembled >> 8);
                        shiftJis[2 * i + 1] = (byte)assembled;
                    }

                    text.Append(Decode(shiftJis, 20));
                    break;
                }

                default:
                    return null;
            }
        }

        Flush();
        return text.ToString();
    }

    private static bool ReadNumeric(ref BitReader reader, int countBits, StringBuilder text)
    {
        if (reader.Available < countBits)
        {
            return false;
        }

        var count = reader.Read(countBits);
        while (count >= 3)
        {
            if (reader.Available < 10)
            {
                return false;
            }

            var value = reader.Read(10);
            if (value >= 1000)
            {
                return false;
            }

            text.Append(value.ToString("D3", System.Globalization.CultureInfo.InvariantCulture));
            count -= 3;
        }

        // 剩两位 7 位、剩一位 4 位
        if (count > 0)
        {
            var bits = count == 2 ? 7 : 4;
            if (reader.Available < bits)
            {
                return false;
            }

            var value = reader.Read(bits);
            if (value >= (count == 2 ? 100 : 10))
            {
                return false;
            }

            text.Append(value.ToString(count == 2 ? "D2" : "D1", System.Globalization.CultureInfo.InvariantCulture));
        }

        return true;
    }

    private static bool ReadAlphanumeric(ref BitReader reader, int countBits, bool fnc1, StringBuilder text)
    {
        if (reader.Available < countBits)
        {
            return false;
        }

        var count = reader.Read(countBits);
        var segment = new StringBuilder(count);
        while (count >= 2)
        {
            if (reader.Available < 11)
            {
                return false;
            }

            var value = reader.Read(11);
            if (value >= 45 * 45)
            {
                return false;
            }

            segment.Append(Alphanumeric[value / 45]).Append(Alphanumeric[value % 45]);
            count -= 2;
        }

        if (count == 1)
        {
            if (reader.Available < 6)
            {
                return false;
            }

            var value = reader.Read(6);
            if (value >= 45)
            {
                return false;
            }

            segment.Append(Alphanumeric[value]);
        }

        if (!fnc1)
        {
            text.Append(segment);
            return true;
        }

        // GS1：% 是分隔符 GS（0x1D），%% 是一个 %
        for (var i = 0; i < segment.Length; i++)
        {
            if (segment[i] != '%')
            {
                text.Append(segment[i]);
            }
            else if (i + 1 < segment.Length && segment[i + 1] == '%')
            {
                text.Append('%');
                i++;
            }
            else
            {
                text.Append('\u001D');
            }
        }

        return true;
    }

    /// <summary>字节 → 文字：有 ECI 照它（不认识的 ECI 当没有）；没有时 UTF-8 → GB18030 → ISO-8859-1。</summary>
    private static string Decode(byte[] bytes, int eci)
    {
        if (eci >= 0 && CodePage(eci) is { } codePage)
        {
            try
            {
                return Encoding.GetEncoding(codePage).GetString(bytes);
            }
            catch (ArgumentException)
            {
                // 这台机器上没有这个字符集：往下猜
            }
            catch (NotSupportedException)
            {
            }
        }

        ReadOnlySpan<byte> body = bytes;
        if (body.Length >= 3 && body[0] == 0xEF && body[1] == 0xBB && body[2] == 0xBF)
        {
            body = body[3..];
        }

        try
        {
            return new UTF8Encoding(false, true).GetString(body);
        }
        catch (DecoderFallbackException)
        {
        }

        try
        {
            return Encoding.GetEncoding(54936, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
        }
        catch (ArgumentException)
        {
        }
        catch (NotSupportedException)
        {
        }

        return Encoding.Latin1.GetString(bytes);
    }

    /// <summary>ECI 指定符 → Windows 代码页（规范 AIM ECI 的常用几个）；不认识的返回 null。</summary>
    private static int? CodePage(int eci) => eci switch
    {
        0 or 2 => 437,
        1 or 3 => 28591,
        4 => 28592,
        5 => 28593,
        6 => 28594,
        7 => 28595,
        8 => 28596,
        9 => 28597,
        10 => 28598,
        11 => 28599,
        13 => 874,
        15 => 28603,
        17 => 28605,
        20 => 932,
        21 => 1250,
        22 => 1251,
        23 => 1252,
        24 => 1256,
        25 => 1201,
        26 => 65001,
        27 or 170 => 20127,
        28 => 950,
        29 => 54936,
        30 => 949,
        _ => null,
    };

    /// <summary>按位读（高位在前）。</summary>
    private struct BitReader
    {
        private readonly byte[] _bytes;
        private int _position;

        public BitReader(byte[] bytes)
        {
            _bytes = bytes;
            _position = 0;
        }

        public readonly int Available => _bytes.Length * 8 - _position;

        public int Read(int count)
        {
            var value = 0;
            for (var i = 0; i < count; i++)
            {
                var bit = (_bytes[_position >> 3] >> (7 - (_position & 7))) & 1;
                value = (value << 1) | bit;
                _position++;
            }

            return value;
        }
    }
}
