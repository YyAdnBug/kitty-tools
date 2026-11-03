// PNG 的宽高：只读文件头的 IHDR（纯函数，配单测），不用解码整张图。
// 长截图的角落卡、复制进剪贴板历史要的是图本身的像素尺寸，不是选区那么大（PLAN-v11 M16，REVIEW R62 漏的那条）。
using System.Buffers.Binary;

namespace KittyTools.Core;

public static class PngInfo
{
    private static ReadOnlySpan<byte> Signature => new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    /// <summary>PNG 的像素宽高；不是 PNG、头不完整、IHDR 不在第一块时返回 null。</summary>
    public static (int Width, int Height)? Size(ReadOnlySpan<byte> png)
    {
        // 8 字节签名 + 4 字节长度 + "IHDR" + 宽 4 + 高 4（大端）。
        if (png.Length < 24 || !png[..8].SequenceEqual(Signature) || !png.Slice(12, 4).SequenceEqual("IHDR"u8))
        {
            return null;
        }

        var width = BinaryPrimitives.ReadInt32BigEndian(png.Slice(16, 4));
        var height = BinaryPrimitives.ReadInt32BigEndian(png.Slice(20, 4));
        return width > 0 && height > 0 ? (width, height) : null;
    }
}
