// 最小的 AVI（RIFF）写入器：单条 MJPEG 视频流，帧率固定，最后补 idx1 索引。
// 不用 Media Foundation / 第三方库：JPEG 用系统的 WIC 编码（Windows.Graphics.Imaging），容器自己写。
// 限制：4 GB 以内、没有音轨（PLAN-v4 的音轨没做，见报告）；文件先写临时名，停止后改名。
using System.Buffers.Binary;
using System.Text;

namespace KittyTools;

internal sealed class AviWriter : IDisposable
{
    private readonly FileStream _stream;
    private readonly BinaryWriter _writer;
    private readonly List<(uint Offset, uint Length)> _index = new();
    private readonly long _riffSizePosition;
    private readonly long _avihFramesPosition;
    private readonly long _strhLengthPosition;
    private readonly long _moviListPosition;
    private readonly long _moviSizePosition;
    private readonly long _moviDataPosition;
    private readonly int _width;
    private readonly int _height;
    private readonly int _fps;
    private bool _finished;

    public AviWriter(string path, int width, int height, int fps)
    {
        _width = width;
        _height = height;
        _fps = fps;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        _stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        _writer = new BinaryWriter(_stream, Encoding.ASCII, leaveOpen: true);

        WriteFourCc("RIFF");
        _riffSizePosition = _stream.Position;
        WriteUInt32(0); // 稍后补
        WriteFourCc("AVI ");

        // LIST hdrl
        WriteFourCc("LIST");
        var hdrlSizePosition = _stream.Position;
        WriteUInt32(0);
        WriteFourCc("hdrl");

        // avih
        WriteFourCc("avih");
        WriteUInt32(56);
        var avihPosition = _stream.Position;
        WriteUInt32((uint)(1_000_000 / fps)); // dwMicroSecPerFrame
        WriteUInt32(0);                       // dwMaxBytesPerSec（补不了就 0）
        WriteUInt32(0);                       // dwPaddingGranularity
        WriteUInt32(0x10);                    // AVIF_HASINDEX
        _avihFramesPosition = _stream.Position;
        WriteUInt32(0);                       // dwTotalFrames
        WriteUInt32(0);                       // dwInitialFrames
        WriteUInt32(1);                       // dwStreams
        WriteUInt32(Math.Max((uint)(width * height * 3), 65536)); // dwSuggestedBufferSize
        WriteUInt32((uint)width);
        WriteUInt32((uint)height);
        for (var index = 0; index < 4; index++)
        {
            WriteUInt32(0);
        }

        // LIST strl
        WriteFourCc("LIST");
        var strlSizePosition = _stream.Position;
        WriteUInt32(0);
        WriteFourCc("strl");

        // strh
        WriteFourCc("strh");
        WriteUInt32(56);
        WriteFourCc("vids");
        WriteFourCc("MJPG");
        WriteUInt32(0);   // dwFlags
        WriteUInt16(0);   // wPriority
        WriteUInt16(0);   // wLanguage
        WriteUInt32(0);   // dwInitialFrames
        WriteUInt32(1);   // dwScale
        WriteUInt32((uint)fps); // dwRate
        WriteUInt32(0);   // dwStart
        _strhLengthPosition = _stream.Position;
        WriteUInt32(0);   // dwLength（帧数）
        WriteUInt32(Math.Max((uint)(width * height * 3), 65536)); // dwSuggestedBufferSize
        WriteUInt32(0xFFFFFFFF); // dwQuality
        WriteUInt32(0);   // dwSampleSize
        WriteInt16(0); WriteInt16(0); WriteInt16((short)width); WriteInt16((short)height); // rcFrame

        // strf（BITMAPINFOHEADER）
        WriteFourCc("strf");
        WriteUInt32(40);
        WriteUInt32(40);
        WriteInt32(width);
        WriteInt32(height);
        WriteUInt16(1);   // biPlanes
        WriteUInt16(24);  // biBitCount
        WriteFourCc("MJPG"); // biCompression
        WriteUInt32((uint)(width * height * 3));
        for (var index = 0; index < 4; index++)
        {
            WriteUInt32(0);
        }

        PatchUInt32(hdrlSizePosition, (uint)(_stream.Position - hdrlSizePosition - 4));
        PatchUInt32(strlSizePosition, (uint)(_stream.Position - strlSizePosition - 4));

        // LIST movi
        _moviListPosition = _stream.Position;
        WriteFourCc("LIST");
        _moviSizePosition = _stream.Position;
        WriteUInt32(0);
        WriteFourCc("movi");
        _moviDataPosition = _stream.Position;
        _ = avihPosition;
    }

    public int Frames => _index.Count;

    public long Bytes => _stream.Length;

    /// <summary>加一帧 JPEG；每帧都是关键帧（MJPEG）。</summary>
    public void AddFrame(byte[] jpeg)
    {
        if (_finished)
        {
            return;
        }

        var offset = (uint)(_stream.Position - _moviDataPosition + 4); // 相对 'movi' 数据（同常见写法）
        WriteFourCc("00dc");
        WriteUInt32((uint)jpeg.Length);
        _writer.Write(jpeg);
        if ((jpeg.Length & 1) != 0)
        {
            _writer.Write((byte)0);
        }

        _index.Add((offset, (uint)jpeg.Length));
    }

    public void Finish()
    {
        if (_finished)
        {
            return;
        }

        _finished = true;
        var moviEnd = _stream.Position;
        PatchUInt32(_moviSizePosition, (uint)(moviEnd - _moviSizePosition - 4));

        // idx1
        WriteFourCc("idx1");
        WriteUInt32((uint)(_index.Count * 16));
        foreach (var (offset, length) in _index)
        {
            WriteFourCc("00dc");
            WriteUInt32(0x10); // AVIIF_KEYFRAME
            WriteUInt32(offset);
            WriteUInt32(length);
        }

        PatchUInt32(_avihFramesPosition, (uint)_index.Count);
        PatchUInt32(_strhLengthPosition, (uint)_index.Count);
        PatchUInt32(_riffSizePosition, (uint)(_stream.Length - 8));
        _writer.Flush();
        _stream.Flush(flushToDisk: true);
        _writer.Dispose();
        _stream.Dispose();
    }

    public void Dispose() => Finish();

    private void PatchUInt32(long position, uint value)
    {
        var current = _stream.Position;
        _stream.Position = position;
        Span<byte> buffer = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(buffer, value);
        _stream.Write(buffer);
        _stream.Position = current;
    }

    private void WriteFourCc(string value)
    {
        Span<byte> buffer = stackalloc byte[4];
        Encoding.ASCII.GetBytes(value, buffer);
        _stream.Write(buffer);
    }

    private void WriteUInt32(uint value)
    {
        Span<byte> buffer = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(buffer, value);
        _stream.Write(buffer);
    }

    private void WriteInt32(int value) => WriteUInt32((uint)value);

    private void WriteUInt16(ushort value)
    {
        Span<byte> buffer = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(buffer, value);
        _stream.Write(buffer);
    }

    private void WriteInt16(short value) => WriteUInt16((ushort)value);
}
