// exe 安装包的载荷（PLAN-setup §2.1，配单测）：安装程序本体后面接 release 的 zip，最后 64 字节是固定格式的尾巴——
//   0–7 标记 KTSETUP1 | 8–15 载荷起点 | 16–23 载荷长度（int64 小端）| 24–55 载荷的 SHA-256 | 56–63 保留（写 0，读时不看）。
// 打包（Setup 的 --pack）写尾巴；安装时读尾巴、校验，再把载荷当成一个只读流交给 ZipArchive；
// 复制成 Uninstall.exe 时只拷载荷起点之前那一段。
using System.Buffers.Binary;
using System.Security.Cryptography;

namespace KittyTools.Core;

public sealed record SetupTrailer(long PayloadOffset, long PayloadLength, byte[] Sha256);

public static class SetupPayload
{
    public const int TrailerSize = 64;

    private static ReadOnlySpan<byte> Magic => "KTSETUP1"u8;

    /// <summary>本体 + zip + 尾巴写成 outputPath（先写 .partial，写完再改名）。本体自己已经带了载荷就拒绝。</summary>
    public static void Pack(string stubPath, string zipPath, string outputPath)
    {
        var partial = outputPath + ".partial";
        using (var stub = File.OpenRead(stubPath))
        using (var zip = File.OpenRead(zipPath))
        {
            if (ReadTrailer(stub) is not null)
            {
                throw new InvalidDataException("本体已经带了载荷");
            }

            var hash = SHA256.HashData(zip);
            using var output = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None);
            stub.Position = 0;
            stub.CopyTo(output);
            zip.Position = 0;
            zip.CopyTo(output);
            output.Write(BuildTrailer(new SetupTrailer(stub.Length, zip.Length, hash)));
        }

        File.Move(partial, outputPath, overwrite: true);
    }

    public static byte[] BuildTrailer(SetupTrailer trailer)
    {
        if (trailer.Sha256.Length != 32)
        {
            throw new ArgumentException("SHA-256 应该是 32 字节", nameof(trailer));
        }

        var bytes = new byte[TrailerSize];
        Magic.CopyTo(bytes);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(8), trailer.PayloadOffset);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(16), trailer.PayloadLength);
        trailer.Sha256.CopyTo(bytes, 24);
        return bytes;
    }

    /// <summary>读文件尾巴；标记不对、起点和长度对不上文件大小都返回 null（当「没有载荷」）。</summary>
    public static SetupTrailer? ReadTrailer(Stream file)
    {
        if (!file.CanSeek || file.Length < TrailerSize)
        {
            return null;
        }

        var bytes = new byte[TrailerSize];
        file.Seek(-TrailerSize, SeekOrigin.End);
        file.ReadExactly(bytes);
        return ParseTrailer(bytes, file.Length);
    }

    public static SetupTrailer? ParseTrailer(ReadOnlySpan<byte> bytes, long fileLength)
    {
        if (bytes.Length != TrailerSize || !bytes[..8].SequenceEqual(Magic))
        {
            return null;
        }

        var offset = BinaryPrimitives.ReadInt64LittleEndian(bytes[8..]);
        var length = BinaryPrimitives.ReadInt64LittleEndian(bytes[16..]);
        // 载荷必须紧挨在尾巴前面，前面还得有本体。先各自比文件小，相加才不会溢出。
        var end = fileLength - TrailerSize;
        if (offset <= 0 || length <= 0 || offset >= end || length >= end || offset + length != end)
        {
            return null;
        }

        return new SetupTrailer(offset, length, bytes[24..56].ToArray());
    }

    /// <summary>按尾巴里的 SHA-256 校验载荷（读完整段）。</summary>
    public static bool Verify(Stream file, SetupTrailer trailer)
    {
        using var payload = OpenPayload(file, trailer);
        return CryptographicOperations.FixedTimeEquals(SHA256.HashData(payload), trailer.Sha256);
    }

    /// <summary>载荷当成一个只读、可 Seek 的流（ZipArchive 要从末尾往前找中央目录）。不负责关 file。</summary>
    public static Stream OpenPayload(Stream file, SetupTrailer trailer)
        => new Window(file, trailer.PayloadOffset, trailer.PayloadLength);

    /// <summary>复制成 Uninstall.exe：只拷 file 开头的 length 字节（= 载荷起点，不带载荷和尾巴）。</summary>
    public static void CopyPrefix(Stream file, long length, Stream destination)
    {
        using var stub = new Window(file, 0, length);
        stub.CopyTo(destination);
    }

    /// <summary>底层流里 [start, start + length) 那一段。每次读之前把底层流挪到对的位置，所以可以和别人共用一个 FileStream。</summary>
    private sealed class Window(Stream inner, long start, long length) : Stream
    {
        private long _position;

        public override bool CanRead => true;

        public override bool CanSeek => true;

        public override bool CanWrite => false;

        public override long Length => length;

        public override long Position
        {
            get => _position;
            set => _position = value >= 0 ? value : throw new ArgumentOutOfRangeException(nameof(value));
        }

        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

        public override int Read(Span<byte> buffer)
        {
            var left = length - _position;
            if (left <= 0 || buffer.IsEmpty)
            {
                return 0;
            }

            if (buffer.Length > left)
            {
                buffer = buffer[..(int)left];
            }

            inner.Position = start + _position;
            var read = inner.Read(buffer);
            _position += read;
            return read;
        }

        public override long Seek(long offset, SeekOrigin origin)
        {
            Position = origin switch
            {
                SeekOrigin.Begin => offset,
                SeekOrigin.Current => _position + offset,
                _ => length + offset,
            };
            return _position;
        }

        public override void Flush()
        {
        }

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
