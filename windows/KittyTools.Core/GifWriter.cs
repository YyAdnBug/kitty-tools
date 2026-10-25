// GIF89a 写入器（第四版第 3 批「转 GIF」）：流式，一帧一帧量化 + LZW 编码，不把所有帧攒在内存里。
// 调色板：6×6×6 颜色立方（216 色）+ 40 级灰阶；每帧 256 色全局调色板，无本地表；循环播放。
// 只依赖 System.IO，纯函数式写入，配单测（看头部 / 帧数 / 结尾）。
using System.Buffers.Binary;

namespace KittyTools.Core;

public sealed class GifWriter : IDisposable
{
    private readonly Stream _stream;
    private readonly int _width;
    private readonly int _height;
    private readonly int _delayHundredths;
    private readonly byte[] _palette = new byte[256 * 3];
    private readonly byte[] _map = new byte[32 * 32 * 32];
    private int _frames;
    private bool _finished;

    public GifWriter(Stream stream, int width, int height, int delayHundredths = 10)
    {
        _stream = stream;
        _width = width;
        _height = height;
        _delayHundredths = Math.Clamp(delayHundredths, 2, 65535);
        BuildPalette();
        BuildMap();
        WriteHeader();
    }

    public int Frames => _frames;

    public void AddFrame(byte[] bgra)
    {
        if (_finished || bgra.Length < _width * _height * 4)
        {
            return;
        }

        // Graphic Control Extension：delay、disposal = 1（不清屏）。
        Span<byte> gce = stackalloc byte[8];
        gce[0] = 0x21;
        gce[1] = 0xF9;
        gce[2] = 4;
        gce[3] = 0x04; // disposal 1 + 无透明色
        BinaryPrimitives.WriteUInt16LittleEndian(gce[4..], (ushort)_delayHundredths);
        gce[6] = 0;
        gce[7] = 0;
        _stream.Write(gce);

        // Image Descriptor。
        Span<byte> descriptor = stackalloc byte[10];
        descriptor[0] = 0x2C;
        BinaryPrimitives.WriteUInt16LittleEndian(descriptor[1..], 0);
        BinaryPrimitives.WriteUInt16LittleEndian(descriptor[3..], 0);
        BinaryPrimitives.WriteUInt16LittleEndian(descriptor[5..], (ushort)_width);
        BinaryPrimitives.WriteUInt16LittleEndian(descriptor[7..], (ushort)_height);
        descriptor[9] = 0; // 不用本地调色板、不交错
        _stream.Write(descriptor);

        var indices = new byte[_width * _height];
        for (var index = 0; index < indices.Length; index++)
        {
            var offset = index * 4;
            var key = ((bgra[offset + 2] >> 3) << 10) | ((bgra[offset + 1] >> 3) << 5) | (bgra[offset] >> 3);
            indices[index] = _map[key];
        }

        _stream.WriteByte(8); // LZW minimum code size
        var compressed = LzwCompress(indices);
        for (var offset = 0; offset < compressed.Length; offset += 255)
        {
            var length = Math.Min(255, compressed.Length - offset);
            _stream.WriteByte((byte)length);
            _stream.Write(compressed, offset, length);
        }

        _stream.WriteByte(0);
        _frames++;
    }

    public void Finish()
    {
        if (_finished)
        {
            return;
        }

        _finished = true;
        _stream.WriteByte(0x3B);
        _stream.Flush();
    }

    public void Dispose() => Finish();

    private void WriteHeader()
    {
        _stream.Write("GIF89a"u8);
        Span<byte> screen = stackalloc byte[7];
        BinaryPrimitives.WriteUInt16LittleEndian(screen, (ushort)_width);
        BinaryPrimitives.WriteUInt16LittleEndian(screen[2..], (ushort)_height);
        screen[4] = 0xF7; // 全局调色板、256 色、8 位
        screen[5] = 0;
        screen[6] = 0;
        _stream.Write(screen);
        _stream.Write(_palette);

        // NETSCAPE2.0 循环扩展：无限循环。
        ReadOnlySpan<byte> loop = stackalloc byte[]
        {
            0x21, 0xFF, 0x0B, (byte)'N', (byte)'E', (byte)'T', (byte)'S', (byte)'C', (byte)'A',
            (byte)'P', (byte)'E', (byte)'2', (byte)'.', (byte)'0', 0x03, 0x01, 0x00, 0x00, 0x00,
        };
        _stream.Write(loop);
    }

    private void BuildPalette()
    {
        var index = 0;
        int[] levels = { 0, 51, 102, 153, 204, 255 };
        foreach (var r in levels)
        {
            foreach (var g in levels)
            {
                foreach (var b in levels)
                {
                    Put(index++, r, g, b);
                }
            }
        }

        for (var gray = 0; gray < 40; gray++)
        {
            var value = gray * 255 / 39;
            Put(index++, value, value, value);
        }
    }

    private void Put(int index, int r, int g, int b)
    {
        _palette[index * 3] = (byte)r;
        _palette[index * 3 + 1] = (byte)g;
        _palette[index * 3 + 2] = (byte)b;
    }

    /// <summary>32×32×32 的颜色（每通道取高 5 位）→ 调色板索引；一次算好。</summary>
    private void BuildMap()
    {
        for (var key = 0; key < _map.Length; key++)
        {
            var r = ((key >> 10) & 31) * 255 / 31;
            var g = ((key >> 5) & 31) * 255 / 31;
            var b = (key & 31) * 255 / 31;
            var best = 0;
            var bestDistance = int.MaxValue;
            for (var index = 0; index < 256; index++)
            {
                var dr = r - _palette[index * 3];
                var dg = g - _palette[index * 3 + 1];
                var db = b - _palette[index * 3 + 2];
                var distance = dr * dr + dg * dg + db * db;
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    best = index;
                }
            }

            _map[key] = (byte)best;
        }
    }

    /// <summary>GIF LZW（可变码长，8 位起，清空码 256，结束码 257）。</summary>
    private static byte[] LzwCompress(byte[] indices)
    {
        var output = new List<byte>(indices.Length / 2 + 16);
        var dictionary = new Dictionary<int, int>(4096);
        var codeSize = 9;
        var nextCode = 258;
        var bitBuffer = 0;
        var bitCount = 0;

        void Emit(int code)
        {
            bitBuffer |= code << bitCount;
            bitCount += codeSize;
            while (bitCount >= 8)
            {
                output.Add((byte)(bitBuffer & 0xFF));
                bitBuffer >>= 8;
                bitCount -= 8;
            }
        }

        void Reset()
        {
            dictionary.Clear();
            codeSize = 9;
            nextCode = 258;
        }

        Emit(256); // clear
        if (indices.Length == 0)
        {
            Emit(257);
        }
        else
        {
            var prefix = (int)indices[0];
            for (var index = 1; index < indices.Length; index++)
            {
                var suffix = indices[index];
                var key = (prefix << 8) | suffix;
                if (dictionary.TryGetValue(key, out var code))
                {
                    prefix = code;
                    continue;
                }

                Emit(prefix);
                dictionary[key] = nextCode++;
                if (nextCode > (1 << codeSize))
                {
                    codeSize++;
                }

                if (nextCode >= 4096)
                {
                    Emit(256);
                    Reset();
                }

                prefix = suffix;
            }

            Emit(prefix);
            Emit(257);
        }

        if (bitCount > 0)
        {
            output.Add((byte)(bitBuffer & 0xFF));
        }

        return output.ToArray();
    }
}
