// 识字认码（REVIEW R105）：取好样的二维码模块 → 文字，照 ISO/IEC 18004 写的。
// 格式信息（纠错等级 + 掩码，两份，BCH(15,5) 取最近的合法码、最多差 3 位）→ 版本 7 起读版本信息（两份，BCH(18,6)，同样最多差 3 位）
// → 标出功能图形 → 按「两列一组、上下来回」读码字并去掉掩码 → 拆回各块、逐块里德-所罗门纠错 → 数据码字交给 QrBitstream。
// 模块是按需取样的（dark(x, y)：第 x 列第 y 行）：网格不对时读到格式信息就停了，不用把整个码取一遍。
// 两张表（每块纠错码字数、块数，按纠错等级 L M Q H × 版本 1–40）是规范表 9 的数；校正图形位置、数据模块数按规范的规律算。
namespace KittyTools.Core.Barcodes;

/// <summary>读的结果：Text 非空是读出来了；Version 大于 0 是版本信息说边长该是那个版本的；都没有是读不出来。</summary>
internal readonly record struct QrOutcome(string? Text, int Version)
{
    public static QrOutcome Failed => default;
}

internal static class QrDecoder
{
    // [纠错等级 L M Q H][版本]，下标 0 不用
    private static readonly int[][] EccPerBlock =
    {
        new[] { -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
        new[] { -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
        new[] { -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
        new[] { -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    };

    private static readonly int[][] BlockCount =
    {
        new[] { -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
        new[] { -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
        new[] { -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
        new[] { -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
    };

    /// <summary>格式信息里两位的纠错等级 → 上面两张表的行（01 L、00 M、11 Q、10 H）。</summary>
    private static readonly int[] LevelFromBits = { 1, 0, 3, 2 };

    /// <summary>32 种（纠错等级 × 掩码）格式信息加上 BCH 码、异或 0x5412 之后的 15 位。</summary>
    private static readonly int[] FormatCodes = MakeFormatCodes();

    /// <summary>版本 7–40 的 18 位版本信息（版本号 + BCH 码）。</summary>
    private static readonly int[] VersionCodes = MakeVersionCodes();

    private static int[] MakeFormatCodes()
    {
        var codes = new int[32];
        for (var data = 0; data < 32; data++)
        {
            var rem = data;
            for (var i = 0; i < 10; i++)
            {
                rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            }

            codes[data] = ((data << 10) | rem) ^ 0x5412;
        }

        return codes;
    }

    private static int[] MakeVersionCodes()
    {
        var codes = new int[41];
        for (var version = 7; version <= 40; version++)
        {
            var rem = version;
            for (var i = 0; i < 12; i++)
            {
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            }

            codes[version] = (version << 12) | rem;
        }

        return codes;
    }

    /// <summary>校正图形中心所在的行（列）号。</summary>
    private static int[] AlignmentPositions(int version)
    {
        if (version == 1)
        {
            return Array.Empty<int>();
        }

        var count = version / 7 + 2;
        var step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2;
        var result = new int[count];
        result[0] = 6;
        var position = version * 4 + 17 - 7;
        for (var i = count - 1; i >= 1; i--)
        {
            result[i] = position;
            position -= step;
        }

        return result;
    }

    /// <summary>去掉功能图形和格式、版本信息之后，放数据和纠错码的模块有几个。</summary>
    private static int RawDataModules(int version)
    {
        var result = (16 * version + 128) * version + 64;
        if (version >= 2)
        {
            var count = version / 7 + 2;
            result -= (25 * count - 10) * count - 55;
            if (version >= 7)
            {
                result -= 36;
            }
        }

        return result;
    }

    /// <summary>两份格式信息里有一份离合法的码不超过 3 位。</summary>
    public static bool HasFormat(int size, Func<int, int, bool> dark) => ReadFormat(size, dark) >= 0;

    /// <summary>格式信息的 5 位数据（纠错等级 2 位 + 掩码 3 位）；两份都读不出返回 -1。</summary>
    private static int ReadFormat(int size, Func<int, int, bool> dark)
    {
        var first = 0;
        var second = 0;
        for (var i = 0; i <= 5; i++)
        {
            if (dark(8, i))
            {
                first |= 1 << i;
            }
        }

        if (dark(8, 7))
        {
            first |= 1 << 6;
        }

        if (dark(8, 8))
        {
            first |= 1 << 7;
        }

        if (dark(7, 8))
        {
            first |= 1 << 8;
        }

        for (var i = 9; i < 15; i++)
        {
            if (dark(14 - i, 8))
            {
                first |= 1 << i;
            }
        }

        for (var i = 0; i < 8; i++)
        {
            if (dark(size - 1 - i, 8))
            {
                second |= 1 << i;
            }
        }

        for (var i = 8; i < 15; i++)
        {
            if (dark(8, size - 15 + i))
            {
                second |= 1 << i;
            }
        }

        var best = -1;
        var bestDistance = 4;
        for (var data = 0; data < 32; data++)
        {
            var distance = Math.Min(BitCount(FormatCodes[data] ^ first), BitCount(FormatCodes[data] ^ second));
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = data;
            }
        }

        return best;
    }

    private static int BitCount(int value) => System.Numerics.BitOperations.PopCount((uint)value);

    /// <summary>size × size 的码（dark(x, y) 取第 x 列第 y 行）→ 内容。</summary>
    public static QrOutcome Decode(int size, Func<int, int, bool> dark)
    {
        if (size < 21 || size > 177 || (size - 17) % 4 != 0)
        {
            return QrOutcome.Failed;
        }

        var version = (size - 17) / 4;
        var format = ReadFormat(size, dark);
        if (format < 0)
        {
            return QrOutcome.Failed;
        }

        var level = LevelFromBits[format >> 3];
        var mask = format & 7;

        if (version >= 7)
        {
            var a = 0;
            var b = 0;
            for (var i = 0; i < 18; i++)
            {
                if (dark(size - 11 + i % 3, i / 3))
                {
                    a |= 1 << i;
                }

                if (dark(i / 3, size - 11 + i % 3))
                {
                    b |= 1 << i;
                }
            }

            var bestVersion = -1;
            var bestDistance = 4;
            for (var v = 7; v <= 40; v++)
            {
                var distance = Math.Min(BitCount(VersionCodes[v] ^ a), BitCount(VersionCodes[v] ^ b));
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    bestVersion = v;
                }
            }

            if (bestVersion < 0)
            {
                return QrOutcome.Failed;
            }

            if (bestVersion != version)
            {
                return new QrOutcome(null, bestVersion);
            }
        }

        // 功能图形：三个定位图案连分隔符和格式信息（9×9 / 8×9）、两条定时图案、校正图形、版本信息
        var function = new bool[size * size];
        void Mark(int x0, int y0, int width, int height)
        {
            for (var y = y0; y < y0 + height; y++)
            {
                for (var x = x0; x < x0 + width; x++)
                {
                    function[y * size + x] = true;
                }
            }
        }

        Mark(0, 0, 9, 9);
        Mark(size - 8, 0, 8, 9);
        Mark(0, size - 8, 9, 8);
        Mark(6, 0, 1, size);
        Mark(0, 6, size, 1);
        var positions = AlignmentPositions(version);
        var last = positions.Length - 1;
        for (var i = 0; i < positions.Length; i++)
        {
            for (var j = 0; j < positions.Length; j++)
            {
                if ((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0))
                {
                    continue;
                }

                Mark(positions[i] - 2, positions[j] - 2, 5, 5);
            }
        }

        if (version >= 7)
        {
            Mark(size - 11, 0, 3, 6);
            Mark(0, size - 11, 6, 3);
        }

        // 从右下角起两列一组、上下来回读，跳过功能图形，顺手去掉掩码
        var rawCount = RawDataModules(version) / 8;
        var raw = new int[rawCount];
        var bitIndex = 0;
        for (var right = size - 1; right >= 1; right -= 2)
        {
            if (right == 6)
            {
                right = 5;
            }

            var upward = ((right + 1) & 2) == 0;
            for (var vertical = 0; vertical < size; vertical++)
            {
                for (var j = 0; j < 2; j++)
                {
                    var x = right - j;
                    var y = upward ? size - 1 - vertical : vertical;
                    if (function[y * size + x] || bitIndex >= rawCount * 8)
                    {
                        continue;
                    }

                    if (dark(x, y) != MaskBit(mask, x, y))
                    {
                        raw[bitIndex >> 3] |= 1 << (7 - (bitIndex & 7));
                    }

                    bitIndex++;
                }
            }
        }

        // 拆回各块（短块在前，长块多一个数据码字；先交织数据码字、再交织纠错码字），逐块纠错
        var blocks = BlockCount[level][version];
        var ecc = EccPerBlock[level][version];
        var shortBlocks = blocks - rawCount % blocks;
        var shortLength = rawCount / blocks;
        var blockData = new List<int>[blocks];
        for (var b = 0; b < blocks; b++)
        {
            blockData[b] = new List<int>(shortLength + 1);
        }

        var index = 0;
        for (var i = 0; i <= shortLength - ecc; i++)
        {
            for (var b = 0; b < blocks; b++)
            {
                if (i < shortLength - ecc || b >= shortBlocks)
                {
                    blockData[b].Add(raw[index++]);
                }
            }
        }

        for (var i = 0; i < ecc; i++)
        {
            for (var b = 0; b < blocks; b++)
            {
                blockData[b].Add(raw[index++]);
            }
        }

        var data = new List<byte>(rawCount);
        for (var b = 0; b < blocks; b++)
        {
            var codewords = blockData[b].ToArray();
            if (!ReedSolomon.Correct(GaloisField.QrCode, codewords, ecc))
            {
                return QrOutcome.Failed;
            }

            for (var k = 0; k < codewords.Length - ecc; k++)
            {
                data.Add((byte)codewords[k]);
            }
        }

        return QrBitstream.Parse(data.ToArray(), version) is { } text ? new QrOutcome(text, 0) : QrOutcome.Failed;
    }

    /// <summary>掩码 0–7 在第 x 列第 y 行要不要翻转。</summary>
    private static bool MaskBit(int mask, int x, int y) => mask switch
    {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}
