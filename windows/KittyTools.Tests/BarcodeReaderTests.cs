// 识字认码（REVIEW R105）：Fixtures/barcodes/ 里的 64 张图是 windows/tools/barcode-fixtures.swift 在 Mac 上生成的
// （CoreImage 的二维码 / Code 128、照规范画的 EAN / UPC / Code 39 / ITF、照规范编的各种模式 / ECI / 掩码；转、透视、缩放、噪声、
// 模糊、深色底、一图多码，还有没码的图），每张都用 mac 识字用的 Vision 读过一遍（只有「GBK 不带 ECI」那张 Vision 读成乱码，
// 这里按 GB18030 读，见 QrBitstream 文件头）。清单 manifest.json 是每张图里每个码的内容。
// 另有里德-所罗门纠错：规范附录的「HELLO WORLD」1-M 纠错码字，和随机错不超过纠错能力的码字块都纠得回来。
// 审查后（REVIEW R105「审查后改的」）加的：大图在时间上限内收手、超过像素上限先缩小、ITF 要三条线、中文汉字模式和 ECI 32。
using System.IO.Compression;
using System.Text.Json;
using KittyTools.Core.Barcodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class BarcodeReaderTests
{
    private static string FixtureDirectory => Path.Combine(AppContext.BaseDirectory, "Fixtures", "barcodes");

    [TestMethod]
    public void ReadsEveryFixture()
    {
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(FixtureDirectory, "manifest.json")));
        var failures = new List<string>();
        var count = 0;
        foreach (var entry in manifest.RootElement.EnumerateArray())
        {
            var file = entry.GetProperty("file").GetString() ?? string.Empty;
            var expected = entry.GetProperty("codes").EnumerateArray().Select(code => code.GetString() ?? string.Empty).ToList();
            var (bgra, width, height) = TestPng.Read(File.ReadAllBytes(Path.Combine(FixtureDirectory, file)));
            // 时间上限放宽：单测机器慢、Debug 构建，这里只验读得对不对
            var codes = BarcodeReader.Read(bgra, width, height, budgetMilliseconds: 30_000);
            if (codes.Count != expected.Count || !expected.ToHashSet().SetEquals(codes))
            {
                failures.Add($"{file}: 期望 [{string.Join(" | ", expected)}]，读到 [{string.Join(" | ", codes)}]");
            }

            count++;
        }

        Assert.IsTrue(count >= 60, $"清单里只有 {count} 张图");
        Assert.AreEqual(0, failures.Count, string.Join("\n", failures));
    }

    [TestMethod]
    public void QrCodesComeBeforeLinearOnes()
    {
        // 同 mac 识字的「二维码优先」：三个二维码在前，EAN-13 在最后
        var (bgra, width, height) = TestPng.Read(File.ReadAllBytes(Path.Combine(FixtureDirectory, "multi-3qr-1ean.png")));
        var codes = BarcodeReader.Read(bgra, width, height, budgetMilliseconds: 30_000);
        Assert.AreEqual(4, codes.Count);
        Assert.AreEqual("6901234567892", codes[3]);
    }

    [TestMethod]
    public void NothingInBlankOrTinyImages()
    {
        Assert.AreEqual(0, BarcodeReader.Read(new byte[4 * 4 * 4], 4, 4).Count);
        var white = Enumerable.Repeat((byte)255, 300 * 200 * 4).ToArray();
        Assert.AreEqual(0, BarcodeReader.Read(white, 300, 200).Count);
        // 像素不够
        Assert.AreEqual(0, BarcodeReader.Read(new byte[10], 300, 200).Count);
    }

    [TestMethod]
    public void HugeImagesStopWithinTheBudget()
    {
        // 审查第 1 条：3000 万像素的噪点、上限 100 ms。灰度、二值化里面也看时间，不会先在预处理里耗上好几秒（Debug 下原来要三四秒）
        var bgra = new byte[6000 * 5000 * 4];
        new Random(105).NextBytes(bgra);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var codes = BarcodeReader.Read(bgra, 6000, 5000, budgetMilliseconds: 100);
        watch.Stop();
        Assert.AreEqual(0, codes.Count);
        Assert.IsTrue(watch.ElapsedMilliseconds < 1100, $"上限 100 ms，用了 {watch.ElapsedMilliseconds} ms");
    }

    [TestMethod]
    public void ShrinksImagesOverThePixelCap()
    {
        // 4 像素一个模块的码放大 5 倍贴进 3000 × 2000 的白图；上限压到 150 万像素 → 缩成一半再认，照样读得出
        var (code, codeWidth, codeHeight) = TestPng.Read(File.ReadAllBytes(Path.Combine(FixtureDirectory, "qr-v02-M.png")));
        const int width = 3000;
        const int height = 2000;
        var bgra = Enumerable.Repeat((byte)255, width * height * 4).ToArray();
        for (var y = 0; y < codeHeight * 5; y++)
        {
            for (var x = 0; x < codeWidth * 5; x++)
            {
                var from = ((y / 5) * codeWidth + x / 5) * 4;
                var to = ((500 + y) * width + 700 + x) * 4;
                Array.Copy(code, from, bgra, to, 4);
            }
        }

        var codes = BarcodeReader.Read(bgra, width, height, budgetMilliseconds: 30_000, maxPixels: 1_500_000);
        CollectionAssert.AreEqual(new[] { Expected("qr-v02-M.png") }, codes.ToArray());
    }

    [TestMethod]
    public void ItfNeedsThreeLines()
    {
        // 审查第 3 条：ITF、Code 39 没有校验位，三条扫描线读到才算。40 像素高的图横线每两行一条（y = 1, 3, 5…）：
        // 4 像素高的条（第 10–13 行）只有两条线穿过，不算；8 像素高的四条，算。斜线穿不过这么矮的整条码
        Assert.AreEqual(0, ReadItf(4).Count);
        CollectionAssert.AreEqual(new[] { "1234567890" }, ReadItf(8).ToArray());
    }

    [TestMethod]
    public void ReadsHanziModeAndNewerEcis()
    {
        // 审查第 4 条：1101 中文汉字模式（GB/T 18284）：子集 0001 = GB2312，版本 1 的字符数 8 位，每个字 13 位
        // （GB2312 的双字节 0xA1A1–0xAAFE 减 0xA1A1、0xB0A1–0xFAFE 减 0xA6A1，高字节 × 0x60 + 低字节：中 4655、文 3875、，203）
        var hanzi = Bits((0b1101, 4), (1, 4), (6, 8), (4655, 13), (3875, 13), (203, 13), (1629, 13), (3851, 13), (2762, 13), (0, 4));
        Assert.AreEqual("中文，二维码", QrBitstream.Parse(hanzi, 1));
        // 子集不是 GB2312：读不出来
        Assert.IsNull(QrBitstream.Parse(Bits((0b1101, 4), (2, 4), (1, 8), (4655, 13), (0, 4)), 1));
        // ECI 32（GB18030）+ 字节模式：「扫码」两个双字节、😀 是四字节
        var eci = Bits((0b0111, 4), (32, 8), (0b0100, 4), (8, 8), (201, 8), (168, 8), (194, 8), (235, 8), (148, 8), (57, 8), (252, 8), (54, 8), (0, 4));
        Assert.AreEqual("扫码😀", QrBitstream.Parse(eci, 1));
    }

    [TestMethod]
    public void ReedSolomonMatchesTheSpecExample()
    {
        // ISO/IEC 18004「HELLO WORLD」1-M：16 个数据码字、10 个纠错码字
        int[] data = { 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17 };
        int[] ecc = { 196, 35, 39, 119, 235, 215, 231, 226, 93, 23 };
        CollectionAssert.AreEqual(ecc, Encode(data, 10)[16..]);

        var damaged = data.Concat(ecc).ToArray();
        damaged[0] ^= 0xFF;
        damaged[7] ^= 0x01;
        damaged[20] ^= 0x5A;
        damaged[25] ^= 0x80;
        damaged[11] ^= 0x33;
        Assert.IsTrue(ReedSolomon.Correct(GaloisField.QrCode, damaged, 10));
        CollectionAssert.AreEqual(data.Concat(ecc).ToArray(), damaged);
    }

    [TestMethod]
    public void ReedSolomonCorrectsUpToHalfTheEccCodewords()
    {
        var random = new Random(105);
        foreach (var ecc in new[] { 7, 10, 13, 17, 22, 26, 28, 30 })
        {
            for (var trial = 0; trial < 60; trial++)
            {
                var data = Enumerable.Range(0, 1 + random.Next(254 - ecc)).Select(_ => random.Next(256)).ToArray();
                var word = Encode(data, ecc);
                var damaged = (int[])word.Clone();
                var errors = random.Next(ecc / 2 + 1);
                foreach (var position in Enumerable.Range(0, word.Length).OrderBy(_ => random.Next()).Take(errors))
                {
                    damaged[position] ^= 1 + random.Next(255);
                }

                Assert.IsTrue(ReedSolomon.Correct(GaloisField.QrCode, damaged, ecc), $"纠错码 {ecc} 个、错 {errors} 个");
                CollectionAssert.AreEqual(word, damaged);
            }
        }
    }

    private static string Expected(string file)
    {
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(FixtureDirectory, "manifest.json")));
        var entry = manifest.RootElement.EnumerateArray().First(item => item.GetProperty("file").GetString() == file);
        return entry.GetProperty("codes")[0].GetString() ?? string.Empty;
    }

    /// <summary>白底上画一条 ITF「1234567890」：2 像素一个模块、宽条 3 个模块，条从第 10 行起 barHeight 行高，左右各留 20 个模块。</summary>
    private static IReadOnlyList<string> ReadItf(int barHeight)
    {
        int[] patterns = { 0b00110, 0b10001, 0b01001, 0b11000, 0b00101, 0b10100, 0b01100, 0b00011, 0b10010, 0b01010 };
        const string digits = "1234567890";
        var widths = new List<int> { 1, 1, 1, 1 };
        for (var i = 0; i < digits.Length; i += 2)
        {
            var bars = patterns[digits[i] - '0'];
            var spaces = patterns[digits[i + 1] - '0'];
            for (var j = 4; j >= 0; j--)
            {
                widths.Add(((bars >> j) & 1) == 1 ? 3 : 1);
                widths.Add(((spaces >> j) & 1) == 1 ? 3 : 1);
            }
        }

        widths.AddRange(new[] { 3, 1, 1 });
        var modules = new List<bool>();
        var dark = true;
        foreach (var w in widths)
        {
            modules.AddRange(Enumerable.Repeat(dark, w));
            dark = !dark;
        }

        var width = (modules.Count + 40) * 2;
        const int height = 40;
        var bgra = Enumerable.Repeat((byte)255, width * height * 4).ToArray();
        for (var y = 10; y < 10 + barHeight; y++)
        {
            for (var m = 0; m < modules.Count; m++)
            {
                if (!modules[m])
                {
                    continue;
                }

                for (var dx = 0; dx < 2; dx++)
                {
                    var p = (y * width + (20 + m) * 2 + dx) * 4;
                    bgra[p] = bgra[p + 1] = bgra[p + 2] = 0;
                }
            }
        }

        return BarcodeReader.Read(bgra, width, height, budgetMilliseconds: 30_000);
    }

    /// <summary>按位拼数据码字（高位在前），不满一个字节的补 0。</summary>
    private static byte[] Bits(params (int Value, int Count)[] fields)
    {
        var bits = new List<bool>();
        foreach (var (value, count) in fields)
        {
            for (var i = count - 1; i >= 0; i--)
            {
                bits.Add(((value >> i) & 1) == 1);
            }
        }

        var bytes = new byte[(bits.Count + 7) / 8];
        for (var i = 0; i < bits.Count; i++)
        {
            if (bits[i])
            {
                bytes[i >> 3] |= (byte)(0x80 >> (i & 7));
            }
        }

        return bytes;
    }

    /// <summary>数据码字后面接上纠错码字（生成多项式 ∏(x - α^i)，i = 0…ecc-1，同二维码）。</summary>
    private static int[] Encode(int[] data, int ecc)
    {
        var field = GaloisField.QrCode;
        var generator = new[] { 1 };
        for (var i = 0; i < ecc; i++)
        {
            var root = field.Alpha(i);
            var next = new int[generator.Length + 1];
            for (var j = 0; j < generator.Length; j++)
            {
                next[j] ^= generator[j];
                next[j + 1] ^= field.Multiply(generator[j], root);
            }

            generator = next;
        }

        var remainder = new int[ecc];
        foreach (var codeword in data)
        {
            var factor = codeword ^ remainder[0];
            Array.Copy(remainder, 1, remainder, 0, ecc - 1);
            remainder[ecc - 1] = 0;
            for (var j = 0; j < ecc; j++)
            {
                remainder[j] ^= field.Multiply(generator[j + 1], factor);
            }
        }

        return data.Concat(remainder).ToArray();
    }

    /// <summary>
    /// 单测用的 PNG 读取：8 位灰度 / 灰度带 alpha / RGB / RGBA、不隔行（生成脚本写的就是这几种），五种行过滤器。
    /// 出来的是 BGRA（alpha 不预乘）。
    /// </summary>
    private static class TestPng
    {
        public static (byte[] Bgra, int Width, int Height) Read(byte[] png)
        {
            var position = 8;
            int width = 0, height = 0, channels = 0;
            using var idat = new MemoryStream();
            while (position + 8 <= png.Length)
            {
                var length = (png[position] << 24) | (png[position + 1] << 16) | (png[position + 2] << 8) | png[position + 3];
                var type = System.Text.Encoding.ASCII.GetString(png, position + 4, 4);
                var body = position + 8;
                if (type == "IHDR")
                {
                    width = (png[body] << 24) | (png[body + 1] << 16) | (png[body + 2] << 8) | png[body + 3];
                    height = (png[body + 4] << 24) | (png[body + 5] << 16) | (png[body + 6] << 8) | png[body + 7];
                    Assert.AreEqual(8, png[body + 8], "只读 8 位的 PNG");
                    Assert.AreEqual(0, png[body + 12], "只读不隔行的 PNG");
                    channels = png[body + 9] switch
                    {
                        0 => 1,
                        2 => 3,
                        4 => 2,
                        6 => 4,
                        _ => throw new InvalidDataException("不认识的 PNG 颜色类型"),
                    };
                }
                else if (type == "IDAT")
                {
                    idat.Write(png, body, length);
                }
                else if (type == "IEND")
                {
                    break;
                }

                position = body + length + 4;
            }

            idat.Position = 0;
            using var zlib = new ZLibStream(idat, CompressionMode.Decompress);
            using var raw = new MemoryStream();
            zlib.CopyTo(raw);
            var bytes = raw.ToArray();

            var stride = width * channels;
            var pixels = new byte[stride * height];
            for (var y = 0; y < height; y++)
            {
                var filter = bytes[y * (stride + 1)];
                for (var x = 0; x < stride; x++)
                {
                    int value = bytes[y * (stride + 1) + 1 + x];
                    int left = x >= channels ? pixels[y * stride + x - channels] : 0;
                    int up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
                    int upLeft = x >= channels && y > 0 ? pixels[(y - 1) * stride + x - channels] : 0;
                    value += filter switch
                    {
                        1 => left,
                        2 => up,
                        3 => (left + up) / 2,
                        4 => Paeth(left, up, upLeft),
                        _ => 0,
                    };
                    pixels[y * stride + x] = (byte)value;
                }
            }

            var bgra = new byte[width * height * 4];
            for (var i = 0; i < width * height; i++)
            {
                var p = i * channels;
                byte r, g, b, a;
                switch (channels)
                {
                    case 1:
                        r = g = b = pixels[p];
                        a = 255;
                        break;
                    case 2:
                        r = g = b = pixels[p];
                        a = pixels[p + 1];
                        break;
                    case 3:
                        (r, g, b, a) = (pixels[p], pixels[p + 1], pixels[p + 2], (byte)255);
                        break;
                    default:
                        (r, g, b, a) = (pixels[p], pixels[p + 1], pixels[p + 2], pixels[p + 3]);
                        break;
                }

                bgra[i * 4] = b;
                bgra[i * 4 + 1] = g;
                bgra[i * 4 + 2] = r;
                bgra[i * 4 + 3] = a;
            }

            return (bgra, width, height);
        }

        private static int Paeth(int a, int b, int c)
        {
            var p = a + b - c;
            var pa = Math.Abs(p - a);
            var pb = Math.Abs(p - b);
            var pc = Math.Abs(p - c);
            return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
        }
    }
}
