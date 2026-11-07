#:property PublishAot=false
// 把 PNG 无损地重新压一遍（PLAN-v16 V4：状态屏的动画表情帧图集让安装包大了 11 MB）。只用 .NET 自带的 zlib，不加任何包：
//   dotnet run windows/tools/png-squeeze.cs -- <目录>
// 每个 8 位 RGB / RGBA、不隔行的 PNG：解出像素 → 每行在五种滤波里挑「残差绝对值和最小」的那种、也整张试「全不滤波」「全 Paeth」，
// 取最小的 → zlib 最高压缩。别的块（sRGB、eXIf 这些）原样照抄、顺序不变（IDAT 之前的还在之前）；有调色板、16 位、隔行的跳过不动。
// 写之前把新文件再解一遍、和原像素逐字节比，一样才覆盖，变大了也不覆盖。在 Mac 上用 tools/status-emoji.swift 重新生成之后再跑一遍。
// 2026-11-07 第一次跑：34 个 PNG 9,932,758 → 7,722,618 字节（-22.3 %），像素逐字节相同（系统的 WIC 解出来也逐字节相同）。
using System.Buffers.Binary;
using System.IO.Compression;

if (args.Length != 1 || !Directory.Exists(args[0]))
{
    Console.Error.WriteLine("用法：dotnet run windows/tools/png-squeeze.cs -- <目录>");
    return 1;
}

long before = 0, after = 0;
foreach (var path in Directory.GetFiles(args[0], "*.png").Order(StringComparer.Ordinal))
{
    var data = File.ReadAllBytes(path);
    before += data.Length;
    if (Png.Decode(data) is not { } image)
    {
        Console.WriteLine($"跳过（不是 8 位 RGB / RGBA 不隔行）：{Path.GetFileName(path)}");
        after += data.Length;
        continue;
    }

    var squeezed = Png.Encode(image);
    if (squeezed.Length >= data.Length || Png.Decode(squeezed) is not { } check || !check.Pixels.AsSpan().SequenceEqual(image.Pixels))
    {
        Console.WriteLine($"不变：{Path.GetFileName(path)} {data.Length:N0}");
        after += data.Length;
        continue;
    }

    File.WriteAllBytes(path, squeezed);
    after += squeezed.Length;
    Console.WriteLine($"{Path.GetFileName(path)} {data.Length:N0} → {squeezed.Length:N0}");
}

Console.WriteLine($"合计 {before:N0} → {after:N0}（{100.0 * (before - after) / Math.Max(before, 1):F1} %）");
return 0;

/// <summary>Before / After：IDAT 前面、后面原样照抄的块（类型 + 内容），不含 IHDR / IDAT / IEND。</summary>
internal sealed record Image(int Width, int Height, int Channels, byte[] Pixels, List<(string Kind, byte[] Body)> Before, List<(string Kind, byte[] Body)> After);

internal static class Png
{
    private static readonly byte[] Signature = { 137, 80, 78, 71, 13, 10, 26, 10 };

    public static Image? Decode(byte[] data)
    {
        if (data.Length < 8 || !data.AsSpan(0, 8).SequenceEqual(Signature))
        {
            return null;
        }

        int width = 0, height = 0, channels = 0;
        var before = new List<(string, byte[])>();
        var after = new List<(string, byte[])>();
        using var compressed = new MemoryStream();
        for (var pos = 8; pos + 12 <= data.Length;)
        {
            var length = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(pos));
            var kind = System.Text.Encoding.ASCII.GetString(data, pos + 4, 4);
            var body = data.AsSpan(pos + 8, length);
            if (kind == "IHDR")
            {
                width = BinaryPrimitives.ReadInt32BigEndian(body);
                height = BinaryPrimitives.ReadInt32BigEndian(body[4..]);
                var (depth, color, interlace) = (body[8], body[9], body[12]);
                if (depth != 8 || interlace != 0 || color is not (2 or 6))
                {
                    return null;
                }

                channels = color == 6 ? 4 : 3;
            }
            else if (kind == "IDAT")
            {
                compressed.Write(body);
            }
            else if (kind != "IEND")
            {
                (compressed.Length == 0 ? before : after).Add((kind, body.ToArray()));
            }

            pos += 12 + length;
        }

        if (channels == 0)
        {
            return null;
        }

