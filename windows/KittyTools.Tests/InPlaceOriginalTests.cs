// 截图就地翻译的「原图」（PLAN-v18 S6，照 mac translationStaysWithItsSelection）：翻完冻结帧那块换成译文；选区一变换回原图、
// 和原图逐字节相同；同一个选区再翻从原图翻、留最早那张；没贴过译文时选区怎么变都不动冻结帧。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class InPlaceOriginalTests
{
    private const int Width = 40;
    private const int Height = 30;

    private static byte[] Frame()
    {
        var frame = new byte[Width * Height * 4];
        for (var i = 0; i < frame.Length; i++)
        {
            frame[i] = (byte)(i * 7 % 251);
        }

        return frame;
    }

    private static byte[] Crop(byte[] frame, int left, int top, int width, int height)
    {
        var result = new byte[width * height * 4];
        for (var row = 0; row < height; row++)
        {
            Buffer.BlockCopy(frame, ((top + row) * Width + left) * 4, result, row * width * 4, width * 4);
        }

        return result;
    }

    private static byte[] Red(int width, int height)
    {
        var patch = new byte[width * height * 4];
        for (var i = 0; i < patch.Length; i += 4)
        {
            patch[i + 2] = 255;
            patch[i + 3] = 255;
        }

        return patch;
    }

    [TestMethod]
    public void SelectionChange_RestoresTheOriginalByteForByte()
    {
        var frame = Frame();
        var untouched = (byte[])frame.Clone();
        var original = new InPlaceOriginal();
        var selection = new RectD(5, 4, 10, 8);
        Assert.IsNull(original.OriginalFor(selection));
        var crop = Crop(frame, 5, 4, 10, 8);
        original.Remember(selection, 5, 4, 10, 8, crop);
        InPlaceOriginal.Paste(frame, Width, Red(10, 8), 5, 4, 10, 8);
        Assert.IsFalse(frame.SequenceEqual(untouched), "贴上了译文");
        Assert.IsTrue(original.HasTranslation);

        Assert.IsFalse(original.RestoreIfChanged(selection, frame, Width), "选区没变不动");
        Assert.IsTrue(original.RestoreIfChanged(selection with { X = 6 }, frame, Width), "方向键挪一下");
        CollectionAssert.AreEqual(untouched, frame);
        Assert.IsFalse(original.HasTranslation);
        Assert.IsFalse(original.RestoreIfChanged(null, frame, Width), "已经换回过了");
    }

    [TestMethod]
    public void SameSelection_TranslatesFromTheEarliestOriginal()
    {
        var frame = Frame();
        var untouched = (byte[])frame.Clone();
        var original = new InPlaceOriginal();
        var selection = new RectD(0, 0, 20, 10);
        original.Remember(selection, 0, 0, 20, 10, Crop(frame, 0, 0, 20, 10));
        InPlaceOriginal.Paste(frame, Width, Red(20, 10), 0, 0, 20, 10);

        // 再翻一次：拿到的是原图，不是贴了译文的那块；再记一次不换掉最早那张。
        var again = original.OriginalFor(selection);
        CollectionAssert.AreEqual(Crop(untouched, 0, 0, 20, 10), again);
        original.Remember(selection, 0, 0, 20, 10, Crop(frame, 0, 0, 20, 10));
        InPlaceOriginal.Paste(frame, Width, Red(20, 10), 0, 0, 20, 10);

        // 右键回到待选（没有选区）：换回原图。
        Assert.IsTrue(original.RestoreIfChanged(null, frame, Width));
        CollectionAssert.AreEqual(untouched, frame);
    }

    [TestMethod]
    public void NothingTranslated_SelectionChangesLeaveTheFrame()
    {
        var frame = Frame();
        var untouched = (byte[])frame.Clone();
        var original = new InPlaceOriginal();
        Assert.IsFalse(original.RestoreIfChanged(new RectD(1, 1, 5, 5), frame, Width));
        Assert.IsFalse(original.RestoreIfChanged(null, frame, Width));
        CollectionAssert.AreEqual(untouched, frame);
    }
}