        compressed.Position = 0;
        using var inflated = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionMode.Decompress))
        {
            zlib.CopyTo(inflated);
        }

        var raw = inflated.ToArray();
        var stride = width * channels;
        if (raw.Length < (stride + 1) * height)
        {
            return null;
        }

        var pixels = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            var filter = raw[y * (stride + 1)];
            var line = pixels.AsSpan(y * stride, stride);
            raw.AsSpan(y * (stride + 1) + 1, stride).CopyTo(line);
            var previous = y > 0 ? pixels.AsSpan((y - 1) * stride, stride) : new byte[stride];
            for (var i = 0; i < stride; i++)
            {
                int a = i >= channels ? line[i - channels] : 0, b = previous[i], c = i >= channels ? previous[i - channels] : 0;
                line[i] = (byte)(line[i] + filter switch { 1 => a, 2 => b, 3 => (a + b) >> 1, 4 => Paeth(a, b, c), _ => 0 });
            }
        }

        return new Image(width, height, channels, pixels, before, after);
    }

    public static byte[] Encode(Image image)
    {
        var best = new[] { Deflate(Filtered(image, -1)), Deflate(Filtered(image, 0)), Deflate(Filtered(image, 4)) }
            .MinBy(bytes => bytes.Length)!;
        using var output = new MemoryStream();
        output.Write(Signature);
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, image.Width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), image.Height);
        header[8] = 8;
        header[9] = (byte)(image.Channels == 4 ? 6 : 2);
        Chunk(output, "IHDR", header);
        foreach (var (kind, body) in image.Before)
        {
            Chunk(output, kind, body);
        }

        Chunk(output, "IDAT", best);
        foreach (var (kind, body) in image.After)
        {
            Chunk(output, kind, body);
        }

        Chunk(output, "IEND", Array.Empty<byte>());
        return output.ToArray();
    }

    /// <summary>filter：-1 = 每行挑残差最小的，0–4 = 整张用这一种。</summary>
    private static byte[] Filtered(Image image, int filter)
    {
        var stride = image.Width * image.Channels;
        var result = new byte[(stride + 1) * image.Height];
        var candidate = new byte[stride];
        for (var y = 0; y < image.Height; y++)
        {
            var line = image.Pixels.AsSpan(y * stride, stride);
            var previous = y > 0 ? image.Pixels.AsSpan((y - 1) * stride, stride) : new byte[stride];
            var target = result.AsSpan(y * (stride + 1) + 1, stride);
            var chosen = filter;
            if (filter < 0)
            {
                var lowest = long.MaxValue;
                for (var kind = 0; kind < 5; kind++)
                {
                    Apply(line, previous, image.Channels, kind, candidate);
                    long score = 0;
                    foreach (var value in candidate)
                    {
                        score += value < 128 ? value : 256 - value;
                    }

                    if (score < lowest)
                    {
                        lowest = score;
                        chosen = kind;
                    }
                }
            }

            Apply(line, previous, image.Channels, chosen, target);
            result[y * (stride + 1)] = (byte)chosen;
        }

        return result;
    }

    private static void Apply(ReadOnlySpan<byte> line, ReadOnlySpan<byte> previous, int channels, int kind, Span<byte> output)
    {
        for (var i = 0; i < line.Length; i++)
        {
            int a = i >= channels ? line[i - channels] : 0, b = previous[i], c = i >= channels ? previous[i - channels] : 0;
            output[i] = (byte)(line[i] - kind switch { 1 => a, 2 => b, 3 => (a + b) >> 1, 4 => Paeth(a, b, c), _ => 0 });
        }
    }

    private static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    private static byte[] Deflate(byte[] raw)
    {
        using var output = new MemoryStream();
        using (var zlib = new ZLibStream(output, CompressionLevel.SmallestSize))
        {
            zlib.Write(raw);
        }

        return output.ToArray();
    }

    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++)
        {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        }

        return c;
    }).ToArray();

    /// <summary>PNG 块的 CRC-32（同 zlib 的那个多项式）。</summary>
    private static uint Crc(byte[] bytes)
    {
        var c = 0xFFFFFFFFu;
        foreach (var value in bytes)
        {
            c = CrcTable[(c ^ value) & 0xFF] ^ (c >> 8);
        }

        return c ^ 0xFFFFFFFFu;
    }

    private static void Chunk(Stream output, string kind, byte[] body)
    {
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(length, body.Length);
        output.Write(length);
        var typed = new byte[4 + body.Length];
        System.Text.Encoding.ASCII.GetBytes(kind, typed);
        body.CopyTo(typed, 4);
        output.Write(typed);
        Span<byte> crc = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crc, Crc(typed));
        output.Write(crc);
    }
}
